import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:jj_mkvmaker/app/app_controller.dart';
import 'package:jj_mkvmaker/core/languages.dart';
import 'package:jj_mkvmaker/core/models.dart';
import 'package:jj_mkvmaker/core/output_paths.dart';
import 'package:jj_mkvmaker/services/model_store.dart';
import 'package:jj_mkvmaker/services/platform_services.dart';

/// 긴 실제 영상 (JJ_LONG_VIDEO) 으로 AI 자막: 원어 자동 → [JJ_LONG_TARGETS] (기본 ja,en).
/// 번역이 제대로 됐는지 줄 단위로 센다 (영어 자막에 일본어가 남은 줄 · 빈 줄 · 같은 말 되풀이).
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('긴 영상 AI 자막 → 번역 확인', (tester) async {
    final video = Platform.environment['JJ_LONG_VIDEO'];
    if (video == null || !File(video).existsSync()) return markTestSkipped('JJ_LONG_VIDEO 없음');
    final targets = (Platform.environment['JJ_LONG_TARGETS'] ?? 'ja,en').split(',');
    final c = AppController(PlatformServices.create());
    final sw = Stopwatch()..start();
    await tester.runAsync(() async {
      await c.init();
      await c.addVideos([video]);
      await c.generateAiSubtitles(
        [c.videos.single],
        AiOptions(targets: {for (final t in targets) languageOf(t)}, whisper: whisperModels.first),
      );
    });
    final v = c.videos.single;
    // ignore: avoid_print
    print('RESULT 걸린 시간 ${sw.elapsed.inSeconds}초\n${c.logs.join('\n')}');
    expect(v.status, isNot(JobStatus.failed), reason: v.message);

    final jp = RegExp(r'[぀-ヿ一-鿿]');
    List<String> texts(String path) {
      final blocks = File(path).readAsStringSync().replaceAll('\r', '').trim().split(RegExp(r'\n\n+'));
      return [for (final b in blocks) b.split('\n').skip(2).join(' ').trim()];
    }

    for (final t in targets) {
      final path = languageSubtitlePath(video, languageOf(t));
      final lines = texts(path);
      final empty = lines.where((l) => l.isEmpty).length;
      final withJp = lines.where(jp.hasMatch).length;
      var repeats = 0;
      for (var i = 1; i < lines.length; i++) {
        if (lines[i].isNotEmpty && lines[i] == lines[i - 1]) repeats++;
      }
      // ignore: avoid_print
      print('RESULT [$t] 줄 ${lines.length} · 빈 줄 $empty · 일본어 글자 있는 줄 $withJp · 바로 앞과 같은 줄 $repeats\n'
          '  처음: ${lines.take(5).join(' / ')}\n'
          '  중간: ${lines.skip(lines.length ~/ 2).take(5).join(' / ')}\n'
          '  끝: ${lines.skip(lines.length - 5).join(' / ')}');
    }
  }, timeout: const Timeout(Duration(minutes: 90)));
}
