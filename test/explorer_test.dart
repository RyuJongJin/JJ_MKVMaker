import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jj_mkvmaker/app/app_controller.dart';
import 'package:jj_mkvmaker/app/settings.dart';
import 'package:jj_mkvmaker/platform/windows/desktop_storage_service.dart';
import 'package:jj_mkvmaker/platform/windows/process_media_tool.dart';
import 'package:jj_mkvmaker/services/app_shell.dart';
import 'package:jj_mkvmaker/services/platform_services.dart';
import 'package:jj_mkvmaker/ui/explorer_page.dart';
import 'package:jj_mkvmaker/ui/path_label.dart';
import 'package:path/path.dart' as p;

/// 다른 앱으로 열기를 기록만 하는 셸 (실제로 프로그램을 띄우지 않게)
class _Shell extends NoopShell {
  final opened = <(String, bool)>[];
  @override
  Future<bool> openWith(String path, {bool choose = false}) async {
    opened.add((path, choose));
    return true;
  }
}

void main() {
  late Directory tmp;
  late String left, right;
  late _Shell shell;
  late AppController c;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('jj_explorer_');
    left = p.join(tmp.path, 'left');
    right = p.join(tmp.path, 'right');
    File(p.join(left, 'doc.txt'))
      ..createSync(recursive: true)
      ..writeAsStringSync('hello');
    File(p.join(left, 'sub', 'inner.txt'))
      ..createSync(recursive: true)
      ..writeAsStringSync('inner');
    Directory(right).createSync();
    shell = _Shell();
    c = AppController(PlatformServices(
        mediaTool: ProcessMediaTool('x', 'y'), storage: DesktopStorageService(), shell: shell));
    c.settings.explorerPaths = [left, right];
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  Future<void> open(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.runAsync(() => tester.pumpWidget(MaterialApp(home: ExplorerPage(c: c))));
    await settle(tester, () => find.text('doc.txt').evaluate().isNotEmpty);
  }

  testWidgets('두 창: 폴더 한 번 = 펼치기 · 파일 한 번 = 선택 · 두 번 = 실행 · 길게 = 메뉴 · 다른 창으로 복사', (tester) async {
    await open(tester);
    // 두 창 + 가운데 버튼 줄, 선택 동그라미는 평소에 안 보임
    expect(find.text('상위 폴더'), findsOneWidget);
    expect(find.text('doc.txt'), findsOneWidget);
    expect(find.byTooltip('표시 (여러 개 고르기)'), findsNothing);
    // 모니터링 · rsync 는 Rsync 화면에만
    expect(find.text('모니터링'), findsNothing);
    expect(find.text('좌 → 우'), findsNothing);

    // 폴더를 한 번 누르면 바로 펼치고, 다시 누르면 접는다
    await act(tester, () => tester.tap(find.text('sub')));
    await settle(tester, () => find.text('inner.txt').evaluate().isNotEmpty);
    expect(find.text('inner.txt'), findsOneWidget);
    await act(tester, () => tester.tap(find.text('sub')));
    await settle(tester, () => find.text('inner.txt').evaluate().isEmpty);
    expect(find.text('inner.txt'), findsNothing);
    // › 화살표로도 펼친다
    await act(tester, () => tester.tap(chevronOf('sub')));
    await settle(tester, () => find.text('inner.txt').evaluate().isNotEmpty);
    expect(find.text('inner.txt'), findsOneWidget);

    // 파일을 한 번 누르면 고르기만 (실행 안 함)
    await act(tester, () => tester.tap(find.text('doc.txt')));
    await settle(tester, () => false, rounds: 15);
    expect(shell.opened, isEmpty);
    // 두 번 누르면 기본 앱으로 실행
    await doubleTap(tester, find.text('doc.txt'));
    await settle(tester, () => shell.opened.isNotEmpty);
    expect(shell.opened.last, (p.join(left, 'doc.txt'), false));

    // 길게 누르기 → 메뉴 → 다른 앱으로 열기 (고르기 창)
    await tester.longPress(find.text('doc.txt'));
    await tester.pumpAndSettle();
    expect(find.text('다른 창으로 복사'), findsOneWidget);
    expect(find.text('삭제'), findsWidgets);
    await act(tester, () => tester.tap(find.text('다른 앱으로 열기')));
    await settle(tester, () => shell.opened.length == 2);
    expect(shell.opened.last, (p.join(left, 'doc.txt'), true));

    // doc.txt 를 고른 채 [복사] → 확인 → 오른쪽 창 폴더에 생긴다
    await act(tester, () => tester.tap(find.text('doc.txt')));
    await settle(tester, () => false, rounds: 15);
    await act(tester, () => tester.tap(find.text('복사').first));
    await tester.pumpAndSettle();
    await act(tester, () => tester.tap(find.widgetWithText(FilledButton, '복사')));
    await settle(tester, () => File(p.join(right, 'doc.txt')).existsSync() && find.byType(LinearProgressIndicator).evaluate().isEmpty);
    expect(File(p.join(right, 'doc.txt')).readAsStringSync(), 'hello');
    expect(File(p.join(left, 'doc.txt')).existsSync(), isTrue);
  });

  testWidgets('바로 실행 모드: 폴더를 누르면 펼치고, 파일을 누르면 바로 실행', (tester) async {
    c.settings.explorerClick = 'open';
    await open(tester);
    await act(tester, () => tester.tap(find.text('sub')));
    await settle(tester, () => find.text('inner.txt').evaluate().isNotEmpty);
    expect(find.text('inner.txt'), findsOneWidget);
    await act(tester, () => tester.tap(find.text('doc.txt')));
    await settle(tester, () => shell.opened.isNotEmpty);
    expect(shell.opened.single, (p.join(left, 'doc.txt'), false));
  });

  testWidgets('폴더 + 파일 목록 배치 · Windows 탐색기 / Total Commander 스타일', (tester) async {
    c.settings
      ..explorerLayout = 'split'
      ..explorerStyle = 'windows';
    await open(tester);
    // 왼쪽 트리는 폴더만, 오른쪽 목록은 고른 폴더 (left) 의 내용
    expect(find.text('sub'), findsNWidgets(2)); // 트리 + 목록
    expect(find.text('doc.txt'), findsOneWidget); // 목록에만
    expect(find.text('수정한 날짜'), findsOneWidget); // Windows 탐색기 열 머리
    expect(find.text('TXT 파일'), findsOneWidget);
    expect(find.text('상위 폴더'), findsOneWidget); // 버튼 줄은 두 창 사이

    // 왼쪽 트리에서 sub 를 고르면 오른쪽 목록이 그 폴더로
    await act(tester, () => tester.tap(find.text('sub').first));
    await settle(tester, () => find.text('inner.txt').evaluate().isNotEmpty);
    expect(find.text('inner.txt'), findsOneWidget);
    expect(find.text('doc.txt'), findsNothing);
    // 목록의 ".." 을 누르면 상위 폴더로
    await act(tester, () => tester.tap(find.text('..')));
    await settle(tester, () => find.text('doc.txt').evaluate().isNotEmpty);
    expect(find.text('doc.txt'), findsOneWidget);
    // 목록의 폴더를 두 번 누르면 들어간다
    await doubleTap(tester, find.text('sub').last);
    await settle(tester, () => find.text('inner.txt').evaluate().isNotEmpty);
    expect(find.text('inner.txt'), findsOneWidget);

    // 이 배치에도 복사 · 이동: 길게 눌러 [복사] 로 담고 → 다른 폴더를 골라 [붙여넣기]
    await tester.longPress(find.text('inner.txt'));
    await tester.pumpAndSettle();
    expect(find.text('다른 창으로 복사'), findsNothing);
    await tester.tap(find.text('복사').last);
    await tester.pumpAndSettle();
    await act(tester, () => tester.tap(find.text('..')));
    await settle(tester, () => find.text('doc.txt').evaluate().isNotEmpty);
    await act(tester, () => tester.tap(find.text('붙여넣기')));
    await tester.pumpAndSettle();
    await act(tester, () => tester.tap(find.widgetWithText(FilledButton, '복사')));
    await settle(tester, () => File(p.join(left, 'inner.txt')).existsSync() && find.byType(LinearProgressIndicator).evaluate().isEmpty);
    expect(File(p.join(left, 'inner.txt')).readAsStringSync(), 'inner');
    expect(File(p.join(left, 'sub', 'inner.txt')).existsSync(), isTrue); // 복사이므로 원본은 그대로
    await settle(tester, () => find.text('inner.txt').evaluate().isNotEmpty);
    expect(find.text('inner.txt'), findsOneWidget); // 목록에 바로 보임

    // Total Commander: [폴더] · <DIR> · 확장자 칸
    await c.updateSettings((s) => s.explorerStyle = 'totalcmd');
    await settle(tester, () => find.text('[sub]').evaluate().length == 2);
    expect(find.text('[sub]'), findsNWidgets(2));
    expect(find.text('<DIR>'), findsOneWidget);
    expect(find.text('doc'), findsOneWidget); // 확장자를 뺀 이름
    expect(find.text('txt'), findsNWidgets(2)); // 확장자 칸 (doc.txt · 붙여넣은 inner.txt)
    expect(find.text('확장자'), findsOneWidget);
  });

  testWidgets('선택 모드: 파일 누르기 = 선택 · 취소, 폴더 누르기 = 자기 자신과 안의 것 모두 선택 · 다시 누르면 모두 취소', (tester) async {
    File(p.join(left, 'sub', 'second.txt')).writeAsStringSync('2');
    await open(tester);
    await act(tester, () => tester.tap(find.text('선택').first)); // 가운데 [선택] 버튼
    expect(find.byTooltip('표시 (여러 개 고르기)'), findsWidgets); // 동그라미가 보인다
    // 파일: 누르면 선택, 다시 누르면 취소 (실행하지 않음)
    await act(tester, () => tester.tap(find.text('doc.txt')));
    expect(find.text('1개 표시함'), findsOneWidget);
    await act(tester, () => tester.tap(find.text('doc.txt')));
    expect(find.text('0개 표시함'), findsNWidgets(2)); // 두 창 모두 (각 창의 선택 수)
    expect(shell.opened, isEmpty);

    IconData markIcon(String name) => (tester
            .widget<IconButton>(find.descendant(
                of: find.ancestor(of: find.text(name), matching: find.byType(Material)).first,
                matching: find.byType(IconButton)))
            .icon as Icon)
        .icon!;

    // 폴더: 누르면 자기 자신과 안의 것 모두 선택 (펼쳐서 ✔ 로 보여 줌)
    await act(tester, () => tester.tap(find.text('sub')));
    await settle(tester, () => find.text('inner.txt').evaluate().isNotEmpty);
    expect(find.text('1개 표시함'), findsOneWidget); // 폴더 하나로 안의 것까지
    expect([markIcon('sub'), markIcon('inner.txt'), markIcon('second.txt')], everyElement(Icons.check_circle));
    // 안의 것 하나를 누르면 그것만 빠지고 나머지는 고른 채로
    await act(tester, () => tester.tap(find.text('inner.txt')));
    await settle(tester, () => false, rounds: 5);
    expect(markIcon('inner.txt'), Icons.check_circle_outline);
    expect(markIcon('second.txt'), Icons.check_circle);
    expect(markIcon('sub'), Icons.check_circle_outline);
    // 폴더를 다시 누르면 다시 전체 선택, 한 번 더 누르면 자기 자신과 안의 것 모두 취소
    await act(tester, () => tester.tap(find.text('sub')));
    await settle(tester, () => false, rounds: 5);
    expect(find.text('1개 표시함'), findsOneWidget);
    expect([markIcon('sub'), markIcon('inner.txt'), markIcon('second.txt')], everyElement(Icons.check_circle));
    await act(tester, () => tester.tap(find.text('sub')));
    await settle(tester, () => false, rounds: 5);
    expect(find.text('0개 표시함'), findsNWidgets(2));
    expect([markIcon('sub'), markIcon('inner.txt'), markIcon('second.txt')], everyElement(Icons.check_circle_outline));
    // [선택 끝] → 동그라미가 사라진다
    await act(tester, () => tester.tap(find.text('선택 끝').first)); // 두 창 모두에 있음
    expect(find.byTooltip('표시 (여러 개 고르기)'), findsNothing);
  });

  testWidgets('65: 여러 개를 지울 때 하나가 실패해도 나머지는 지우고, 못 지운 것을 알린다', (tester) async {
    final locked = File(p.join(left, 'locked.txt'))..writeAsStringSync('l');
    final h = locked.openSync(mode: FileMode.append); // Windows: 열려 있는 파일은 지울 수 없다
    addTearDown(h.closeSync);
    await open(tester);
    await act(tester, () => tester.tap(find.text('선택').first));
    await act(tester, () => tester.tap(markOf('doc.txt')));
    await act(tester, () => tester.tap(markOf('locked.txt')));
    await act(tester, () => tester.tap(markOf('sub')));
    await settle(tester, () => find.text('3개 표시함').evaluate().isNotEmpty);
    await act(tester, () => tester.tap(find.text('삭제').first));
    await tester.pumpAndSettle();
    await tester.tap(find.text('휴지통을 거치지 않고 영구 삭제 (Shift+Delete)'));
    await tester.pumpAndSettle();
    await act(tester, () => tester.tap(find.widgetWithText(FilledButton, '영구 삭제')));
    await settle(tester, () => find.textContaining('지우지 못했습니다').evaluate().isNotEmpty);
    expect(find.text('3개 중 1개를 지우지 못했습니다'), findsOneWidget);
    expect(find.text('locked.txt'), findsWidgets);
    expect(File(p.join(left, 'doc.txt')).existsSync(), isFalse);
    expect(Directory(p.join(left, 'sub')).existsSync(), isFalse);
    expect(locked.existsSync(), isTrue);
    await tester.tap(find.widgetWithText(FilledButton, '확인'));
    await tester.pumpAndSettle();
  }, skip: !Platform.isWindows);

  testWidgets('여러 개 표시 → 삭제 · 새 폴더 · 이름 변경', (tester) async {
    await open(tester);
    await act(tester, () => tester.tap(find.text('선택').first));
    // 동그라미로 doc.txt · sub 표시 (반드시 이름으로 찾은 줄의 버튼만: 목록에는 시험 폴더 위쪽의 실제 폴더도 보인다)
    await act(tester, () => tester.tap(markOf('sub')));
    await settle(tester, () => find.text('inner.txt').evaluate().isNotEmpty); // 폴더를 고르면 펼쳐서 안의 것도 ✔
    await act(tester, () => tester.tap(markOf('doc.txt')));
    await settle(tester, () => find.text('2개 표시함').evaluate().isNotEmpty);
    expect(find.text('2개 표시함'), findsOneWidget);
    await act(tester, () => tester.tap(find.text('삭제').first));
    await tester.pumpAndSettle();
    // 지울 항목 이름이 확인 창에 보인다. 65: Windows 는 기본이 휴지통 (시험에서는 영구 삭제를 골라 휴지통을 어지럽히지 않음)
    expect(find.textContaining('2개 항목을 휴지통으로 보낼까요?'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, '휴지통으로'), findsOneWidget);
    expect(find.textContaining('· sub'), findsOneWidget);
    expect(find.textContaining('· doc.txt'), findsOneWidget);
    await tester.tap(find.text('휴지통을 거치지 않고 영구 삭제 (Shift+Delete)'));
    await tester.pumpAndSettle();
    expect(find.textContaining('2개 항목을 지울까요? 되돌릴 수 없습니다.'), findsOneWidget);
    await act(tester, () => tester.tap(find.widgetWithText(FilledButton, '영구 삭제')));
    await settle(tester, () => find.text('doc.txt').evaluate().isEmpty);
    expect(Directory(left).listSync(), isEmpty);

    // 새 폴더 → 이름 변경
    await act(tester, () => tester.tap(find.text('새 폴더').first));
    await tester.pumpAndSettle();
    await act(tester, () => tester.enterText(find.byType(TextField), 'films'));
    await act(tester, () => tester.tap(find.widgetWithText(FilledButton, '확인')));
    await settle(tester, () => find.text('films').evaluate().isNotEmpty);
    expect(Directory(p.join(left, 'films')).existsSync(), isTrue);
    await act(tester, () => tester.tap(find.text('이름 변경').first));
    await tester.pumpAndSettle();
    await act(tester, () => tester.enterText(find.byType(TextField), 'movies'));
    await act(tester, () => tester.tap(find.widgetWithText(FilledButton, '확인')));
    await settle(tester, () => find.text('movies').evaluate().isNotEmpty);
    expect(Directory(p.join(left, 'movies')).existsSync(), isTrue);
  });

  testWidgets('창 배치: 한 창 · 버튼 줄 숨김, 버튼 구성: 버튼 빼기 → 설정에 저장', (tester) async {
    await open(tester);
    await tester.tap(find.byTooltip('창 배치 · 버튼 구성'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('창 배치').last);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ChoiceChip, '한 창'));
    await tester.pump();
    await tester.tap(find.widgetWithText(ChoiceChip, '숨김'));
    await tester.pump();
    await act(tester, () => tester.tap(find.widgetWithText(FilledButton, '확인')));
    await tester.pumpAndSettle();
    expect([c.settings.explorerLayout, c.settings.explorerToolbar], ['single', 'hidden']);
    expect(find.text('상위 폴더'), findsNothing); // 버튼 줄 숨김
    expect(find.text('doc.txt'), findsOneWidget); // 한 창 (왼쪽만)

    // ⋮ 메뉴에서 버튼 구성: "찾기" 빼기
    await c.updateSettings((s) => s.explorerToolbar = 'middle');
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('창 배치 · 버튼 구성'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('버튼 구성').last);
    await tester.pumpAndSettle();
    // 처음 값 순서 (자주 쓰는 것부터) 에서 뒤쪽이라 목록을 내려 보이게 한 뒤
    await tester.scrollUntilVisible(find.widgetWithText(CheckboxListTile, 'MKV 목록에 추가'), 80,
        scrollable: find.descendant(of: find.byType(AlertDialog), matching: find.byType(Scrollable)).first);
    await tester.tap(find.widgetWithText(CheckboxListTile, 'MKV 목록에 추가'));
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, '확인'));
    await tester.pumpAndSettle();
    expect(c.settings.explorerButtons, isNot(contains('addMkv')));
    expect(c.settings.explorerButtons, contains('copy'));
    expect(find.text('MKV 목록에 추가'), findsNothing);

    // 설정 저장 · 읽기
    final back = AppSettings.fromJson(c.settings.toJson());
    expect([back.explorerLayout, back.explorerToolbar, back.explorerButtons],
        [c.settings.explorerLayout, c.settings.explorerToolbar, c.settings.explorerButtons]);
  });

  testWidgets('Rsync 화면: 늘 좌우 두 창 · 폴더만 · 창마다 하나만 고르기 · → ← ⇄ · 모니터링', (tester) async {
    Directory(p.join(left, 'sub2')).createSync();
    Directory(p.join(right, 'rsub')).createSync();
    File(p.join(right, 'r.txt')).writeAsStringSync('r');
    File(p.join(right, 'rsub', 'back.txt')).writeAsStringSync('b'); // ⇄ 비교에서 ← 로 건너갈 것
    c.settings
      ..explorerLayout = 'single' // 파일 탐색기 배치와 상관없이 두 창
      ..rsyncPaths = [left, right];
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.runAsync(() => tester.pumpWidget(MaterialApp(home: ExplorerPage(c: c, rsync: true))));
    await settle(tester, () => find.text('sub').evaluate().isNotEmpty && find.text('rsub').evaluate().isNotEmpty);
    expect(find.text('Rsync'), findsWidgets);
    // 폴더만 (파일은 안 보임) · 버튼은 → ← ⇄ 모니터링 (파일 기능 · 선택 없음)
    expect(find.text('doc.txt'), findsNothing);
    expect(find.text('r.txt'), findsNothing);
    for (final t in ['좌 → 우', '좌 ← 우', '좌 ⇄ 우', '모니터링']) {
      expect(find.text(t), findsOneWidget);
    }
    expect(find.text('선택'), findsNothing);
    expect(find.text('삭제'), findsNothing);

    // 고르지 않고 → : 알림
    await act(tester, () => tester.tap(find.text('좌 → 우')));
    expect(find.text('왼쪽 · 오른쪽 창에서 폴더를 하나씩 고르세요.'), findsOneWidget);

    // 창마다 하나만: sub → sub2 로 바꾸면 sub 는 풀림, 다시 누르면 취소
    await act(tester, () => tester.tap(find.text('sub')));
    await act(tester, () => tester.tap(find.text('sub2')));
    await settle(tester, () => false, rounds: 5);
    expect(find.byTooltip('고르기 취소'), findsOneWidget);
    await act(tester, () => tester.tap(find.text('sub2')));
    await settle(tester, () => false, rounds: 5);
    expect(find.byTooltip('고르기 취소'), findsNothing);
    await act(tester, () => tester.tap(find.text('sub')));
    await act(tester, () => tester.tap(find.text('rsub')));
    await settle(tester, () => false, rounds: 5);
    expect(find.byTooltip('고르기 취소'), findsNWidgets(2)); // 왼쪽 하나 · 오른쪽 하나

    // ⇄ : 두 방향을 보여 주고 -u, 취소하면 모니터링에 남지 않는다
    await act(tester, () => tester.tap(find.text('좌 ⇄ 우')));
    await settle(tester, () => find.textContaining('비교하는 중').evaluate().isEmpty, rounds: 400);
    // 72: 실행 전에 무엇이 바뀌는지 (⇄: 양쪽에만 있는 파일이 서로 건너감)
    expect(find.textContaining('→ 새로'), findsOneWidget);
    expect(find.textContaining('← 새로'), findsOneWidget);
    expect(find.text('rsync 양쪽 (⇄)'), findsOneWidget);
    // 109: 짧은 경로 (끝 폴더) + 전체 경로는 작게
    final ls = p.join(left, 'sub'), rs = p.join(right, 'rsub');
    expect(find.text('→  ${shortPath(rs)}'), findsOneWidget);
    expect(find.text('→  ${shortPath(ls)}'), findsOneWidget);
    expect(find.text('$ls/  →  $rs/'), findsOneWidget);
    expect(find.text('$rs/  →  $ls/'), findsOneWidget);
    expect(find.textContaining('-avPog -u'), findsNWidgets(2));
    await tester.tap(find.text('취소'));
    await tester.pumpAndSettle();
    expect(c.settings.copyTasks, isEmpty);
    expect(find.text('원본 파일 지우기 (--remove-source-files)'), findsNothing); // 양쪽에는 없음
    // → 는 한 방향 · -u 없이 · 원본 파일 지우기를 고를 수 있다 (고르면 원본 폴더 남김 / 지움)
    await act(tester, () => tester.tap(find.text('좌 → 우')));
    await settle(tester, () => find.textContaining('비교하는 중').evaluate().isEmpty, rounds: 400);
    expect(find.text('$ls/  →  $rs/'), findsOneWidget);
    expect(find.text('$rs/  →  $ls/'), findsNothing);
    expect(find.textContaining('-u'), findsNothing);
    expect(find.text('빈 폴더 지움 · 원본 폴더는 남김'), findsNothing);
    await tester.tap(find.text('원본 파일 지우기 (--remove-source-files)'));
    await tester.pumpAndSettle();
    expect(find.textContaining('-avPog --remove-source-files'), findsOneWidget);
    expect(find.text('빈 폴더 지움 · 원본 폴더는 남김'), findsOneWidget);
    expect(find.text('빈 폴더 지움 · 원본 폴더도 지움'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, '이동'), findsOneWidget);
    await tester.tap(find.text('취소'));
    await tester.pumpAndSettle();
    // 고른 폴더는 기억 (다음에 열 때 그 폴더부터)
    expect(c.settings.rsyncPaths, [p.join(left, 'sub'), p.join(right, 'rsub')]);

    // 새 폴더: 만든 폴더가 바로 그 창의 원본 · 대상으로 골라진다 (오른쪽 창 rsub 안에)
    await act(tester, () => tester.tap(find.text('rsub')));
    await settle(tester, () => false, rounds: 5); // rsub 를 다시 눌러 취소
    await act(tester, () => tester.tap(find.text('rsub')));
    await settle(tester, () => false, rounds: 5); // 다시 골라 지금 폴더로
    await act(tester, () => tester.tap(find.text('새 폴더')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '새로만든');
    await act(tester, () => tester.tap(find.widgetWithText(FilledButton, '확인')));
    await settle(tester, () => find.text('새로만든').evaluate().isNotEmpty);
    expect(Directory(p.join(right, 'rsub', '새로만든')).existsSync(), isTrue);
    final newRow = find.ancestor(of: find.text('새로만든'), matching: find.byType(Material)).first;
    expect(find.descendant(of: newRow, matching: find.byTooltip('고르기 취소')), findsOneWidget);
    expect(find.descendant(of: find.ancestor(of: find.text('rsub'), matching: find.byType(Material)).first,
        matching: find.byTooltip('고르기 취소')), findsNothing); // 창마다 하나만
  });
}

