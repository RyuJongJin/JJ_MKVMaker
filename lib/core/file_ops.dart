import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../l10n/tr.dart';
import 'playlist.dart' show naturalCompare;
import 'vfs.dart';

/// 파일 탐색기 (X-plore 참고) 의 화면과 상관없는 부분: 폴더 읽기 · 정렬 · 복사 / 이동 / 삭제 · 찾기.

/// 폴더 안의 항목 하나
class FileEntry {
  final String path;
  final bool isDir;
  final int size;
  final DateTime modified;
  const FileEntry(this.path, {required this.isDir, this.size = 0, required this.modified});

  String get name => p.basename(path);
  bool get hidden => name.startsWith('.');

  /// 확장자 (소문자, 점 없이)
  String get ext => isDir ? '' : p.extension(path).replaceFirst('.', '').toLowerCase();
}

enum SortBy { name, date, size, type }

/// 정렬: 폴더 먼저, 이름은 숫자를 숫자로 비교 (file2 < file10)
List<FileEntry> sortEntries(List<FileEntry> list, SortBy by, {bool descending = false}) {
  int cmp(FileEntry a, FileEntry b) {
    if (a.isDir != b.isDir) return a.isDir ? -1 : 1; // 폴더는 거꾸로여도 늘 위
    final r = switch (by) {
      SortBy.name => 0,
      SortBy.date => a.modified.compareTo(b.modified),
      SortBy.size => a.size.compareTo(b.size),
      SortBy.type => a.ext.compareTo(b.ext),
    };
    final v = r != 0 ? r : naturalCompare(a.name, b.name);
    return descending ? -v : v;
  }

  return [...list]..sort(cmp);
}

/// 폴더 읽기 (읽을 수 없는 항목은 건너뜀). [showHidden] 이 아니면 점으로 시작하는 항목을 뺀다.
Future<List<FileEntry>> listEntries(String dir, {bool showHidden = false}) async {
  if (isDav(dir)) {
    // WebDAV: 네트워크 오류 · 인증 실패는 그대로 던진다 (화면이 "읽을 수 없음" 과 이유를 보여 줌)
    return [
      for (final e in await vList(dir))
        if (showHidden || !vBasename(e.path).startsWith('.'))
          FileEntry(e.path, isDir: e.isDir, size: e.size, modified: e.modified),
    ];
  }
  final out = <FileEntry>[];
  await for (final e in Directory(dir).list(followLinks: false).handleError((_) {})) {
    try {
      final st = await e.stat();
      final isDir = st.type == FileSystemEntityType.directory;
      final entry = FileEntry(e.path, isDir: isDir, size: isDir ? 0 : st.size, modified: st.modified);
      if (!showHidden && entry.hidden) continue;
      out.add(entry);
    } catch (_) {}
  }
  return out;
}

/// 저장 장치 (맨 위 폴더): Windows 는 드라이브 (C:\ …), 그 밖은 주어진 목록
List<(String path, String label)> windowsDrives() => [
      for (final c in 'CDEFGHIJKLMNOPQRSTUVWXYZAB'.split(''))
        if (FileSystemEntity.isDirectorySync('$c:\\')) ('$c:\\', '$c:'),
    ];

/// 같은 이름이 있으면 "이름 (2).확장자" 로
String uniqueTarget(String dir, String name) {
  var target = p.join(dir, name);
  if (FileSystemEntity.typeSync(target) == FileSystemEntityType.notFound) return target;
  final base = p.basenameWithoutExtension(name), ext = p.extension(name);
  for (var i = 2;; i++) {
    target = p.join(dir, '$base ($i)$ext');
    if (FileSystemEntity.typeSync(target) == FileSystemEntityType.notFound) return target;
  }
}

/// 같은 경로인지 (Windows 는 대소문자 무시)
bool samePath(String a, String b) {
  final dav = davSame(a, b);
  if (dav != null) return dav;
  final x = p.normalize(p.absolute(a)), y = p.normalize(p.absolute(b));
  return Platform.isWindows ? x.toLowerCase() == y.toLowerCase() : x == y;
}

