import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../core/file_ops.dart';
import '../core/sync_tools.dart';
import '../core/vfs.dart';

/// 복사 · 이동 한 번 (파일 탐색기). 방법 (현재 방식 · rsync · robocopy) 과 상관없이 같은 진행 상태를 알린다:
/// - 위쪽: 고른 항목 (폴더) 중 몇 번째인지 · 전체 진행률
/// - 아래쪽: 지금 항목 (폴더) 의 파일 중 몇 개를 했는지
class TransferJob extends ChangeNotifier {
  final List<String> sources;
  final String dest;
  final bool move;
  final CopyMethod method;

  /// rsync · robocopy 옵션 글자
  final String options;

  /// 여러 항목을 rsync 한 번으로 (false 면 항목마다 따로)
  final bool once;
  final int bandwidthKBps;

  /// rsync 실행 파일 (rsync 방법일 때)
  final String? rsyncExe;

  /// 폴더 "안의 것" 을 [dest] 에 맞추기 (rsync 원본/ → 대상/, 현재 방식은 바뀐 것만). lsync 에서 옮겨 온 복사.
  final bool contents;

  /// 이동 뒤 원본 정리: '' 안 함 · 'keep' 빈 폴더 지움 (원본 폴더는 남김) · 'all' 원본 폴더까지
  final String prune;

  TransferJob({
    required this.sources,
    required this.dest,
    required this.move,
    this.method = CopyMethod.builtin,
    this.options = '',
    this.once = false,
    this.bandwidthKBps = 0,
    this.rsyncExe,
    this.contents = false,
    this.prune = '',
  });

  /// 지금 복사하는 파일 (원본 기준 상대 경로, rsync 는 이름을 먼저 알리고 그 파일의 진행률을 알린다)
  String currentFile = '';

  /// 지금 전송 속도 (바이트/초, 모르면 null): rsync 는 -P 가 알려 주는 값, 현재 방식은 최근 3초 동안 복사한 양
  double? speed;
  int _bytes = 0;
  final _samples = <(DateTime, int)>[];

  void _addBytes(int n) {
    final now = DateTime.now();
    _bytes += n;
    _samples
      ..add((now, _bytes))
      ..removeWhere((x) => now.difference(x.$1).inMilliseconds > 3000);
    if (_samples.length >= 2) {
      final ms = now.difference(_samples.first.$1).inMilliseconds;
      if (ms > 0) speed = (_bytes - _samples.first.$2) * 1000 / ms;
    }
  }

  /// 원본 정리 중 · 지운 빈 폴더 수
  bool pruning = false;
  int pruned = 0;

  // ── 진행 상태 ──
  int index = 0; // 지금 항목
  int get total => sources.length;
  String get currentName => index < sources.length ? p.basename(sources[index]) : '';
  late final List<int> filesTotal = List.filled(sources.length, 0);
  late final List<int> filesDone = List.filled(sources.length, 0);

  /// 지금 파일의 진행률 (rsync -P · robocopy 가 알려 줄 때)
  double? filePercent;
  bool counting = true;
  bool finished = false;
  Object? error;
  bool cancelled = false;
  final made = <String>[];

  /// 마지막 출력 몇 줄 (실패했을 때 보여 줌)
  final log = <String>[];

  /// rsync 가 알려 주는 폴더 전체 확인 (to-chk) - 바뀐 파일만 이름이 나오므로 파일 수보다 정확하다. 모르면 0.
  int checked = 0, checkTotal = 0;

  /// 폴더 전체 진행률 (rsync 는 to-chk, 그 밖은 [overall])
  double get folderProgress {
    if (finished) return 1;
    if (checkTotal > 0) return (checked / checkTotal).clamp(0.0, 1.0);
    return overall;
  }

  int get allFiles => filesTotal.fold(0, (a, b) => a + b);
  int get allDone => filesDone.fold(0, (a, b) => a + b);

  /// 위쪽 진행률: 끝낸 항목 + 지금 항목의 파일 진행
  double get overall {
    if (finished) return 1;
    if (total == 0) return 0;
    final cur = index < total && filesTotal[index] > 0 ? (filesDone[index] / filesTotal[index]).clamp(0.0, 1.0) : 0.0;
    return ((index + cur) / total).clamp(0.0, 1.0);
  }

  /// 아래쪽 진행률: 지금 항목의 파일
  double get current {
    if (finished) return 1;
    if (index >= total || filesTotal[index] == 0) return 0;
    return (filesDone[index] / filesTotal[index]).clamp(0.0, 1.0);
  }

