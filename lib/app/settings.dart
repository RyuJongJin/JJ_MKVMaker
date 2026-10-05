import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../core/download_detect.dart';
import '../core/encode_options.dart';
import '../core/playlist.dart';
import '../services/app_shell.dart' show appIconOf;

/// MKV 세부 정보의 이동 버튼 하나: 표시 이름 · 옮길 폴더
class MoveTarget {
  final String name;
  final String dir;
  const MoveTarget(this.name, this.dir);

  MoveTarget copyWith({String? name, String? dir}) => MoveTarget(name ?? this.name, dir ?? this.dir);

  Map<String, Object?> toJson() => {'name': name, 'dir': dir};

  factory MoveTarget.fromJson(Map<Object?, Object?> j) =>
      MoveTarget((j['name'] as String?)?.trim().isNotEmpty == true ? j['name'] as String : '이동', j['dir'] as String);

  @override
  bool operator ==(Object other) => other is MoveTarget && other.name == name && other.dir == dir;

  @override
  int get hashCode => Object.hash(name, dir);
}

/// 실시간 동기화 한 쌍 (lsyncd 처럼: 원본 폴더를 지켜보다가 바뀌면 대상 폴더에 맞춘다)
class LiveSyncPair {
  final String source;
  final String target;

  /// 'builtin' · 'rsync' · 'robocopy' (CopyMethod 이름)
  final String method;

  /// 원본에 없는 것을 대상에서 지우기 (rsync --delete, robocopy /PURGE)
  final bool delete;
  final bool enabled;

  /// 동작 시간 (cron 줄들, core/cron_window.dart). 비어 있으면 계속 (앱이 켜져 있는 동안 늘)
  final List<String> schedule;
  const LiveSyncPair(this.source, this.target,
      {this.method = 'builtin', this.delete = false, this.enabled = true, this.schedule = const []});

  LiveSyncPair copyWith({String? method, bool? delete, bool? enabled, List<String>? schedule}) => LiveSyncPair(source, target,
      method: method ?? this.method,
      delete: delete ?? this.delete,
      enabled: enabled ?? this.enabled,
      schedule: schedule ?? this.schedule);

  Map<String, Object?> toJson() =>
      {'source': source, 'target': target, 'method': method, 'delete': delete, 'enabled': enabled, 'schedule': schedule};

  factory LiveSyncPair.fromJson(Map<Object?, Object?> j) => LiveSyncPair(
        j['source'] as String,
        j['target'] as String,
        method: const ['rsync', 'robocopy'].contains(j['method']) ? j['method'] as String : 'builtin',
        delete: j['delete'] == true,
        enabled: j['enabled'] != false,
        schedule: [for (final x in (j['schedule'] as List?) ?? const []) '$x'],
      );
}

/// 복사 · 이동 기억 (모니터링 > 복사 · rsync): 같은 원본 → 대상을 다시 복사하면 이 옵션을 쓴다. 언제든 [실행] 으로 다시.
class CopyTask {
  final String id;
  final List<String> sources;
  final String dest;
  final bool move;

  /// 폴더 "안의 것" 을 대상에 맞추기 (lsync 에서 옮겨 온 것: 원본/ → 대상/)
  final bool contents;

  /// CopyMethod 이름 · 그 방법의 옵션 · 한 번에 · 속도 제한 (KB/s)
  final String method;
  final String options;
  final bool once;
  final int bandwidthKBps;

  /// 마지막 실행: 시각 (ISO) · 결과 ('done' · 'failed' · 'cancelled' · '') · 글 · 파일 수
  final String lastRun;
  final String lastResult;
  final String lastMessage;
  final int lastFiles;

  const CopyTask({
    required this.id,
    required this.sources,
    required this.dest,
    this.move = false,
    this.contents = false,
    this.method = 'builtin',
    this.options = '',
    this.once = false,
    this.bandwidthKBps = 0,
    this.lastRun = '',
    this.lastResult = '',
    this.lastMessage = '',
    this.lastFiles = 0,
  });

  /// 같은 복사인지 (원본들 · 대상 · 이동)
  String get key => '${move ? 'M' : contents ? 'S' : 'C'}|${[...sources]..sort()}|$dest';

