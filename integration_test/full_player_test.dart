import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:jj_mkvmaker/platform/common/media_kit_full_player.dart';
import 'package:jj_mkvmaker/platform/common/media_kit_player.dart';
import 'package:jj_mkvmaker/platform/windows/desktop_shell.dart';
import 'package:jj_mkvmaker/services/media_player.dart';
import 'package:path/path.dart' as p;
import 'package:window_manager/window_manager.dart';

/// 실제 mpv 플레이어 + 창 모드
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('재생 목록 · 자막 트랙 · 음량 · 전체 화면 · 팝업 · 창 크기', (tester) async {
    MediaKitPreviewPlayer.ensureInitialized();
    final dir = Directory.systemTemp.createTempSync('jj_fp_');
    final srt = p.join(dir.path, 's.srt');
    File(srt).writeAsStringSync('1\n00:00:00,000 --> 00:00:05,000\n내장 자막\n');
    final ext = p.join(dir.path, 'ep1_ko.srt');
    File(ext).writeAsStringSync('1\n00:00:00,000 --> 00:00:05,000\n외부 자막\n');
    final files = <String>[];
    for (final n in ['ep1.mkv', 'ep2.mkv']) {
      final f = p.join(dir.path, n);
      final r = await Process.run('ffmpeg', [
        '-y', '-f', 'lavfi', '-i', 'testsrc=size=640x360:rate=25', '-f', 'lavfi', '-i', 'sine',
        '-i', srt, '-t', '6', '-map', '0', '-map', '1', '-map', '2',
        '-c:v', 'libx264', '-pix_fmt', 'yuv420p', '-c:a', 'aac', '-c:s', 'srt',
        '-metadata:s:s:0', 'language=kor', '-metadata:s:s:0', 'title=한국어', f,
      ]);
      expect(r.exitCode, 0, reason: '${r.stderr}');
      files.add(f);
    }

    final pl = MediaKitFullPlayer();
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: pl.buildView())));

    Future<void> waitFor(bool Function(PlayerState) ok, String what) async {
      for (var i = 0; i < 80 && !ok(pl.state.value); i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
        await tester.pump();
      }
      expect(ok(pl.state.value), isTrue, reason: what);
    }

    await tester.runAsync(() => pl.open(files));
    await waitFor((s) => s.playing && s.position > const Duration(milliseconds: 300), '재생 시작');
    await waitFor((s) => s.width == 640 && s.subtitleTracks.isNotEmpty, '영상 크기 · 내장 자막 트랙');
    expect(pl.state.value.subtitleTracks.first.label, contains('한국어'));

    // 외부 자막으로 바꾸기 → 끄기
    await tester.runAsync(() => pl.setSubtitleTrack(TrackInfo('file:$ext', 'ep1_ko.srt', file: ext)));
    expect(pl.state.value.subtitleId, 'file:$ext');
    await tester.runAsync(() => pl.setSubtitleTrack(null));
    expect(pl.state.value.subtitleId, isNull);

    // 음량
    await tester.runAsync(() => pl.setVolume(30));
    await waitFor((s) => (s.volume - 30).abs() < 1, '음량 30');

    // 다음 파일
    await tester.runAsync(() => pl.next());
    await waitFor((s) => s.index == 1, '다음 파일');
    await tester.runAsync(() => pl.add([files.first]));
    expect(pl.playlist, hasLength(3));

    // 창 모드
    final shell = DesktopShell();
    await tester.runAsync(() => windowManager.ensureInitialized());
    Future<void> settle() => tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 600)));

    await tester.runAsync(() => shell.setFullScreen(true));
    await settle();
    expect(await tester.runAsync(() => shell.isFullScreen()), isTrue);
    await tester.runAsync(() => shell.setFullScreen(false));
    await settle();
    expect(await tester.runAsync(() => shell.isFullScreen()), isFalse);

    final before = await tester.runAsync(() => windowManager.getBounds());
    await tester.runAsync(() => shell.setPopup(true));
    await settle();
    final popup = await tester.runAsync(() => windowManager.getBounds());
    expect(popup!.width, closeTo(480, 2));
    expect(await tester.runAsync(() => windowManager.isAlwaysOnTop()), isTrue);
    await tester.runAsync(() => shell.setPopup(false));
    await settle();
    final after = await tester.runAsync(() => windowManager.getBounds());
    expect(after!.width, closeTo(before!.width, 2));
    expect(await tester.runAsync(() => windowManager.isAlwaysOnTop()), isFalse);

    await tester.runAsync(() => shell.fitVideo(640, 360, 1));
    await settle();
    final fit = await tester.runAsync(() => windowManager.getSize());
    expect(fit!.width, closeTo(640 + 16, 2));

    await tester.runAsync(() => pl.dispose());
    dir.deleteSync(recursive: true);
  }, timeout: const Timeout(Duration(minutes: 3)));
}
