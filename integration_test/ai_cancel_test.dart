import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:jj_mkvmaker/app/app_controller.dart';
import 'package:jj_mkvmaker/core/languages.dart';
import 'package:jj_mkvmaker/core/models.dart';
import 'package:jj_mkvmaker/services/model_store.dart';
import 'package:jj_mkvmaker/services/platform_services.dart';

/// 긴 영상 (JJ_LONG_VIDEO) 의 음성인식 도중 [작업 취소] → 몇 초 안에 멈춘다 (끝까지 기다리지 않음)
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('음성인식 중 취소', (tester) async {
    final video = Platform.environment['JJ_LONG_VIDEO'];
    if (video == null || !File(video).existsSync()) return markTestSkipped('JJ_LONG_VIDEO 없음');
    final c = AppController(PlatformServices.create());
    await tester.runAsync(() async {
      await c.init();
      await c.addVideos([video]);
      final v = c.videos.single;
      final job = c.generateAiSubtitles([v], AiOptions(targets: {languageOf('en')}, whisper: whisperModels.first));
      // 음성인식이 시작될 때까지 (음성 추출이 끝나고)
      for (var i = 0; i < 600 && !(v.phase ?? '').startsWith('음성인식'); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      await Future<void>.delayed(const Duration(seconds: 5));
      final sw = Stopwatch()..start();
      c.cancel();
      await job;
      // ignore: avoid_print
      print('RESULT 취소 후 멈추기까지 ${sw.elapsedMilliseconds}ms · 상태 ${v.status} · ${c.logs.last}');
      expect(sw.elapsed.inSeconds, lessThan(15));
      expect(v.status, JobStatus.ready);
      expect(c.logs.last, contains('취소'));
    });
  }, timeout: const Timeout(Duration(minutes: 10)));
}