  Process? _proc;
  FileOps? _ops;

  final _done = Completer<void>();

  /// 끝날 때 (성공 · 실패 · 취소)
  Future<void> get done => _done.future;

  void cancel() {
    cancelled = true;
    _ops?.cancel();
    _proc?.kill();
    notifyListeners();
  }

  void _tick() => notifyListeners();

  /// 한쪽이라도 WebDAV 면 rsync · robocopy 대신 앱이 직접 (크기 · 시각 비교) 맞춘다
  bool get viaWebDav => isDav(dest) || sources.any(isDav);

  /// rsync -u (--update) 를 옵션에 넣었는지 (앱이 맞출 때도 같은 뜻으로: 대상이 더 새것이면 건너뜀)
  bool get _update => splitOptions(options).any((o) => o == '--update' || (o.startsWith('-') && !o.startsWith('--') && o.contains('u')));

  static Future<int> countFiles(String path) async {
    if (isDav(path)) return vCountFiles(path);
    if (!FileSystemEntity.isDirectorySync(path)) return 1;
    var n = 0;
    await for (final e in Directory(path).list(recursive: true, followLinks: false).handleError((_) {})) {
      if (e is File) n++;
    }
    return n;
  }

  Future<void> run() async {
    try {
      for (var i = 0; i < sources.length; i++) {
        final s = sources[i];
        if ((isDav(s) || FileSystemEntity.isDirectorySync(s)) && isSameOrInside(dest, s)) {
          throw FileSystemException('폴더를 자기 안으로 복사 · 이동할 수 없습니다', s);
        }
        filesTotal[i] = await countFiles(s);
      }
      counting = false;
      _tick();
      switch (viaWebDav ? CopyMethod.builtin : method) {
        case CopyMethod.builtin:
          await _runBuiltin();
        case CopyMethod.rsync:
          await _runRsync();
        case CopyMethod.robocopy:
          await _runRobocopy();
      }
      if (cancelled) throw const FileOpCancelled();
      // 옮긴 뒤 원본에 남은 빈 폴더 정리 (find 원본/ -type d -empty -delete)
      if (move && prune.isNotEmpty) {
        pruning = true;
        _tick();
        for (final s in sources) {
          if (isDav(s) || FileSystemEntity.isDirectorySync(s)) pruned += await removeEmptyDirs(s, keepRoot: prune == 'keep');
        }
      }
    } catch (e) {
      error = cancelled ? const FileOpCancelled() : e;
    } finally {
      finished = true;
      speed = null;
      _tick();
      if (!_done.isCompleted) _done.complete();
    }
  }

  Future<void> _runBuiltin() async {
    for (index = 0; index < sources.length; index++) {
      if (cancelled) return;
      final i = index;
      _ops = FileOps(
        bandwidthKBps: bandwidthKBps,
        onFileDone: (src) {
          filesDone[i]++;
          currentFile = vBasename(src);
          _tick();
        },
        // 보낸 양으로 전송 속도 (WebDAV 포함)
        onBytes: _addBytes,
      );
      _tick();
      if (contents && (isDav(sources[i]) || FileSystemEntity.isDirectorySync(sources[i]))) {
        // 폴더 "안의 것" 맞추기 (rsync 원본/ 대상/ 과 같은 뜻): -u · 원본 파일 지우기 (--remove-source-files) 도
        await _ops!.mirror(sources[i], dest, update: _update);
        if (move && !cancelled) await _deleteFilesIn(sources[i]);
        made.add(dest);
      } else {
        final r = move ? await _ops!.move([sources[i]], dest) : await _ops!.copy([sources[i]], dest);
        made.addAll(r);
      }
      filesDone[i] = filesTotal[i]; // 이름 바꾸기로 옮긴 경우
    }
    index = sources.length;
  }

  /// 맞춘 뒤 원본의 파일만 지운다 (rsync --remove-source-files 처럼, 빈 폴더는 [prune] 이 정리)
  Future<void> _deleteFilesIn(String dir) async {
    for (final e in await vList(dir)) {
      if (cancelled) return;
      if (e.isDir) {
        await _deleteFilesIn(e.path);
      } else {
        await vDelete(e.path);
      }
    }
  }

  void _addLog(String line) {
    if (line.trim().isEmpty) return;
    log.add(line.trim());
    if (log.length > 20) log.removeAt(0);
  }