/// [a] 가 [b] 와 같거나 그 안에 있는지 (폴더를 자기 안으로 복사 · 이동하지 않게)
bool isSameOrInside(String a, String b) {
  final dav = davInside(a, b);
  if (dav != null) return dav;
  final x = p.normalize(p.absolute(a)), y = p.normalize(p.absolute(b));
  return samePath(a, b) || p.isWithin(y, x) || (Platform.isWindows && p.isWithin(y.toLowerCase(), x.toLowerCase()));
}

/// 복사 · 이동을 시작하기 전 확인 (모든 방법 공통 - rsync · robocopy 는 스스로 막지 않는다).
/// 문제가 있으면 알릴 글, 없으면 null.
/// - 원본이 없음 (다른 곳에서 지워졌거나 옮겨짐) · 대상 폴더가 없음
/// - 폴더를 자기 자신 (또는 그 안) 으로 복사 · 이동
/// - 이미 그 폴더에 있는 것을 같은 폴더로 이동
String? transferProblem(List<String> sources, String dest, {required bool move}) {
  // WebDAV 경로는 네트워크라 여기서 있는지 확인하지 않는다 (없으면 복사할 때 알림)
  final missing = [for (final s in sources) if (vMissingSync(s)) s];
  if (missing.isNotEmpty) {
    return trf('원본이 없습니다 (다른 곳에서 지워졌거나 옮겨졌습니다): {0}', [missing.map(vBasename).join(', ')]);
  }
  if (!isDav(dest) && !Directory(dest).existsSync()) return trf('대상 폴더가 없습니다: {0}', [dest]);
  for (final s in sources) {
    if ((isDav(s) || FileSystemEntity.isDirectorySync(s)) && isSameOrInside(dest, s)) {
      return trf('폴더를 자기 자신 안으로 {0} 수 없습니다: {1}', [move ? tr('옮길') : tr('복사할'), vBasename(s)]);
    }
    if (move && samePath(vDirname(s), dest)) return trf('이미 이 폴더에 있습니다: {0}', [vBasename(s)]);
  }
  return null;
}

/// [root] 안의 빈 폴더를 안쪽부터 지운다 (find root/ -type d -empty -delete 와 같음). 지운 폴더 수.
/// [keepRoot] 면 [root] 자신은 비어도 남긴다. 파일 · 링크가 하나라도 있는 폴더는 그대로.
Future<int> removeEmptyDirs(String root, {bool keepRoot = true}) async {
  if (isDav(root)) return _removeEmptyDirsV(root, keepRoot: keepRoot);
  var n = 0;
  Future<bool> walk(Directory d) async {
    var empty = true;
    final items = await d.list(followLinks: false).handleError((_) => empty = false).toList();
    for (final e in items) {
      if (e is Directory && await walk(e)) {
        try {
          await e.delete();
          n++;
        } catch (_) {
          empty = false;
        }
      } else {
        empty = false;
      }
    }
    return empty;
  }

  final d = Directory(root);
  if (!await d.exists()) return 0;
  if (await walk(d) && !keepRoot) {
    try {
      await d.delete();
      n++;
    } catch (_) {}
  }
  return n;
}

/// 복사 · 이동 중 알림 (지금 파일, 지금까지 바이트, 전체 바이트)
typedef CopyProgress = void Function(String current, int done, int total);

/// [removeEmptyDirs] 의 WebDAV 판
Future<int> _removeEmptyDirsV(String root, {bool keepRoot = true}) async {
  var n = 0;
  Future<bool> walk(String dir) async {
    var empty = true;
    for (final e in await vList(dir)) {
      if (e.isDir && await walk(e.path)) {
        try {
          await vDelete(e.path);
          n++;
        } catch (_) {
          empty = false;
        }
      } else {
        empty = false;
      }
    }
    return empty;
  }

  if (!await vExists(root)) return 0;
  if (await walk(root) && !keepRoot) {
    try {
      await vDelete(root);
      n++;
    } catch (_) {}
  }
  return n;
}

