import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../core/ai_catalog.dart';
import '../core/sd_cli.dart';
import '../l10n/tr.dart';
import '../services/image_ai.dart';
import 'app_controller.dart';
import 'component_store.dart' show AccumulatorSink;
import 'copy_center.dart' show diskSpace;

/// 123 · 121: 기기 안 AI 파일 (모델 · 실행 파일) 받기 · 지우기. 앱 데이터 폴더의 ai/ 아래 (업데이트해도 남게).
class AiStore extends ChangeNotifier {
  AiStore(this.dataDir, {HttpClient? http}) : _http = http ?? (HttpClient()..userAgent = 'JJMKVMaker');
  final String dataDir;
  final HttpClient _http;

  static AiStore? instance;

  String get root => p.join(dataDir, 'ai');

  /// 받은 파일이 놓이는 곳. LoRA 는 sd-cli 의 <lora:이름:1> 과 맞게 이름을 바꿔 둔다.
  String pathOf(AiFile f) => switch (f.kind) {
        'engine' => p.join(root, f.id),
        'lora' => p.join(root, 'lora', 'lcm-lora-sdv1-5.safetensors'),
        _ => p.join(root, 'models', '${f.id}${p.extension(f.fileName)}'),
      };

  File _mark(AiFile f) => File(p.join(root, 'installed', '${f.id}.json'));

  bool isInstalled(String id) => isFileInstalled(aiFile(id));

  bool isFileInstalled(AiFile f) => _mark(f).existsSync() && FileSystemEntity.typeSync(pathOf(f)) != FileSystemEntityType.notFound;

  /// 받는 중인 것 (id → 0~1, 모르면 null)
  final progress = <String, double?>{};
  final _cancel = <String>{};

  void cancel(String id) => _cancel.add(id);

  /// 받기 (SHA-256 확인). 저장 공간이 모자라면 먼저 알린다. zip (실행 파일) 은 푼다.
  Future<void> install(String id) => installFile(aiFile(id));

  /// [install] 의 본체 (시험은 카탈로그 밖의 파일로)
  Future<void> installFile(AiFile f) async {
    final id = f.id;
    if (progress.containsKey(id)) return;
    _cancel.remove(id);
    await Directory(root).create(recursive: true);
    final free = await diskSpace(root);
    // 받는 파일 + 푸는 자리 (zip 은 두 배쯤) 와 여유 200MB
    final need = (f.kind == 'engine' ? f.size * 3 : f.size) + (200 << 20);
    if (free != null && free.$1 < need) {
      throw ImageAiException(trf('저장 공간이 모자랍니다: {0} 이 필요한데 {1} 남았습니다', [_gb(need), _gb(free.$1)]));
    }
    progress[id] = 0;
    notifyListeners();
    final part = File('${pathOf(f)}.part${f.kind == 'engine' ? '.zip' : ''}');
    try {
      await part.parent.create(recursive: true);
      await _download(f, part, (d) {
        progress[id] = d;
        notifyListeners();
      });
      if (f.kind == 'engine') {
        final dir = Directory(pathOf(f));
        if (await dir.exists()) await dir.delete(recursive: true);
        await extractFileToDisk(part.path, dir.path);
        await part.delete();
      } else {
        final dst = File(pathOf(f));
        if (await dst.exists()) await dst.delete();
        await part.rename(dst.path);
      }
      await _mark(f).parent.create(recursive: true);
      await _mark(f).writeAsString(jsonEncode({'sha256': f.sha256, 'installed': DateTime.now().toIso8601String()}));
    } catch (_) {
      try {
        if (await part.exists()) await part.delete();
      } catch (_) {}
      rethrow;
    } finally {
      progress.remove(id);
      notifyListeners();
    }
  }

  Future<void> remove(String id) async {
    final f = aiFile(id);
    try {
      await _mark(f).delete();
    } catch (_) {}
    final t = FileSystemEntity.typeSync(pathOf(f));
    if (t == FileSystemEntityType.directory) await Directory(pathOf(f)).delete(recursive: true);
    if (t == FileSystemEntityType.file) await File(pathOf(f)).delete();
    notifyListeners();
  }

  static String _gb(int b) => b >= 1 << 30 ? '${(b / (1 << 30)).toStringAsFixed(1)}GB' : '${(b / (1 << 20)).round()}MB';
  static String sizeText(int b) => _gb(b);

