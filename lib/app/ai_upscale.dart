import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

import '../core/ai_catalog.dart';
import '../core/sd_cli.dart';
import '../l10n/tr.dart';
import '../services/image_ai.dart';
import 'ai_local.dart';

/// 121: AI 해상도 올리기 (Real-ESRGAN, stable-diffusion.cpp 의 sd-cli -M upscale).
/// 모델은 늘 4배로 그리고, 2 · 3배는 그 결과를 줄여 만든다. 원본은 절대 덮어쓰지 않는다.
class UpscaleOptions {
  /// 'auto' · 'photo' · 'anime'
  final String model;
  final int scale;

  /// 'same' (원본과 같은 형식, WebP 등 못 쓰는 형식은 PNG) · 'png' · 'jpg'
  final String format;
  final int jpgQuality;

  /// 저장 폴더 (비어 있으면 원본 옆)
  final String outDir;
  const UpscaleOptions({this.model = 'auto', this.scale = 2, this.format = 'same', this.jpgQuality = 92, this.outDir = ''});
}

/// 자동 모델: GPU 가 있으면 사진용 (x4plus), CPU 뿐이면 가볍고 빠른 만화용 (CPU 로 x4plus 는 512px 한 장에 20분 - 이 PC 실측)
String pickUpscaleModel(String setting, {required bool gpu}) =>
    setting == 'auto' ? (gpu ? 'esrgan-x4plus' : 'esrgan-anime6b') : upscaleModelFor(setting, phone: false);

/// 저장 형식 확장자
String upscaleExt(String source, String format) {
  final e = p.extension(source).toLowerCase().replaceFirst('.', '');
  return switch (format) {
    'png' => 'png',
    'jpg' => 'jpg',
    _ => const ['jpg', 'jpeg'].contains(e) ? 'jpg' : 'png',
  };
}

/// 저장할 이름: 원본 옆 (또는 [outDir]) 에 "이름_x2.png". 이미 있으면 "이름_x2 (2).png" … (덮어쓰지 않음)
String upscaledPath(String source, {required int scale, required String ext, String outDir = ''}) {
  final dir = outDir.isEmpty ? p.dirname(source) : outDir;
  final base = '${p.basenameWithoutExtension(source)}_x$scale';
  var path = p.join(dir, '$base.$ext');
  for (var n = 2; File(path).existsSync(); n++) {
    path = p.join(dir, '$base ($n).$ext');
  }
  return path;
}

/// 4배로 올린 그림 [fourX] 를 [scale] 배 크기로 줄이고 형식에 맞게 담는다 (따로 돌려 화면이 멈추지 않게)
Future<Uint8List> finishUpscale(Uint8List fourX, {required int origW, required int origH, required int scale, required String ext, int quality = 92}) =>
    compute(_finish, (fourX, origW, origH, scale, ext, quality));

Uint8List _finish((Uint8List, int, int, int, String, int) a) {
  final (bytes, w, h, scale, ext, q) = a;
  var im = img.decodeImage(bytes);
  if (im == null) throw const ImageAiException('decode failed');
  if (scale != 4 && w > 0 && h > 0) {
    im = img.copyResize(im, width: w * scale, height: h * scale, interpolation: img.Interpolation.cubic);
  }
  return ext == 'jpg' ? img.encodeJpg(im, quality: q) : img.encodePng(im);
}

/// 156-2: Android CPU 는 모든 코어와 큰 타일 (512) 을 쓴다. S10 실측 512×384 (만화 모델):
/// 기본 (물리 코어 · 타일 128) 88~92초, -t 8 65~96초, 타일 512 60~65초, 타일 256 108~111초, -t 8 + 타일 512 45~48초.
/// 그 밖 (Windows · GPU) 은 엔진 기본값
bool _androidCpu(SdDevice d) => Platform.isAndroid && d.backend == 'cpu';
int upscaleThreads(SdDevice d) => _androidCpu(d) ? Platform.numberOfProcessors : 0;
int upscaleTileSize(SdDevice d) => _androidCpu(d) ? 512 : 0;