/// [name] 줄의 "표시" 동그라미 버튼
Finder markOf(String name) => find.descendant(
      of: find.ancestor(of: find.text(name), matching: find.byType(Material)).first,
      matching: find.byTooltip('표시 (여러 개 고르기)'),
    );

/// 누르기 등을 실제 비동기 구역에서 (그 때 시작한 파일 작업이 테스트의 가짜 시간에 묶이지 않게)
Future<void> act(WidgetTester tester, Future<void> Function() f) async {
  await tester.runAsync(f);
  await tester.pump();
}

/// [name] 트리 줄의 › (펼치기) 화살표
Finder chevronOf(String name) => find.descendant(
      of: find.ancestor(of: find.text(name), matching: find.byType(InkWell)).first,
      matching: find.byIcon(Icons.chevron_right),
    );

/// 두 번 누르기 (실제 비동기 구역에서: 그때 시작한 파일 작업이 테스트의 가짜 시간에 묶이지 않게)
Future<void> doubleTap(WidgetTester tester, Finder f) async {
  await tester.runAsync(() async {
    await tester.tap(f);
    await Future<void>.delayed(const Duration(milliseconds: 80));
    await tester.tap(f);
  });
  await tester.pump();
}

/// 실제 파일 작업 (비동기 IO) 이 끝나기를 기다리며 화면을 갱신
// 끝나면 바로 나온다 - 넉넉한 횟수는 전체 시험 중 PC 가 바쁠 때 (실제 파일 입출력이 느려짐) 흔들리지 않게
Future<void> settle(WidgetTester tester, bool Function() done, {int rounds = 300}) async {
  for (var i = 0; i < rounds; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
    await tester.pump();
    if (done()) break;
  }
  await tester.pump(const Duration(milliseconds: 300));
}
