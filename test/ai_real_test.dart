import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jj_mkvmaker/app/ai_local.dart';
import 'package:jj_mkvmaker/core/sd_cli.dart';
import 'package:path/path.dart' as p;

/// 123: 진짜 stable-diffusion.cpp 와 모델로 앱의 엔진 코드를 돌린다 (JJ_TEST_SD_DIR 가 있을 때만 - 모델이 4GB).
/// JJ_TEST_SD_DIR 아래: bin_vulkan/sd-cli.exe, models/v1-5-pruned-emaonly.safetensors, models/lcm-lora-sdv1-5.safetensors, models/taesd.safetensors
void main() {
  final root = Platform.environment['JJ_TEST_SD_DIR'] ?? '';
  test('진짜 엔진: 256×256 · 1단계 · 두 장 (CPU + TAESD) - 앱이 넘기는 인수 그대로', () async {
    final dir = Directory.systemTemp.createTempSync('jj_ai_real_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final models = SdModelPaths(
      model: p.join(root, 'models', 'v1-5-pruned-emaonly.safetensors'),
      loraDir: p.join(root, 'models'),
      loraName: 'lcm-lora-sdv1-5',
      taesd: p.join(root, 'models', 'taesd.safetensors'),
    );
    final engine = LocalSdEngine(device: SdDevice(p.join(root, 'bin_vulkan', 'sd-cli.exe'), 'cpu', 'CPU'), models: models);
    final progress = <double>[];
    final made = await engine.generate(const ImageGenRequest(prompt: 'a red apple on a table', width: 256, height: 256, steps: 1, seed: 5, count: 2),
        outDir: dir.path, baseName: 'real', onProgress: (v, _) {
      if (v != null) progress.add(v);
    });
    expect(made.map((g) => g.seed), [5, 6]);
    for (final g in made) {
      final bytes = File(g.path).readAsBytesSync();
      expect(bytes.sublist(1, 4), 'PNG'.codeUnits);
      expect(bytes.length, greaterThan(10000), reason: '잡음 · 빈 그림이 아니라 실제 그림 크기');
    }
    expect(progress, isNotEmpty);
    expect(progress.last, closeTo(1, 0.001));
  }, timeout: const Timeout(Duration(minutes: 10)), skip: root.isEmpty || !Platform.isWindows);
}
