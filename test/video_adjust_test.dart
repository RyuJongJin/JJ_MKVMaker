import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jj_mkvmaker/app/settings.dart';
import 'package:jj_mkvmaker/core/encode_options.dart';
import 'package:jj_mkvmaker/core/models.dart';
import 'package:path/path.dart' as p;

const _land = StreamInfo(index: 0, type: 'video', codec: 'h264', width: 1920, height: 1080);

void main() {
  test('필터: 바꾼 것이 없으면 없음, 크기만 바꾸면 예전과 같음', () {
    expect(buildVideoFilter(const EncodeSettings(codec: VideoCodecChoice.h264), _land), isNull);
    expect(buildVideoFilter(const EncodeSettings(codec: VideoCodecChoice.h264, resolution: ResolutionChoice.p720), _land),
        'scale=-2:720:flags=lanczos');
  });

  test('필터: 세로 9:16 채우기 · 맞추기 · 흐린 배경, 회전, 색 보정', () {
    const s = EncodeSettings(codec: VideoCodecChoice.h264, frame: FrameChoice.portrait);
    expect(buildVideoFilter(s, _land),
        'scale=1080:1920:force_original_aspect_ratio=increase:flags=lanczos,crop=1080:1920,setsar=1');
    expect(buildVideoFilter(s.copyWith(fit: FitChoice.fit), _land), contains('pad=1080:1920'));
    expect(buildVideoFilter(s.copyWith(fit: FitChoice.blur), _land), contains('boxblur'));
    // 720p 를 고르면 짧은 변 720
    expect(buildVideoFilter(s.copyWith(resolution: ResolutionChoice.p720), _land), contains('crop=720:1280'));
    expect(buildVideoFilter(const EncodeSettings(rotate: RotateChoice.cw90), _land), 'transpose=1');
    expect(buildVideoFilter(const EncodeSettings(saturation: 20, temperature: -40), _land),
        'eq=brightness=0.000:contrast=1.000:saturation=1.200,colorbalance=rs=-0.100:rm=-0.100:rh=-0.100:bs=0.100:bm=0.100:bh=0.100');
    expect(const EncodeSettings(frame: FrameChoice.portrait, saturation: 20).adjustSummary, contains('채도 +20'));
  });

  test('설정 저장: 화면 비율 · 맞추기 · 회전 · 색 보정', () {
    final s = AppSettings()
      ..encode = const EncodeSettings(
          codec: VideoCodecChoice.h264,
          frame: FrameChoice.square,
          fit: FitChoice.blur,
          rotate: RotateChoice.ccw90,
          brightness: 10,
          contrast: -5,
          saturation: 30,
          temperature: 100);
    final e = AppSettings.fromJson(s.toJson()).encode;
    expect([e.frame, e.fit, e.rotate], [FrameChoice.square, FitChoice.blur, RotateChoice.ccw90]);
    expect([e.brightness, e.contrast, e.saturation, e.temperature], [10, -5, 30, 100]);
    expect(AppSettings.fromJson({'encode': {'saturation': 999}}).encode.saturation, 100);
  });

  // 실제 FFmpeg 로 만들어 보고 출력 크기 확인
  final ffmpeg = p.join(Directory.current.path, 'third_party', 'ffmpeg', 'windows', 'ffmpeg.exe');
  test('실제 FFmpeg: 가로 영상 → 세로 9:16 (세 가지 맞추기) · 회전 · 색 보정이 오류 없이 되고 크기가 맞다', () async {
    final dir = Directory.systemTemp.createTempSync('jj_adj_');
    addTearDown(() => dir.deleteSync(recursive: true));
    const src = StreamInfo(index: 0, type: 'video', codec: 'h264', width: 640, height: 360);
    final cases = {
      'fill': (const EncodeSettings(codec: VideoCodecChoice.h264, frame: FrameChoice.portrait), '360x640'),
      'fit': (const EncodeSettings(codec: VideoCodecChoice.h264, frame: FrameChoice.portrait, fit: FitChoice.fit), '360x640'),
      'blur': (
        const EncodeSettings(
            codec: VideoCodecChoice.h264, frame: FrameChoice.portrait, fit: FitChoice.blur, saturation: 30, temperature: 50),
        '360x640'
      ),
      'rotate': (const EncodeSettings(codec: VideoCodecChoice.h264, rotate: RotateChoice.cw90, brightness: 20), '360x640'),
      'square': (const EncodeSettings(codec: VideoCodecChoice.h264, frame: FrameChoice.square, contrast: 40), '360x360'),
    };
    for (final MapEntry(key: name, value: (s, size)) in cases.entries) {
      final out = p.join(dir.path, '$name.png');
      final r = await Process.run(ffmpeg, [
        '-hide_banner', '-v', 'error', '-f', 'lavfi', '-i', 'testsrc2=size=640x360:duration=1', //
        '-frames:v', '1', '-vf', buildVideoFilter(s, src)!, '-y', out,
      ]);
      expect(r.exitCode, 0, reason: '$name: ${r.stderr}');
      final probe = await Process.run(ffmpeg, ['-hide_banner', '-i', out]);
      expect('${probe.stderr}', contains(size), reason: name);
    }
  }, skip: File(ffmpeg).existsSync() ? false : 'ffmpeg 없음');
}