class FileOpCancelled implements Exception {
  const FileOpCancelled();
}

/// 복사 · 이동 · 삭제. [cancel] 을 부르면 다음 조각에서 멈춘다.
class FileOps {
  bool _cancel = false;
  void cancel() => _cancel = true;

  /// 속도 제한 (KB/s, 0 = 제한 없음)
  final int bandwidthKBps;

  /// 파일 하나를 다 복사할 때마다 (원본 경로)
  final void Function(String source)? onFileDone;

  /// 조각을 보낼 때마다 (바이트) - 전송 속도 계산용
  final void Function(int bytes)? onBytes;

  FileOps({this.bandwidthKBps = 0, this.onFileDone, this.onBytes});

  /// 한쪽이라도 WebDAV 면 아래의 "V" (어느 저장소든) 판으로
  static bool _anyDav(Iterable<String> paths) => paths.any(isDav);

  final _clock = Stopwatch();
  int _sent = 0;

  /// 속도 제한: 보낸 양이 허용량보다 앞서면 그만큼 쉰다
  Future<void> _throttle(int bytes) async {
    if (bandwidthKBps <= 0) return;
    if (!_clock.isRunning) _clock.start();
    _sent += bytes;
    final wantMs = _sent * 1000 ~/ (bandwidthKBps * 1024);
    final ahead = wantMs - _clock.elapsedMilliseconds;
    if (ahead > 5) await Future<void>.delayed(Duration(milliseconds: ahead));
  }

  void _check() {
    if (_cancel) throw const FileOpCancelled();
  }

  /// 전체 크기 (진행률용)
  static Future<int> totalSize(List<String> paths) async {
    if (_anyDav(paths)) return _totalSizeV(paths);
    var total = 0;
    for (final s in paths) {
      final t = FileSystemEntity.typeSync(s, followLinks: false);
      if (t == FileSystemEntityType.directory) {
        await for (final e in Directory(s).list(recursive: true, followLinks: false).handleError((_) {})) {
          if (e is File) {
            try {
              total += await e.length();
            } catch (_) {}
          }
        }
      } else if (t == FileSystemEntityType.file) {
        total += await File(s).length();
      }
    }
    return total;
  }

  /// [sources] 를 [destDir] 로 복사 (같은 이름이 있으면 "이름 (2)"). 만든 경로들을 돌려준다.
  Future<List<String>> copy(List<String> sources, String destDir, {CopyProgress? onProgress}) async {
    if (_anyDav([...sources, destDir])) return _copyV(sources, destDir, onProgress: onProgress);
    final total = await totalSize(sources);
    var done = 0;
    final made = <String>[];
    Future<void> copyFile(File f, String target) async {
      _check();
      final out = File(target).openWrite();
      try {
        try {
          await for (final chunk in f.openRead()) {
            _check();
            out.add(chunk);
            done += chunk.length;
            onProgress?.call(f.path, done, total);
            onBytes?.call(chunk.length);
            await _throttle(chunk.length);
          }
        } finally {
          await out.close();
        }
        _check();
      } catch (_) {
        // 취소 · 실패: 만들다 만 파일을 남기지 않는다
        try {
          await File(target).delete();
        } catch (_) {}
        rethrow;
      }
      try {
        await File(target).setLastModified(await f.lastModified());
      } catch (_) {}
      onFileDone?.call(f.path);
    }

    Future<void> copyAny(String src, String target) async {
      if (FileSystemEntity.isDirectorySync(src)) {
        await Directory(target).create(recursive: true);
        await for (final e in Directory(src).list(followLinks: false)) {
          await copyAny(e.path, p.join(target, p.basename(e.path)));
        }
      } else {
        await copyFile(File(src), target);
      }
    }

    for (final s in sources) {
      if (FileSystemEntity.isDirectorySync(s) && isSameOrInside(destDir, s)) {
        throw FileSystemException('폴더를 자기 안으로 복사할 수 없습니다', s);
      }
      final target = uniqueTarget(destDir, p.basename(s));
      await copyAny(s, target);
      made.add(target);
    }
    return made;
  }

