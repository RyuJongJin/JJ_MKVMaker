import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

import '../core/charset_detector.dart';
import '../core/encode_options.dart';
import '../core/languages.dart';
import '../core/mkv_command_builder.dart';
import '../core/models.dart';
import '../core/output_paths.dart';
import '../core/playlist.dart';
import '../core/srt.dart';
import '../core/subtitle_detector.dart';
import '../core/subtitle_search.dart';
import '../services/subtitle_provider.dart';
import '../core/text_codec.dart';
import '../core/ai_subtitle.dart';
import '../services/ai_services.dart';
import '../services/media_tool.dart';
import '../services/model_store.dart';
import '../services/platform_services.dart';
import '../services/system_usage.dart';
import 'settings.dart';
import '../l10n/tr.dart';

extension<T> on Set<T> {
  Set<T> ifEmpty(Set<T> other) => isEmpty ? other : this;
}

/// AI 자막 설정
class AiOptions {
  /// 원어 (undetermined = 자동 감지)
  final Language source;

  /// 만들 언어 (기본: 한국어·영어·일본어)
  final Set<Language> targets;
  final ModelSpec whisper;

  const AiOptions({
    this.source = undetermined,
    required this.targets,
    required this.whisper,
  });

  /// 기본값: 한국어·영어·일본어
  static AiOptions defaults() =>
      AiOptions(targets: {for (final c in defaultTargetLanguages) languageOf(c)}, whisper: whisperModels.first);

  /// 원어와 다른 언어가 있으면 번역 모델 필요 (원어 자동이면 필요하다고 봄)
  bool get needsTranslation =>
      source == undetermined || targets.any((t) => t.code != source.code);

  AiOptions copyWith({Language? source, Set<Language>? targets, ModelSpec? whisper}) => AiOptions(
      source: source ?? this.source, targets: targets ?? this.targets, whisper: whisper ?? this.whisper);
}

/// 화면 상태와 작업 흐름 (플랫폼 무관)
class AppController extends ChangeNotifier {
  final PlatformServices services;

  /// 설정 저장소 (null 이면 저장하지 않음 - 테스트용)
  final SettingsStore? settingsStore;
  AppSettings settings = AppSettings();

  AppController(this.services, {this.settingsStore});

  /// 종료 전 확인 (다운로드 중이면 목록 확인). main 에서 연결, 업데이트 설치 때 사용
  Future<bool> Function()? confirmQuit;

  /// 설정 변경 후 저장·적용
  /// 위쪽 막대의 CPU · MEM 표시 (2초마다, 보는 화면이 있을 때만 잰다). 지원하지 않으면 null.
  late final UsageMonitor? usage =
      services.usage == null ? null : UsageMonitor(services.usage!, diskPath: _downloadDisk);

  /// 다운로드 폴더가 있는 드라이브 (예: "M:\\"). 설정이 바뀔 때만 다시 알아낸다.
  String? _diskFor, _diskRoot;
  String _downloadDisk() {
    final key = settings.downloadRoot ?? '';
    if (_diskRoot == null || _diskFor != key) {
      _diskFor = key;
      try {
        _diskRoot = p.rootPrefix(p.absolute(settings.resolvedDownloadRoot()));
      } catch (_) {
        _diskRoot = '';
      }
    }
    return _diskRoot!;
  }

  // ───────── 목록 정렬 ─────────

  /// 마지막으로 누른 정렬 ('name' · 'date') 과 방향. 같은 것을 다시 누르면 반대로.
  String? sortedBy;
  bool sortAscending = true;

  /// 동영상 목록을 파일 이름 ('name') 또는 파일 날짜 ('date') 순으로 정렬
  void sortVideos(String by) {
    sortAscending = sortedBy == by ? !sortAscending : true;
    sortedBy = by;
    final dates = <VideoItem, DateTime>{};
    if (by == 'date') {
      for (final v in videos) {
        try {
          dates[v] = File(v.path).lastModifiedSync();
        } catch (_) {
          dates[v] = DateTime.fromMillisecondsSinceEpoch(0);
        }
      }
    }
    videos.sort((a, b) {
      var d = by == 'date' ? dates[a]!.compareTo(dates[b]!) : 0;
      if (d == 0) d = naturalCompare(a.fileName.toLowerCase(), b.fileName.toLowerCase());
      return sortAscending ? d : -d;
    });
    _saveVideoList();
    notifyListeners();
  }

  Future<void> updateSettings(void Function(AppSettings s) change) async {
    change(settings);
    _applySettings();
    notifyListeners();
    await settingsStore?.save(settings);
  }

  void _applySettings() {
    outputRootOverride =
        (settings.mkvOutputRoot?.isNotEmpty ?? false) ? settings.mkvOutputRoot : null;
  }

  void _saveSettings() => settingsStore?.save(settings);

  MediaTool get _tool => services.mediaTool;

  final List<VideoItem> videos = [];
  final List<String> logs = [];
  VideoItem? selected;
  String? ffmpegVersion;
  bool busy = false;

  /// 화면 크기 · 코덱 · 화질 (모든 동영상에 적용)
  EncodeSettings encode = const EncodeSettings();

  /// FFmpeg 가 지원하는 영상 인코더
  Set<String> encoders = {};

  Future<void> init() async {
    if (settingsStore != null) {
      settings = await settingsStore!.load();
      // 앱 안 브라우저의 로그인 · 쿠키 폴더 (yt-dlp 가 같은 쿠키를 읽음)
      try {
        settings.webViewDataDir = p.join((await getApplicationSupportDirectory()).path, 'webview');
      } catch (_) {}
      encode = settings.encode;
      aiOptions = AiOptions(
        source: languageOf(settings.aiSource),
        targets: {
          for (final c in settings.aiTargets)
            if (languageOf(c) != undetermined) languageOf(c),
        }.ifEmpty({for (final c in defaultTargetLanguages) languageOf(c)}),
        whisper: whisperModels.firstWhere((m) => m.id == settings.aiWhisper,
            orElse: () => whisperModels.first),
      );
      _applySettings();
    }
    ffmpegVersion = await _tool.version();
    if (ffmpegVersion == null) {
      _log(tr('⚠ FFmpeg 를 찾을 수 없습니다. MKV 만들기를 사용할 수 없습니다.'));
      return;
    }
    encoders = await _tool.encoders();
    final missing = [
      for (final c in VideoCodecChoice.values)
        if (c != VideoCodecChoice.copy && !isCodecAvailable(c)) c.label,
    ];
    _log(trf('FFmpeg 준비됨: {0}' '{1}', [ffmpegVersion, missing.isEmpty ? '' : trf(' ⚠ 사용할 수 없는 코덱: {0}', [missing.join(', ')])]));
  }

  bool isCodecAvailable(VideoCodecChoice c) =>
      c == VideoCodecChoice.copy || c.pickEncoder(encoders) != null;

  void setCodec(VideoCodecChoice c) {
    // 원본 유지(복사)는 크기 · 화면 비율 · 회전 · 색 보정을 할 수 없으므로 처음으로
    encode = c == VideoCodecChoice.copy
        ? encode.resetAdjust().copyWith(codec: c, resolution: ResolutionChoice.original)
        : encode.copyWith(codec: c);
    _encodeChanged();
  }

