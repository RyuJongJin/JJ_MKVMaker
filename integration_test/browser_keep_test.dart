import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:jj_mkvmaker/app/app_controller.dart';
import 'package:jj_mkvmaker/app/bookmarks_controller.dart';
import 'package:jj_mkvmaker/app/download_manager.dart';
import 'package:jj_mkvmaker/platform/windows/desktop_storage_service.dart';
import 'package:jj_mkvmaker/platform/windows/process_media_tool.dart';
import 'package:jj_mkvmaker/services/platform_services.dart';
import 'package:jj_mkvmaker/ui/browser_page.dart';
import 'package:path/path.dart' as p;

/// 실제 Edge(WebView2): MKV 화면 ↔ 브라우저를 여러 번 오가도 보던 페이지를 다시 읽지 않고 그대로 이어진다
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('MKV 화면 ↔ 브라우저: 페이지 · 세션 유지', (tester) async {
    var hits = 0;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      if (req.uri.path == '/page') hits++;
      req.response
        ..headers.contentType = ContentType.html
        ..write('<html><head><meta charset="utf-8"><title>JJ 유지</title></head><body>유지</body></html>');
      await req.response.close();
    });
    final url = 'http://127.0.0.1:${server.port}/page';
    final dataDir = Directory.systemTemp.createTempSync('jj_keep_').path;

    final c = AppController(PlatformServices(mediaTool: ProcessMediaTool('x', 'y'), storage: DesktopStorageService()));
    c.settings
      ..webViewDataDir = dataDir
      ..homeUrl = url;
    final bm = BookmarksController(p.join(dataDir, 'bm.json'));
    final d = DownloadManager(backends: const [], settings: () => c.settings, readClipboard: () async => null);
    final navKey = GlobalKey<NavigatorState>();

    await tester.pumpWidget(MaterialApp(
      navigatorKey: navKey,
      navigatorObservers: [browserRouteObserver],
      home: const Scaffold(body: Text('MKV 화면')),
    ));
    Future<void> wait(int ms) async {
      await tester.runAsync(() => Future<void>.delayed(Duration(milliseconds: ms)));
      await tester.pump();
    }

    String address() {
      final f = find.byType(TextField);
      return f.evaluate().isEmpty ? '' : tester.widget<TextField>(f.first).controller!.text;
    }

    // 브라우저를 열어 페이지를 읽는다
    BrowserPage.open(navKey.currentState!, c: c, downloads: d, bookmarks: bm);
    for (var i = 0; i < 100 && hits == 0; i++) {
      await wait(100);
    }
    await wait(1000);
    expect(hits, 1);

    for (var round = 1; round <= 3; round++) {
      // MKV 화면으로 (브라우저 화면이 닫힌다) → 다시 브라우저
      navKey.currentState!.popUntil((r) => r.isFirst);
      for (var i = 0; i < 10; i++) {
        await wait(100);
      }
      expect(find.text('MKV 화면'), findsOneWidget);
      BrowserPage.open(navKey.currentState!, c: c, downloads: d, bookmarks: bm);
      for (var i = 0; i < 25; i++) {
        await wait(100);
      }
      // ignore: avoid_print
      print('RESULT $round번째: 주소 ${address()} · 페이지 요청 $hits번 · 브라우저 ${find.byType(BrowserPage).evaluate().length} · '
          '입력칸 ${find.byType(TextField).evaluate().length} · MKV ${find.text('MKV 화면').evaluate().length}');
      expect(address(), url, reason: '$round번째: 보던 주소');
      expect(hits, 1, reason: '$round번째: 페이지를 다시 읽지 않음 (같은 웹뷰)');
    }
    await server.close(force: true);
  }, timeout: const Timeout(Duration(minutes: 3)));
}
