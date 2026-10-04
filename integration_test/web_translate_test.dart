import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:jj_mkvmaker/app/app_controller.dart';
import 'package:jj_mkvmaker/app/bookmarks_controller.dart';
import 'package:jj_mkvmaker/platform/windows/desktop_storage_service.dart';
import 'package:jj_mkvmaker/platform/windows/process_media_tool.dart';
import 'package:jj_mkvmaker/services/platform_services.dart';
import 'package:jj_mkvmaker/ui/browser_page.dart';
import 'package:path/path.dart' as p;

/// 실제 웹뷰 (Windows: Edge WebView2 · Android: 시스템 WebView) + 실제 Google 번역:
/// 페이지 자동 번역 · 원문 보기 · JavaScript 끄기.
/// Android 는 JavaScript 를 끄면 앱이 페이지를 읽을 수 없어, 페이지 스크립트가 돌면 서버로 보내는 신호 (/ran) 로 확인한다.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('웹 페이지 번역 · JavaScript 끄기', (tester) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var pageLoads = 0, scriptRuns = 0;
    server.listen((req) async {
      if (req.uri.path == '/ran') {
        scriptRuns++;
        req.response.statusCode = 204;
        await req.response.close();
        return;
      }
      if (req.uri.path != '/') {
        req.response.statusCode = 404;
        await req.response.close();
        return;
      }
      pageLoads++;
      req.response
        ..headers.contentType = ContentType.html
        ..write('<html lang="en"><head><meta charset="utf-8"><title>JJ</title></head><body>'
            '<h1 id="h">Hello world</h1>'
            '<p id="p">  Download the video  </p>'
            '<code id="c">Hello code</code>'
            '<p id="k">안녕하세요 여러분</p>'
            '<input id="i" placeholder="Search here">'
            '<div id="js">no script</div>'
            '<script>document.getElementById("js").textContent = "script ran"; fetch("/ran");'
            'setTimeout(function(){var d=document.createElement("p");d.id="late";d.textContent="Good morning";'
            'document.body.appendChild(d);}, 1500);</script>'
            '</body></html>');
      await req.response.close();
    });
    final url = 'http://127.0.0.1:${server.port}/';
    final dataDir = Directory.systemTemp.createTempSync('jj_webview_').path;

    final c = AppController(PlatformServices(mediaTool: ProcessMediaTool('x', 'y'), storage: DesktopStorageService()));
    c.settings
      ..webViewDataDir = dataDir
      ..uiLanguage = 'ko'
      ..webTranslate = true;
    final bm = BookmarksController(p.join(dataDir, 'bm.json'));
    await tester.pumpWidget(MaterialApp(home: BrowserPage(c: c, bookmarks: bm, initialUrl: url)));

    Future<Map<String, String>> dom() async {
      final r = await tester.runAsync(() async => BrowserPage.debugNav?.evaluate(
          'JSON.stringify({h: (document.getElementById("h")||{}).textContent, p: (document.getElementById("p")||{}).textContent,'
          ' c: (document.getElementById("c")||{}).textContent, k: (document.getElementById("k")||{}).textContent,'
          ' i: (document.getElementById("i")||{getAttribute:function(){}}).getAttribute("placeholder"),'
          ' js: (document.getElementById("js")||{}).textContent, late: (document.getElementById("late")||{}).textContent})'));
      if (r == null) return {};
      final v = jsonDecode(r is String ? r : jsonEncode(r));
      // 없는 요소는 JSON 에서 빠진다 → 빈 글로
      final m = (v is String ? jsonDecode(v) : v) as Map;
      return {for (final k in const ['h', 'p', 'c', 'k', 'i', 'js', 'late']) k: '${m[k] ?? ''}'};
    }

    final hangul = RegExp('[가-힣]');
    Future<Map<String, String>> waitFor(bool Function(Map<String, String>) ok, String what) async {
      var d = <String, String>{};
      for (var i = 0; i < 300; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
        await tester.pump();
        d = await dom();
        if (d.isNotEmpty && ok(d)) break;
      }
      // ignore: avoid_print
      print('RESULT $what: $d');
      return d;
    }

    // 1. 자동 번역 (JavaScript 켬): 영어 글 · 안내 글은 한국어로, 코드 · 한국어 글은 그대로, 나중에 생긴 글도
    var d = await waitFor((d) => hangul.hasMatch(d['h']!) && hangul.hasMatch(d['late']!), '자동 번역');
    expect(d['h'], matches(hangul));
    expect(d['p'], matches(hangul));
    expect(d['p'], startsWith('  ')); // 앞뒤 빈칸은 그대로
    expect(d['i'], matches(hangul));
    expect(d['late'], matches(hangul));
    expect(d['c'], 'Hello code');
    expect(d['k'], '안녕하세요 여러분');
    expect(d['js'], isNot('no script')); // 페이지 스크립트가 돌았다 (그 글도 번역됨)

    // 2. 번역 버튼 → 원문
    await tester.tap(find.byTooltip('원문 보기 (번역 끄기)'));
    d = await waitFor((d) => d['h'] == 'Hello world', '원문 보기');
    expect(d['h'], 'Hello world');
    expect(d['p'], '  Download the video  ');
    expect(d['i'], 'Search here');
    expect(d['late'], 'Good morning');
    expect(d['js'], 'script ran');

    Future<void> waitServer(bool Function() ok) async {
      for (var i = 0; i < 300 && !ok(); i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
        await tester.pump();
      }
    }

    // 3. JavaScript 끄기 → 페이지를 다시 읽고, 페이지 스크립트는 돌지 않는다
    expect(scriptRuns, greaterThan(0));
    final loads = pageLoads, runs = scriptRuns;
    await c.updateSettings((s) => s.webJavaScript = false);
    await waitServer(() => pageLoads > loads);
    await tester.runAsync(() => Future<void>.delayed(const Duration(seconds: 3)));
    // ignore: avoid_print
    print('RESULT JavaScript 끔: 다시 읽음 ${pageLoads - loads}번, 스크립트 실행 ${scriptRuns - runs}번');
    expect(pageLoads, greaterThan(loads));
    expect(scriptRuns, runs); // 다시 읽은 페이지의 스크립트가 돌지 않았다

    if (Platform.isAndroid) {
      // 4. Android 웹뷰는 JavaScript 를 끄면 앱이 넣는 스크립트도 막는다 → 번역 · 페이지 읽기가 안 됨 (설정 설명대로)
      expect(await dom(), isEmpty);
      await tester.tap(find.byTooltip('이 페이지를 한국어(으)로 번역'));
      await tester.runAsync(() => Future<void>.delayed(const Duration(seconds: 3)));
      await tester.pump();
      // ignore: avoid_print
      print('RESULT JavaScript 끈 채 번역 (Android): 페이지 읽기 ${await dom()} → 번역 안 됨 (예상대로)');
    } else {
      d = await waitFor((d) => d['js'] == 'no script', 'JavaScript 끔 (페이지)');
      expect(d['js'], 'no script');
      expect(d['late'], ''); // setTimeout 도 돌지 않음

      // 4. Edge 는 JavaScript 를 꺼도 번역 버튼으로 번역된다 (앱이 넣는 스크립트는 실행)
      await tester.tap(find.byTooltip('이 페이지를 한국어(으)로 번역'));
      d = await waitFor((d) => hangul.hasMatch(d['h']!), 'JavaScript 끈 채 번역');
      expect(d['h'], matches(hangul));
      expect(d['js'], matches(hangul)); // "no script" 도 번역
    }

    // 5. 다시 켜기 → 다시 읽고 페이지 스크립트가 돈다, 번역도 다시
    final runs2 = scriptRuns;
    await c.updateSettings((s) => s.webJavaScript = true);
    await waitServer(() => scriptRuns > runs2);
    expect(scriptRuns, greaterThan(runs2));
    d = await waitFor((d) => d['late']!.isNotEmpty && hangul.hasMatch(d['h']!), 'JavaScript 다시 켬');
    expect(d['late'], isNotEmpty); // setTimeout 이 다시 돈다
    expect(d['h'], matches(hangul));

    await tester.pumpWidget(const SizedBox());
    await server.close(force: true);
  }, timeout: const Timeout(Duration(minutes: 3)));
}