  /// 화면 비율 · 회전 · 색 보정 바꾸기 (재인코딩이 필요하면 기본 H.264 로)
  void setAdjust(EncodeSettings e) {
    encode = e.adjusts && e.codec == VideoCodecChoice.copy ? e.copyWith(codec: VideoCodecChoice.h264) : e;
    _encodeChanged();
  }

  void _encodeChanged() {
    settings.encode = encode;
    _saveSettings();
    notifyListeners();
  }

  void setResolution(ResolutionChoice r) {
    // 크기를 바꾸려면 재인코딩이 필요하므로 기본 H.264 로
    final needCodec =
        r != ResolutionChoice.original && encode.codec == VideoCodecChoice.copy;
    encode = encode.copyWith(
        resolution: r, codec: needCodec ? VideoCodecChoice.h264 : null);
    _encodeChanged();
  }

  void setQuality(QualityChoice q) {
    encode = encode.copyWith(quality: q);
    _encodeChanged();
  }

  /// 원본보다 큰 크기로 인코딩하게 되는 동영상 수
  int get upscaleCount => videos
      .where((v) => isUpscale(encode.resolution, v.info?.ofType('video').firstOrNull))
      .length;

  // ───────── 동영상 ─────────

  Future<void> pickVideos() async {
    final paths = await services.storage.pickVideos();
    await addVideos(paths);
  }

  /// [allowOutputFolder]: 탐색기에서 직접 연 파일은 jj_mkv 폴더 안에 있어도 넣는다
  Future<void> addVideos(List<String> paths, {bool allowOutputFolder = false}) async {
    for (final path in paths) {
      if (videos.any((v) => p.equals(v.path, path))) continue;
      // jj_mkv 출력 폴더 안의 파일은 제외 (폴더째 넣을 때 만든 결과물이 다시 들어가지 않게)
      if (!allowOutputFolder && p.basename(p.dirname(path)) == outputFolderName) {
        _log(trf('건너뜀 (출력 폴더의 파일): {0}', [p.basename(path)]));
        continue;
      }
      final v = VideoItem(path);
      videos.add(v);
      selected ??= v;
      notifyListeners();
      await _loadVideo(v);
    }
    _saveVideoList();
  }

  // ───────── 동영상 목록 저장 · 창끼리 공유 ─────────
  //
  // 목록(경로)을 파일 하나에 적어 둔다. 다시 켜면 그대로 불러오고, 창이 여러 개면
  // 1초마다 파일을 보고 다른 창에서 넣거나 지운 것을 따라 한다.

  String? _videoListFile;
  String _videoListSaved = '[]';
  Timer? _videoListTimer;
  bool _videoListSyncing = false;

  /// 목록 저장 · 공유 시작 ([file] 을 먼저 불러온다)
  Future<void> shareVideoList(String file) async {
    _videoListFile = file;
    await syncVideoList();
    _videoListTimer?.cancel();
    _videoListTimer = Timer.periodic(const Duration(seconds: 1), (_) => syncVideoList());
  }

  void stopVideoListShare() {
    _videoListTimer?.cancel();
    _videoListTimer = null;
  }

  void _saveVideoList() {
    final file = _videoListFile;
    if (file == null || _videoListSyncing) return;
    final text = jsonEncode([for (final v in videos) v.path]);
    if (text == _videoListSaved) return;
    _videoListSaved = text;
    try {
      // 다른 창이 읽는 중에 반쯤 쓴 파일을 보지 않도록: 임시 파일 → 이름 바꾸기
      final tmp = File('$file.$pid.tmp')..writeAsStringSync(text, flush: true);
      tmp.renameSync(file);
    } catch (_) {}
  }

  /// 파일이 바뀌었으면 (다른 창에서 넣거나 지움) 이 창의 목록을 맞춘다
  Future<void> syncVideoList() async {
    final file = _videoListFile;
    if (file == null || _videoListSyncing) return;
    String text;
    try {
      final f = File(file);
      if (!f.existsSync()) return;
      text = f.readAsStringSync();
    } catch (_) {
      return;
    }
    if (text == _videoListSaved) return;
    List<String> want;
    try {
      want = (jsonDecode(text) as List).cast<String>();
    } catch (_) {
      return;
    }
    _videoListSyncing = true;
    try {
      _videoListSaved = text;
      bool inWant(VideoItem v) => want.any((w) => p.equals(w, v.path));
      // 작업 중인 동영상은 지우지 않는다
      videos.removeWhere((v) => !inWant(v) && v.status != JobStatus.running);
      if (selected != null && !videos.contains(selected)) selected = videos.firstOrNull;
      notifyListeners();
      await addVideos([for (final w in want) if (File(w).existsSync()) w], allowOutputFolder: true);
    } finally {
      _videoListSyncing = false;
      _saveVideoList(); // 없는 파일을 뺐거나 맞추는 동안 이 창에서 바꾼 것이 있으면 다시 적는다
    }
  }

  Future<void> _loadVideo(VideoItem v) async {
    try {
      v.info = await _tool.probe(v.path);
      // 내장 자막 (mkv 등)
      for (final s in v.info!.ofType('subtitle')) {
        v.subtitles.add(SubtitleEntry.embedded(
          streamIndex: s.index,
          codec: s.codec,
          language: languageOf(s.language),
          title: s.title,
        ));
      }
    } on MediaToolException catch (e) {
      v.message = e.message;
      _log(trf('분석 실패: {0} - {1}', [v.fileName, e.message]));
    }

    // 같은 폴더의 자막 자동 추가 (기능 4)
    final siblings = findSiblingSubtitles(
        v.path, await services.storage.listFiles(v.directory));
    for (final d in siblings) {
      await _addExternal(v, d.path, d.language);
    }
    // 전에 만든 자막 (jj_mkv 의 파일명_ko.srt 등: AI 자막 · 번역 · 인터넷 자막) 도 다시 연결
    // (앱을 다시 켜거나 목록에 다시 넣어도 MKV 에 빠지지 않게). 음성인식 원본 파일명_AI.srt 는 언어별 파일과 같아서 뺀다.
    var made = 0;
    final out = outputDirFor(v.path);
    if (!p.equals(out, v.directory)) {
      List<String> files = const [];
      try {
        files = await services.storage.listFiles(out);
      } catch (_) {}
      for (final d in findSiblingSubtitles(v.path, files)) {
        if (d.isAi || d.language == undetermined) continue;
        if (v.subtitles.any((s) => s.path != null && p.equals(s.path!, d.path))) continue;
        await _addExternal(v, d.path, d.language);
        made++;
      }
    }
    final embeddedCount =
        v.subtitles.where((s) => s.kind == SubtitleKind.embedded).length;
    _log(trf('추가: {0} (내장 자막 {1}개, 같은 폴더 자막 {2}개)', [v.fileName, embeddedCount, siblings.length]) +
        (made > 0 ? trf(' · 전에 만든 자막 {0}개 (jj_mkv)', [made]) : ''));
    notifyListeners();
  }

