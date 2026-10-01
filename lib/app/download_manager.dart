import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../core/download_detect.dart';
import '../core/playlist.dart';
import '../services/downloader.dart';
import 'settings.dart';

/// 다운로드 목록 · 클립보드 감시 (플랫폼 무관)
class DownloadManager extends ChangeNotifier {
  final Map<DownloadKind, DownloadBackend> backends;
  final AppSettings Function() settings;

  /// 클립보드 읽기 (테스트에서 바꿔 끼움)
  final Future<String?> Function() readClipboard;

  DownloadManager({
    required List<DownloadBackend> backends,
    required this.settings,
    Future<String?> Function()? readClipboard,
  })  : backends = {for (final b in backends) b.kind: b},
        readClipboard = readClipboard ?? _systemClipboard;

  static Future<String?> _systemClipboard() async =>
      (await Clipboard.getData(Clipboard.kTextPlain))?.text;

  final List<DownloadTask> tasks = [];
  final Set<String> selected = {};
  int _nextId = 0;
  Timer? _clipTimer;
  String? _lastClip;

  /// 받은 동영상을 편집 목록(MKV 만들기)에 넣는 함수 (새로 넣은 개수를 돌려줌). 앱이 연결해 준다.
  Future<int> Function(List<String> files)? addToEditList;

  /// "완료시 자동 동영상추가" 를 켜고 끄는 함수 (설정에 저장). 앱이 연결해 준다.
  Future<void> Function(bool on)? setAutoAdd;

  /// 설정이 바뀌었을 때 화면 갱신
  void refresh() => notifyListeners();

  /// 목록에서만 뺀다 (받은 파일은 그대로)
  void dropFromList(DownloadTask t) {
    tasks.remove(t);
    selected.remove(t.id);
    notifyListeners();
  }

  /// 고른 다운로드 중 다 받은 것의 동영상 파일
  List<String> get selectedVideoFiles => [
        for (final t in _sel)
          if (t.state == DownloadState.done) ...videoFilesOf(t),
      ];

  /// 새로 추가된 다운로드 알림 (화면에 안내 표시용)
  final _added = StreamController<DownloadTask>.broadcast();
  Stream<DownloadTask> get onAdded => _added.stream;

  /// 다 받은 다운로드 알림 (편집 목록 자동 추가용). 한 건에 한 번만.
  final _finished = StreamController<DownloadTask>.broadcast();
  Stream<DownloadTask> get onFinished => _finished.stream;
  final Set<String> _reported = {};

  /// 받은 파일 중 동영상 (임시 · 조각 파일 제외, 실제로 있는 것만)
  static List<String> videoFilesOf(DownloadTask t, {bool Function(String)? exists}) {
    final ok = exists ?? (String f) => File(f).existsSync();
    final frag = RegExp(r'\.f\d+\.[^.]+$|\.part$|\.temp\.|\.ytdl$', caseSensitive: false);
    return [
      for (final f in t.files)
        if (isVideoFile(f) && !frag.hasMatch(f) && ok(f)) f,
    ];
  }

  int get activeCount => tasks.where((t) => t.unfinished).length;
  int get downloadingCount => tasks.where((t) => t.state == DownloadState.downloading).length;

  /// 진행 중 작업의 평균 진행률
  double? get overallProgress {
    final act = tasks.where((t) => t.state == DownloadState.downloading && t.progress != null);
    if (act.isEmpty) return null;
    return act.map((t) => t.progress!).reduce((a, b) => a + b) / act.length;
  }

  // ───────── 클립보드 감시 ─────────

  /// 1초마다 클립보드를 확인. 처음 시작할 때 이미 있던 내용은 무시한다.
  Future<void> startClipboardWatch() async {
    _clipTimer?.cancel();
    _lastClip = await _safeRead();
    _clipTimer = Timer.periodic(const Duration(seconds: 1), (_) => checkClipboard());
  }

  void stopClipboardWatch() {
    _clipTimer?.cancel();
    _clipTimer = null;
  }

  Future<String?> _safeRead() async {
    try {
      return await readClipboard();
    } catch (_) {
      return null;
    }
  }

