import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jj_mkvmaker/app/app_controller.dart';
import 'package:jj_mkvmaker/app/bookmarks_controller.dart';
import 'package:jj_mkvmaker/app/download_manager.dart';
import 'package:jj_mkvmaker/app/settings.dart';
import 'package:jj_mkvmaker/core/bookmarks.dart';
import 'package:jj_mkvmaker/core/download_detect.dart';
import 'package:jj_mkvmaker/core/web_address.dart';
import 'package:jj_mkvmaker/platform/windows/desktop_storage_service.dart';
import 'package:jj_mkvmaker/platform/windows/process_media_tool.dart';
import 'package:jj_mkvmaker/services/downloader.dart';
import 'package:jj_mkvmaker/services/platform_services.dart';
import 'package:jj_mkvmaker/ui/browser_page.dart';
import 'package:jj_mkvmaker/ui/downloads_page.dart';
import 'package:path/path.dart' as p;

class _Backend implements DownloadBackend {
  @override
  final DownloadKind kind;
  final started = <String>[];
  void Function()? changed;
  _Backend(this.kind);
  @override
  Future<(String, List<PlaylistEntry>)?> expandPlaylist(String url) async => null;
  @override
  Future<void> start(DownloadTask t, void Function() changed) async {
    this.changed = changed;
    started.add(t.source);
    t.state = DownloadState.downloading;
  }

  @override
  Future<void> pause(DownloadTask t) async {}
  @override
  Future<void> cancel(DownloadTask t) async {}
  @override
  Future<void> shutdown() async {}
}

class _Nav implements WebNav {
  int paused = 0;
  @override
  Future<void> pauseMedia() async => paused++;
  final scripts = <String>[];
  @override
  Future<void> runScript(String js) async => scripts.add(js);
  final loads = <String>[];
  @override
  Future<void> load(String url) async => loads.add(url);
  int backs = 0;
  @override
  Future<void> back() async => backs++;
  @override
  Future<void> forward() async {}
  @override
  Future<void> reload() async {}
  @override
  Future<void> stop() async {}
  var exported = 0;
  @override
  Future<void> exportCookies() async => exported++;
  @override
  Future<void> clearData() async {}
  @override
  Future<Object?> evaluate(String js) async {
    scripts.add(js);
    return null;
  }

  final javaScript = <bool>[];
  @override
  Future<void> setJavaScript(bool on) async => javaScript.add(on);
}

