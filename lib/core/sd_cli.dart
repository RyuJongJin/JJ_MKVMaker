import 'dart:convert';

/// 123: AI 그림 한 번 만들기 (글 → 그림, [initImage] 가 있으면 그림 → 그림)
class ImageGenRequest {
  final String prompt;
  final String negative;
  final int width;
  final int height;
  final int steps;
  final double cfg;

  /// 시드 (-1 이면 엔진이 아무렇게나 - 만든 뒤 실제 시드를 남긴다)
  final int seed;
  final int count;

  /// 그림 → 그림: 바탕 그림 · 바꾸는 정도 (0 거의 그대로 ~ 1 새로 그림)
  final String? initImage;
  final double strength;

  /// 기기 안 엔진의 모델 (카탈로그 id) · 인터넷 · 자기 서버 엔진의 모델 이름
  final String model;

  const ImageGenRequest({
    required this.prompt,
    this.negative = '',
    this.width = 512,
    this.height = 512,
    this.steps = 4,
    this.cfg = 1,
    this.seed = -1,
    this.count = 1,
    this.initImage,
    this.strength = 0.6,
    this.model = 'sd15-lcm',
  });

  bool get imageToImage => initImage != null && initImage!.isNotEmpty;

  /// 다시 만들 수 있게 결과 옆에 남기는 정보 (그림 파일 이름.json)
  Map<String, Object?> toJson({required String engine, int? actualSeed}) => {
        'app': 'JJ_MKVMaker',
        'engine': engine,
        'model': model,
        'prompt': prompt,
        'negative': negative,
        'width': width,
        'height': height,
        'steps': steps,
        'cfg': cfg,
        'seed': actualSeed ?? seed,
        if (imageToImage) 'initImage': initImage,
        if (imageToImage) 'strength': strength,
        'created': DateTime.now().toIso8601String(),
      };

  static ImageGenRequest fromJson(Map<String, Object?> j) => ImageGenRequest(
        prompt: '${j['prompt'] ?? ''}',
        negative: '${j['negative'] ?? ''}',
        width: (j['width'] as num?)?.toInt() ?? 512,
        height: (j['height'] as num?)?.toInt() ?? 512,
        steps: (j['steps'] as num?)?.toInt() ?? 4,
        cfg: (j['cfg'] as num?)?.toDouble() ?? 1,
        seed: (j['seed'] as num?)?.toInt() ?? -1,
        initImage: j['initImage'] as String?,
        strength: (j['strength'] as num?)?.toDouble() ?? 0.6,
        model: '${j['model'] ?? 'sd15-lcm'}',
      );

  String encode({required String engine, int? actualSeed}) =>
      const JsonEncoder.withIndent('  ').convert(toJson(engine: engine, actualSeed: actualSeed));
}

/// sd-cli 에 넘길 모델 파일들
class SdModelPaths {
  final String model;

  /// LCM-LoRA 가 있는 폴더 · 파일 이름 (확장자 없이) - 없으면 LoRA 없이
  final String? loraDir;
  final String? loraName;

  /// 빠른 디코더 (TAESD) - 없으면 원래 VAE
  final String? taesd;
  const SdModelPaths({required this.model, this.loraDir, this.loraName, this.taesd});
}

/// sd-cli 인수. [backend]: 'cpu' · 'vulkan0' · 'cuda0' 등 (null 이면 엔진이 고름), [out]: 결과 (%d 로 여러 장)
List<String> sdCliArgs(ImageGenRequest r, SdModelPaths m, {required String out, String? backend, int threads = 0}) {
  final lora = m.loraDir != null && m.loraName != null;
  return [
    '-m', m.model,
    // 공식 모델 파일을 그대로 받아 f16 으로 (변환한 gguf 는 이 판에서 잡음이 나옴)
    '--type', 'f16',
    if (lora) ...['--lora-model-dir', m.loraDir!],
    if (m.taesd != null) ...['--taesd', m.taesd!],
    '-p', lora ? '${r.prompt}<lora:${m.loraName}:1>' : r.prompt,
    if (r.negative.trim().isNotEmpty) ...['-n', r.negative],
    '-W', '${r.width}',
    '-H', '${r.height}',
    '--steps', '${r.steps}',
    '--cfg-scale', r.cfg.toString(),
    if (lora) ...['--sampling-method', 'lcm'],
    '--seed', '${r.seed}',
    '-b', '${r.count}',
    if (r.imageToImage) ...['-i', r.initImage!, '--strength', r.strength.toString()],
    if (backend != null && backend.isNotEmpty) ...['--backend', backend],
    if (threads > 0) ...['-t', '$threads'],
    '-o', out,
  ];
}

/// 해상도 올리기 (121): sd-cli -M upscale
List<String> sdUpscaleArgs({required String model, required String input, required String out, int repeats = 1, String? backend}) => [
      '-M', 'upscale',
      '--upscale-model', model,
      '-i', input,
      if (repeats > 1) ...['--upscale-repeats', '$repeats'],
      if (backend != null && backend.isNotEmpty) ...['--backend', backend],
      '-o', out,
    ];

/// sd-cli 진행 줄 하나를 읽은 결과
class SdProgress {
  /// 'load' 모델 읽기 · 'sample' 그리기 · 'decode' 그림으로 · 'done'
  final String phase;
  final int step;
  final int steps;

  /// 한 단계에 걸린 초 (그리기일 때)
  final double? secondsPerStep;
  const SdProgress(this.phase, this.step, this.steps, {this.secondsPerStep});

  /// 전체 진행 (0 ~ 1): 읽기 0 ~ 0.1 · 그리기 0.1 ~ 0.9 · 그림으로 0.9 ~ 1
  double get overall => switch (phase) {
        'load' => 0.1 * (steps == 0 ? 0 : step / steps),
        'sample' => 0.1 + 0.8 * (steps == 0 ? 0 : step / steps),
        'decode' => 0.9,
        _ => 1,
      };
}

final _bar = RegExp(r'\|[=#> ]*\|\s*(\d+)/(\d+)\s*-\s*([\d.]+)\s*(s/it|it/s|MB/s)');

/// sd-cli 출력 (줄바꿈 · \r 로 나뉜 조각) 에서 진행을 읽는다. 진행이 아니면 null
SdProgress? parseSdProgress(String text) {
  final t = text.trim();
  if (t.contains('decode_first_stage') || t.contains('decoding')) return const SdProgress('decode', 0, 0);
  if (t.contains('generate_image completed') || t.contains('images saved')) return const SdProgress('done', 1, 1);
  final m = _bar.allMatches(t).lastOrNull;
  if (m == null) return null;
  final a = int.parse(m.group(1)!), b = int.parse(m.group(2)!);
  final unit = m.group(4)!;
  if (unit == 'MB/s') return SdProgress('load', a, b);
  final v = double.tryParse(m.group(3)!);
  final spi = v == null || v == 0 ? null : (unit == 's/it' ? v : 1 / v);
  return SdProgress('sample', a, b, secondsPerStep: spi);
}

/// sd-cli --list-devices 결과 → 고를 수 있는 처리 장치 ('Vulkan0' → 'vulkan0' 이름, 설명)
List<(String, String)> parseSdDevices(String out) => [
      for (final line in const LineSplitter().convert(out))
        if (RegExp(r'^(CPU|Vulkan\d+|CUDA\d+)\t').hasMatch(line))
          (line.split('\t').first.toLowerCase(), line.split('\t').skip(1).join(' ').trim()),
    ];
