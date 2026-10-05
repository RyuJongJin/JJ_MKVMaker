import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../core/file_ops.dart';
import '../core/sync_tools.dart';
import '../l10n/tr.dart';
import '../platform/windows/rsync_installer.dart';
import 'app_controller.dart';
import 'settings.dart';

/// 지금 설정으로 쓸 rsync 실행 파일 (없으면 null).
/// - 직접 지정: 그 파일
/// - 처음 쓸 때 내려받기 (Windows): 내려받아 둔 것
Future<String?> rsyncExecutable(AppSettings s) async {
  if (s.rsyncSource == 'custom') {
    return s.rsyncPath.isNotEmpty && File(s.rsyncPath).existsSync() ? s.rsyncPath : null;
  }
  if (!Platform.isWindows) return null;
  return RsyncInstaller.installedPath();
}

/// 이 기기에서 쓸 수 있는 방법
bool copyMethodAvailable(CopyMethod m, AppSettings s) => switch (m) {
      CopyMethod.builtin => true,
      CopyMethod.robocopy => Platform.isWindows,
      CopyMethod.rsync => Platform.isWindows || s.rsyncSource == 'custom',
    };

/// 실시간 동기화 (lsyncd 처럼): 설정의 폴더 쌍마다 원본을 지켜보다가 바뀌면 대상에 맞춘다.
/// Windows 는 폴더 감시로 바로 (모아서 3초 뒤), 그 밖은 [AppSettings.liveSyncIntervalSec] 마다 살핀다.
/// 앱이 켜져 있는 동안만 동작하고, 시작할 때 한 번 맞춘다.
class LiveSync extends ChangeNotifier {
  final AppController c;
  LiveSync(this.c);

  static LiveSync? instance;

  final _watch = <String, StreamSubscription<FileSystemEvent>>{};
  final _timers = <String, Timer>{};
  final _pending = <String, Timer>{};
  final _running = <String>{};

  /// 쌍마다 마지막 결과 (화면 표시용): (시각, 글)
  final status = <String, (DateTime, String)>{};

  String _sig = '';

  void start() {
    instance = this;
    c.addListener(_apply);
    _apply();
  }

  @override
  void dispose() {
    c.removeListener(_apply);
    _stopAll();
    if (instance == this) instance = null;
    super.dispose();
  }

  static String keyOf(LiveSyncPair x) => '${x.source}=>${x.target}';

  void _stopAll() {
    for (final s in _watch.values) {
      s.cancel();
    }
    for (final t in [..._timers.values, ..._pending.values]) {
      t.cancel();
    }
    _watch.clear();
    _timers.clear();
    _pending.clear();
  }

  /// 설정이 바뀌면 감시를 다시 꾸린다
  void _apply() {
    final s = c.settings;
    final pairs = s.liveSyncPairs.where((x) => x.enabled).toList();
    final sig = jsonEncode([for (final x in pairs) x.toJson(), s.liveSyncIntervalSec]);
    if (sig == _sig) return;
    _sig = sig;
    _stopAll();
    for (final x in pairs) {
      final k = keyOf(x);
      if (!Directory(x.source).existsSync()) {
        status[k] = (DateTime.now(), tr('원본 폴더가 없습니다'));
        continue;
      }
      // 대상이 원본 안이면 맞출 때마다 원본이 바뀌어 끝없이 돈다
      if (isSameOrInside(x.target, x.source) || isSameOrInside(x.source, x.target)) {
        status[k] = (DateTime.now(), tr('원본과 대상이 서로 안에 있습니다'));
        continue;
      }
      if (Platform.isWindows) {
        try {
          _watch[k] = Directory(x.source).watch(recursive: true).listen((_) => _schedule(x));
        } catch (_) {
          _timers[k] = Timer.periodic(Duration(seconds: s.liveSyncIntervalSec), (_) => _schedule(x));
        }
      } else {
        // Android 등: 폴더 안쪽까지 감시가 안 되므로 정해진 간격으로 살핀다
        _timers[k] = Timer.periodic(Duration(seconds: s.liveSyncIntervalSec), (_) => _schedule(x));
      }
      _schedule(x); // 시작할 때 한 번
    }
    notifyListeners();
  }