  Future<void> _download(AiFile f, File out, void Function(double? d) onProgress) async {
    final req = await _http.getUrl(Uri.parse(f.url));
    final res = await req.close();
    if (res.statusCode != 200) throw ImageAiException(trf('받을 수 없습니다 ({0}): {1}', [res.statusCode, f.url]));
    final total = res.contentLength > 0 ? res.contentLength : f.size;
    final sink = out.openWrite();
    final hash = AccumulatorSink<Digest>();
    final hasher = sha256.startChunkedConversion(hash);
    var done = 0;
    try {
      await for (final chunk in res) {
        if (_cancel.contains(f.id)) throw ImageAiException(tr('취소했습니다'));
        sink.add(chunk);
        hasher.add(chunk);
        done += chunk.length;
        onProgress(total > 0 ? done / total : null);
      }
    } finally {
      await sink.close();
      hasher.close();
    }
    if (hash.events.single.toString() != f.sha256) {
      await out.delete();
      throw ImageAiException(trf('받은 파일이 손상되었습니다 (SHA-256 다름): {0}', [f.name]));
    }
  }

  // ───────── 실행 파일 ─────────

  /// sd-cli: Android 는 앱에 들어 있는 것 (libsdcli.so - 앱 데이터 폴더의 파일은 실행할 수 없음), Windows 는 받은 것
  Future<String?> sdCli({bool cuda = false}) async {
    if (Platform.isAndroid) {
      try {
        final dir = await const MethodChannel('jj_mkvmaker/android').invokeMethod<String>('nativeLibDir');
        final f = dir == null ? null : File(p.join(dir, 'libsdcli.so'));
        return f != null && f.existsSync() ? f.path : null;
      } catch (_) {
        return null;
      }
    }
    final id = cuda ? 'engine-cuda' : 'engine-vulkan';
    if (!isInstalled(id)) return null;
    final exe = _find(Directory(pathOf(aiFile(id))), 'sd-cli.exe');
    return exe;
  }

  static String? _find(Directory dir, String name) {
    if (!dir.existsSync()) return null;
    for (final e in dir.listSync(recursive: true, followLinks: false)) {
      if (e is File && p.basename(e.path).toLowerCase() == name) return e.path;
    }
    return null;
  }

  /// CUDA 판은 런타임 (cudart) DLL 을 같은 폴더에 둔다
  Future<void> placeCudaRuntime() async {
    if (!isInstalled('engine-cuda') || !isInstalled('engine-cudart')) return;
    final exe = await sdCli(cuda: true);
    if (exe == null) return;
    for (final e in Directory(pathOf(aiFile('engine-cudart'))).listSync(recursive: true)) {
      if (e is File && e.path.toLowerCase().endsWith('.dll')) {
        final dst = File(p.join(p.dirname(exe), p.basename(e.path)));
        if (!dst.existsSync()) await e.copy(dst.path);
      }
    }
  }

  /// NVIDIA 그래픽카드가 있는지 (CUDA 판을 받기 목록에 보일지)
  static Future<bool> hasNvidia() async {
    // 위젯 시험에서는 실제 프로그램을 부르지 않는다 (가짜 시간 안에서 끝나지 않음)
    if (!Platform.isWindows || Platform.environment.containsKey('FLUTTER_TEST')) return false;
    try {
      final r = await Process.run('nvidia-smi', ['-L']);
      return r.exitCode == 0 && '${r.stdout}'.contains('GPU');
    } catch (_) {
      return false;
    }
  }

  /// 그림 만들기에 쓸 모델 파일 (없으면 null)
  SdModelPaths? sd15Paths({required bool taesd}) {
    if (!sd15LcmFiles.every(isInstalled)) return null;
    final lora = pathOf(aiFile('lcm-lora-sd15'));
    return SdModelPaths(
      model: pathOf(aiFile('sd15')),
      loraDir: p.dirname(lora),
      loraName: p.basenameWithoutExtension(lora),
      taesd: taesd && isInstalled('taesd') ? pathOf(aiFile('taesd')) : null,
    );
  }
}

/// 처리 장치 하나 (실행 파일 + sd-cli --backend 값)
class SdDevice {
  final String exe;
  final String backend;
  final String label;
  const SdDevice(this.exe, this.backend, this.label);
  String get key => '${p.basename(p.dirname(exe))}:$backend';
}

/// 기기 안 엔진 (stable-diffusion.cpp 의 sd-cli 를 따로 띄움 - 메모리가 모자라 꺼져도 앱은 살아 있고, 취소는 프로세스 끝내기)
class LocalSdEngine implements ImageAiEngine {
  LocalSdEngine({required this.device, required this.models, this.threads = 0});
  final SdDevice device;
  final SdModelPaths models;
  final int threads;
  Process? _proc;
  bool _cancelled = false;

  @override
  String get label => trf('이 기기 ({0})', [device.label]);
  @override
  bool get leavesDevice => false;

  @override
  void cancel() {
    _cancelled = true;
    _proc?.kill();
  }

