import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:jj_mkvmaker/app/app_controller.dart';
import 'package:jj_mkvmaker/services/platform_services.dart';
import 'package:jj_mkvmaker/ui/explorer_page.dart';
import 'package:jj_mkvmaker/ui/theme.dart';

/// 파일 탐색기 화면을 실제 글꼴 · 실제 FFmpeg (썸네일 · 동영상 정보) 로 그려 PNG 로 저장 (JJ_SHOT_DIR).
/// 왼쪽 · 오른쪽 창 폴더: JJ_SHOT_LEFT · JJ_SHOT_RIGHT. 화면 배치 확인용.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('파일 탐색기 화면 그림', (tester) async {
    final env = Platform.environment;
    final out = env['JJ_SHOT_DIR'] ?? Directory.systemTemp.path;
    final c = AppController(PlatformServices.create());
    c.settings.explorerPaths = [env['JJ_SHOT_LEFT'] ?? Directory.current.path, env['JJ_SHOT_RIGHT'] ?? Directory.current.path];
    final key = GlobalKey();
    for (final (name, size, orient) in [
      ('wide', const Size(1600, 900), 'auto'),
      ('tall', const Size(900, 1400), 'auto'),
    ]) {
      c.settings.explorerOrientation = orient;
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      await tester.runAsync(() => tester.pumpWidget(MaterialApp(
            theme: buildTheme(),
            home: RepaintBoundary(key: key, child: ExplorerPage(c: c)),
          )));
      // 목록 · 썸네일 · 동영상 정보가 나올 때까지
      for (var i = 0; i < 40; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 250)));
        await tester.pump();
      }
      final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await tester.runAsync(() => boundary.toImage());
      final bytes = await tester.runAsync(() => image!.toByteData(format: ui.ImageByteFormat.png));
      File('$out/explorer_$name.png').writeAsBytesSync(bytes!.buffer.asUint8List());
      await tester.pumpWidget(const SizedBox());
    }
    tester.view.reset();
  });
}
