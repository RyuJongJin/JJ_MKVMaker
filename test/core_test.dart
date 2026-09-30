import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:jj_mkvmaker/core/charset_detector.dart';
import 'package:jj_mkvmaker/core/languages.dart';
import 'package:jj_mkvmaker/core/mkv_command_builder.dart';
import 'package:jj_mkvmaker/core/models.dart';
import 'package:jj_mkvmaker/core/output_paths.dart';
import 'package:jj_mkvmaker/core/subtitle_detector.dart';
import 'package:jj_mkvmaker/platform/windows/process_media_tool.dart';
import 'package:path/path.dart' as p;

void main() {
  group('같은 폴더 자막 감지', () {
    final video = p.join('D:', 'movies', '영화.mp4');
    String f(String name) => p.join('D:', 'movies', name);

    test('언어 표기 인식', () {
      final found = findSiblingSubtitles(video, [
        f('영화.srt'),
        f('영화.ko.srt'),
        f('영화_en.srt'),
        f('영화.japanese.ass'),
        f('영화.kor.smi'),
        f('영화_AI.srt'),
        f('영화.zh-Hant.srt'),
        f('영화2.srt'), // 다른 영상
        f('영화.txt'), // 자막 아님
        f('다른영화.ko.srt'),
      ]);
      final byName = {for (final d in found) p.basename(d.path): d};
      expect(byName.keys, hasLength(7));
      expect(byName['영화.srt']!.language, undetermined);
      expect(byName['영화.ko.srt']!.language.code, 'ko');
      expect(byName['영화_en.srt']!.language.code, 'en');
      expect(byName['영화.japanese.ass']!.language.code, 'ja');
      expect(byName['영화.kor.smi']!.language.code, 'ko');
      expect(byName['영화_AI.srt']!.isAi, isTrue);
      expect(byName['영화.zh-Hant.srt']!.language.code, 'zh-Hant');
    });
  });

  group('문자셋 판별', () {
    test('UTF-8 / BOM / UTF-16', () {
      expect(detectCharset(Uint8List.fromList(utf8.encode('안녕하세요'))), 'UTF-8');
      expect(detectCharset(Uint8List.fromList([0xEF, 0xBB, 0xBF, 0x41])), 'UTF-8');
      expect(detectCharset(Uint8List.fromList([0xFF, 0xFE, 0x41, 0x00])), 'UTF-16LE');
    });
    test('CP949 한글', () {
      // "안녕하세요" CP949
      final bytes = [0xBE, 0xC8, 0xB3, 0xE7, 0xC7, 0xCF, 0xBC, 0xBC, 0xBF, 0xE4];
      expect(detectCharset(Uint8List.fromList(bytes)), 'CP949');
    });
    test('Shift-JIS 가나', () {
      // "こんにちは" Shift-JIS
      final bytes = [0x82, 0xB1, 0x82, 0xF1, 0x82, 0xC9, 0x82, 0xBF, 0x82, 0xCD];
      expect(detectCharset(Uint8List.fromList(bytes)), 'SHIFT_JIS');
    });
  });

  group('출력 경로', () {
    final video = p.join('D:', 'movies', '영화.mp4');
    test('jj_mkv 폴더와 파일명 규칙', () {
      expect(outputMkvPath(video), p.join('D:', 'movies', 'jj_mkv', '영화.mkv'));
      expect(aiSubtitlePath(video), p.join('D:', 'movies', 'jj_mkv', '영화_AI.srt'));
      expect(languageSubtitlePath(video, languageOf('ja')),
          p.join('D:', 'movies', 'jj_mkv', '영화_ja.srt'));
    });
  });

  test('ffmpeg -i 출력 해석 (ffprobe 대체)', () {
    const text = '''
Input #0, mov,mp4,m4a,3gp,3g2,mj2, from 'a.mp4':
  Metadata:
    title           : 전체 제목
  Duration: 01:02:03.50, start: 0.000000, bitrate: 1000 kb/s
  Stream #0:0[0x1](und): Video: h264 (High) (avc1 / 0x31637661), yuv420p(tv, bt709, progressive), 1920x1080 [SAR 1:1 DAR 16:9], 24 fps (default)
  Stream #0:1[0x2](eng): Audio: aac (LC) (mp4a / 0x6134706D), 48000 Hz, stereo, fltp, 128 kb/s (default)
  Stream #0:2[0x3](kor): Subtitle: mov_text (tx3g / 0x67337874), 0 kb/s
      Metadata:
        title           : 한국어 자막
At least one output file must be specified
''';
    final info = parseFfmpegInfo(text);
    expect(info.duration, const Duration(hours: 1, minutes: 2, seconds: 3, milliseconds: 500));
    expect(info.streams, hasLength(3));
    final v = info.streams[0];
    expect([v.type, v.codec, v.width, v.height, v.language, v.isDefault],
        ['video', 'h264', 1920, 1080, '', true]);
    final s = info.streams[2];
    expect([s.index, s.type, s.codec, s.language, s.title, s.isDefault],
        [2, 'subtitle', 'mov_text', 'kor', '한국어 자막', false]);
  });

  group('FFmpeg 인수', () {
    test('내장 삭제 + 외부 추가 + 문자셋 + 한국어 기본', () {
      final v = VideoItem('in.mkv');
      v.subtitles.addAll([
        SubtitleEntry.embedded(
            streamIndex: 2, codec: 'subrip', language: languageOf('eng')),
        SubtitleEntry.embedded(
            streamIndex: 3, codec: 'mov_text', language: undetermined),
        SubtitleEntry.embedded(
            streamIndex: 4, codec: 'ass', language: undetermined, enabled: false),
        SubtitleEntry.external(
            path: 'a.ko.smi', language: languageOf('ko'), charset: 'CP949'),
        SubtitleEntry.external(
            path: 'a.ja.srt', language: languageOf('ja'), charset: 'UTF-8'),
      ]);
      final a = buildMuxArgs(v, 'out.mkv').join(' ');

      // 문자셋은 해당 입력 앞에만
      expect(a, contains('-sub_charenc CP949 -i a.ko.smi -i a.ja.srt'));
      // 삭제된 트랙(4)은 매핑하지 않음
      expect(a, contains('-map 0:2 -map 0:3 -map 1:0 -map 2:0'));
      expect(a, isNot(contains('0:4')));
      // 코덱: 복사 / mov_text→srt / smi→srt / srt→srt
      expect(a, contains('-c:s:0 copy'));
      expect(a, contains('-c:s:1 srt'));
      expect(a, contains('-c:s:2 srt'));
      // 언어 태그 (MKV 639-2)
      expect(a, contains('-metadata:s:s:2 language=kor'));
      expect(a, contains('-metadata:s:s:3 language=jpn'));
      // 한국어가 기본 자막
      expect(a, contains('-disposition:s:2 default'));
      expect(a, contains('-disposition:s:0 0'));
      expect(a, endsWith('out.mkv'));
    });
  });
}