  @override
  Future<List<GeneratedImage>> generate(ImageGenRequest r, {required String outDir, required String baseName, AiProgress? onProgress}) async {
    _cancelled = false;
    await Directory(outDir).create(recursive: true);
    final seed = resolveSeed(r.seed);
    final req = ImageGenRequest(
      prompt: r.prompt,
      negative: r.negative,
      width: r.width,
      height: r.height,
      steps: r.steps,
      cfg: r.cfg,
      seed: seed,
      count: r.count,
      initImage: r.initImage,
      strength: r.strength,
      model: r.model,
    );
    final out = p.join(outDir, '${baseName}_%d.png');
    final args = sdCliArgs(req, models, out: out, backend: device.backend, threads: threads);
    final lines = await runSdCli(device.exe, args, onProgress: (prog) {
      final step = switch (prog.phase) {
        'load' => tr('모델 읽는 중'),
        'sample' => trf('그리는 중 {0}/{1}', [prog.step, prog.steps]),
        'decode' => tr('그림으로 바꾸는 중'),
        _ => tr('저장하는 중'),
      };
      onProgress?.call(prog.overall, step);
    }, onStart: (pr) => _proc = pr);
    if (_cancelled) throw ImageAiException(tr('취소했습니다'));
    final made = Directory(outDir)
        .listSync()
        .whereType<File>()
        .where((f) => RegExp('^${RegExp.escape(baseName)}_\\d+\\.png\$').hasMatch(p.basename(f.path)))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    if (made.isEmpty) throw ImageAiException(trf('그림을 만들지 못했습니다: {0}', [lines.join('\n')]));
    return [for (final (i, f) in made.indexed) GeneratedImage(f.path, seed + i)];
  }
}

/// sd-cli 를 돌리고 진행을 알린다. 실패하면 마지막 출력 몇 줄로 [ImageAiException]
Future<List<String>> runSdCli(String exe, List<String> args,
    {void Function(SdProgress)? onProgress, void Function(Process)? onStart}) async {
  final proc = await Process.start(exe, args, workingDirectory: p.dirname(exe));
  onStart?.call(proc);
  final tail = <String>[];
  var saved = false;
  void feed(String chunk) {
    if (chunk.contains('images saved')) saved = true;
    for (final piece in chunk.split(RegExp(r'[\r\n]+'))) {
      if (piece.trim().isEmpty) continue;
      final prog = parseSdProgress(piece);
      if (prog != null) {
        onProgress?.call(prog);
      } else {
        tail.add(piece.trim());
        if (tail.length > 8) tail.removeAt(0);
      }
    }
  }

  final a = proc.stdout.transform(const Utf8Decoder(allowMalformed: true)).listen(feed).asFuture<void>();
  final b = proc.stderr.transform(const Utf8Decoder(allowMalformed: true)).listen(feed).asFuture<void>();
  final code = await proc.exitCode;
  await Future.wait([a, b]);
  // 그림을 다 저장한 뒤 끝내면서 0 이 아닌 코드로 끝나는 일이 있다 (이 판의 sd-cli) - 저장했으면 성공으로 본다
  if (code != 0 && !saved) {
    final err = tail.where((l) => l.contains('[E]') || l.toLowerCase().contains('error')).toList();
    throw ImageAiException(trf('AI 엔진이 실패했습니다 ({0}): {1}', [code, (err.isEmpty ? tail : err).join('\n')]));
  }
  return tail;
}

/// 처리 장치 후보 (Windows: CUDA 판 · Vulkan 판의 GPU · CPU, Android: CPU)
Future<List<SdDevice>> sdDevices(AiStore store) async {
  final out = <SdDevice>[];
  final cuda = await store.sdCli(cuda: true);
  if (cuda != null) {
    await store.placeCudaRuntime();
    out.add(SdDevice(cuda, 'cuda0', 'NVIDIA CUDA'));
  }
  final exe = await store.sdCli();
  if (exe == null) return out;
  if (Platform.isWindows) {
    try {
      final r = await Process.run(exe, ['--list-devices'], workingDirectory: p.dirname(exe));
      final devs = parseSdDevices('${r.stdout}\n${r.stderr}');
      // Vulkan 장치 중 첫째 (보통 따로 단 그래픽카드)
      for (final (name, desc) in devs) {
        if (name.startsWith('vulkan')) {
          out.add(SdDevice(exe, name, 'Vulkan · $desc'));
          break;
        }
      }
    } catch (_) {}
  }
  out.add(SdDevice(exe, 'cpu', 'CPU'));
  return out;
}

/// 123: 진행 중인 AI 작업 (작업 알림 · 모니터링 · 화면이 함께 본다)
class AiJobs extends ChangeNotifier {
  static final instance = AiJobs();

  /// 지금 하는 일 (없으면 null) · 진행 (0~1) · 남은 장 수 · 예상 남은 시간
  String? title;
  double? progress;
  int remaining = 0;
  Duration? eta;
  ImageAiEngine? _engine;

