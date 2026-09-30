import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:jj_mkvmaker/app/app_controller.dart';
import 'package:jj_mkvmaker/app/bookmarks_controller.dart';
import 'package:jj_mkvmaker/app/download_manager.dart';
import 'package:jj_mkvmaker/core/languages.dart';
import 'package:jj_mkvmaker/core/models.dart';
import 'package:jj_mkvmaker/core/output_paths.dart';
import 'package:jj_mkvmaker/services/platform_services.dart';
import 'package:jj_mkvmaker/ui/browser_page.dart';
import 'package:path/path.dart' as p;

/// 실제 NLLB + 실제 Edge(WebView2): 브라우저를 보면서 영어 자막 → 한국어 번역 → MKV 를
/// 대기열로 돌리고, 화면 분할 "작업 현황" 에서 진행을 확인 (모델이 JJ_MKVMAKER_MODELS 에 있어야 함)
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('브라우저 + 작업 현황: 영어 자막 → 한국어 번역 → MKV (대기열)', (tester) async {
    final dir = Directory.systemTemp.createTempSync('jj_split_');
    final video = p.join(dir.path, 'movie.mp4');
    final r = await Process.run('ffmpeg', [
      '-y', '-f', 'lavfi', '-i', 'testsrc=size=320x240:rate=10', '-f', 'lavfi', '-i', 'sine',
      '-t', '8', '-c:v', 'libx264', '-pix_fmt', 'yuv420p', '-c:a', 'aac', video,
    ]);
    expect(r.exitCode, 0, reason: '${r.stderr}');
    final en = p.join(dir.path, 'movie.en.srt');
    File(en).writeAsStringSync('1\n00:00:01,000 --> 00:00:03,000\nGood morning, how are you today?\n\n'
        '2\n00:00:04,000 --> 00:00:06,000\nI want to watch this movie with my family.\n\n');

    final c = AppController(PlatformServices.create());
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      req.response
        ..headers.contentType = ContentType.html
        ..write('<html><head><title>JJ</title></head><body>hello</body></html>');
      await req.response.close();
    });
    await tester.runAsync(() async {
      await c.init();
      await c.addVideos([video]);
    });
    c.settings.webViewDataDir = Directory.systemTemp.createTempSync('jj_webview_').path;
    final v = c.videos.single;
    // 같은 폴더의 movie.en.srt 가 자동으로 잡힘
    final s = v.subtitles.firstWhere((x) => x.path != null && p.equals(x.path!, en));
    // ignore: avoid_print
    print('RESULT 자동 추가된 자막: ${s.displayName} 언어=${s.language.code}');

    final bm = BookmarksController(p.join(dir.path, 'bm.json'));
    final d = DownloadManager(backends: const [], settings: () => c.settings, readClipboard: () async => null);
    await tester.pumpWidget(MaterialApp(
        home: BrowserPage(c: c, bookmarks: bm, downloads: d, initialUrl: 'http://127.0.0.1:${server.port}/')));
    await tester.pump(const Duration(milliseconds: 500));

    // 번역 시작 + 바로 MKV 만들기 (대기열)
    final sw = Stopwatch()..start();
    final tr = c.translateSubtitle(v, s, {languageOf('ko')});
    final mkv = c.buildAll();
    await tester.pump();
    expect(c.busy, isTrue);
    expect(c.pendingJobs, ['MKV 만들기']);

    // 화면 분할 열기 → 진행 표시
    await tester.tap(find.byTooltip('작업 현황 보기 · 화면 분할 (Ctrl+Shift+J)'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('작업 현황'), findsOneWidget);
    expect(find.textContaining('▶ 자막 번역'), findsOneWidget);
    expect(find.textContaining('MKV 만들기  (대기)'), findsOneWidget);
    final phases = <String>{};
    while (c.busy) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
      await tester.pump();
      if (v.phase != null) phases.add(v.phase!.replaceAll(RegExp(r'\d+%'), '%'));
    }
    await tester.runAsync(() => Future.wait([tr, mkv]));
    await tester.pump();
    // ignore: avoid_print
    print('RESULT 걸린 시간 ${sw.elapsedMilliseconds}ms, 단계: ${phases.join(' | ')}');
    // ignore: avoid_print
    print(c.logs.join('\n'));
    expect(find.text('쉬는 중'), findsOneWidget);
    expect(find.text('MKV 완성'), findsOneWidget);

    final koPath = languageSubtitlePath(video, languageOf('ko'));
    final ko = File(koPath).readAsStringSync();
    // ignore: avoid_print
    print('RESULT --- ko ---\n$ko');
    expect(RegExp(r'[가-힣]').hasMatch(ko), isTrue);
    expect(ko, contains('00:00:04,000 --> 00:00:06,000'));
    expect(v.status, JobStatus.done, reason: v.message);
    final info = await tester.runAsync(() => c.services.mediaTool.probe(outputMkvPath(video)));
    final langs = info!.ofType('subtitle').map((x) => x.language).toList();
    // ignore: avoid_print
    print('RESULT MKV 자막 언어: $langs');
    expect(langs, containsAll(['kor', 'eng']));

    await tester.pumpWidget(const SizedBox());
    d.dispose();
    await server.close(force: true);
  }, timeout: const Timeout(Duration(minutes: 15)));
}
