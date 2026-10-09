import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../core/secret_gate.dart';
import '../core/sd_cli.dart';
import '../l10n/tr.dart';

/// 만든 그림 하나 (파일 · 실제 시드)
class GeneratedImage {
  final String path;
  final int seed;
  const GeneratedImage(this.path, this.seed);
}

class ImageAiException implements Exception {
  final String message;

  /// 엔진 원문 (화면에는 [자세히] 를 눌러야 보인다 - 150)
  final String detail;

  /// 사용자가 취소함 (오류가 아님)
  final bool cancelled;
  const ImageAiException(this.message, {this.detail = '', this.cancelled = false});
  @override
  String toString() => message;
}

/// 진행 (0 ~ 1, 모르면 null) 과 지금 하는 일
typedef AiProgress = void Function(double? progress, String step);

/// 123: 그림 만들기 엔진. 기기 안 (stable-diffusion.cpp) 과 사용자가 추가한 서버 · 인터넷 서비스가 같은 모양으로 쓰인다.
abstract class ImageAiEngine {
  /// 화면에 보일 이름
  String get label;

  /// 그림 · 프롬프트가 기기 밖으로 나가는지 (그러면 화면에 늘 알린다)
  bool get leavesDevice;

  /// [outDir] 에 [baseName]_1.png … 로 저장하고 돌려준다
  Future<List<GeneratedImage>> generate(ImageGenRequest r, {required String outDir, required String baseName, AiProgress? onProgress});

  void cancel();
}

/// 시드: 정하지 않았으면 (-1) 여기서 정해 결과에 남긴다 (다시 만들 수 있게)
int resolveSeed(int seed, [Random? random]) => seed >= 0 ? seed : (random ?? Random()).nextInt(1 << 31);

/// 사용자가 추가한 그림 서비스 · 자기 서버 (123). API 키는 설정 파일이 아니라 안전 저장소에 둔다 (124).
class AiService {
  final String id;
  final String name;
  final String url;

  /// 'a1111' Automatic1111 (Forge 포함) API · 'comfy' ComfyUI · 'openai' OpenAI 이미지 API 형식
  final String kind;

  /// 서버의 모델 (A1111 은 비워 두면 서버에 고른 것, ComfyUI 는 체크포인트 파일 이름, OpenAI 형식은 모델 이름)
  final String model;
  final String apiKey;
  const AiService({required this.id, required this.name, required this.url, required this.kind, this.model = '', this.apiKey = ''});

  static const kinds = ['a1111', 'comfy', 'openai'];

  String get label => name.isEmpty ? url : name;

  AiService copyWith({String? name, String? url, String? kind, String? model, String? apiKey}) => AiService(
        id: id,
        name: name ?? this.name,
        url: url ?? this.url,
        kind: kind ?? this.kind,
        model: model ?? this.model,
        apiKey: apiKey ?? this.apiKey,
      );

  /// 설정 파일에는 키를 쓰지 않는다 (있는지만)
  Map<String, Object?> toJson() => {'id': id, 'name': name, 'url': url, 'kind': kind, 'model': model, 'hasKey': apiKey.isNotEmpty};

  factory AiService.fromJson(Map j) => AiService(
        id: '${j['id']}',
        name: '${j['name'] ?? ''}',
        url: '${j['url'] ?? ''}',
        kind: kinds.contains(j['kind']) ? j['kind'] as String : 'a1111',
        model: '${j['model'] ?? ''}',
        apiKey: '${j['apiKey'] ?? ''}',
      );
}

/// 사용자가 추가한 서버 · 서비스로 그리기 (기기 밖으로 나감)
class RemoteImageEngine implements ImageAiEngine {
  RemoteImageEngine(this.service, {HttpClient? http}) : _http = http ?? HttpClient();
  final AiService service;
  final HttpClient _http;
  bool _cancel = false;

  @override
  String get label => service.label;
  @override
  bool get leavesDevice => true;

  @override
  void cancel() => _cancel = true;

  Uri _uri(String path, [Map<String, String>? q]) {
    final base = service.url.endsWith('/') ? service.url.substring(0, service.url.length - 1) : service.url;
    return Uri.parse('$base$path').replace(queryParameters: q);
  }

  void _auth(HttpClientRequest req) {
    final k = service.apiKey;
    if (k.isEmpty) return;
    // A1111 의 --api-auth 는 "아이디:비밀번호" (Basic), 그 밖은 Bearer 키
    req.headers.set(HttpHeaders.authorizationHeader,
        service.kind == 'a1111' && k.contains(':') ? 'Basic ${base64Encode(utf8.encode(k))}' : 'Bearer $k');
  }

