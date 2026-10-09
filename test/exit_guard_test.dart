import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jj_mkvmaker/app/app_controller.dart';
import 'package:jj_mkvmaker/platform/windows/desktop_storage_service.dart';
import 'package:jj_mkvmaker/platform/windows/process_media_tool.dart';
import 'package:jj_mkvmaker/services/platform_services.dart';
import 'package:jj_mkvmaker/ui/exit_guard.dart';

void main() {
  setUp(() => ExitGuard.forceAndroid = true);
  tearDown(() => ExitGuard.forceAndroid = false);

  Future<AppController> pump(WidgetTester tester, {required bool background, required bool busy}) async {
    final c = AppController(PlatformServices(mediaTool: ProcessMediaTool('x', 'y'), storage: DesktopStorageService()));
    c.settings.runInBackground = background;
    c.busy = busy;
    c.currentJob = busy ? 'MKV 만들기 3/10' : null;
    final nav = GlobalKey<NavigatorState>();
    await tester.pumpWidget(MaterialApp(
      navigatorKey: nav,
      home: ExitGuard(c: c, child: const Scaffold(body: Text('home'))),
    ));
    return c;
  }

  testWidgets('백그라운드로 실행이 꺼져 있고 작업 중이면 ← 에 묻는다 (취소하면 그대로)', (tester) async {
    await pump(tester, background: false, busy: true);
    final nav = tester.state<NavigatorState>(find.byType(Navigator));
    await nav.maybePop();
    await tester.pumpAndSettle();
    expect(find.text('작업이 진행 중입니다'), findsOneWidget);
    expect(find.text('• MKV 만들기 3/10'), findsOneWidget);
    expect(find.text('뒤로 보내고 계속'), findsOneWidget);
    await tester.tap(find.text('취소'));
    await tester.pumpAndSettle();
    expect(find.text('home'), findsOneWidget);
  });

  testWidgets('작업이 없거나 백그라운드로 실행이 켜져 있으면 묻지 않는다', (tester) async {
    for (final (bg, busy) in [(false, false), (true, true)]) {
      await pump(tester, background: bg, busy: busy);
      final nav = tester.state<NavigatorState>(find.byType(Navigator));
      await nav.maybePop();
      await tester.pumpAndSettle();
      expect(find.text('작업이 진행 중입니다'), findsNothing);
    }
  });
}
