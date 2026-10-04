import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:jj_mkvmaker/app/app_controller.dart';
import 'package:jj_mkvmaker/core/encode_options.dart';
import 'package:jj_mkvmaker/core/models.dart';
import 'package:jj_mkvmaker/core/output_paths.dart';
import 'package:jj_mkvmaker/services/platform_services.dart';
import 'package:jj_mkvmaker/ui/theme.dart';
import 'package:jj_mkvmaker/ui/video_adjust_dialog.dart';
import 'package:path/path.dart' as p;

/// 실제 FFmpeg: 가로 영상 → 화면 · 색 보정 창 미리보기 → 세로 9:16 + 채도 MKV 만들기
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('화면 · 색 보정: 미리보기와 세로 9:16 MKV', (tester) async {
    final dir = Directory.systemTemp.createTempSync('jj_adj_e2e_');
    final video = p.join(dir.path, '가로 영상.mp4');
    final ffmpeg = p.join(Directory.current.path, 'third_party', 'ffmpeg', 'windows', 'ffmpeg.exe');
    final r = await Process.run(ffmpeg, [
      '-y', '-v', 'error', '-f', 'lavfi', '-i', 'testsrc2=size=640x360:rate=10:duration=3', //
      '-c:v', 'libx264', '-pix_fmt', 'yuv420p', video,
    ]);
    expect(r.exitCode, 0, reason: '${r.stderr}');

    final c = AppController(PlatformServices.create());
    await tester.runAsync(() async {
      await c.init();
      await c.addVideos([video]);
    });
    c.setAdjust(c.encode.copyWith(frame: FrameChoice.portrait, fit: FitChoice.blur, saturation: 40, temperature: 30));
    expect(c.encode.codec, isNot(VideoCodecChoice.copy), reason: '조정하면 재인코딩');

    // 창을 열고 미리보기가 그려질 때까지
    tester.view.physicalSize = const Size(1200, 760);
    tester.view.devicePixelRatio = 1;
    final key = GlobalKey();
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(),
      // 대화 상자 (Navigator 위) 까지 사진에 담기게 앱 전체를 감싼다
      builder: (context, child) => RepaintBoundary(key: key, child: child),
      home: Scaffold(body: Builder(builder: (context) {
        return Center(
          child: FilledButton(onPressed: () => showVideoAdjust(context, c), child: const Text('open')),
        );
      })),
    ));
    await tester.tap(find.text('open'));
    for (var i = 0; i < 60 && find.byType(Image).evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
      await tester.pump();
    }
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 800)));
    await tester.pump();
    expect(find.byType(Image), findsOneWidget, reason: '미리보기 장면');
    final shot = Platform.environment['JJ_SHOT_DIR'];
    if (shot != null) {
      final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await tester.runAsync(() => boundary.toImage());
      final bytes = await tester.runAsync(() => image!.toByteData(format: ui.ImageByteFormat.png));
      File('$shot/adjust_dialog.png').writeAsBytesSync(bytes!.buffer.asUint8List());
    }
    await tester.tap(find.byTooltip('닫기'));
    await tester.pumpAndSettle();

    // MKV 만들기 → 세로 360x640
    await tester.runAsync(() => c.buildAll());
    final v = c.videos.single;
    expect(v.status, JobStatus.done, reason: '${v.message}\n${c.logs.join('\n')}');
    final info = await tester.runAsync(() => c.services.mediaTool.probe(outputMkvPath(video)));
    final vs = info!.ofType('video').single;
    expect([vs.width, vs.height], [360, 640]);
    tester.view.reset();
    dir.deleteSync(recursive: true);
  }, timeout: const Timeout(Duration(minutes: 5)));
}
