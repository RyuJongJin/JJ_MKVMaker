import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jj_mkvmaker/app/app_controller.dart';
import 'package:jj_mkvmaker/platform/windows/desktop_storage_service.dart';
import 'package:jj_mkvmaker/platform/windows/process_media_tool.dart';
import 'package:jj_mkvmaker/services/platform_services.dart';
import 'package:jj_mkvmaker/ui/explorer_page.dart';
import 'package:path/path.dart' as p;

/// 48 · 154 · 155: 같은 이름이 있으면 덮어쓰기 · 건너뛰기 · 이름 바꾸기를 고르고, 확인 창에 항목 이름이 보인다
void main() {
  late Directory tmp;
  late String left, right;
  late AppController c;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('jj_conflict_');
    left = p.join(tmp.path, 'left');
    right = p.join(tmp.path, 'right');
    File(p.join(left, 'doc.txt'))
      ..createSync(recursive: true)
      ..writeAsStringSync('new');
    File(p.join(right, 'doc.txt'))
      ..createSync(recursive: true)
      ..writeAsStringSync('old');
    c = AppController(PlatformServices(mediaTool: ProcessMediaTool('x', 'y'), storage: DesktopStorageService()));
    c.settings.explorerPaths = [left, right];
    final root = p.rootPrefix(tmp.path);
    ExplorerPage.debugVolumes = () => [(root, root.replaceAll(RegExp(r'[\\/]+$'), ''))];
  });
  tearDown(() {
    ExplorerPage.debugVolumes = null;
    tmp.deleteSync(recursive: true);
  });

  Future<void> settle(WidgetTester tester, bool Function() done, {int rounds = 100}) async {
    for (var i = 0; i < rounds && !done(); i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump();
    }
    await tester.pump(const Duration(milliseconds: 300));
  }

  /// 왼쪽 doc.txt 를 고르고 [복사] → 확인 창 (같은 이름 알림이 뜰 때까지)
  Future<void> startCopy(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.runAsync(() => tester.pumpWidget(MaterialApp(home: ExplorerPage(c: c))));
    await settle(tester, () => find.text('doc.txt').evaluate().length >= 2);
    await tester.runAsync(() => tester.tap(find.text('doc.txt').first));
    await settle(tester, () => false, rounds: 10);
    await tester.runAsync(() => tester.tap(find.text('복사').first));
    await tester.pump();
    // 확인 창은 바로 뜨고, 같은 이름은 창 안에서 찾아 알린다
    expect(find.widgetWithText(FilledButton, '복사'), findsOneWidget);
    await settle(tester, () => find.textContaining('같은 이름이 이미 있습니다').evaluate().isNotEmpty);
    expect(find.textContaining('같은 이름이 이미 있습니다: doc.txt'), findsOneWidget);
    // 154 · 155: 확인 창에 항목 이름
    expect(find.textContaining('\ndoc.txt'), findsOneWidget);
  }

  Future<void> confirm(WidgetTester tester) async {
    await tester.runAsync(() => tester.tap(find.widgetWithText(FilledButton, '복사')));
    await settle(tester, () => find.byType(LinearProgressIndicator).evaluate().isEmpty && find.byType(SnackBar).evaluate().isNotEmpty);
  }

  testWidgets('48: 기본은 이름 바꾸기 (원래 파일 그대로, 새 파일은 "doc (2).txt")', (tester) async {
    await startCopy(tester);
    await confirm(tester);
    expect(File(p.join(right, 'doc.txt')).readAsStringSync(), 'old');
    expect(File(p.join(right, 'doc (2).txt')).readAsStringSync(), 'new');
  });

  testWidgets('48: 덮어쓰기를 고르면 원래 파일을 새것으로', (tester) async {
    await startCopy(tester);
    await tester.tap(find.text('덮어쓰기 (원래 파일은 없어집니다)'));
    await tester.pump();
    await confirm(tester);
    expect(File(p.join(right, 'doc.txt')).readAsStringSync(), 'new');
    expect(File(p.join(right, 'doc (2).txt')).existsSync(), isFalse);
  });

  testWidgets('48 보충: 환경 설정이 "늘 덮어쓰기" 면 묻지 않고 (확인 창에 알림만) 덮어쓴다', (tester) async {
    c.settings.copyConflict = 'overwrite';
    await startCopy(tester);
    expect(find.text('덮어쓰기 (원래 파일은 없어집니다)'), findsNothing, reason: '고르는 칸 없음');
    expect(find.textContaining('환경 설정대로 덮어씁니다'), findsOneWidget);
    await confirm(tester);
    expect(File(p.join(right, 'doc.txt')).readAsStringSync(), 'new');
  });

  testWidgets('48 보충: 처음 열면 아무것도 고르지 않은 상태 - 바로 [복사] 를 누르면 "복사할 항목을 고르세요" (폴더 통째로 복사하지 않음)', (tester) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.runAsync(() => tester.pumpWidget(MaterialApp(home: ExplorerPage(c: c))));
    await settle(tester, () => find.text('doc.txt').evaluate().length >= 2);
    await tester.runAsync(() => tester.tap(find.text('복사').first));
    await tester.pump();
    expect(find.widgetWithText(FilledButton, '복사'), findsNothing, reason: '확인 창이 뜨지 않음');
    expect(find.textContaining('복사할 항목을 고르세요'), findsOneWidget);
    expect(Directory(p.join(right, 'left')).existsSync(), isFalse);
    // 상위 폴더로 가도 (사용자 이동) 그 폴더를 대상으로 잡지 않는다
    await tester.runAsync(() => tester.tap(find.text('상위 폴더').first));
    await settle(tester, () => false, rounds: 15);
    ScaffoldMessenger.of(tester.element(find.byType(ExplorerPage))).clearSnackBars();
    await tester.pump();
    await tester.runAsync(() => tester.tap(find.text('복사').first));
    await tester.pump();
    expect(find.widgetWithText(FilledButton, '복사'), findsNothing);
    expect(find.textContaining('복사할 항목을 고르세요'), findsOneWidget);
  });

  testWidgets('52: 복사 중에 화면을 떠났다 돌아와도 진행 막대가 다시 보이고, 끝나면 받는 폴더를 새로 읽는다 (.jjpart 가 남아 보이지 않음)', (tester) async {
    File(p.join(left, 'big.bin')).writeAsBytesSync(List.filled(150 * 1024, 3));
    c.settings.copyBandwidthKBps = 60; // 약 2.5초 걸리게
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.runAsync(() => tester.pumpWidget(MaterialApp(home: ExplorerPage(c: c))));
    await settle(tester, () => find.text('big.bin').evaluate().isNotEmpty);
    await tester.runAsync(() => tester.tap(find.text('big.bin')));
    await settle(tester, () => false, rounds: 10);
    await tester.runAsync(() => tester.tap(find.text('복사').first));
    await tester.pump();
    await tester.runAsync(() => tester.tap(find.widgetWithText(FilledButton, '복사')));
    await settle(tester, () => find.byType(LinearProgressIndicator).evaluate().isNotEmpty);
    // 다른 화면으로 (탐색기 화면이 없어짐) → 돌아옴
    await tester.runAsync(() => tester.pumpWidget(const MaterialApp(home: Scaffold(body: Text('다른 화면')))));
    await tester.pump();
    await tester.runAsync(() => tester.pumpWidget(MaterialApp(home: ExplorerPage(c: c))));
    await settle(tester, () => find.byType(LinearProgressIndicator).evaluate().isNotEmpty, rounds: 30);
    expect(find.byType(LinearProgressIndicator), findsWidgets, reason: '돌아와도 진행 막대');
    // 끝나면 오른쪽 창에 big.bin 이 보이고 .jjpart 는 없다
    await settle(tester, () => File(p.join(right, 'big.bin')).existsSync() && find.text('big.bin').evaluate().length >= 2,
        rounds: 300);
    expect(find.text('big.bin'), findsNWidgets(2));
    expect(find.textContaining('.jjpart'), findsNothing);
  });

  testWidgets('148: 휴지통으로 보낸 뒤 알림의 [되돌리기] 를 누르면 원래 자리로', (tester) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.runAsync(() => tester.pumpWidget(MaterialApp(home: ExplorerPage(c: c))));
    await settle(tester, () => find.text('doc.txt').evaluate().length >= 2);
    await tester.runAsync(() => tester.tap(find.text('doc.txt').first));
    await settle(tester, () => false, rounds: 10);
    await tester.runAsync(() => tester.tap(find.text('삭제').first));
    await tester.pumpAndSettle();
    await tester.runAsync(() => tester.tap(find.widgetWithText(FilledButton, '휴지통으로')));
    await settle(tester, () => find.text('되돌리기').evaluate().isNotEmpty);
    expect(File(p.join(left, 'doc.txt')).existsSync(), isFalse);
    expect(find.textContaining('1개 항목을 휴지통으로 보냈습니다.'), findsOneWidget);
    // 알림의 버튼은 시험의 가짜 시간 안에서 누른다 (알림 닫기 애니메이션이 시험 밖에서 돌지 않게)
    await tester.tap(find.text('되돌리기'));
    await tester.pump();
    await settle(tester, () => find.textContaining('되돌렸습니다').evaluate().isNotEmpty);
    expect(File(p.join(left, 'doc.txt')).readAsStringSync(), 'new');
    expect(find.textContaining('1개 항목을 되돌렸습니다.'), findsOneWidget);
    // 알림 (10초) 이 시험이 끝난 뒤에 닫히지 않게 정리
    ScaffoldMessenger.of(tester.element(find.byType(ExplorerPage))).clearSnackBars();
    await tester.pumpAndSettle();
  }, skip: !Platform.isWindows);

  testWidgets('48: 건너뛰기를 고르면 그대로 두고 건너뛴 것을 알린다', (tester) async {
    await startCopy(tester);
    await tester.tap(find.text('건너뛰기'));
    await tester.pump();
    await confirm(tester);
    expect(File(p.join(right, 'doc.txt')).readAsStringSync(), 'old');
    expect(File(p.join(right, 'doc (2).txt')).existsSync(), isFalse);
    expect(find.textContaining('같은 이름이라 건너뜀: doc.txt'), findsOneWidget);
  });
}