  Future<dynamic> _json(String method, Uri uri, [Object? body]) async {
    if (_cancel) throw ImageAiException(tr('취소했습니다'));
    final req = await _http.openUrl(method, uri);
    _auth(req);
    if (body != null) {
      final bytes = utf8.encode(jsonEncode(body));
      req.headers.contentType = ContentType.json;
      req.contentLength = bytes.length;
      req.add(bytes);
    }
    final res = await req.close();
    final text = await res.transform(utf8.decoder).join();
    if (res.statusCode >= 300) throw ImageAiException(trf('서버가 거절했습니다 ({0}): {1}', [res.statusCode, _short(text)]));
    return text.isEmpty ? null : jsonDecode(text);
  }

  static String _short(String s) => s.length > 300 ? '${s.substring(0, 300)}…' : s;

  @override
  Future<List<GeneratedImage>> generate(ImageGenRequest r, {required String outDir, required String baseName, AiProgress? onProgress}) async {
    _cancel = false;
    // 124: 저장된 API 키를 쓰기 전에 (마스터 비밀번호를 정해 두었으면)
    if (service.apiKey.isNotEmpty && !await SecretGate.pass(force: true)) throw ImageAiException(tr(secretGateMessage));
    final seed = resolveSeed(r.seed);
    onProgress?.call(null, trf('{0} 에 보내는 중', [service.label]));
    final List<List<int>> images = switch (service.kind) {
      'comfy' => await _comfy(r, seed, onProgress),
      'openai' => await _openai(r),
      _ => await _a1111(r, seed),
    };
    await Directory(outDir).create(recursive: true);
    return [
      for (final (i, bytes) in images.indexed)
        GeneratedImage(await _save(outDir, '${baseName}_${i + 1}.png', bytes), seed + i),
    ];
  }

  static Future<String> _save(String dir, String name, List<int> bytes) async {
    final f = File(p.join(dir, name));
    await f.writeAsBytes(bytes, flush: true);
    return f.path;
  }

  Future<List<List<int>>> _a1111(ImageGenRequest r, int seed) async {
    final body = <String, Object?>{
      'prompt': r.prompt,
      'negative_prompt': r.negative,
      'width': r.width,
      'height': r.height,
      'steps': r.steps,
      'cfg_scale': r.cfg,
      'seed': seed,
      'batch_size': r.count,
      if (service.model.isNotEmpty) 'override_settings': {'sd_model_checkpoint': service.model},
      if (r.imageToImage) 'init_images': [base64Encode(await File(r.initImage!).readAsBytes())],
      if (r.imageToImage) 'denoising_strength': r.strength,
    };
    final j = await _json('POST', _uri(r.imageToImage ? '/sdapi/v1/img2img' : '/sdapi/v1/txt2img'), body);
    final list = (j is Map ? j['images'] : null) as List?;
    if (list == null || list.isEmpty) throw ImageAiException(tr('서버가 그림을 돌려주지 않았습니다'));
    return [for (final x in list) base64Decode('$x'.split(',').last)];
  }

  Future<List<List<int>>> _openai(ImageGenRequest r) async {
    if (r.imageToImage) throw ImageAiException(tr('이 서비스 방식은 그림 → 그림을 지원하지 않습니다'));
    final j = await _json('POST', _uri('/v1/images/generations'), {
      if (service.model.isNotEmpty) 'model': service.model,
      'prompt': r.negative.isEmpty ? r.prompt : '${r.prompt}\n(avoid: ${r.negative})',
      'n': r.count,
      'size': '${r.width}x${r.height}',
      'response_format': 'b64_json',
    });
    final data = (j is Map ? j['data'] : null) as List?;
    if (data == null || data.isEmpty) throw ImageAiException(tr('서버가 그림을 돌려주지 않았습니다'));
    return [for (final x in data) base64Decode('${(x as Map)['b64_json']}')];
  }

