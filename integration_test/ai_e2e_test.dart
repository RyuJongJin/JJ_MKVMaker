import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:jj_mkvmaker/app/app_controller.dart';
import 'package:jj_mkvmaker/core/languages.dart';
import 'package:jj_mkvmaker/core/models.dart';
import 'package:jj_mkvmaker/core/output_paths.dart';
import 'package:jj_mkvmaker/services/platform_services.dart';
import 'package:path/path.dart' as p;

/// 실제 Whisper + NLLB 로 AI 자막 → MKV (모델이 JJ_MKVMAKER_MODELS 에 있어야 함)
/// 실행: flutter drive --driver=test_driver/integration_test.dart
///        --target=integration_test/ai_e2e_test.dart --profile -d windows
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('영어 음성 영상 → AI 자막(ko/en/ja) → MKV', (tester) async {
    final dir = Directory.systemTemp.createTempSync('jj_e2e_');
    final video = p.join(dir.path, '영어 강의.mp4');
    final speech = p.join(Directory.current.path, 'test_assets', 'speech_en.wav');
    final r = await Process.run('ffmpeg', [
      '-y', '-f', 'lavfi', '-i', 'testsrc=size=320x240:rate=10', '-i', speech,
      '-shortest', '-c:v', 'libx264', '-pix_fmt', 'yuv420p', '-c:a', 'aac', video,
    ]);
    expect(r.exitCode, 0, reason: '${r.stderr}');

    final c = AppController(PlatformServices.create());
    await tester.runAsync(() async {
      await c.init();
      await c.addVideos([video]);
      final sw = Stopwatch()..start();
      await c.generateAiSubtitles([c.videos.single], AiOptions.defaults());
      // ignore: avoid_print
      print('AI 자막: ${sw.elapsedMilliseconds}ms');
    });
    final v = c.videos.single;
    // ignore: avoid_print
    print(c.logs.join('\n'));
    expect(v.status, JobStatus.ready, reason: v.message);

    String read(String code) =>
        File(languageSubtitlePath(video, languageOf(code))).readAsStringSync();
    final ai = File(aiSubtitlePath(video)).readAsStringSync();
    // ignore: avoid_print
    print('--- AI ---\n$ai--- ko ---\n${read('ko')}--- ja ---\n${read('ja')}');
    expect(ai.toLowerCase(), contains('subtitles'));
    expect(read('en'), ai);
    expect(RegExp(r'[가-힣]').hasMatch(read('ko')), isTrue);
    expect(RegExp(r'[぀-ヿ一-鿿]').hasMatch(read('ja')), isTrue);

    await tester.runAsync(() => c.buildAll());
    expect(v.status, JobStatus.done, reason: v.message);
    final info = await tester.runAsync(() => c.services.mediaTool.probe(outputMkvPath(video)));
    final langs = info!.ofType('subtitle').map((s) => s.language).toList();
    expect(langs, containsAll(['kor', 'eng', 'jpn']));
    dir.deleteSync(recursive: true);
  }, timeout: const Timeout(Duration(minutes: 15)));
}
