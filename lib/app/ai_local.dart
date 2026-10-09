import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
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

  /// 받을 때 SHA-256 이 공식 값과 같았는지 (표시 파일에 남김) - 화면에 "확인됨"
  bool isVerified(AiFile f) {
    try {
      return (jsonDecode(_mark(f).readAsStringSync()) as Map)['sha256'] == f.sha256;
    } catch (_) {
      return false;
    }
  }

  bool isFileInstalled(AiFile f) => _mark(f).existsSync() && FileSystemEntity.typeSync(pathOf(f)) != FileSystemEntityType.notFound;

  /// 받는 중인 것 (id → 0~1, 모르면 null)
  /// 받는 중인 것 (id → 0~1, 모르면 null)
  final progress = <String, double?>{};

  /// 받은 바이트 · 전체 · 이번에 받기 시작한 때와 그때 이미 있던 바이트 (속도 · 남은 시간)
  final received = <String, int>{};
  final totals = <String, int>{};
  final _started = <String, (DateTime, int)>{};

  /// [installAll] 로 차례를 기다리는 것 (149-②: "차례 기다림")
  final queued = <String>{};

  /// 연결이 끊겨 다시 잇는 중 (몇 번째)
  final retrying = <String, int>{};

  /// 마지막 실패 (id → 쉬운 말). 다시 받으면 지운다
  final failures = <String, String>{};
  final _cancel = <String>{};

  void cancel(String id) {
    _cancel.add(id);
    queued.remove(id);
    notifyListeners();
  }

  /// 받기 (SHA-256 확인). 저장 공간이 모자라면 먼저 알린다. zip (실행 파일) 은 푼다.
  Future<void> install(String id) => installFile(aiFile(id));

  /// 여러 개를 차례로 (기다리는 것은 [queued] 로 보인다). 하나가 실패하면 멈추고 알린다
  Future<void> installAll(List<AiFile> files) async {
    final todo = [for (final f in files) if (!isFileInstalled(f) && !progress.containsKey(f.id)) f];
    queued.addAll(todo.map((f) => f.id));
    notifyListeners();
    try {
      for (final f in todo) {
        if (!queued.contains(f.id)) continue; // 기다리는 동안 취소
        queued.remove(f.id);
        await installFile(f);
      }
    } finally {
      queued.removeAll(todo.map((f) => f.id));
      notifyListeners();
    }
  }

  /// 받을 때 필요한 공간 (zip 은 푸는 자리까지) - 이미 받아 둔 조각만큼은 빼고
  int neededSpace(AiFile f) {
    final part = _partOf(f);
    final have = part.existsSync() ? part.lengthSync() : 0;
    return (f.kind == 'engine' ? f.size * 3 : f.size) - have;
  }

  File _partOf(AiFile f) => File('${pathOf(f)}.part${f.kind == 'engine' ? '.zip' : ''}');

  /// [install] 의 본체 (시험은 카탈로그 밖의 파일로).
  /// 149: 끊기면 받은 곳부터 이어 받고 (조각 파일을 남겨 둠), 몇 번 저절로 다시 잇는다. 실패는 쉬운 말로 (주소는 보이지 않음).
  Future<void> installFile(AiFile f, {int retries = 5, Duration retryWait = const Duration(seconds: 3)}) async {
    final id = f.id;
    if (progress.containsKey(id)) return;
    _cancel.remove(id);
    failures.remove(id);
    await Directory(root).create(recursive: true);
    final free = await diskSpace(root);
    final need = neededSpace(f) + (200 << 20); // 여유 200MB
    if (free != null && free.$1 < need) {
      throw ImageAiException(trf('저장 공간이 모자랍니다: {0} 이 필요한데 {1} 남았습니다', [_gb(need), _gb(free.$1)]));
    }
    final part = _partOf(f);
    progress[id] = 0;
    notifyListeners();
    try {
      await part.parent.create(recursive: true);
      for (var attempt = 0;; attempt++) {
        try {
          await _download(f, part);
          break;
        } on ImageAiException {
          rethrow; // 취소 · 손상 (다시 받아도 같음)
        } catch (e) {
          if (_cancel.contains(id) || attempt >= retries) {
            final msg = tr('연결이 끊겼습니다. [이어 받기] 를 누르면 받은 곳부터 이어 받습니다');
            failures[id] = msg;
            throw ImageAiException(msg);
          }
          retrying[id] = attempt + 1;
          notifyListeners();
          await Future<void>.delayed(retryWait * (attempt + 1));
        }
      }
      retrying.remove(id);
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
    } finally {
      progress.remove(id);
      received.remove(id);
      totals.remove(id);
      _started.remove(id);
      retrying.remove(id);
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
    try {
      final part = _partOf(f);
      if (part.existsSync()) part.deleteSync();
    } catch (_) {}
    notifyListeners();
  }

  static String _gb(int b) => b >= 1 << 30 ? '${(b / (1 << 30)).toStringAsFixed(1)}GB' : '${(b / (1 << 20)).round()}MB';
  static String sizeText(int b) => _gb(b);

  /// 진행 한 줄: "58% · 2.3GB / 4.0GB · 남은 약 5분" (149-①)
  String? progressText(String id) {
    if (queued.contains(id)) return tr('차례 기다림');
    if (!progress.containsKey(id)) return null;
    final got = received[id] ?? 0, total = totals[id] ?? 0;
    final retry = retrying[id];
    final left = eta(id);
    return [
      if (total > 0) '${(got * 100 / total).floor()}%',
      if (total > 0) '${_gb(got)} / ${_gb(total)}',
      if (left != null) trf('남은 약 {0}', [AiJobs.durationText(left)]),
      if (retry != null) trf('연결이 끊겨 다시 잇는 중 ({0}번째)', [retry]),
    ].join(' · ');
  }

  /// 남은 시간 (이번에 받은 속도로)
  Duration? eta(String id) {
    final s = _started[id];
    final got = received[id], total = totals[id];
    if (s == null || got == null || total == null || total <= 0) return null;
    final secs = DateTime.now().difference(s.$1).inMilliseconds / 1000;
    final rate = (got - s.$2) / (secs <= 0 ? 1 : secs);
    if (secs < 3 || rate <= 0) return null;
    return Duration(seconds: ((total - got) / rate).round());
  }

  /// 받는 중인 것을 한 줄로 (작업 알림 - 화면이 꺼져도 계속 받는 동안)
  String? get statusLine {
    if (progress.isEmpty) return null;
    final id = progress.keys.first;
    final name = aiCatalog.where((f) => f.id == id).firstOrNull?.name ?? id;
    final more = queued.length;
    return '${trf('AI 모델 받는 중: {0}', [tr(name)])} · ${progressText(id) ?? ''}'
        '${more > 0 ? ' · ${trf('다음 {0}개 기다림', [more])}' : ''}';
  }

  /// 조각 파일 [out] 이 있으면 그 뒤부터 (Range) 받는다. 서버가 이어 주지 않으면 처음부터.
  /// SHA-256 은 이미 받은 조각까지 합쳐 확인한다.
  Future<void> _download(AiFile f, File out) async {
    var have = out.existsSync() ? out.lengthSync() : 0;
    if (have > f.size) {
      out.deleteSync();
      have = 0;
    }
    final req = await _http.getUrl(Uri.parse(f.url));
    if (have > 0) req.headers.set(HttpHeaders.rangeHeader, 'bytes=$have-');
    final res = await req.close();
    final whole = res.statusCode == 416 && have == f.size; // 이미 다 받아 둠 - 확인만
    if (whole) {
      await res.drain<void>();
    } else if (res.statusCode == 416) {
      // 조각이 서버 파일과 맞지 않음 (크기가 다름) - 조각을 버리고 처음부터 (다시 시도만 반복하다 막히지 않게)
      await res.drain<void>();
      if (out.existsSync()) out.deleteSync();
      throw HttpException('range not satisfiable - restart');
    } else if (res.statusCode == 200) {
      have = 0; // 이어 주지 않음 - 처음부터
    } else if (res.statusCode == 206 && contentRangeStart(res.headers.value(HttpHeaders.contentRangeHeader)) != have) {
      // CDN 이 다른 범위를 줌 - 섞이지 않게 조각을 버리고 처음부터
      await res.drain<void>();
      if (out.existsSync()) out.deleteSync();
      throw HttpException('unexpected range - restart');
    } else if (res.statusCode != 206) {
      await res.drain<void>();
      throw HttpException('status ${res.statusCode}'); // 다시 시도 대상 (주소는 사용자에게 보이지 않음)
    }
    final total = f.size;
    final hash = AccumulatorSink<Digest>();
    final hasher = sha256.startChunkedConversion(hash);
    if (have > 0) {
      await for (final c in out.openRead(0, have)) {
        hasher.add(c);
      }
    }
    received[f.id] = have;
    totals[f.id] = total;
    _started[f.id] = (DateTime.now(), have);
    notifyListeners();
    final sink = out.openWrite(mode: have > 0 ? FileMode.append : FileMode.write);
    var done = have;
    var lastNotify = DateTime.now();
    try {
      if (!whole) {
        await for (final chunk in res) {
          if (_cancel.contains(f.id)) throw ImageAiException(tr('취소했습니다'));
          sink.add(chunk);
          hasher.add(chunk);
          done += chunk.length;
          received[f.id] = done;
          progress[f.id] = total > 0 ? done / total : null;
          if (DateTime.now().difference(lastNotify).inMilliseconds > 250) {
            lastNotify = DateTime.now();
            notifyListeners();
          }
        }
      }
    } finally {
      await sink.flush();
      await sink.close();
      hasher.close();
    }
    if (done < total) throw HttpException('short read $done/$total'); // 끊김 - 이어 받기
    if (hash.events.single.toString() != f.sha256) {
      await out.delete();
      failures[f.id] = tr('파일이 깨졌습니다 · [다시 받기] 를 눌러 주세요');
      throw ImageAiException(trf('받은 파일이 손상되었습니다 (SHA-256 다름): {0}', [f.name]));
    }
  }

  // ───────── 실행 파일 ─────────

  /// sd-cli: Android 는 앱에 들어 있는 것 (libsdcli.so - 앱 데이터 폴더의 파일은 실행할 수 없음), Windows 는 받은 것
  Future<String?> sdCli({bool cuda = false}) async {
    if (Platform.isAndroid) {
      // 156: Android 에는 CUDA 판이 없다 (같은 libsdcli.so 를 CUDA 로 잘못 세면 GPU 가 있는 줄 알고 사진용 모델을 찾았다)
      if (cuda) return null;
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

/// Content-Range ("bytes 120000-299999/300000") 의 시작 (모르면 null)
int? contentRangeStart(String? header) {
  final m = RegExp(r'bytes\s+(\d+)-').firstMatch(header ?? '');
  return m == null ? null : int.parse(m.group(1)!);
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
    final List<String> lines;
    try {
      lines = await runSdCli(device.exe, args, onProgress: (prog) {
        final step = switch (prog.phase) {
          // 152: 읽는 동안은 남은 시간을 모른다
          'load' => tr('모델 읽는 중 …'),
          'sample' => trf('그리는 중 {0}/{1}', [prog.step, prog.steps]),
          'decode' => tr('그림으로 바꾸는 중'),
          _ => tr('저장하는 중'),
        };
        onProgress?.call(prog.overall, step);
      }, onStart: (pr) => _proc = pr);
    } catch (_) {
      // 150: 취소로 엔진을 끝낸 것은 실패가 아니다
      if (_cancelled) throw ImageAiException(tr('취소했습니다'), cancelled: true);
      rethrow;
    }
    if (_cancelled) throw ImageAiException(tr('취소했습니다'), cancelled: true);
    final made = Directory(outDir)
        .listSync()
        .whereType<File>()
        .where((f) => RegExp('^${RegExp.escape(baseName)}_\\d+\\.png\$').hasMatch(p.basename(f.path)))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    if (made.isEmpty) throw ImageAiException(trf('그림을 만들지 못했습니다: {0}', [lines.join('\n')]));
    // 156-2: 정한 크기가 아니면 (바탕 그림을 그대로 돌려준 것 등) 엔진이 그리지 못한 것
    for (final f in made) {
      if (!sizeMatches(f.readAsBytesSync(), r.width, r.height)) {
        for (final x in made) {
          try {
            x.deleteSync();
          } catch (_) {}
        }
        throw ImageAiException(tr('AI 엔진이 그림을 그리지 못했습니다 (처리 장치를 바꿔 보세요)'), detail: lines.join('\n'));
      }
    }
    return [for (final (i, f) in made.indexed) GeneratedImage(f.path, seed + i)];
  }
}

/// 그림 [bytes] 가 [w]×[h] 인지 (머리만 읽음)
bool sizeMatches(Uint8List bytes, int w, int h) {
  final info = img.findDecoderForData(bytes)?.startDecode(bytes);
  return info != null && info.width == w && info.height == h;
}

/// sd-cli 기록 중 결과를 믿을 수 없게 만드는 실패 (업스케일러 · 장치 · 모델을 만들지 못함)
bool isSdFatalLine(String line) {
  final l = line.toLowerCase();
  return const [
    'new_upscaler_ctx failed',
    'upscale failed',
    'backend config failed',
    'failed to initialize',
    'new_sd_ctx_t failed',
  ].any(l.contains);
}

/// sd-cli 실행기 (시험에서 가짜 엔진으로 바꿀 수 있게)
typedef SdRunner = Future<List<String>> Function(String exe, List<String> args,
    {void Function(SdProgress)? onProgress, void Function(Process)? onStart});

/// sd-cli 를 돌리고 진행을 알린다. 실패하면 마지막 출력 몇 줄로 [ImageAiException]
Future<List<String>> runSdCli(String exe, List<String> args,
    {void Function(SdProgress)? onProgress, void Function(Process)? onStart}) async {
  final proc = await Process.start(exe, args, workingDirectory: p.dirname(exe));
  onStart?.call(proc);
  final tail = <String>[];
  final fatal = <String>[];
  var saved = false;
  void feed(String chunk) {
    if (chunk.contains('images saved')) saved = true;
    for (final piece in chunk.split(RegExp(r'[\r\n]+'))) {
      if (piece.trim().isEmpty) continue;
      if (isSdFatalLine(piece)) fatal.add(piece.trim());
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
  // 156-2: 업스케일러 · 장치를 만들지 못해도 sd-cli 는 원본을 저장하고 0 으로 끝난다 - 기록으로 실패를 알아챈다
  if (fatal.isNotEmpty) {
    throw ImageAiException(tr('AI 엔진이 해상도를 올리거나 그리지 못했습니다 (처리 장치를 바꿔 보세요)'), detail: fatal.join('\n'));
  }
  // 그림을 다 저장한 뒤 끝내면서 0 이 아닌 코드로 끝나는 일이 있다 (이 판의 sd-cli) - 저장했으면 성공으로 본다
  if (code != 0 && !saved) {
    final err = tail.where((l) => l.contains('[E]') || l.toLowerCase().contains('error')).toList();
    // 150: 쉬운 말 한 줄, 엔진 원문은 [자세히] 에
    throw ImageAiException(trf('AI 엔진이 멈췄습니다 (코드 {0}). 메모리가 모자라거나 파일이 깨졌을 수 있습니다', [code]),
        detail: (err.isEmpty ? tail : err).join('\n'));
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
  void Function()? _cancelTask;

  bool get busy => title != null;

  /// 157: 마지막으로 끝난 일 (작업 현황에 "✓ 4장 저장: 폴더 [열기]") - 다음 일을 시작하면 지운다
  String? lastDone;
  String? lastDoneDir;

  /// 176: 끝난 일을 다시 볼 것 (화면을 떠나 끝난 한 장 해상도 올리기 → 비교 · 저장). 작업 현황의 [보기]
  Future<void> Function()? lastDoneView;
  void Function()? _lastDoneDispose;

  /// [dispose]: 다음 일을 시작하거나 다른 끝난 일로 바뀔 때 (남겨 둔 임시 결과 지우기 등)
  void done(String text, {String? dir, Future<void> Function()? view, void Function()? dispose}) {
    _clearDone();
    lastDone = text;
    lastDoneDir = dir;
    lastDoneView = view;
    _lastDoneDispose = dispose;
    notifyListeners();
  }

  /// [보기] 를 한 번 쓰면 (비교 화면에서 저장 · 버림) 지운다
  void clearDoneView() {
    lastDoneView = null;
    _lastDoneDispose = null;
    notifyListeners();
  }

  void _clearDone() {
    _lastDoneDispose?.call();
    _lastDoneDispose = null;
    lastDoneView = null;
    lastDone = null;
    lastDoneDir = null;
  }

  void start(String t, ImageAiEngine engine, int count) {
    title = t;
    _engine = engine;
    total = count;
    remaining = count;
    progress = 0;
    eta = null;
    _clearDone();
    notifyListeners();
  }

  void update({double? progress, int? remaining, Duration? eta, String? title}) {
    this.progress = progress ?? this.progress;
    this.remaining = remaining ?? this.remaining;
    this.eta = eta ?? this.eta;
    this.title = title ?? this.title;
    notifyListeners();
  }

  /// 151: 지금 쓰는 받은 파일 (그동안은 [지우기] 를 끈다)
  Set<String> inUse = const {};

  void finish() {
    inUse = const {};
    title = null;
    progress = null;
    total = 0;
    remaining = 0;
    eta = null;
    _engine = null;
    notifyListeners();
  }

  void cancel() {
    _engine?.cancel();
    _cancelTask?.call();
  }

  /// 121: 여러 장 작업 (폴더 · ZIP 전체 해상도 올리기 등) 을 한 번에 하나로. [body] 는 i 번째 장을 하고 진행 (0~1) 을 알린다.
  /// 남은 장 · 예상 시간을 알림 · 작업 현황에 보이고, [onCancel] 로 지금 장을 멈춘다. 끝낸 장 수를 돌려준다.
  Future<int> runTask(String title, int count, Future<void> Function(int i, void Function(double? p) progress) body,
      {required void Function() onCancel, Set<String> uses = const {}}) async {
    if (busy) throw ImageAiException(tr('이미 작업 중입니다'));
    inUse = uses;
    _clearDone();
    var stop = false;
    this.title = title;
    total = count;
    remaining = count;
    progress = 0;
    eta = null;
    _cancelTask = () {
      stop = true;
      onCancel();
    };
    notifyListeners();
    final started = DateTime.now();
    var done = 0;
    try {
      for (var i = 0; i < count && !stop; i++) {
        await body(i, (pp) {
          final overall = (i + (pp ?? 0)) / count;
          final spent = DateTime.now().difference(started);
          update(
            progress: overall,
            remaining: count - i,
            eta: overall > 0.02 ? spent * ((1 - overall) / overall) : null,
          );
        });
        done++;
      }
    } finally {
      _cancelTask = null;
      finish();
    }
    return done;
  }

  /// 그리기 한 번 (한 번에 하나). 진행 · 남은 장 · 예상 시간을 알리고, 그림마다 옆에 json (프롬프트 · 시드 · 모델) 을 남긴다.
  Future<List<GeneratedImage>> run(ImageAiEngine engine, ImageGenRequest r, {required String outDir}) async {
    if (busy) throw ImageAiException(tr('이미 그리는 중입니다'));
    final started = DateTime.now();
    final stamp = started.toIso8601String().replaceAll(RegExp(r'[-:T]'), '').split('.').first;
    start(trf('AI 그림 ({0})', [engine.label]), engine, r.count);
    if (engine is LocalSdEngine) inUse = {...sd15LcmFiles, 'taesd', 'engine-vulkan', 'engine-cuda', 'engine-cudart'};
    try {
      final made = await engine.generate(r, outDir: outDir, baseName: 'ai_$stamp', onProgress: (prog, step) {
        Duration? left;
        // 152: 모델을 읽는 동안 (0.1 까지) 은 남은 시간을 모른다
        if (prog != null && prog > 0.12) {
          final spent = DateTime.now().difference(started);
          left = spent * ((1 - prog) / prog);
        }
        // update 는 null 을 무시하므로 직접 지운다 (읽는 동안 지난 "남은 약 0초" 가 남아 있었다)
        eta = left;
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
    // 161: 여러 장이면 "10장 중 3장째" (알림 · 작업 현황 · 그림 화면)
    final at = total > 1 ? ' · ${trf('{0}장 중 {1}장째', [total, (total - remaining + 1).clamp(1, total)])}' : '';
    return '$t$at$left';
  }

  /// 161: 이번 작업의 장 수 (남은 장 [remaining] 과 함께 "n장 중 m장째")
  int total = 0;

  static String durationText(Duration d) => _dur(d);

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