  /// 이동: 같은 드라이브면 이름 바꾸기, 아니면 복사한 뒤 원본 삭제
  Future<List<String>> move(List<String> sources, String destDir, {CopyProgress? onProgress}) async {
    if (_anyDav([...sources, destDir])) return _moveV(sources, destDir, onProgress: onProgress);
    final made = <String>[];
    for (final s in sources) {
      _check();
      if (isSameOrInside(destDir, s)) throw FileSystemException('폴더를 자기 안으로 옮길 수 없습니다', s);
      if (samePath(p.dirname(s), destDir)) {
        made.add(s); // 이미 그 폴더에 있음
        continue;
      }
      final target = uniqueTarget(destDir, p.basename(s));
      try {
        final t = FileSystemEntity.typeSync(s);
        if (t == FileSystemEntityType.directory) {
          await Directory(s).rename(target);
        } else {
          await File(s).rename(target);
        }
        made.add(target);
      } on FileSystemException {
        // 다른 드라이브 · 저장 장치: 복사 후 삭제
        final copied = await copy([s], destDir, onProgress: onProgress);
        await delete([s]);
        made.addAll(copied);
      }
    }
    return made;
  }

  /// 동기화 (실시간 동기화 · lsyncd 처럼): [srcDir] 의 내용을 [dstDir] 에 맞춘다.
  /// 크기나 바뀐 시각이 다른 파일만 복사, [delete] 면 원본에 없는 것을 대상에서 지운다. 복사한 파일 수를 돌려준다.
  ///
  /// [update] (rsync -u): 대상이 더 새 파일이면 건너뛴다 (양쪽 ⇄ 을 함께 맞출 때 서로 덮어쓰지 않게).
  Future<int> mirror(String srcDir, String dstDir, {bool delete = false, bool update = false}) async {
    if (_anyDav([srcDir, dstDir])) return _mirrorV(srcDir, dstDir, delete: delete, update: update);
    var n = 0;
    Future<void> walk(String src, String dst) async {
      _check();
      await Directory(dst).create(recursive: true);
      final names = <String>{};
      await for (final e in Directory(src).list(followLinks: false).handleError((_) {})) {
        final name = p.basename(e.path);
        names.add(name);
        final target = p.join(dst, name);
        if (e is Directory) {
          await walk(e.path, target);
        } else if (e is File) {
          final st = await e.stat();
          final t = File(target);
          final exists = await t.exists();
          final same = exists &&
              (await t.length()) == st.size &&
              ((await t.lastModified()).difference(st.modified).inSeconds.abs() <= 2);
          if (same) continue;
          if (update && exists && (await t.lastModified()).isAfter(st.modified.add(const Duration(seconds: 2)))) continue;
          final tmp = '$target.jjsync';
          final out = File(tmp).openWrite();
          try {
            await for (final chunk in e.openRead()) {
              _check();
              out.add(chunk);
              onBytes?.call(chunk.length);
              await _throttle(chunk.length);
            }
          } finally {
            await out.close();
          }
          await File(tmp).rename(target);
          try {
            await File(target).setLastModified(st.modified);
          } catch (_) {}
          n++;
          onFileDone?.call(e.path);
        }
      }
      if (delete) {
        await for (final e in Directory(dst).list(followLinks: false).handleError((_) {})) {
          if (!names.contains(p.basename(e.path)) && !e.path.endsWith('.jjsync')) {
            await e.delete(recursive: true);
          }
        }
      }
    }

    await walk(srcDir, dstDir);
    return n;
  }

  Future<void> delete(List<String> paths) async {
    for (final s in paths) {
      _check();
      if (isDav(s)) {
        await vDelete(s);
        continue;
      }
      final t = FileSystemEntity.typeSync(s, followLinks: false);
      if (t == FileSystemEntityType.directory) {
        await Directory(s).delete(recursive: true);
      } else if (t != FileSystemEntityType.notFound) {
        await File(s).delete();
      }
    }
  }

