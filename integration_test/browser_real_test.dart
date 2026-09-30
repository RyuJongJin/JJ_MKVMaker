import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:jj_mkvmaker/app/app_controller.dart';
import 'package:jj_mkvmaker/app/bookmarks_controller.dart';
import 'package:jj_mkvmaker/app/download_manager.dart';
import 'package:jj_mkvmaker/core/download_detect.dart';
import 'package:jj_mkvmaker/platform/windows/desktop_storage_service.dart';
import 'package:jj_mkvmaker/platform/windows/process_media_tool.dart';
import 'package:jj_mkvmaker/platform/windows/ytdlp_backend.dart';
import 'package:jj_mkvmaker/services/platform_services.dart';
import 'package:jj_mkvmaker/ui/browser_page.dart';
import 'package:path/path.dart' as p;

/// 실제 Edge(WebView2): 페이지 열기 · 동영상 감지 · 쿠키 저장 → yt-dlp 가 같은 쿠키를 읽는지
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('앱 안 브라우저 → 쿠키 → yt-dlp', (tester) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      req.response
        ..headers.contentType = ContentType.html
        ..headers.add('Set-Cookie', 'jjserver=ok; Max-Age=3600; Path=/')
        ..write('<html><head><meta charset="utf-8"><title>JJ 테스트</title></head><body>'
            '<video width="200" height="100"></video>'
            '<script>document.cookie = "jjscript=hello; max-age=3600; path=/";</script></body></html>');
      await req.response.close();
    });
    final url = 'http://127.0.0.1:${server.port}/';
    final dataDir = Directory.systemTemp.createTempSync('jj_webview_').path;

    final c = AppController(PlatformServices(mediaTool: ProcessMediaTool('x', 'y'), storage: DesktopStorageService()));
    c.settings.webViewDataDir = dataDir;
    final bm = BookmarksController(p.join(dataDir, 'bm.json'));
    final d = DownloadManager(backends: const [], settings: () => c.settings, readClipboard: () async => null);

    await tester.pumpWidget(MaterialApp(home: BrowserPage(c: c, bookmarks: bm, downloads: d, initialUrl: url)));

    // 페이지가 열리고 <video> 를 찾을 때까지 (최대 30초)
    bool videoSeen = false;
    for (var i = 0; i < 300 && !videoSeen; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump();
      final btn = tester.widget<FilledButton>(find.ancestor(
          of: find.text('다운로드'), matching: find.byWidgetPredicate((w) => w is FilledButton)));
      videoSeen = btn.onPressed != null;
    }
    // ignore: avoid_print
    print('RESULT 동영상 감지(다운로드 버튼 켜짐): $videoSeen');
    expect(videoSeen, isTrue);

    // YouTube 에 로그인한 것처럼 쿠키를 심고 (HttpOnly 포함) [다운로드] → cookies.txt 내보내기
    final env = await tester.runAsync(() => browserEnvironment(dataDir));
    final cm = CookieManager.instance(webViewEnvironment: env);
    final future = DateTime.now().add(const Duration(days: 30)).millisecondsSinceEpoch;
    await tester.runAsync(() async {
      await cm.setCookie(url: WebUri('https://www.youtube.com/'), name: 'LOGIN_INFO', value: 'jj-login',
          domain: '.youtube.com', isSecure: true, isHttpOnly: true, expiresDate: future);
      await cm.setCookie(url: WebUri('https://www.youtube.com/'), name: 'PREF', value: 'hl=ko',
          domain: '.youtube.com', isSecure: true, expiresDate: future);
    });
    await tester.tap(find.text('다운로드'));
    for (var i = 0; i < 50 && c.settings.internalCookieFile.isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump();
    }
    final cookieFile = c.settings.internalCookieFile;
    final text = cookieFile.isEmpty ? '' : File(cookieFile).readAsStringSync();
    // ignore: avoid_print
    print('RESULT 내보낸 쿠키 파일: "$cookieFile"\n${text.split('\n').where((l) => l.contains('youtube')).join('\n')}');
    expect(text, contains('#HttpOnly_.youtube.com'));
    expect(text, contains('LOGIN_INFO\tjj-login'));
    // 만료 시각은 초 단위 (지금부터 약 30일 뒤)
    final expLine = text.split('\n').firstWhere((l) => l.contains('LOGIN_INFO'));
    final exp = int.parse(expLine.split('\t')[4]);
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    expect(exp, inInclusiveRange(now + 29 * 86400, now + 31 * 86400));

    // yt-dlp 에 넘길 인수는 내보낸 파일이 우선 (브라우저가 켜져 있어도 됨)
    final args = ytDlpCookieArgs(
        browser: internalBrowserCookies,
        internalProfile: c.settings.internalCookieProfile,
        internalCookieFile: cookieFile);
    expect(args, ['--cookies', cookieFile]);

    // yt-dlp 가 이 파일을 문제없이 읽는지 (브라우저가 켜진 상태에서)
    final ytdlp = p.join(Directory.current.path, 'third_party', 'tools', 'windows', 'yt-dlp.exe');
    final copy = p.join(dataDir, 'check.txt');
    File(cookieFile).copySync(copy);
    final r = await tester.runAsync(() => Process.run(ytdlp,
        ['-v', '--simulate', '--cookies', copy, url], environment: {'PYTHONIOENCODING': 'utf-8'}));
    final log = '${r!.stdout}\n${r.stderr}';
    // yt-dlp 는 읽은 쿠키를 같은 파일에 다시 저장한다 → 로그인 쿠키가 남아 있으면 제대로 읽은 것
    final saved = File(copy).readAsStringSync();
    final cookieErrors = log.split('\n').where((l) => l.startsWith('ERROR') && l.toLowerCase().contains('cookie'));
    // ignore: avoid_print
    print('RESULT yt-dlp 가 다시 저장한 파일에 LOGIN_INFO: ${saved.contains('LOGIN_INFO')}, 쿠키 오류 줄: ${cookieErrors.length}');
    expect(saved, contains('This file is generated by yt-dlp'));
    expect(saved, contains('LOGIN_INFO\tjj-login'));
    expect(cookieErrors, isEmpty);
    expect(locateTool('yt-dlp'), isNotEmpty);
    await tester.pumpWidget(const SizedBox());

    d.dispose();
    await server.close(force: true);
  }, timeout: const Timeout(Duration(minutes: 3)));
}
