import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jj_mkvmaker/app/app_controller.dart';
import 'package:jj_mkvmaker/app/settings.dart';
import 'package:jj_mkvmaker/core/file_ops.dart' show uncRoot;
import 'package:jj_mkvmaker/platform/windows/desktop_storage_service.dart';
import 'package:jj_mkvmaker/platform/windows/process_media_tool.dart';
import 'package:jj_mkvmaker/services/platform_services.dart';
import 'package:jj_mkvmaker/ui/explorer_page.dart';
import 'package:path/path.dart' as p;

import 'explorer_test.dart' show act, settle;

/// 23: 앞의 복사가 끝나지 않아도 다음 복사를 함께 시작한다 (막지 않음, 진행 막대가 둘)
void main() {
  testWidgets('복사 중에 다른 파일 복사 → 둘 다 진행 · 둘 다 끝남', (tester) async {
    final tmp = Directory.systemTemp.createTempSync('jj_parallel_');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final left = p.join(tmp.path, 'left'), right = p.join(tmp.path, 'right');
    File(p.join(left, 'big.bin'))
      ..createSync(recursive: true)
      ..writeAsBytesSync(List.filled(3 << 20, 7));
    File(p.join(left, 'doc.txt')).writeAsStringSync('hello');
    Directory(right).createSync();
    final c = AppController(PlatformServices(mediaTool: ProcessMediaTool('x', 'y'), storage: DesktopStorageService()));
    c.settings
      ..explorerPaths = [left, right]
      ..copyBandwidthKBps = 512; // 큰 파일이 6초쯤 걸리게
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.runAsync(() => tester.pumpWidget(MaterialApp(home: ExplorerPage(c: c))));
    await settle(tester, () => find.text('doc.txt').evaluate().isNotEmpty);

    Future<void> copy(String name) async {
      await act(tester, () => tester.tap(find.text(name).first));
      await settle(tester, () => false, rounds: 15);
      await act(tester, () => tester.tap(find.text('복사').first));
      await tester.pump(const Duration(milliseconds: 300));
      await act(tester, () => tester.tap(find.widgetWithText(FilledButton, '복사')));
      await tester.pump(const Duration(milliseconds: 300));
    }

    await copy('big.bin');
    await settle(tester, () => find.textContaining('복사하는 중').evaluate().isNotEmpty, rounds: 30);
    await copy('doc.txt');
    expect(find.text('앞의 복사 · 이동이 끝난 뒤에 하세요.'), findsNothing);
    // 둘이 함께 돈다 (진행 막대 두 줄)
    expect(find.textContaining('복사하는 중'), findsNWidgets(2));
    await settle(tester, () => File(p.join(right, 'doc.txt')).existsSync(), rounds: 100);
    await settle(tester,
        () => File(p.join(right, 'big.bin')).existsSync() && find.byType(LinearProgressIndicator).evaluate().isEmpty,
        rounds: 400);
    expect(File(p.join(right, 'big.bin')).lengthSync(), 3 << 20);
    expect(File(p.join(right, 'doc.txt')).readAsStringSync(), 'hello');
  });

  testWidgets('25: Rsync 화면 폴더도 길게 누르면 메뉴 (고르기 · 열기 · 이름 변경 · 삭제 · 정보)', (tester) async {
    final tmp = Directory.systemTemp.createTempSync('jj_rsync_menu_');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final l = p.join(tmp.path, 'L'), r = p.join(tmp.path, 'R');
    Directory(p.join(l, 'sub')).createSync(recursive: true);
    Directory(p.join(r, 'rsub')).createSync(recursive: true);
    final c = AppController(PlatformServices(mediaTool: ProcessMediaTool('x', 'y'), storage: DesktopStorageService()));
    c.settings
      ..explorerLayout = 'single'
      ..rsyncPaths = [l, r];
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.runAsync(() => tester.pumpWidget(MaterialApp(home: ExplorerPage(c: c, rsync: true))));
    await settle(tester, () => find.text('sub').evaluate().isNotEmpty);
    await tester.longPress(find.text('sub'));
    await tester.pumpAndSettle();
    for (final t in ['rsync 에 고르기', '열기', '다른 창에서 열기', '이름 변경', '삭제', '정보']) {
      expect(find.text(t), findsOneWidget, reason: t);
    }
    expect(find.text('다른 앱으로 열기'), findsNothing); // 파일 메뉴는 없음
    await act(tester, () => tester.tap(find.text('rsync 에 고르기')));
    await settle(tester, () => false, rounds: 5);
    expect(find.byTooltip('고르기 취소'), findsOneWidget);
  });

  test('37: 네트워크 공유 경로의 맨 위', () {
    expect(uncRoot(r'\\NAS\영상\드라마\1화.mkv'), r'\\NAS\영상');
    expect(uncRoot(r'\\NAS\영상'), r'\\NAS\영상');
  });

  testWidgets('37: 경로를 직접 넣어 가기 · 없는 경로는 알림', (tester) async {
    final tmp = Directory.systemTemp.createTempSync('jj_enter_path_');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final l = p.join(tmp.path, 'L'), deep = p.join(l, 'a', 'b');
    File(p.join(deep, 'deep.txt'))
      ..createSync(recursive: true)
      ..writeAsStringSync('d');
    File(p.join(l, 'top.txt')).writeAsStringSync('t');
    final c = AppController(PlatformServices(mediaTool: ProcessMediaTool('x', 'y'), storage: DesktopStorageService()));
    c.settings
      ..explorerLayout = 'single'
      ..explorerPaths = [l, l];
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.runAsync(() => tester.pumpWidget(MaterialApp(home: ExplorerPage(c: c))));
    await settle(tester, () => find.text('top.txt').evaluate().isNotEmpty);
    await tester.tap(find.byTooltip('경로 입력').first);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, p.join(tmp.path, 'none'));
    await act(tester, () => tester.tap(find.widgetWithText(FilledButton, '확인')));
    await settle(tester, () => find.textContaining('폴더가 없거나 열 수 없습니다').evaluate().isNotEmpty, rounds: 20);
    expect(find.textContaining('폴더가 없거나 열 수 없습니다'), findsOneWidget);
    await tester.tap(find.byTooltip('경로 입력').first);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, deep);
    await act(tester, () => tester.tap(find.widgetWithText(FilledButton, '확인')));
    await settle(tester, () => find.text('deep.txt').evaluate().isNotEmpty);
    expect(find.text('deep.txt'), findsOneWidget);
  });

  testWidgets('122: 앱 밖에서 만든 폴더도 경로 입력으로 가면 새로 읽어 펼치고 화면에 보인다', (tester) async {
    final tmp = Directory.systemTemp.createTempSync('jj_enter_fresh_');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final dl = p.join(tmp.path, 'Download');
    // 앞쪽에 파일이 많아 새 폴더가 화면 아래로 밀리는 Download
    for (var i = 0; i < 60; i++) {
      File(p.join(dl, 'a$i.txt'))
        ..createSync(recursive: true)
        ..writeAsStringSync('$i');
    }
    final c = AppController(PlatformServices(mediaTool: ProcessMediaTool('x', 'y'), storage: DesktopStorageService()));
    c.settings
      ..explorerLayout = 'single'
      ..explorerPaths = [dl, dl];
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.runAsync(() => tester.pumpWidget(MaterialApp(home: ExplorerPage(c: c))));
    await settle(tester, () => find.text('a0.txt').evaluate().isNotEmpty);
    // 앱이 Download 를 읽은 뒤에 다른 앱이 만든 폴더 (이름 순으로 맨 뒤)
    final made = p.join(dl, 'zz_jjsup');
    File(p.join(made, 'pg1.png'))
      ..createSync(recursive: true)
      ..writeAsBytesSync([1, 2, 3]);
    await tester.tap(find.byTooltip('경로 입력').first);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, made);
    await act(tester, () => tester.tap(find.widgetWithText(FilledButton, '확인')));
    await settle(tester, () => find.text('pg1.png').evaluate().isNotEmpty, rounds: 300);
    expect(find.text('zz_jjsup'), findsOneWidget);
    expect(find.text('pg1.png').hitTestable(), findsOneWidget, reason: '그 자리로 스크롤되어 보임');
  });

  testWidgets('38: 좁고 낮은 창 (접은 폴드 · 위아래 두 창) 에서 안내가 있어도 목록이 보인다', (tester) async {
    final tmp = Directory.systemTemp.createTempSync('jj_notice_');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final l = p.join(tmp.path, 'L');
    for (var i = 0; i < 4; i++) {
      File(p.join(l, 'part$i.mkv.jjpart'))
        ..createSync(recursive: true)
        ..writeAsStringSync('x')
        ..setLastModifiedSync(DateTime.now().subtract(const Duration(hours: 1)));
    }
    File(p.join(l, 'zz_file.txt')).writeAsStringSync('t');
    final c = AppController(PlatformServices(mediaTool: ProcessMediaTool('x', 'y'), storage: DesktopStorageService()));
    c.settings
      ..explorerLayout = 'dual'
      ..explorerOrientation = 'stacked'
      ..explorerPaths = [l, l];
    tester.view.physicalSize = const Size(420, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.runAsync(() => tester.pumpWidget(MaterialApp(home: ExplorerPage(c: c))));
    await settle(tester, () => find.textContaining('만들다 만 파일').evaluate().isNotEmpty);
    expect(tester.takeException(), isNull); // 넘침 (overflow) 없음
    // 목록 (창마다) 이 밀려 사라지지 않고 높이가 남아 있다
    final lists = find.byWidgetPredicate((w) => w is ListView && w.scrollDirection == Axis.vertical);
    expect(lists, findsWidgets);
    for (final e in lists.evaluate()) {
      expect(tester.getSize(find.byWidget(e.widget)).height, greaterThan(80));
    }
  });

  test('118: 두 창 배치 처음 값은 좌우 · 예전 "화면 모양 따라" 는 한 번 좌우로 (알림) · 고른 위아래는 그대로', () {
    expect(AppSettings().explorerOrientation, 'side');
    expect(AppSettings.fromJson({}).explorerOrientation, 'side');
    final old = AppSettings.fromJson({'explorerOrientation': 'auto'});
    expect(old.explorerOrientation, 'side');
    expect(old.migrated, contains('explorerOrientation'));
    final stacked = AppSettings.fromJson({'explorerOrientation': 'stacked'});
    expect(stacked.explorerOrientation, 'stacked');
    expect(stacked.migrated, isNot(contains('explorerOrientation')));
    // 옮긴 뒤 사용자가 다시 '화면 모양 따라' 를 고르면 그대로
    final again = AppSettings.fromJson((AppSettings()..explorerOrientation = 'auto').toJson());
    expect(again.explorerOrientation, 'auto');
    expect(again.migrated, isEmpty);
  });

  testWidgets('118: 가운데 버튼 [좌우 ⇆ / 위아래 ⇅] - 한 번 눌러 바로 바뀜 · 한 창이면 두 창 (좌우) 으로', (tester) async {
    final tmp = Directory.systemTemp.createTempSync('jj_orient_');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final l = p.join(tmp.path, 'L');
    File(p.join(l, 'a.txt'))
      ..createSync(recursive: true)
      ..writeAsStringSync('a');
    final c = AppController(PlatformServices(mediaTool: ProcessMediaTool('x', 'y'), storage: DesktopStorageService()));
    c.settings
      ..explorerLayout = 'single'
      ..explorerPaths = [l, l];
    // 폰 세로처럼 좁고 긴 화면
    tester.view.physicalSize = const Size(500, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.runAsync(() => tester.pumpWidget(MaterialApp(home: ExplorerPage(c: c))));
    await settle(tester, () => find.text('a.txt').evaluate().isNotEmpty);
    await act(tester, () => tester.tap(find.byTooltip('두 창으로 보기 (좌우)')));
    await settle(tester, () => false, rounds: 5);
    expect((c.settings.explorerLayout, c.settings.explorerOrientation), ('dual', 'side'));
    expect(find.byTooltip('창 배치: 좌우 (누르면 위아래)'), findsOneWidget, reason: '폰 세로에서도 좌우');
    expect(find.text('a.txt'), findsNWidgets(2));
    final left = tester.getCenter(find.text('a.txt').first), right = tester.getCenter(find.text('a.txt').last);
    expect(right.dx, greaterThan(left.dx));
    await act(tester, () => tester.tap(find.byTooltip('창 배치: 좌우 (누르면 위아래)')));
    await settle(tester, () => false, rounds: 5);
    expect(c.settings.explorerOrientation, 'stacked');
    expect(find.byTooltip('창 배치: 위아래 (누르면 좌우)'), findsOneWidget);
    final top = tester.getCenter(find.text('a.txt').first), bottom = tester.getCenter(find.text('a.txt').last);
    expect(bottom.dy, greaterThan(top.dy));
    // 위아래면 버튼 줄이 가로로 밀어 보는 줄 - 보이게 한 뒤 누른다
    await tester.ensureVisible(find.byTooltip('창 배치: 위아래 (누르면 좌우)'));
    await tester.pump();
    await act(tester, () => tester.tap(find.byTooltip('창 배치: 위아래 (누르면 좌우)')));
    await settle(tester, () => false, rounds: 5);
    expect(c.settings.explorerOrientation, 'side');
  });
}
