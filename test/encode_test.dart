import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jj_mkvmaker/core/encode_options.dart';
import 'package:jj_mkvmaker/core/mkv_command_builder.dart';
import 'package:jj_mkvmaker/core/models.dart';
import 'package:jj_mkvmaker/platform/windows/process_media_tool.dart';
import 'package:path/path.dart' as p;

void main() {
  const all = {'libx264', 'libx265', 'libvpx-vp9', 'libaom-av1', 'libxvid', 'mpeg4'};
  const landscape = StreamInfo(index: 0, type: 'video', codec: 'h264', width: 1920, height: 1080);
  const portrait = StreamInfo(index: 0, type: 'video', codec: 'h264', width: 1080, height: 1920);

  group('인코딩 인수', () {
    test('원본 유지는 재인코딩 인수 없음', () {
      expect(buildVideoEncodeArgs(const EncodeSettings(), all, landscape), isEmpty);
    });

    test('코덱별 인코더 선택', () {
      String enc(VideoCodecChoice c) =>
          buildVideoEncodeArgs(EncodeSettings(codec: c), all, landscape)[1];
      expect(enc(VideoCodecChoice.h264), 'libx264');
      expect(enc(VideoCodecChoice.h265), 'libx265');
      expect(enc(VideoCodecChoice.vp9), 'libvpx-vp9');
      expect(enc(VideoCodecChoice.av1), 'libaom-av1');
      expect(enc(VideoCodecChoice.mpeg4), 'libxvid');
      // SVT-AV1 이 있으면 우선
      expect(buildVideoEncodeArgs(const EncodeSettings(codec: VideoCodecChoice.av1),
          {...all, 'libsvtav1'}, landscape)[1], 'libsvtav1');
    });

    test('화질별 CRF', () {
      List<String> a(QualityChoice q) => buildVideoEncodeArgs(
          EncodeSettings(codec: VideoCodecChoice.h264, quality: q), all, landscape);
      expect(a(QualityChoice.high).join(' '), contains('-crf 18'));
      expect(a(QualityChoice.normal).join(' '), contains('-crf 23'));
      expect(a(QualityChoice.small).join(' '), contains('-crf 28'));
    });

    test('크기 변경: 가로/세로 영상 모두 짧은 변 기준', () {
      const s = EncodeSettings(codec: VideoCodecChoice.h264, resolution: ResolutionChoice.p720);
      expect(buildVideoEncodeArgs(s, all, landscape).join(' '), contains('scale=-2:720'));
      expect(buildVideoEncodeArgs(s, all, portrait).join(' '), contains('scale=720:-2'));
      expect(isUpscale(ResolutionChoice.k4, landscape), isTrue);
      expect(isUpscale(ResolutionChoice.p720, landscape), isFalse);
    });

    test('인코더가 없으면 오류', () {
      expect(
          () => buildVideoEncodeArgs(
              const EncodeSettings(codec: VideoCodecChoice.av1), {'libx264'}, landscape),
          throwsArgumentError);
    });

    test('MKV 인수에 영상 인코딩 포함, 음성은 복사', () {
      final v = VideoItem('in.mp4');
      final a = buildMuxArgs(v, 'out.mkv',
              encode: const EncodeSettings(codec: VideoCodecChoice.h265), encoders: all)
          .join(' ');
      expect(a, contains('-map 0:V? -map 0:a?'));
      expect(a, contains('-c copy -c:v libx265'));
      expect(a, isNot(contains('-c:a')));
    });

    test('ffmpeg -encoders 목록 해석', () {
      const text = '''
Encoders:
 V..... = Video
 A..... = Audio
 ------
 V....D libx264              libx264 H.264
 V.S..D mpeg4                MPEG-4 part 2
 A....D aac                  AAC
''';
      expect(parseEncoderList(text), {'libx264', 'mpeg4'});
    });
  });

  test('통합: 동봉 FFmpeg 로 H.264 · H.265 · VP9 · AV1 · MPEG-4 MKV 만들기', () async {
    final tool = ProcessMediaTool('ffmpeg', 'ffprobe');
    if (await tool.version() == null) {
      markTestSkipped('FFmpeg 없음');
      return;
    }
    final available = await tool.encoders();
    for (final c in VideoCodecChoice.values.skip(1)) {
      expect(c.pickEncoder(available), isNotNull, reason: '${c.label} 인코더 없음');
    }

    final dir = Directory.systemTemp.createTempSync('jj_enc_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final src = p.join(dir.path, '원본.mp4');
    await tool.runFfmpeg([
      '-y', '-f', 'lavfi', '-i', 'testsrc=size=320x240:rate=25', '-f', 'lavfi', '-i', 'sine',
      '-t', '2', '-c:v', 'libx264', '-pix_fmt', 'yuv420p', '-c:a', 'aac', src,
    ]);
    final v = VideoItem(src)..info = await tool.probe(src);

    const expected = {
      VideoCodecChoice.h264: 'h264',
      VideoCodecChoice.h265: 'hevc',
      VideoCodecChoice.vp9: 'vp9',
      VideoCodecChoice.av1: 'av1',
      VideoCodecChoice.mpeg4: 'mpeg4',
    };
    for (final e in expected.entries) {
      // H.264 는 720p 로 크기 변경도 함께 확인
      final res = e.key == VideoCodecChoice.h264 ? ResolutionChoice.p720 : ResolutionChoice.original;
      final out = p.join(dir.path, '${e.value}.mkv');
      await tool.runFfmpeg(buildMuxArgs(v, out,
          encode: EncodeSettings(codec: e.key, resolution: res, quality: QualityChoice.small),
          encoders: available));
      final info = await tool.probe(out);
      final vs = info.ofType('video').single;
      expect(vs.codec, e.value, reason: e.key.label);
      expect(vs.height, res == ResolutionChoice.p720 ? 720 : 240, reason: e.key.label);
      expect(info.ofType('audio').single.codec, 'aac', reason: '음성은 복사');
    }
  }, timeout: const Timeout(Duration(minutes: 5)));
}