  Future<int> _start(String exe, List<String> args, Encoding enc, void Function(String chunk) onOut) async {
    _proc = await Process.start(exe, args, runInShell: false);
    final a = _proc!.stdout.transform(enc.decoder).listen(onOut);
    final b = _proc!.stderr.transform(enc.decoder).listen((t) {
      for (final l in t.split(RegExp(r'[\r\n]'))) {
        _addLog(l);
      }
    });
    final code = await _proc!.exitCode;
    await a.cancel();
    await b.cancel();
    _proc = null;
    return code;
  }

  Future<void> _runRsync() async {
    final exe = rsyncExe;
    if (exe == null || exe.isEmpty) throw StateError('rsync 실행 파일이 없습니다');
    final windows = Platform.isWindows;
    Future<void> one(List<int> idx) async {
      final out = RsyncOutput();
      final names = [for (final i in idx) p.basename(sources[i])];
      final code = await _start(
        exe,
        rsyncArgs(
            options: options,
            sources: [for (final i in idx) sources[i]],
            dest: dest,
            bandwidthKBps: bandwidthKBps,
            move: move,
            windows: windows,
            contents: contents),
        utf8,
        (chunk) {
          for (final f in out.feed(chunk)) {
            _addLog(f);
            currentFile = f;
            // 출력 경로의 첫 부분 = 원본 이름 → 어느 항목인지 (안의 것 모드는 이름이 없어 지금 항목)
            final first = f.split('/').first;
            var k = contents ? -1 : idx.indexWhere((i) => p.basename(sources[i]) == first);
            if (k < 0) k = names.indexOf(f);
            final at = k < 0 ? index : idx[k];
            if (at > index) index = at;
            filesDone[at]++;
          }
          filePercent = out.currentPercent;
          speed = out.currentSpeed ?? speed;
          if (out.checkTotal != null) {
            checkTotal = out.checkTotal!;
            checked = out.checked!;
          }
          _tick();
        },
      );
      if (cancelled) return;
      if (!rsyncOk(code)) throw ProcessException(exe, const [], 'rsync 종료 코드 $code\n${log.take(8).join('\n')}', code);
      for (final i in idx) {
        filesDone[i] = filesTotal[i];
        made.add(p.join(dest, p.basename(sources[i])));
        // 폴더째 이동 (안의 것 [contents] 이 아니고 원본 정리 [prune] 를 고르지 않음): rsync 는 파일만 지우므로
        // 비어 남은 원본 폴더를 지운다. 원본 정리를 고른 이동은 끝에서 그 고른 대로 ([prune]).
        if (move && !contents && prune.isEmpty && FileSystemEntity.isDirectorySync(sources[i]) && await countFiles(sources[i]) == 0) {
          await Directory(sources[i]).delete(recursive: true);
        }
      }
    }

    if (once) {
      index = 0;
      await one([for (var i = 0; i < sources.length; i++) i]);
    } else {
      for (index = 0; index < sources.length; index++) {
        if (cancelled) return;
        _tick();
        await one([index]);
      }
    }
    index = sources.length;
  }

  Future<void> _runRobocopy() async {
    // robocopy 는 폴더마다 (파일은 같은 폴더끼리) 한 번씩
    for (index = 0; index < sources.length; index++) {
      if (cancelled) return;
      final s = sources[index];
      final dir = FileSystemEntity.isDirectorySync(s);
      final runs = robocopyRuns(
        options: options,
        folders: dir ? [s] : const [],
        files: dir ? const [] : [s],
        dest: dest,
        bandwidthKBps: bandwidthKBps,
        move: move,
        contents: contents,
      );
      _tick();
      for (final args in runs) {
        final out = RobocopyOutput();
        final i = index;
        final code = await _start(
          'robocopy',
          [...args, '/BYTES', '/NJH', '/NJS', '/NDL', '/FP'],
          systemEncoding,
          (chunk) {
            for (final f in out.feed(chunk)) {
              _addLog(f);
              filesDone[i]++;
            }
            filePercent = out.currentPercent;
            _tick();
          },
        );
        if (cancelled) return;
        if (!robocopyOk(code)) throw ProcessException('robocopy', const [], 'robocopy 종료 코드 $code', code);
      }
      filesDone[index] = filesTotal[index];
      made.add(p.join(dest, p.basename(s)));
    }
    index = sources.length;
  }
}