  CopyTask copyWith({
    String? method,
    String? options,
    bool? once,
    int? bandwidthKBps,
    bool? move,
    String? lastRun,
    String? lastResult,
    String? lastMessage,
    int? lastFiles,
  }) =>
      CopyTask(
        id: id,
        sources: sources,
        dest: dest,
        move: move ?? this.move,
        contents: contents,
        method: method ?? this.method,
        options: options ?? this.options,
        once: once ?? this.once,
        bandwidthKBps: bandwidthKBps ?? this.bandwidthKBps,
        lastRun: lastRun ?? this.lastRun,
        lastResult: lastResult ?? this.lastResult,
        lastMessage: lastMessage ?? this.lastMessage,
        lastFiles: lastFiles ?? this.lastFiles,
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'sources': sources,
        'dest': dest,
        'move': move,
        'contents': contents,
        'method': method,
        'options': options,
        'once': once,
        'bandwidthKBps': bandwidthKBps,
        'lastRun': lastRun,
        'lastResult': lastResult,
        'lastMessage': lastMessage,
        'lastFiles': lastFiles,
      };

  factory CopyTask.fromJson(Map<Object?, Object?> j) => CopyTask(
        id: '${j['id']}',
        sources: [for (final x in (j['sources'] as List?) ?? const []) '$x'],
        dest: '${j['dest']}',
        move: j['move'] == true,
        contents: j['contents'] == true,
        method: const ['rsync', 'robocopy'].contains(j['method']) ? j['method'] as String : 'builtin',
        options: j['options'] as String? ?? '',
        once: j['once'] == true,
        bandwidthKBps: (j['bandwidthKBps'] as num?)?.toInt() ?? 0,
        lastRun: j['lastRun'] as String? ?? '',
        lastResult: j['lastResult'] as String? ?? '',
        lastMessage: j['lastMessage'] as String? ?? '',
        lastFiles: (j['lastFiles'] as num?)?.toInt() ?? 0,
      );
}

/// 환경 설정 (settings.json 에 저장)
class AppSettings {
  /// MKV·자막 저장 위치. null 이면 동영상이 있는 폴더 아래 jj_mkv
  String? mkvOutputRoot;

  /// MKV 세부 정보 오른쪽 아래의 이동 버튼들 (표시 이름 · 폴더). 세 번 누르기는 첫 번째 버튼의 폴더로.
  /// 비어 있으면 [이동] 을 처음 누를 때 폴더를 골라 하나 만든다.
  List<MoveTarget> moveTargets = [];

  /// 웹 브라우저에서 YouTube 광고 자동 건너뛰기 (건너뛰기 버튼 누르기 · 건너뛸 수 없는 광고는 빨리 감기 · 소리 끄기)
  bool youtubeAdSkip = true;

  /// YouTube 페이지의 광고 배너 · 광고 영역 숨기기
  bool youtubeAdHide = true;

  /// 다운로드 위치 (아래에 jj_yt-dlp, jj_aria2 생성). null 이면 프로그램 폴더
  String? downloadRoot;

  /// Ctrl+C 로 복사한 주소를 자동으로 다운로드
  bool clipboardWatch = true;

  /// 최소화하면 작업 표시줄 대신 트레이로
  bool minimizeToTray = true;

  /// 종료 (창 X · 종료 버튼) 를 눌렀을 때:
  /// 'background' 창만 숨기고 다운로드 · 변환 계속 / 'quit' 묻지 않고 모두 종료 / 'ask' 매번 고르기
  String closeAction = 'background';

  /// 창 보이기 단축키 (예: Ctrl+Shift+X)
  String showHotkey = 'Ctrl+Shift+X';

  /// AI 자막: 매번 설정 창을 띄울지 (끄면 마지막 설정으로 바로 시작)
  bool askAiOptions = true;

  /// 다운로드가 끝난 동영상을 편집 목록(MKV 만들기)에 자동으로 추가
  bool addFinishedDownloads = true;

  /// OpenSubtitles (인터넷 자막 검색) - 키는 필수, 아이디·비밀번호는 선택 (받기 횟수 늘어남)
  String openSubtitlesKey = '';
  String openSubtitlesUser = '';
  String openSubtitlesPassword = '';

