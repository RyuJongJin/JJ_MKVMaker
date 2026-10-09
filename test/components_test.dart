import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jj_mkvmaker/app/app_controller.dart';
import 'package:jj_mkvmaker/app/components.dart';
import 'package:jj_mkvmaker/app/settings.dart';
import 'package:jj_mkvmaker/platform/windows/desktop_storage_service.dart';
import 'package:jj_mkvmaker/platform/windows/process_media_tool.dart';
import 'package:jj_mkvmaker/services/platform_services.dart';
import 'package:jj_mkvmaker/ui/app_actions.dart';
import 'package:jj_mkvmaker/ui/component_settings.dart';
import 'package:jj_mkvmaker/ui/home_page.dart';

AppController _plain() =>
    AppController(PlatformServices(mediaTool: ProcessMediaTool('x', 'y'), storage: DesktopStorageService()));

void main() {
  test('컴포넌트: 설치한 화면만 순서대로 · 홈 화면은 제거되면 첫 화면 · 설정 저장', () {
    final s = AppSettings();
    expect(s.components, containsAll(['mkv', 'browser', 'explorer', 'rsync', 'downloads', 'viewer']));
    expect(s.components, isNot(contains('docs'))); // 변환기를 받아야 하는 것은 처음엔 꺼짐
    expect([for (final p in AppComponent.pages(s.components, s.navOrder)) p.id],
        ['mkv', 'browser', 'explorer', 'rsync', 'downloads']);
    s
      ..navOrder = ['explorer', 'mkv']
      ..components = ['mkv', 'explorer', 'downloads'];
    expect([for (final p in AppComponent.pages(s.components, s.navOrder)) p.id], ['explorer', 'mkv', 'downloads']);
    s.startScreen = 'browser'; // 제거한 화면 → 설치된 첫 화면
    expect(AppNavButtons.homeId(s), 'explorer');
    final back = AppSettings.fromJson(s.toJson());
    expect(back.components, ['mkv', 'explorer', 'downloads']);
    expect(back.navOrder, ['explorer', 'mkv']);
    // 예전 설정 (컴포넌트 없음) 은 기본
    expect(AppSettings.fromJson({}).components, AppComponent.defaultInstalled);
  });

  testWidgets('위쪽 이동 버튼: 설치한 화면만 · 설정을 바꾸면 바로 · 하나뿐이면 그것만', (tester) async {
    tester.view.physicalSize = const Size(1500, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final c = _plain();
    await tester.pumpWidget(MaterialApp(
      builder: (context, child) => AppScope(controller: c, child: child!),
      home: HomePage(c: c),
    ));
    expect(find.byTooltip('MKV 화면 (지금 여기)'), findsOneWidget);
    expect(find.byTooltip('파일 탐색기'), findsOneWidget);
    expect(find.byTooltip('Rsync'), findsOneWidget);
    await c.updateSettings((s) => s.components = ['mkv', 'explorer']);
    await tester.pump();
    expect(find.byTooltip('Rsync'), findsNothing);
    expect(find.byTooltip('파일 탐색기'), findsOneWidget);
    await c.updateSettings((s) => s.components = ['mkv']);
    await tester.pump();
    expect(find.byTooltip('파일 탐색기'), findsNothing);
    expect(find.byTooltip('MKV 화면 (지금 여기)'), findsOneWidget);
  });

  testWidgets('화면 순서: ▲ ▼ 로 바꾸고 위쪽 버튼 줄도 그 순서', (tester) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final c = _plain();
    await tester.pumpWidget(MaterialApp(
      builder: (context, child) => AppScope(controller: c, child: child!),
      home: Scaffold(body: SingleChildScrollView(child: ListenableBuilder(
          listenable: c, builder: (_, _) => ComponentSettings(c: c)))),
    ));
    // 2번째 (웹 브라우저) 를 위로 → 맨 앞
    await tester.tap(find.byTooltip('위로').at(1));
    await tester.pump();
    expect(c.settings.navOrder.take(2), ['browser', 'mkv']);
    // 맨 앞 (웹 브라우저) 를 아래로 → 다시 2번째
    await tester.tap(find.byTooltip('아래로').first);
    await tester.pump();
    expect(c.settings.navOrder.take(2), ['mkv', 'browser']);
    // 마지막 (다운로드) 를 위로 → 4번째
    await tester.tap(find.byTooltip('위로').last);
    await tester.pump();
    expect(c.settings.navOrder, ['mkv', 'browser', 'explorer', 'downloads', 'rsync']);
  });

  testWidgets('화면 가운데를 좌우로 밀면 순서대로 다음 · 이전 화면 (끝 다음은 처음)', (tester) async {
    tester.view.physicalSize = const Size(1500, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final c = _plain();
    c.settings
      ..components = ['mkv', 'explorer', 'rsync']
      ..navOrder = ['mkv', 'explorer', 'rsync'];
    await tester.pumpWidget(MaterialApp(
      builder: (context, child) => AppScope(controller: c, child: child!),
      home: HomePage(c: c),
    ));
    Future<void> swipe(double dx) async {
      await tester.flingFrom(const Offset(750, 450), Offset(dx, 0), 2000);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
    }

    await swipe(-600); // 왼쪽으로 → 다음 (파일 탐색기)
    expect(find.byTooltip('파일 탐색기 (지금 여기)'), findsOneWidget);
    await swipe(-600);
    expect(find.byTooltip('Rsync (지금 여기)'), findsOneWidget);
    await swipe(-600); // 마지막 다음은 처음
    expect(find.byTooltip('MKV 화면 (지금 여기)'), findsOneWidget);
    await swipe(600); // 오른쪽으로 → 이전 (끝으로)
    expect(find.byTooltip('Rsync (지금 여기)'), findsOneWidget);
    // 102: 끝에서 처음으로 돌기를 끄면 끝에서 멈춘다
    await c.updateSettings((s) => s.swipeWrap = false);
    await tester.pump();
    await swipe(-600);
    expect(find.byTooltip('Rsync (지금 여기)'), findsOneWidget);
    await swipe(600);
    expect(find.byTooltip('파일 탐색기 (지금 여기)'), findsOneWidget);
    await swipe(-600);
    expect(find.byTooltip('Rsync (지금 여기)'), findsOneWidget);
    await c.updateSettings((s) => s.swipeWrap = true);
    // 끄면 밀어도 그대로
    await c.updateSettings((s) => s.swipeNav = false);
    await tester.pump();
    await swipe(600);
    expect(find.byTooltip('Rsync (지금 여기)'), findsOneWidget);
  });
}