  void select(VideoItem v) {
    selected = v;
    notifyListeners();
  }

  // ───────── 여러 개 선택 (일괄 작업) ─────────

  /// 체크한 동영상 (일괄 자막 만들기 · MKV 만들기 · 제거 대상)
  final Set<VideoItem> checked = {};

  void toggleChecked(VideoItem v) {
    if (!checked.remove(v)) checked.add(v);
    notifyListeners();
  }

  /// 모두 체크되어 있으면 모두 해제, 아니면 모두 체크
  void toggleAllChecked() {
    if (checked.length == videos.length) {
      checked.clear();
    } else {
      checked
        ..clear()
        ..addAll(videos);
    }
    notifyListeners();
  }

  /// 일괄 작업 대상: 체크한 동영상 (목록 순서대로). 체크한 것이 없으면 지금 보고 있는 한 개.
  List<VideoItem> get batchTargets {
    checked.retainAll(videos);
    if (checked.isNotEmpty) return videos.where(checked.contains).toList();
    return [?selected];
  }

  /// 체크한 동영상을 목록에서 제거 (작업 중인 것은 남긴다)
  void removeChecked() {
    final gone = checked.where((v) => v.status != JobStatus.running).toList();
    videos.removeWhere(gone.contains);
    checked.removeAll(gone);
    if (selected != null && !videos.contains(selected)) selected = videos.firstOrNull;
    _saveVideoList();
    notifyListeners();
  }

  /// [targets] 의 AI 자막을 만들고, 이어서 그 동영상들만 MKV 로 만든다 (자막 만들기를 취소하면 거기서 멈춤)
  Future<void> aiThenBuild(List<VideoItem> targets, AiOptions opts) async {
    await generateAiSubtitles(targets, opts);
    if (_aiCancelled) return;
    await buildVideos(targets);
  }

  /// 다 받은 동영상을 편집 목록에 추가 (이미 있으면 건너뜀). 새로 넣은 개수.
  Future<int> addDownloaded(List<String> files) async {
    final before = videos.length;
    await addVideos(files);
    final n = videos.length - before;
    for (final v in videos.skip(before)) {
      _log(trf('받은 동영상을 편집 목록에 추가: {0}', [v.fileName]));
    }
    return n;
  }

  /// 동영상을 이동 폴더 (환경 설정) 로 옮긴다. 옆에 있는 같은 이름의 자막 파일 (a.srt · a.ko.smi …) 과
  /// 만든 결과물 (jj_mkv 의 a.mkv · a_AI.srt · a_ko.srt …) 도 함께 (결과물은 이동 폴더의 jj_mkv 로).
  /// 옮긴 동영상은 목록에서 뺀다. 작업 중인 것은 옮기지 않는다. 반환: (옮긴 수, 못 옮긴 이유들)
  Future<(int, List<String>)> moveVideos(List<VideoItem> targets) async {
    final dest = settings.moveTargetDir;
    if (dest == null || dest.isEmpty) return (0, [tr('이동할 폴더가 정해지지 않았습니다 (환경 설정 > 저장 위치)')]);
    var moved = 0;
    final errors = <String>[];
    try {
      await Directory(dest).create(recursive: true);
    } catch (e) {
      return (0, [trf('이동할 폴더를 만들 수 없습니다: {0} ({1})', [dest, e])]);
    }
    for (final v in List.of(targets)) {
      if (v.status == JobStatus.running) {
        errors.add(trf('{0}: 작업 중이라 옮기지 않았습니다', [v.fileName]));
        continue;
      }
      if (p.equals(v.directory, dest)) {
        errors.add(trf('{0}: 이미 이동 폴더에 있습니다', [v.fileName]));
        continue;
      }
      try {
        final side = {
          for (final s in v.subtitles)
            if (s.path != null &&
                p.equals(p.dirname(s.path!), v.directory) &&
                p.basename(s.path!).startsWith('${v.baseName}.') &&
                File(s.path!).existsSync())
              s.path!,
        };
        final to = await moveFileInto(v.path, dest);
        for (final s in side) {
          try {
            await moveFileInto(s, dest);
          } catch (e) {
            _log(trf('자막 이동 실패: {0} ({1})', [p.basename(s), e]));
          }
        }
        final results = await _moveResults(v.path, to);
        _log(trf('이동: {0} → {1}{2}', [
          v.fileName,
          to,
          [
            if (side.isNotEmpty) trf(' (자막 {0}개 함께)', [side.length]),
            if (results > 0) trf(' (결과물 {0}개 함께)', [results]),
          ].join(),
        ]));
        videos.remove(v);
        checked.remove(v);
        moved++;
      } catch (e) {
        errors.add('${v.fileName}: $e');
      }
    }
    if (selected != null && !videos.contains(selected)) selected = videos.firstOrNull;
    _saveVideoList();
    notifyListeners();
    return (moved, errors);
  }

  /// 만든 결과물 (jj_mkv 의 이름.mkv · 이름_AI.srt · 이름_ko.srt …) 을 옮긴 동영상의 jj_mkv 로. 옮긴 개수.
  Future<int> _moveResults(String oldVideo, String newVideo) async {
    final from = outputDirFor(oldVideo), to = outputDirFor(newVideo);
    if (p.equals(from, to) || !Directory(from).existsSync()) return 0;
    final stem = p.basenameWithoutExtension(oldVideo);
    final mine = RegExp('^${RegExp.escape(stem)}(\\.mkv|_[A-Za-z-]+\\.(srt|ass|ssa|smi|vtt|sub))\$', caseSensitive: false);
    var n = 0;
    for (final f in Directory(from).listSync().whereType<File>()) {
      if (!mine.hasMatch(p.basename(f.path))) continue;
      try {
        await Directory(to).create(recursive: true);
        await moveFileInto(f.path, to);
        n++;
      } catch (e) {
        _log(trf('결과물 이동 실패: {0} ({1})', [p.basename(f.path), e]));
      }
    }
    return n;
  }

  /// 파일을 폴더 안으로 옮긴다 (같은 이름이 있으면 "이름 (2).mp4"). 다른 드라이브 · SD 카드면 복사 후 지운다. 옮긴 경로를 돌려준다.
  static Future<String> moveFileInto(String from, String dir) async {
    final stem = p.basenameWithoutExtension(from), ext = p.extension(from);
    var to = p.join(dir, p.basename(from));
    for (var n = 2; File(to).existsSync(); n++) {
      to = p.join(dir, '$stem ($n)$ext');
    }
    try {
      await File(from).rename(to);
    } on FileSystemException {
      await File(from).copy(to);
      await File(from).delete();
    }
    return to;
  }

  void removeVideo(VideoItem v) {
    if (v.status == JobStatus.running) return;
    videos.remove(v);
    checked.remove(v);
    if (selected == v) selected = videos.isEmpty ? null : videos.first;
    _saveVideoList();
    notifyListeners();
  }

  void clearVideos() {
    if (busy) return;
    videos.clear();
    checked.clear();
    selected = null;
    _saveVideoList();
    notifyListeners();
  }

  // ───────── 자막 ─────────