  /// YouTube 받을 형식 · 화질 (기본: MP4 최고 화질)
  YtContainer ytContainer = YtContainer.mp4;
  YtQuality ytQuality = YtQuality.best;

  /// 재생목록 주소면 목록 전체를 받기
  bool ytExpandPlaylists = true;

  /// YouTube 로봇 확인 대응: 쿠키를 가져올 브라우저 (빈 값 = 사용 안 함) 또는 cookies.txt 경로
  String ytCookiesBrowser = internalBrowserCookies; // 기본: 앱 안 브라우저 로그인 사용
  String ytCookiesFile = '';

  /// 동시에 받는 다운로드 수 (0 = 무제한)
  int maxParallelDownloads = 3;

  /// 동시에 만드는 MKV 수 (0 = 무제한)
  int maxParallelJobs = 5;

  /// 메인 화면 아래 작업 기록 창 보이기
  bool showLog = true;

  /// 처음 화면: 'home' = 지금처럼 MKV 화면 (기본), 'browser' = 웹 브라우저 ([homeUrl]), 'files' = 파일 탐색기
  String startScreen = 'home';

  /// 화면 (글자 · 버튼) 크기 배율. [uiScale] 은 지금 크기 (위쪽 막대의 − · + 로 바꿈),
  /// [uiScaleDefault] 는 기본 크기 (환경 설정에서 정함, 가운데 숫자를 누르면 이 크기로 돌아감)
  double uiScale = 1.0;
  double uiScaleDefault = 1.0;
  static const double uiScaleMin = 0.7, uiScaleMax = 1.6;
  static double clampUiScale(num? v) =>
      ((v ?? 1.0).toDouble().clamp(uiScaleMin, uiScaleMax) * 20).round() / 20;

  /// 탐색기에서 동영상을 열었을 때 (더블클릭 · 연결 프로그램): 'play' 바로 재생 / 'add' 편집 목록에 추가
  String openFileAction = 'play';

  /// Android 화면 방향: 'landscape' 가로 고정 (기본) / 'portrait' 세로 고정 / 'auto' 기기 방향 따라
  String screenOrientation = 'landscape';

  /// 화면 언어 (ko · en · ja · zh-Hans, 또는 더한 언어)
  String uiLanguage = 'ko';

  /// 앱 아이콘 (appIconIds 중 하나: 'yellow' 기본 · 'black' · 'film_jj' · 'film' · 'blue')
  String appIcon = 'yellow';

  /// 더한 화면 언어 (AI 로 자동 번역한 사전이 설정 폴더 l10n 에 있음)
  List<String> uiLanguagesAdded = [];

  /// 프로그램이 켜져 있을 때 탐색기에서 연 동영상 재생: 'same' 켜져 있는 창에서 / 'new' 새 재생 창
  String openFileWindow = 'same';
  String homeUrl = 'https://www.youtube.com/';

  /// 앱 안 브라우저 엔진: 'edge' (WebView2, 기본). 'chrome' 은 내려받아 연결 (준비 중)
  String browserEngine = 'edge';

  /// "외부 브라우저로 열기" 에 쓸 브라우저: 'system' · 'chrome' · 'firefox' · 'edge' · 'whale'
  String externalBrowser = 'system';

  /// 앱 안 브라우저: 다른 언어로 된 웹 페이지를 화면 언어 ([uiLanguage]) 로 자동 번역 (Google 번역)
  bool webTranslate = false;

  /// 앱 안 브라우저: 페이지의 JavaScript 실행 (끄면 스크립트 없이 글 · 그림만)
  bool webJavaScript = true;

  // ── 파일 탐색기 (X-plore 참고) ──
  /// 창: 'dual' 두 창 (기본) · 'split' 왼쪽 폴더 트리 + 오른쪽 그 폴더의 파일 목록 · 'single' 한 창
  String explorerLayout = 'dual';

  /// 누르기: 'select' 한 번 = 선택 · 두 번 = 열기 (기본) / 'open' 한 번 = 바로 열기.
  /// 길게 누르기 · 오른쪽 클릭은 늘 기능 메뉴.
  String explorerClick = 'select';