  /// ComfyUI: 기본 작업 흐름 (체크포인트 → 글 → KSampler → VAE → 저장) 을 보내고 끝날 때까지 기다린다
  Future<List<List<int>>> _comfy(ImageGenRequest r, int seed, AiProgress? onProgress) async {
    String? uploaded;
    if (r.imageToImage) uploaded = await _comfyUpload(r.initImage!);
    final flow = comfyWorkflow(r, seed, checkpoint: service.model, initImage: uploaded);
    final j = await _json('POST', _uri('/prompt'), {'prompt': flow, 'client_id': 'jj_mkvmaker'});
    final id = '${(j as Map)['prompt_id']}';
    for (var i = 0; i < 1800; i++) {
      if (_cancel) {
        try {
          await _json('POST', _uri('/interrupt'));
        } catch (_) {}
        throw ImageAiException(tr('취소했습니다'));
      }
      await Future<void>.delayed(const Duration(seconds: 1));
      onProgress?.call(null, trf('{0} 에서 그리는 중 ({1}초)', [service.label, i + 1]));
      final h = await _json('GET', _uri('/history/$id'));
      final entry = h is Map ? h[id] : null;
      final outputs = entry is Map ? entry['outputs'] : null;
      if (outputs is! Map || outputs.isEmpty) continue;
      final out = <List<int>>[];
      for (final node in outputs.values) {
        for (final img in ((node as Map)['images'] as List? ?? const [])) {
          final m = img as Map;
          out.add(await _bytes(_uri('/view', {'filename': '${m['filename']}', 'subfolder': '${m['subfolder'] ?? ''}', 'type': '${m['type'] ?? 'output'}'})));
        }
      }
      if (out.isNotEmpty) return out;
    }
    throw ImageAiException(tr('서버가 너무 오래 답하지 않습니다'));
  }

  Future<List<int>> _bytes(Uri uri) async {
    final req = await _http.getUrl(uri);
    _auth(req);
    final res = await req.close();
    final b = BytesBuilder(copy: false);
    await for (final c in res) {
      b.add(c);
    }
    if (res.statusCode >= 300) throw ImageAiException(trf('그림을 받을 수 없습니다 ({0})', [res.statusCode]));
    return b.takeBytes();
  }

  Future<String> _comfyUpload(String path) async {
    final boundary = 'jj${DateTime.now().microsecondsSinceEpoch}';
    final req = await _http.postUrl(_uri('/upload/image'));
    _auth(req);
    req.headers.set(HttpHeaders.contentTypeHeader, 'multipart/form-data; boundary=$boundary');
    final head = utf8.encode('--$boundary\r\nContent-Disposition: form-data; name="image"; filename="${p.basename(path)}"\r\n'
        'Content-Type: application/octet-stream\r\n\r\n');
    final tail = utf8.encode('\r\n--$boundary\r\nContent-Disposition: form-data; name="overwrite"\r\n\r\ntrue\r\n--$boundary--\r\n');
    final data = await File(path).readAsBytes();
    req.contentLength = head.length + data.length + tail.length;
    req
      ..add(head)
      ..add(data)
      ..add(tail);
    final res = await req.close();
    final text = await res.transform(utf8.decoder).join();
    if (res.statusCode >= 300) throw ImageAiException(trf('그림을 올릴 수 없습니다 ({0})', [res.statusCode]));
    return '${(jsonDecode(text) as Map)['name']}';
  }
}

/// ComfyUI 에 보낼 기본 작업 흐름 (API 형식)
Map<String, Object?> comfyWorkflow(ImageGenRequest r, int seed, {required String checkpoint, String? initImage}) {
  final latent = initImage == null
      ? {'class_type': 'EmptyLatentImage', 'inputs': {'width': r.width, 'height': r.height, 'batch_size': r.count}}
      : {'class_type': 'VAEEncode', 'inputs': {'pixels': ['10', 0], 'vae': ['4', 2]}};
  return {
    '4': {'class_type': 'CheckpointLoaderSimple', 'inputs': {'ckpt_name': checkpoint}},
    '6': {'class_type': 'CLIPTextEncode', 'inputs': {'text': r.prompt, 'clip': ['4', 1]}},
    '7': {'class_type': 'CLIPTextEncode', 'inputs': {'text': r.negative, 'clip': ['4', 1]}},
    '5': latent,
    if (initImage != null) '10': {'class_type': 'LoadImage', 'inputs': {'image': initImage}},
    '3': {
      'class_type': 'KSampler',
      'inputs': {
        'seed': seed,
        'steps': r.steps,
        'cfg': r.cfg,
        'sampler_name': 'euler',
        'scheduler': 'normal',
        'denoise': initImage == null ? 1.0 : r.strength,
        'model': ['4', 0],
        'positive': ['6', 0],
        'negative': ['7', 0],
        'latent_image': ['5', 0],
      },
    },
    '8': {'class_type': 'VAEDecode', 'inputs': {'samples': ['3', 0], 'vae': ['4', 2]}},
    '9': {'class_type': 'SaveImage', 'inputs': {'filename_prefix': 'jj_mkvmaker', 'images': ['8', 0]}},
  };
}