  Future<void> pickSubtitlesFor(VideoItem v) async {
    final paths =
        await services.storage.pickSubtitles(initialDirectory: v.directory);
    for (final path in paths) {
      if (v.subtitles.any((s) => s.path != null && p.equals(s.path!, path))) {
        continue;
      }
      final d = findSiblingSubtitles(v.path, [path]);
      await _addExternal(v, path, d.isEmpty ? undetermined : d.first.language);
    }
    notifyListeners();
  }

  Future<void> _addExternal(VideoItem v, String path, Language lang) async {
    String charset = 'UTF-8';
    try {
      final head = await services.storage.readHead(path, 64 * 1024);
      charset = detectCharset(Uint8List.fromList(head));
    } catch (_) {}
    v.subtitles.add(SubtitleEntry.external(
        path: path, language: lang, charset: charset));
  }

  /// 내장 자막은 '삭제' 표시(출력에서 제외), 외부 자막은 목록에서 제거
  void removeSubtitle(VideoItem v, SubtitleEntry s) {
    if (s.kind == SubtitleKind.embedded) {
      s.enabled = !s.enabled;
    } else {
      v.subtitles.remove(s);
    }
    notifyListeners();
  }

  void setLanguage(SubtitleEntry s, Language lang) {
    s.language = lang;
    notifyListeners();
  }

  void setCharset(SubtitleEntry s, String charset) {
    s.charset = charset;
    notifyListeners();
  }

  // ───────── 자막 편집 (2단계) ─────────

  /// 편집 가능 여부 (이미지 자막은 불가)
  bool canEdit(SubtitleEntry s) =>
      !(s.kind == SubtitleKind.embedded && bitmapSubtitleCodecs.contains(s.codec)) &&
      (s.kind == SubtitleKind.external || ffmpegVersion != null);

  /// 자막을 큐 목록으로 불러온다.
  /// - 외부 SRT: 지정 문자셋으로 직접 읽음
  /// - 외부 SMI/ASS/VTT, 내장 트랙: FFmpeg 로 UTF-8 SRT 변환 후 읽음
  Future<List<Cue>> loadCues(VideoItem v, SubtitleEntry s) async {
    final storage = services.storage;
    if (s.kind == SubtitleKind.external && s.codec == 'srt') {
      final bytes = await storage.readBytes(s.path!);
      return parseSrt(decodeText(bytes, s.charset ?? 'UTF-8'));
    }
    final tmp = p.join(await storage.tempDirectory(),
        'edit_${DateTime.now().microsecondsSinceEpoch}.srt');
    final copy = await _utf8Copy(s);
    try {
      await _tool.runFfmpeg(s.kind == SubtitleKind.external
          ? buildToSrtArgs(input: copy ?? s.path!, output: tmp, charset: copy == null ? s.charset : null)
          : buildToSrtArgs(input: v.path, output: tmp, streamIndex: s.streamIndex));
      return parseSrt(decodeText(await storage.readBytes(tmp), 'UTF-8'));
    } finally {
      await storage.delete(tmp);
      if (copy != null) await storage.delete(copy);
    }
  }

  /// UTF-8 이 아닌 외부 자막 (CP949 SMI 등) 의 UTF-8 임시 사본. 필요 없으면 null.
  /// Android 의 FFmpeg (ffmpeg-kit) 에는 문자셋 변환 (iconv) 이 없어 -sub_charenc 를 쓸 수 없으므로
  /// 앱이 바꿔서 넘긴다 (Windows 도 같은 방식으로).
  Future<String?> _utf8Copy(SubtitleEntry s) async {
    final cs = s.charset;
    if (s.kind != SubtitleKind.external || s.path == null || cs == null || cs.startsWith('UTF-')) return null;
    final storage = services.storage;
    final text = decodeText(await storage.readBytes(s.path!), cs);
    final copy = p.join(await storage.tempDirectory(),
        'utf8_${DateTime.now().microsecondsSinceEpoch}_${p.basename(s.path!)}');
    await storage.writeBytes(copy, utf8.encode(text));
    return copy;
  }

  /// 편집한 자막을 jj_mkv\파일명_언어코드.srt 로 저장하고 MKV 에 반영되도록 목록을 바꾼다.
  /// - 내장 자막: 원래 트랙은 '삭제' 표시, 편집본을 외부 자막으로 추가
  /// - 외부 자막: 같은 자리의 항목을 편집본으로 교체 (원본 파일은 그대로 둠)
  /// 돌려주는 값: (저장 경로, 표현할 수 없어 '?' 로 바뀐 글자 수)
  Future<(String, int)> saveEdited(
      VideoItem v, SubtitleEntry s, List<Cue> cues, String charset) async {
    final enc = encodeText(formatSrt(cues), charset);
    final target = await _editedPath(v, s);
    await services.storage.writeBytes(target, enc.bytes);

    final edited = SubtitleEntry.external(
      path: target,
      language: s.language,
      charset: charset == 'UTF-8-BOM' ? 'UTF-8' : charset,
      title: s.title,
    );
    final i = v.subtitles.indexOf(s);
    if (s.kind == SubtitleKind.embedded) {
      s.enabled = false;
      v.subtitles.insert(i + 1, edited);
    } else {
      v.subtitles[i] = edited;
    }
    if (v.status == JobStatus.done) v.status = JobStatus.ready;
    _log(trf('자막 저장: {0} ({1}, {2}개 줄)' '{3}', [p.basename(target), charset, cues.length, enc.lostChars > 0 ? trf(' ⚠ 표현할 수 없는 글자 {0}개', [enc.lostChars]) : '']));
    notifyListeners();
    return (target, enc.lostChars);
  }

  /// 다른 이름으로 저장 (목록은 바꾸지 않음)
  Future<(String?, int)> saveCuesAs(
      VideoItem v, List<Cue> cues, String charset, String fileName) async {
    final enc = encodeText(formatSrt(cues), charset);
    final path = await services.storage.saveAs(
        fileName: fileName, bytes: enc.bytes, initialDirectory: v.directory);
    if (path != null) _log(trf('다른 이름으로 저장: {0} ({1})', [path, charset]));
    return (path, enc.lostChars);
  }

  Future<String> _editedPath(VideoItem v, SubtitleEntry s) async {
    // 이미 편집본(jj_mkv 안)을 다시 편집하면 같은 파일에 덮어쓴다
    if (s.kind == SubtitleKind.external &&
        p.equals(p.dirname(s.path!), outputDirFor(v.path)) &&
        p.extension(s.path!).toLowerCase() == '.srt') {
      return s.path!;
    }
    final base = languageSubtitlePath(v.path, s.language);
    final used = v.subtitles
        .where((e) => e != s && e.path != null)
        .map((e) => p.normalize(e.path!).toLowerCase())
        .toSet();
    var candidate = base;
    for (var n = 2; used.contains(p.normalize(candidate).toLowerCase()); n++) {
      candidate = '${p.withoutExtension(base)}_$n.srt';
    }
    return candidate;
  }

  // ───────── AI 자막 (4단계) ─────────

  bool get aiAvailable =>
      services.createRecognizer != null && services.createTranslator != null;

  /// 마지막으로 고른 AI 자막 설정
  AiOptions aiOptions = AiOptions.defaults();

