import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:jj_mkvmaker/platform/common/media_kit_player.dart';
import 'package:path/path.dart' as p;

/// 실제 Windows 앱에서 libmpv 재생 확인
/// 실행: flutter test integration_test -d windows
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('media_kit: 영상 열기 · 재생 · 이동', (tester) async {
    MediaKitPreviewPlayer.ensureInitialized();

    final dir = Directory.systemTemp.createTempSync('jj_play_');
    final video = p.join(dir.path, '재생 테스트.mp4');
    final r = await Process.run('ffmpeg', [
      '-y', '-f', 'lavfi', '-i', 'testsrc=size=320x240:rate=25',
      '-f', 'lavfi', '-i', 'sine', '-t', '10', '-c:v', 'libx264', '-pix_fmt', 'yuv420p', '-c:a', 'aac', video,
    ]);
    expect(r.exitCode, 0, reason: '${r.stderr}');

    final player = MediaKitPreviewPlayer();
    final errors = <String>[];
    player.errorStream.listen(errors.add);

    await tester.pumpWidget(MaterialApp(
      home: SizedBox(width: 320, height: 240, child: player.buildView()),
    ));

    Future<void> waitFor(bool Function() ok, String what) async {
      for (var i = 0; i < 100 && !ok(); i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
        await tester.pump();
      }
      expect(ok(), isTrue, reason: '$what (오류: $errors)');
    }

    await tester.runAsync(() => player.open(video));
    await waitFor(() => player.duration > const Duration(seconds: 9), '길이 읽기');

    await tester.runAsync(() => player.playOrPause());
    await waitFor(() => player.position > const Duration(milliseconds: 800), '재생 진행');

    await tester.runAsync(() => player.pause());
    await tester.runAsync(() => player.seek(const Duration(seconds: 7)));
    await waitFor(
        () => (player.position - const Duration(seconds: 7)).inMilliseconds.abs() < 300,
        '위치 이동');

    await tester.runAsync(() => player.dispose());
    dir.deleteSync(recursive: true);
    expect(errors, isEmpty);
  });
}
