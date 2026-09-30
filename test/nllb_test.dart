import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jj_mkvmaker/core/nllb_tokenizer.dart';
import 'package:jj_mkvmaker/platform/common/nllb_translator.dart';
import 'package:path/path.dart' as p;

/// NLLB 모델이 있어야 실행 (없으면 건너뜀)
final modelDir = p.join(
    Platform.environment['JJ_MKVMAKER_MODELS'] ?? r'M:\jj_CapCut\models', 'nllb-200-distilled-600M');

void main() {
  final hasModel = File(p.join(modelDir, 'tokenizer.json')).existsSync();

  group('NLLB 토크나이저 (Hugging Face 결과와 비교)', () {
    late NllbTokenizer tok;
    setUpAll(() {
      if (hasModel) tok = NllbTokenizer.fromJson(File(p.join(modelDir, 'tokenizer.json')).readAsStringSync());
    });

    // Python tokenizers 로 만든 정답 (원어 eng_Latn)
    const cases = {
      'Hello everyone. Today we will learn how to make subtitles.':
          [256047, 94124, 58327, 248075, 51166, 659, 4062, 62725, 11657, 202, 7038, 3384, 23147, 606, 248075, 2],
      '안녕하세요. 오늘은 자막을 만드는 방법을 배워 보겠습니다.':
          [256047, 198207, 54799, 248075, 108446, 1676, 250487, 248365, 47893, 40322, 8447, 250018, 2065, 26871, 248075, 2],
      'こんにちは、世界！': [256047, 9881, 177606, 248917, 248243, 253131, 4509, 248203, 2],
    };
    for (final e in cases.entries) {
      test(e.key, () {
        if (!hasModel) return markTestSkipped('모델 없음');
        expect(tok.encode(e.key, 'eng_Latn'), e.value);
      });
    }
    test('디코드', () {
      if (!hasModel) return markTestSkipped('모델 없음');
      expect(tok.decode(cases.values.first), 'Hello everyone. Today we will learn how to make subtitles.');
    });
  });

  test('NLLB 번역 (영→한·일, 한→영)', () async {
    if (!hasModel || !Platform.isWindows) return markTestSkipped('모델 없음');
    // 테스트 실행기에는 DLL 이 옆에 없으므로 패키지 폴더의 DLL 을 먼저 올려 둔다
    final config = jsonDecode(File('.dart_tool/package_config.json').readAsStringSync()) as Map;
    final pkg = (config['packages'] as List).cast<Map>().firstWhere((e) => e['name'] == 'onnxruntime');
    final root = Uri.parse(pkg['rootUri'] as String);
    final rootPath = root.isAbsolute ? root.toFilePath() : p.normalize(p.join('.dart_tool', root.toFilePath()));
    DynamicLibrary.open(p.join(rootPath, 'windows', 'onnxruntime.dll'));

    final t = NllbTranslator(batchSize: 4);
    final sw = Stopwatch()..start();
    await t.load(modelDir);
    // ignore: avoid_print
    print('load ${sw.elapsedMilliseconds}ms');

    const en = [
      'Hello everyone.',
      'Today we will learn how to make subtitles.',
      '',
      'This program runs completely offline.',
    ];
    final progress = <double>[];
    sw.reset();
    final ko = await t.translate(en, source: 'eng_Latn', target: 'kor_Hang', onProgress: progress.add);
    // ignore: avoid_print
    print('en→ko ${sw.elapsedMilliseconds}ms $ko');
    sw.reset();
    final ja = await t.translate(en, source: 'eng_Latn', target: 'jpn_Jpan');
    // ignore: avoid_print
    print('en→ja ${sw.elapsedMilliseconds}ms $ja');
    final back = await t.translate(['오늘은 자막을 만드는 방법을 배워 보겠습니다.'],
        source: 'kor_Hang', target: 'eng_Latn');
    // ignore: avoid_print
    print('ko→en $back');
    await t.dispose();

    expect(ko, hasLength(4));
    expect(ko[2], '');
    expect(ko[1], contains('자막'));
    expect(RegExp(r'[가-힣]').hasMatch(ko[3]), isTrue);
    expect(RegExp(r'[\u3040-\u30ff\u4e00-\u9fff]').hasMatch(ja[1]), isTrue);
    expect(back.single.toLowerCase(), contains('subtitle'));
    expect(progress.last, 1.0);
  }, timeout: const Timeout(Duration(minutes: 5)));
}