/// 156-2: 걸린 시간을 기억할 열쇠 (처리 장치 · 모델이 같아야 비교가 된다)
String upscaleSpeedKey(AiUpscaler up) => '${up.device.backend}|${up.modelId}';

/// 그림의 화소 수 (백만 단위, 머리만 읽음 - 모르면 null)
double? megapixels(Uint8List bytes) {
  final info = img.findDecoderForData(bytes)?.startDecode(bytes);
  if (info == null || info.width == 0) return null;
  return info.width * info.height / 1e6;
}

/// 지난번 걸린 시간으로 이 그림 한 장의 예상 시간 (모르면 null)
Duration? upscaleEstimate(Map<String, double> secPerMp, AiUpscaler up, double mp) {
  final s = secPerMp[upscaleSpeedKey(up)];
  return s == null ? null : Duration(seconds: (s * mp).round().clamp(1, 1 << 20));
}

/// 167: sd-cli 진행 → (진행 0~1, 남은 시간). 모델을 읽는 막대 ("192/192 - 84MB/s") 는 올리기 진행이 아니다 -
/// 그때는 모름 (null, 움직이는 막대). 올리기는 타일 (n/m) 과 타일 한 장에 걸린 초로 남은 시간을 셈
(double?, Duration?) upscaleProgressOf(SdProgress prog) => switch (prog.phase) {
      'done' => (1.0, Duration.zero),
      'sample' when prog.steps > 0 => (
          prog.step / prog.steps,
          prog.secondsPerStep == null || prog.step == 0
              ? null
              : Duration(milliseconds: ((prog.steps - prog.step) * prog.secondsPerStep! * 1000).round()),
        ),
      _ => (null, null),
    };

/// 156-2: [result] 가 [input] 의 정확히 4배 크기인지 (그림 머리만 읽음)
bool isFourTimes(Uint8List input, Uint8List result) {
  final a = img.findDecoderForData(input)?.startDecode(input);
  final b = img.findDecoderForData(result)?.startDecode(result);
  if (a == null || b == null || a.width == 0) return false;
  return b.width == a.width * 4 && b.height == a.height * 4;
}

/// 그림 한 장 올리기. [input] 은 이 기기의 파일 (ZIP · WebDAV 의 그림은 부르는 쪽이 임시 파일로).
/// 결과를 [save] 가 true 면 저장하고 그 경로를, 아니면 임시 파일 경로를 돌려준다 (비교해 보고 저장할 때).
class AiUpscaler {
  AiUpscaler({required this.device, required this.modelPath, this.modelId = '', this.runner = runSdCli});
  final SdDevice device;
  final String modelPath;

  /// sd-cli 실행기 (시험에서 가짜 엔진)
  final SdRunner runner;

  /// 카탈로그 id (자동이 CPU 에서 만화용을 골랐는지 알리려고)
  final String modelId;
  Process? _proc;
  bool _cancelled = false;

  void cancel() {
    _cancelled = true;
    _proc?.kill();
  }

  /// 4배 결과를 임시 파일로 만든다 (진행: 0~1)
  Future<String> upscale4x(String input, {void Function(double? p)? onProgress, void Function(Duration? left)? onEta}) async {
    _cancelled = false;
    final tmp = await Directory.systemTemp.createTemp('jj_up_');
    final out = p.join(tmp.path, 'up.png');
    try {
      await runner(device.exe, sdUpscaleArgs(model: modelPath, input: input, out: out, backend: device.backend, threads: upscaleThreads(device), tileSize: upscaleTileSize(device)),
          onProgress: (prog) {
            final (v, left) = upscaleProgressOf(prog);
            onProgress?.call(v);
            onEta?.call(left);
          },
          onStart: (pr) => _proc = pr);
    } catch (_) {
      if (_cancelled) throw ImageAiException(tr('취소했습니다'), cancelled: true);
      rethrow;
    }
    if (_cancelled) throw ImageAiException(tr('취소했습니다'), cancelled: true);
    if (!File(out).existsSync()) throw ImageAiException(tr('해상도를 올리지 못했습니다'));
    // 156-2: 엔진이 업스케일러를 만들지 못하면 (장치가 맞지 않는 등) 원본을 그대로 저장하고 정상으로 끝난다 -
    // 크기가 정확히 4배가 아니면 AI 결과가 아니므로 보통 확대로 꾸며 보이지 않고 실패로 알린다
    if (!isFourTimes(await File(input).readAsBytes(), await File(out).readAsBytes())) {
      throw ImageAiException(tr('AI 엔진이 해상도를 올리지 못했습니다 (처리 장치를 바꿔 보세요)'));
    }
    return out;
  }

