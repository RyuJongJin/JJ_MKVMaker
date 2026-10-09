import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../../core/languages.dart';
import '../../core/subtitle_search.dart';
import '../../services/subtitle_provider.dart';
import '../../l10n/tr.dart';
import '../../core/secret_gate.dart';

/// OpenSubtitles.com REST API (v1). Windows·Android 공용.
///
/// - 무료 API 키 필요: opensubtitles.com 가입 → 프로필 → API consumers → New consumer
/// - 로그인하지 않아도 받을 수 있지만 하루 받기 횟수가 적다 (로그인하면 늘어남)
class OpenSubtitlesProvider implements SubtitleProvider {
  final String Function() apiKey;
  final String Function() username;
  final String Function() password;

  /// 테스트용으로 바꿀 수 있는 주소
  final String baseUrl;
  static const userAgent = 'JJ_MKVMaker v1.0';

  final HttpClient _http = HttpClient()..connectionTimeout = const Duration(seconds: 20);
  String? _token;
  String? _tokenFor;
  String? _base;

  OpenSubtitlesProvider({
    required this.apiKey,
    required this.username,
    required this.password,
    this.baseUrl = 'https://api.opensubtitles.com/api/v1',
  });

  @override
  String get name => 'OpenSubtitles';

  @override
  bool get configured => apiKey().trim().isNotEmpty;

  @override
  String get setupHint => tr('OpenSubtitles 무료 API 키가 필요합니다.\n' '1. opensubtitles.com 가입 (무료)\n' '2. 프로필 → API consumers → New consumer 에서 키 만들기\n' '3. 아래 칸 또는 환경 설정에 키 붙여넣기');

  String get _api => _base ?? baseUrl;

  Future<Map<String, dynamic>> _request(String method, String path,
      {Map<String, String>? query, Object? body, bool auth = false}) async {
    // 124: 저장된 API 키 · 비밀번호를 쓰기 전에
    if (!await SecretGate.pass()) throw SubtitleProviderException(tr(secretGateMessage));
    final uri = Uri.parse('$_api$path').replace(queryParameters: query);
    final req = await _http.openUrl(method, uri);
    req.headers
      ..set('Api-Key', apiKey().trim())
      ..set('User-Agent', userAgent)
      ..set('Accept', 'application/json');
    if (auth && _token != null) req.headers.set('Authorization', 'Bearer $_token');
    if (body != null) {
      final bytes = utf8.encode(jsonEncode(body));
      req.headers.contentType = ContentType.json;
      req.contentLength = bytes.length;
      req.add(bytes);
    }
    final res = await req.close();
    final text = await res.transform(utf8.decoder).join();
    Map<String, dynamic> json;
    try {
      json = text.isEmpty ? {} : jsonDecode(text) as Map<String, dynamic>;
    } catch (_) {
      json = {'message': text};
    }
    if (res.statusCode >= 400) {
      var msg = '${json['message'] ?? json['errors']?.toString() ?? text}';
      // 54: 아이디는 있는데 비밀번호가 비었으면 (저장된 것이 없음) 알린다
      if ((res.statusCode == 401 || res.statusCode == 406) && username().trim().isNotEmpty && password().isEmpty) {
        msg = '$msg · ${tr('저장된 비밀번호가 없습니다. 한 번만 다시 넣어 주세요')}';
      }
      throw SubtitleProviderException(
          switch (res.statusCode) {
            401 || 403 => trf('OpenSubtitles API 키 또는 로그인 정보가 올바르지 않습니다. ({0})', [msg]),
            406 => trf('오늘 받을 수 있는 자막 수를 모두 사용했습니다. ({0})', [msg]),
            429 => tr('요청이 너무 많습니다. 잠시 후 다시 시도하세요.'),
            _ => trf('OpenSubtitles 오류 {0}: {1}', [res.statusCode, msg]),
          },
          quotaExceeded: res.statusCode == 406);
    }
    return json;
  }