  void _schedule(LiveSyncPair x) {
    final k = keyOf(x);
    _pending[k]?.cancel();
    _pending[k] = Timer(const Duration(seconds: 3), () => syncNow(x));
  }

  bool isRunning(LiveSyncPair x) => _running.contains(keyOf(x));

  /// 지금 맞추기 (원본 내용 → 대상)
  Future<void> syncNow(LiveSyncPair x) async {
    final k = keyOf(x);
    if (_running.contains(k)) {
      _schedule(x); // 도는 중에 바뀐 것은 끝난 뒤 다시
      return;
    }
    _running.add(k);
    notifyListeners();
    final s = c.settings;
    try {
      final method = CopyMethod.of(x.method);
      final n = switch (method) {
        CopyMethod.builtin => await FileOps(bandwidthKBps: s.copyBandwidthKBps).mirror(x.source, x.target, delete: x.delete),
        CopyMethod.rsync => await _rsync(x, s),
        CopyMethod.robocopy => await _robocopy(x, s),
      };
      status[k] = (DateTime.now(), n < 0 ? tr('맞춤') : trf('{0}개 맞춤', [n]));
      if (n != 0) c.note(trf('실시간 동기화 ({0}): {1} → {2}', [method.label, x.source, x.target]));
    } catch (e) {
      status[k] = (DateTime.now(), trf('실패: {0}', [e]));
      c.note(trf('실시간 동기화 실패: {0} → {1}: {2}', [x.source, x.target, e]));
    } finally {
      _running.remove(k);
      notifyListeners();
    }
  }

  /// rsync: 원본 "내용" 을 대상으로 (끝에 / ), 지우기는 --delete. 보낸 파일 수 (모르면 -1)
  Future<int> _rsync(LiveSyncPair x, AppSettings s) async {
    final exe = await rsyncExecutable(s);
    if (exe == null) throw StateError(tr('rsync 가 없습니다 (환경 설정 > 파일 탐색기에서 내려받기 · 경로 지정)'));
    final win = Platform.isWindows;
    final args = [
      ...splitOptions(s.rsyncOptions).where((o) => o != '-P' && o != '--progress'),
      if (s.copyBandwidthKBps > 0) '--bwlimit=${s.copyBandwidthKBps}',
      if (x.delete) '--delete',
      '${toCygwinPath(x.source, windows: win)}/',
      '${toCygwinPath(x.target, windows: win)}/',
    ];
    await Directory(x.target).create(recursive: true);
    final r = await Process.run(exe, args, stdoutEncoding: utf8, stderrEncoding: utf8);
    if (!rsyncOk(r.exitCode)) throw ProcessException(exe, const [], '${r.stderr}'.trim(), r.exitCode);
    return RsyncOutput().feed('${r.stdout}\n').length;
  }

  Future<int> _robocopy(LiveSyncPair x, AppSettings s) async {
    final opts = splitOptions(s.robocopyOptions);
    final r = await Process.run('robocopy', [
      x.source,
      x.target,
      ...opts,
      if (!opts.any((o) => o.toUpperCase() == '/E' || o.toUpperCase() == '/MIR')) '/E',
      if (x.delete) '/PURGE',
      if (s.copyBandwidthKBps > 0) '/IPG:${robocopyIpg(s.copyBandwidthKBps)}',
      '/BYTES', '/NJH', '/NJS', '/NDL', '/NP',
    ]);
    if (!robocopyOk(r.exitCode)) throw ProcessException('robocopy', const [], '${r.stdout}'.trim(), r.exitCode);
    return RobocopyOutput().feed('${r.stdout}\n').length;
  }
}
