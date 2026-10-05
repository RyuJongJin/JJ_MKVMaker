import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'playlist.dart' show naturalCompare;

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
  final x = p.normalize(p.absolute(a)), y = p.normalize(p.absolute(b));
  return Platform.isWindows ? x.toLowerCase() == y.toLowerCase() : x == y;
}

/// [a] 가 [b] 와 같거나 그 안에 있는지 (폴더를 자기 안으로 복사 · 이동하지 않게)
bool isSameOrInside(String a, String b) {
  final x = p.normalize(p.absolute(a)), y = p.normalize(p.absolute(b));
  return samePath(a, b) || p.isWithin(y, x) || (Platform.isWindows && p.isWithin(y.toLowerCase(), x.toLowerCase()));
}

/// 복사 · 이동 중 알림 (지금 파일, 지금까지 바이트, 전체 바이트)
typedef CopyProgress = void Function(String current, int done, int total);

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

  FileOps({this.bandwidthKBps = 0, this.onFileDone});

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
  Future<int> mirror(String srcDir, String dstDir, {bool delete = false}) async {
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
          final same = await t.exists() &&
              (await t.length()) == st.size &&
              ((await t.lastModified()).difference(st.modified).inSeconds.abs() <= 2);
          if (same) continue;
          final tmp = '$target.jjsync';
          final out = File(tmp).openWrite();
          try {
            await for (final chunk in e.openRead()) {
              _check();
              out.add(chunk);
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
    final target = p.join(dir, n);
    if (FileSystemEntity.typeSync(target) != FileSystemEntityType.notFound) {
      throw FileSystemException('같은 이름이 이미 있습니다', target);
    }
    return (await Directory(target).create()).path;
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