  /// 아이디가 설정되어 있으면 로그인 (토큰은 메모리에만 보관)
  Future<void> _ensureLogin() async {
    final user = username().trim();
    if (user.isEmpty || password().isEmpty) {
      _token = null;
      _base = null;
      return;
    }
    if (_token != null && _tokenFor == user) return;
    final r = await _request('POST', '/login', body: {'username': user, 'password': password()});
    _token = r['token'] as String?;
    _tokenFor = user;
    final host = r['base_url'] as String?;
    if (host != null && host.isNotEmpty && baseUrl.startsWith('https://api.opensubtitles.com')) {
      _base = 'https://$host/api/v1';
    }
  }

  static String _code(Language l) => switch (l.code) {
        'zh-Hans' => 'zh-cn',
        'zh-Hant' => 'zh-tw',
        'pt' => 'pt-pt,pt-br',
        _ => l.code,
      };

  static Language _lang(String code) => switch (code.toLowerCase()) {
        'zh-cn' || 'zh' => languageOf('zh-Hans'),
        'zh-tw' || 'ze' => languageOf('zh-Hant'),
        'pt-br' || 'pt-pt' => languageOf('pt'),
        final c => languageOf(c),
      };

  @override
  Future<List<SubtitleSearchResult>> search(SubtitleQuery q) async {
    if (!configured) throw SubtitleProviderException(setupHint);
    // API 권장: 매개변수 이름 알파벳 순, 값은 소문자
    final params = <String, String>{
      if (q.episode != null) 'episode_number': '${q.episode}',
      if (q.languages.isNotEmpty)
        'languages': (q.languages.expand((l) => _code(l).split(',')).toSet().toList()..sort()).join(','),
      if (q.movieHash != null) 'moviehash': q.movieHash!,
      if (q.title.trim().isNotEmpty) 'query': q.title.trim().toLowerCase(),
      if (q.season != null) 'season_number': '${q.season}',
      if (q.year != null && q.season == null) 'year': '${q.year}',
    };
    final keys = params.keys.toList()..sort();
    final r = await _request('GET', '/subtitles', query: {for (final k in keys) k: params[k]!});
    final out = <SubtitleSearchResult>[];
    for (final item in (r['data'] as List? ?? const [])) {
      final a = (item as Map)['attributes'] as Map? ?? const {};
      final files = a['files'] as List? ?? const [];
      if (files.isEmpty) continue;
      final f = files.first as Map;
      final feature = a['feature_details'] as Map? ?? const {};
      out.add(SubtitleSearchResult(
        provider: name,
        id: '${item['id']}',
        fileId: '${f['file_id']}',
        language: _lang('${a['language'] ?? ''}'),
        release: '${a['release'] ?? f['file_name'] ?? ''}',
        fileName: '${f['file_name'] ?? ''}',
        downloads: (a['download_count'] as num?)?.toInt() ?? 0,
        rating: (a['ratings'] as num?)?.toDouble() ?? 0,
        hashMatch: a['moviehash_match'] == true,
        machineTranslated: a['machine_translated'] == true || a['ai_translated'] == true,
        hearingImpaired: a['hearing_impaired'] == true,
        uploader: (a['uploader'] as Map?)?['name'] as String?,
        featureTitle: [
          feature['title'] ?? feature['movie_name'],
          if (feature['year'] != null) '(${feature['year']})',
        ].whereType<Object>().join(' '),
      ));
    }
    return rankResults(out);
  }

  @override
  Future<Uint8List> download(SubtitleSearchResult r) async {
    if (!configured) throw SubtitleProviderException(setupHint);
    await _ensureLogin();
    final res = await _request('POST', '/download',
        body: {'file_id': int.tryParse(r.fileId) ?? r.fileId, 'sub_format': 'srt'}, auth: true);
    final link = res['link'] as String?;
    if (link == null) throw SubtitleProviderException(trf('다운로드 주소를 받지 못했습니다: {0}', [res['message']]));
    final req = await _http.getUrl(Uri.parse(link));
    req.headers.set('User-Agent', userAgent);
    final file = await req.close();
    if (file.statusCode != 200) {
      throw SubtitleProviderException(trf('자막 파일을 받을 수 없습니다 ({0})', [file.statusCode]));
    }
    final b = BytesBuilder(copy: false);
    await for (final chunk in file) {
      b.add(chunk);
    }
    return b.toBytes();
  }
}
