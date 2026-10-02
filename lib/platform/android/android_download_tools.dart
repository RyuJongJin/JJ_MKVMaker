import 'dart:async';

import 'package:flutter/services.dart';

import '../../app/settings.dart';
import '../../core/download_detect.dart';
import '../../services/downloader.dart';
import '../windows/aria2_backend.dart';
import '../windows/ytdlp_backend.dart';

/// Android 의 다운로드 프로그램 (youtubedl-android 가 앱에 넣은 Python · yt-dlp · ffmpeg · aria2c).
/// MainActivity.kt 의 "downloadToolsInit" 이 처음 켤 때 풀고, 직접 실행할 경로 · 환경 변수를 알려 준다.
/// 실행은 Windows 와 같은 [YtDlpBackend] · [Aria2Backend] 가 한다.
class AndroidDownloadTools {
  static const _ch = MethodChannel('jj_mkvmaker/android');

  final String python, ytdlp, ffmpeg, quickjs, aria2c, cert, version;
  final Map<String, String> environment;

  AndroidDownloadTools._(Map<Object?, Object?> m)
    : python = m['python'] as String,
      ytdlp = m['ytdlp'] as String,
      ffmpeg = m['ffmpeg'] as String,
      quickjs = m['quickjs'] as String,
      aria2c = m['aria2c'] as String,
      cert = m['cert'] as String,
      version = m['version'] as String? ?? '',
      environment = (m['env'] as Map).cast<String, String>();

  static Future<AndroidDownloadTools>? _ready;

  /// 작업 기록에 남길 곳 (main 에서 정함)
  static void Function(String)? log;

  /// 한 번만 준비한다 (처음 켤 때 Python 등을 푸느라 몇 초 걸림).
  /// YouTube 가 바뀌면 오래된 yt-dlp 는 받지 못하므로 준비할 때 새 yt-dlp 가 있으면 받는다 (못 받아도 계속).
  static Future<AndroidDownloadTools> ready() {
    final f = _ready ??= _prepare();
    // 실패하면 (저장 공간 부족 등) 다음에 다시 시도
    f.then(
      (_) {},
      onError: (Object _) {
        if (identical(_ready, f)) _ready = null;
      },
    );
    return f;
  }

  static Future<AndroidDownloadTools> _prepare() async {
    final m = await _ch.invokeMethod<Map<Object?, Object?>>('downloadToolsInit');
    try {
      final r = await _ch.invokeMethod<String>('downloadToolsUpdate').timeout(const Duration(seconds: 30));
      if (r == 'DONE') log?.call('yt-dlp 를 새 버전으로 바꿨습니다');
    } catch (e) {
      log?.call('yt-dlp 업데이트 확인 실패 (지금 버전으로 받습니다): $e');
    }
    final tools = AndroidDownloadTools._(m!);
    log?.call('다운로드 준비됨: yt-dlp ${tools.version}');
    return tools;
  }

  /// 다운로드 엔진: yt-dlp (동영상 사이트) · aria2 (토렌트). 실제 엔진은 처음 쓸 때 준비된다.
  static List<DownloadBackend> backends(AppSettings Function() s) => [
    _Deferred(DownloadKind.video, () async {
      final t = await ready();
      return YtDlpBackend(
        ytdlp: t.python,
        prefixArgs: [t.ytdlp, '--no-cache-dir'],
        environment: t.environment,
        // --ffmpeg-location 은 파일 경로도 받는다 (libffmpeg.so = ffmpeg 실행 파일)
        ffmpegDir: t.ffmpeg,
        jsRuntime: 'quickjs:${t.quickjs}',
        formatArgs: () => ytDlpFormatArgs(s().ytContainer, s().ytQuality),
        cookieArgs: () => ytDlpCookieArgs(
          browser: s().ytCookiesBrowser,
          file: s().ytCookiesFile,
          internalCookieFile: s().internalCookieFile,
        ),
        fallbackCookieArgs: () =>
            ytDlpCookieArgs(browser: internalBrowserCookies, internalCookieFile: s().internalCookieFile),
      );
    }),
    _Deferred(DownloadKind.torrent, () async {
      final t = await ready();
      return Aria2Backend(aria2c: t.aria2c, environment: t.environment, extraArgs: ['--ca-certificate=${t.cert}']);
    }),
  ];
}

/// 처음 쓸 때 엔진을 준비하는 다운로드 엔진 (앱 시작을 늦추지 않도록)
class _Deferred implements DownloadBackend {
  @override
  final DownloadKind kind;
  final Future<DownloadBackend> Function() _create;
  Future<DownloadBackend>? _backend;

  _Deferred(this.kind, this._create);

  Future<DownloadBackend> get _b {
    final f = _backend ??= _create();
    // 실패하면 다음에 다시 시도
    f.then(
      (_) {},
      onError: (Object _) {
        if (identical(_backend, f)) _backend = null;
      },
    );
    return f;
  }

  @override
  Future<(String, List<PlaylistEntry>)?> expandPlaylist(String url) async => (await _b).expandPlaylist(url);

  @override
  Future<void> start(DownloadTask t, void Function() changed) async {
    final DownloadBackend b;
    try {
      b = await _b;
    } catch (e) {
      t
        ..state = DownloadState.failed
        ..error = '다운로드 프로그램을 준비할 수 없습니다: $e';
      changed();
      return;
    }
    return b.start(t, changed);
  }

  @override
  Future<void> pause(DownloadTask t) async => (await _b).pause(t);

  @override
  Future<void> cancel(DownloadTask t) async => (await _b).cancel(t);

  @override
  Future<void> shutdown() async {
    if (_backend != null) await (await _backend!).shutdown();
  }
}
