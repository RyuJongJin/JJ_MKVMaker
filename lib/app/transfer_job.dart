import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../core/file_ops.dart';
import '../core/sync_tools.dart';

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
  });

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

  static Future<int> countFiles(String path) async {
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
        if (FileSystemEntity.isDirectorySync(s) && isSameOrInside(dest, s)) {
          throw FileSystemException('폴더를 자기 안으로 복사 · 이동할 수 없습니다', s);
        }
        filesTotal[i] = await countFiles(s);
      }
      counting = false;
      _tick();
      switch (method) {
        case CopyMethod.builtin:
          await _runBuiltin();
        case CopyMethod.rsync:
          await _runRsync();
        case CopyMethod.robocopy:
          await _runRobocopy();
      }
      if (cancelled) throw const FileOpCancelled();
    } catch (e) {
      error = cancelled ? const FileOpCancelled() : e;
    } finally {
      finished = true;
      _tick();
      if (!_done.isCompleted) _done.complete();
    }
  }

  Future<void> _runBuiltin() async {
    for (index = 0; index < sources.length; index++) {
      if (cancelled) return;
      final i = index;
      _ops = FileOps(bandwidthKBps: bandwidthKBps, onFileDone: (_) {
        filesDone[i]++;
        _tick();
      });
      _tick();
      if (contents && FileSystemEntity.isDirectorySync(sources[i])) {
        await _ops!.mirror(sources[i], dest);
        made.add(dest);
      } else {
        final r = move ? await _ops!.move([sources[i]], dest) : await _ops!.copy([sources[i]], dest);
        made.addAll(r);
      }
      filesDone[i] = filesTotal[i]; // 이름 바꾸기로 옮긴 경우
    }
    index = sources.length;
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
            // 출력 경로의 첫 부분 = 원본 이름 → 어느 항목인지 (안의 것 모드는 이름이 없어 지금 항목)
            final first = f.split('/').first;
            var k = contents ? -1 : idx.indexWhere((i) => p.basename(sources[i]) == first);
            if (k < 0) k = names.indexOf(f);
            final at = k < 0 ? index : idx[k];
            if (at > index) index = at;
            filesDone[at]++;
          }
          filePercent = out.currentPercent;
          _tick();
        },
      );
      if (cancelled) return;
      if (!rsyncOk(code)) throw ProcessException(exe, const [], 'rsync 종료 코드 $code\n${log.take(8).join('\n')}', code);
      for (final i in idx) {
        filesDone[i] = filesTotal[i];
        made.add(p.join(dest, p.basename(sources[i])));
        // 이동: rsync 는 파일만 지우므로 빈 폴더를 정리
        if (move && FileSystemEntity.isDirectorySync(sources[i]) && await countFiles(sources[i]) == 0) {
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
