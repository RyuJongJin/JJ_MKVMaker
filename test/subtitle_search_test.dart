import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:jj_mkvmaker/app/app_controller.dart';
import 'package:jj_mkvmaker/app/settings.dart';
import 'package:jj_mkvmaker/core/languages.dart';
import 'package:jj_mkvmaker/core/models.dart';
import 'package:jj_mkvmaker/core/output_paths.dart';
import 'package:jj_mkvmaker/core/subtitle_search.dart';
import 'package:jj_mkvmaker/core/text_codec.dart';
import 'package:jj_mkvmaker/platform/common/opensubtitles_provider.dart';
import 'package:jj_mkvmaker/platform/windows/desktop_storage_service.dart';
import 'package:jj_mkvmaker/platform/windows/process_media_tool.dart';
import 'package:jj_mkvmaker/services/platform_services.dart';
import 'package:jj_mkvmaker/services/subtitle_provider.dart';
import 'package:path/path.dart' as p;

/// OpenSubtitles API 흉내 서버
class _FakeApi {
  late HttpServer server;
  final requests = <String>[];
  var downloadsLeft = 5;
  String get base => 'http://127.0.0.1:${server.port}/api/v1';

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      final body = await utf8.decoder.bind(req).join();
      requests.add('${req.method} ${req.uri.path}?${req.uri.query} key=${req.headers.value('Api-Key')} '
          'ua=${req.headers.value('User-Agent')} auth=${req.headers.value('Authorization')} $body');
      final res = req.response..headers.contentType = ContentType.json;
      // 실제 서비스처럼 API 주소에만 키 확인 (받기 링크는 키 없이 받음)
      if (req.uri.path.startsWith('/api/') && req.headers.value('Api-Key') != 'KEY') {
        res.statusCode = 403;
        res.write('{"message":"You cannot consume this service"}');
      } else if (req.uri.path.endsWith('/login')) {
        res.write('{"token":"TOKEN","base_url":"api.opensubtitles.com"}');
      } else if (req.uri.path.endsWith('/subtitles')) {
        res.write(jsonEncode({
          'total_count': 3,
          'data': [
            _item('1', 'en', 'Movie.2010.720p', 900, 101, hash: false),
            _item('2', 'ko', 'Movie.2010.1080p.BluRay', 50, 102, hash: true),
            _item('3', 'zh-cn', 'Movie.2010.AI', 5000, 103, machine: true),
          ],
        }));
      } else if (req.uri.path.endsWith('/download')) {
        if (downloadsLeft-- <= 0) {
          res.statusCode = 406;
          res.write('{"message":"You have downloaded your allowed 5 subtitles for 24h"}');
        } else {
          final id = (jsonDecode(body) as Map)['file_id'];
          res.write(jsonEncode({'link': 'http://127.0.0.1:${server.port}/file/$id.srt', 'remaining': downloadsLeft}));
        }
      } else if (req.uri.path.startsWith('/file/')) {
        res.headers.contentType = ContentType.binary;
        if (req.uri.path.contains('102')) {
          // CP949 한국어 자막
          res.add([
            ...ascii.encode('1\r\n00:00:01,000 --> 00:00:02,000\r\n'),
            ...encodeText('안녕하세요 똠방각하', 'CP949').bytes,
            13, 10,
          ]);
        } else {
          res.add(utf8.encode('1\n00:00:01,000 --> 00:00:02,000\nHello\n'));
        }
      } else {
        res.statusCode = 404;
      }
      await res.close();
    });
  }

  static Map<String, Object?> _item(String id, String lang, String release, int dl, int fileId,
          {bool hash = false, bool machine = false}) =>
      {
        'id': id,
        'attributes': {
          'language': lang,
          'release': release,
          'download_count': dl,
          'moviehash_match': hash,
          'machine_translated': machine,
          'uploader': {'name': 'tester'},
          'feature_details': {'title': 'Movie', 'year': 2010},
          'files': [
            {'file_id': fileId, 'file_name': '$release.srt'},
          ],
        },
      };
}

