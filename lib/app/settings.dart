import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'components.dart';
import '../core/reader_sources.dart' show defaultImageExtensions;
import '../core/download_detect.dart';
import '../core/encode_options.dart';
import '../core/playlist.dart';
import '../core/webdav.dart';
import '../services/image_ai.dart' show AiService;
import '../services/app_shell.dart' show appIconOf;
import '../services/secret_store.dart';
import '../l10n/tr.dart';

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

  /// "지우기" 를 사용자가 지울 목록을 보고 확인했는지. 확인 전에는 지울 것이 있으면 지우지 않고 맞추며 확인을 기다린다 (42).
  /// 이 값이 생기기 전부터 돌던 쌍은 확인한 것으로 본다.
  final bool deleteConfirmed;
  const LiveSyncPair(this.source, this.target,
      {this.method = 'builtin',
      this.delete = false,
      this.enabled = true,
      this.schedule = const [],
      this.deleteConfirmed = false});

  /// [delete] 를 새로 켜면 확인은 다시 받는다
  LiveSyncPair copyWith({String? method, bool? delete, bool? enabled, List<String>? schedule, bool? deleteConfirmed}) =>
      LiveSyncPair(source, target,
          method: method ?? this.method,
          delete: delete ?? this.delete,
          enabled: enabled ?? this.enabled,
          schedule: schedule ?? this.schedule,
          deleteConfirmed: deleteConfirmed ?? (delete == true && !this.delete ? false : this.deleteConfirmed));

  Map<String, Object?> toJson() => {
        'source': source,
        'target': target,
        'method': method,
        'delete': delete,
        'enabled': enabled,
        'schedule': schedule,
        'deleteConfirmed': deleteConfirmed,
      };

  factory LiveSyncPair.fromJson(Map<Object?, Object?> j) => LiveSyncPair(
        j['source'] as String,
        j['target'] as String,
        method: const ['rsync', 'robocopy'].contains(j['method']) ? j['method'] as String : 'builtin',
        delete: j['delete'] == true,
        enabled: j['enabled'] != false,
        schedule: [for (final x in (j['schedule'] as List?) ?? const []) '$x'],
        // 이 값이 없는 예전 쌍은 이미 지우기 포함으로 돌던 것 → 확인한 것으로
        deleteConfirmed: j['deleteConfirmed'] as bool? ?? true,
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

  /// 이동 ([move], rsync --remove-source-files) 뒤 원본 정리: '' 그대로 · 'keep' 빈 폴더를 지우고 원본 폴더는 남김 ·
  /// 'all' 원본 폴더까지 (비었으면) 지움 (find 원본/ -type d -empty -delete)
  final String prune;

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
    this.prune = '',
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
    String? prune,
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
        prune: prune ?? this.prune,
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
        'prune': prune,
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
        prune: const ['keep', 'all'].contains(j['prune']) ? j['prune'] as String : '',
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

  /// 웹 브라우저 위에 다른 화면이 올라오거나 다른 화면으로 가면 페이지의 동영상 · 소리를 멈춤 (끄면 계속 들림)
  bool webPauseOnLeave = true;

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

  /// 36: 같은 크기면 H.264 를 먼저 (휴대폰 · 태블릿은 AV1 · VP9 을 하드웨어로 못 푸는 일이 많음). 기본: Android 켜짐, PC 꺼짐
  bool ytPreferH264 = Platform.isAndroid;

  /// 재생목록 주소면 목록 전체를 받기
  bool ytExpandPlaylists = true;

  /// YouTube 로봇 확인 대응: 쿠키를 가져올 브라우저 (빈 값 = 사용 안 함) 또는 cookies.txt 경로
  String ytCookiesBrowser = internalBrowserCookies; // 기본: 앱 안 브라우저 로그인 사용

  /// 53: 앱 안 브라우저 로그인 쿠키를 넘길 사이트 (처음은 모두 - 28)
  List<String> loginCookieSites = [...loginCookieDomains];
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
  // 18: 50 ~ 250% (사용자 결정)
  static const double uiScaleMin = 0.5, uiScaleMax = 2.5;
  static double clampUiScale(num? v) =>
      ((v ?? 1.0).toDouble().clamp(uiScaleMin, uiScaleMax) * 20).round() / 20;

  /// 탐색기에서 동영상을 열었을 때 (더블클릭 · 연결 프로그램): 'play' 바로 재생 / 'add' 편집 목록에 추가
  String openFileAction = 'play';

  /// Android 화면 방향: 'auto' 기기 방향 따라 (기본) / 'landscape' 가로 고정 / 'portrait' 세로 고정.
  /// 값이 없거나 틀리면 자동 (제한 없는 쪽). 고정은 사용자가 환경 설정에서 고를 때만.
  String screenOrientation = 'auto';

  /// 화면 언어 (ko · en · ja · zh-Hans, 또는 더한 언어)
  String uiLanguage = 'system';

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
  String explorerLayout = 'auto';

  /// 누르기: 'select' 한 번 = 선택 · 두 번 = 열기 (기본) / 'open' 한 번 = 바로 열기.
  /// 길게 누르기 · 오른쪽 클릭은 늘 기능 메뉴.
  String explorerClick = Platform.isAndroid ? 'open' : 'select';

  /// 모양: 'xplore' (기본) · 'windows' Windows 탐색기 · 'totalcmd' Total Commander
  String explorerStyle = 'xplore';

  /// 두 창 배치: 'side' 좌우 (기본, 118 - 폰 세로에서도) · 'stacked' 위아래 · 'auto' 화면 모양 따라 (가로로 넓으면 좌우, 세로로 길면 위아래)
  String explorerOrientation = 'side';

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

  /// 48: 복사 · 이동할 때 받는 폴더에 같은 이름이 있으면 'ask' (확인 창에서 고름, 처음 값) · 'rename' · 'overwrite' · 'skip'
  String copyConflict = 'ask';
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

  /// 설치한 (켠) 컴포넌트 id (app/components.dart). 처음엔 기본으로 들어 있는 것 모두
  List<String> components = AppComponent.defaultInstalled;

  /// 화면 순서 (위쪽 이동 버튼 · 화면 가운데를 좌우로 밀어 이동): 마지막 다음은 처음으로
  List<String> navOrder = AppComponent.defaultOrder;

  /// 화면 가운데를 좌우로 밀어 다음 · 이전 화면으로
  bool swipeNav = true;

  /// 그림 보기 (만화 보기) 대상 확장자 (파일 탐색기에서 두 번 누르면 보기로 연다)
  List<String> imageExts = [...defaultImageExtensions];

  /// 보기: 'page' 한 쪽 맞추기 · 'width' 좌우 맞추기 (세로로 밀어 봄)
  String readerFit = 'page';

  /// 보기: 오른쪽에서 왼쪽으로 넘김 (일본 만화)
  bool readerRtl = false;

  /// 보기: 밝기 (-0.7 어둡게 ~ 0.7 밝게)
  double readerBrightness = 0;

  /// 30 · 101: 보기 화면에서 위 · 아래 시스템 막대 (시계 · 알림 · 뒤로) 를 그대로 보이기 (기본: 보임 - 기기의 평소 동작, 화면 가득은 버튼 · 설정으로)
  bool readerSystemBars = true;

  /// 117: 보기 화면 "계속 보기" 간격 (초, 1 ~ 60)
  int readerAutoSeconds = 3;

  /// 119: 한 장에 두 쪽이 붙은 그림을 반씩 나눠 보기 - 'auto' 가로가 세로보다 긴 그림만 · 'on' 늘 · 'off' 안 함
  String readerSplit = 'auto';

  /// 99 (Windows): 시작 메뉴에 등록 - 알림이 JJ_MKVMaker 로 보이고 눌러서 열린다
  bool startMenuShortcut = true;

  /// 92 (Windows): 실시간 동기화가 멈췄을 때 Windows 알림
  bool syncStopToast = true;

  // ── 102: 사용자에게 물어 정한 것 · 관리자 1차 판단 (기본값 = 그 답) ──

  /// 66: 좌우로 밀 때 끝에서 처음으로 (끄면 끝에서 멈춤)
  bool swipeWrap = true;

  /// 66-2: 웹 브라우저에서 화면 옮기기 (위쪽 막대를 좌우로) 안내를 한 번 보였는지
  bool browserSwipeHinted = false;

  /// 저장 공간 정리 창에서 미리 체크할 묶음 (작업 임시 파일 · 받다 만 다운로드)
  List<String> cleanupPrechecked = ['work', 'download'];

  /// 19: 업데이트로 바뀐 기본값을 켤 때 한 번 알림
  bool migrationNotice = true;

  /// 34: Rsync · 동기화에서 원본이 대상 안 (안쪽 → 바깥) 을 허용 (지우기가 있을 때만 막음). 끄면 늘 막음
  bool allowInnerToOuter = true;

  /// 40 · 54: 비밀번호를 이 기기의 안전 저장소에 기억 (끄면 저장하지 않고 앱을 켤 때마다 다시 넣음)
  bool rememberPasswords = true;


  /// 65 (Windows): 탐색기에서 지우면 휴지통으로 (끄면 늘 영구 삭제로 묻는다)
  bool recycleOnDelete = true;

  /// 47: MKV 목록에서 세 번 누르면 'move' (확인 뒤 이동 폴더로) · 'none' (아무것도 안 함)
  String tripleTapAction = 'move';

  /// 61: 기본 자막 언어 (MKV 의 기본 자막 트랙 · 플레이어가 먼저 켜는 자막). '' = 화면 언어 따르기, 그 밖은 자막 언어 코드 (ko · ja …)
  String preferredSubtitleLanguage = '';

  /// 55: 로그인이 필요한 WebDAV 동영상을 다른 앱으로 열 때 'ask' (매번 묻기) · 'fetch' (늘 받아서) · 'url' (늘 주소로)
  String davExternalOpen = 'ask';

  /// 39: 켤 때 "모든 파일 접근" 안내를 한 번 보였는지 (그 뒤로는 파일 탐색기 안의 안내로)
  bool allFilesHintShown = false;

  /// 내장 플레이어 자막 글자 크기 배율 (0.5 ~ 2.5, 기본 1)
  double subtitleScale = 1.0;

  /// ZIP · CBZ 를 두 번 누르면 안의 그림을 만화처럼 보기 (끄면 목록). 기본은 목록 (사용자 지시)
  bool zipComic = false;

  /// WebDAV 서버 (파일 탐색기 · Rsync 화면 위쪽 "SD 카드" 옆 탭). 비밀번호는 이 설정 파일에만.
  List<DavServer> webdavServers = [];

  // ───────── 123 · 121: AI 그림 · 해상도 올리기 ─────────

  /// 그리는 엔진: 'local' 이 기기 안 (기본) · 아니면 [aiServices] 의 id (사용자가 추가한 서버 · 서비스)
  String aiEngine = 'local';

  /// 기기 안 처리 장치: 'auto' (잰 결과로 빠른 쪽) 또는 장치 열쇠 (예: 'engine-cuda:cuda0', 'engine-vulkan:cpu')
  String aiDevice = 'auto';

  /// 'auto' 가 잰 가장 빠른 장치와 그때의 장치 목록 (목록이 바뀌면 다시 잰다)
  String aiAutoDevice = '';
  String aiAutoDeviceFor = '';

  /// 빠른 디코더 (TAESD) - 그림이 거의 같고 디코드가 10배쯤 빠르다 (받아 두었을 때)
  bool aiTaesd = true;
  int aiWidth = 512;
  int aiHeight = 512;
  int aiSteps = 4;
  double aiCfg = 1;
  int aiCount = 1;
  double aiStrength = 0.6;
  String aiNegative = '';

  /// 159: 마지막 프롬프트와 만든 그림 목록 (최근 것부터, 업데이트 · 다시 열어도 남게)
  String aiPrompt = '';
  List<String> aiRecent = [];

  /// 저장 폴더 (비어 있으면 사진 폴더의 JJ_MKVMaker_AI)
  String aiSaveDir = '';

  /// 사용자가 추가한 그림 서버 · 서비스 (API 키는 안전 저장소에)
  List<AiService> aiServices = [];

  /// 라이선스 조건에 동의한 받는 파일 (149-④: 한 번 동의하면 다시 묻지 않음)
  List<String> aiAgreed = [];

  // 121: 해상도 올리기
  /// 모델 'auto' (GPU 면 사진용, CPU 뿐이면 가볍고 빠른 만화용) · 'photo' · 'anime'
  String aiUpModel = 'auto';

  /// 156-2: 해상도 올리기에 걸린 시간 (처리 장치|모델 → 원본 100만 화소당 초) - "한 장 약 n초" 를 미리 알리려고
  Map<String, double> aiUpSecPerMp = {};

  /// 배율 2 · 3 · 4
  int aiUpScale = 2;

  /// 저장 형식 'same' (원본과 같게, 못 쓰는 형식은 PNG) · 'png' · 'jpg' · JPG 품질
  String aiUpFormat = 'same';
  int aiUpJpgQuality = 92;

  /// 저장 위치 (비어 있으면 원본 옆 "이름_x2")
  String aiUpDir = '';

  /// 저장한 뒤 'upscaled' 올린 것으로 계속 보기 · 'original' 원본으로
  String aiUpAfter = 'upscaled';

  /// 실시간 동기화 확인 간격 (초). Windows 는 바뀌면 바로, 그 밖은 이 간격으로 살핀다.
  int liveSyncIntervalSec = 30;

  /// 백그라운드로 실행 (Android): 켜면 ← 로 닫거나 최근 앱에서 밀어도 동기화 · MKV 만들기 · 다운로드를 계속한다 (알림에 표시).
  /// 끄면 지금처럼 닫을 때 끝난다. Windows 는 [closeAction] 'background' 가 같은 뜻 ([backgroundRun]).
  bool runInBackground = true;

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

  /// 마지막으로 이 설정을 쓴 (실행한) 버전. 예전 버전은 이 항목을 몰라 저장하면서 지운다 →
  /// 돌아온 버전이 자기 것이 아니면 보관해 둔 그 버전의 설정을 되살릴지 묻는다 (VersionSnapshot)
  String lastRunVersion = '';

  /// P0 (Android 되돌리기): 받은 AI 모델을 공용 폴더에 옮겨 두었다가 되살릴지. '' = 남은 공간이 모델의 2배 이상이면 켬 · 'on' · 'off'
  String rollbackKeepModels = '';

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

  /// [plainSecrets]: 안전 저장소를 쓸 수 없을 때만 (예전 파일에 있던 비밀 값을 잃지 않게) 예전처럼 파일에 둔다
  Map<String, Object?> toJson({bool plainSecrets = false}) => {
        // 이 판이 모르는 항목 (새 판이 쓴 것 등) 은 지우지 않고 그대로 (40)
        ...stripSecrets(extra),
        'mkvOutputRoot': mkvOutputRoot,
        'moveTargets': [for (final t in moveTargets) t.toJson()],
        'youtubeAdSkip': youtubeAdSkip,
        'youtubeAdHide': youtubeAdHide,
        'webPauseOnLeave': webPauseOnLeave,
        'downloadRoot': downloadRoot,
        'clipboardWatch': clipboardWatch,
        'minimizeToTray': minimizeToTray,
        'closeAction': closeAction,
        'showHotkey': showHotkey,
        'askAiOptions': askAiOptions,
        'addFinishedDownloads': addFinishedDownloads,
        // 비밀 값은 안전 저장소에 (54). 파일에는 저장해 두었는지만
        'openSubtitlesSaved': {
          'key': openSubtitlesKey.isNotEmpty,
          'user': openSubtitlesUser.isNotEmpty,
          'password': openSubtitlesPassword.isNotEmpty,
        },
        if (plainSecrets) ...{
          'openSubtitlesKey': openSubtitlesKey,
          'openSubtitlesUser': openSubtitlesUser,
          'openSubtitlesPassword': openSubtitlesPassword,
        },
        'ytContainer': ytContainer.name,
        'ytQuality': ytQuality.name,
        'ytPreferH264': ytPreferH264,
        'ytExpandPlaylists': ytExpandPlaylists,
        'ytCookiesBrowser': ytCookiesBrowser,
        'loginCookieSites': loginCookieSites,
        'cookieScopeV2': true,
        'ytCookiesFile': ytCookiesFile,
        'maxParallelDownloads': maxParallelDownloads,
        'maxParallelJobs': maxParallelJobs,
        'showLog': showLog,
        'startScreen': startScreen,
        'uiScale': uiScale,
        'uiScaleDefault': uiScaleDefault,
        'openFileAction': openFileAction,
        'screenOrientation': screenOrientation,
        // 기본이 가로 고정이던 때의 값은 한 번 자동으로 옮긴다 (사용자가 정한 적 없는 가로 고정)
        'orientationV2': true,
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
        // 예전 기본값 (두 창 · 한 번 누르면 선택) 은 사용자가 고른 값이 아니므로 한 번 새 기본값으로 옮긴다
        'explorerV2': true,
        'explorerStyle': explorerStyle,
        'explorerOrientation': explorerOrientation,
        'explorerOrientV3': true,
        'explorerToolbar': explorerToolbar,
        'explorerButtons': explorerButtons,
        'explorerSort': explorerSort,
        'explorerSortDesc': explorerSortDesc,
        'explorerShowHidden': explorerShowHidden,
        'explorerPaths': explorerPaths,
        'copyMethodFile': copyMethodFile,
        'copyConflict': copyConflict,
        'copyMethodFolder': copyMethodFolder,
        'rsyncPaths': rsyncPaths,
        'components': components,
        'aiImageV1': true,
        'navOrder': navOrder,
        'swipeNav': swipeNav,
        'imageExts': imageExts,
        'readerFit': readerFit,
        'readerRtl': readerRtl,
        'readerBrightness': readerBrightness,
        'readerSystemBars': readerSystemBars,
        'readerAutoSeconds': readerAutoSeconds,
        'readerSplit': readerSplit,
        'startMenuShortcut': startMenuShortcut,
        'syncStopToast': syncStopToast,
        'swipeWrap': swipeWrap,
        'browserSwipeHinted': browserSwipeHinted,
        'cleanupPrechecked': cleanupPrechecked,
        'migrationNotice': migrationNotice,
        'allowInnerToOuter': allowInnerToOuter,
        'rememberPasswords': rememberPasswords,
        'recycleOnDelete': recycleOnDelete,
        'tripleTapAction': tripleTapAction,
        'preferredSubtitleLanguage': preferredSubtitleLanguage,
        'davExternalOpen': davExternalOpen,
        // 116: 예전 판의 표시 ('allFilesHintShown') 는 권한이 없어진 것을 몰라 다시 띄우지 못했다 → 새 이름으로 한 번 더
        'allFilesHint2': allFilesHintShown,
        'subtitleScale': subtitleScale,
        'zipComic': zipComic,
        // 예전 기본값 (만화 보기 켜짐) 은 지시와 반대였으므로 한 번 꺼진 상태 (목록) 로
        'zipComicV2': true,
        'aiEngine': aiEngine,
        'aiDevice': aiDevice,
        'aiAutoDevice': aiAutoDevice,
        'aiAutoDeviceFor': aiAutoDeviceFor,
        'aiTaesd': aiTaesd,
        'aiWidth': aiWidth,
        'aiHeight': aiHeight,
        'aiSteps': aiSteps,
        'aiCfg': aiCfg,
        'aiCount': aiCount,
        'aiStrength': aiStrength,
        'aiNegative': aiNegative,
        'aiPrompt': aiPrompt,
        'aiRecent': aiRecent,
        'aiSaveDir': aiSaveDir,
        'aiAgreed': aiAgreed,
        'aiUpModel': aiUpModel,
        'aiUpSecPerMp': aiUpSecPerMp,
        'aiUpScale': aiUpScale,
        'aiUpFormat': aiUpFormat,
        'aiUpJpgQuality': aiUpJpgQuality,
        'aiUpDir': aiUpDir,
        'aiUpAfter': aiUpAfter,
        'aiServices': [
          for (final x in aiServices) {...x.toJson(), if (plainSecrets) 'apiKey': x.apiKey},
        ],
        'webdavServers': [
          for (final x in webdavServers) {...x.toJson(), if (plainSecrets) 'password': x.password},
        ],
        'rsyncOptions': rsyncOptions,
        'robocopyOptions': robocopyOptions,
        'copyRunMode': copyRunMode,
        'copyBandwidthKBps': copyBandwidthKBps,
        'rsyncSource': rsyncSource,
        'rsyncPath': rsyncPath,
        'liveSyncPairs': [for (final x in liveSyncPairs) x.toJson()],
        'liveSyncIntervalSec': liveSyncIntervalSec,
        'runInBackground': runInBackground,
        'backgroundV2': true,
        'liveSyncOnStart': liveSyncOnStart,
        'copyTasks': [for (final x in copyTasks) x.toJson()],
        'explorerHistory': explorerHistory,
        'autoCheckUpdates': autoCheckUpdates,
        'lastUpdateCheck': lastUpdateCheck,
        'lastUpdateCheckVersion': lastUpdateCheckVersion,
        'lastRunVersion': lastRunVersion,
        'rollbackKeepModels': rollbackKeepModels,
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
    final s = AppSettings()
      ..mkvOutputRoot = j['mkvOutputRoot'] as String?
      ..moveTargets = [
        for (final x in (j['moveTargets'] as List?) ?? const [])
          if (x is Map && x['dir'] is String) MoveTarget.fromJson(x),
        // 예전 판의 이동 폴더 하나 → "이동" 버튼으로
        if (j['moveTargets'] == null && j['moveTargetDir'] is String) MoveTarget('이동', j['moveTargetDir'] as String),
      ]
      ..youtubeAdSkip = j['youtubeAdSkip'] as bool? ?? true
      ..youtubeAdHide = j['youtubeAdHide'] as bool? ?? true
      ..webPauseOnLeave = j['webPauseOnLeave'] as bool? ?? true
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
      ..ytPreferH264 = j['ytPreferH264'] is bool ? j['ytPreferH264'] as bool : Platform.isAndroid
      ..ytQuality = pick(YtQuality.values, j['ytQuality'], YtQuality.best)
      ..ytExpandPlaylists = j['ytExpandPlaylists'] as bool? ?? true
      ..ytCookiesBrowser = j['ytCookiesBrowser'] as String? ?? internalBrowserCookies
      ..loginCookieSites = j['loginCookieSites'] is List
          ? [for (final x in j['loginCookieSites'] as List) if (loginCookieDomains.contains(x)) '$x']
          : [...loginCookieDomains]
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
      ..screenOrientation = j['orientationV2'] == true && const ['landscape', 'portrait', 'auto'].contains(j['screenOrientation'])
          ? j['screenOrientation'] as String
          : 'auto'
      ..openFileWindow = j['openFileWindow'] == 'new' ? 'new' : 'same'
      ..homeUrl = j['homeUrl'] as String? ?? 'https://www.youtube.com/'
      ..browserEngine = j['browserEngine'] as String? ?? 'edge'
      ..externalBrowser = j['externalBrowser'] as String? ?? 'system'
      ..webTranslate = j['webTranslate'] as bool? ?? false
      ..webJavaScript = j['webJavaScript'] as bool? ?? true
      // 'auto' = 넓은 화면은 두 창, 좁은 화면 (폰 세로) 은 한 창. 예전 기본 'dual' 은 한 번 'auto' 로
      ..explorerLayout = const ['single', 'split', 'auto'].contains(j['explorerLayout'])
          ? j['explorerLayout'] as String
          : j['explorerLayout'] == 'dual' && j['explorerV2'] == true
              ? 'dual'
              : 'auto'
      // Android 는 손가락으로 한 번 누르면 바로 실행이 기본. 예전 기본 'select' 는 Android 에서 한 번 'open' 으로
      ..explorerClick = j['explorerClick'] == 'open'
          ? 'open'
          : j['explorerClick'] == 'select' && (j['explorerV2'] == true || !Platform.isAndroid)
              ? 'select'
              : (Platform.isAndroid ? 'open' : 'select')
      ..explorerStyle = const ['windows', 'totalcmd'].contains(j['explorerStyle']) ? j['explorerStyle'] as String : 'xplore'
      // 118: 예전 기본 '화면 모양 따라' 는 한 번 좌우로 옮긴다 (사용자가 고른 위아래는 그대로)
      ..explorerOrientation = j['explorerOrientation'] == 'stacked'
          ? 'stacked'
          : j['explorerOrientation'] == 'auto' && j['explorerOrientV3'] == true
              ? 'auto'
              : 'side'
      ..explorerToolbar = const ['edge', 'hidden'].contains(j['explorerToolbar']) ? j['explorerToolbar'] as String : 'middle'
      ..explorerButtons = [for (final x in (j['explorerButtons'] as List?) ?? const []) '$x']
      ..explorerSort = const ['date', 'size', 'type'].contains(j['explorerSort']) ? j['explorerSort'] as String : 'name'
      ..explorerSortDesc = j['explorerSortDesc'] as bool? ?? false
      ..explorerShowHidden = j['explorerShowHidden'] as bool? ?? false
      ..explorerPaths = [for (final x in (j['explorerPaths'] as List?) ?? const []) '$x']
      ..copyMethodFile = _method(j['copyMethodFile'])
      ..copyConflict = const ['rename', 'overwrite', 'skip'].contains(j['copyConflict']) ? j['copyConflict'] as String : 'ask'
      ..copyMethodFolder = _method(j['copyMethodFolder'])
      ..rsyncPaths = [for (final x in (j['rsyncPaths'] as List?) ?? const []) '$x']
      ..components = j['components'] is List
          ? [
              for (final x in j['components'] as List) if (AppComponent.byId('$x') != null) '$x',
              // 123: 새 화면 "AI 그림" 은 예전 설정에도 한 번 켜서 넣는다 (끄기: 환경 설정 > 컴포넌트)
              if (j['aiImageV1'] != true && !(j['components'] as List).contains('aiimage')) 'aiimage',
            ]
          : AppComponent.defaultInstalled
      ..navOrder = j['navOrder'] is List
          ? [for (final x in j['navOrder'] as List) if (AppComponent.defaultOrder.contains('$x')) '$x']
          : AppComponent.defaultOrder
      ..swipeNav = j['swipeNav'] as bool? ?? true
      ..imageExts = j['imageExts'] is List
          ? [for (final x in j['imageExts'] as List) '$x'.toLowerCase()]
          : [...defaultImageExtensions]
      ..readerFit = j['readerFit'] == 'width' ? 'width' : 'page'
      ..readerRtl = j['readerRtl'] as bool? ?? false
      ..readerBrightness = ((j['readerBrightness'] as num?)?.toDouble() ?? 0).clamp(-0.7, 0.7)
      ..readerSystemBars = j['readerSystemBars'] != false
      ..readerAutoSeconds = ((j['readerAutoSeconds'] as num?)?.toInt() ?? 3).clamp(1, 60)
      ..readerSplit = const ['auto', 'on', 'off'].contains(j['readerSplit']) ? j['readerSplit'] as String : 'auto'
      ..startMenuShortcut = j['startMenuShortcut'] != false
      ..syncStopToast = j['syncStopToast'] != false
      ..swipeWrap = j['swipeWrap'] != false
      ..browserSwipeHinted = j['browserSwipeHinted'] == true
      ..cleanupPrechecked = j['cleanupPrechecked'] is List
          ? [for (final x in j['cleanupPrechecked'] as List) '$x']
          : ['work', 'download']
      ..migrationNotice = j['migrationNotice'] != false
      ..allowInnerToOuter = j['allowInnerToOuter'] != false
      ..rememberPasswords = j['rememberPasswords'] != false
      ..recycleOnDelete = j['recycleOnDelete'] != false
      ..tripleTapAction = j['tripleTapAction'] == 'none' ? 'none' : 'move'
      ..preferredSubtitleLanguage = j['preferredSubtitleLanguage'] is String ? j['preferredSubtitleLanguage'] as String : ''
      ..davExternalOpen = const ['fetch', 'url'].contains(j['davExternalOpen']) ? j['davExternalOpen'] as String : 'ask'
      ..allFilesHintShown = j['allFilesHint2'] == true
      ..subtitleScale = ((j['subtitleScale'] as num?)?.toDouble() ?? 1.0).clamp(0.5, 2.5)
      ..zipComic = j['zipComic'] == true && j['zipComicV2'] == true
      ..aiEngine = j['aiEngine'] as String? ?? 'local'
      ..aiDevice = j['aiDevice'] as String? ?? 'auto'
      ..aiAutoDevice = j['aiAutoDevice'] as String? ?? ''
      ..aiAutoDeviceFor = j['aiAutoDeviceFor'] as String? ?? ''
      ..aiTaesd = j['aiTaesd'] != false
      ..aiWidth = ((j['aiWidth'] as num?)?.toInt() ?? 512).clamp(64, 2048)
      ..aiHeight = ((j['aiHeight'] as num?)?.toInt() ?? 512).clamp(64, 2048)
      ..aiSteps = ((j['aiSteps'] as num?)?.toInt() ?? 4).clamp(1, 150)
      ..aiCfg = ((j['aiCfg'] as num?)?.toDouble() ?? 1).clamp(0, 30)
      ..aiCount = ((j['aiCount'] as num?)?.toInt() ?? 1).clamp(1, 100)
      ..aiStrength = ((j['aiStrength'] as num?)?.toDouble() ?? 0.6).clamp(0, 1)
      ..aiNegative = j['aiNegative'] as String? ?? ''
      ..aiPrompt = j['aiPrompt'] as String? ?? ''
      ..aiRecent = [for (final x in (j['aiRecent'] as List?) ?? const []) '$x']
      ..aiSaveDir = j['aiSaveDir'] as String? ?? ''
      ..aiAgreed = [for (final x in (j['aiAgreed'] as List?) ?? const []) '$x']
      ..aiUpModel = const ['photo', 'anime'].contains(j['aiUpModel']) ? j['aiUpModel'] as String : 'auto'
      ..aiUpSecPerMp = {
        if (j['aiUpSecPerMp'] case final Map m)
          for (final e in m.entries)
            if (e.value is num && (e.value as num) > 0) '${e.key}': (e.value as num).toDouble(),
      }
      ..aiUpScale = const [3, 4].contains(j['aiUpScale']) ? j['aiUpScale'] as int : 2
      ..aiUpFormat = const ['png', 'jpg'].contains(j['aiUpFormat']) ? j['aiUpFormat'] as String : 'same'
      ..aiUpJpgQuality = ((j['aiUpJpgQuality'] as num?)?.toInt() ?? 92).clamp(50, 100)
      ..aiUpDir = j['aiUpDir'] as String? ?? ''
      ..aiUpAfter = j['aiUpAfter'] == 'original' ? 'original' : 'upscaled'
      ..aiServices = [
        for (final x in (j['aiServices'] as List?) ?? const [])
          if (x is Map) AiService.fromJson(x),
      ]
      ..webdavServers = [
        for (final x in (j['webdavServers'] as List?) ?? const [])
          if (x is Map) DavServer.fromJson(x),
      ]
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
      // 사용자 결정 (10/8): 기본 켜짐. 예전 기본 (꺼짐) 은 한 번 켜짐으로
      ..runInBackground = j['backgroundV2'] == true ? j['runInBackground'] != false : true
      ..liveSyncOnStart = const ['auto', 'ask', 'off'].contains(j['liveSyncOnStart']) ? j['liveSyncOnStart'] as String : 'auto'
      ..copyTasks = [
        for (final x in (j['copyTasks'] as List?) ?? const [])
          if (x is Map && x['dest'] is String) CopyTask.fromJson(x),
      ]
      ..explorerHistory = [for (final x in (j['explorerHistory'] as List?) ?? const []) '$x']
      ..autoCheckUpdates = j['autoCheckUpdates'] as bool? ?? true
      ..lastUpdateCheck = j['lastUpdateCheck'] as String? ?? ''
      ..lastUpdateCheckVersion = j['lastUpdateCheckVersion'] as String? ?? ''
      ..lastRunVersion = j['lastRunVersion'] as String? ?? ''
      ..rollbackKeepModels = const ['on', 'off'].contains(j['rollbackKeepModels']) ? j['rollbackKeepModels'] as String : ''
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
    s.migrated = _migrated(j, s);
    s.extra = Map.of(j);
    return s;
  }

  /// 업데이트하면서 예전 기본값을 새 기본값으로 옮긴 것 (예전 설정 파일에 그 값이 실제로 있었을 때만).
  /// 앱이 켜질 때 한 번 알리고 (무엇이 바뀌었는지 · 환경 설정에서 되돌릴 수 있다는 것) 비운다. 저장하지 않는다.
  List<String> migrated = [];

  /// 읽은 설정 파일 그대로 (이 판이 모르는 항목을 저장할 때 지우지 않게)
  Map<String, dynamic> extra = {};

  /// 설정 파일에 평문으로 두면 안 되는 항목 (54)
  static const secretKeys = ['openSubtitlesKey', 'openSubtitlesUser', 'openSubtitlesPassword'];

  /// 설정 JSON 에서 비밀 값을 뺀 것 (.bak · 모르는 항목 보존용)
  static Map<String, dynamic> stripSecrets(Map<String, dynamic> j) {
    final r = Map<String, dynamic>.of(j);
    for (final k in secretKeys) {
      r.remove(k);
    }
    final servers = r['webdavServers'];
    if (servers is List) {
      r['webdavServers'] = [
        for (final x in servers) x is Map ? (Map.of(x)..remove('password')) : x,
      ];
    }
    final ai = r['aiServices'];
    if (ai is List) {
      r['aiServices'] = [
        for (final x in ai) x is Map ? (Map.of(x)..remove('apiKey')) : x,
      ];
    }
    return r;
  }

  static List<String> _migrated(Map<String, dynamic> j, AppSettings s) => [
        if (j['orientationV2'] != true && j['screenOrientation'] == 'landscape' && s.screenOrientation == 'auto')
          'orientation',
        if (j['explorerV2'] != true && j['explorerLayout'] == 'dual' && s.explorerLayout == 'auto') 'explorerLayout',
        if (j['explorerV2'] != true && j['explorerClick'] == 'select' && s.explorerClick == 'open') 'explorerClick',
        if (j['explorerOrientV3'] != true && j['explorerOrientation'] == 'auto') 'explorerOrientation',
        if (j['aiImageV1'] != true && j['components'] is List && !(j['components'] as List).contains('aiimage')) 'aiImage',
        // 53 · 28: 앱 안 브라우저 쿠키를 쓰던 사람에게 넘기는 사이트가 넓어졌음을 한 번 알린다
        if (j['cookieScopeV2'] != true && j.isNotEmpty && (j['ytCookiesBrowser'] ?? internalBrowserCookies) == internalBrowserCookies)
          'cookieScope',
        if (j['zipComicV2'] != true && j['zipComic'] != false && j.containsKey('imageExts') && !s.zipComic) 'zipComic',
        if (j['backgroundV2'] != true && j['runInBackground'] == false && s.runInBackground && Platform.isAndroid)
          'background',
      ];

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
/// 설정 파일 읽기 · 쓰기.
/// - 쓰기: 임시 파일에 다 쓴 뒤 바꿔치기 (쓰는 도중 앱이 끝나도 settings.json 이 깨지지 않게).
///   바꿔치기 전의 정상 파일은 settings.json.bak 으로 남긴다.
/// - 읽기: settings.json 을 읽지 못하면 settings.json.bak 으로 되살린다. 읽지 못한 파일은 지우지 않고
///   settings.broken-(시각).json 으로 보관한다 (다음 저장에 덮여 사라지지 않게). 무슨 일이 있었는지는 [problem].
class SettingsStore {
  final String? _path;

  /// 비밀 값 (WebDAV 비밀번호 · OpenSubtitles) 을 두는 곳. 경로를 직접 주면 (시험) 메모리
  final SecretStore secrets;

  SettingsStore([this._path, SecretStore? secrets])
      : secrets = secrets ?? (_path == null ? SecretStore.platform() : MemorySecretStore());

  /// 안전 저장소를 읽을 수 있었는지 (못 읽었으면 저장소를 건드리지 않는다 - 지워 버리지 않게)
  bool _secretsOk = true;

  /// 안전 저장소에 마지막으로 쓴 (읽은) 값 - 바뀐 것만 쓴다
  Map<String, String> _known = {};

  /// 설정 파일에 예전부터 평문으로 있던 값 (저장소 열쇠 → 값). 안전 저장소에 들어가기 전까지는 파일에서 지우지 않는다 (40-1).
  /// 새로 넣은 값은 저장소에 못 쓰더라도 평문으로 쓰지 않는다 (사용자 결정) - 대신 [secretIssue] 로 알린다.
  final Map<String, String> _filePlain = {};

  /// 안전 저장소 문제 (화면 위 알림 · [다시 시도]). null = 문제 없음
  final secretIssue = ValueNotifier<SecretIssue?>(null);

  /// 안전 저장소의 열쇠
  static const _osKeys = {
    'openSubtitlesKey': 'os.key',
    'openSubtitlesUser': 'os.user',
    'openSubtitlesPassword': 'os.password',
  };
  static String _davKey(String id) => 'dav.pw.$id';
  static String _aiKey(String id) => 'ai.key.$id';
  static const _davServers = 'dav.servers';

  static String _os(AppSettings s, String k) => switch (k) {
        'openSubtitlesKey' => s.openSubtitlesKey,
        'openSubtitlesUser' => s.openSubtitlesUser,
        _ => s.openSubtitlesPassword,
      };

  /// 지금 설정의 비밀 값 (빈 값은 넣지 않음 = 저장소에서 지움)
  static Map<String, String> _secretsOf(AppSettings s) => !s.rememberPasswords ? const {} : {
        for (final e in _osKeys.entries)
          if (_os(s, e.key).isNotEmpty) e.value: _os(s, e.key),
        for (final x in s.webdavServers)
          if (x.password.isNotEmpty) _davKey(x.id): x.password,
        for (final x in s.aiServices)
          if (x.apiKey.isNotEmpty) _aiKey(x.id): x.apiKey,
        // 서버 목록 (비밀번호 없이): 예전 판이 설정 파일에서 서버 목록을 지워도 되살릴 수 있게 (40)
        if (s.webdavServers.isNotEmpty) _davServers: jsonEncode([for (final x in s.webdavServers) x.toJson()]),
      };

  /// 저장소에 못 넣은 예전 평문 값을 설정 JSON 에 그대로 둔다
  static void _putPlain(Map<String, Object?> j, String key, String value) {
    for (final e in _osKeys.entries) {
      if (e.value == key) j[e.key] = value;
    }
    if (key.startsWith('ai.key.')) {
      final id = key.substring('ai.key.'.length);
      for (final x in (j['aiServices'] as List?) ?? const []) {
        if (x is Map && '${x['id']}' == id) x['apiKey'] = value;
      }
    }
    if (key.startsWith('dav.pw.')) {
      final id = key.substring('dav.pw.'.length);
      for (final x in (j['webdavServers'] as List?) ?? const []) {
        if (x is Map && '${x['id']}' == id) x['password'] = value;
      }
    }
  }

  /// 비어 있는 비밀 값을 안전 저장소의 것으로 채운다 (파일에 평문이 있으면 그것을 쓰고 [_filePlain] 에 기억)
  void _fill(AppSettings s, Map<String, String> stored) {
    final os = <String, String>{};
    for (final e in _osKeys.entries) {
      final v = _os(s, e.key);
      os[e.key] = v.isNotEmpty ? v : stored[e.value] ?? '';
    }
    s
      ..openSubtitlesKey = os['openSubtitlesKey']!
      ..openSubtitlesUser = os['openSubtitlesUser']!
      ..openSubtitlesPassword = os['openSubtitlesPassword']!;
    s.webdavServers = [
      for (final x in s.webdavServers)
        x.password.isNotEmpty ? x : x.copyWith(password: stored[_davKey(x.id)] ?? ''),
    ];
    s.aiServices = [
      for (final x in s.aiServices) x.apiKey.isNotEmpty ? x : x.copyWith(apiKey: stored[_aiKey(x.id)] ?? ''),
    ];
  }

  /// 읽은 설정에 안전 저장소의 비밀 값을 채운다. 파일에 예전 평문 값이 있으면 저장소로 옮기고 파일에서 지운다 (54).
  Future<void> _loadSecrets(AppSettings s) async {
    Map<String, String> stored;
    try {
      stored = await secrets.readAll();
      _secretsOk = true;
    } catch (_) {
      stored = {};
      _secretsOk = false;
    }
    _known = Map.of(stored);
    _filePlain.clear();
    // 예전 판이 서버 목록을 지운 설정 파일 (항목 자체가 없음) → 저장소의 목록으로
    if (!s.extra.containsKey('webdavServers') && stored[_davServers] != null) {
      try {
        s.webdavServers = [
          for (final x in jsonDecode(stored[_davServers]!) as List)
            if (x is Map) DavServer.fromJson(x),
        ];
      } catch (_) {}
    }
    // 파일의 평문 값 (예전 판 · 저장소에 못 넣었던 것) 기억
    for (final e in _osKeys.entries) {
      final v = _os(s, e.key);
      if (v.isNotEmpty) _filePlain[e.value] = v;
    }
    for (final x in s.webdavServers) {
      if (x.password.isNotEmpty) _filePlain[_davKey(x.id)] = x.password;
    }
    for (final x in s.aiServices) {
      if (x.apiKey.isNotEmpty) _filePlain[_aiKey(x.id)] = x.apiKey;
    }
    _fill(s, stored);
    secretIssue.value = !_secretsOk
        ? const SecretIssue(SecretIssueKind.readFailed)
        : secrets.lostCopy != null
            ? SecretIssue(SecretIssueKind.lost, kept: secrets.lostCopy)
            : null;
    // 옮기기: 저장소에 쓰고 파일에서 지운다 (못 쓴 것은 파일에 그대로)
    if (_filePlain.isNotEmpty && _secretsOk) await save(s);
    // 백업으로 되살렸거나 예전 이름의 파일을 옮겨 왔으면, 저장소에 다 들어간 뒤 그 파일들의 평문도 지운다 (40-4)
    if (_secretsOk && _filePlain.isEmpty) {
      for (final f in _scrub) {
        await _scrubFile(f);
      }
    }
    _scrub.clear();
  }

  /// 평문 비밀 값이 남아 있을 수 있는 파일 (.bak 으로 되살림 · jj_capcut 에서 옮김)
  final List<File> _scrub = [];

  static Future<void> _scrubFile(File f) async {
    try {
      if (!await f.exists()) return;
      final j = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      final clean = AppSettings.stripSecrets(j);
      if (jsonEncode(clean) == jsonEncode(j)) return;
      await f.writeAsString(const JsonEncoder.withIndent('  ').convert(clean), flush: true);
    } catch (_) {}
  }

  /// 깨진 설정 파일의 보관본에서 비밀 값을 지운다 (JSON 으로 읽을 수 없으니 글자로)
  static String redactSecrets(String text) => text.replaceAllMapped(
      RegExp(r'"(openSubtitlesKey|openSubtitlesUser|openSubtitlesPassword|password|apiKey)"\s*:\s*"(?:[^"\\]|\\.)*"'),
      (m) => '"${m[1]}": ""');

  /// 읽기 오류를 알릴 글 (파일 내용은 넣지 않음 - JSON 오류 메시지에는 원문 일부가 들어간다)
  static String _describe(Object e) =>
      e is FormatException ? 'FormatException: ${e.message}${e.offset != null ? ' (offset ${e.offset})' : ''}' : '$e';

  /// [다시 시도]: 안전 저장소를 다시 읽고 (못 읽었으면) 저장하지 못한 값을 다시 쓴다. 문제가 없어지면 true
  Future<bool> retrySecrets(AppSettings s) async {
    if (!_secretsOk) {
      try {
        final stored = await secrets.readAll();
        _secretsOk = true;
        _known = Map.of(stored);
        _fill(s, stored);
      } catch (_) {
        secretIssue.value = const SecretIssue(SecretIssueKind.readFailed);
        return false;
      }
    }
    await save(s);
    final i = secretIssue.value;
    if (i?.kind == SecretIssueKind.readFailed) secretIssue.value = null;
    return secretIssue.value == null || secretIssue.value!.kind == SecretIssueKind.lost;
  }

  /// 마지막 [load] 에서 생긴 일 (null = 문제 없음). 앱이 켜질 때 사용자에게 알린다.
  SettingsLoadProblem? problem;

  Future<String> _file() async =>
      _path ?? p.join((await getApplicationSupportDirectory()).path, 'settings.json');

  static AppSettings _parse(String text) => AppSettings.fromJson(jsonDecode(text) as Map<String, dynamic>);

  Future<AppSettings> load() async {
    final s = await _loadFile();
    await _loadSecrets(s);
    return s;
  }

  Future<AppSettings> _loadFile() async {
    problem = null;
    final f = File(await _file());
    try {
      // 이전 이름(jj_capcut) 의 설정 파일이 있으면 옮겨 온다
      final legacy = File(p.join(p.dirname(f.parent.path), 'jj_capcut', 'settings.json'));
      if (_path == null && !await f.exists() && await legacy.exists()) {
        await f.parent.create(recursive: true);
        await legacy.copy(f.path);
        _scrub.add(legacy);
      }
    } catch (_) {}
    final bak = File('${f.path}.bak');
    if (!await f.exists()) {
      // 바꿔치기 도중 끝나 settings.json 만 없는 경우: 백업이 있으면 그것으로
      if (await bak.exists()) {
        try {
          final s = _parse(await bak.readAsString());
          problem = SettingsLoadProblem(restoredFromBackup: true, brokenCopy: null, error: tr('settings.json 없음'));
          _scrub.add(bak);
          return s;
        } catch (_) {}
      }
      return AppSettings();
    }
    String? text;
    Object? error;
    try {
      text = await f.readAsString();
      return _parse(text);
    } catch (e) {
      error = e;
    }
    // 읽지 못함: 깨진 파일을 보관하고 백업으로
    String? kept;
    try {
      final stamp = DateTime.now().toIso8601String().replaceAll(':', '').split('.').first;
      kept = p.join(f.parent.path, 'settings.broken-$stamp.json');
      // 비밀 값은 지우고 보관 (40-4)
      await File(kept).writeAsString(redactSecrets(utf8.decode(await f.readAsBytes(), allowMalformed: true)));
    } catch (_) {
      kept = null;
    }
    if (await bak.exists()) {
      try {
        final s = _parse(await bak.readAsString());
        problem = SettingsLoadProblem(restoredFromBackup: true, brokenCopy: kept, error: _describe(error));
        _scrub.add(bak);
        return s;
      } catch (_) {}
    }
    problem = SettingsLoadProblem(restoredFromBackup: false, brokenCopy: kept, error: _describe(error));
    return AppSettings();
  }

  /// 한 번에 하나씩 쓴다 (빠르게 여러 번 바꿔도 파일이 섞이지 않게)
  Future<void> _last = Future.value();

  Future<void> save(AppSettings s) {
    final j = s.toJson();
    final values = _secretsOf(s);
    return _last = _last.catchError((_) {}).then((_) async {
      final unsaved = await _writeSecrets(values);
      // 40-1: 저장소에 들어가지 못한 값 중 파일에 원래 평문으로 있던 것은 지우지 않고 그대로 둔다
      for (final k in _filePlain.keys.toList()) {
        if (!values.containsKey(k) || !unsaved.contains(k)) {
          _filePlain.remove(k); // 사용자가 지웠거나 저장소에 들어감
        } else {
          _putPlain(j, k, _filePlain[k]!);
        }
      }
      final missing = unsaved.where((k) => k != _davServers).toList();
      if (missing.isNotEmpty) {
        // 91: 새로 넣은 값이 저장되지 않았으면, 앱을 끈 뒤 어떻게 되는지 (예전 값으로 돌아감 / 사라짐)
        var reverts = false, lost = false;
        for (final k in missing) {
          final old = _filePlain[k] ?? _known[k];
          if (old == values[k]) continue; // 예전 평문 그대로 (파일에 남아 있음)
          if (old != null) {
            reverts = true;
          } else {
            lost = true;
          }
        }
        secretIssue.value = SecretIssue(_secretsOk ? SecretIssueKind.writeFailed : SecretIssueKind.readFailed,
            revertsToOld: reverts, lostOnExit: lost);
      } else if (secretIssue.value?.kind == SecretIssueKind.writeFailed) {
        secretIssue.value = null;
      }
      await _write(const JsonEncoder.withIndent('  ').convert(j));
    });
  }

  /// 바뀐 비밀 값만 안전 저장소에 쓴다 (빈 값 · 지운 서버는 저장소에서도 지움). 저장소에 넣지 못한 열쇠를 돌려준다.
  Future<Set<String>> _writeSecrets(Map<String, String> values) async {
    if (!_secretsOk) return {...values.keys.where((k) => _known[k] != values[k])};
    final unsaved = <String>{};
    for (final k in {..._known.keys, ...values.keys}) {
      if (!k.startsWith('os.') && !k.startsWith('dav.') && !k.startsWith('ai.')) continue;
      final v = values[k];
      if (v == _known[k]) continue;
      try {
        if (v == null) {
          await secrets.delete(k);
          _known.remove(k);
        } else {
          await secrets.write(k, v);
          _known[k] = v;
        }
      } catch (_) {
        if (v != null) unsaved.add(k);
      }
    }
    return unsaved;
  }

  Future<void> _write(String text) async {
    final f = File(await _file());
    await f.parent.create(recursive: true);
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(text, flush: true);
    if (await f.exists()) {
      // 지금 파일이 정상이면 백업으로 남긴다 (깨진 파일로 좋은 백업을 덮지 않게). 비밀 값은 빼고 (54)
      try {
        final j = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
        AppSettings.fromJson(j);
        // 저장소에 못 넣어 파일에 남겨 둔 평문이 있으면 백업에도 그대로 (40-1)
        await File('${f.path}.bak').writeAsString(
            const JsonEncoder.withIndent('  ').convert(_filePlain.isNotEmpty ? j : AppSettings.stripSecrets(j)),
            flush: true);
      } catch (_) {}
    }
    await tmp.rename(f.path);
  }
}

/// 안전 저장소 문제의 종류
enum SecretIssueKind {
  /// 안전 저장소를 읽을 수 없음 (이번 실행에서 넣은 비밀번호는 저장되지 않음)
  readFailed,

  /// 안전 저장소에 쓰지 못함 (넣은 비밀번호가 저장되지 않음)
  writeFailed,

  /// 안전 저장소를 풀 수 없어 저장된 비밀번호를 되살리지 못함 (풀지 못한 파일은 [SecretIssue.kept] 에 보관)
  lost,
}

class SecretIssue {
  final SecretIssueKind kind;
  final String? kept;

  /// 91: 저장하지 못한 새 값 중 예전 값이 있는 것이 있다 (앱을 끄면 예전 비밀번호로 돌아감)
  final bool revertsToOld;

  /// 저장하지 못한 새 값 중 예전 값이 없는 것이 있다 (앱을 끄면 사라짐)
  final bool lostOnExit;

  const SecretIssue(this.kind, {this.kept, this.revertsToOld = false, this.lostOnExit = false});

  // 같은 상황이면 알림을 다시 띄우지 않게 (90)
  @override
  bool operator ==(Object other) =>
      other is SecretIssue &&
      other.kind == kind &&
      other.kept == kept &&
      other.revertsToOld == revertsToOld &&
      other.lostOnExit == lostOnExit;
  @override
  int get hashCode => Object.hash(kind, kept, revertsToOld, lostOnExit);
}

/// 설정 파일을 읽다 생긴 일 (앱이 켜질 때 알림)
class SettingsLoadProblem {
  /// 백업 (직전 정상 저장) 으로 되살렸는지. false 면 처음 설정으로 켰다.
  final bool restoredFromBackup;

  /// 읽지 못한 원래 파일을 보관한 곳
  final String? brokenCopy;
  final String error;
  const SettingsLoadProblem({required this.restoredFromBackup, required this.brokenCopy, required this.error});
}
