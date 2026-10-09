import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jj_mkvmaker/app/app_controller.dart';
import 'package:jj_mkvmaker/platform/windows/desktop_storage_service.dart';
import 'package:jj_mkvmaker/platform/windows/process_media_tool.dart';
import 'package:jj_mkvmaker/services/platform_services.dart';
import 'package:jj_mkvmaker/ui/explorer_page.dart';
import 'package:path/path.dart' as p;

import 'support/recycle_leftovers.dart';

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
  tearDown(() async {
    ExplorerPage.debugVolumes = null;
    // 휴지통을 건드리는 시험 (148 · 144): 사용자 휴지통에 이 시험 폴더 아래의 흔적이 없는지 스스로 확인
    expect(await recycleLeftovers(tmp.path), 0, reason: '사용자 휴지통에 시험 흔적 없음 (하위 폴더 포함)');
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

  testWidgets('144: 긴 경로는 휴지통에 넣지 못한 이유 한 줄과 [영구 삭제] - 누르면 지운다 · [그대로 두기] 면 남는다', (tester) async {
    String lp(String s) => r'\\?\' + s;
    var deep = p.join(left, 'deep');
    while (deep.length < 250) {
      deep = p.join(deep, 'd' * 30);
    }
    Directory(lp(deep)).createSync(recursive: true);
    File(lp(p.join(deep, 'a_file_name_that_makes_it_longer.txt'))).writeAsStringSync('x');
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.runAsync(() => tester.pumpWidget(MaterialApp(home: ExplorerPage(c: c))));
    await settle(tester, () => find.text('deep').evaluate().isNotEmpty);
    Future<void> deleteDeep() async {
      await tester.runAsync(() => tester.tap(find.text('deep').first));
      await settle(tester, () => false, rounds: 10);
      await tester.runAsync(() => tester.tap(find.text('삭제').first));
      await tester.pumpAndSettle();
      await tester.runAsync(() => tester.tap(find.widgetWithText(FilledButton, '휴지통으로')));
      await settle(tester, () => find.textContaining('경로가 너무 길어').evaluate().isNotEmpty);
    }

    await deleteDeep();
    // 이유는 한 줄, 항목은 이름만, 버튼은 [그대로 두기] · [영구 삭제]
    expect(find.textContaining('경로가 너무 길어 휴지통에 넣을 수 없습니다'), findsOneWidget);
    expect(find.text('· deep'), findsOneWidget);
    expect(find.textContaining('영구 삭제로 지울 수 있습니다'), findsNothing, reason: '긴 설명을 항목마다 되풀이하지 않음');
    await tester.tap(find.text('그대로 두기'));
    await tester.pumpAndSettle();
    expect(Directory(lp(deep)).existsSync(), isTrue);
    // 다시 → [영구 삭제]
    await deleteDeep();
    await tester.runAsync(() => tester.tap(find.textContaining('영구 삭제 (1개, 되돌릴 수 없음)')));
    await settle(tester, () => find.textContaining('영구 삭제했습니다').evaluate().isNotEmpty);
    expect(Directory(p.join(left, 'deep')).existsSync(), isFalse);
    expect(find.textContaining('1개를 영구 삭제했습니다.'), findsOneWidget);
  }, skip: !Platform.isWindows);

  testWidgets('49: 뒤로 키 - 먼저 고른 것 풀기 → 상위 폴더 → 맨 위에서 화면 닫기', (tester) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    // 시험 폴더를 저장 장치 맨 위로 (left 에서 한 번 올라가면 맨 위)
    ExplorerPage.debugVolumes = () => [(tmp.path, 'T:')];
    final navKey = GlobalKey<NavigatorState>();
    await tester.runAsync(() => tester.pumpWidget(MaterialApp(navigatorKey: navKey, home: const Text('앞 화면'))));
    unawaited(navKey.currentState!.push(MaterialPageRoute<void>(builder: (_) => ExplorerPage(c: c))));
    await settle(tester, () => find.text('doc.txt').evaluate().isNotEmpty);
    Future<void> back() async {
      await tester.runAsync(() => tester.binding.handlePopRoute());
      await settle(tester, () => false, rounds: 10);
    }

    // 표시 (선택 모드) 를 켜고 doc.txt 를 고름
    await tester.runAsync(() => tester.tap(find.text('선택').first));
    await settle(tester, () => false, rounds: 5);
    await tester.runAsync(() => tester.tap(find.text('doc.txt').first));
    await settle(tester, () => false, rounds: 5);
    expect(find.textContaining('1개 표시함'), findsOneWidget);
    await back(); // 1) 고른 것 풀기 (화면은 그대로)
    expect(find.textContaining('표시함'), findsNothing);
    expect(find.byType(ExplorerPage), findsOneWidget);
    expect(find.textContaining(p.join(tmp.path, 'left')), findsWidgets, reason: '아직 left 폴더');
    await back(); // 2) 상위 폴더 (= 맨 위)
    expect(find.byType(ExplorerPage), findsOneWidget);
    expect(find.textContaining(p.join(tmp.path, 'left')), findsNothing);
    await back(); // 3) 맨 위에서는 화면 닫기
    await tester.pumpAndSettle(); // 닫히는 전환 (가짜 시간을 흘려야 끝난다)
    expect(find.byType(ExplorerPage), findsNothing);
    expect(find.text('앞 화면'), findsOneWidget);
  });

  testWidgets('E10: 권한 없는 폴더는 빈 폴더가 아니라 "읽을 수 없음 · 이유" 와 [다시 시도]', (tester) async {
    const locked = r'C:\System Volume Information';
    if (!Platform.isWindows || !Directory(locked).existsSync()) return;
    c.settings.explorerPaths = [locked, right];
    ExplorerPage.debugVolumes = () => [(r'C:\', 'C:'), (p.rootPrefix(tmp.path), p.rootPrefix(tmp.path).substring(0, 2))];
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.runAsync(() => tester.pumpWidget(MaterialApp(home: ExplorerPage(c: c))));
    await settle(tester, () => find.textContaining('이 폴더를 읽을 권한이 없습니다').evaluate().isNotEmpty);
    expect(find.textContaining('이 폴더를 읽을 권한이 없습니다'), findsOneWidget);
    expect(find.text('다시 시도'), findsOneWidget);
  });

  testWidgets('135: 두 창이 같은 폴더 - [이동] 은 "이미 이 폴더에 있습니다" 창 · [복사] 는 사본을 만들지 묻는다', (tester) async {
    c.settings.explorerPaths = [left, left];
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.runAsync(() => tester.pumpWidget(MaterialApp(home: ExplorerPage(c: c))));
    await settle(tester, () => find.text('doc.txt').evaluate().length >= 2);
    await tester.runAsync(() => tester.tap(find.text('선택').first));
    await settle(tester, () => false, rounds: 5);
    await tester.runAsync(() => tester.tap(find.text('doc.txt').first));
    await settle(tester, () => false, rounds: 5);
    expect(find.textContaining('1개 표시함'), findsOneWidget);
    await tester.runAsync(() => tester.tap(find.text('이동').first));
    await settle(tester, () => find.byType(AlertDialog).evaluate().isNotEmpty, rounds: 30);
    // 짧은 알림은 놓치기 쉬워 창으로 (135)
    expect(find.descendant(of: find.byType(AlertDialog), matching: find.text('이미 이 폴더에 있습니다')), findsOneWidget);
    expect(find.textContaining('doc.txt 은(는) 이미 이 폴더에 있어 옮길 것이 없습니다'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, '확인'));
    await tester.pumpAndSettle();
    expect(File(p.join(left, 'doc.txt')).existsSync(), isTrue);
    // 같은 폴더로 [복사] 는 사본을 만들지 묻는다: [취소] → 그대로, [사본 만들기] → "doc (2).txt"
    await tester.runAsync(() => tester.tap(find.text('복사').first));
    await settle(tester, () => find.byType(AlertDialog).evaluate().isNotEmpty, rounds: 30);
    expect(find.textContaining('같은 폴더에 사본을 만들까요? (이름 (2))'), findsOneWidget);
    await tester.tap(find.text('취소'));
    await tester.pumpAndSettle();
    expect(File(p.join(left, 'doc (2).txt')).existsSync(), isFalse);
    await tester.runAsync(() => tester.tap(find.text('복사').first));
    await settle(tester, () => find.byType(AlertDialog).evaluate().isNotEmpty, rounds: 30);
    await tester.runAsync(() => tester.tap(find.widgetWithText(FilledButton, '사본 만들기')));
    await settle(tester, () => File(p.join(left, 'doc (2).txt')).existsSync() && find.byType(SnackBar).evaluate().isNotEmpty);
    expect(File(p.join(left, 'doc (2).txt')).readAsStringSync(), 'new');
    expect(find.widgetWithText(FilledButton, '복사'), findsNothing, reason: '확인 창을 두 번 띄우지 않음');
  });

  testWidgets('135 보충: 섞어 고른 [이동] - 이미 그 폴더에 있는 것만 건너뛰고 나머지는 옮긴다 (확인 창 · 끝난 알림에 적음)', (tester) async {
    File(p.join(left, 'a.txt')).writeAsStringSync('a');
    File(p.join(right, 'b.txt')).writeAsStringSync('b');
    c.settings.explorerPaths = [tmp.path, right]; // 왼쪽 창은 left · right 를 함께 보는 위 폴더
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.runAsync(() => tester.pumpWidget(MaterialApp(home: ExplorerPage(c: c))));
    await settle(tester, () => find.text('left').evaluate().isNotEmpty);
    // 왼쪽 창에서 left · right 를 펼침
    await tester.runAsync(() => tester.tap(find.text('left').first));
    await settle(tester, () => find.text('a.txt').evaluate().isNotEmpty);
    await tester.runAsync(() => tester.tap(find.text('right').first));
    await settle(tester, () => find.text('b.txt').evaluate().length >= 2);
    await tester.runAsync(() => tester.tap(find.text('선택').first));
    await settle(tester, () => false, rounds: 5);
    await tester.runAsync(() => tester.tap(find.text('a.txt').first));
    await tester.runAsync(() => tester.tap(find.text('b.txt').first));
    await settle(tester, () => false, rounds: 5);
    expect(find.textContaining('2개 표시함'), findsOneWidget);
    await tester.runAsync(() => tester.tap(find.text('이동').first));
    await settle(tester, () => find.byType(AlertDialog).evaluate().isNotEmpty, rounds: 30);
    expect(find.textContaining('이미 이 폴더에 있어 건너뜀: b.txt'), findsOneWidget);
    await tester.runAsync(() => tester.tap(find.widgetWithText(FilledButton, '이동')));
    await settle(tester, () => File(p.join(right, 'a.txt')).existsSync() && find.byType(SnackBar).evaluate().isNotEmpty);
    expect(File(p.join(right, 'a.txt')).readAsStringSync(), 'a');
    expect(File(p.join(left, 'a.txt')).existsSync(), isFalse);
    expect(File(p.join(right, 'b.txt')).readAsStringSync(), 'b');
    expect(find.textContaining('이미 이 폴더에 있어 건너뜀: b.txt'), findsOneWidget, reason: '끝난 알림에도');
  });

  testWidgets('147: 버튼 줄이 다 들어가지 않으면 (낮은 화면) 나머지는 [더 보기] 메뉴로 - "숨은 항목 표시" 도 누를 수 있다', (tester) async {
    tester.view.physicalSize = const Size(1200, 560);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final before = c.settings.explorerShowHidden;
    await tester.runAsync(() => tester.pumpWidget(MaterialApp(home: ExplorerPage(c: c))));
    await settle(tester, () => find.text('doc.txt').evaluate().isNotEmpty);
    expect(tester.takeException(), isNull, reason: '넘침 없음');
    expect(find.text('더 보기'), findsOneWidget);
    expect(find.text('숨은 항목 표시'), findsNothing, reason: '들어가지 않는 버튼은 줄에 없음');
    await tester.tap(find.text('더 보기'));
    await tester.pumpAndSettle();
    expect(find.text('숨은 항목 표시'), findsOneWidget);
    await tester.runAsync(() => tester.tap(find.text('숨은 항목 표시')));
    await settle(tester, () => c.settings.explorerShowHidden != before, rounds: 20);
    expect(c.settings.explorerShowHidden, !before);
    // 창 배치 버튼은 좁아도 늘 줄에 (사용자 요청) · 처음 값은 자주 쓰는 것부터 (복사 · 이동 · 삭제 …)
    expect(find.byTooltip('창 배치: 좌우 (누르면 위아래)'), findsOneWidget);
    expect(ExplorerButton.fromSettings(const []).take(8).map((b) => b.name),
        ['copy', 'move', 'delete', 'newFolder', 'rename', 'select', 'search', 'orient']);
    expect(ExplorerButton.fromSettings(const ['hidden', 'copy']), [ExplorerButton.hidden, ExplorerButton.copy],
        reason: '사용자가 정한 순서는 그대로');
    // 넉넉한 화면에서는 [더 보기] 없이 모두
    tester.view.physicalSize = const Size(1600, 1400);
    await settle(tester, () => find.text('더 보기').evaluate().isEmpty, rounds: 20); // 숨은 항목을 바꿔 다시 읽는 중일 수 있어 정해진 만큼만
    expect(find.text('더 보기'), findsNothing);
  });

  testWidgets('157 · 162: 끝난 작업의 [열기] - 이 앱의 탐색기로 그 폴더를 연다 (이미 열려 있으면 그 화면에서 그 폴더로)', (tester) async {
    final out = Directory(p.join(tmp.path, 'out_AI'))..createSync();
    File(p.join(out.path, 'p1_x2.png')).writeAsStringSync('x');
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final navKey = GlobalKey<NavigatorState>();
    await tester.runAsync(() => tester.pumpWidget(MaterialApp(navigatorKey: navKey, home: const Text('앞 화면'))));
    unawaited(ExplorerPage.openAt(navKey.currentState!, c: c, dir: out.path));
    // 제목 (지금 경로) 이 그 폴더 - 목록은 저장 장치 맨 위부터라 그 파일 줄이 화면 밖일 수 있다
    await settle(tester, () => find.text(out.path).evaluate().isNotEmpty);
    expect(find.text(out.path), findsOneWidget);
    expect(ExplorerPage.goToRequest.value, isNull, reason: '간 뒤에는 비움');
    // 이미 열린 채로 다른 폴더를 요청하면 새 화면을 쌓지 않고 그 화면에서
    // (실제 비동기 구역에서: 그때 시작한 폴더 읽기가 시험의 가짜 시간에 묶이지 않게)
    await tester.runAsync(() async => unawaited(ExplorerPage.openAt(navKey.currentState!, c: c, dir: right)));
    await settle(tester, () => find.text(right).evaluate().isNotEmpty);
    expect(find.byType(ExplorerPage), findsOneWidget);
    expect(find.text(right), findsOneWidget);
  });

  testWidgets('146 · 37-2: 없는 경로를 넣으면 창을 닫지 않고 칸 아래에 "폴더가 없거나 열 수 없습니다" · 고친 경로로 간다', (tester) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.runAsync(() => tester.pumpWidget(MaterialApp(home: ExplorerPage(c: c))));
    await settle(tester, () => find.text('doc.txt').evaluate().isNotEmpty);
    await tester.tap(find.byTooltip('경로 입력').first);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, p.join(tmp.path, 'nope'));
    await tester.runAsync(() => tester.tap(find.widgetWithText(FilledButton, '확인')));
    await settle(tester, () => find.text('폴더가 없거나 열 수 없습니다').evaluate().isNotEmpty);
    expect(find.text('폴더가 없거나 열 수 없습니다'), findsOneWidget, reason: '칸 아래 (창은 그대로)');
    expect(find.byType(AlertDialog), findsOneWidget);
    // 고치기 시작하면 오류는 지워지고, 있는 폴더면 창을 닫고 간다
    await tester.enterText(find.byType(TextField).last, right);
    await tester.pump();
    expect(find.text('폴더가 없거나 열 수 없습니다'), findsNothing);
    await tester.runAsync(() => tester.tap(find.widgetWithText(FilledButton, '확인')));
    await settle(tester, () => find.byType(AlertDialog).evaluate().isEmpty);
    await settle(tester, () => false, rounds: 10);
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.textContaining(right), findsWidgets);
  });

  testWidgets('37-2: 보던 폴더가 밖에서 지워지면 새로 읽을 때 남아 있는 상위 폴더로 옮기고 알린다', (tester) async {
    final deep = Directory(p.join(left, 'a', 'b'))..createSync(recursive: true);
    c.settings.explorerPaths = [deep.path, right];
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.runAsync(() => tester.pumpWidget(MaterialApp(home: ExplorerPage(c: c))));
    await settle(tester, () => find.textContaining(deep.path).evaluate().isNotEmpty);
    // 밖에서 a 폴더째 지움 → [새로 고침]
    Directory(p.join(left, 'a')).deleteSync(recursive: true);
    await tester.runAsync(() => tester.tap(find.text('새로 고침').first));
    await settle(tester, () => find.textContaining('보던 폴더가 없어져 상위 폴더로 옮겼습니다').evaluate().isNotEmpty);
    expect(find.textContaining('보던 폴더가 없어져 상위 폴더로 옮겼습니다'), findsOneWidget);
    await settle(tester, () => false, rounds: 10);
    // 제목 (지금 경로) 도 남아 있는 가장 가까운 상위 (left) 로
    expect(find.textContaining(p.join(left, 'a')), findsNothing);
    expect(find.text('doc.txt'), findsWidgets);
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