  Translator? _translator;
  bool _aiCancelled = false;

  // ───────── 작업 대기열 ─────────

  /// 실행 중인 작업 이름 (없으면 null)
  String? currentJob;

  /// 대기 중인 작업 이름 (차례대로)
  final List<String> pendingJobs = [];
  final List<(Future<void> Function(), Completer<void>)> _pendingRuns = [];

  /// 작업 중이면 대기열에 넣고, 아니면 바로 실행한다. 끝나면 다음 작업을 이어서 실행.
  /// (AI 자막 · 자막 번역 · MKV 만들기 는 CPU · 메모리를 많이 써서 하나씩)
  /// 돌려주는 Future 는 그 작업이 실제로 끝날 때 (취소로 빠지면 바로) 끝난다.
  Future<void> _enqueue(String label, Future<void> Function() job) {
    if (busy) {
      final done = Completer<void>();
      pendingJobs.add(label);
      _pendingRuns.add((job, done));
      _log(trf('대기열에 추가: {0} (대기 {1}개)', [label, pendingJobs.length]));
      notifyListeners();
      return done.future;
    }
    return _run(label, job);
  }

  Future<void> _run(String label, Future<void> Function() job) async {
    busy = true;
    currentJob = label;
    notifyListeners();
    try {
      await job();
    } finally {
      busy = false;
      currentJob = null;
      notifyListeners();
      if (_pendingRuns.isNotEmpty) {
        final (next, done) = _pendingRuns.removeAt(0);
        final nextLabel = pendingJobs.removeAt(0);
        unawaited(_run(nextLabel, next).then((_) => done.complete(), onError: done.completeError));
      }
    }
  }

  /// [targets] 동영상들의 AI 자막 만들기 (하나씩 차례로). 다른 작업 중이면 대기열로.
  Future<void> generateAiSubtitles(List<VideoItem> targets, AiOptions opts) async {
    if (!aiAvailable || ffmpegVersion == null || targets.isEmpty) return;
    aiOptions = opts;
    settings
      ..aiSource = opts.source.code
      ..aiTargets = [for (final t in opts.targets) t.code]
      ..aiWhisper = opts.whisper.id;
    _saveSettings();
    if (busy) {
      for (final v in targets) {
        v.phase = tr('AI 자막 대기 중');
      }
    }
    final label = targets.length == 1 ? trf('AI 자막: {0}', [targets.first.fileName]) : trf('AI 자막 {0}개', [targets.length]);
    return _enqueue(label, () => _runAi(targets, opts));
  }

  Future<void> _runAi(List<VideoItem> targets, AiOptions opts) async {
    _aiCancelled = false;
    try {
      // 1. 모델 준비 (없으면 내려받기)
      for (final m in [opts.whisper, nllbModel]) {
        if (m == nllbModel && !opts.needsTranslation) continue;
        if (await services.models.isInstalled(m)) continue;
        _log(trf('모델 내려받는 중: {0} ({1})', [m.label, m.sizeLabel]));
        await services.models.download(m,
            isCancelled: () => _aiCancelled,
            onProgress: (x) {
              for (final v in targets) {
                v
                  ..phase = trf('모델 내려받는 중 {0}%', [(x * 100).round()])
                  ..progress = x
                  ..status = JobStatus.running;
              }
              notifyListeners();
            });
      }
      for (final v in targets) {
        if (_aiCancelled) break;
        await _generateOne(v, opts);
      }
    } catch (e) {
      _log(trf('AI 자막 중단: {0}', [e]));
      for (final v in targets.where((v) => v.status == JobStatus.running)) {
        v
          ..status = JobStatus.failed
          ..message = '$e'
          ..phase = null;
      }
    } finally {
      await _translator?.dispose();
      _translator = null;
      notifyListeners();
    }
  }

  Future<void> _generateOne(VideoItem v, AiOptions opts) async {
    void phase(String text, double p) {
      v
        ..status = JobStatus.running
        ..phase = text
        ..progress = p;
      notifyListeners();
    }

    final storage = services.storage;
    final tmp = p.join(await storage.tempDirectory(),
        'ai_${DateTime.now().microsecondsSinceEpoch}');
    await storage.ensureDirectory(tmp);
    final wav = p.join(tmp, 'audio.wav');
    _log(trf('AI 자막 시작: {0}', [v.fileName]));
    try {
      if (!await storage.exists(v.path)) throw MediaToolException(missingFileMessage);
      // 2. 음성 추출 (전체의 5%)
      if (v.info?.ofType('audio').isEmpty ?? false) {
        throw MediaToolException(tr('음성 트랙이 없습니다.'));
      }
      phase(tr('음성 추출 중'), 0);
      await _tool.runFfmpeg(buildExtractAudioArgs(v.path, wav),
          duration: v.info?.duration, onProgress: (x) => phase(tr('음성 추출 중'), x * 0.05));
      if (_aiCancelled) throw const AiCancelled();

      // 3. 음성인식 (5% ~ 50%)
      phase(tr('음성인식 중'), 0.05);
      final recognizer = _recognizer = services.createRecognizer!();
      if (_aiCancelled) throw const AiCancelled();
      final raw = await recognizer.transcribe(
        wav,
        modelPath: await services.models.pathOf(opts.whisper),
        language: opts.source == undetermined ? 'auto' : whisperCode(opts.source),
        onProgress: (x) => phase(trf('음성인식 중 {0}%', [(x * 100).round()]), 0.05 + x * 0.45),
      );
      final cues = cleanRecognized(raw);
      if (cues.isEmpty) throw MediaToolException(tr('인식된 말이 없습니다.'));
      if (_aiCancelled) throw const AiCancelled();

      // 4. 원어
      final src = opts.source != undetermined
          ? opts.source
          : detectLanguage(cues.map((c) => c.text).join(' '));
      _log(trf('음성인식 완료: {0}줄, 원어 {1}({2})', [cues.length, src.name, src.code]));

      // 5. 파일명_AI.srt (원본)
      await storage.ensureDirectory(outputDirFor(v.path));
      await storage.writeBytes(
          aiSubtitlePath(v.path), encodeText(formatSrt(cues), 'UTF-8').bytes);

      // 6. 언어별 파일명_코드.srt (원어도 따로 만듦) → MKV 에 추가
      final langs = opts.targets.toList();
      for (var i = 0; i < langs.length; i++) {
        final tgt = langs[i];
        final base = 0.5 + 0.5 * i / langs.length;
        final span = 0.5 / langs.length;
        List<Cue> out;
        if (tgt.code == src.code || src == undetermined) {
          out = [for (final c in cues) c.copy()];
        } else {
          if (_translator == null) {
            phase(tr('번역 모델 불러오는 중'), base);
            _translator = services.createTranslator!();
            await _translator!.load(await services.models.folderOf(nllbModel));
          }
          phase(trf('{0} 번역 중', [tgt.name]), base);
          final texts = await translateKeepingFillers(
            [for (final c in cues) c.text.replaceAll('\n', ' ')],
            (rest) => _translator!.translate(
              rest,
              source: src.nllb,
              target: tgt.nllb,
              onProgress: (x) => phase(trf('{0} 번역 중 {1}%', [tgt.name, (x * 100).round()]), base + span * x),
            ),
            src: src.code,
            tgt: tgt.code,
          );
          out = [
            for (var k = 0; k < cues.length; k++)
              Cue(cues[k].start, cues[k].end, cleanRecognized([Cue(cues[k].start, cues[k].end, texts[k])]).firstOrNull?.text ?? texts[k]),
          ];
        }
        final path = languageSubtitlePath(v.path, tgt);
        await storage.writeBytes(path, encodeText(formatSrt(out), 'UTF-8').bytes);
        _addOrReplaceExternal(v, path, tgt, tgt.code == src.code ? tr('AI 인식') : tr('AI 번역'));
        _log(trf('저장: {0}', [p.basename(path)]));
      }
      v
        ..status = JobStatus.ready
        ..phase = null
        ..progress = 0;
      _log(trf('AI 자막 완료: {0} → {1}\\{2}_AI.srt 외 {3}개', [v.fileName, outputFolderName, v.baseName, langs.length]));
    } on AiCancelled {
      v
        ..status = JobStatus.ready
        ..phase = null
        ..progress = 0;
      _aiCancelled = true;
      _log(trf('AI 자막 취소: {0}', [v.fileName]));
    } catch (e) {
      v
        ..status = JobStatus.failed
        ..phase = null
        ..message = e is MediaToolException ? e.message : '$e';
      _log(trf('AI 자막 실패: {0}\n{1}', [v.fileName, v.message]));
    } finally {
      // 작업 폴더째 지운다 (음성인식이 만드는 변환 사본 audio.wav.wav 도 함께)
      try {
        await Directory(tmp).delete(recursive: true);
      } catch (_) {
        await storage.delete(wav);
      }
      notifyListeners();
    }
  }