  /// 이름 바꾸기 (같은 폴더 안). 새 경로를 돌려준다.
  static Future<String> rename(String path, String newName) async {
    final name = newName.trim();
    if (name.isEmpty || name.contains(RegExp(r'[\\/:*?"<>|]'))) {
      throw FileSystemException('쓸 수 없는 이름입니다', name);
    }
    if (isDav(path)) {
      final target = vJoin(vDirname(path), name);
      if (target == vNorm(path)) return target;
      if (await vExists(target)) throw FileSystemException('같은 이름이 이미 있습니다', target);
      await vRename(path, target);
      return target;
    }
    final target = p.join(p.dirname(path), name);
    if (target == path) return path;
    if (FileSystemEntity.typeSync(target) != FileSystemEntityType.notFound &&
        target.toLowerCase() != path.toLowerCase()) {
      throw FileSystemException('같은 이름이 이미 있습니다', target);
    }
    final t = FileSystemEntity.typeSync(path);
    return t == FileSystemEntityType.directory
        ? (await Directory(path).rename(target)).path
        : (await File(path).rename(target)).path;
  }

  static Future<String> makeFolder(String dir, String name) async {
    final n = name.trim();
    if (n.isEmpty || n.contains(RegExp(r'[\\/:*?"<>|]'))) throw FileSystemException('쓸 수 없는 이름입니다', n);
    if (isDav(dir)) {
      final target = vJoin(dir, n);
      if (await vExists(target)) throw FileSystemException('같은 이름이 이미 있습니다', target);
      await vMkdirs(target);
      return target;
    }
    final target = p.join(dir, n);
    if (FileSystemEntity.typeSync(target) != FileSystemEntityType.notFound) {
      throw FileSystemException('같은 이름이 이미 있습니다', target);
    }
    return (await Directory(target).create()).path;
  }

  // ───────── 어느 저장소든 (로컬 · WebDAV) ─────────

  static Future<int> _totalSizeV(List<String> paths) async {
    var total = 0;
    Future<void> walk(String path) async {
      final st = await vStat(path);
      if (st == null) return;
      if (!st.isDir) {
        total += st.size;
        return;
      }
      for (final e in await vList(path)) {
        if (e.isDir) {
          await walk(e.path);
        } else {
          total += e.size;
        }
      }
    }

    for (final s in paths) {
      await walk(s);
    }
    return total;
  }

  /// 파일 하나: 읽어서 쓴다 (속도 제한 · 취소 · 진행)
  Future<void> _copyFileV(String src, String target, int size, DateTime modified, void Function(int n)? onChunk) async {
    _check();
    final input = await vOpenRead(src);
    final relay = StreamController<List<int>>();
    final pump = () async {
      try {
        await for (final chunk in input) {
          if (_cancel) break;
          relay.add(chunk);
          onBytes?.call(chunk.length);
          onChunk?.call(chunk.length);
          await _throttle(chunk.length);
        }
      } catch (e, st) {
        relay.addError(e, st);
      } finally {
        await relay.close();
      }
    }();
    try {
      await vWrite(target, relay.stream, length: size, modified: modified);
    } finally {
      await pump;
    }
    if (_cancel) {
      try {
        await vDelete(target);
      } catch (_) {}
      throw const FileOpCancelled();
    }
    onFileDone?.call(src);
  }

  Future<List<String>> _copyV(List<String> sources, String destDir, {CopyProgress? onProgress}) async {
    final total = await _totalSizeV(sources);
    var done = 0;
    final made = <String>[];
    Future<void> copyAny(String src, String target) async {
      _check();
      final st = await vStat(src);
      if (st == null) throw FileSystemException('원본이 없습니다', src);
      if (st.isDir) {
        await vMkdirs(target);
        for (final e in await vList(src)) {
          await copyAny(e.path, vJoin(target, vBasename(e.path)));
        }
      } else {
        await _copyFileV(src, target, st.size, st.modified, (n) {
          done += n;
          onProgress?.call(src, done, total);
        });
      }
    }

    for (final s in sources) {
      if (isSameOrInside(destDir, s) && await vIsDir(s)) throw FileSystemException('폴더를 자기 안으로 복사할 수 없습니다', s);
      final target = await vUniqueTarget(destDir, vBasename(s));
      await copyAny(s, target);
      made.add(target);
    }
    return made;
  }

