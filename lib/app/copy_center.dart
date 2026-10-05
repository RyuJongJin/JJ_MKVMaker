import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../core/file_ops.dart';
import '../core/sync_tools.dart';
import '../l10n/tr.dart';
import '../platform/windows/windows_usage.dart';
import 'app_controller.dart';
import 'live_sync.dart';
import 'settings.dart';
import 'transfer_job.dart';

/// 복사 · 이동 모니터링 (파일 탐색기 > 모니터링 > 복사 · rsync):
/// 복사한 원본 → 대상을 기억 (설정의 copyTasks) 해 진행 · 결과를 보여 주고, 옵션을 고쳐 다시 실행하고,
/// 실시간 동기화 (lsync) 로 옮기거나 lsync 에서 가져온다.
class CopyCenter extends ChangeNotifier {
  final AppController c;
  CopyCenter(this.c);

  static CopyCenter? _instance;
  static CopyCenter of(AppController c) => _instance != null && _instance!.c == c ? _instance! : (_instance = CopyCenter(c));

  /// 작업 id → 지금 (또는 마지막) 실행
  final jobs = <String, TransferJob>{};

  List<CopyTask> get tasks => c.settings.copyTasks;

  bool isRunning(String id) => jobs[id] != null && !jobs[id]!.finished;
  bool get anyRunning => jobs.values.any((j) => !j.finished);

  /// 새 작업: 지금 설정의 방법 · 옵션으로
  CopyTask fresh(List<String> sources, String dest, {bool move = false, bool contents = false, String? method}) {
    final s = c.settings;
    final hasDir = sources.any(FileSystemEntity.isDirectorySync);
    var m = CopyMethod.of(method ?? (hasDir ? s.copyMethodFolder : s.copyMethodFile));
    if (!copyMethodAvailable(m, s)) m = CopyMethod.builtin;
    return CopyTask(
      id: '${DateTime.now().microsecondsSinceEpoch}',
      sources: sources,
      dest: dest,
      move: move,
      contents: contents,
      method: m.name,
      options: m == CopyMethod.robocopy ? s.robocopyOptions : s.rsyncOptions,
      once: s.copyRunMode == 'once',
      bandwidthKBps: s.copyBandwidthKBps,
    );
  }

  /// 같은 복사를 기억해 두었으면 그것 (그 옵션을 쓴다), 없으면 새로 기억
  Future<CopyTask> remember(List<String> sources, String dest, {bool move = false}) async {
    final t = fresh(sources, dest, move: move);
    final old = tasks.where((x) => x.key == t.key).firstOrNull;
    if (old != null) return old;
    await c.updateSettings((x) => x.copyTasks = [t, ...x.copyTasks]);
    notifyListeners();
    return t;
  }

  Future<void> update(CopyTask t) async {
    await c.updateSettings((x) => x.copyTasks = [for (final y in x.copyTasks) y.id == t.id ? t : y]);
    notifyListeners();
  }

  Future<void> remove(String id) async {
    cancel(id);
    jobs.remove(id);
    await c.updateSettings((x) => x.copyTasks = [for (final y in x.copyTasks) if (y.id != id) y]);
    notifyListeners();
  }

  void cancel(String id) => jobs[id]?.cancel();

  /// 실행을 시작하고 그 작업을 바로 돌려준다 (rsync 가 없으면 null). 끝나면 결과를 기억한다 ([TransferJob.done]).
  Future<TransferJob?> start(CopyTask t, {String? rsyncExe}) async {
    if (isRunning(t.id)) return jobs[t.id];
    final method = CopyMethod.of(t.method);
    final exe = method == CopyMethod.rsync ? (rsyncExe ?? await rsyncExecutable(c.settings)) : null;
    if (method == CopyMethod.rsync && exe == null) return null;
    final job = TransferJob(
      sources: t.sources,
      dest: t.dest,
      move: t.move,
      method: method,
      options: t.options,
      once: t.once,
      bandwidthKBps: t.bandwidthKBps,
      rsyncExe: exe,
      contents: t.contents,
    );
    jobs[t.id] = job;
    job.addListener(notifyListeners);
    notifyListeners();
    unawaited(_runAndRecord(t, job, method));
    return job;
  }

  Future<void> _runAndRecord(CopyTask t, TransferJob job, CopyMethod method) async {
    await job.run();
    final e = job.error;
    final cur = tasks.where((x) => x.id == t.id).firstOrNull;
    if (cur != null) {
      await update(cur.copyWith(
        lastRun: DateTime.now().toIso8601String(),
        lastResult: e == null ? 'done' : e is FileOpCancelled ? 'cancelled' : 'failed',
        lastMessage: e == null ? '' : '$e',
        lastFiles: job.allDone,
      ));
    }
    c.note(e == null
        ? trf('복사 끝 ({0}): {1}개 → {2}', [method.label, t.sources.length, t.dest])
        : trf('복사 실패 ({0}): {1}', [method.label, e]));
    notifyListeners();
  }

  /// lsync 로 옮기기: 원본 폴더마다 (원본 → 대상\이름) 실시간 동기화 쌍. 파일 원본은 넣을 수 없어 남긴다.
  Future<int> toLiveSync(CopyTask t) async {
    final dirs = t.sources.where(FileSystemEntity.isDirectorySync).toList();
    if (dirs.isEmpty) return 0;
    final pairs = [
      for (final d in dirs) LiveSyncPair(d, t.contents ? t.dest : p.join(t.dest, p.basename(d)), method: t.method),
    ];
    final rest = t.sources.where((s) => !dirs.contains(s)).toList();
    await c.updateSettings((x) => x
      ..liveSyncPairs = [
        ...x.liveSyncPairs,
        for (final n in pairs)
          if (!x.liveSyncPairs.any((o) => o.source == n.source && o.target == n.target)) n,
      ]
      ..copyTasks = [
        for (final y in x.copyTasks)
          if (y.id != t.id)
            y
          else if (rest.isNotEmpty)
            CopyTask(id: y.id, sources: rest, dest: y.dest, method: y.method, options: y.options, bandwidthKBps: y.bandwidthKBps),
      ]);
    notifyListeners();
    return pairs.length;
  }

  /// lsync 에서 빼서 복사 목록으로 (rsync 로, 원본 "안의 것" → 대상)
  Future<CopyTask> fromLiveSync(LiveSyncPair x) async {
    final s = c.settings;
    final m = copyMethodAvailable(CopyMethod.rsync, s) ? 'rsync' : x.method;
    final t = fresh([x.source], x.target, contents: true, method: m);
    await c.updateSettings((y) => y
      ..liveSyncPairs = [for (final o in y.liveSyncPairs) if (!(o.source == x.source && o.target == x.target)) o]
      ..copyTasks = [t, ...y.copyTasks]);
    notifyListeners();
    return t;
  }
}

/// 디스크 남은 용량 · 전체 용량 (바이트). 알 수 없으면 null.
Future<(int, int)?> diskSpace(String path) async {
  try {
    if (Platform.isWindows) return WindowsUsage().disk(path);
    if (Platform.isAndroid) {
      final r = await const MethodChannel('jj_mkvmaker/android').invokeMethod<List<Object?>>('diskSpace', {'path': path});
      if (r != null && r.length == 2) return ((r[0] as num).toInt(), (r[1] as num).toInt());
    }
  } catch (_) {}
  return null;
}
