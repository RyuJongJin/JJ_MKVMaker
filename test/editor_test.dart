import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jj_mkvmaker/app/app_controller.dart';
import 'package:jj_mkvmaker/app/subtitle_editor_controller.dart';
import 'package:jj_mkvmaker/core/models.dart';
import 'package:jj_mkvmaker/core/output_paths.dart';
import 'package:jj_mkvmaker/core/srt.dart';
import 'package:jj_mkvmaker/core/text_codec.dart';
import 'package:jj_mkvmaker/platform/windows/desktop_storage_service.dart';
import 'package:jj_mkvmaker/platform/windows/process_media_tool.dart';
import 'package:jj_mkvmaker/services/platform_services.dart';
import 'package:path/path.dart' as p;

void main() {
  group('SRT', () {
    const src = '﻿1\r\n00:00:01,000 --> 00:00:02,500\r\n첫 줄\r\n둘째 줄\r\n\r\n'
        '2\r\n00:00:03.2 --> 00:00:04,000\r\n세 번째\r\n\r\n\r\n'
        '00:00:05,000 --> 00:00:06,000\r\n번호 없음\r\n';

    test('해석 (BOM, 여러 줄, 마침표 밀리초, 번호 누락)', () {
      final cues = parseSrt(src);
      expect(cues, hasLength(3));
      expect(cues[0].text, '첫 줄\n둘째 줄');
      expect(cues[1].start, const Duration(seconds: 3, milliseconds: 200));
      expect(cues[2].text, '번호 없음');
    });

    test('저장 후 다시 읽어도 같음', () {
      final cues = parseSrt(src);
      final again = parseSrt(formatSrt(cues));
      expect(again.map((c) => c.text), cues.map((c) => c.text));
      expect(formatSrt(cues), startsWith('1\r\n00:00:01,000 --> 00:00:02,500\r\n'));
    });

    test('시간 입력 / 전체 이동', () {
      expect(parseSrtTime('01:02:03,4'), const Duration(hours: 1, minutes: 2, seconds: 3, milliseconds: 400));
      expect(parseSrtTime('1:05'), const Duration(minutes: 1, seconds: 5));
      expect(parseSrtTime('00:61:00'), isNull);
      expect(parseSrtTime('abc'), isNull);
      final cues = parseSrt(src);
      shiftCues(cues, const Duration(milliseconds: -1500));
      expect(cues[0].start, Duration.zero);
      expect(cues[0].end, const Duration(seconds: 1));
    });

    test('편집기: 형식 오류·순서 오류가 있으면 저장 불가', () {
      final e = SubtitleEditorController(parseSrt(src), saveCharset: 'UTF-8');
      expect(e.canSave, isTrue);
      expect(e.setTime(e.cues[0], '12:xx', isStart: true), isFalse);
      expect(e.canSave, isFalse);
      e.setTime(e.cues[0], '00:00:09,000', isStart: true); // 끝(2.5초)보다 늦음
      expect(e.invalidOrder, [0]);
      expect(e.canSave, isFalse);
      e.setTime(e.cues[0], '00:00:01,000', isStart: true);
      expect(e.canSave, isTrue);
      expect(e.dirty, isTrue);
    });
  });

  group('문자셋 변환', () {
    const text = '안녕하세요 똠방각하 Hello';
    for (final cs in ['UTF-8', 'UTF-8-BOM', 'UTF-16LE', 'UTF-16BE', 'CP949']) {
      test('$cs 왕복', () {
        final r = encodeText(text, cs);
        expect(r.lostChars, 0);
        expect(decodeText(r.bytes, cs), text);
      });
    }
    test('Shift-JIS / GBK 왕복', () {
      expect(decodeText(encodeText('こんにちは 漢字', 'SHIFT_JIS').bytes, 'SHIFT_JIS'), 'こんにちは 漢字');
      expect(decodeText(encodeText('你好 中文', 'GBK').bytes, 'GBK'), '你好 中文');
    });
    test('표현 불가 글자 개수', () {
      final r = encodeText('가나 abc', 'SHIFT_JIS'); // 한글은 Shift-JIS 에 없음
      expect(r.lostChars, 2);
      expect(latin1.decode(r.bytes), '?? abc');
    });
  });

  test('통합: MKV 내장 자막 편집 → CP949 저장 → MKV 다시 만들기', () async {
    final tool = ProcessMediaTool('ffmpeg', 'ffprobe');
    if (await tool.version() == null) {
      markTestSkipped('FFmpeg 없음');
      return;
    }
    final dir = Directory.systemTemp.createTempSync('jj_edit_');
    addTearDown(() => dir.deleteSync(recursive: true));

    // 한국어 내장 자막이 있는 MKV 준비
    final srt = p.join(dir.path, 'src.srt');
    File(srt).writeAsStringSync('1\n00:00:00,500 --> 00:00:02,000\n원래 문장\n');
    final video = p.join(dir.path, '드라마.mkv');
    await tool.runFfmpeg([
      '-y', '-f', 'lavfi', '-i', 'testsrc=size=160x120:rate=10', '-i', srt, '-t', '3',
      '-c:v', 'libx264', '-c:s', 'srt', '-metadata:s:s:0', 'language=kor', video,
    ]);
    File(srt).deleteSync(); // 같은 폴더 자막으로 잡히지 않게

    final c = AppController(
        PlatformServices(mediaTool: tool, storage: DesktopStorageService()));
    await c.init();
    await c.addVideos([video]);
    final v = c.videos.single;
    final embedded = v.subtitles.single;
    expect(embedded.kind, SubtitleKind.embedded);
    expect(embedded.language.code, 'ko');

    final cues = await c.loadCues(v, embedded);
    expect(cues.single.text, '원래 문장');
    cues.single.text = '고친 문장 똠';
    cues.add(Cue(const Duration(seconds: 2), const Duration(seconds: 3), '추가한 줄'));

    final (path, lost) = await c.saveEdited(v, embedded, cues, 'CP949');
    expect(lost, 0);
    expect(path, p.join(outputDirFor(video), '드라마_ko.srt'));
    expect(decodeText(File(path).readAsBytesSync(), 'CP949'), contains('고친 문장 똠'));
    // 원래 트랙은 제외, 편집본이 외부 자막으로 추가
    expect(embedded.enabled, isFalse);
    expect(v.subtitles[1].path, path);
    expect(v.subtitles[1].charset, 'CP949');

    await c.buildAll();
    expect(v.status, JobStatus.done, reason: v.message);
    final out = outputMkvPath(video);
    final info = await tool.probe(out);
    final subs = info.ofType('subtitle').toList();
    expect(subs, hasLength(1));
    final check = p.join(dir.path, 'check.srt');
    await tool.runFfmpeg(['-y', '-i', out, '-map', '0:${subs.single.index}', check]);
    final text = File(check).readAsStringSync();
    expect(text, contains('고친 문장 똠'));
    expect(text, contains('추가한 줄'));
    expect(text, isNot(contains('원래 문장')));
  }, timeout: const Timeout(Duration(minutes: 2)));
}
