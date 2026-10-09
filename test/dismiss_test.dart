import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jj_mkvmaker/app/app_controller.dart';
import 'package:jj_mkvmaker/app/copy_center.dart';
import 'package:jj_mkvmaker/app/live_sync.dart';
import 'package:jj_mkvmaker/app/settings.dart';
import 'package:jj_mkvmaker/platform/windows/desktop_storage_service.dart';
import 'package:jj_mkvmaker/platform/windows/process_media_tool.dart';
import 'package:jj_mkvmaker/services/platform_services.dart';
import 'package:jj_mkvmaker/ui/confirm.dart';
import 'package:jj_mkvmaker/ui/explorer_page.dart';
import 'package:jj_mkvmaker/ui/monitor_page.dart';
import 'package:jj_mkvmaker/ui/sync_preview_view.dart';
import 'package:path/path.dart' as p;

import 'explorer_test.dart' show act, settle;

/// 110: 확인 창은 뒤로 가기 · 바깥 누르기 · [취소] 로 닫으면 아무것도 하지 않는다 ([실행] · [지우기] 등만 실행)
void main() {
  const ways = ['back', 'barrier', 'cancel'];

  Future<void> dismiss(WidgetTester tester, String how) async {
    switch (how) {
      case 'back':
        await tester.runAsync(() => tester.binding.handlePopRoute());
      case 'barrier':
        await tester.tapAt(const Offset(4, 4));
      default:
        await tester.tap(find.text('취소').last);
    }
    await tester.pumpAndSettle();
  }

  late Directory tmp;
  late AppController c;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('jj_dismiss_');
    c = AppController(PlatformServices(mediaTool: ProcessMediaTool('x', 'y'), storage: DesktopStorageService()));
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  /// [run] 을 누르는 단추 하나만 있는 화면
  Future<void> host(WidgetTester tester, Future<void> Function(BuildContext) run) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: Builder(builder: (ctx) => Center(child: ElevatedButton(onPressed: () => run(ctx), child: const Text('열기'))))),
    ));
    await tester.tap(find.text('열기'));
    await tester.pump(const Duration(milliseconds: 400));
  }

  for (final how in ways) {
    testWidgets('46 · 47 공용 확인 창 ($how) → false', (tester) async {
      bool? r;
      await host(tester, (ctx) async => r = await confirmAction(ctx, title: 't', body: 'b', ok: '지우기'));
      expect(find.text('지우기'), findsOneWidget);
      await dismiss(tester, how);
      expect(r, isFalse);
    });

    testWidgets('104 지우기 미리 보기 창 ($how) → 실행 안 함', (tester) async {
      final src = p.join(tmp.path, 'src'), dst = p.join(tmp.path, 'dst');
      File(p.join(src, 'a.txt'))
        ..createSync(recursive: true)
        ..writeAsStringSync('a');
      File(p.join(dst, 'old.txt'))
        ..createSync(recursive: true)
        ..writeAsStringSync('o');
      bool? r;
      final t = CopyTask(id: '1', sources: [src], dest: dst, contents: true, method: 'rsync', options: '-av --delete');
      await host(tester, (ctx) async => r = await confirmDeletingRun(ctx, t));
      await settle(tester, () => find.textContaining('비교하는 중').evaluate().isEmpty, rounds: 200);
      expect(find.textContaining('− old.txt'), findsOneWidget);
      await dismiss(tester, how);
      expect(r, isFalse);
    });

    testWidgets('42 지울 목록 창 ($how) → 지우지도 · 지우기를 끄지도 않음', (tester) async {
      final src = p.join(tmp.path, 's'), dst = p.join(tmp.path, 'd');
      File(p.join(src, 'a.txt'))
        ..createSync(recursive: true)
        ..writeAsStringSync('a');
      File(p.join(dst, 'only.txt'))
        ..createSync(recursive: true)
        ..writeAsStringSync('o');
      final pair = LiveSyncPair(src, dst, delete: true);
      c.settings.liveSyncPairs = [pair];
      final live = LiveSync(c);
      addTearDown(live.dispose);
      await tester.runAsync(() => live.syncNow(pair));
      expect(live.toDelete[LiveSync.keyOf(pair)], ['only.txt']);
      await host(tester, (ctx) => confirmLiveDeletes(ctx, live, c.settings.liveSyncPairs.single));
      await dismiss(tester, how == 'cancel' ? 'back' : how); // 이 창의 "닫기" 는 [나중에]
      await settle(tester, () => false, rounds: 10);
      expect(File(p.join(dst, 'only.txt')).existsSync(), isTrue);
      expect(c.settings.liveSyncPairs.single.delete, isTrue);
      expect(c.settings.liveSyncPairs.single.deleteConfirmed, isFalse);
    });

    testWidgets('70 원본이 빈 쌍의 [그래도 맞추기] 창 ($how) → 지우지 않음', (tester) async {
      final src = p.join(tmp.path, 'e'), dst = p.join(tmp.path, 'f');
      Directory(src).createSync();
      File(p.join(dst, 'keep.txt'))
        ..createSync(recursive: true)
        ..writeAsStringSync('k');
      final pair = LiveSyncPair(src, dst, delete: true).copyWith(deleteConfirmed: true);
      c.settings.liveSyncPairs = [pair];
      final live = LiveSync(c);
      addTearDown(live.dispose);
      await tester.runAsync(() => live.syncNow(pair));
      await host(tester, (ctx) => confirmEmptySourceSync(ctx, live, pair));
      await dismiss(tester, how);
      await settle(tester, () => false, rounds: 10);
      expect(File(p.join(dst, 'keep.txt')).existsSync(), isTrue);
    });

    testWidgets('65 탐색기 지우기 창 ($how) → 그대로', (tester) async {
      final dir = p.join(tmp.path, 'x');
      final f = File(p.join(dir, 'doc.txt'))
        ..createSync(recursive: true)
        ..writeAsStringSync('d');
      c.settings
        ..explorerLayout = 'single'
        ..explorerPaths = [dir, dir];
      tester.view.physicalSize = const Size(1600, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.runAsync(() => tester.pumpWidget(MaterialApp(home: ExplorerPage(c: c))));
      await settle(tester, () => find.text('doc.txt').evaluate().isNotEmpty);
      await act(tester, () => tester.tap(find.text('doc.txt').first));
      await settle(tester, () => false, rounds: 10);
      await act(tester, () => tester.tap(find.text('삭제').first));
      await tester.pumpAndSettle();
      await dismiss(tester, how);
      await settle(tester, () => false, rounds: 10);
      expect(f.existsSync(), isTrue);
    });
  }

  testWidgets('104: 모니터링 [실행] 도 지우기가 있으면 미리 보기를 거친다 (취소하면 실행 안 함)', (tester) async {
    final src = p.join(tmp.path, 'ms'), dst = p.join(tmp.path, 'md');
    File(p.join(src, 'a.txt'))
      ..createSync(recursive: true)
      ..writeAsStringSync('a');
    final keep = File(p.join(dst, 'keep.txt'))
      ..createSync(recursive: true)
      ..writeAsStringSync('k');
    c.settings.copyTasks = [CopyTask(id: '1', sources: [src], dest: dst, contents: true, method: 'rsync', options: '-av --delete')];
    tester.view.physicalSize = const Size(1500, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: MonitorPage(c: c)));
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, '실행').first);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('지우기가 들어 있는 작업입니다'), findsOneWidget);
    await settle(tester, () => find.textContaining('비교하는 중').evaluate().isEmpty, rounds: 200);
    expect(find.textContaining('− keep.txt'), findsOneWidget);
    await tester.tap(find.text('취소').last);
    await tester.pumpAndSettle();
    await settle(tester, () => false, rounds: 10);
    expect(keep.existsSync(), isTrue);
    expect(find.text('아직 실행 안 함'), findsOneWidget);
  });

  testWidgets('105: 원본이 대상 안 + 창에서 [원본 파일 지우기] 로 지우기 옵션이 생기면 막는다', (tester) async {
    final outer = p.join(tmp.path, 'O'), inner = p.join(outer, 'in');
    File(p.join(inner, 'n.txt'))
      ..createSync(recursive: true)
      ..writeAsStringSync('n');
    final center = CopyCenter.of(c);
    c.settings
      ..rsyncOptions = '-avPog'
      ..explorerLayout = 'single'
      ..rsyncPaths = [outer, tmp.path];
    // 이동 (원본 파일 지우기) 작업만 --delete 를 기억
    await center.remember([inner], outer, contents: true, method: 'rsync', move: true).then((t) => center.update(t.copyWith(options: '-avPog --delete')));
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.runAsync(() => tester.pumpWidget(MaterialApp(home: ExplorerPage(c: c, rsync: true))));
    await settle(tester, () => find.text('in').evaluate().isNotEmpty && find.text('O').evaluate().isNotEmpty);
    await act(tester, () => tester.tap(find.text('in').first));
    await act(tester, () => tester.tap(find.text('O').last));
    await settle(tester, () => false, rounds: 5);
    await act(tester, () => tester.tap(find.text('좌 → 우')));
    await settle(tester, () => find.textContaining('비교하는 중').evaluate().isEmpty, rounds: 200);
    expect(find.text('rsync'), findsWidgets);
    await tester.tap(find.text('원본 파일 지우기 (--remove-source-files)'));
    await tester.pump();
    expect(find.text('원본이 대상 안에 있으면 지우기 (--delete) 를 함께 쓸 수 없습니다 (대상의 다른 파일이 모두 지워집니다).'), findsOneWidget);
    expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, '이동')).onPressed, isNull);
    await tester.tap(find.text('취소').last);
    await tester.pumpAndSettle();
  });

  testWidgets('112 · 114: 모니터링 작업 - 짧은 경로, 저장하지 않은 고침이 있으면 [실행] 할 때 묻는다 (저장하면 그 옵션 · 지우기면 미리 보기)',
      (tester) async {
    final src = p.join(tmp.path, 'Download', 'movies'), dst = p.join(tmp.path, 'backup', 'movies');
    File(p.join(src, 'a.txt'))
      ..createSync(recursive: true)
      ..writeAsStringSync('a');
    File(p.join(dst, 'keep.txt'))
      ..createSync(recursive: true)
      ..writeAsStringSync('k');
    c.settings.copyTasks = [CopyTask(id: '1', sources: [src], dest: dst, contents: true, method: 'rsync', options: '-av')];
    tester.view.physicalSize = const Size(1500, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: MonitorPage(c: c)));
    await tester.pump();
    expect(find.text('… › ${p.basename(tmp.path)} › Download › movies'), findsOneWidget); // 112
    await tester.enterText(find.widgetWithText(TextField, '옵션'), '-av --delete');
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, '실행').first);
    await tester.pumpAndSettle();
    expect(find.text('고친 옵션을 저장하지 않았습니다'), findsOneWidget);
    await tester.tap(find.text('저장하고 실행'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(c.settings.copyTasks.single.options, '-av --delete');
    // 저장한 옵션에 지우기가 있으므로 미리 보기 창
    expect(find.text('지우기가 들어 있는 작업입니다'), findsOneWidget);
    await settle(tester, () => find.textContaining('비교하는 중').evaluate().isEmpty, rounds: 200);
    expect(find.textContaining('− keep.txt'), findsOneWidget);
    await tester.tap(find.text('취소').last);
    await tester.pumpAndSettle();
    expect(File(p.join(dst, 'keep.txt')).existsSync(), isTrue);
  });
}
