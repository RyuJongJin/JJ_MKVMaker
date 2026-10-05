import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:jj_mkvmaker/app/app_controller.dart';
import 'package:jj_mkvmaker/app/live_sync.dart';
import 'package:jj_mkvmaker/app/settings.dart';
import 'package:jj_mkvmaker/platform/windows/desktop_storage_service.dart';
import 'package:jj_mkvmaker/platform/windows/process_media_tool.dart';
import 'package:jj_mkvmaker/services/platform_services.dart';
import 'package:jj_mkvmaker/ui/copy_sync_settings.dart';
import 'package:jj_mkvmaker/ui/theme.dart';

/// 환경 설정 > 파일 탐색기 의 복사 · 동기화 부분을 실제 글꼴로 그려 PNG 로 (JJ_SHOT_DIR). 화면 배치 확인용.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('복사 · 동기화 설정 그림', (tester) async {
    final out = Platform.environment['JJ_SHOT_DIR'] ?? Directory.systemTemp.path;
    final c = AppController(PlatformServices(mediaTool: ProcessMediaTool('x', 'y'), storage: DesktopStorageService()));
    c.settings
      ..copyMethodFolder = 'rsync'
      ..copyBandwidthKBps = 5000
      ..liveSyncPairs = [
        LiveSyncPair(r'D:\영상\원본', r'\\nas\backup\영상', method: 'rsync', delete: true),
        LiveSyncPair(r'C:\Users\me\Documents', r'E:\Documents', enabled: false),
      ];
    final live = LiveSync(c);
    final key = GlobalKey();
    tester.view.physicalSize = const Size(1400, 1300);
    tester.view.devicePixelRatio = 1;
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(),
      home: RepaintBoundary(
        key: key,
        child: Scaffold(body: SingleChildScrollView(child: CopySyncSettings(c: c))),
      ),
    ));
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump();
    }
    final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await tester.runAsync(() => boundary.toImage());
    final bytes = await tester.runAsync(() => image!.toByteData(format: ui.ImageByteFormat.png));
    File('$out/copy_sync.png').writeAsBytesSync(bytes!.buffer.asUint8List());
    live.dispose();
    tester.view.reset();
  });
}
