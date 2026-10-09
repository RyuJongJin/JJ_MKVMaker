import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'package:path/path.dart' as p;

import '../core/cron_window.dart';
import '../core/file_ops.dart';
import '../core/sync_preview.dart' show isRsyncDeleteOption, isSourceRemovingOption;
import '../core/sync_tools.dart';
import '../core/vfs.dart';
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
    if (isDav(x.source) || isDav(x.target)) return _diffV(x, limit: limit);
    final out = <String>[];
    Future<void> walk(String src, String dst, String rel) async {
      if (out.length >= limit) return;
      final names = <String>{};
      List<FileSystemEntity> items;
      try {
        items = await Directory(src).list(followLinks: false).toList();
      } catch (_) {
        return; // 원본을 읽지 못함: 이 폴더의 "지울 것" 은 세지 않는다
      }
      for (final e in items) {
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

  /// [diff] 의 WebDAV 판 (한쪽이라도 dav://): 크기가 다르거나, 대상이 원본보다 옛것이면
  static Future<List<String>> _diffV(LiveSyncPair x, {int limit = 500}) async {
    final out = <String>[];
    Future<void> walk(String src, String dst, String rel) async {
      if (out.length >= limit) return;
      final there = <String, ({String path, bool isDir, int size, DateTime modified})>{};
      try {
        for (final e in await vList(dst)) {
          there[vBasename(e.path)] = e;
        }
      } catch (_) {} // 대상 폴더가 아직 없음
      final names = <String>{};
      List<({String path, bool isDir, int size, DateTime modified})> items;
      try {
        items = await vList(src, strict: true);
      } catch (_) {
        return; // 원본을 읽지 못함: "지울 것" 을 세지 않는다
      }
      for (final e in items) {
        if (out.length >= limit) return;
        final name = vBasename(e.path);
        names.add(name);
        final r = rel.isEmpty ? name : '$rel/$name';
        if (e.isDir) {
          await walk(e.path, vJoin(dst, name), r);
          continue;
        }
        final t = there[name];
        if (t == null || t.isDir || t.size != e.size || t.modified.isBefore(e.modified.subtract(const Duration(seconds: 2)))) {
          out.add(r);
        }
      }
      if (x.delete) {
        for (final name in there.keys) {
          if (!names.contains(name) && !name.endsWith('.jjsync')) out.add('− ${rel.isEmpty ? name : '$rel/$name'}');
        }
      }
    }

    if (await vExists(x.source)) await walk(x.source, x.target, '');
    return out;
  }

  Future<void> refreshPending(LiveSyncPair x) async {
    final k = keyOf(x);
    // 68: 원본을 읽을 수 없으면 "맞출 것 없음" 이 아니라 문제로 알린다
    try {
      if (!await vExists(x.source)) throw const FileSystemException('없음');
      await vList(x.source, strict: true);
      if (problems[k]?.empty == false) problems.remove(k); // 다시 읽힌다
    } catch (e) {
      problems[k] = SourceUnreadableException(x.source, cause: e);
    }
    try {
      pending[k] = await diff(x);
    } catch (_) {}
    notifyListeners();
  }

  static String keyOf(LiveSyncPair x) => '${x.source}=>${x.target}';

  /// 지우기를 확인하지 않은 쌍: 대상에만 있어 지워질 항목 (원본 기준 상대 경로). 확인 창에 보여 준다 (42)
  final toDelete = <String, List<String>>{};

  /// 원본을 읽지 못했거나 원본이 비어 멈춘 쌍 (68 · 70). 성공하면 지운다. 카드에 빨갛게 · 작업 알림에도
  final problems = <String, SourceUnreadableException>{};

  /// 원본이 비어 멈춘 쌍에서 지워질 항목 (70: 목록을 보고 [그래도 맞추기])
  final emptyDeletes = <String, List<String>>{};

  /// 다음 한 번은 원본이 비어도 맞춘다 (70)
  final _allowEmpty = <String>{};

  /// 70: 원본이 정말 비어 있는 것을 확인했다 → 이번 한 번 그대로 맞춘다 (대상에서 지움)
  Future<void> syncEmptyAnyway(LiveSyncPair x) async {
    _allowEmpty.add(keyOf(x));
    await syncNow(x);
  }

  /// 설정의 쌍을 바꾼다 (같은 원본 → 대상)
  Future<void> _setPair(LiveSyncPair old, LiveSyncPair now) => c.updateSettings((s) => s.liveSyncPairs = [
        for (final p in s.liveSyncPairs) keyOf(p) == keyOf(old) ? now : p,
      ]);

  /// 지울 목록을 보고 결정: [delete] true = 지우기 포함으로 맞추기 (확인함), false = 지우기 끄기. 그 뒤 바로 맞춘다
  Future<void> decideDelete(LiveSyncPair x, {required bool delete}) async {
    final now = delete ? x.copyWith(deleteConfirmed: true) : x.copyWith(delete: false);
    toDelete.remove(keyOf(x));
    await _setPair(x, now);
    await syncNow(now);
  }

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
      if (!isDav(x.source) && !Directory(x.source).existsSync()) {
        status[k] = (DateTime.now(), tr('원본 폴더가 없습니다'));
        continue;
      }
      // 대상이 원본 안이면 맞출 때마다 원본이 바뀌어 끝없이 돈다. 34: 원본이 대상 안 (안쪽 → 바깥) 은 지우기가 없을 때만
      if (nestingProblem(x, allowInnerToOuter: s.allowInnerToOuter) case final nest?) {
        status[k] = (DateTime.now(), nest);
        continue;
      }
      if (Platform.isWindows && !isDav(x.source)) {
        try {
          _watch[k] = Directory(x.source).watch(recursive: true).listen((_) => _schedule(x));
        } catch (_) {
          _timers[k] = Timer.periodic(Duration(seconds: s.liveSyncIntervalSec), (_) => _schedule(x));
        }
      } else {
        // Android 등 · 원본이 WebDAV: 폴더 안쪽까지 감시가 안 되므로 정해진 간격으로 살핀다
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
  /// 맞추면 안 되는 쌍이면 그 이유 (34: 대상이 원본 안 = 끝없이 돎, 원본이 대상 안 + 지우기 = 대상의 다른 파일이 지워짐)
  static String? nestingProblem(LiveSyncPair x, {bool allowInnerToOuter = true}) {
    if (isSameOrInside(x.target, x.source)) return tr('대상이 원본과 같거나 원본 안에 있습니다');
    if (x.delete && isSameOrInside(x.source, x.target)) return tr('원본이 대상 안에 있으면 지우기 포함으로 맞출 수 없습니다');
    // 102: 환경 설정에서 안쪽 → 바깥을 끄면 늘 막는다
    if (!allowInnerToOuter && isSameOrInside(x.source, x.target)) return tr('원본이 대상 안에 있습니다 (환경 설정에서 막아 둠)');
    return null;
  }

  Future<void> syncNow(LiveSyncPair x) async {
    final k = keyOf(x);
    final nest = nestingProblem(x, allowInnerToOuter: c.settings.allowInnerToOuter);
    if (nest != null) {
      status[k] = (DateTime.now(), nest);
      notifyListeners();
      return;
    }
    if (_running.contains(k)) {
      _schedule(x); // 도는 중에 바뀐 것은 끝난 뒤 다시
      return;
    }
    _running.add(k);
    notifyListeners();
    final s = c.settings;
    final asked = x;
    try {
      // 42: 지우기를 아직 확인하지 않았으면, 지울 것이 있을 때 지우지 않고 맞추고 확인을 기다린다 (목록은 [toDelete])
      if (x.delete && !x.deleteConfirmed) {
        final del = [for (final d in await diff(x, limit: 100000)) if (d.startsWith('− ')) d.substring(2)];
        if (del.isEmpty) {
          await _setPair(x, x.copyWith(deleteConfirmed: true));
        } else {
          toDelete[k] = del;
          x = x.copyWith(delete: false);
        }
      } else {
        toDelete.remove(k);
      }
      // 지우기 포함이면 원본을 확실히 읽을 수 있을 때만 (rsync --delete · robocopy /PURGE 도). 못 읽으면 멈추고 알린다
      final allowEmpty = _allowEmpty.remove(k);
      if (x.delete) await ensureSourceForDelete(x.source, x.target, allowEmpty: allowEmpty);
      // 한쪽이라도 WebDAV 면 rsync · robocopy 대신 앱이 맞춘다 (크기 · 시각 비교)
      final method = isDav(x.source) || isDav(x.target) ? CopyMethod.builtin : CopyMethod.of(x.method);
      final n = switch (method) {
        CopyMethod.builtin => await FileOps(bandwidthKBps: s.copyBandwidthKBps)
            .mirror(x.source, x.target, delete: x.delete, allowEmptySource: allowEmpty),
        CopyMethod.rsync => await _rsync(x, s),
        CopyMethod.robocopy => await _robocopy(x, s),
      };
      status[k] = toDelete[k] != null
          ? (DateTime.now(), trf('지우지 않고 맞춤 · 대상에만 있는 {0}개를 지울지 확인 필요', [toDelete[k]!.length]))
          : (DateTime.now(), n < 0 ? tr('맞춤') : trf('{0}개 맞춤', [n]));
      problems.remove(k);
      emptyDeletes.remove(k);
      pending[k] = await diff(asked);
      if (n != 0) c.note(trf('실시간 동기화 ({0}): {1} → {2}', [method.label, x.source, x.target]));
    } on SourceUnreadableException catch (e) {
      // 68 · 70: 대상은 건드리지 않고 멈춤. 카드에 빨갛게 · 작업 알림에 · 로그에
      problems[k] = e;
      status[k] = (DateTime.now(), e.empty ? tr('원본 폴더가 비어 있어 멈춤') : tr('원본을 읽을 수 없어 멈춤'));
      if (e.empty) {
        try {
          emptyDeletes[k] = [for (final d in await diff(asked, limit: 100000)) if (d.startsWith('− ')) d.substring(2)];
        } catch (_) {}
      } else {
        emptyDeletes.remove(k);
      }
      c.note(trf('실시간 동기화 멈춤: {0} → {1}: {2}', [x.source, x.target, e]));
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
    final args = rsyncArgsFor(x, s, windows: Platform.isWindows);
    await Directory(x.target).create(recursive: true);
    final r = await Process.run(exe, args, stdoutEncoding: utf8, stderrEncoding: utf8);
    if (!rsyncOk(r.exitCode)) throw ProcessException(exe, const [], '${r.stderr}'.trim(), r.exitCode);
    return RsyncOutput().feed('${r.stdout}\n').length;
  }

  /// rsync 인수 (실시간 동기화). 지우기는 쌍의 "지우기 포함" 으로만 - 설정의 rsync 옵션에 --delete · --del 이 있어도
  /// 41 · 42 의 확인을 건너뛰지 않게 뺀다 (97)
  static List<String> rsyncArgsFor(LiveSyncPair x, AppSettings s, {required bool windows}) => [
        // 107: 원본을 지우는 옵션 (--remove-source-files) 도 실시간 동기화에서는 쓰지 않는다
        ...splitOptions(s.rsyncOptions)
            .where((o) => o != '-P' && o != '--progress' && !isRsyncDeleteOption(o) && !isSourceRemovingOption(o)),
        if (!windows) '-8', // 한글 등 이름을 \#355… 로 바꾸지 않고 그대로 (Android 빌드는 iconv 없음)
        if (s.copyBandwidthKBps > 0) '--bwlimit=${s.copyBandwidthKBps}',
        if (x.delete) '--delete',
        '${toCygwinPath(x.source, windows: windows)}/',
        '${toCygwinPath(x.target, windows: windows)}/',
      ];

  /// robocopy 인수 (실시간 동기화). 지우기 (/MIR · /PURGE) 는 쌍의 "지우기 포함" 으로만 (/MIR 는 /E 로) - 97
  static List<String> robocopyArgsFor(LiveSyncPair x, AppSettings s) {
    final opts = [
      for (final o in splitOptions(s.robocopyOptions))
        if (o.toUpperCase() == '/MIR') '/E' else if (o.toUpperCase() != '/PURGE' && !isSourceRemovingOption(o)) o,
    ];
    return [
      x.source,
      x.target,
      ...opts,
      if (!opts.any((o) => o.toUpperCase() == '/E')) '/E',
      if (x.delete) '/PURGE',
      if (s.copyBandwidthKBps > 0) '/IPG:${robocopyIpg(s.copyBandwidthKBps)}',
      '/BYTES', '/NJH', '/NJS', '/NDL', '/NP',
    ];
  }

  Future<int> _robocopy(LiveSyncPair x, AppSettings s) async {
    final r = await Process.run('robocopy', robocopyArgsFor(x, s));
    if (!robocopyOk(r.exitCode)) throw ProcessException('robocopy', const [], '${r.stdout}'.trim(), r.exitCode);
    return RobocopyOutput().feed('${r.stdout}\n').length;
  }
}
