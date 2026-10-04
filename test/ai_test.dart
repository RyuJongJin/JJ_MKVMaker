import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jj_mkvmaker/app/app_controller.dart';
import 'package:jj_mkvmaker/core/ai_subtitle.dart';
import 'package:jj_mkvmaker/core/languages.dart';
import 'package:jj_mkvmaker/core/models.dart';
import 'package:jj_mkvmaker/core/output_paths.dart';
import 'package:jj_mkvmaker/core/srt.dart';
import 'package:jj_mkvmaker/platform/windows/desktop_storage_service.dart';
import 'package:jj_mkvmaker/platform/windows/process_media_tool.dart';
import 'package:jj_mkvmaker/services/ai_services.dart';
import 'package:jj_mkvmaker/services/model_store.dart';
import 'package:jj_mkvmaker/services/platform_services.dart';
import 'package:path/path.dart' as p;

class _FakeRecognizer implements SpeechRecognizer {
  @override
  void cancel() {}
  String? lastLanguage;
  @override
  Future<List<Cue>> transcribe(String wavPath,
      {required String modelPath, String language = 'auto', AiProgress? onProgress}) async {
    lastLanguage = language;
    expect(File(wavPath).existsSync(), isTrue, reason: '음성 추출 파일');
    onProgress?.call(1);
    return [
      Cue(const Duration(seconds: 1), const Duration(seconds: 2), ' Hello everyone. '),
      Cue(const Duration(seconds: 2), const Duration(seconds: 3), '[BLANK_AUDIO]'),
      Cue(const Duration(seconds: 3), const Duration(seconds: 5), 'This is a test of the subtitle program.'),
    ];
  }
}

class _FakeTranslator implements Translator {
  final calls = <String>[];
  Completer<void>? gate;
  bool disposed = false;
  @override
  Future<void> load(String modelDir) async {}
  @override
  Future<List<String>> translate(List<String> lines,
      {required String source, required String target, AiProgress? onProgress}) async {
    calls.add('$source>$target');
    await gate?.future;
    onProgress?.call(1);
    return [for (final l in lines) '[$target] $l'];
  }

  @override
  void cancel() {}
  @override
  Future<void> dispose() async => disposed = true;
}