  bool get busy => title != null;

  void start(String t, ImageAiEngine engine, int count) {
    title = t;
    _engine = engine;
    remaining = count;
    progress = 0;
    eta = null;
    notifyListeners();
  }

  void update({double? progress, int? remaining, Duration? eta, String? title}) {
    this.progress = progress ?? this.progress;
    this.remaining = remaining ?? this.remaining;
    this.eta = eta ?? this.eta;
    this.title = title ?? this.title;
    notifyListeners();
  }

  void finish() {
    title = null;
    progress = null;
    remaining = 0;
    eta = null;
    _engine = null;
    notifyListeners();
  }

  void cancel() => _engine?.cancel();

  /// 그리기 한 번 (한 번에 하나). 진행 · 남은 장 · 예상 시간을 알리고, 그림마다 옆에 json (프롬프트 · 시드 · 모델) 을 남긴다.
  Future<List<GeneratedImage>> run(ImageAiEngine engine, ImageGenRequest r, {required String outDir}) async {
    if (busy) throw ImageAiException(tr('이미 그리는 중입니다'));
    final started = DateTime.now();
    final stamp = started.toIso8601String().replaceAll(RegExp(r'[-:T]'), '').split('.').first;
    start(trf('AI 그림 ({0})', [engine.label]), engine, r.count);
    try {
      final made = await engine.generate(r, outDir: outDir, baseName: 'ai_$stamp', onProgress: (prog, step) {
        Duration? left;
        if (prog != null && prog > 0.05) {
          final spent = DateTime.now().difference(started);
          left = spent * ((1 - prog) / prog);
        }
        update(
          progress: prog,
          title: trf('AI 그림: {0}', [step]),
          remaining: prog == null ? null : (r.count - (prog * r.count).floor()).clamp(1, r.count),
          eta: left,
        );
      });
      for (final g in made) {
        try {
          await File('${p.withoutExtension(g.path)}.json').writeAsString(r.encode(engine: engine.label, actualSeed: g.seed));
        } catch (_) {}
      }
      return made;
    } finally {
      finish();
    }
  }

  /// 알림 · 모니터링에 보일 한 줄
  String? get statusLine {
    final t = title;
    if (t == null) return null;
    final left = eta == null ? '' : ' · ${trf('남은 약 {0}', [_dur(eta!)])}';
    return '$t${remaining > 1 ? ' · ${trf('남은 {0}장', [remaining])}' : ''}$left';
  }

  static String _dur(Duration d) => d.inMinutes >= 1 ? trf('{0}분', [d.inMinutes + (d.inSeconds % 60 >= 30 ? 1 : 0)]) : trf('{0}초', [d.inSeconds]);
}

/// 그릴 처리 장치. 'auto' 면 한 번 짧게 재서 (256×256 · 1단계) 가장 빠른 것을 기억한다 (장치 목록이 바뀌면 다시 잰다).
Future<SdDevice?> pickAiDevice(AppController c, AiStore store, {void Function(String step)? onStep}) async {
  final devices = await sdDevices(store);
  if (devices.isEmpty) return null;
  final s = c.settings;
  if (s.aiDevice != 'auto') return devices.where((d) => d.key == s.aiDevice).firstOrNull ?? devices.first;
  if (devices.length == 1) return devices.first;
  final signature = devices.map((d) => d.key).join(',');
  if (s.aiAutoDeviceFor == signature) {
    final known = devices.where((d) => d.key == s.aiAutoDevice).firstOrNull;
    if (known != null) return known;
  }
  final models = store.sd15Paths(taesd: s.aiTaesd);
  if (models == null) return devices.first;
  final tmp = await Directory.systemTemp.createTemp('jj_ai_probe_');
  SdDevice? best;
  Duration? bestTime;
  try {
    for (final d in devices) {
      onStep?.call(trf('가장 빠른 처리 장치를 찾는 중 (처음 한 번): {0}', [d.label]));
      final sw = Stopwatch()..start();
      try {
        await runSdCli(d.exe, sdCliArgs(const ImageGenRequest(prompt: 'test', width: 256, height: 256, steps: 1, seed: 1), models,
            out: p.join(tmp.path, 'probe.png'), backend: d.backend));
      } catch (_) {
        continue; // 이 장치는 안 됨 (메모리 부족 등)
      }
      sw.stop();
      if (bestTime == null || sw.elapsed < bestTime) {
        best = d;
        bestTime = sw.elapsed;
      }
    }
  } finally {
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
    onStep?.call('');
  }
  best ??= devices.last;
  final chosen = best;
  await c.updateSettings((x) => x
    ..aiAutoDevice = chosen.key
    ..aiAutoDeviceFor = signature);
  return chosen;
}
