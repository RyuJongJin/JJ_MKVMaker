import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:whisper_ggml/whisper_ggml.dart';

/// whisper.cpp 동작 확인 (스마트 앱 컨트롤·속도)
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('whisper.cpp base: 영어·한국어 인식', (tester) async {
    final model = p.join(Platform.environment['JJ_MKVMAKER_MODELS'] ?? r'M:\jj_MKVMaker\models',
        'whisper', 'ggml-base.bin');
    final assets = p.join(Directory.current.path, 'test_assets');
    for (final name in ['speech_en.wav', 'speech_ko.wav']) {
      final tmp = Directory.systemTemp.createTempSync('jj_w_');
      final wav = File(p.join(assets, name)).copySync(p.join(tmp.path, name)).path;
      final sw = Stopwatch()..start();
      final r = await tester.runAsync(() => const Whisper(model: WhisperModel.base).transcribe(
            transcribeRequest: TranscribeRequest(audio: wav, language: 'auto', threads: 4),
            modelPath: model,
          ));
      // ignore: avoid_print
      print('[$name] ${sw.elapsedMilliseconds}ms segments=${r!.segments?.length}');
      for (final s in r.segments ?? const []) {
        // ignore: avoid_print
        print('  ${s.fromTs} → ${s.toTs}: ${s.text}');
      }
      expect(r.segments, isNotEmpty);
      tmp.deleteSync(recursive: true);
    }
  });
}
