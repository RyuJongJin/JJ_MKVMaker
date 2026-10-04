import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:jj_mkvmaker/app/app_controller.dart';
import 'package:jj_mkvmaker/platform/windows/desktop_storage_service.dart';
import 'package:jj_mkvmaker/platform/windows/process_media_tool.dart';
import 'package:jj_mkvmaker/services/platform_services.dart';
import 'package:jj_mkvmaker/ui/settings_page.dart';
import 'package:jj_mkvmaker/ui/theme.dart';

/// 환경 설정 화면을 실제 글꼴로 그려 PNG 로 저장 (JJ_SHOT_DIR). 화면 배치 확인용.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('환경 설정 화면 그림', (tester) async {
    final out = Platform.environment['JJ_SHOT_DIR'] ?? Directory.systemTemp.path;
    final c = AppController(PlatformServices(mediaTool: ProcessMediaTool('x', 'y'), storage: DesktopStorageService()));
    final key = GlobalKey();
    for (final (name, size) in [('wide', const Size(1400, 2600)), ('narrow', const Size(800, 3400))]) {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      await tester.pumpWidget(MaterialApp(
        theme: buildTheme(),
        home: RepaintBoundary(key: key, child: SettingsPage(c: c)),
      ));
      await tester.pumpAndSettle();
      final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await tester.runAsync(() => boundary.toImage());
      final bytes = await tester.runAsync(() => image!.toByteData(format: ui.ImageByteFormat.png));
      File('$out/settings_$name.png').writeAsBytesSync(bytes!.buffer.asUint8List());
    }
    tester.view.reset();
  });
}
