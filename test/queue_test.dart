import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jj_mkvmaker/app/app_controller.dart';
import 'package:jj_mkvmaker/app/download_manager.dart';
import 'package:jj_mkvmaker/app/settings.dart';
import 'package:jj_mkvmaker/core/download_detect.dart';
import 'package:jj_mkvmaker/core/models.dart';
import 'package:jj_mkvmaker/main.dart';
import 'package:jj_mkvmaker/platform/windows/desktop_storage_service.dart';
import 'package:jj_mkvmaker/platform/windows/ytdlp_backend.dart';
import 'package:jj_mkvmaker/services/downloader.dart';
import 'package:jj_mkvmaker/services/media_tool.dart';
import 'package:jj_mkvmaker/services/platform_services.dart';
import 'package:jj_mkvmaker/ui/settings_page.dart';
import 'package:path/path.dart' as p;

/// 시작만 하고 끝내기는 테스트가 직접 (finish)
class _Backend implements DownloadBackend {
  @override
  final DownloadKind kind;
  _Backend(this.kind);
  final running = <DownloadTask, void Function()>{};
  (String, List<PlaylistEntry>)? playlist;

  @override
  Future<(String, List<PlaylistEntry>)?> expandPlaylist(String url) async => playlist;
  @override
  Future<void> start(DownloadTask t, void Function() changed) async {
    t.state = DownloadState.downloading;
    running[t] = changed;
    changed();
  }

  void finish(DownloadTask t) {
    t.state = DownloadState.done;
    running.remove(t)!();
  }

  @override
  Future<void> pause(DownloadTask t) async {
    running.remove(t);
    t.state = DownloadState.paused;
  }

  @override
  Future<void> cancel(DownloadTask t) async {
    running.remove(t);
    t.state = DownloadState.cancelled;
  }

  @override
  Future<void> shutdown() async {}
}

/// 동시에 몇 개가 실행되는지 재는 가짜 FFmpeg
class _Tool implements MediaTool {
  var now = 0, peak = 0;
  @override
  Future<String?> version() async => 'ffmpeg test';
  @override
  Future<Set<String>> encoders() async => {'libx264'};
  @override
  Future<MediaInfo> probe(String path) async => const MediaInfo(duration: Duration(seconds: 1));
  @override
  Future<void> runFfmpeg(List<String> args, {Duration? duration, ProgressCallback? onProgress}) async {
    now++;
    if (now > peak) peak = now;
    await Future<void>.delayed(const Duration(milliseconds: 30));
    now--;
  }

  @override
  void cancel() {}
}

