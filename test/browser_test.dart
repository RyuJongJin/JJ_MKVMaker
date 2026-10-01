import 'dart:io';

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
  final loads = <String>[];
  @override
  Future<void> load(String url) async => loads.add(url);
  @override
  Future<void> back() async {}
  @override
  Future<void> forward() async {}
  @override
  Future<void> reload() async {}
  @override
  Future<void> stop() async {}
  var exported = 0;
  @override
  Future<void> exportCookies() async => exported++;
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
    FilledButton dl() => tester.widget<FilledButton>(find.ancestor(of: find.text('다운로드'), matching: find.byWidgetPredicate((w) => w is FilledButton)));
    expect(dl().onPressed, isNull); // 동영상 페이지 아님

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