void main() {
  group('파일명 → 검색어', () {
    test('영화', () {
      final q = guessQuery(r'D:\m\The.Matrix.1999.1080p.BluRay.x264-GROUP.mkv');
      expect([q.title, q.year, q.season], ['The Matrix', 1999, null]);
    });
    test('드라마 회차', () {
      final q = guessQuery(r'D:\m\Breaking.Bad.S02E05.720p.WEB-DL.mkv');
      expect([q.title, q.season, q.episode], ['Breaking Bad', 2, 5]);
      final q2 = guessQuery(r'D:\m\[SubGroup] Show Name 3x07 [1080p].mkv');
      expect([q2.title, q2.season, q2.episode], ['Show Name', 3, 7]);
    });
    test('연도 괄호 · 한글 제목', () {
      final q = guessQuery(r'D:\m\기생충 (2019) 2160p.mkv');
      expect([q.title, q.year], ['기생충', 2019]);
      expect(guessQuery(r'D:\m\내 영상.mp4').title, '내 영상');
    });
  });

  test('영상 해시 (Python 계산값과 비교)', () {
    const size = 200000;
    final data = Uint8List.fromList(List.generate(size, (i) => (i * 7 + 3) % 256));
    expect(openSubtitlesHash(size, data.sublist(0, 65536), data.sublist(size - 65536)), '60a0df1f5fa2cd40');
  });

  test('이름 겹침 → _2, _3', () {
    expect(nextFreeName('a_ko.srt', {'a_ko.srt', 'a_ko_2.srt'}), 'a_ko_3.srt');
    expect(nextFreeName('a_en.srt', {'a_ko.srt'}), 'a_en.srt');
  });

  group('OpenSubtitles (흉내 서버)', () {
    late _FakeApi api;
    setUp(() async {
      api = _FakeApi();
      await api.start();
    });
    tearDown(() => api.server.close(force: true));

    OpenSubtitlesProvider make({String key = 'KEY', String user = '', String pw = ''}) =>
        OpenSubtitlesProvider(apiKey: () => key, username: () => user, password: () => pw, baseUrl: api.base);

    test('검색: 매개변수 알파벳 순 · 언어 코드 변환 · 정렬', () async {
      final r = await make().search(SubtitleQuery(
        title: 'The Matrix',
        year: 1999,
        movieHash: 'abcdef0123456789',
        languages: [languageOf('ko'), languageOf('zh-Hans'), languageOf('en')],
      ));
      final q = api.requests.single;
      expect(q, contains('GET /api/v1/subtitles?languages=en%2Cko%2Czh-cn&moviehash=abcdef0123456789&query=the+matrix&year=1999'));
      expect(q, contains('ua=JJ_MKVMaker v1.0'));
      // 해시 일치 → 사람이 만든 자막(다운로드 많은 순) → 기계 번역
      expect(r.map((x) => x.id), ['2', '1', '3']);
      expect(r.first.language.code, 'ko');
      expect(r.first.hashMatch, isTrue);
      expect(r.last.language.code, 'zh-Hans');
      expect(r.last.machineTranslated, isTrue);
      expect(r.first.featureTitle, 'Movie (2010)');
    });

    test('키 없음 / 잘못된 키', () async {
      final noKey = make(key: '');
      expect(noKey.configured, isFalse);
      await expectLater(noKey.search(const SubtitleQuery(title: 'x')), throwsA(isA<SubtitleProviderException>()));
      await expectLater(make(key: 'BAD').search(const SubtitleQuery(title: 'x')),
          throwsA(predicate((e) => '$e'.contains('API 키'))));
    });

    test('로그인 후 받기 · 하루 한도 초과', () async {
      final prov = make(user: 'me', pw: 'pw');
      final r = (await prov.search(const SubtitleQuery(title: 'movie'))).first;
      final bytes = await prov.download(r);
      expect(bytes, isNotEmpty);
      expect(api.requests.where((x) => x.contains('/login')).single, contains('"username":"me"'));
      expect(api.requests.where((x) => x.contains('/download')).single, contains('auth=Bearer TOKEN'));
      expect(api.requests.where((x) => x.contains('/download')).single, contains('"file_id":102'));

      api.downloadsLeft = 0;
      await expectLater(prov.download(r), throwsA(predicate((e) => '$e'.contains('모두 사용'))));
      expect(api.requests.where((x) => x.contains('/login')), hasLength(1)); // 토큰 재사용
    });

    test('컨트롤러: 받은 자막 UTF-8 저장 · 이름 겹침 · MKV 목록 추가', () async {
      final tool = ProcessMediaTool('ffmpeg', 'ffprobe');
      if (await tool.version() == null) return markTestSkipped('FFmpeg 없음');
      final dir = Directory.systemTemp.createTempSync('jj_os_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final video = File(p.join(dir.path, 'Movie.2010.mkv'))..writeAsBytesSync(List.filled(200000, 7));

      final settings = AppSettings()..openSubtitlesKey = 'KEY';
      final c = AppController(PlatformServices(
        mediaTool: tool,
        storage: DesktopStorageService(),
        createSubtitleProviders: (s) => [
          OpenSubtitlesProvider(
              apiKey: () => s().openSubtitlesKey, username: () => '', password: () => '', baseUrl: api.base),
        ],
      ));
      c.settings = settings;
      final v = VideoItem(video.path);
      // AI 가 이미 만든 한국어 파일이 있다고 가정
      Directory(outputDirFor(video.path)).createSync();
      File(p.join(outputDirFor(video.path), 'Movie.2010_ko.srt')).writeAsStringSync('기존');

      final q = await c.guessSubtitleQuery(v, [languageOf('ko'), languageOf('en')]);
      expect(q.title, 'Movie');
      expect(q.movieHash, hasLength(16));
      final results = await c.searchSubtitles(q);
      final n = await c.downloadSubtitles(v, results.where((r) => r.id != '3').toList());
      expect(n, 2);

      final ko = File(p.join(outputDirFor(video.path), 'Movie.2010_ko_2.srt'));
      expect(ko.readAsStringSync(), contains('안녕하세요 똠방각하')); // CP949 → UTF-8
      expect(File(p.join(outputDirFor(video.path), 'Movie.2010_en.srt')).existsSync(), isTrue);
      expect(File(p.join(outputDirFor(video.path), 'Movie.2010_ko.srt')).readAsStringSync(), '기존');
      expect(v.subtitles.map((s) => [s.language.code, s.charset, s.title]), [
        ['ko', 'UTF-8', '한국어 (OpenSubtitles)'],
        ['en', 'UTF-8', '영어 (OpenSubtitles)'],
      ]);
    });
  });
}
