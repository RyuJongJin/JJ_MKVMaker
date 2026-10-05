import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:jj_mkvmaker/app/app_controller.dart';
import 'package:jj_mkvmaker/app/copy_center.dart';
import 'package:jj_mkvmaker/app/live_sync.dart';
import 'package:jj_mkvmaker/app/settings.dart';
import 'package:jj_mkvmaker/services/platform_services.dart';
import 'package:jj_mkvmaker/ui/monitor_page.dart';
import 'package:jj_mkvmaker/ui/schedule_editor.dart';
import 'package:jj_mkvmaker/ui/theme.dart';
import 'package:path/path.dart' as p;

/// 모니터링 화면 (복사 진행 중 · lsync · 일정 격자) 을 실제 글꼴로 그려 PNG 로 (JJ_SHOT_DIR). 화면 배치 확인용.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('모니터링 화면 그림', (tester) async {
    final out = Platform.environment['JJ_SHOT_DIR'] ?? Directory.systemTemp.path;
    final tmp = Directory.systemTemp.createTempSync('jj_monshot_');
    final src = p.join(tmp.path, '영상 원본'), dst = p.join(tmp.path, '백업');
    for (var i = 0; i < 6; i++) {
      File(p.join(src, i < 3 ? 'A' : 'B', 'clip$i.mkv'))
        ..createSync(recursive: true)
        ..writeAsBytesSync(List.filled(200 * 1024, i));
    }
    Directory(dst).createSync();
    final c = AppController(PlatformServices.create());
    c.settings.liveSyncPairs = [
        LiveSyncPair(src, p.join(dst, 'mirror'), schedule: const ['0 9-17 * * 1-5', '0 22-23 * * 0,6'], delete: true),
      ];
    final live = LiveSync(c)..start();
    final center = CopyCenter.of(c);
    final t = await tester.runAsync(() => center.remember([p.join(src, 'A'), p.join(src, 'B')], dst));
    await center.update(t!.copyWith(bandwidthKBps: 300));
    final key = GlobalKey();
    tester.view.physicalSize = const Size(1500, 900);
    tester.view.devicePixelRatio = 1;
    Future<void> shot(String name) async {
      final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await tester.runAsync(() => boundary.toImage());
      final bytes = await tester.runAsync(() => image!.toByteData(format: ui.ImageByteFormat.png));
      File('$out/$name.png').writeAsBytesSync(bytes!.buffer.asUint8List());
    }

    Future<void> wait(int ms) async {
      for (var i = 0; i < ms ~/ 100; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
        await tester.pump();
      }
    }

    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(),
      builder: (_, child) => RepaintBoundary(key: key, child: child),
      home: MonitorPage(c: c),
    ));
    await tester.runAsync(() => center.start(center.tasks.single));
    await wait(2000);
    await shot('monitor_copy');
    await tester.tap(find.text('lsync (실시간 동기화)'));
    await wait(5000);
    await shot('monitor_lsync');
    // 일정 격자
    final ctx = tester.element(find.byType(MonitorPage));
    final f = editSchedule(ctx, const ['0 9-17 * * 1-5', '0 22-23 * * 0,6']);
    await wait(800);
    await shot('monitor_schedule');
    Navigator.of(ctx).pop();
    await f;
    center.cancel(center.tasks.single.id);
    await wait(500);
    live.dispose();
    tester.view.reset();
    tmp.deleteSync(recursive: true);
  });
}