  /// 모양: 'xplore' (기본) · 'windows' Windows 탐색기 · 'totalcmd' Total Commander
  String explorerStyle = 'xplore';

  /// 두 창 배치: 'auto' 화면 모양 따라 (가로로 넓으면 좌우, 세로로 길면 위아래) · 'side' 좌우 · 'stacked' 위아래
  String explorerOrientation = 'auto';

  /// 기능 버튼 줄: 'middle' 두 창 사이 (기본) · 'edge' 오른쪽 (위아래 배치면 아래) 끝 · 'hidden' 숨김
  String explorerToolbar = 'middle';

  /// 기능 버튼 줄에 보일 버튼과 순서 (ExplorerButton 이름). 비어 있으면 기본 구성.
  List<String> explorerButtons = [];

  /// 정렬 · 숨긴 항목
  String explorerSort = 'name';
  bool explorerSortDesc = false;
  bool explorerShowHidden = false;

  // ── 복사 · 이동 (파일 탐색기) · rsync · lsync (Rsync 화면) ──
  /// 파일 탐색기의 복사 · 이동 방법: 'builtin' 현재 방식 (기본) · 'robocopy' (Windows). 파일만 고를 때 / 폴더가 들어 있을 때.
  /// rsync 는 Rsync 화면에서 따로 (파일 탐색기에서는 쓰지 않음)
  String copyMethodFile = 'builtin';
  String copyMethodFolder = 'builtin';
  String rsyncOptions = '-avPog';
  String robocopyOptions = '/E /COPY:DAT /DCOPY:T /R:2 /W:2';

  /// 여러 개를 고르면: 'each' 항목마다 따로 실행 (기본) · 'once' 한 번에 (rsync)
  String copyRunMode = 'each';

  /// 속도 제한 KB/s (0 = 제한 없음). 모든 방법에 (rsync --bwlimit, 현재 방식은 앱이 조절, robocopy 는 /IPG 로 비슷하게)
  int copyBandwidthKBps = 0;

  /// rsync 가져오기: 'download' 앱에 들어 있는 것 (기본, Windows 는 없으면 내려받기) · 'custom' 직접 지정한 실행 파일 ([rsyncPath])
  String rsyncSource = 'download';
  String rsyncPath = '';

  /// 실시간 동기화 (lsyncd 처럼)
  List<LiveSyncPair> liveSyncPairs = [];

  /// 모니터링 (Rsync 화면 가운데 [모니터링]): 실행한 rsync 를 기억해 다시 실행 · 옵션 고치기 · lsync 로 옮기기
  List<CopyTask> copyTasks = [];

  /// Rsync 화면에서 마지막으로 연 폴더 (왼쪽 · 오른쪽)
  List<String> rsyncPaths = [];

  /// 실시간 동기화 확인 간격 (초). Windows 는 바뀌면 바로, 그 밖은 이 간격으로 살핀다.
  int liveSyncIntervalSec = 30;

  /// 백그라운드로 실행 (Android): 켜면 ← 로 닫거나 최근 앱에서 밀어도 동기화 · MKV 만들기 · 다운로드를 계속한다 (알림에 표시).
  /// 끄면 지금처럼 닫을 때 끝난다. Windows 는 [closeAction] 'background' 가 같은 뜻 ([backgroundRun]).
  bool runInBackground = false;

  /// 앱을 다시 켤 때 실시간 동기화: 'auto' 바로 시작 / 'ask' 골라서 시작 / 'off' 시작 안 함 (모니터링에서 시작)
  String liveSyncOnStart = 'auto';

  /// 백그라운드로 실행 (설정 화면의 체크 하나). Windows: 창 ✕ 를 누르면 트레이로 (끄면 종료), Android: [runInBackground]
  bool get backgroundRun => Platform.isWindows ? closeAction == 'background' : runInBackground;
  set backgroundRun(bool v) {
    if (Platform.isWindows) {
      closeAction = v ? 'background' : 'quit';
    } else {
      runInBackground = v;
    }
  }

  /// 마지막으로 연 폴더 (왼쪽 · 오른쪽 창)
  List<String> explorerPaths = [];

  /// 최근에 연 폴더 (내역, 최신이 앞)
  List<String> explorerHistory = [];