  Future<List<String>> _moveV(List<String> sources, String destDir, {CopyProgress? onProgress}) async {
    final made = <String>[];
    for (final s in sources) {
      _check();
      if (isSameOrInside(destDir, s)) throw FileSystemException('폴더를 자기 안으로 옮길 수 없습니다', s);
      if (samePath(vDirname(s), destDir)) {
        made.add(s);
        continue;
      }
      final target = await vUniqueTarget(destDir, vBasename(s));
      // 같은 WebDAV 서버 안이면 서버가 옮긴다 (빠름)
      if (isDav(s) && isDav(destDir) && DavPath.parse(s).server == DavPath.parse(destDir).server) {
        await vRename(s, target);
        made.add(target);
        continue;
      }
      made.addAll(await _copyV([s], destDir, onProgress: onProgress));
      await vDelete(s);
    }
    return made;
  }

  Future<int> _mirrorV(String srcDir, String dstDir, {bool delete = false, bool update = false}) async {
    var n = 0;
    Future<void> walk(String src, String dst) async {
      _check();
      await vMkdirs(dst);
      final there = {for (final e in await vList(dst)) vBasename(e.path): e};
      final names = <String>{};
      for (final e in await vList(src)) {
        final name = vBasename(e.path);
        names.add(name);
        final target = vJoin(dst, name);
        if (e.isDir) {
          await walk(e.path, target);
          continue;
        }
        final t = there[name];
        if (t != null && !t.isDir && t.size == e.size) {
          // 크기가 같고 대상이 원본보다 새것이거나 (올린 파일은 서버 시각) 거의 같으면 그대로
          if (!t.modified.isBefore(e.modified.subtract(const Duration(seconds: 2)))) continue;
        }
        if (update && t != null && t.modified.isAfter(e.modified.add(const Duration(seconds: 2)))) continue;
        if (t != null && t.isDir) await vDelete(target);
        await _copyFileV(e.path, target, e.size, e.modified, null);
        n++;
      }
      if (delete) {
        for (final name in there.keys) {
          if (!names.contains(name) && !name.endsWith('.jjsync')) await vDelete(vJoin(dst, name));
        }
      }
    }

    await walk(srcDir, dstDir);
    return n;
  }
}

/// [root] 아래에서 이름에 [query] 가 들어간 항목 찾기 (대소문자 무시, * ? 사용 가능). 찾는 대로 내보낸다.
Stream<FileEntry> searchFiles(String root, String query, {bool showHidden = false, int limit = 2000}) async* {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return;
  final wild = q.contains('*') || q.contains('?');
  final re = wild
      ? RegExp('^${RegExp.escape(q).replaceAll(r'\*', '.*').replaceAll(r'\?', '.')}\$')
      : null;
  var n = 0;
  final pending = <String>[root];
  while (pending.isNotEmpty) {
    final dir = pending.removeAt(0);
    List<FileEntry> items;
    try {
      items = await listEntries(dir, showHidden: showHidden);
    } catch (_) {
      continue;
    }
    for (final e in sortEntries(items, SortBy.name)) {
      final name = e.name.toLowerCase();
      if (re != null ? re.hasMatch(name) : name.contains(q)) {
        yield e;
        if (++n >= limit) return;
      }
      if (e.isDir) pending.add(e.path);
    }
  }
}

/// "1.2GB" · "350MB" · "12KB"
String formatSize(int bytes) {
  const k = 1024;
  if (bytes >= k * k * k) return '${(bytes / (k * k * k)).toStringAsFixed(1)}GB';
  if (bytes >= k * k) return '${(bytes / (k * k)).toStringAsFixed(bytes < 10 * k * k ? 1 : 0)}MB';
  if (bytes >= k) return '${(bytes / k).round()}KB';
  return '${bytes}B';
}