void main() {
  group('즐겨찾기 트리', () {
    test('추가 · 찾기 · 이동 · 삭제', () {
      final t = BookmarkTree.defaults();
      final f = t.add(BookmarkTree.barId, BookmarkNode.folder('f', '음악'));
      t.add('f', BookmarkNode.link('a', 'A', 'https://a.com/'));
      expect(t.findByUrl('https://a.com'), isNotNull); // 끝의 / 무시
      expect(t.parentOf('a')!.id, 'f');

      // 같은 폴더 안: 맨 앞 → 맨 뒤
      final first = t.bar.children!.first.id;
      expect(t.move(first, BookmarkTree.barId, t.bar.children!.length), isTrue);
      expect(t.bar.children!.last.id, first);

      // 폴더를 자기 안으로는 못 옮김
      final sub = t.add('f', BookmarkNode.folder('s', '하위'));
      expect(t.move('f', sub.id, 0), isFalse);
      expect(t.move('a', BookmarkTree.otherId, 0), isTrue);
      expect(t.other.children!.single.id, 'a');

      final r = t.remove(f.id)!;
      expect(r.$2, BookmarkTree.barId);
      expect(t.find('s'), isNull);
      expect(t.remove(BookmarkTree.barId), isNull); // 기본 폴더는 못 지움
    });

    test('JSON 저장 · 불러오기', () {
      final t = BookmarkTree.defaults()..add(BookmarkTree.otherId, BookmarkNode.folder('x', 'X', [BookmarkNode.link('y', 'Y', 'https://y')]));
      final back = BookmarkTree.fromJson(t.toJson());
      expect(back.find('y')!.url, 'https://y');
      expect(back.bar.children!.map((n) => n.title), t.bar.children!.map((n) => n.title));
    });

    test('Chrome 즐겨찾기 가져오기', () {
      final t = BookmarkTree.defaults();
      final n = t.importChromium({
        'roots': {
          'bookmark_bar': {
            'type': 'folder', 'name': '북마크바',
            'children': [
              {'type': 'url', 'name': '네이버', 'url': 'https://naver.com'},
              {'type': 'url', 'name': '설정', 'url': 'chrome://settings'}, // 제외
              {'type': 'folder', 'name': '영상', 'children': [
                {'type': 'url', 'name': 'YT', 'url': 'https://youtube.com'},
              ]},
            ],
          },
          'other': {'type': 'folder', 'name': '기타', 'children': []},
        },
      }, 'Chrome 에서 가져옴');
      expect(n, 2);
      final imported = t.other.children!.single;
      expect(imported.title, 'Chrome 에서 가져옴');
      expect(t.findByUrl('https://youtube.com')!.title, 'YT');
    });
  });

  group('주소 · 동영상 판별 · 쿠키', () {
    test('주소창 입력', () {
      expect(normalizeAddress('youtube.com'), 'https://youtube.com');
      expect(normalizeAddress('http://a.b/c'), 'http://a.b/c');
      expect(normalizeAddress('localhost:8080/x'), 'https://localhost:8080/x');
      expect(normalizeAddress('자막 만드는 법'), startsWith('https://www.google.com/search?q='));
    });
    test('동영상 페이지', () {
      expect(looksLikeVideoPage('https://www.youtube.com/watch?v=abc'), isTrue);
      expect(looksLikeVideoPage('https://vimeo.com/12345'), isTrue);
      expect(looksLikeVideoPage('https://tv.naver.com/v/123'), isTrue);
      expect(looksLikeVideoPage('https://www.google.com/'), isFalse);
    });
    test('앱 안 브라우저 쿠키 → yt-dlp', () {
      // 내보낸 cookies.txt 가 없으면 쿠키 없이 (프로필 폴더를 직접 읽지 않는다)
      expect(ytDlpCookieArgs(browser: internalBrowserCookies, internalProfile: r'C:\w\EBWebView\Default'), isEmpty);
      expect(isCookieReadError(r'ERROR: could not find edge cookies database in "C:\x"'), isTrue);
      expect(isCookieReadError('ERROR: Failed to decrypt with DPAPI. See cookies issue'), isTrue);
      expect(isCookieReadError('ERROR: Video unavailable'), isFalse);
      expect(ytDlpCookieArgs(browser: internalBrowserCookies), isEmpty); // 아직 로그인 전
      expect(AppSettings().ytCookiesBrowser, internalBrowserCookies); // 새 설치 기본값
    });
    test('cookies.txt 형식 (HttpOnly · 중복 제거 · 쿠키 파일 우선)', () {
      final txt = toNetscapeCookies(const [
        CookieRecord(name: 'SID', value: 'a\tb', domain: '.youtube.com', expires: 1800000000, secure: true, httpOnly: true),
        CookieRecord(name: 'SID', value: 'dup', domain: '.youtube.com'),
        CookieRecord(name: 'X', value: '1', domain: 'www.google.com'),
      ]);
      final lines = txt.split('\n').where((l) => l.isNotEmpty && !l.startsWith('# ')).toList();
      expect(lines, [
        '#HttpOnly_.youtube.com\tTRUE\t/\tTRUE\t1800000000\tSID\tab',
        'www.google.com\tFALSE\t/\tFALSE\t0\tX\t1',
      ]);
      expect(txt, startsWith('# Netscape HTTP Cookie File'));
      expect(
          ytDlpCookieArgs(browser: internalBrowserCookies, internalProfile: r'C:\p', internalCookieFile: r'C:\c.txt'),
          ['--cookies', r'C:\c.txt']);
    });

    test('브라우저 페이지 받기 (YouTube 외 사이트도)', () {
      final v = _Backend(DownloadKind.video);
      final d = DownloadManager(backends: [v], settings: () => AppSettings()..downloadRoot = r'D:\dl');
      expect(d.addPage('https://vimeo.com/12345')!.kind, DownloadKind.video);
      expect(d.addPage('https://vimeo.com/12345'), isNull); // 이미 받는 중
      expect(d.addPage('about:blank'), isNull);
      expect(d.addPage('https://youtu.be/abc')!.source, 'https://youtu.be/abc');
      d.dispose();
    });

    test('다 받은 영상 → 편집 목록 알림 (한 번만, 조각 파일 제외)', () async {
      final v = _Backend(DownloadKind.video);
      final d = DownloadManager(backends: [v], settings: () => AppSettings()..downloadRoot = r'D:\dl');
      final got = <String>[];
      d.onFinished.listen((t) => got.add(t.id));
      final t = d.addPage('https://vimeo.com/1')!;
      t.files.addAll([r'D:\dl\a.f137.mp4', r'D:\dl\a.mp4.part', r'D:\dl\a.mp4', r'D:\dl\a.en.vtt']);
      expect(DownloadManager.videoFilesOf(t, exists: (_) => true), [r'D:\dl\a.mp4']);
      t.state = DownloadState.done;
      v.changed!(); // 백엔드가 "다 받음" 알림
      v.changed!(); // 두 번 알려도 한 번만
      await Future<void>.delayed(Duration.zero);
      expect(got, [t.id]);
      d.dispose();
    });
  });

  testWidgets('다운로드 알림: 브라우저 화면이 닫혀도 "목록 보기" 가 되고, 준비가 끝나면 사라진다', (tester) async {
    tester.view.physicalSize = const Size(1500, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final dir = Directory.systemTemp.createTempSync('jj_dlbar_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final c = AppController(PlatformServices(mediaTool: ProcessMediaTool('x', 'y'), storage: DesktopStorageService()));
    final bm = BookmarksController(p.join(dir.path, 'bookmarks.json'));
    final d = DownloadManager(
        backends: [_Backend(DownloadKind.video)], settings: () => c.settings, readClipboard: () async => null);
    final navKey = GlobalKey<NavigatorState>();
    late BrowserHost host;
    Future<void> settle() async {
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    await tester.pumpWidget(MaterialApp(navigatorKey: navKey, home: const Scaffold(body: Text('MKV 화면'))));
    navKey.currentState!.push(MaterialPageRoute<void>(
      builder: (_) => BrowserPage(
        c: c,
        bookmarks: bm,
        downloads: d,
        initialUrl: 'https://www.youtube.com/watch?v=abc',
        viewBuilder: (h, url) {
          host = h;
          h.attach(_Nav());
          return const ColoredBox(color: Colors.white);
        },
      ),
    ));
    await settle();
    host.onUrl('https://www.youtube.com/watch?v=abc');
    await tester.pump();
    await tester.tap(find.text('다운로드'));
    await settle();
    expect(find.text('목록 보기'), findsOneWidget);
    final t = d.tasks.single;

    // MKV 화면으로 (브라우저 화면이 닫힘) → 알림의 "목록 보기" 를 눌러도 다운로드 목록이 열린다
    navKey.currentState!.popUntil((r) => r.isFirst);
    await settle();
    expect(find.byType(BrowserPage), findsNothing);
    await tester.tap(find.text('목록 보기'));
    await settle();
    expect(find.byType(DownloadsPage), findsOneWidget);
    expect(find.text('목록 보기'), findsNothing); // 누르면 알림은 닫힘
    // 다시 열어도 (위쪽 버튼 등) 목록 화면이 겹쳐 쌓이지 않는다
    await DownloadsPage.open(navKey.currentState!, d);
    await settle();
    expect(find.byType(DownloadsPage, skipOffstage: false), findsOneWidget);
    expect(t.state, DownloadState.downloading);

    // 다른 동영상: 받기 준비가 끝나면 (진행률이 나오면) 알림이 저절로 사라진다
    navKey.currentState!.popUntil((r) => r.isFirst);
    navKey.currentState!.push(MaterialPageRoute<void>(
      builder: (_) => BrowserPage(
        c: c,
        bookmarks: bm,
        downloads: d,
        initialUrl: 'https://www.youtube.com/watch?v=def',
        viewBuilder: (h, url) {
          host = h;
          h.attach(_Nav());
          return const ColoredBox(color: Colors.white);
        },
      ),
    ));
    await settle();
    host.onUrl('https://www.youtube.com/watch?v=def');
    await tester.pump();
    await tester.tap(find.text('다운로드'));
    await settle();
    expect(find.text('목록 보기'), findsOneWidget);
    await tester.pump(const Duration(seconds: 30));
    expect(find.text('목록 보기'), findsOneWidget, reason: '준비 중에는 그대로');
    expect(find.byIcon(Icons.close), findsOneWidget); // [✕] 로 바로 닫을 수도 있다
    d.tasks.first.progress = 0.1;
    d.refresh();
    await settle();
    expect(find.text('목록 보기'), findsNothing);

    // [✕] 누르면 바로 닫힘
    host.onUrl('https://www.youtube.com/watch?v=ghi');
    await tester.pump();
    await tester.tap(find.text('다운로드'));
    await settle();
    expect(find.text('목록 보기'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.close));
    await settle();
    expect(find.text('목록 보기'), findsNothing);
    d.dispose();
  });

  testWidgets('Android 뒤로 키: 앞 웹 페이지가 있으면 웹 뒤로, 없으면 화면 닫기 · 위쪽 ← 는 늘 닫기', (tester) async {
    tester.view.physicalSize = const Size(1500, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final dir = Directory.systemTemp.createTempSync('jj_back_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final c = AppController(PlatformServices(mediaTool: ProcessMediaTool('x', 'y'), storage: DesktopStorageService()));
    final bm = BookmarksController(p.join(dir.path, 'bookmarks.json'));
    final navKey = GlobalKey<NavigatorState>();
    late BrowserHost host;
    final nav = _Nav();
    Future<void> open() async {
      navKey.currentState!.push(MaterialPageRoute<void>(
        builder: (_) => BrowserPage(
          c: c,
          bookmarks: bm,
          initialUrl: 'https://example.com/',
          viewBuilder: (h, url) {
            host = h;
            h.attach(nav);
            return const ColoredBox(color: Colors.white);
          },
        ),
      ));
      await tester.pumpAndSettle();
    }

    await tester.pumpWidget(MaterialApp(navigatorKey: navKey, home: const Scaffold(body: Text('MKV 화면'))));
    await open();
    host.onHistory(true, false);
    await tester.pump();
    await tester.binding.handlePopRoute(); // 기기의 뒤로 키
    await tester.pumpAndSettle();
    expect(nav.backs, 1);
    expect(find.byType(BrowserPage), findsOneWidget);
    host.onHistory(false, true);
    await tester.pump();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(nav.backs, 1);
    expect(find.byType(BrowserPage), findsNothing);

    // 위쪽 ← (화면 이동) 은 웹 기록이 있어도 브라우저 화면을 닫는다
    await open();
    host.onHistory(true, false);
    await tester.pump();
    await tester.tap(find.byTooltip('뒤로'));
    await tester.pumpAndSettle();
    expect(nav.backs, 1);
    expect(find.byType(BrowserPage), findsNothing);
    debugDefaultTargetPlatformOverride = null; // 끝나기 전에 되돌려야 한다 (테스트 검사)
  });

  testWidgets('브라우저: ☆ 추가 · 표시줄 · 다운로드 버튼 · 관리 패널 (삭제 · 실행 취소)', (tester) async {
    tester.view.physicalSize = const Size(1500, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final dir = Directory.systemTemp.createTempSync('jj_bm_');

    final c = AppController(PlatformServices(mediaTool: ProcessMediaTool('x', 'y'), storage: DesktopStorageService()));
    final bm = BookmarksController(p.join(dir.path, 'bookmarks.json'));
    final video = _Backend(DownloadKind.video);
    final d = DownloadManager(backends: [video], settings: () => c.settings, readClipboard: () async => null);
    final nav = _Nav();
    late BrowserHost host;

    await tester.pumpWidget(MaterialApp(
      home: BrowserPage(
        c: c,
        bookmarks: bm,
        downloads: d,
        initialUrl: 'https://www.google.com/',
        viewBuilder: (h, url) {
          host = h;
          h.attach(nav);
          return const ColoredBox(color: Colors.white);
        },
      ),
    ));
    // 기본 즐겨찾기 표시줄
    expect(find.text('YouTube'), findsOneWidget);
    // 터치 화면: 즐겨찾기를 길게 누르면 오른쪽 클릭과 같은 메뉴
    await tester.longPress(find.text('YouTube'));
    await tester.pumpAndSettle();
    expect(find.text('수정 · 이동'), findsOneWidget);
    await tester.tapAt(const Offset(5, 880));
    await tester.pumpAndSettle();
    FilledButton dl() => tester.widget<FilledButton>(find.ancestor(of: find.text('다운로드'), matching: find.byWidgetPredicate((w) => w is FilledButton)));
    // 27: 동영상 페이지가 아니어도 받아 볼 수 있다 (덜 눈에 띄는 버튼 · 안내)
    expect(dl().onPressed, isNotNull);
    expect(find.byTooltip('다운로드 (이 페이지에서 동영상을 찾지 못했지만 받아 볼 수 있습니다)'), findsOneWidget);

    // 주소창 입력 → 이동
    await tester.enterText(find.byType(TextField).first, 'youtube.com/watch?v=abc');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    expect(nav.loads.last, 'https://youtube.com/watch?v=abc');
    host.onUrl('https://www.youtube.com/watch?v=abc');
    host.onTitle('재미있는 영상');
    await tester.pump();
    expect(dl().onPressed, isNotNull);
    await tester.tap(find.text('다운로드'));
    await tester.pump();
    expect(video.started, ['https://www.youtube.com/watch?v=abc']);

    // ☆ → Chrome 처럼 "즐겨찾기 추가됨" 창: 이름 · 폴더 고르기, 그 자리에서 새 폴더
    await tester.tap(find.byTooltip('즐겨찾기 추가 (Ctrl+D)'));
    await tester.pumpAndSettle();
    expect(find.text('즐겨찾기 추가됨'), findsOneWidget);
    expect(bm.tree.parentOf(bm.tree.findByUrl('https://www.youtube.com/watch?v=abc')!.id)!.id, BookmarkTree.barId);
    await tester.tap(find.text('새 폴더'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, '음악');
    await tester.tap(find.text('확인'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('완료'));
    await tester.pumpAndSettle();
    final saved = bm.tree.findByUrl('https://www.youtube.com/watch?v=abc')!;
    final folder = bm.tree.parentOf(saved.id)!;
    expect(folder.title, '음악');
    expect(bm.tree.parentOf(folder.id)!.id, BookmarkTree.barId);
    // 표시줄에는 폴더가 보인다
    expect(find.widgetWithText(TextButton, '음악'), findsOneWidget);

    // 관리 패널 → 삭제 → 실행 취소
    await tester.tap(find.byTooltip('즐겨찾기 관리 (Ctrl+Shift+B)'));
    await tester.pumpAndSettle();
    expect(find.text('즐겨찾기'), findsWidgets);
    await tester.tap(find.byTooltip('더 보기').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('삭제').last);
    await tester.pumpAndSettle();
    expect(bm.tree.findByUrl('https://www.youtube.com/watch?v=abc'), isNull);
    await tester.tap(find.text('실행 취소'));
    await tester.pumpAndSettle();
    expect(bm.tree.findByUrl('https://www.youtube.com/watch?v=abc'), isNotNull);
    // 실행 취소 알림은 누르지 않으면 몇 초 뒤 저절로 사라진다 (Flutter 3.47+ 는 action 이 있으면 기본이 안 사라짐)
    await tester.tap(find.byTooltip('더 보기').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('삭제').last);
    await tester.pumpAndSettle();
    expect(find.text('실행 취소'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    expect(find.text('실행 취소'), findsNothing);
    bm.undoRemove();
    await tester.pumpAndSettle();
    expect(bm.tree.findByUrl('https://www.youtube.com/watch?v=abc'), isNotNull);

    // 패널에서 누르면 그 주소로 이동
    await tester.tap(find.text('OpenSubtitles').last);
    expect(nav.loads.last, 'https://www.opensubtitles.com/');

    // 화면 분할: 작업 현황 (다운로드 진행 · 편집 목록)
    await tester.tap(find.byTooltip('작업 현황 보기 · 화면 분할 (Ctrl+Shift+J)'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('작업 현황'), findsOneWidget);
    expect(find.text('쉬는 중'), findsOneWidget);
    expect(find.text('다운로드 1개'), findsOneWidget);
    await tester.tap(find.byTooltip('작업 현황 닫기'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('작업 현황'), findsNothing);
    d.dispose();
  });

  test('즐겨찾기 파일 저장 · 다시 불러오기 · 순서 바꾸기', () async {
    final dir = Directory.systemTemp.createTempSync('jj_bm2_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = p.join(dir.path, 'bookmarks.json');
    final a = BookmarksController(file);
    await a.load();
    a.addFolder('영상');
    a.addLink('B', 'https://b.com');
    final ids = a.tree.bar.children!.map((n) => n.title).toList();
    a.reorder(BookmarkTree.barId, ids.length - 1, 0); // 맨 뒤 → 맨 앞
    await Future<void>.delayed(const Duration(milliseconds: 300));

    final b = BookmarksController(file);
    await b.load();
    expect(b.tree.bar.children!.first.title, 'B');
    expect(b.tree.bar.children!.any((n) => n.isFolder && n.title == '영상'), isTrue);
  });
}