  void _addOrReplaceExternal(VideoItem v, String path, Language lang, String title) {
    final entry = SubtitleEntry.external(
        path: path, language: lang, charset: 'UTF-8', title: '${lang.name} ($title)');
    final i = v.subtitles.indexWhere((s) => s.path != null && p.equals(s.path!, path));
    if (i >= 0) {
      v.subtitles[i] = entry;
    } else {
      v.subtitles.add(entry);
    }
  }

  // ───────── 인터넷 자막 (5단계) ─────────

  late final List<SubtitleProvider> subtitleProviders =
      services.createSubtitleProviders?.call(() => settings) ?? const [];

  SubtitleProvider? get subtitleProvider =>
      subtitleProviders.isEmpty ? null : subtitleProviders.first;

  /// 파일명으로 검색 조건 추정 + 영상 해시 계산
  Future<SubtitleQuery> guessSubtitleQuery(VideoItem v, List<Language> langs) async {
    final q = guessQuery(v.path, languages: langs);
    String? hash;
    try {
      final s = services.storage;
      final size = await s.fileSize(v.path);
      const chunk = 65536;
      if (size >= chunk) {
        hash = openSubtitlesHash(size, await s.readRange(v.path, 0, chunk),
            await s.readRange(v.path, size - chunk, chunk));
      }
    } catch (_) {}
    return SubtitleQuery(
        title: q.title, year: q.year, season: q.season, episode: q.episode,
        movieHash: hash, languages: langs);
  }

  Future<List<SubtitleSearchResult>> searchSubtitles(SubtitleQuery q) async {
    final p0 = subtitleProvider;
    if (p0 == null) return const [];
    final r = await p0.search(q);
    _log(trf('자막 검색 ({0}): "{1}"{2} → {3}개', [p0.name, q.title, q.season != null ? ' S${q.season}E${q.episode}' : '', r.length]));
    return r;
  }

  /// 고른 자막 받기 → jj_mkv\파일명_언어코드.srt (UTF-8) 저장 → MKV 자막에 추가
  /// 돌려주는 값: 받은 개수
  /// [translateTo] 를 주면 받은 자막을 그 언어로 번역해 함께 추가 (대기열, 기다리지 않음)
  Future<int> downloadSubtitles(VideoItem v, List<SubtitleSearchResult> picks, {Language? translateTo}) async {
    final provider = subtitleProvider;
    if (provider == null) return 0;
    final storage = services.storage;
    final dir = outputDirFor(v.path);
    await storage.ensureDirectory(dir);
    final used = {
      for (final f in await storage.listFiles(dir)) p.basename(f).toLowerCase(),
      for (final s in v.subtitles)
        if (s.path != null) p.basename(s.path!).toLowerCase(),
    };
    var ok = 0;
    var queuedTranslate = false;
    for (final r in picks) {
      try {
        final bytes = await provider.download(r);
        final text = decodeText(bytes, detectCharset(bytes));
        final cues = parseSrt(text);
        if (cues.isEmpty) throw SubtitleProviderException(tr('SRT 형식이 아니거나 비어 있습니다.'));
        final name = nextFreeName('${v.baseName}_${r.language.code}.srt', used);
        used.add(name.toLowerCase());
        final path = p.join(dir, name);
        await storage.writeBytes(path, encodeText(formatSrt(cues), 'UTF-8').bytes);
        final entry = SubtitleEntry.external(
            path: path, language: r.language, charset: 'UTF-8',
            title: '${r.language.name} (${provider.name})');
        v.subtitles.add(entry);
        ok++;
        if (translateTo != null &&
            !queuedTranslate &&
            r.language.code != translateTo.code &&
            !v.subtitles.any((x) => x.enabled && x.language.code == translateTo.code)) {
          queuedTranslate = true; // 한 번만 (여러 언어를 받아도 첫 자막에서 번역)
          unawaited(translateSubtitle(v, entry, {translateTo}));
        }
        _log(trf('자막 받음: {0}  ← {1}', [name, r.release]));
      } catch (e) {
        _log(trf('자막 받기 실패: {0}\n{1}', [r.release, e]));
        if (e is SubtitleProviderException && e.quotaExceeded) break;
      }
      notifyListeners();
    }
    if (v.status == JobStatus.done && ok > 0) v.status = JobStatus.ready;
    notifyListeners();
    return ok;
  }

  // ───────── 자막 번역 (있는 자막 → 다른 언어) ─────────

  /// 자막 [s] 를 [targets] 언어로 번역해 jj_mkv\파일명_언어코드.srt 로 저장하고 MKV 자막에 추가.
  /// 원어는 자막의 언어 태그, 없으면 글자로 추정. 이 PC 안에서 NLLB 로 번역 (다른 작업 중이면 대기열로).
  Future<void> translateSubtitle(VideoItem v, SubtitleEntry s, Set<Language> targets) async {
    if (services.createTranslator == null || targets.isEmpty) return;
    if (busy) v.phase = tr('자막 번역 대기 중');
    notifyListeners();
    return _enqueue(trf('자막 번역: {0} → {1}', [v.fileName, targets.map((t) => t.code).join('/')]),
        () => _runTranslate(v, s, targets));
  }

