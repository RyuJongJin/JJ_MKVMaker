import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jj_mkvmaker/app/app_controller.dart';
import 'package:jj_mkvmaker/app/live_sync.dart';
import 'package:jj_mkvmaker/app/settings.dart';
import 'package:jj_mkvmaker/core/file_ops.dart';
import 'package:jj_mkvmaker/platform/android/android_keep_alive.dart';
import 'package:jj_mkvmaker/platform/windows/desktop_storage_service.dart';
import 'package:jj_mkvmaker/platform/windows/process_media_tool.dart';
import 'package:jj_mkvmaker/services/platform_services.dart';
import 'package:jj_mkvmaker/ui/explorer_page.dart';
import 'package:jj_mkvmaker/ui/monitor_page.dart';
import 'package:path/path.dart' as p;

import 'explorer_test.dart' show act, settle;

/// 68 · 70 · 71
void main() {
  late Directory tmp;
  late String src, dst;
  late AppController c;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('jj_sync_problem_');
    src = p.join(tmp.path, 'src');
    dst = p.join(tmp.path, 'backup');
    File(p.join(dst, 'keep1.txt'))
      ..createSync(recursive: true)
      ..writeAsStringSync('1');
    File(p.join(dst, 'sub', 'keep2.txt'))
      ..createSync(recursive: true)
      ..writeAsStringSync('2');
    c = AppController(PlatformServices(mediaTool: ProcessMediaTool('x', 'y'), storage: DesktopStorageService()));
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  int count() => Directory(dst).listSync(recursive: true).whereType<File>().length;

  test('68: 원본을 읽을 수 없으면 문제로 기억 (짧은 원인 · 원문 예외 없음) · "맞출 것 없음" 이 아님 · 작업 알림 맨 앞', () async {
    final pair = LiveSyncPair(src, dst, delete: true).copyWith(deleteConfirmed: true);
    c.settings.liveSyncPairs = [pair];
    final live = LiveSync(c);
    final k = LiveSync.keyOf(pair);
    await live.refreshPending(pair);
    expect(live.problems[k], isNotNull);
    await live.syncNow(pair);
    final e = live.problems[k]!;
    expect(e.empty, isFalse);
    expect(e.detail, '폴더가 없습니다');
    expect('$e', isNot(contains('FileSystemException')));
    expect(live.status[k]!.$2, '원본을 읽을 수 없어 멈춤');
    expect(count(), 2);
    expect(AndroidKeepAlive.status(null, false, 0, null, stopped: 1).$1, startsWith('⚠ 동기화 멈춤 1개'));
    // 원본이 돌아오면 다시 세기 · 맞추기로 문제가 사라진다
    File(p.join(src, 'keep1.txt'))
      ..createSync(recursive: true)
      ..writeAsStringSync('1');
    await live.refreshPending(pair);
    expect(live.problems[k], isNull);
    live.dispose();
  });

  test('70: 원본이 정말 비었으면 멈추고 지울 목록 → [그래도 맞추기] 로 그 한 번만 지운다', () async {
    Directory(src).createSync();
    final pair = LiveSyncPair(src, dst, delete: true).copyWith(deleteConfirmed: true);
    c.settings.liveSyncPairs = [pair];
    final live = LiveSync(c);
    final k = LiveSync.keyOf(pair);
    await live.syncNow(pair);
    expect(live.problems[k]?.empty, isTrue);
    expect(live.emptyDeletes[k], unorderedEquals(['keep1.txt', 'sub']));
    expect(count(), 2);
    await live.syncEmptyAnyway(pair);
    expect(count(), 0);
    expect(live.problems[k], isNull);
    // 한 번만: 다시 대상에 파일이 생기면 또 멈춘다
    File(p.join(dst, 'again.txt')).writeAsStringSync('a');
    await live.syncNow(pair);
    expect(live.problems[k]?.empty, isTrue);
    expect(File(p.join(dst, 'again.txt')).existsSync(), isTrue);
    live.dispose();
  });

  test('34: 안쪽 → 바깥은 지우기 없이만 맞춘다 · 바깥 → 안쪽 · 안쪽 → 바깥 + 지우기는 막는다', () async {
    final outer = p.join(tmp.path, 'outer'), inner = p.join(outer, 'inner');
    File(p.join(inner, 'new.txt'))
      ..createSync(recursive: true)
      ..writeAsStringSync('n');
    File(p.join(outer, 'other.txt')).writeAsStringSync('o');
    final live = LiveSync(c);
    // 안쪽 → 바깥, 지우기 없음: 맞춘다 (다른 파일은 그대로)
    final ok = LiveSyncPair(inner, outer);
    c.settings.liveSyncPairs = [ok];
    await live.syncNow(ok);
    expect(File(p.join(outer, 'new.txt')).existsSync(), isTrue);
    expect(File(p.join(outer, 'other.txt')).existsSync(), isTrue);
    // 안쪽 → 바깥 + 지우기: 막는다 (대상의 다른 파일을 지우지 않음)
    final del = LiveSyncPair(inner, outer, delete: true).copyWith(deleteConfirmed: true);
    expect(LiveSync.nestingProblem(del), isNotNull);
    await live.syncNow(del);
    expect(File(p.join(outer, 'other.txt')).existsSync(), isTrue);
    expect(live.status[LiveSync.keyOf(del)]!.$2, contains('지우기 포함으로 맞출 수 없습니다'));
    // 바깥 → 안쪽: 막는다
    expect(LiveSync.nestingProblem(LiveSyncPair(outer, inner)), isNotNull);
    live.dispose();
  });

  testWidgets('68 · 70: lsync 카드 - "맞출 것 없음" 대신 빨간 안내 · 할 일 · [다시 시도] · [지울 목록 보고 결정] → [그래도 맞추기]',
      (tester) async {
    Directory(src).createSync();
    final pair = LiveSyncPair(src, dst, delete: true).copyWith(deleteConfirmed: true);
    c.settings.liveSyncPairs = [pair];
    final live = LiveSync(c);
    LiveSync.instance = live;
    addTearDown(() {
      LiveSync.instance = null;
      live.dispose();
    });
    await tester.runAsync(() => live.syncNow(pair));
    tester.view.physicalSize = const Size(1500, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: MonitorPage(c: c)));
    await tester.tap(find.text('lsync (실시간 동기화)'));
    await tester.pumpAndSettle();
    expect(find.text('원본 폴더가 비어 있어 멈췄습니다'), findsOneWidget);
    expect(find.text('대상 파일은 지우지 않았습니다.'), findsOneWidget);
    expect(find.text('맞출 것 없음 (원본과 대상이 같습니다)'), findsNothing);
    expect(find.text('다시 시도'), findsOneWidget);
    await tester.tap(find.text('지울 목록 보고 결정'));
    await tester.pumpAndSettle();
    expect(find.text('원본이 비어 있습니다. 대상에서 2개를 지울까요?'), findsOneWidget);
    await tester.tap(find.text('그래도 맞추기 (2개 지움)'));
    await settle(tester, () => count() == 0 && live.problems.isEmpty && !live.anyRunning);
    expect(count(), 0);
    await tester.pumpAndSettle();
    expect(find.text('원본 폴더가 비어 있어 멈췄습니다'), findsNothing);
  });

  testWidgets('93: Rsync --delete 실행은 비교가 끝나 지울 목록이 보인 뒤에만 [실행] 이 켜진다', (tester) async {
    final l = p.join(tmp.path, 'L'), r = p.join(tmp.path, 'R');
    File(p.join(l, 'sub', 'a.txt'))
      ..createSync(recursive: true)
      ..writeAsStringSync('a');
    File(p.join(r, 'rsub', 'only_r.txt'))
      ..createSync(recursive: true)
      ..writeAsStringSync('r');
    c.settings
      ..explorerLayout = 'single'
      ..rsyncOptions = '-avPog --delete'
      ..rsyncPaths = [l, r];
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.runAsync(() => tester.pumpWidget(MaterialApp(home: ExplorerPage(c: c, rsync: true))));
    await settle(tester, () => find.text('sub').evaluate().isNotEmpty && find.text('rsub').evaluate().isNotEmpty);
    await act(tester, () => tester.tap(find.text('sub')));
    await act(tester, () => tester.tap(find.text('rsub')));
    await settle(tester, () => false, rounds: 5);
    await act(tester, () => tester.tap(find.text('좌 → 우')));
    await tester.pump();
    // 비교가 끝나기 전: 꺼져 있고 이유를 보여 준다
    expect(find.text('지우기가 들어간 실행이라, 지울 목록이 나온 뒤에 실행할 수 있습니다.'), findsOneWidget);
    expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, '실행')).onPressed, isNull);
    await settle(tester, () => find.textContaining('비교하는 중').evaluate().isEmpty, rounds: 400);
    // 끝나면: 지울 목록 (빨강) · [실행 (1개 지움)] 켜짐
    expect(find.text('받는 쪽에서 1개가 지워집니다 (--delete, 되돌릴 수 없음)'), findsOneWidget);
    expect(find.textContaining('− only_r.txt'), findsOneWidget);
    expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, '실행')).onPressed, isNotNull);
    await tester.tap(find.text('취소'));
    await tester.pumpAndSettle();
  });

  testWidgets('71: 끊겨 남은 .jjpart 는 탐색기에 "만들다 만 파일" 로 보이고 확인 후 지운다 (지금 쓰는 것은 빼고)', (tester) async {
    final dir = p.join(tmp.path, 'left');
    File(p.join(dir, 'doc.txt'))
      ..createSync(recursive: true)
      ..writeAsStringSync('hello');
    final old = File(p.join(dir, 'movie.mkv.jjpart'))..writeAsStringSync('half');
    old.setLastModifiedSync(DateTime.now().subtract(const Duration(hours: 1)));
    final writing = File(p.join(dir, 'now.mkv.jjpart'))..writeAsStringSync('half'); // 지금 쓰는 중 (방금 바뀜)
    expect(isPartialFile('a.jjsync'), isTrue);
    c.settings.explorerPaths = [dir, dir];
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.runAsync(() => tester.pumpWidget(MaterialApp(home: ExplorerPage(c: c))));
    await settle(tester, () => find.text('doc.txt').evaluate().isNotEmpty);
    expect(find.text('만들다 만 파일 1개'), findsWidgets);
    await act(tester, () => tester.tap(find.text('지우기').first));
    await tester.pumpAndSettle();
    expect(find.text('만들다 만 파일 1개를 지울까요?'), findsOneWidget);
    expect(find.text('movie.mkv.jjpart'), findsWidgets);
    await act(tester, () => tester.tap(find.widgetWithText(FilledButton, '지우기')));
    await settle(tester, () => !old.existsSync() && find.text('만들다 만 파일 1개').evaluate().isEmpty);
    expect(old.existsSync(), isFalse);
    expect(writing.existsSync(), isTrue);
    expect(find.text('만들다 만 파일 1개'), findsNothing);
  });
}