void main() {
  group('YouTube 주소 · 형식', () {
    test('재생목록 판별', () {
      expect(youtubePlaylistId('https://www.youtube.com/playlist?list=PLabc_123'), 'PLabc_123');
      expect(youtubePlaylistId('https://www.youtube.com/watch?v=x1&list=PLxyz&index=3'), 'PLxyz');
      expect(youtubePlaylistId('https://www.youtube.com/watch?v=x1&list=RDx1'), isNull); // 믹스
      expect(youtubePlaylistId('https://www.youtube.com/watch?v=x1'), isNull);
    });
    test('폴더 이름 정리', () {
      expect(safeFolderName('My: List / 2024?'), 'My List 2024');
      expect(safeFolderName('끝 점...'), '끝 점');
    });
    test('형식 인수', () {
      expect(ytDlpFormatArgs(YtContainer.mp4, YtQuality.p1080).join(' '),
          '-S res:1080,ext:mp4:m4a --merge-output-format mp4 --remux-video mp4');
      expect(ytDlpFormatArgs(YtContainer.webm, YtQuality.best).join(' '), '-S ext:webm:webm --merge-output-format webm');
      // Android: 같은 크기면 H.264 (하드웨어 재생)
      expect(ytDlpFormatArgs(YtContainer.mp4, YtQuality.p1080, preferH264: true).take(2).join(' '),
          '-S res:1080,vcodec:h264,ext:mp4:m4a');
      expect(ytDlpFormatArgs(YtContainer.mp3, YtQuality.p720), contains('mp3'));
      expect(ytDlpCookieArgs(browser: 'firefox'), ['--cookies-from-browser', 'firefox']);
      expect(ytDlpCookieArgs(browser: 'firefox', file: r'C:\c.txt'), ['--cookies', r'C:\c.txt']);
      expect(ytDlpCookieArgs(), isEmpty);
      expect(friendlyYtDlpError('ERROR: [youtube] x: Sign in to confirm you’re not a bot'), contains('로봇 확인'));
    });
  });

  group('다운로드 대기열 · 재생목록', () {
    late _Backend video;
    late AppSettings settings;
    late DownloadManager d;
    setUp(() {
      video = _Backend(DownloadKind.video);
      settings = AppSettings()
        ..downloadRoot = r'D:\dl'
        ..maxParallelDownloads = 2;
      d = DownloadManager(backends: [video], settings: () => settings, readClipboard: () async => null);
    });
    tearDown(() => d.dispose());

    test('동시 2개, 끝나면 다음 차례 (들어온 순서)', () async {
      final ts = [for (var i = 1; i <= 5; i++) d.add('https://youtu.be/v$i')!];
      await Future<void>.delayed(Duration.zero);
      expect(ts.map((t) => t.state.name), ['downloading', 'downloading', 'queued', 'queued', 'queued']);
      video.finish(ts[0]);
      await Future<void>.delayed(Duration.zero);
      expect(ts[2].state, DownloadState.downloading);
      expect(ts[3].state, DownloadState.queued);
      // 일시정지하면 자리가 비어 다음이 시작, 재개하면 대기열로
      await d.pause([ts[1]]);
      expect(ts[3].state, DownloadState.downloading);
      await d.resume([ts[1]]);
      expect(ts[1].state, DownloadState.queued);
      settings.maxParallelDownloads = 0; // 무한
      await d.resume(const []);
      expect(ts.where((t) => t.state == DownloadState.downloading), hasLength(4));
    });

    test('재생목록 → 영상별 항목, 하위 폴더, 이미 받는 영상 제외', () async {
      d.add('https://youtu.be/b');
      video.playlist = ('My: Playlist', const [
        PlaylistEntry('https://youtu.be/a', '첫째'),
        PlaylistEntry('https://youtu.be/b', '둘째'),
        PlaylistEntry('https://youtu.be/c', '셋째'),
      ]);
      final holder = d.add('https://www.youtube.com/playlist?list=PLtest')!;
      expect(holder.expanding, isTrue);
      expect(holder.title, contains('재생목록 불러오는 중'));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      final titles = d.tasks.map((t) => t.title).toList();
      expect(titles.take(2), ['[1/3] 첫째', '[3/3] 셋째']);
      expect(d.tasks.first.dir, p.join(r'D:\dl', 'jj_yt-dlp', 'My Playlist'));
      expect(d.tasks.contains(holder), isFalse);

      settings.ytExpandPlaylists = false;
      final single = d.add('https://www.youtube.com/watch?v=z&list=PLother')!;
      expect(single.expanding, isFalse);
    });
  });

  test('MKV 동시 변환 수: 1 · 2 · 무한', () async {
    for (final (limit, expected) in [(1, 1), (2, 2), (0, 5)]) {
      final tool = _Tool();
      final c = AppController(PlatformServices(mediaTool: tool, storage: DesktopStorageService()));
      await c.init();
      c.settings.maxParallelJobs = limit;
      final dir = Directory.systemTemp.createTempSync('jj_par_');
      for (var i = 0; i < 5; i++) {
        final f = File(p.join(dir.path, 'v$i.mp4'))..writeAsStringSync(''); // 없는 파일은 만들지 않으므로
        c.videos.add(VideoItem(f.path)..info = const MediaInfo(duration: Duration(seconds: 1)));
      }
      await c.buildAll();
      dir.deleteSync(recursive: true);
      expect(tool.peak, expected, reason: '최대 $limit');
      expect(c.videos.every((v) => v.status == JobStatus.done), isTrue);
    }
  });

  test('실제 yt-dlp 재생목록 읽기 (JJ_NET_TESTS=1)', () async {
    final exe = p.join(Directory.current.path, 'third_party', 'tools', 'windows', 'yt-dlp.exe');
    if (Platform.environment['JJ_NET_TESTS'] != '1' || !File(exe).existsSync()) {
      return markTestSkipped('인터넷 테스트 꺼짐');
    }
    final b = YtDlpBackend(ytdlp: exe, deno: p.join(p.dirname(exe), 'deno.exe'));
    final r = await b.expandPlaylist('https://www.youtube.com/watch?v=x&list=PLzH6n4zXuckpfMu_4Ff8E7Z1behQks5ba');
    expect(r, isNotNull);
    expect(r!.$1, contains('Data Analysis'));
    expect(r.$2.length, greaterThanOrEqualTo(10));
    expect(r.$2.first.url, startsWith('https://www.youtube.com/watch?v='));
  }, timeout: const Timeout(Duration(minutes: 2)));

  testWidgets('작업 기록 ✕ → 숨김, 아래 줄 누르면 다시 보임', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final c = AppController(PlatformServices(mediaTool: _Tool(), storage: DesktopStorageService()));
    await c.init();
    await tester.pumpWidget(JjCapCutApp(controller: c));
    expect(find.byTooltip('작업 기록 숨기기'), findsOneWidget);
    await tester.tap(find.byTooltip('작업 기록 숨기기'));
    await tester.pump();
    expect(c.settings.showLog, isFalse);
    expect(find.text('작업 기록 보기'), findsOneWidget);
    await tester.tap(find.text('작업 기록 보기'));
    await tester.pump();
    expect(c.settings.showLog, isTrue);
    expect(find.byTooltip('작업 기록 숨기기'), findsOneWidget);
  });

  testWidgets('환경 설정: 새 항목이 깨지지 않고 보임', (tester) async {
    // 스크롤 없이 모두 보이도록 세로로 긴 화면
    tester.view.physicalSize = const Size(1400, 3200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final c = AppController(PlatformServices(mediaTool: _Tool(), storage: DesktopStorageService()));
    await tester.pumpWidget(MaterialApp(home: SettingsPage(c: c)));
    await tester.pumpAndSettle();
    for (final t in ['YouTube 받을 형식', 'YouTube 화질', '재생목록 주소면 목록 전체 받기', 'YouTube 쿠키 (로봇 확인이 나올 때)',
      '동시 다운로드 수', '동시 MKV 변환 수']) {
      expect(find.text(t), findsOneWidget, reason: t);
    }
    expect(find.text('MP4 (동영상)'), findsOneWidget);
    expect(find.text('3개'), findsOneWidget); // 동시 다운로드 기본
    expect(find.text('5개'), findsOneWidget); // 동시 변환 기본
  });

  testWidgets('개수 선택: 1 · 5 · 10 · 무한 · 직접 입력', (tester) async {
    var value = 5;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: StatefulBuilder(
          builder: (_, set) => CountSelector(value: value, onChanged: (n) => set(() => value = n)),
        ),
      ),
    ));
    await tester.tap(find.text('5개'));
    await tester.pumpAndSettle();
    for (final t in ['1개', '10개', '무한', '직접 입력…']) {
      expect(find.text(t), findsWidgets);
    }
    await tester.tap(find.text('직접 입력…').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '7');
    await tester.tap(find.text('확인'));
    await tester.pumpAndSettle();
    expect(value, 7);
    expect(find.text('7개'), findsOneWidget);
  });
}