  /// 클립보드가 바뀌었으면 주소를 찾아 다운로드 추가
  Future<List<DownloadTask>> checkClipboard() async {
    if (!settings().clipboardWatch) return const [];
    final text = await _safeRead();
    if (text == null || text == _lastClip) return const [];
    _lastClip = text;
    final added = <DownloadTask>[];
    for (final link in detectLinks(text)) {
      final t = add(link.url);
      if (t != null) added.add(t);
    }
    return added;
  }

  // ───────── 추가 · 제어 ─────────

  /// 주소 추가 후 바로 시작. 이미 받는 중인 주소거나 알 수 없는 주소면 null.
  DownloadTask? add(String text) {
    final links = detectLinks(text.trim());
    if (links.isEmpty) return null;
    final link = links.first;
    if (tasks.any((t) => t.source == link.url && t.state != DownloadState.cancelled)) return null;
    final backend = backends[link.kind];
    if (backend == null) return null;
    final s = settings();
    final t = DownloadTask(
      id: '${_nextId++}',
      kind: link.kind,
      source: link.url,
      dir: link.kind == DownloadKind.video ? s.ytDlpDir : s.aria2Dir,
    );
    tasks.insert(0, t);
    _added.add(t);
    // YouTube 재생목록: 목록을 읽어 영상마다 한 줄씩 바꿔 넣는다
    if (link.kind == DownloadKind.video && s.ytExpandPlaylists && youtubePlaylistId(link.url) != null) {
      t
        ..expanding = true
        ..title = '재생목록 불러오는 중…  ${link.url}';
      notifyListeners();
      unawaited(_expand(t, backend));
      return t;
    }
    notifyListeners();
    _pump();
    return t;
  }

  /// 브라우저에서 보고 있는 페이지 받기 (상단 [다운로드] 버튼).
  /// YouTube · 마그넷 · torrent 는 [add] 와 같고, 그 밖의 http 주소는 yt-dlp 로 받는다.
  DownloadTask? addPage(String url) {
    if (detectLinks(url).isNotEmpty) return add(url);
    if (!RegExp(r'^https?://', caseSensitive: false).hasMatch(url)) return null;
    if (tasks.any((t) => t.source == url && t.state != DownloadState.cancelled)) return null;
    if (backends[DownloadKind.video] == null) return null;
    final t = DownloadTask(id: '${_nextId++}', kind: DownloadKind.video, source: url, dir: settings().ytDlpDir);
    tasks.insert(0, t);
    _added.add(t);
    _changed();
    return t;
  }

  Future<void> _expand(DownloadTask holder, DownloadBackend backend) async {
    try {
      final r = await backend.expandPlaylist(holder.source);
      final i = tasks.indexOf(holder);
      if (i < 0) return; // 불러오는 동안 삭제됨
      if (r == null || r.$2.isEmpty) {
        // 재생목록이 아니면 영상 하나로 받음
        holder
          ..expanding = false
          ..title = holder.source;
        _changed();
        return;
      }
      final (name, entries) = r;
      final folder = safeFolderName(name);
      final dir = p.join(settings().ytDlpDir, folder.isEmpty ? 'playlist' : folder);
      final have = tasks.where((x) => x.state != DownloadState.cancelled).map((x) => x.source).toSet();
      final items = <DownloadTask>[];
      for (var k = 0; k < entries.length; k++) {
        final e = entries[k];
        if (have.contains(e.url)) continue;
        items.add(DownloadTask(id: '${_nextId++}', kind: DownloadKind.video, source: e.url, dir: dir)
          ..title = '[${k + 1}/${entries.length}] ${e.title}'
          ..extra['playlist'] = name);
      }
      tasks
        ..removeAt(i)
        ..insertAll(i, items);
      selected.remove(holder.id);
      _changed();
    } catch (e) {
      holder
        ..expanding = false
        ..state = DownloadState.failed
        ..error = e is ProcessException ? e.message : '$e';
      notifyListeners();
    }
  }

  /// 상태가 바뀔 때: 화면 갱신 + 대기 중인 다음 작업 시작
  /// 작업 기록에 남기기 (앱이 연결해 준다): 다운로드 시작 · 완료 · 실패
  void Function(String msg)? log;
  final Map<String, DownloadState> _lastState = {};

