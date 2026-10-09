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
