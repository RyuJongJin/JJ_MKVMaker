import 'dart:io';

import 'package:flutter/gestures.dart' show kSecondaryButton;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jj_mkvmaker/app/bookmarks_controller.dart';
import 'package:jj_mkvmaker/core/bookmarks.dart';
import 'package:jj_mkvmaker/ui/bookmark_ui.dart';
import 'package:path/path.dart' as p;

BookmarksController _bm() {
  // 저장은 기다리지 않고 뒤에서 하므로, 시험이 끝나도 폴더를 바로 지우지 않는다 (임시 폴더)
  final dir = Directory.systemTemp.createTempSync('jj_bmf_');
  return BookmarksController(p.join(dir.path, 'bookmarks.json'));
}

void main() {
  test('폴더 안에 폴더 · 즐겨찾기, 경로 · 검색 · 개수, 폴더로 옮기기 규칙', () {
    final bm = _bm();
    final music = bm.addFolder('음악');
    final kpop = bm.addFolder('K-POP', parentId: music.id);
    final song = bm.addLink('좋은 노래', 'https://youtube.com/watch?v=1', parentId: kpop.id);
    bm.addLink('라디오', 'https://radio.example', parentId: music.id);

    expect(bm.tree.pathTo(song.id).map((n) => n.title), ['즐겨찾기 표시줄', '음악', 'K-POP', '좋은 노래']);
    expect(bm.tree.countLinks(music), 2);
    expect(bm.tree.search('노래').single.id, song.id);
    expect(bm.tree.search('RADIO.example').single.title, '라디오'); // 주소 · 대소문자 무시
    expect(bm.tree.search('k-pop').single.id, kpop.id); // 폴더도

    // 끌어다 놓기 규칙: 자기 자신 · 자기 안쪽 · 기본 폴더 자체는 안 됨
    expect(bm.canMoveInto(music.id, kpop.id), isFalse);
    expect(bm.canMoveInto(music.id, music.id), isFalse);
    expect(bm.canMoveInto(BookmarkTree.barId, BookmarkTree.otherId), isFalse);
    expect(bm.canMoveInto(song.id, BookmarkTree.otherId), isTrue);
    expect(bm.moveInto(kpop.id, BookmarkTree.otherId), isTrue);
    expect(bm.tree.parentOf(kpop.id)!.id, BookmarkTree.otherId);
    expect(bm.tree.parentOf(song.id)!.id, kpop.id); // 폴더째 옮겨짐
  });

  test('즐겨찾기 HTML 내보내기 → 가져오기 (폴더 구조 그대로)', () {
    final bm = _bm();
    final f = bm.addFolder('영상 & 음악');
    bm.addLink('A "따옴표" <b>', 'https://a.com/?x=1&y=2', parentId: bm.addFolder('하위', parentId: f.id).id);
    final html = bm.tree.toNetscapeHtml();
    expect(html, startsWith('<!DOCTYPE NETSCAPE-Bookmark-file-1>'));
    expect(html, contains('PERSONAL_TOOLBAR_FOLDER="true"'));
    expect(html, contains('HREF="https://a.com/?x=1&amp;y=2"'));

    final other = BookmarkTree.defaults();
    final n = other.importNetscapeHtml(html, '가져옴');
    expect(n, bm.tree.countLinks(bm.tree.bar) + bm.tree.countLinks(bm.tree.other));
    final root = other.other.children!.last;
    expect(root.title, '가져옴');
    final link = other.findByUrl('https://a.com/?x=1&y=2')!;
    expect(link.title, 'A "따옴표" <b>');
    expect(other.pathTo(link.id).map((x) => x.title),
        ['기타 즐겨찾기', '가져옴', '즐겨찾기 표시줄', '영상 & 음악', '하위', 'A "따옴표" <b>']);
  });

  testWidgets('즐겨찾기 수정 창: 다른 폴더로 옮기기 · 새 폴더 만들어 넣기', (tester) async {
    final bm = _bm();
    final link = bm.addLink('뉴스', 'https://news.example');
    late BuildContext ctx;
    await tester.pumpWidget(MaterialApp(home: Builder(builder: (c) {
      ctx = c;
      return const SizedBox();
    })));
    unawaitedShow() => showBookmarkEditor(ctx, bm, link);

    unawaitedShow();
    await tester.pumpAndSettle();
    expect(find.text('즐겨찾기 수정'), findsOneWidget);
    // 폴더 목록에서 "기타 즐겨찾기" 고르기
    await tester.tap(find.text('즐겨찾기 표시줄').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('기타 즐겨찾기').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('저장'));
    await tester.pumpAndSettle();
    expect(bm.tree.parentOf(link.id)!.id, BookmarkTree.otherId);

    // 새 폴더를 만들면 그 폴더가 골라지고, 저장하면 그 안으로
    unawaitedShow();
    await tester.pumpAndSettle();
    await tester.tap(find.text('새 폴더'));
    await tester.pumpAndSettle();
    expect(find.text('"기타 즐겨찾기" 안에 만듭니다'), findsOneWidget);
    await tester.enterText(find.byType(TextField).last, '읽을거리');
    await tester.tap(find.text('확인'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('저장'));
    await tester.pumpAndSettle();
    final parent = bm.tree.parentOf(link.id)!;
    expect(parent.title, '읽을거리');
    expect(bm.tree.parentOf(parent.id)!.id, BookmarkTree.otherId);
  });

  testWidgets('즐겨찾기 관리자: 폴더 나무 · 새 폴더 · 끌어서 폴더로 · 검색 · 오른쪽 클릭', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final bm = _bm();
    final opened = <String>[];
    await tester.pumpWidget(MaterialApp(
        home: BookmarkManagerPage(bm: bm, onOpen: opened.add, currentUrl: 'https://now.example', currentTitle: '지금 페이지')));
    expect(find.text('즐겨찾기 관리자'), findsOneWidget);
    expect(find.text('YouTube'), findsOneWidget); // 표시줄 내용

    // 새 폴더 (지금 보는 폴더 = 표시줄 안)
    await tester.tap(find.widgetWithText(OutlinedButton, '새 폴더'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, '보관함');
    await tester.tap(find.text('확인'));
    await tester.pumpAndSettle();
    final box = bm.tree.bar.children!.firstWhere((n) => n.title == '보관함');
    expect(find.text('보관함'), findsWidgets); // 왼쪽 나무 + 오른쪽 목록

    // "YouTube" 아이콘을 끌어 목록의 "보관함" 폴더 줄에 놓기
    final yt = bm.tree.bar.children!.firstWhere((n) => n.title == 'YouTube');
    final from = tester.getCenter(find.descendant(
        of: find.ancestor(of: find.text('YouTube'), matching: find.byType(ListTile)), matching: find.byIcon(Icons.public)));
    final to = tester.getCenter(find.ancestor(of: find.text('보관함').last, matching: find.byType(ListTile)));
    final g = await tester.startGesture(from);
    await tester.pump(const Duration(milliseconds: 100));
    await g.moveTo(to);
    await tester.pump(const Duration(milliseconds: 100));
    await g.up();
    await tester.pumpAndSettle();
    expect(bm.tree.parentOf(yt.id)!.id, box.id);

    // 왼쪽 나무에서 폴더를 누르면 오른쪽에 그 내용
    await tester.tap(find.text('보관함').first);
    await tester.pumpAndSettle();
    expect(find.text('YouTube'), findsOneWidget);

    // 오른쪽 클릭 → "이 폴더에 현재 페이지 추가" 는 빈 곳 메뉴, 여기서는 항목 메뉴의 "현재 페이지 추가"
    await tester.tapAt(tester.getCenter(find.text('YouTube')), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text('현재 페이지 추가'));
    await tester.pumpAndSettle();
    expect(bm.tree.findByUrl('https://now.example'), isNotNull);
    expect(bm.tree.parentOf(bm.tree.findByUrl('https://now.example')!.id)!.id, box.id);

    // 검색 → 결과에 들어 있는 폴더 경로, 누르면 열기
    await tester.enterText(find.byType(TextField).first, 'subtitles');
    await tester.pumpAndSettle();
    expect(find.text('"subtitles" 검색 결과 1개'), findsOneWidget);
    await tester.tap(find.text('OpenSubtitles'));
    await tester.pumpAndSettle();
    expect(opened, ['https://www.opensubtitles.com/']);
  });
}