  void _changed() {
    for (final t in tasks) {
      if (t.state == DownloadState.done && _reported.add(t.id)) _finished.add(t);
      final before = _lastState[t.id];
      if (before != t.state) {
        _lastState[t.id] = t.state;
        final name = t.title == t.source ? t.source : '${t.title} (${t.source})';
        switch (t.state) {
          case DownloadState.downloading when before != DownloadState.downloading:
            log?.call('다운로드 시작: $name');
          case DownloadState.done:
            log?.call('다운로드 완료: $name${t.totalBytes == null ? '' : ' (${formatBytes(t.totalBytes!)})'}');
          case DownloadState.failed:
            log?.call('다운로드 실패: $name - ${t.error ?? ''}');
          default:
            break;
        }
      }
    }
    notifyListeners();
    _pump();
  }

  /// 동시 다운로드 수 안에서 대기 중인 작업을 들어온 순서대로 시작
  void _pump() {
    final limit = settings().maxParallelDownloads;
    var running = tasks.where((t) => t.state == DownloadState.downloading).length;
    final waiting = tasks.where((t) => t.state == DownloadState.queued && !t.expanding).toList()
      ..sort((a, b) => int.parse(a.id).compareTo(int.parse(b.id)));
    for (final t in waiting) {
      if (limit > 0 && running >= limit) break;
      final backend = backends[t.kind];
      if (backend == null) continue;
      t.state = DownloadState.downloading;
      running++;
      unawaited(backend.start(t, _changed));
    }
  }

  Iterable<DownloadTask> get _sel => tasks.where((t) => selected.contains(t.id));

  void toggle(DownloadTask t) {
    if (!selected.remove(t.id)) selected.add(t.id);
    notifyListeners();
  }

  void selectAll() {
    selected
      ..clear()
      ..addAll(tasks.map((t) => t.id));
    notifyListeners();
  }

  void selectNone() {
    selected.clear();
    notifyListeners();
  }

  Future<void> pause(Iterable<DownloadTask> list) async {
    for (final t in list.toList()) {
      if (t.state == DownloadState.downloading || t.state == DownloadState.queued) {
        await backends[t.kind]!.pause(t);
      }
    }
    _changed();
  }

  /// 다시 받기: 대기열에 넣고 차례가 되면 시작
  Future<void> resume(Iterable<DownloadTask> list) async {
    for (final t in list.toList()) {
      if (t.state == DownloadState.paused || t.state == DownloadState.failed) {
        if (t.state == DownloadState.failed) t.extra.remove('gid'); // 실패한 aria2 작업은 새로 추가
        t
          ..state = DownloadState.queued
          ..error = null;
      }
    }
    _changed();
  }

  /// 중지하고 받던 파일 삭제 (목록에는 '취소됨' 으로 남김)
  Future<void> cancel(Iterable<DownloadTask> list) async {
    for (final t in list.toList()) {
      if (t.unfinished) await backends[t.kind]!.cancel(t);
    }
    _changed();
  }

  /// 목록에서 삭제 (진행 중이면 취소 후 삭제)
  Future<void> remove(Iterable<DownloadTask> list) async {
    final items = list.toList();
    await cancel(items);
    for (final t in items) {
      tasks.remove(t);
      selected.remove(t.id);
    }
    notifyListeners();
  }

  Future<void> pauseSelected() => pause(_sel);
  Future<void> resumeSelected() => resume(_sel);
  Future<void> cancelSelected() => cancel(_sel);
  Future<void> removeSelected() => remove(_sel);

  /// 완료·취소·실패 항목 정리 (받은 파일은 그대로 둠)
  void cleanupFinished() {
    tasks.removeWhere((t) {
      final gone = !t.unfinished;
      if (gone) selected.remove(t.id);
      return gone;
    });
    notifyListeners();
  }

  /// 앱 종료: 모든 다운로드 중지
  Future<void> shutdown() async {
    stopClipboardWatch();
    for (final b in backends.values) {
      await b.shutdown();
    }
  }

  @override
  void dispose() {
    stopClipboardWatch();
    _added.close();
    _finished.close();
    super.dispose();
  }
}
