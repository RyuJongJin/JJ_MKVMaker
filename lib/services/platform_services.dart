import 'dart:io';

import 'package:path/path.dart' as p;

import '../platform/common/media_kit_full_player.dart';
import '../platform/common/media_kit_player.dart';
import '../app/settings.dart';
import '../core/download_detect.dart';
import '../platform/common/nllb_translator.dart';
import '../platform/common/opensubtitles_provider.dart';
import '../platform/common/whisper_recognizer.dart';
import '../platform/android/android_download_tools.dart';
import '../platform/android/android_shell.dart';
import '../platform/android/android_storage.dart';
import '../platform/android/android_updater.dart';
import '../platform/android/ffmpeg_kit_media_tool.dart';
import '../platform/windows/aria2_backend.dart';
import '../platform/windows/desktop_shell.dart';
import '../platform/windows/desktop_storage_service.dart';
import '../platform/windows/github_updater.dart';
import '../platform/windows/process_media_tool.dart';
import '../platform/windows/windows_usage.dart';
import '../platform/windows/ytdlp_backend.dart';
import 'ai_services.dart';
import 'app_shell.dart';
import 'downloader.dart';
import 'media_player.dart';
import 'media_tool.dart';
import 'model_store.dart';
import 'preview_player.dart';
import 'storage_service.dart';
import 'subtitle_provider.dart';
import 'system_usage.dart';
import 'updater.dart';

/// 플랫폼별 구현을 한 곳에서 고른다.
/// Android 이식 시 이 파일에 분기만 추가하면 된다.
class PlatformServices {
  final MediaTool mediaTool;
  final StorageService storage;

  /// 영상 재생기 생성 (없으면 영상 없이 자막만 편집)
  final PreviewPlayer Function()? createPlayer;

  /// 동영상 플레이어 (재생 목록 · 트랙)
  final MediaPlayer Function()? createMediaPlayer;

  /// AI 자막 (없으면 AI 자막 기능 숨김)
  final SpeechRecognizer Function()? createRecognizer;
  final Translator Function()? createTranslator;
  final ModelStore models;

  /// 다운로드 엔진 (yt-dlp, aria2). 설정값(형식 · 화질)을 읽는 함수를 받는다.
  final List<DownloadBackend> Function(AppSettings Function() settings)? createDownloadBackends;

  /// 트레이 · 전역 단축키 · 창 닫기
  final AppShell shell;

  /// 새 버전 확인 · 설치 (없으면 업데이트 기능 숨김)
  final Updater? updater;

  /// PC 의 CPU · 메모리 사용량 (없으면 표시 숨김)
  final SystemUsage? usage;

  /// 인터넷 자막 사이트 (설정값을 읽는 함수를 받아 만든다)
  final List<SubtitleProvider> Function(AppSettings Function() settings)? createSubtitleProviders;

  PlatformServices({
    required this.mediaTool,
    required this.storage,
    this.createPlayer,
    this.createMediaPlayer,
    this.createRecognizer,
    this.createTranslator,
    this.createDownloadBackends,
    this.createSubtitleProviders,
    this.updater,
    this.usage,
    ModelStore? models,
    AppShell? shell,
  })  : models = models ?? ModelStore(),
        shell = shell ?? NoopShell();

  factory PlatformServices.create() {
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      MediaKitPreviewPlayer.ensureInitialized();
      final tool = ProcessMediaTool.locate();
      final ffmpegDir = File(tool.ffmpeg).existsSync() ? p.dirname(tool.ffmpeg) : null;
      return PlatformServices(
        mediaTool: tool,
        storage: DesktopStorageService(),
        createPlayer: MediaKitPreviewPlayer.new,
        createMediaPlayer: MediaKitFullPlayer.new,
        createRecognizer: WhisperRecognizer.new,
        createTranslator: NllbTranslator.new,
        createDownloadBackends: (s) => [
          YtDlpBackend(
            ffmpegDir: ffmpegDir,
            formatArgs: () => ytDlpFormatArgs(s().ytContainer, s().ytQuality),
            cookieArgs: () => ytDlpCookieArgs(
                browser: s().ytCookiesBrowser,
                file: s().ytCookiesFile,
                internalProfile: s().internalCookieProfile,
                internalCookieFile: s().internalCookieFile),
            // 고른 브라우저의 쿠키를 못 읽으면 앱 안 브라우저의 쿠키로
            fallbackCookieArgs: () => ytDlpCookieArgs(
                browser: internalBrowserCookies, internalCookieFile: s().internalCookieFile),
          ),
          Aria2Backend(),
        ],
        shell: DesktopShell(),
        updater: GitHubUpdater(),
        usage: Platform.isWindows ? WindowsUsage() : null,
        createSubtitleProviders: (s) => [
          OpenSubtitlesProvider(
            apiKey: () => s().openSubtitlesKey,
            username: () => s().openSubtitlesUser,
            password: () => s().openSubtitlesPassword,
          ),
        ],
      );
    }
    if (Platform.isAndroid) {
      // 탐색기 연결은 데스크톱 전용. 업데이트는 APK 를 받아 Android 설치 화면으로. 다운로드는 앱에 넣은 yt-dlp · aria2c (youtubedl-android)
      MediaKitPreviewPlayer.ensureInitialized();
      final storage = AndroidStorageService();
      return PlatformServices(
        mediaTool: FfmpegKitMediaTool(),
        storage: storage,
        updater: AndroidUpdater(storage),
        createPlayer: MediaKitPreviewPlayer.new,
        createMediaPlayer: MediaKitFullPlayer.new,
        createRecognizer: WhisperRecognizer.new,
        createTranslator: NllbTranslator.new,
        createDownloadBackends: AndroidDownloadTools.backends,
        shell: AndroidShell(),
        createSubtitleProviders: (s) => [
          OpenSubtitlesProvider(
            apiKey: () => s().openSubtitlesKey,
            username: () => s().openSubtitlesUser,
            password: () => s().openSubtitlesPassword,
          ),
        ],
      );
    }
    throw UnsupportedError('아직 지원하지 않는 플랫폼입니다: ${Platform.operatingSystem}');
  }
}