  /// 앱 안 브라우저의 데이터 폴더 (로그인 · 쿠키). 실행 중에 정해지며 저장하지 않음
  String webViewDataDir = '';

  /// 시작할 때 새 버전 확인 (하루 한 번)
  bool autoCheckUpdates = true;
  String lastUpdateCheck = '';

  /// [lastUpdateCheck] 를 한 버전 (같은 설정 파일을 쓰는 다른 버전이 확인했으면 다시 확인)
  String lastUpdateCheckVersion = '';

  /// "이 버전 건너뛰기" 한 버전
  String skippedVersion = '';

  /// 동영상 하나를 재생할 때 재생 목록 (기본: 같은 시리즈)
  PlaylistMode playlistMode = PlaylistMode.series;

  /// 확장자별 재생 프로그램 (없으면 내장 플레이어): 'system' 또는 실행 파일 경로
  Map<String, String> externalPlayers = {};

  /// 마지막 인코딩 설정
  EncodeSettings encode = const EncodeSettings();

  /// 마지막 AI 자막 설정
  String aiSource = 'und';
  List<String> aiTargets = ['ko', 'en', 'ja'];
  String aiWhisper = 'whisper-base';

  AppSettings();

  Map<String, Object?> toJson() => {
        'mkvOutputRoot': mkvOutputRoot,
        'moveTargets': [for (final t in moveTargets) t.toJson()],
        'youtubeAdSkip': youtubeAdSkip,
        'youtubeAdHide': youtubeAdHide,
        'downloadRoot': downloadRoot,
        'clipboardWatch': clipboardWatch,
        'minimizeToTray': minimizeToTray,
        'closeAction': closeAction,
        'showHotkey': showHotkey,
        'askAiOptions': askAiOptions,
        'addFinishedDownloads': addFinishedDownloads,
        'openSubtitlesKey': openSubtitlesKey,
        'openSubtitlesUser': openSubtitlesUser,
        'openSubtitlesPassword': openSubtitlesPassword,
        'ytContainer': ytContainer.name,
        'ytQuality': ytQuality.name,
        'ytExpandPlaylists': ytExpandPlaylists,
        'ytCookiesBrowser': ytCookiesBrowser,
        'ytCookiesFile': ytCookiesFile,
        'maxParallelDownloads': maxParallelDownloads,
        'maxParallelJobs': maxParallelJobs,
        'showLog': showLog,
        'startScreen': startScreen,
        'uiScale': uiScale,
        'uiScaleDefault': uiScaleDefault,
        'openFileAction': openFileAction,
        'screenOrientation': screenOrientation,
        'uiLanguage': uiLanguage,
        'appIcon': appIcon,
        'uiLanguagesAdded': uiLanguagesAdded,
        'openFileWindow': openFileWindow,
        'homeUrl': homeUrl,
        'browserEngine': browserEngine,
        'externalBrowser': externalBrowser,
        'webTranslate': webTranslate,
        'webJavaScript': webJavaScript,
        'explorerLayout': explorerLayout,
        'explorerClick': explorerClick,
        'explorerStyle': explorerStyle,
        'explorerOrientation': explorerOrientation,
        'explorerToolbar': explorerToolbar,
        'explorerButtons': explorerButtons,
        'explorerSort': explorerSort,
        'explorerSortDesc': explorerSortDesc,
        'explorerShowHidden': explorerShowHidden,
        'explorerPaths': explorerPaths,
        'copyMethodFile': copyMethodFile,
        'copyMethodFolder': copyMethodFolder,
        'rsyncPaths': rsyncPaths,
        'rsyncOptions': rsyncOptions,
        'robocopyOptions': robocopyOptions,
        'copyRunMode': copyRunMode,
        'copyBandwidthKBps': copyBandwidthKBps,
        'rsyncSource': rsyncSource,
        'rsyncPath': rsyncPath,
        'liveSyncPairs': [for (final x in liveSyncPairs) x.toJson()],
        'liveSyncIntervalSec': liveSyncIntervalSec,
        'runInBackground': runInBackground,
        'liveSyncOnStart': liveSyncOnStart,
        'copyTasks': [for (final x in copyTasks) x.toJson()],
        'explorerHistory': explorerHistory,
        'autoCheckUpdates': autoCheckUpdates,
        'lastUpdateCheck': lastUpdateCheck,
        'lastUpdateCheckVersion': lastUpdateCheckVersion,
        'skippedVersion': skippedVersion,
        'playlistMode': playlistMode.name,
        'externalPlayers': externalPlayers,
        'encode': {
          'codec': encode.codec.name,
          'resolution': encode.resolution.name,
          'quality': encode.quality.name,
          'frame': encode.frame.name,
          'fit': encode.fit.name,
          'rotate': encode.rotate.name,
          'brightness': encode.brightness,
          'contrast': encode.contrast,
          'saturation': encode.saturation,
          'temperature': encode.temperature,
        },
        'aiSource': aiSource,
        'aiTargets': aiTargets,
        'aiWhisper': aiWhisper,
      };

