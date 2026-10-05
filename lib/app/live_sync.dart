import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'package:path/path.dart' as p;

import '../core/cron_window.dart';
import '../core/file_ops.dart';
import '../core/sync_tools.dart';
import '../l10n/tr.dart';
import '../platform/windows/rsync_installer.dart';
import 'app_controller.dart';
import 'settings.dart';

/// 앱에 들어 있는 rsync (없으면 null). 시작할 때 [findBundledRsync] 로 정한다.
/// - Windows: 실행 파일 옆 rsync/rsync.exe (tool/fetch_rsync.ps1 로 준비해 빌드에 넣음)
/// - Android: 네이티브 라이브러리 폴더의 librsync.so (tool/build_rsync_android.sh, APK 의 jniLibs)
String? bundledRsync;

Future<void> findBundledRsync() async {
  String? path;
  if (Platform.isWindows) {
    path = p.join(p.dirname(Platform.resolvedExecutable), 'rsync', 'rsync.exe');
  } else if (Platform.isAndroid) {
    try {
      final dir = await const MethodChannel('jj_mkvmaker/android').invokeMethod<String>('nativeLibDir');
      if (dir != null) path = p.join(dir, 'librsync.so');
    } catch (_) {}
  }
  bundledRsync = path != null && File(path).existsSync() ? path : null;
}

/// 지금 설정으로 쓸 rsync 실행 파일 (없으면 null).
/// - 직접 지정: 그 파일
/// - 기본: 앱에 들어 있는 것, 없으면 (Windows) 내려받아 둔 것
Future<String?> rsyncExecutable(AppSettings s) async {
  if (s.rsyncSource == 'custom') {
    return s.rsyncPath.isNotEmpty && File(s.rsyncPath).existsSync() ? s.rsyncPath : null;
  }
  final b = bundledRsync;
  if (b != null && File(b).existsSync()) return b;
  if (!Platform.isWindows) return null;
  return RsyncInstaller.installedPath();
}

/// 이 기기에서 쓸 수 있는 방법
bool copyMethodAvailable(CopyMethod m, AppSettings s) => switch (m) {
      CopyMethod.builtin => true,
      CopyMethod.robocopy => Platform.isWindows,
      CopyMethod.rsync => Platform.isWindows || s.rsyncSource == 'custom' || bundledRsync != null,
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

  /// 쌍마다 아직 맞추지 않은 것 (원본 기준 상대 경로, 지울 것은 "− " 를 앞에). 바뀌면 자동으로 다시 센다.
  final pending = <String, List<String>>{};

  String _sig = '';

  /// 1분마다: 동작 시간 (cron) 이 시작되면 밀린 것을 맞춘다
  Timer? _clock;

  /// 이번 실행 동안 멈춘 쌍 (설정의 켜기 · 끄기와 따로, 앱을 다시 켜면 [AppSettings.liveSyncOnStart] 를 따른다)
  final paused = <String>{};

  /// [hold] 면 켜진 쌍을 모두 멈춘 채로 시작 (모니터링 · [resume] 으로 시작)
  void start({bool hold = false}) {
    instance = this;
    if (hold) paused.addAll(c.settings.liveSyncPairs.where((x) => x.enabled).map(keyOf));
    c.addListener(_apply);
    _apply();
    _clock ??= Timer.periodic(const Duration(minutes: 1), (_) => _onClock());
  }

  @override
  void dispose() {
    c.removeListener(_apply);
    _clock?.cancel();
    _stopAll();
    if (instance == this) instance = null;
    super.dispose();
  }

  /// 지금 동작 시간인지 (일정이 없으면 늘)
  static bool activeNow(LiveSyncPair x, [DateTime? now]) => scheduleActive(x.schedule, now ?? DateTime.now());

  bool isPaused(LiveSyncPair x) => paused.contains(keyOf(x));

  /// 지금 지켜보는 쌍 (켜져 있고 멈추지 않은 것)
  List<LiveSyncPair> get watching => [
        for (final x in c.settings.liveSyncPairs)
          if (x.enabled && !paused.contains(keyOf(x))) x,
      ];

  void pause(LiveSyncPair x) => _setPaused({...paused, keyOf(x)});
  void resume(LiveSyncPair x) => _setPaused({...paused}..remove(keyOf(x)));
  void pauseAll() => _setPaused({...paused, ...c.settings.liveSyncPairs.map(keyOf)});
  void resumeAll() => _setPaused({});

  /// 시작할 때 고른 쌍만 (나머지는 멈춤)
  void runOnly(Iterable<LiveSyncPair> xs) {
    final keep = xs.map(keyOf).toSet();
    _setPaused({for (final x in c.settings.liveSyncPairs) if (!keep.contains(keyOf(x))) keyOf(x)});
  }

  void _setPaused(Set<String> v) {
    paused
      ..clear()
      ..addAll(v);
    _apply();
    notifyListeners();
  }

  void _onClock() {
    for (final x in watching) {
      if (activeNow(x) && (pending[keyOf(x)]?.isNotEmpty ?? false)) _schedule(x);
    }
    notifyListeners(); // 남은 시간 표시
  }

  /// 원본과 대상의 다른 점 (크기 · 바뀐 시각). [x.delete] 면 원본에 없는 대상 항목도 "− 이름" 으로.
  static Future<List<String>> diff(LiveSyncPair x, {int limit = 500}) async {
    final out = <String>[];
    Future<void> walk(String src, String dst, String rel) async {
      if (out.length >= limit) return;
      final names = <String>{};
      await for (final e in Directory(src).list(followLinks: false).handleError((_) {})) {
        if (out.length >= limit) return;
        final name = p.basename(e.path);
        names.add(name);
        final r = rel.isEmpty ? name : '$rel/$name';
        final t = p.join(dst, name);
        if (e is Directory) {
          await walk(e.path, t, r);
        } else if (e is File) {
          final st = await e.stat();
          final tf = File(t);
          if (!await tf.exists()) {
            out.add(r);
            continue;
          }
          final ts = await tf.stat();
          if (ts.size != st.size || ts.modified.difference(st.modified).inSeconds.abs() > 2) out.add(r);
        }
      }
      if (x.delete && await Directory(dst).exists()) {
        await for (final e in Directory(dst).list(followLinks: false).handleError((_) {})) {
          final name = p.basename(e.path);
          if (!names.contains(name) && !name.endsWith('.jjsync')) out.add('− ${rel.isEmpty ? name : '$rel/$name'}');
        }
      }
    }

    if (await Directory(x.source).exists()) await walk(x.source, x.target, '');
    return out;
  }

  Future<void> refreshPending(LiveSyncPair x) async {
    try {
      pending[keyOf(x)] = await diff(x);
    } catch (_) {}
    notifyListeners();
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
    final pairs = watching;
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

  /// 바뀜 · 정해진 간격: 다른 점을 다시 세고, 동작 시간이면 3초 뒤 맞춘다 (모아서)
  void _schedule(LiveSyncPair x) {
    final k = keyOf(x);
    _pending[k]?.cancel();
    _pending[k] = Timer(const Duration(seconds: 3), () async {
      await refreshPending(x);
      if (activeNow(x) && (pending[k]?.isNotEmpty ?? false)) await syncNow(x);
    });
  }

  bool isRunning(LiveSyncPair x) => _running.contains(keyOf(x));

  /// 지금 맞추는 쌍이 있는지
  bool get anyRunning => _running.isNotEmpty;

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
      pending[k] = await diff(x);
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
      if (!win) '-8', // 한글 등 이름을 \#355… 로 바꾸지 않고 그대로 (Android 빌드는 iconv 없음)
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