  Future<void> _runTranslate(VideoItem v, SubtitleEntry s, Set<Language> targets) async {
    _aiCancelled = false;
    void phase(String t, double p) {
      v
        ..status = JobStatus.running
        ..phase = t
        ..progress = p;
      notifyListeners();
    }

    Translator? translator;
    try {
      phase(tr('자막 불러오는 중'), 0);
      final cues = await loadCues(v, s);
      if (cues.isEmpty) throw MediaToolException(tr('자막이 비어 있습니다.'));
      final src = s.language != undetermined
          ? s.language
          : detectLanguage(cues.take(200).map((c) => c.text).join(' '));
      if (src == undetermined) throw MediaToolException(tr('자막 언어를 알 수 없습니다. 자막 줄에서 언어를 먼저 고르세요.'));
      final langs = targets.where((t) => t.code != src.code).toList();
      if (langs.isEmpty) throw MediaToolException(trf('원어({0})와 같은 언어로는 번역하지 않습니다.', [src.name]));

      if (!await services.models.isInstalled(nllbModel)) {
        _log(trf('번역 모델 내려받는 중: {0}', [nllbModel.sizeLabel]));
        await services.models.download(nllbModel,
            isCancelled: () => _aiCancelled, onProgress: (x) => phase(trf('번역 모델 내려받는 중 {0}%', [(x * 100).round()]), x * 0.2));
      }
      phase(tr('번역 모델 불러오는 중'), 0.2);
      translator = _translator = services.createTranslator!();
      await translator.load(await services.models.folderOf(nllbModel));

      final dir = outputDirFor(v.path);
      await services.storage.ensureDirectory(dir);
      final used = {
        for (final f in await services.storage.listFiles(dir)) p.basename(f).toLowerCase(),
        for (final e in v.subtitles)
          if (e.path != null) p.basename(e.path!).toLowerCase(),
      };
      for (var i = 0; i < langs.length; i++) {
        if (_aiCancelled) throw const AiCancelled();
        final tgt = langs[i];
        final base = 0.25 + 0.75 * i / langs.length;
        final span = 0.75 / langs.length;
        final texts = await translateKeepingFillers(
          [for (final c in cues) c.text.replaceAll('\n', ' ')],
          (rest) => translator!.translate(
            rest,
            source: src.nllb,
            target: tgt.nllb,
            onProgress: (x) => phase(trf('{0} → {1} 번역 {2}%', [src.name, tgt.name, (x * 100).round()]), base + span * x),
          ),
          src: src.code,
          tgt: tgt.code,
        );
        final out = [
          for (var k = 0; k < cues.length; k++)
            Cue(cues[k].start, cues[k].end,
                cleanRecognized([Cue(cues[k].start, cues[k].end, texts[k])]).firstOrNull?.text ?? texts[k]),
        ];
        final name = nextFreeName('${v.baseName}_${tgt.code}.srt', used);
        used.add(name.toLowerCase());
        final path = p.join(dir, name);
        await services.storage.writeBytes(path, encodeText(formatSrt(out), 'UTF-8').bytes);
        v.subtitles.add(SubtitleEntry.external(
            path: path, language: tgt, charset: 'UTF-8', title: trf('{0} (AI 번역 ← {1})', [tgt.name, src.code])));
        _log(trf('자막 번역 저장: {0} ({1} → {2}, {3}줄)', [name, src.name, tgt.name, cues.length]));
      }
      v
        ..status = JobStatus.ready
        ..phase = null
        ..progress = 0;
    } on AiCancelled {
      v
        ..status = JobStatus.ready
        ..phase = null;
      _log(trf('자막 번역 취소: {0}', [v.fileName]));
    } catch (e) {
      v
        ..status = JobStatus.failed
        ..phase = null
        ..message = e is MediaToolException ? e.message : '$e';
      _log(trf('자막 번역 실패: {0}\n{1}', [v.fileName, v.message]));
    } finally {
      await translator?.dispose();
      _translator = null;
      notifyListeners();
    }
  }

  // ───────── 동영상 재생 ─────────

  /// 재생 준비. 확장자에 외부 프로그램이 지정되어 있으면 그것으로 열고 null,
  /// 아니면 내장 플레이어용 (목록, 시작 위치).
  /// [keepOrder]: 여러 개를 줄 때 이름순으로 다시 정렬하지 않고 준 순서대로 재생
  Future<(List<String>, int)?> preparePlayback(List<String> files, {bool keepOrder = false}) async {
    final videos = files.where(isVideoFile).toList();
    if (videos.isEmpty) return null;
    final ext = p.extension(videos.first).replaceFirst('.', '').toLowerCase();
    final program = settings.externalPlayers[ext];
    if (program != null && program.isNotEmpty) {
      await services.shell.openExternal(program, videos);
      _log(trf('외부 프로그램으로 재생: {0} ← {1}개', [program == 'system' ? tr('기본 연결 프로그램') : p.basename(program), videos.length]));
      return null;
    }
    if (videos.length > 1) {
      if (!keepOrder) videos.sort((a, b) => naturalCompare(p.basename(a), p.basename(b)));
      return (videos, 0);
    }
    final siblings = await services.storage.listFiles(p.dirname(videos.first));
    return buildPlaylist(videos.first, siblings, settings.playlistMode);
  }

  /// 재생 중 고를 수 있는 외부 자막: 같은 폴더의 자막 + jj_mkv 안의 파일명_*.srt
  /// 플레이어에 넘길 자막 파일 (Android). Android 의 mpv 는 문자셋 변환 (iconv) 이 없고 SAMI (SMI) 도 열지 못하므로
  /// UTF-8 이 아닌 자막은 UTF-8 사본으로, SMI 는 SRT 로 바꿔 임시 폴더에 만든다. 그 밖에는 그대로.
  Future<String> playableSubtitle(String path) async {
    if (!Platform.isAndroid) return path;
    try {
      final storage = services.storage;
      final ext = p.extension(path).toLowerCase();
      final isSami = ext == '.smi' || ext == '.sami';
      final cs = detectCharset(Uint8List.fromList(await storage.readHead(path, 64 * 1024)));
      if (cs == 'UTF-8' && !isSami) return path;
      final tmp = await storage.tempDirectory();
      final key = path.hashCode.toUnsigned(32);
      var src = path;
      if (cs != 'UTF-8') {
        src = p.join(tmp, 'play_${key}_${p.basename(path)}');
        await storage.writeBytes(src, utf8.encode(decodeText(await storage.readBytes(path), cs)));
      }
      if (!isSami) return src;
      final srt = p.join(tmp, 'play_$key.srt');
      await _tool.runFfmpeg(buildToSrtArgs(input: src, output: srt));
      return srt;
    } catch (_) {
      return path;
    }
  }

  Future<List<String>> externalSubtitlesFor(String video) async {
    final out = <String>[];
    final storage = services.storage;
    out.addAll(findSiblingSubtitles(video, await storage.listFiles(p.dirname(video))).map((d) => d.path));
    final base = p.basenameWithoutExtension(video).toLowerCase();
    for (final f in await storage.listFiles(outputDirFor(video))) {
      final n = p.basename(f).toLowerCase();
      if (n.startsWith('${base}_') && subtitleExtensions.contains(p.extension(n).replaceFirst('.', ''))) {
        out.add(f);
      }
    }
    return out;
  }

