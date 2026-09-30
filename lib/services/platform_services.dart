import 'dart:io';

import 'package:path/path.dart' as p;

import '../platform/common/media_kit_full_player.dart';
import '../platform/common/media_kit_player.dart';
import '../app/settings.dart';
import '../core/download_detect.dart';
import '../platform/common/nllb_translator.dart';
import '../platform/common/opensubtitles_provider.dart';
import '../platform/common/whisper_recognizer.dart';
import '../platform/windows/aria2_backend.dart';
import '../platform/windows/desktop_shell.dart';
import '../platform/windows/desktop_storage_service.dart';
import '../platform/windows/github_updater.dart';
import '../platform/windows/process_media_tool.dart';
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