  /// 파일 탐색기의 복사 방법 (rsync 는 Rsync 화면으로 옮겨 예전 값 rsync 도 현재 방식으로)
  static String _method(Object? v) => v == 'robocopy' ? 'robocopy' : 'builtin';

  /// 색 보정 값 (-100 ~ 100)
  static int _adj(Object? v) => ((v as num?)?.round() ?? 0).clamp(-100, 100);

  factory AppSettings.fromJson(Map<String, dynamic> j) {
    T pick<T extends Enum>(List<T> values, Object? name, T fallback) =>
        values.firstWhere((v) => v.name == name, orElse: () => fallback);
    final e = (j['encode'] as Map?) ?? const {};
    return AppSettings()
      ..mkvOutputRoot = j['mkvOutputRoot'] as String?
      ..moveTargets = [
        for (final x in (j['moveTargets'] as List?) ?? const [])
          if (x is Map && x['dir'] is String) MoveTarget.fromJson(x),
        // 예전 판의 이동 폴더 하나 → "이동" 버튼으로
        if (j['moveTargets'] == null && j['moveTargetDir'] is String) MoveTarget('이동', j['moveTargetDir'] as String),
      ]
      ..youtubeAdSkip = j['youtubeAdSkip'] as bool? ?? true
      ..youtubeAdHide = j['youtubeAdHide'] as bool? ?? true
      ..downloadRoot = j['downloadRoot'] as String?
      ..clipboardWatch = j['clipboardWatch'] as bool? ?? true
      ..minimizeToTray = j['minimizeToTray'] as bool? ?? true
      ..closeAction = const ['background', 'quit', 'ask'].contains(j['closeAction']) ? j['closeAction'] as String : 'background'
      ..showHotkey = j['showHotkey'] as String? ?? 'Ctrl+Shift+X'
      ..askAiOptions = j['askAiOptions'] as bool? ?? true
      ..addFinishedDownloads = j['addFinishedDownloads'] as bool? ?? true
      ..openSubtitlesKey = j['openSubtitlesKey'] as String? ?? ''
      ..openSubtitlesUser = j['openSubtitlesUser'] as String? ?? ''
      ..openSubtitlesPassword = j['openSubtitlesPassword'] as String? ?? ''
      ..ytContainer = pick(YtContainer.values, j['ytContainer'], YtContainer.mp4)
      ..ytQuality = pick(YtQuality.values, j['ytQuality'], YtQuality.best)
      ..ytExpandPlaylists = j['ytExpandPlaylists'] as bool? ?? true
      ..ytCookiesBrowser = j['ytCookiesBrowser'] as String? ?? internalBrowserCookies
      ..ytCookiesFile = j['ytCookiesFile'] as String? ?? ''
      ..maxParallelDownloads = (j['maxParallelDownloads'] as num?)?.toInt() ?? 3
      ..maxParallelJobs = (j['maxParallelJobs'] as num?)?.toInt() ?? 5
      ..showLog = j['showLog'] as bool? ?? true
      ..startScreen = j['startScreen'] as String? ?? 'home'
      ..uiScale = clampUiScale(j['uiScale'] as num?)
      ..uiScaleDefault = clampUiScale(j['uiScaleDefault'] as num?)
      ..openFileAction = j['openFileAction'] == 'add' ? 'add' : 'play'
      ..uiLanguage = j['uiLanguage'] as String? ?? 'ko'
      ..appIcon = appIconOf(j['appIcon'] as String?)
      ..uiLanguagesAdded = [for (final x in (j['uiLanguagesAdded'] as List?) ?? const []) '$x']
      ..screenOrientation = const ['portrait', 'auto'].contains(j['screenOrientation'])
          ? j['screenOrientation'] as String
          : 'landscape'
      ..openFileWindow = j['openFileWindow'] == 'new' ? 'new' : 'same'
      ..homeUrl = j['homeUrl'] as String? ?? 'https://www.youtube.com/'
      ..browserEngine = j['browserEngine'] as String? ?? 'edge'
      ..externalBrowser = j['externalBrowser'] as String? ?? 'system'
      ..webTranslate = j['webTranslate'] as bool? ?? false
      ..webJavaScript = j['webJavaScript'] as bool? ?? true
      ..explorerLayout = const ['single', 'split'].contains(j['explorerLayout']) ? j['explorerLayout'] as String : 'dual'
      ..explorerClick = j['explorerClick'] == 'open' ? 'open' : 'select'
      ..explorerStyle = const ['windows', 'totalcmd'].contains(j['explorerStyle']) ? j['explorerStyle'] as String : 'xplore'
      ..explorerOrientation = const ['side', 'stacked'].contains(j['explorerOrientation'])
          ? j['explorerOrientation'] as String
          : 'auto'
      ..explorerToolbar = const ['edge', 'hidden'].contains(j['explorerToolbar']) ? j['explorerToolbar'] as String : 'middle'
      ..explorerButtons = [for (final x in (j['explorerButtons'] as List?) ?? const []) '$x']
      ..explorerSort = const ['date', 'size', 'type'].contains(j['explorerSort']) ? j['explorerSort'] as String : 'name'
      ..explorerSortDesc = j['explorerSortDesc'] as bool? ?? false
      ..explorerShowHidden = j['explorerShowHidden'] as bool? ?? false
      ..explorerPaths = [for (final x in (j['explorerPaths'] as List?) ?? const []) '$x']
      ..copyMethodFile = _method(j['copyMethodFile'])
      ..copyMethodFolder = _method(j['copyMethodFolder'])
      ..rsyncPaths = [for (final x in (j['rsyncPaths'] as List?) ?? const []) '$x']
      ..rsyncOptions = j['rsyncOptions'] as String? ?? '-avPog'
      ..robocopyOptions = j['robocopyOptions'] as String? ?? '/E /COPY:DAT /DCOPY:T /R:2 /W:2'
      ..copyRunMode = j['copyRunMode'] == 'once' ? 'once' : 'each'
      ..copyBandwidthKBps = ((j['copyBandwidthKBps'] as num?)?.toInt() ?? 0).clamp(0, 10000000)
      ..rsyncSource = j['rsyncSource'] == 'custom' ? 'custom' : 'download'
      ..rsyncPath = j['rsyncPath'] as String? ?? ''
      ..liveSyncPairs = [
        for (final x in (j['liveSyncPairs'] as List?) ?? const [])
          if (x is Map && x['source'] is String && x['target'] is String) LiveSyncPair.fromJson(x),
      ]
      ..liveSyncIntervalSec = ((j['liveSyncIntervalSec'] as num?)?.toInt() ?? 30).clamp(5, 3600)
      ..runInBackground = j['runInBackground'] == true
      ..liveSyncOnStart = const ['auto', 'ask', 'off'].contains(j['liveSyncOnStart']) ? j['liveSyncOnStart'] as String : 'auto'
      ..copyTasks = [
        for (final x in (j['copyTasks'] as List?) ?? const [])
          if (x is Map && x['dest'] is String) CopyTask.fromJson(x),
      ]
      ..explorerHistory = [for (final x in (j['explorerHistory'] as List?) ?? const []) '$x']
      ..autoCheckUpdates = j['autoCheckUpdates'] as bool? ?? true
      ..lastUpdateCheck = j['lastUpdateCheck'] as String? ?? ''
      ..lastUpdateCheckVersion = j['lastUpdateCheckVersion'] as String? ?? ''
      ..skippedVersion = j['skippedVersion'] as String? ?? ''
      ..playlistMode = pick(PlaylistMode.values, j['playlistMode'], PlaylistMode.series)
      ..externalPlayers = ((j['externalPlayers'] as Map?) ?? const {}).cast<String, String>()
      ..encode = EncodeSettings(
        codec: pick(VideoCodecChoice.values, e['codec'], VideoCodecChoice.copy),
        resolution: pick(ResolutionChoice.values, e['resolution'], ResolutionChoice.original),
        quality: pick(QualityChoice.values, e['quality'], QualityChoice.normal),
        frame: pick(FrameChoice.values, e['frame'], FrameChoice.original),
        fit: pick(FitChoice.values, e['fit'], FitChoice.fill),
        rotate: pick(RotateChoice.values, e['rotate'], RotateChoice.none),
        brightness: _adj(e['brightness']),
        contrast: _adj(e['contrast']),
        saturation: _adj(e['saturation']),
        temperature: _adj(e['temperature']),
      )
      ..aiSource = j['aiSource'] as String? ?? 'und'
      ..aiTargets = (j['aiTargets'] as List?)?.cast<String>() ?? ['ko', 'en', 'ja']
      ..aiWhisper = j['aiWhisper'] as String? ?? 'whisper-base';
  }

