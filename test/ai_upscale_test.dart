import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:jj_mkvmaker/app/ai_local.dart';
import 'package:jj_mkvmaker/app/ai_upscale.dart';
import 'package:jj_mkvmaker/app/settings.dart';
import 'package:jj_mkvmaker/core/ai_catalog.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('jj_up_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('121: 모델 고르기 - 자동은 GPU 면 사진용 · CPU 뿐이면 가볍고 빠른 만화용', () {
    expect(pickUpscaleModel('auto', gpu: true), 'esrgan-x4plus');
    expect(pickUpscaleModel('auto', gpu: false), 'esrgan-anime6b');
    expect(pickUpscaleModel('photo', gpu: false), 'esrgan-x4plus');
    expect(pickUpscaleModel('anime', gpu: true), 'esrgan-anime6b');
    for (final id in ['esrgan-x4plus', 'esrgan-anime6b']) {
      expect(aiFile(id).license, 'BSD-3-Clause');
      expect(aiFile(id).kind, 'upscale');
    }
  });

  test('121: 저장 형식 · 이름 - 원본 옆 "이름_x2", 있으면 덮지 않고 (2)', () {
    expect(upscaleExt('a.jpg', 'same'), 'jpg');
    expect(upscaleExt('a.webp', 'same'), 'png', reason: 'WebP 는 담을 수 없어 PNG');
    expect(upscaleExt('a.png', 'jpg'), 'jpg');
    final src = p.join(tmp.path, 'page.jpg');
    File(src).writeAsStringSync('x');
    final first = upscaledPath(src, scale: 2, ext: 'png');
    expect(p.basename(first), 'page_x2.png');
    File(first).writeAsStringSync('old');
    expect(p.basename(upscaledPath(src, scale: 2, ext: 'png')), 'page_x2 (2).png');
    expect(p.dirname(upscaledPath(src, scale: 3, ext: 'jpg', outDir: p.join(tmp.path, 'out'))), p.join(tmp.path, 'out'));
    expect(File(src).readAsStringSync(), 'x', reason: '원본 그대로');
  });

  test('121: 4배 결과를 2배 · 3배로 줄여 담기 (PNG · JPG)', () async {
    final four = img.Image(width: 40, height: 24);
    img.fill(four, color: img.ColorRgb8(200, 30, 30));
    final bytes = img.encodePng(four);
    final two = img.decodeImage(await finishUpscale(bytes, origW: 10, origH: 6, scale: 2, ext: 'png'))!;
    expect((two.width, two.height), (20, 12));
    final three = await finishUpscale(bytes, origW: 10, origH: 6, scale: 3, ext: 'jpg', quality: 80);
    expect(three.sublist(0, 2), [0xFF, 0xD8], reason: 'JPG');
    expect(img.decodeImage(three)!.width, 30);
    final keep = img.decodeImage(await finishUpscale(bytes, origW: 10, origH: 6, scale: 4, ext: 'png'))!;
    expect(keep.width, 40);
  });

  test('121: 여러 장 작업 - 진행 · 남은 장 · 취소하면 지금 장에서 멈춤', () async {
    final jobs = AiJobs.instance;
    final seen = <int>[];
    var cancelled = 0;
    final done = await jobs.runTask('올리기', 5, (i, progress) async {
      progress(0.5);
      seen.add(jobs.remaining);
      if (i == 2) jobs.cancel();
    }, onCancel: () => cancelled++);
    expect(done, 3);
    expect(seen, [5, 4, 3]);
    expect(cancelled, 1);
    expect(jobs.busy, isFalse);
  });

  test('121: 설정 처음 값 · 저장', () {
    final s = AppSettings();
    expect((s.aiUpModel, s.aiUpScale, s.aiUpFormat, s.aiUpDir, s.aiUpAfter), ('auto', 2, 'same', '', 'upscaled'));
    final b = AppSettings.fromJson((AppSettings()
          ..aiUpModel = 'photo'
          ..aiUpScale = 4
          ..aiUpFormat = 'jpg'
          ..aiUpJpgQuality = 80
          ..aiUpAfter = 'original')
        .toJson());
    expect((b.aiUpModel, b.aiUpScale, b.aiUpFormat, b.aiUpJpgQuality, b.aiUpAfter), ('photo', 4, 'jpg', 80, 'original'));
  });

  // 진짜 엔진 (JJ_TEST_SD_DIR: bin_vulkan/sd-cli.exe · models/RealESRGAN_x4plus_anime_6B.pth)
  final root = Platform.environment['JJ_TEST_SD_DIR'] ?? '';
  test('121: 진짜 엔진으로 64×48 → 2배 저장 (CPU, 원본은 그대로)', () async {
    final src = File(p.join(tmp.path, 'small.png'));
    final im = img.Image(width: 64, height: 48);
    img.fillCircle(im, x: 32, y: 24, radius: 16, color: img.ColorRgb8(10, 120, 220));
    src.writeAsBytesSync(img.encodePng(im));
    final before = src.readAsBytesSync();
    final up = AiUpscaler(
        device: SdDevice(p.join(root, 'bin_vulkan', 'sd-cli.exe'), 'cpu', 'CPU'),
        modelPath: p.join(root, 'models', 'RealESRGAN_x4plus_anime_6B.pth'));
    final progress = <double?>[];
    final saved = await up.upscaleAndSave(src.path, const UpscaleOptions(scale: 2), onProgress: progress.add);
    expect(p.basename(saved), 'small_x2.png');
    final out = img.decodeImage(File(saved).readAsBytesSync())!;
    expect((out.width, out.height), (128, 96));
    expect(src.readAsBytesSync(), before);
  }, timeout: const Timeout(Duration(minutes: 5)), skip: root.isEmpty || !Platform.isWindows);
}