  // ───────── MKV 만들기 ─────────

  /// 목록의 MKV 만들기 (다른 작업 중이면 대기열로)
  Future<void> buildAll() async {
    if (ffmpegVersion == null) return;
    return _enqueue(tr('MKV 만들기'), _runBuildAll);
  }

  /// 고른 동영상만 MKV 로 (이미 만든 것도 다시 만든다 - 자막이 바뀌었을 수 있으므로)
  Future<void> buildVideos(List<VideoItem> targets) async {
    if (ffmpegVersion == null || targets.isEmpty) return;
    final label = targets.length == 1 ? trf('MKV 만들기: {0}', [targets.first.fileName]) : trf('MKV 만들기 {0}개', [targets.length]);
    return _enqueue(label, () => _runBuildAll(targets));
  }

  Future<void> _runBuildAll([List<VideoItem>? only]) async {
    _buildCancelled = false;
    try {
      // 동시에 [maxParallelJobs] 개씩 (0 = 무제한). 작업자가 목록에서 하나씩 가져가 처리한다.
      final queue = only?.where(videos.contains).toList() ??
          videos.where((v) => v.status != JobStatus.done).toList();
      if (queue.isEmpty) return;
      final limit = settings.maxParallelJobs <= 0 ? queue.length : settings.maxParallelJobs;
      if (queue.length > 1) _log(trf('MKV 만들기: {0}개, 동시에 {1}개씩', [queue.length, limit.clamp(1, queue.length)]));
      var next = 0;
      Future<void> worker() async {
        while (!_buildCancelled && next < queue.length) {
          await _build(queue[next++]);
        }
      }

      await Future.wait([for (var i = 0; i < limit.clamp(1, queue.length); i++) worker()]);
      // 이번에 만든 것 기준 (목록의 다른 동영상은 세지 않음)
      final ok = queue.where((v) => v.status == JobStatus.done).length;
      _log(trf('완료: 성공 {0} / 전체 {1}', [ok, queue.length]));
    } finally {
      notifyListeners();
    }
  }

  Future<void> _build(VideoItem v) async {
    final out = outputMkvPath(v.path);
    v
      ..status = JobStatus.running
      ..progress = 0
      ..message = null;
    notifyListeners();
    _log(trf('시작: {0} → {1}\\{2}' '{3}', [v.fileName, outputFolderName, p.basename(out), encode.reencode ? ' [${encode.codec.label} · ${encode.resolution.label} · ${encode.quality.label}${encode.adjusts ? ' · ${encode.adjustSummary}' : ''}]' : '']));
    final copies = <SubtitleEntry, String>{};
    var started = false; // FFmpeg 가 출력 파일을 쓰기 시작했는지
    try {
      if (!await services.storage.exists(v.path)) throw MediaToolException(missingFileMessage);
      // Android 의 FFmpeg (ffmpeg-kit) 에는 AV1 디코더가 없어 다시 인코딩할 수 없다 (원본 유지는 된다)
      final vcodec = v.info?.ofType('video').firstOrNull?.codec;
      if (Platform.isAndroid && encode.reencode && vcodec == 'av1') {
        throw MediaToolException(tr('AV1 영상은 이 기기에서 다시 인코딩할 수 없습니다. ' '코덱을 "원본 유지" 로 바꿔 MKV 를 만드세요. (PC 판은 됩니다)'));
      }
      await services.storage.ensureDirectory(outputDirFor(v.path));
      for (final s in v.subtitles.where((s) => s.enabled)) {
        final c = await _utf8Copy(s);
        if (c != null) copies[s] = c;
      }
      started = true;
      await _tool.runFfmpeg(
        buildMuxArgs(v, out, encode: encode, encoders: encoders, utf8Copies: copies),
        duration: v.info?.duration,
        onProgress: (x) {
          v.progress = x;
          notifyListeners();
        },
      );
      v
        ..status = JobStatus.done
        ..outputPath = out;
      _log(trf('성공: {0}', [p.basename(out)]));
    } catch (e) {
      final msg = e is MediaToolException
          ? e.message
          : e is ArgumentError
              ? '${e.message}'
              : '$e';
      v
        ..status = JobStatus.failed
        ..message = msg;
      _log(trf('실패: {0}\n{1}', [v.fileName, msg]));
      // 만들다 만 파일은 지운다 (0 바이트 MKV 가 남지 않도록). 시작 전에 실패했으면 전에 만든 MKV 는 그대로 둔다.
      if (started) {
        try {
          await services.storage.delete(out);
        } catch (_) {}
      }
    } finally {
      for (final c in copies.values) {
        try {
          await services.storage.delete(c);
        } catch (_) {}
      }
    }
    notifyListeners();
  }

  bool _buildCancelled = false;

  /// 목록에 넣은 뒤 파일이 옮겨지거나 지워졌을 때
  static String get missingFileMessage => tr('동영상 파일이 없습니다 (옮겨졌거나 지워졌습니다). 목록에서 빼고 다시 추가하세요.');

  /// 지금 작업 중단 + 대기 중인 작업 모두 비우기
  /// 지금 음성인식 (취소하면 멈춘다)
  SpeechRecognizer? _recognizer;

  void cancel() {
    _recognizer?.cancel();
    if (pendingJobs.isNotEmpty) _log(trf('대기 중인 작업 {0}개 취소', [pendingJobs.length]));
    pendingJobs.clear();
    for (final (_, done) in _pendingRuns) {
      done.complete();
    }
    _pendingRuns.clear();
    for (final v in videos) {
      if (v.status != JobStatus.running) v.phase = null;
    }
    _buildCancelled = true;
    _aiCancelled = true;
    _translator?.cancel();
    _tool.cancel();
  }

  /// 완료·실패 상태를 초기화해 다시 만들 수 있게 한다.
  void resetStatus(VideoItem v) {
    if (v.status == JobStatus.running) return;
    v
      ..status = JobStatus.ready
      ..progress = 0
      ..message = null;
    notifyListeners();
  }

  /// 작업 기록에 한 줄 남기기 (앱의 다른 부분에서 알릴 것이 있을 때)
  void note(String msg) => _log(msg);

  /// 작업 기록을 파일에도 남길 곳 (설정 폴더의 app.log). 프로그램이 갑자기 꺼져도 무슨 일이 있었는지 볼 수 있게.
  /// 2MB 를 넘으면 app.log.1 로 옮기고 새로 시작한다.
  String? logFile;

  void _log(String msg) {
    final t = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    logs.add('[${two(t.hour)}:${two(t.minute)}:${two(t.second)}] $msg');
    if (logs.length > 500) logs.removeAt(0);
    _appendLogFile('${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}:${two(t.second)}  $msg');
    notifyListeners();
  }

  void _appendLogFile(String line) {
    final path = logFile;
    if (path == null) return;
    try {
      final f = File(path);
      if (f.existsSync() && f.lengthSync() > 2 * 1024 * 1024) f.renameSync('$path.1');
      f.writeAsStringSync('$line\n', mode: FileMode.append, flush: true);
    } catch (_) {}
  }
}
