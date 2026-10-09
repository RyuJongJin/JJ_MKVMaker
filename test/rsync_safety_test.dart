import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jj_mkvmaker/app/app_controller.dart';
import 'package:jj_mkvmaker/app/copy_center.dart';
import 'package:jj_mkvmaker/core/webdav.dart';
import 'package:jj_mkvmaker/platform/windows/desktop_storage_service.dart';
import 'package:jj_mkvmaker/platform/windows/process_media_tool.dart';
import 'package:jj_mkvmaker/services/platform_services.dart';
import 'package:jj_mkvmaker/ui/explorer_page.dart';
import 'package:path/path.dart' as p;

import 'explorer_test.dart' show act, settle;
import 'support/dav_server.dart';

/// 95 · 96 · 97 · 100: Rsync 화면의 지우기 - 확인 창 · 미리 보기 · 실행이 같고, ⇄ 는 차례로 (← 는 지우지 않음)
void main() {
  late Directory tmp, remote;
  late String left;
  late TestDavServer server;
  late AppController c;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('jj_rsync_safe_');
    left = p.join(tmp.path, 'L');
    remote = Directory(p.join(tmp.path, 'remote'))..createSync();
    File(p.join(left, 'sub', 'a.txt'))
      ..createSync(recursive: true)
      ..writeAsStringSync('a');
    File(p.join(remote.path, 'rsub', 'b.txt'))
      ..createSync(recursive: true)
      ..writeAsStringSync('b');
    server = TestDavServer(remote);
    await server.start();
    final s = DavServer(id: 'nas', name: '집 NAS', url: server.url, user: 'user', password: 'pass');
    c = AppController(PlatformServices(mediaTool: ProcessMediaTool('x', 'y'), storage: DesktopStorageService()));
    c.settings
      ..webdavServers = [s]
      ..explorerLayout = 'single'
      ..rsyncPaths = [left, 'dav://nas/'];
    DavRegistry.configure([s]);
  });
  tearDown(() async {
    DavRegistry.configure([]);
    await server.stop();
    tmp.deleteSync(recursive: true);
  });

  Future<void> open(WidgetTester tester) async {
    HttpOverrides.global = null;
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.runAsync(() => tester.pumpWidget(MaterialApp(home: ExplorerPage(c: c, rsync: true))));
    await settle(tester, () => find.text('sub').evaluate().isNotEmpty && find.text('rsub').evaluate().isNotEmpty);
    await act(tester, () => tester.tap(find.text('sub')));
    await act(tester, () => tester.tap(find.text('rsub')));
    await settle(tester, () => false, rounds: 5);
  }

  Future<void> waitCompare(WidgetTester tester) =>
      settle(tester, () => find.textContaining('비교하는 중').evaluate().isEmpty, rounds: 400);

  FilledButton runButton(WidgetTester tester) =>
      tester.widget<FilledButton>(find.ancestor(of: find.textContaining('실행').last, matching: find.byType(FilledButton)).first);

  testWidgets('100 · 95: WebDAV ⇄ + --delete - 미리 보기대로 → (지움) 다음 ← (지우지 않음), 한쪽에만 있던 새 파일이 양쪽에서 사라지지 않는다',
      (tester) async {
    c.settings.rsyncOptions = '-avPog --delete';
    await open(tester);
    await act(tester, () => tester.tap(find.text('좌 ⇄ 우')));
    await waitCompare(tester);
    // 미리 보기: → 에서 오른쪽에만 있는 b 는 지워짐, a 는 → 로 복사
    expect(find.textContaining('− b.txt'), findsOneWidget);
    expect(find.textContaining('→ + a.txt'), findsOneWidget);
    // 두 번째 (←) 는 지우기 없이
    expect(find.textContaining('-avPog -u --delete'), findsNothing);
    expect(find.textContaining('rsync -avPog -u'), findsWidgets);
    expect(runButton(tester).onPressed, isNotNull);
    expect(find.text('받는 쪽에서 1개가 지워집니다 (--delete, 되돌릴 수 없음)'), findsOneWidget);
    await act(tester, () => tester.tap(find.widgetWithText(FilledButton, '실행')));
    await settle(tester, () => find.byType(LinearProgressIndicator).evaluate().isEmpty && find.textContaining('rsync 끝').evaluate().isNotEmpty,
        rounds: 400);
    // 결과가 미리 보기와 같다: 오른쪽에 a (b 는 지워짐), 왼쪽에도 a 만 (b 가 되돌아오지 않음)
    expect(File(p.join(remote.path, 'rsub', 'a.txt')).existsSync(), isTrue);
    expect(File(p.join(remote.path, 'rsub', 'b.txt')).existsSync(), isFalse);
    expect(File(p.join(left, 'sub', 'a.txt')).existsSync(), isTrue);
    expect(File(p.join(left, 'sub', 'b.txt')).existsSync(), isFalse);
  });

  testWidgets('96: 원본 파일 지우기를 켜면 확인 창 · 미리 보기가 실제 실행할 (이동) 작업의 옵션으로 바뀐다', (tester) async {
    // 기억해 둔 (복사) 작업은 --delete 없음, 새 작업의 기본 옵션은 --delete 있음
    c.settings.rsyncOptions = '-avPog --delete';
    await open(tester);
    await CopyCenter.of(c)
        .remember([p.join(left, 'sub')], 'dav://nas/rsub', contents: true, method: 'rsync')
        .then((t) => CopyCenter.of(c).update(t.copyWith(options: '-avPog')));
    await act(tester, () => tester.tap(find.text('좌 → 우')));
    await waitCompare(tester);
    expect(find.textContaining('rsync -avPog --delete'), findsNothing);
    expect(find.textContaining('− b.txt'), findsNothing);
    // 원본 파일 지우기 (이동 작업) → 그 작업의 옵션 (--delete) 으로 다시 보이고 다시 비교한다
    await tester.tap(find.text('원본 파일 지우기 (--remove-source-files)'));
    await tester.pump();
    expect(find.textContaining('rsync -avPog --delete --remove-source-files'), findsOneWidget);
    await waitCompare(tester);
    expect(find.textContaining('− b.txt'), findsOneWidget);
    expect(find.text('받는 쪽에서 1개가 지워집니다 (--delete, 되돌릴 수 없음)'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, '이동'), findsOneWidget);
    await tester.tap(find.text('취소'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 20)); // HTTP 연결 유휴 타이머
  });

  testWidgets('97: [다시 비교] 하는 동안은 지우는 실행을 누를 수 없다', (tester) async {
    c.settings.rsyncOptions = '-avPog --del';
    await open(tester);
    await act(tester, () => tester.tap(find.text('좌 → 우')));
    await waitCompare(tester);
    expect(find.text('받는 쪽에서 1개가 지워집니다 (--delete, 되돌릴 수 없음)'), findsOneWidget); // --del 도 지우기로 알아본다
    await tester.tap(find.byTooltip('다시 비교'));
    await tester.pump();
    expect(runButton(tester).onPressed, isNull);
    await waitCompare(tester);
    expect(runButton(tester).onPressed, isNotNull);
    await tester.tap(find.text('취소'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 20)); // HTTP 연결 유휴 타이머
  });

  for (final how in ['back', 'barrier', 'cancel']) {
    testWidgets('110: 확인 창을 닫으면 ($how) 아무것도 하지 않는다', (tester) async {
      await open(tester);
      await act(tester, () => tester.tap(find.text('좌 ⇄ 우')));
      await waitCompare(tester);
      expect(find.text('rsync 양쪽 (⇄)'), findsOneWidget);
      switch (how) {
        case 'back':
          await tester.runAsync(() => tester.binding.handlePopRoute());
        case 'barrier':
          await tester.tapAt(const Offset(5, 5));
        default:
          await tester.tap(find.text('취소'));
      }
      await tester.pumpAndSettle();
      expect(find.text('rsync 양쪽 (⇄)'), findsNothing);
      // 몇 초 기다려도 복사되지 않는다
      await settle(tester, () => false, rounds: 60);
      expect(File(p.join(remote.path, 'rsub', 'a.txt')).existsSync(), isFalse);
      expect(File(p.join(left, 'sub', 'b.txt')).existsSync(), isFalse);
      expect(c.settings.copyTasks, isEmpty);
      await tester.pump(const Duration(seconds: 20));
    });
  }

  testWidgets('110: 좁은 화면 - 비교가 끝나도 [취소] · [실행] 자리가 그대로, 창을 여러 번 열고 닫아도 실행되지 않음', (tester) async {
    c.settings.rsyncOptions = '-avPog --delete';
    HttpOverrides.global = null;
    tester.view.physicalSize = const Size(900, 1400); // 세로로 든 태블릿
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.runAsync(() => tester.pumpWidget(MaterialApp(home: ExplorerPage(c: c, rsync: true))));
    await settle(tester, () => find.text('sub').evaluate().isNotEmpty && find.text('rsub').evaluate().isNotEmpty);
    await act(tester, () => tester.tap(find.text('sub')));
    await act(tester, () => tester.tap(find.text('rsub')));
    await settle(tester, () => false, rounds: 5);
    // 기억된 작업이 없을 때 · 한 번 저장된 뒤 (기억된 작업이 있을 때) 둘 다
    for (var round = 0; round < 6; round++) {
      if (round == 3) {
        await CopyCenter.of(c).remember([p.join(left, 'sub')], 'dav://nas/rsub', contents: true, method: 'rsync');
        await CopyCenter.of(c).remember(['dav://nas/rsub'], p.join(left, 'sub'), contents: true, method: 'rsync');
      }
      await act(tester, () => tester.tap(find.textContaining(RegExp('(좌|위) ⇄ (우|아래)'))));
      await tester.pump(const Duration(milliseconds: 300));
      final cancelAt = tester.getCenter(find.text('취소').last);
      await waitCompare(tester);
      // 비교가 끝나도 [취소] 는 같은 자리 (그 자리를 누르면 취소)
      expect(tester.getCenter(find.text('취소').last), cancelAt);
      switch (round % 3) {
        case 0:
          await tester.tapAt(cancelAt);
        case 1:
          await tester.runAsync(() => tester.binding.handlePopRoute());
        default:
          await tester.tapAt(const Offset(4, 4));
      }
      await tester.pumpAndSettle();
      expect(find.text('rsync 양쪽 (⇄)'), findsNothing);
      await settle(tester, () => false, rounds: 20);
      expect(File(p.join(remote.path, 'rsub', 'a.txt')).existsSync(), isFalse, reason: 'round $round');
      expect(File(p.join(remote.path, 'rsub', 'b.txt')).existsSync(), isTrue, reason: 'round $round');
    }
    await tester.pump(const Duration(seconds: 20));
  });
}
