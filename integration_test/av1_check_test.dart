import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:jj_mkvmaker/platform/common/media_kit_full_player.dart';
import 'package:jj_mkvmaker/platform/common/media_kit_player.dart';

/// AV1 (하드웨어 디코딩 미지원 그래픽카드) 파일: 오류 알림 없이 재생되는지 (JJ_AV1_FILE)
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('AV1 재생 · 오류 알림 없음', (tester) async {
    final file = Platform.environment['JJ_AV1_FILE'];
    if (file == null || !File(file).existsSync()) return;
    MediaKitPreviewPlayer.ensureInitialized();
    final pl = MediaKitFullPlayer();
    final errors = <String>[];
    pl.errors.listen(errors.add);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: pl.buildView())));
    await tester.runAsync(() => pl.open([file]));
    for (var i = 0; i < 60; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump();
    }
    final s = pl.state.value;
    // ignore: avoid_print
    print('RESULT 위치 ${s.position.inMilliseconds}ms 음성트랙 ${s.audioTracks.length} 오류 $errors');
    expect(s.position, greaterThan(const Duration(seconds: 4)));
    expect(errors, isEmpty);
    await tester.runAsync(() => pl.dispose());
  });
}