void main() {
  group('원어 판별', () {
    test('문자 체계', () {
      expect(detectLanguage('안녕하세요 반갑습니다').code, 'ko');
      expect(detectLanguage('こんにちは、元気ですか').code, 'ja');
      expect(detectLanguage('你好，我们今天学习').code, 'zh-Hans');
      expect(detectLanguage('Привет, как дела').code, 'ru');
      expect(detectLanguage('...').code, 'und');
    });
    test('라틴 문자', () {
      expect(detectLanguage('This is what we are going to do and it is fun').code, 'en');
      expect(detectLanguage('Hola, ¿qué tal? Esta es la casa de los padres').code, 'es');
      expect(detectLanguage("Je ne sais pas, c'est une question que nous avons").code, 'fr');
      expect(detectLanguage('Ich weiß nicht, das ist nicht die Frage und wir').code, 'de');
    });
  });

  test('인식 결과 정리: 비음성 표시 제거, 긴 줄 나누기', () {
    final out = cleanRecognized([
      Cue(Duration.zero, const Duration(seconds: 1), '  [Music]  '),
      Cue(Duration.zero, const Duration(seconds: 1), '(음악)'),
      Cue(Duration.zero, const Duration(seconds: 1), ''),
      Cue(Duration.zero, const Duration(seconds: 3),
          'This sentence is definitely much longer than forty two characters in total'),
    ]);
    expect(out, hasLength(1));
    expect(out.single.text.split('\n'), hasLength(2));
    expect(out.single.text.replaceAll('\n', ' '),
        'This sentence is definitely much longer than forty two characters in total');
  });

  test('인식 결과 정리: 말 없는 곳에서 지어낸 되풀이 (ん · ん · ん …) 는 빼고, 진짜 대화의 짧은 반복은 둔다', () {
    Cue cue(int s, String t) => Cue(Duration(seconds: s), Duration(seconds: s + 1), t);
    final out = cleanRecognized([
      cue(0, 'はい'),
      cue(1, 'はい'),
      cue(2, 'それでは'),
      for (var i = 0; i < 5; i++) cue(10 + i, 'ん'),
      for (var i = 0; i < 6; i++) cue(20 + i, 'ご視聴ありがとうございました'),
    ]);
    expect([for (final c in out) c.text], ['はい', 'はい', 'それでは', 'ご視聴ありがとうございました']);
  });

  test('짧은 말 (はい · えー · そうそう …) 은 표의 번역, 나머지만 번역 모델로', () async {
    expect(fillerTranslation('はい。', 'ja', 'en'), 'Yes.');
    expect(fillerTranslation('はーーい！', 'ja', 'ko'), '네~');
    expect(fillerTranslation('えー、', 'ja', 'en'), 'Um...');
    expect(fillerTranslation('Thank you!', 'en', 'ja'), 'ありがとうございます。');
    expect(fillerTranslation('はい、皆さんこんにちは', 'ja', 'en'), isNull);
    expect(fillerTranslation('はい', 'ja', 'fr'), isNull); // 표에 없는 언어는 모델로
    final sent = <String>[];
    final out = await translateKeepingFillers(
      ['はい。', '大学はどこに行けばいいですかね', 'そうそう', '頭がいい人が好きなんだ'],
      (rest) async {
        sent.addAll(rest);
        return [for (final r in rest) 'EN($r)'];
      },
      src: 'ja',
      tgt: 'en',
    );
    expect(sent, ['大学はどこに行けばいいですかね', '頭がいい人が好きなんだ']);
    expect(out, ['Yes.', 'EN(大学はどこに行けばいいですかね)', 'Right, right.', 'EN(頭がいい人が好きなんだ)']);
  });

  test('흐름: 영어 영상 → _AI.srt + _ko/_en/_ja.srt, MKV 목록에 추가', () async {
    final tool = ProcessMediaTool('ffmpeg', 'ffprobe');
    if (await tool.version() == null) return markTestSkipped('FFmpeg 없음');

    final dir = Directory.systemTemp.createTempSync('jj_ai_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final video = p.join(dir.path, '강의.mp4');
    await tool.runFfmpeg(['-y', '-f', 'lavfi', '-i', 'testsrc=size=160x120:rate=10',
      '-f', 'lavfi', '-i', 'sine', '-t', '3', '-c:v', 'libx264', '-pix_fmt', 'yuv420p', '-c:a', 'aac', video]);

    // 모델 파일이 이미 있는 것처럼 준비 (내려받기 건너뜀)
    final models = ModelStore(p.join(dir.path, 'models'));
    for (final m in [whisperModels.first, nllbModel]) {
      for (var i = 0; i < m.files.length; i++) {
        File(await models.pathOf(m, i))
          ..createSync(recursive: true)
          ..writeAsStringSync('x');
      }
    }
    final rec = _FakeRecognizer();
    final tr = _FakeTranslator();
    final c = AppController(PlatformServices(
      mediaTool: tool,
      storage: DesktopStorageService(),
      createRecognizer: () => rec,
      createTranslator: () => tr,
      models: models,
    ));
    await c.init();
    await c.addVideos([video]);
    final v = c.videos.single;

    await c.generateAiSubtitles([v], AiOptions.defaults());

    expect(v.status, JobStatus.ready, reason: v.message);
    expect(rec.lastLanguage, 'auto');
    // 원어(영어) 는 번역하지 않음
    expect(tr.calls, ['eng_Latn>kor_Hang', 'eng_Latn>jpn_Jpan']);
    expect(tr.disposed, isTrue);

    final ai = parseSrt(File(aiSubtitlePath(video)).readAsStringSync());
    expect(ai.map((c) => c.text), ['Hello everyone.', 'This is a test of the subtitle program.']);
    String read(String code) => File(languageSubtitlePath(video, languageOf(code))).readAsStringSync();
    expect(read('ko'), contains('[kor_Hang] Hello everyone.'));
    expect(read('ja'), contains('[jpn_Jpan] This is a test'));
    expect(read('en'), contains('Hello everyone.'));
    expect(read('en'), isNot(contains('[')));

    // MKV 목록: 언어별 3개 (AI 원본 파일은 넣지 않음)
    final ext = v.subtitles.where((s) => s.kind == SubtitleKind.external).toList();
    expect(ext.map((s) => p.basename(s.path!)), ['강의_ko.srt', '강의_en.srt', '강의_ja.srt']);
    expect(ext[1].title, '영어 (AI 인식)');
    expect(ext[0].title, '한국어 (AI 번역)');

    // 다시 실행해도 중복 추가되지 않음
    await c.generateAiSubtitles([v], AiOptions.defaults());
    expect(v.subtitles.where((s) => s.kind == SubtitleKind.external), hasLength(3));
  });

  test('있는 자막 번역: 영어 SRT → _ko.srt (MKV 목록에 추가, 덮어쓰지 않음) + 작업 대기열', () async {
    final dir = Directory.systemTemp.createTempSync('jj_tr_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final video = p.join(dir.path, 'movie.mp4');
    File(video).writeAsStringSync('x');
    final en = p.join(dir.path, 'movie.en.srt');
    File(en).writeAsStringSync('1\n00:00:01,000 --> 00:00:02,000\nHello there.\n\n'
        '2\n00:00:03,000 --> 00:00:04,000\nThis is\na test.\n\n');
    final models = ModelStore(p.join(dir.path, 'models'));
    for (var i = 0; i < nllbModel.files.length; i++) {
      File(await models.pathOf(nllbModel, i))
        ..createSync(recursive: true)
        ..writeAsStringSync('x');
    }
    final tr = _FakeTranslator()..gate = Completer<void>();
    final c = AppController(PlatformServices(
      mediaTool: ProcessMediaTool('ffmpeg', 'ffprobe'),
      storage: DesktopStorageService(),
      createTranslator: () => tr,
      models: models,
    ));
    // 이미 있는 _ko.srt 는 덮어쓰지 않는다
    Directory(p.join(dir.path, 'jj_mkv')).createSync();
    File(p.join(dir.path, 'jj_mkv', 'movie_ko.srt')).writeAsStringSync('old');

    final v = VideoItem(video);
    final s = SubtitleEntry.external(path: en, language: undetermined, charset: 'UTF-8');
    v.subtitles.add(s);

    final first = c.translateSubtitle(v, s, {languageOf('ko')});
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(c.busy, isTrue);
    expect(c.currentJob, contains('자막 번역'));
    // 번역 중에 하나 더 → 대기열
    final second = c.translateSubtitle(v, s, {languageOf('ja')});
    expect(c.pendingJobs, hasLength(1));
    tr.gate!.complete();
    await first;
    await second;
    expect(c.busy, isFalse);
    expect(c.pendingJobs, isEmpty);

    // 원어 자동 판별 (영어) → 한국어, 일본어 순서대로
    expect(tr.calls, ['eng_Latn>kor_Hang', 'eng_Latn>jpn_Jpan']);
    expect(v.status, JobStatus.ready, reason: v.message);
    final added = v.subtitles.skip(1).toList();
    expect(added.map((x) => p.basename(x.path!)), ['movie_ko_2.srt', 'movie_ja.srt']);
    expect(added.first.language.code, 'ko');
    expect(added.first.title, contains('AI 번역'));
    final ko = parseSrt(File(added.first.path!).readAsStringSync());
    expect(ko.map((x) => x.text), ['[kor_Hang] Hello there.', '[kor_Hang] This is a test.']);
    expect(ko[1].start, const Duration(seconds: 3));
    expect(File(p.join(dir.path, 'jj_mkv', 'movie_ko.srt')).readAsStringSync(), 'old');
  });
}
