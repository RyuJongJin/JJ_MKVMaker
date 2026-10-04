import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../core/download_detect.dart';
import '../core/encode_options.dart';
import '../core/playlist.dart';

/// 환경 설정 (settings.json 에 저장)
class AppSettings {
  /// MKV·자막 저장 위치. null 이면 동영상이 있는 폴더 아래 jj_mkv
  String? mkvOutputRoot;

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

  /// 처음 화면: 'home' = 지금처럼 MKV 화면 (기본), 'browser' = 웹 브라우저 ([homeUrl])
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

  /// 프로그램이 켜져 있을 때 탐색기에서 연 동영상 재생: 'same' 켜져 있는 창에서 / 'new' 새 재생 창
  String openFileWindow = 'same';
  String homeUrl = 'https://www.youtube.com/';

  /// 앱 안 브라우저 엔진: 'edge' (WebView2, 기본). 'chrome' 은 내려받아 연결 (준비 중)
  String browserEngine = 'edge';

  /// "외부 브라우저로 열기" 에 쓸 브라우저: 'system' · 'chrome' · 'firefox' · 'edge' · 'whale'
  String externalBrowser = 'system';

  /// 앱 안 브라우저의 데이터 폴더 (로그인 · 쿠키). 실행 중에 정해지며 저장하지 않음
  String webViewDataDir = '';

  /// 시작할 때 새 버전 확인 (하루 한 번)
  bool autoCheckUpdates = true;
  String lastUpdateCheck = '';

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
        'openFileWindow': openFileWindow,
        'homeUrl': homeUrl,
        'browserEngine': browserEngine,
        'externalBrowser': externalBrowser,
        'autoCheckUpdates': autoCheckUpdates,
        'lastUpdateCheck': lastUpdateCheck,
        'skippedVersion': skippedVersion,
        'playlistMode': playlistMode.name,
        'externalPlayers': externalPlayers,
        'encode': {
          'codec': encode.codec.name,
          'resolution': encode.resolution.name,
          'quality': encode.quality.name,
        },
        'aiSource': aiSource,
        'aiTargets': aiTargets,
        'aiWhisper': aiWhisper,
      };

  factory AppSettings.fromJson(Map<String, dynamic> j) {
    T pick<T extends Enum>(List<T> values, Object? name, T fallback) =>
        values.firstWhere((v) => v.name == name, orElse: () => fallback);
    final e = (j['encode'] as Map?) ?? const {};
    return AppSettings()
      ..mkvOutputRoot = j['mkvOutputRoot'] as String?
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
      ..screenOrientation = const ['portrait', 'auto'].contains(j['screenOrientation'])
          ? j['screenOrientation'] as String
          : 'landscape'
      ..openFileWindow = j['openFileWindow'] == 'new' ? 'new' : 'same'
      ..homeUrl = j['homeUrl'] as String? ?? 'https://www.youtube.com/'
      ..browserEngine = j['browserEngine'] as String? ?? 'edge'
      ..externalBrowser = j['externalBrowser'] as String? ?? 'system'
      ..autoCheckUpdates = j['autoCheckUpdates'] as bool? ?? true
      ..lastUpdateCheck = j['lastUpdateCheck'] as String? ?? ''
      ..skippedVersion = j['skippedVersion'] as String? ?? ''
      ..playlistMode = pick(PlaylistMode.values, j['playlistMode'], PlaylistMode.series)
      ..externalPlayers = ((j['externalPlayers'] as Map?) ?? const {}).cast<String, String>()
      ..encode = EncodeSettings(
        codec: pick(VideoCodecChoice.values, e['codec'], VideoCodecChoice.copy),
        resolution: pick(ResolutionChoice.values, e['resolution'], ResolutionChoice.original),
        quality: pick(QualityChoice.values, e['quality'], QualityChoice.normal),
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
