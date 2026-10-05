import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:jj_mkvmaker/app/app_controller.dart';
import 'package:jj_mkvmaker/app/live_sync.dart';
import 'package:jj_mkvmaker/services/platform_services.dart';
import 'package:jj_mkvmaker/ui/explorer_page.dart';
import 'package:jj_mkvmaker/ui/theme.dart';
import 'package:path/path.dart' as p;

/// Rsync 화면을 실제 rsync (앱에 들어 있는 것) 로: → 한 방향, ⇄ 양쪽 (-u), 모니터링에 남는지. 화면은 JJ_SHOT_DIR 에 PNG.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Rsync 화면: → · ⇄ 실제 실행', (tester) async {
    final out = Platform.environment['JJ_SHOT_DIR'] ?? Directory.systemTemp.path;
    final tmp = Directory.systemTemp.createTempSync('jj_rsyncpage_');
    final a = p.join(tmp.path, '왼쪽 폴더'), b = p.join(tmp.path, 'right');
    File(p.join(a, 'sub', '한글 파일.txt'))
      ..createSync(recursive: true)
      ..writeAsStringSync('left');
    File(p.join(a, 'same.txt')).writeAsStringSync('old');
    Directory(b).createSync();
    await tester.runAsync(findBundledRsync);
    expect(bundledRsync, isNotNull, reason: 'build 출력의 rsync\rsync.exe (tool\fetch_rsync.ps1)');

    final c = AppController(PlatformServices.create());
    c.settings
      ..rsyncPaths = [tmp.path, tmp.path]
      ..explorerStyle = 'windows';
    final key = GlobalKey();
    tester.view.physicalSize = const Size(1500, 900);
    tester.view.devicePixelRatio = 1;
    Future<void> wait(int ms) async {
      for (var i = 0; i < ms ~/ 100; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
        await tester.pump();
      }
    }

    Future<void> shot(String name) async {
      final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await tester.runAsync(() => boundary.toImage());
      final bytes = await tester.runAsync(() => image!.toByteData(format: ui.ImageByteFormat.png));
      File('$out/$name.png').writeAsBytesSync(bytes!.buffer.asUint8List());
    }

    Future<void> tap(Finder f) async {
      await tester.tap(f);
      await wait(600);
    }

    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(),
      builder: (_, child) => RepaintBoundary(key: key, child: child),
      home: ExplorerPage(c: c, rsync: true),
    ));
    await wait(2500);
    // 왼쪽 창: 왼쪽 폴더 · 오른쪽 창: right
    await tap(find.text('왼쪽 폴더').first);
    await tap(find.text('right').last);
    await wait(800);
    expect(find.byTooltip('고르기 취소'), findsNWidgets(2));

    // → : 왼쪽 폴더 안의 것 → right
    await tap(find.text('좌 → 우'));
    await tap(find.text('실행'));
    for (var i = 0; i < 100 && !File(p.join(b, 'sub', '한글 파일.txt')).existsSync(); i++) {
      await wait(200);
    }
    await wait(1500);
    expect(File(p.join(b, 'sub', '한글 파일.txt')).readAsStringSync(), 'left');
    expect(Directory(p.join(b, '왼쪽 폴더')).existsSync(), isFalse); // 안의 것만 (폴더째가 아님)

    // ⇄ : 오른쪽에서 새 파일 · 더 새로 고친 same.txt 는 왼쪽으로, 오른쪽의 새 것은 덮어쓰지 않음 (-u)
    File(p.join(b, 'only-right.txt')).writeAsStringSync('r');
    await Future<void>.delayed(const Duration(seconds: 2));
    File(p.join(b, 'same.txt')).writeAsStringSync('newer on right');
    await tap(find.text('좌 ⇄ 우'));
    await shot('rsync_confirm');
    await tap(find.text('실행'));
    await wait(1500);
    await shot('rsync_running');
    for (var i = 0; i < 100 && !File(p.join(a, 'only-right.txt')).existsSync(); i++) {
      await wait(200);
    }
    await wait(2500);
    expect(File(p.join(a, 'only-right.txt')).readAsStringSync(), 'r');
    expect(File(p.join(b, 'same.txt')).readAsStringSync(), 'newer on right'); // 오른쪽의 새 것이 그대로
    expect(File(p.join(a, 'same.txt')).readAsStringSync(), 'newer on right'); // 왼쪽으로 맞춰짐
    await shot('rsync_page');

    // 모니터링: 실행한 두 방향이 남는다
    await tap(find.text('모니터링'));
    await wait(1500);
    expect(c.settings.copyTasks.length, 2);
    expect(c.settings.copyTasks.every((t) => t.method == 'rsync' && t.contents && t.lastResult == 'done'), isTrue);
    await shot('rsync_monitor');
    tester.view.reset();
    tmp.deleteSync(recursive: true);
  });
}
