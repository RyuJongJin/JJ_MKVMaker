import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:jj_mkvmaker/platform/common/media_kit_full_player.dart';
import 'package:jj_mkvmaker/platform/common/media_kit_player.dart';

/// 재생 바로 건너뛰면 다음 파일로 넘어가는지 (JJ_SEEK_FILE = 시험할 동영상)
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final file = Platform.environment['JJ_SEEK_FILE'];

  testWidgets('건너뛰기: 다음 파일로 넘어가지 않는다', (tester) async {
    MediaKitPreviewPlayer.ensureInitialized();
    final pl = MediaKitFullPlayer();
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: pl.buildView())));
    Future<void> wait(int ms) async {
      for (var i = 0; i < ms ~/ 100; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
        await tester.pump();
      }
    }

    await tester.runAsync(() => pl.open([file!, file]));
    for (var i = 0; i < 50 && pl.state.value.duration == Duration.zero; i++) {
      await wait(100);
    }
    final total = pl.state.value.duration;
    debugPrint('SEEK total $total');
    var jumped = 0;
    for (final f in [0.1, 0.5, 0.9, 0.3, 0.7, 0.95, 0.2, 0.6, 0.8, 0.4, 0.99, 0.05]) {
      // 끌기처럼 여러 번 빠르게
      for (final d in [-0.02, -0.01, 0.0]) {
        await tester.runAsync(() => pl.seek(total * (f + d).clamp(0, 1)));
      }
      await wait(1500);
      final s = pl.state.value;
      debugPrint('SEEK ${(f * 100).round()}% → index ${s.index} pos ${s.position} dur ${s.duration} done ${s.completed}');
      if (s.index != 0) {
        jumped++;
        await tester.runAsync(() => pl.jump(0));
        await wait(1500);
      }
    }
    debugPrint('SEEK jumped $jumped');
    expect(jumped, 0);
    // 진짜 끝: 끝 2초 전으로 건너뛰면 끝난 뒤 다음 파일로
    await tester.runAsync(() => pl.play());
    await tester.runAsync(() => pl.seek(total - const Duration(seconds: 2)));
    for (var i = 0; i < 80 && pl.state.value.index != 1; i++) {
      await wait(100);
    }
    debugPrint('SEEK end → index ${pl.state.value.index} pos ${pl.state.value.position}');
    expect(pl.state.value.index, 1);
    await wait(1500);
    expect(pl.state.value.playing, isTrue);
  }, skip: file == null);
}