  /// 다운로드 기본 위치: 프로그램 폴더 (쓸 수 없으면 사용자 다운로드 폴더)
  String resolvedDownloadRoot() {
    if (downloadRoot != null && downloadRoot!.isNotEmpty) return downloadRoot!;
    // Android: 프로그램 폴더가 없으므로 내장 저장소의 Download\JJ_MKVMaker
    if (Platform.isAndroid) return '/storage/emulated/0/Download/JJ_MKVMaker';
    final appDir = p.dirname(Platform.resolvedExecutable);
    try {
      final probe = File(p.join(appDir, '.jj_write_test'));
      probe.writeAsStringSync('x');
      probe.deleteSync();
      return appDir;
    } catch (_) {
      final home = Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'] ?? appDir;
      return p.join(home, 'Downloads');
    }
  }

  String get ytDlpDir => p.join(resolvedDownloadRoot(), 'jj_yt-dlp');

  /// 앱 안 브라우저가 내보낸 YouTube · Google 쿠키 (cookies.txt). 없으면 빈 값
  String get internalCookieFile {
    if (webViewDataDir.isEmpty) return '';
    final f = p.join(webViewDataDir, 'cookies_youtube.txt');
    return File(f).existsSync() ? f : '';
  }

  /// 앱 안 브라우저의 쿠키가 있는 프로필 폴더 (로그인한 적이 없으면 빈 값)
  String get internalCookieProfile {
    if (webViewDataDir.isEmpty) return '';
    final profile = p.join(webViewDataDir, 'EBWebView', 'Default');
    final hasCookies = File(p.join(profile, 'Network', 'Cookies')).existsSync() ||
        File(p.join(profile, 'Cookies')).existsSync();
    return hasCookies ? profile : '';
  }
  String get aria2Dir => p.join(resolvedDownloadRoot(), 'jj_aria2');
}

/// 설정 파일 읽기·쓰기
class SettingsStore {
  final String? _path;

  SettingsStore([this._path]);

  Future<String> _file() async =>
      _path ?? p.join((await getApplicationSupportDirectory()).path, 'settings.json');

  Future<AppSettings> load() async {
    try {
      final f = File(await _file());
      // 이전 이름(jj_capcut) 의 설정 파일이 있으면 옮겨 온다
      final legacy = File(p.join(p.dirname(f.parent.path), 'jj_capcut', 'settings.json'));
      if (_path == null && !await f.exists() && await legacy.exists()) {
        await f.parent.create(recursive: true);
        await legacy.copy(f.path);
      }
      if (await f.exists()) {
        return AppSettings.fromJson(jsonDecode(await f.readAsString()) as Map<String, dynamic>);
      }
    } catch (_) {}
    return AppSettings();
  }

  Future<void> save(AppSettings s) async {
    final f = File(await _file());
    await f.parent.create(recursive: true);
    await f.writeAsString(const JsonEncoder.withIndent('  ').convert(s.toJson()));
  }
}
