import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../platform/common/onnx_external.dart';

/// 내려받을 AI 모델
class ModelSpec {
  final String id;
  final String label;

  /// 모델 폴더 아래 상대 경로의 폴더
  final String folder;
  final List<ModelFile> files;

  const ModelSpec(this.id, this.label, this.folder, this.files);

  int get totalBytes => files.fold(0, (a, f) => a + f.bytes);
  String get sizeLabel => '${(totalBytes / 1e6).round()}MB';
}

class ModelFile {
  final String name;
  final String url;

  /// 대략적인 크기 (진행률 표시용)
  final int bytes;

  const ModelFile(this.name, this.url, this.bytes);
}

const _whisperBase = 'https://huggingface.co/ggerganov/whisper.cpp/resolve/main';
const _nllbBase = 'https://huggingface.co/Xenova/nllb-200-distilled-600M/resolve/main';

/// 음성인식 모델
const whisperModels = [
  ModelSpec('whisper-base', 'Whisper base (빠름)', 'whisper',
      [ModelFile('ggml-base.bin', '$_whisperBase/ggml-base.bin', 147951465)]),
  ModelSpec('whisper-small', 'Whisper small (정확)', 'whisper',
      [ModelFile('ggml-small.bin', '$_whisperBase/ggml-small.bin', 487601967)]),
];

/// 번역 모델 (NLLB-200 600M, int8)
const nllbModel = ModelSpec('nllb-600m', 'NLLB-200 번역 (600M)', 'nllb-200-distilled-600M', [
  ModelFile('tokenizer.json', '$_nllbBase/tokenizer.json', 17331176),
  ModelFile('encoder_model_quantized.onnx', '$_nllbBase/onnx/encoder_model_quantized.onnx', 419100000),
  ModelFile('decoder_model_merged_quantized.onnx',
      '$_nllbBase/onnx/decoder_model_merged_quantized.onnx', 475500000),
]);

/// 모델 저장소 (처음 사용할 때 인터넷에서 내려받음 - 다운로드만, 업로드 없음)
///
/// 위치: 환경 변수 JJ_MKVMAKER_MODELS → 프로그램 폴더\models (휴대용, 쓸 수 있을 때)
///       → 앱 데이터 폴더\models
class ModelStore {
  String? _dir;

  ModelStore([this._dir]);

  Future<String> directory() async {
    if (_dir != null) return _dir!;
    // 이전 이름(JJ_CAPCUT_MODELS)도 인식
    final env = Platform.environment['JJ_MKVMAKER_MODELS'] ?? Platform.environment['JJ_CAPCUT_MODELS'];
    if (env != null && env.isNotEmpty) return _dir = env;
    final portable = p.join(p.dirname(Platform.resolvedExecutable), 'models');
    try {
      await Directory(portable).create(recursive: true);
      final probe = File(p.join(portable, '.jj_write_test'));
      await probe.writeAsString('x');
      await probe.delete();
      return _dir = portable;
    } catch (_) {
      return _dir = p.join((await getApplicationSupportDirectory()).path, 'models');
    }
  }

  Future<String> folderOf(ModelSpec m) async => p.join(await directory(), m.folder);

  Future<String> pathOf(ModelSpec m, [int file = 0]) async =>
      p.join(await folderOf(m), m.files[file].name);

  Future<bool> isInstalled(ModelSpec m) async {
    final dir = await folderOf(m);
    for (final f in m.files) {
      if (!_present(p.join(dir, f.name))) return false;
    }
    return true;
  }

  /// 파일이 있거나, 외부 데이터 형식으로 바꿔 둔 것이 있으면 (Android 는 바꾼 뒤 원래 파일을 지운다)
  static bool _present(String path) => File(path).existsSync() || OnnxExternal.isReady(path);

  /// 없는 파일만 내려받는다. [onProgress] 0.0~1.0, [isCancelled] 가 true 면 중단.
  Future<void> download(
    ModelSpec m, {
    void Function(double)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final dir = await folderOf(m);
    await Directory(dir).create(recursive: true);
    final total = m.totalBytes;
    var done = 0;
    final client = HttpClient();
    try {
      for (final f in m.files) {
        final target = File(p.join(dir, f.name));
        if (_present(target.path)) {
          done += f.bytes;
          continue;
        }
        final part = File('${target.path}.part');
        final req = await client.getUrl(Uri.parse(f.url));
        final res = await req.close();
        if (res.statusCode != 200) {
          throw HttpException('모델을 내려받을 수 없습니다 (${res.statusCode}): ${f.url}');
        }
        final sink = part.openWrite();
        var got = 0;
        try {
          await for (final chunk in res) {
            if (isCancelled?.call() ?? false) throw const _Cancelled();
            sink.add(chunk);
            got += chunk.length;
            onProgress?.call(((done + got) / total).clamp(0.0, 1.0));
          }
        } finally {
          await sink.close();
        }
        await part.rename(target.path);
        done += f.bytes;
      }
      onProgress?.call(1.0);
    } finally {
      client.close(force: true);
    }
  }
}

class _Cancelled implements Exception {
  const _Cancelled();
  @override
  String toString() => '사용자가 취소했습니다.';
}
