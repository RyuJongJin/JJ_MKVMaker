import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jj_mkvmaker/platform/common/onnx_external.dart';
import 'package:path/path.dart' as p;

/// 실제 NLLB 모델을 외부 데이터 형식으로 바꿔 본다 (모델이 없으면 건너뜀).
/// 바꾼 모델이 원래와 같은 결과를 내는지는 tool/check_onnx_external.py 로 확인한다.
void main() {
  final dir = p.join(Platform.environment['JJ_MKVMAKER_MODELS'] ?? r'M:\jj_MKVMaker\models', 'nllb-200-distilled-600M');
  final out = Platform.environment['JJ_ONNX_EXT_OUT'];
  test('ONNX 외부 데이터로 바꾸기', () {
    final tmp = out ?? Directory.systemTemp.createTempSync('onnx_ext').path;
    // 바꾼 모델 (약 1.1GB) 은 확인용으로 폴더를 정했을 때만 남긴다
    if (out == null) addTearDown(() => Directory(tmp).deleteSync(recursive: true));
    for (final f in ['encoder_model_quantized.onnx', 'decoder_model_merged_quantized.onnx']) {
      final src = p.join(dir, f);
      final dst = OnnxExternal.externalPath(p.join(tmp, f));
      final sw = Stopwatch()..start();
      OnnxExternal.convert(src, dst);
      final model = File(dst).lengthSync(), data = File('$dst.data').lengthSync();
      // ignore: avoid_print
      print('$f → model ${model >> 10}KB + data ${data >> 20}MB (${sw.elapsedMilliseconds}ms)');
      expect(model, lessThan(20 << 20));
      expect(data, greaterThan(File(src).lengthSync() * 0.9));
    }
  }, skip: Directory(dir).existsSync() ? false : '모델 없음', timeout: const Timeout(Duration(minutes: 5)));
}
