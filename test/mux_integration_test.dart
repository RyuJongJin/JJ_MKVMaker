import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jj_mkvmaker/core/charset_detector.dart';
import 'package:jj_mkvmaker/core/languages.dart';
import 'package:jj_mkvmaker/core/mkv_command_builder.dart';
import 'package:jj_mkvmaker/core/models.dart';
import 'package:jj_mkvmaker/core/output_paths.dart';
import 'package:jj_mkvmaker/core/subtitle_detector.dart';
import 'package:jj_mkvmaker/platform/windows/process_media_tool.dart';
import 'package:path/path.dart' as p;

/// 실제 FFmpeg 로 MKV 를 만들어 확인 (FFmpeg 가 없으면 건너뜀)
void main() {
  final tool = ProcessMediaTool('ffmpeg', 'ffprobe');
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('jj_mux_'));
  tearDown(() => dir.deleteSync(recursive: true));

  test('mp4 + 같은 폴더 자막(UTF-8, CP949) → jj_mkv/영화.mkv', () async {
    if (await tool.version() == null) {
      markTestSkipped('FFmpeg 없음');
      return;
    }
    final video = p.join(dir.path, '영화 테스트.mp4');
    await tool.runFfmpeg([
      '-hide_banner', '-y', '-f', 'lavfi', '-i', 'testsrc=size=320x240:rate=10',
      '-f', 'lavfi', '-i', 'sine=frequency=440', '-t', '3',
      '-c:v', 'libx264', '-c:a', 'aac', '-shortest', video,
    ]);

    // UTF-8 영어 자막
    File(p.join(dir.path, '영화 테스트.en.srt'))
        .writeAsStringSync('1\n00:00:00,500 --> 00:00:02,000\nHello\n');
    // CP949 한국어 자막: "안녕"
    File(p.join(dir.path, '영화 테스트_ko.srt')).writeAsBytesSync([
      ...ascii.encode('1\r\n00:00:00,500 --> 00:00:02,000\r\n'),
      0xBE, 0xC8, 0xB3, 0xE7, 0x0D, 0x0A,
    ]);

    final v = VideoItem(video)..info = await tool.probe(video);
    final files = dir.listSync().map((e) => e.path);
    for (final d in findSiblingSubtitles(video, files)) {
      v.subtitles.add(SubtitleEntry.external(
        path: d.path,
        language: d.language,
        charset: detectCharset(File(d.path).readAsBytesSync()),
      ));
    }
    expect(v.subtitles.map((s) => s.charset), containsAll(['UTF-8', 'CP949']));

    final out = outputMkvPath(video);
    await Directory(outputDirFor(video)).create();
    double last = 0;
    await tool.runFfmpeg(buildMuxArgs(v, out),
        duration: v.info!.duration, onProgress: (x) => last = x);
    expect(last, 1.0);

    final info = await tool.probe(out);
    final subs = info.ofType('subtitle').toList();
    expect(subs.map((s) => s.language), containsAll(['eng', 'kor']));
    expect(subs.firstWhere((s) => s.language == 'kor').isDefault, isTrue);
    expect(info.ofType('video'), hasLength(1));
    expect(info.ofType('audio'), hasLength(1));

    // CP949 자막이 UTF-8 로 올바르게 변환되었는지 확인
    final koIndex = subs.firstWhere((s) => s.language == 'kor').index;
    final srt = p.join(dir.path, 'check.srt');
    await tool.runFfmpeg(['-y', '-i', out, '-map', '0:$koIndex', srt]);
    expect(File(srt).readAsStringSync(), contains('안녕'));
    expect(languageOf('kor').code, 'ko');
  }, timeout: const Timeout(Duration(minutes: 2)));
}
