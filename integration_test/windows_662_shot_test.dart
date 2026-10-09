import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:jj_mkvmaker/app/app_controller.dart';
import 'package:jj_mkvmaker/app/bookmarks_controller.dart';
import 'package:jj_mkvmaker/platform/windows/desktop_storage_service.dart';
import 'package:jj_mkvmaker/platform/windows/process_media_tool.dart';
import 'package:jj_mkvmaker/services/platform_services.dart';
import 'package:jj_mkvmaker/ui/app_actions.dart';
import 'package:jj_mkvmaker/ui/browser_page.dart';
import 'package:jj_mkvmaker/ui/home_page.dart';
import 'package:jj_mkvmaker/ui/theme.dart';
import 'package:path/path.dart' as p;

/// 66-2 기기 감독 확인용 (Windows): 지금 화면 아이콘 (넓은 · 좁은 화면) · 처음으로 알림 · 브라우저 안내 한 줄을 PNG (JJ_SHOT_DIR) 로.
/// 설정은 메모리에만 (저장하지 않음), 즐겨찾기는 시험 폴더 (JJ_SHOT_TMP).
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final out = Platform.environment['JJ_SHOT_DIR'] ?? p.join(Directory.systemTemp.path, 'jj_shots_662');
  final key = GlobalKey();

  Future<void> settle(WidgetTester t, [int rounds = 10]) async {
    for (var i = 0; i < rounds; i++) {
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await t.pump();
    }
  }

  Future<void> shot(WidgetTester t, String name) async {
    await settle(t, 3);
    final b = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final img = await t.runAsync(() => b.toImage());
    final bytes = await t.runAsync(() => img!.toByteData(format: ui.ImageByteFormat.png));
    Directory(out).createSync(recursive: true);
    File(p.join(out, '$name.png')).writeAsBytesSync(bytes!.buffer.asUint8List());
  }

  AppController plain() {
    final c = AppController(PlatformServices(mediaTool: ProcessMediaTool('x', 'y'), storage: DesktopStorageService()));
    c.settings
      ..components = ['mkv', 'explorer', 'rsync']
      ..navOrder = ['mkv', 'explorer', 'rsync'];
    return c;
  }

  Future<void> showHome(WidgetTester t, AppController c, Size size) async {
    t.view.physicalSize = size;
    t.view.devicePixelRatio = 1;
    await t.runAsync(() => t.pumpWidget(MaterialApp(
          theme: buildTheme(),
          builder: (_, child) => AppScope(controller: c, child: RepaintBoundary(key: key, child: child!)),
          home: KeyedSubtree(key: UniqueKey(), child: HomePage(c: c)),
        )));
    await settle(t);
  }

  Future<void> swipe(WidgetTester t, Size size, double dx) async {
    await t.flingFrom(Offset(size.width / 2, size.height / 2), Offset(dx, 0), 2500);
    await settle(t, 8);
  }

  testWidgets('66-2: 지금 화면 아이콘 (넓은 · 좁은 화면) · 처음으로 알림', (t) async {
    for (final (name, size) in [('wide', const Size(1280, 800)), ('narrow', const Size(420, 860))]) {
      final c = plain();
      await showHome(t, c, size);
      await shot(t, 'b3_662_${name}_mkv_current');
      await swipe(t, size, -size.width * 0.6); // 다음 (파일 탐색기)
      await shot(t, 'b3_662_${name}_explorer_current');
      await swipe(t, size, -size.width * 0.6); // Rsync
      await swipe(t, size, -size.width * 0.6); // 끝 다음 = 처음
      await shot(t, 'b3_662_${name}_wrap_to_first');
    }
  });

  testWidgets('66-2: 웹 브라우저를 처음 열면 위쪽 막대 아래에 안내 한 줄 · 173 브라우저 아이콘도 지금 위치로 파랗게', (t) async {
    final c = plain();
    // 실제 앱처럼 웹 브라우저도 화면 목록에 (그래야 위쪽 막대에 브라우저 아이콘이 있다)
    c.settings
      ..components = ['mkv', 'browser', 'explorer', 'rsync']
      ..navOrder = ['mkv', 'browser', 'explorer', 'rsync'];
    final base = Platform.environment['JJ_SHOT_TMP'];
    final dir = (base == null || base.isEmpty ? Directory.systemTemp : (Directory(base)..createSync(recursive: true)))
        .createTempSync('jj_shot_662_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final bm = BookmarksController(p.join(dir.path, 'bookmarks.json'));
    t.view.physicalSize = const Size(1280, 800);
    t.view.devicePixelRatio = 1;
    await t.runAsync(() => t.pumpWidget(MaterialApp(
          theme: buildTheme(),
          builder: (_, child) => AppScope(controller: c, bookmarks: bm, child: RepaintBoundary(key: key, child: child!)),
          home: BrowserPage(
            c: c,
            bookmarks: bm,
            initialUrl: 'https://example.com/',
            viewBuilder: (BrowserHost h, String url) => const ColoredBox(color: Colors.white),
          ),
        )));
    await settle(t);
    await shot(t, 'b3_662_browser_hint');
  });
}
