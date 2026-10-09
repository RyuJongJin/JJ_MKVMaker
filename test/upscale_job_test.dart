import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:jj_mkvmaker/app/ai_local.dart';
import 'package:jj_mkvmaker/app/ai_upscale.dart';
import 'package:jj_mkvmaker/app/app_controller.dart';
import 'package:jj_mkvmaker/platform/windows/desktop_storage_service.dart';
import 'package:jj_mkvmaker/platform/windows/process_media_tool.dart';
import 'package:jj_mkvmaker/services/platform_services.dart';
import 'package:jj_mkvmaker/ui/ai_upscale_ui.dart';
import 'package:path/path.dart' as p;

/// 176: 한 장 해상도 올리기도 작업 (AiJobs) 으로 - 작업 알림 · 앞 서비스 · 작업 현황에 나오고 화면을 떠나도 끝난다
void main() {
  late Directory tmp;
  late String input;
  late Completer<void> engine;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('jj_up_job_');
    input = p.join(tmp.path, 'page.png');
    File(input).writeAsBytesSync(img.encodePng(img.Image(width: 8, height: 6)));
    engine = Completer<void>();
    debugUpscalerForTest = () => AiUpscaler(
          device: const SdDevice('sd-cli', 'cpu', 'CPU'),
          modelPath: 'm.pth',
          modelId: 'esrgan-x4plus',
          runner: (exe, args, {onProgress, onStart}) async {
            await engine.future; // 엔진이 도는 동안
            File(args[args.indexOf('-o') + 1]).writeAsBytesSync(img.encodePng(img.Image(width: 32, height: 24)));
            return const [];
          },
        );
  });
  tearDown(() {
    debugUpscalerForTest = null;
    AiJobs.instance.done(''); // 남은 [보기] 정리
    tmp.deleteSync(recursive: true);
  });

  test('타일 크기: 기기 메모리의 20% 안 (S10 16GB → 320), 메모리를 모르면 큰 그림만 256', () {
    expect(androidUpscaleTile(memTotalMb: 15000), 320);
    expect(androidUpscaleTile(memTotalMb: 40000), 512);
    expect(androidUpscaleTile(memTotalMb: 6000), 192);
    expect(androidUpscaleTile(longSide: 1024), 256);
    expect(androidUpscaleTile(longSide: 800), 512);
  });

  testWidgets('[이 장] 은 작업 목록에 오르고, [뒤에서 계속] 으로 화면을 떠나도 끝나며 [보기] 로 비교 · 저장', (tester) async {
    final c = AppController(PlatformServices(mediaTool: ProcessMediaTool('x', 'y'), storage: DesktopStorageService()));
    var finished = false;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) => TextButton(
            onPressed: () => upscaleOne(ctx, c, input: input, nameFrom: input, outDir: tmp.path).whenComplete(() => finished = true),
            child: const Text('올리기'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('올리기'));
    for (var i = 0; i < 20 && !AiJobs.instance.busy; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
    // 작업 목록 (알림 · 작업 현황) 에 오른다
    expect(AiJobs.instance.busy, isTrue);
    expect(AiJobs.instance.statusLine, contains('page.png'));
    // 화면을 떠난다 (진행 창만 닫힘, 작업은 계속)
    await tester.tap(find.text('뒤에서 계속'));
    await tester.pumpAndSettle();
    expect(find.text('AI 해상도 올리기'), findsNothing);
    expect(AiJobs.instance.busy, isTrue);
    // 엔진이 끝나면 비교 화면을 띄우지 않고 [보기] 를 남긴다
    engine.complete();
    // 시험의 가짜 시간 안에서 시작한 일이라 기다리지 말고 끝날 때까지 돌린다
    for (var i = 0; i < 200 && !finished; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
    expect(finished, isTrue);
    await tester.pumpAndSettle();
    expect(AiJobs.instance.busy, isFalse);
    expect(AiJobs.instance.lastDone, contains('page.png'));
    expect(find.byType(UpscaleCompareView), findsNothing);
    final view = AiJobs.instance.lastDoneView;
    expect(view, isNotNull);
    // [보기] → 비교 화면 → [저장]
    var viewed = false;
    view!().whenComplete(() => viewed = true);
    await tester.pumpAndSettle();
    expect(find.byType(UpscaleCompareView), findsOneWidget);
    await tester.runAsync(() => tester.tap(find.widgetWithText(FilledButton, '저장')));
    for (var i = 0; i < 100 && !viewed; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
    expect(viewed, isTrue);
    final saved = [for (final f in tmp.listSync(recursive: true).whereType<File>()) if (!p.equals(f.path, input)) f.path];
    expect(saved, isNotEmpty, reason: '저장됨 (원본 옆, 새 파일)');
    expect(AiJobs.instance.lastDoneView, isNull, reason: '[보기] 는 한 번');
    ScaffoldMessenger.of(tester.element(find.text('올리기'))).clearSnackBars();
    await tester.pumpAndSettle();
  });
}