  /// 올려서 저장까지: 저장한 경로
  Future<String> upscaleAndSave(String input, UpscaleOptions o, {String? nameFrom, void Function(double? p)? onProgress}) async {
    final four = await upscale4x(input, onProgress: onProgress);
    try {
      return await saveUpscaled(four, source: nameFrom ?? input, original: input, o: o);
    } finally {
      try {
        await Directory(p.dirname(four)).delete(recursive: true);
      } catch (_) {}
    }
  }
}

/// 4배 결과 [fourX] 를 설정대로 줄이고 담아 새 파일로 저장한다 (이름은 [source] 기준, 크기는 [original] 기준)
Future<String> saveUpscaled(String fourX, {required String source, required String original, required UpscaleOptions o}) async {
  final orig = img.decodeImage(await File(original).readAsBytes());
  final ext = upscaleExt(source, o.format);
  final bytes = await finishUpscale(await File(fourX).readAsBytes(),
      origW: orig?.width ?? 0, origH: orig?.height ?? 0, scale: o.scale, ext: ext, quality: o.jpgQuality);
  final path = upscaledPath(source, scale: o.scale, ext: ext, outDir: o.outDir);
  await Directory(p.dirname(path)).create(recursive: true);
  await File(path).writeAsBytes(bytes, flush: true);
  return path;
}

/// 156: 쓸 모델 - 자동이면 고른 것을 받아 두지 않았을 때 받아 둔 다른 것을 쓴다 (없으면 null)
String? installedUpscaleModel(bool Function(String id) installed, String setting, {required bool gpu}) {
  final want = pickUpscaleModel(setting, gpu: gpu);
  if (installed(want)) return want;
  if (setting != 'auto') return null;
  for (final id in const ['esrgan-x4plus', 'esrgan-anime6b']) {
    if (installed(id)) return id;
  }
  return null;
}

/// 해상도 올리기에 쓸 장치 (엔진이 없으면 null)
Future<SdDevice?> pickUpscaleDevice(AiStore store, {String device = 'auto'}) async {
  final devices = await sdDevices(store);
  if (devices.isEmpty) return null;
  SdDevice dev;
  if (device != 'auto') {
    dev = devices.where((d) => d.key == device).firstOrNull ?? devices.first;
  } else {
    // 해상도 올리기는 그림 만들기와 달리 Vulkan 이 CUDA 보다 빨랐다 (이 PC, x4plus 512→2048: Vulkan 116초 · CUDA 197초 · CPU 1224초)
    dev = devices.where((d) => d.backend.startsWith('vulkan')).firstOrNull ??
        devices.where((d) => d.backend.startsWith('cuda')).firstOrNull ??
        devices.first;
  }
  return dev;
}

/// 해상도 올리기에 쓸 장치 · 모델 (없으면 null - 받을 것을 묻는다)
Future<AiUpscaler?> prepareUpscaler(AiStore store, {required String modelSetting, String device = 'auto', String autoDevice = ''}) async {
  final dev = await pickUpscaleDevice(store, device: device);
  if (dev == null) return null;
  final id = installedUpscaleModel(store.isInstalled, modelSetting, gpu: dev.backend != 'cpu');
  if (id == null) return null;
  return AiUpscaler(device: dev, modelPath: store.pathOf(aiFile(id)), modelId: id);
}
