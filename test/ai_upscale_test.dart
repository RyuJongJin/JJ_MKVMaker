import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:jj_mkvmaker/app/ai_local.dart';
import 'package:jj_mkvmaker/app/ai_upscale.dart';
import 'package:jj_mkvmaker/app/settings.dart';
import 'package:jj_mkvmaker/core/ai_catalog.dart';
import 'package:jj_mkvmaker/services/image_ai.dart';
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

  test('156: 자동이면 받아 둔 모델을 쓴다 (고른 것이 없을 때) · 직접 고른 것은 그대로', () {
    bool only(String id, String x) => x == id;
    expect(installedUpscaleModel((x) => only('esrgan-anime6b', x), 'auto', gpu: true), 'esrgan-anime6b');
    expect(installedUpscaleModel((x) => only('esrgan-x4plus', x), 'auto', gpu: false), 'esrgan-x4plus');
    expect(installedUpscaleModel((x) => true, 'auto', gpu: true), 'esrgan-x4plus');
    expect(installedUpscaleModel((x) => false, 'auto', gpu: true), isNull);
    expect(installedUpscaleModel((x) => only('esrgan-anime6b', x), 'photo', gpu: true), isNull);
  });

  test('152: 모델 읽는 동안에는 남은 시간을 보이지 않는다 · 157: 끝난 일은 다음 일을 시작하면 지운다', () {
    final jobs = AiJobs();
    jobs.done('4장 저장: x', dir: 'x');
    expect(jobs.lastDone, '4장 저장: x');
    jobs.update(title: 'AI', eta: const Duration(seconds: 5));
    expect(jobs.statusLine, contains('5'));
    jobs.eta = null;
    jobs.update(title: 'AI 그림: 모델 읽는 중 …');
    expect(jobs.statusLine, isNot(contains('남은 약')));
  });

  test('159: 프롬프트 · 만든 그림 목록이 설정에 남는다', () {
    final b = AppSettings.fromJson((AppSettings()
          ..aiPrompt = 'a cat'
          ..aiRecent = ['C:/a/ai_1.png', 'C:/a/ai_2.png'])
        .toJson());
    expect(b.aiPrompt, 'a cat');
    expect(b.aiRecent, ['C:/a/ai_1.png', 'C:/a/ai_2.png']);
  });

  group('156-2: 가짜 AI 결과 막기', () {
    // 그림 하나 (원본) 와 그 4배
    late String input;
    setUp(() {
      input = p.join(tmp.path, 'in.png');
      File(input).writeAsBytesSync(img.encodePng(img.Image(width: 8, height: 6)));
    });

    AiUpscaler fake(void Function(String input, String out) write, {List<String> log = const []}) => AiUpscaler(
          device: const SdDevice('sd-cli', 'cpu', 'CPU'),
          modelPath: 'm.pth',
          modelId: 'esrgan-anime6b',
          runner: (exe, args, {onProgress, onStart}) async {
            write(args[args.indexOf('-i') + 1], args[args.indexOf('-o') + 1]);
            for (final l in log) {
              if (isSdFatalLine(l)) throw ImageAiException('fatal', detail: l);
            }
            return log;
          },
        );

    test('엔진이 원본을 그대로 돌려주면 (업스케일러를 만들지 못함) 실패', () async {
      final up = fake((i, o) => File(i).copySync(o));
      await expectLater(up.upscale4x(input), throwsA(isA<ImageAiException>()));
    });

    test('정확히 4배면 통과', () async {
      final up = fake((i, o) => File(o).writeAsBytesSync(img.encodePng(img.Image(width: 32, height: 24))));
      final out = await up.upscale4x(input);
      expect(File(out).existsSync(), true);
    });

    test('엔진 기록의 실패 줄을 알아챈다 (0 으로 끝나도)', () {
      expect(isSdFatalLine('[E] new_upscaler_ctx failed --- main.cpp:966'), true);
      expect(isSdFatalLine('[ERROR] upscaler backend config failed: unknown backend cuda0'), true);
      expect(isSdFatalLine('[I] 1/1 images saved --- main.cpp:573'), false);
    });

    test('그림 만들기: 정한 크기인지', () {
      final png = img.encodePng(img.Image(width: 512, height: 384));
      expect(sizeMatches(png, 512, 384), true);
      expect(sizeMatches(png, 512, 512), false);
    });

    test('지난번 걸린 시간으로 한 장 예상 · 설정에 남음', () {
      final up = fake((i, o) {});
      expect(upscaleSpeedKey(up), 'cpu|esrgan-anime6b');
      expect(upscaleEstimate({}, up, 0.2), isNull);
      // S10 실측: 512×384 (0.197MP) 에 약 87초 → 100만 화소당 약 442초
      expect(upscaleEstimate({'cpu|esrgan-anime6b': 442}, up, 0.196608)!.inSeconds, 87);
      final b = AppSettings.fromJson((AppSettings()..aiUpSecPerMp = {'cpu|esrgan-anime6b': 442.5}).toJson());
      expect(b.aiUpSecPerMp, {'cpu|esrgan-anime6b': 442.5});
    });
  });
}
