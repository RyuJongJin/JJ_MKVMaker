import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// 앱 안 웹 브라우저의 페이지 번역 (환경 설정 > 웹 브라우저 > 웹 페이지 자동 번역).
///
/// 엔진 (Edge · Chrome · Android) 과 상관없이 같은 방식으로 동작한다:
/// 1. [webTranslateCollectScript] 로 페이지의 글자 (텍스트 노드 · placeholder · title) 를 모은다.
///    한 번 번역한 글자는 다시 모으지 않고, 페이지가 바뀌면 (YouTube 처럼 주소만 바뀌는 사이트 포함) 새 글자만 모은다.
/// 2. [WebPageTranslator] 가 Google 번역으로 화면 언어로 번역한다 (원문 언어는 자동 감지).
/// 3. [webTranslateApplyScript] 로 페이지에 넣는다. [webTranslateRestoreScript] 는 원문으로 되돌린다.
///
/// 스크립트는 앱이 페이지에 넣는 것이라 페이지의 JavaScript 를 꺼도 Edge 에서는 동작한다.

/// 화면 언어 코드 → Google 번역 언어 코드
String googleLang(String uiLanguage) => switch (uiLanguage) {
      'zh-Hans' => 'zh-CN',
      'zh-Hant' => 'zh-TW',
      'he' => 'iw',
      _ => uiLanguage,
    };

/// 두 언어 코드가 같은 언어인지 (ko-KR = ko, zh-CN ≠ zh-TW, he = iw)
bool sameLanguage(String a, String b) {
  String norm(String x) {
    x = x.trim().toLowerCase().replaceAll('_', '-');
    if (x == 'iw' || x.startsWith('iw-')) return 'he';
    if (x.startsWith('zh')) return x.contains('tw') || x.contains('hk') || x.contains('hant') ? 'zh-tw' : 'zh-cn';
    final i = x.indexOf('-');
    return i < 0 ? x : x.substring(0, i);
  }

  return a.isNotEmpty && b.isNotEmpty && norm(a) == norm(b);
}

/// 페이지의 아직 번역하지 않은 글자를 모으는 스크립트. 결과는 JSON 문자열:
/// `{"items": [[번호, 글자], ...], "more": 남은 글자가 있는지, "same": 이미 화면 언어인 페이지}`.
///
/// [force] 가 아니면 페이지가 이미 화면 언어 (`<html lang>` 또는 앞서 번역해 보니 대부분 그 언어) 일 때 모으지 않는다.
String webTranslateCollectScript(String target, {bool force = false, int max = 300}) =>
    '(function(tl,force,max){$_init'
    r'''
  if (T.target && T.target !== tl) T.restore();
  T.target = tl;
  if (force && !T.forced) { T.forced = true; T.same = false; T.dirty = true; }
  if (!force && !T.forced) {
    var lang = (document.documentElement.getAttribute('lang') || '').toLowerCase();
    if (lang && T.base(lang) === T.base(tl)) T.same = true;
  }
  if (T.same) return JSON.stringify({items: [], same: true});
  if (!T.dirty && T.obs) return JSON.stringify({items: []});
  T.dirty = false;
  if (T.refs.length > 4000) T.refs = T.refs.filter(function(r){ return (r.n || r.e).isConnected; });
  var items = [], more = false, letter = /\p{L}/u;
  function add(r, text) {
    if (items.length >= max) { more = true; return false; }
    r.i = T.refs.length; T.refs.push(r);
    items.push([r.i, text]);
    return true;
  }
  var root = document.body || document.documentElement;
  // 건너뛸 요소 (스크립트 · 코드 · 입력칸 · translate="no" …) 아래의 글은 거른다. 요소마다 한 번만 판단해 기억.
  // TreeWalker 의 거르기 함수 (acceptNode) 는 쓰지 않는다: 페이지 JavaScript 를 끄면 Edge 가 그 함수를 부르지 못한다.
  var memo = new Map();
  function skipped(el) {
    if (!el || el.nodeType !== 1) return false;
    var s = memo.get(el);
    if (s === undefined) { s = T.skipOne(el) || skipped(el.parentNode); memo.set(el, s); }
    return s;
  }
  var w = document.createTreeWalker(root, NodeFilter.SHOW_TEXT), n;
  while ((n = w.nextNode())) {
    var v = n.nodeValue;
    if (n.__jjT === v || !letter.test(v) || skipped(n.parentNode)) continue;
    if (!add({n: n, o: v}, v.replace(/\s+/g, ' ').trim())) break;
  }
  if (!more) {
    var els = root.querySelectorAll('[placeholder],[title]');
    for (var i = 0; i < els.length && !more; i++) {
      var e = els[i];
      // 입력칸 자체는 글자만 건너뛰고 안내 글 (placeholder) · 풍선 도움말 (title) 은 번역
      if (skipped(e.parentNode) || e.getAttribute('translate') === 'no' || e.classList.contains('notranslate')) continue;
      ['placeholder', 'title'].forEach(function(a){
        var v = e.getAttribute(a);
        if (v && e['__jjT_' + a] !== v && letter.test(v)) add({e: e, a: a, o: v}, v.trim());
      });
    }
  }
  if (more) T.dirty = true;
  return JSON.stringify({items: items, more: more});
})'''
    '(${jsonEncode(target)},$force,$max)';

/// 번역한 글자를 페이지에 넣는 스크립트. [texts] 는 번호 → 번역 (null = 이미 화면 언어라 그대로 둠).
/// [same]: 이 페이지는 화면 언어로 보고 (직접 번역을 누르지 않았으면) 더 모으지 않는다.
String webTranslateApplyScript(Map<int, String?> texts, {bool same = false}) =>
    '(function(m,same){$_init'
    r'''
  var c = 0;
  for (var k in m) {
    var r = T.refs[k], t = m[k];
    if (!r) continue;
    if (r.a) {
      if (r.e.getAttribute(r.a) !== r.o) continue;
      if (t !== null) { r.e.setAttribute(r.a, t); r.t = t; c++; }
      r.e['__jjT_' + r.a] = t === null ? r.o : t;
    } else {
      if (r.n.nodeValue !== r.o) continue;
      if (t !== null) {
        r.t = r.o.match(/^\s*/)[0] + t + r.o.match(/\s*$/)[0];
        r.n.nodeValue = r.t;
        c++;
      }
      r.n.__jjT = t === null ? r.o : r.t;
    }
  }
  if (same && !T.forced) T.same = true;
  if (T.obs) T.obs.takeRecords();
  return c;
})'''
    '(${jsonEncode({for (final e in texts.entries) '${e.key}': e.value})},$same)';

/// 번역한 글자를 원문으로 되돌리는 스크립트 (번역 끄기)
const webTranslateRestoreScript = '(function(){var T = window.__jjTr; if (!T) return 0; return T.restore();})()';

/// 페이지에 번역 도구를 한 번만 만든다 (T). 페이지가 바뀌는 것은 MutationObserver 로 알아챈다.
const _init = r'''
  var T = window.__jjTr;
  if (!T) {
    T = window.__jjTr = {refs: [], target: '', same: false, forced: false, dirty: true, obs: null};
    T.base = function(x){ x = x.toLowerCase(); if (x.indexOf('zh') === 0) return /tw|hk|hant/.test(x) ? 'zh-tw' : 'zh-cn'; if (x === 'iw') return 'he'; return x.split('-')[0]; };
    var SKIP = {SCRIPT:1, STYLE:1, NOSCRIPT:1, TEXTAREA:1, CODE:1, PRE:1, KBD:1, SAMP:1, VAR:1, TEMPLATE:1, INPUT:1, SELECT:1, OPTION:1};
    T.skipOne = function(el){
      return !!(SKIP[el.nodeName.toUpperCase()] || el.isContentEditable || el.getAttribute('translate') === 'no' ||
        (el.classList && el.classList.contains('notranslate')));
    };
    T.restore = function(){
      var c = 0;
      for (var i = T.refs.length - 1; i >= 0; i--) {
        var r = T.refs[i];
        if (r.a) {
          if (r.t !== undefined && r.e.getAttribute(r.a) === r.t) { r.e.setAttribute(r.a, r.o); c++; }
          r.e['__jjT_' + r.a] = undefined;
        } else {
          if (r.t !== undefined && r.n.nodeValue === r.t) { r.n.nodeValue = r.o; c++; }
          r.n.__jjT = undefined;
        }
      }
      T.refs = []; T.target = ''; T.same = false; T.forced = false; T.dirty = true;
      if (T.obs) T.obs.takeRecords();
      return c;
    };
    try {
      T.obs = new MutationObserver(function(){ T.dirty = true; });
      T.obs.observe(document.documentElement, {childList: true, subtree: true, characterData: true, attributes: true, attributeFilter: ['placeholder', 'title']});
    } catch (e) { T.obs = null; }
  }
''';

/// [webTranslateCollectScript] 의 결과
class CollectedText {
  final List<int> ids;
  final List<String> texts;
  final bool more;
  final bool same;
  const CollectedText(this.ids, this.texts, {this.more = false, this.same = false});

  /// 웹뷰가 돌려준 값 (JSON 문자열, 또는 엔진에 따라 이미 풀린 Map). 알 수 없으면 null.
  static CollectedText? parse(Object? raw) {
    try {
      var v = raw;
      if (v is String) v = jsonDecode(v);
      // 엔진에 따라 JSON 문자열을 한 번 더 감싸서 준다
      if (v is String) v = jsonDecode(v);
      if (v is! Map) return null;
      final ids = <int>[], texts = <String>[];
      for (final it in (v['items'] as List?) ?? const []) {
        if (it is List && it.length == 2) {
          ids.add((it[0] as num).toInt());
          texts.add('${it[1]}');
        }
      }
      return CollectedText(ids, texts, more: v['more'] == true, same: v['same'] == true);
    } catch (_) {
      return null;
    }
  }
}

/// Google 번역 요청 (주소, 본문) → 응답 본문. 테스트에서 바꿔 끼운다.
typedef TranslatePost = Future<String> Function(Uri url, String body);

/// 여러 글자를 Google 번역으로 한 번에 번역한다 (원문 언어 자동 감지). 같은 글자는 다시 묻지 않는다.
class WebPageTranslator {
  final TranslatePost _post;
  WebPageTranslator({TranslatePost? post}) : _post = post ?? _httpPost;

  /// (대상 언어, 원문) → 번역. null = 이미 대상 언어
  final _cache = <(String, String), String?>{};
  static const _cacheMax = 20000;

  /// 한 번에 보내는 양
  static const _chunkChars = 3000, _chunkItems = 100;

  /// [texts] 를 [target] (Google 언어 코드) 으로. 결과의 null 은 이미 그 언어라 번역하지 않은 것.
  Future<List<String?>> translate(List<String> texts, String target) async {
    final out = List<String?>.filled(texts.length, null);
    final todo = <int>[];
    final asked = <String>{};
    for (var i = 0; i < texts.length; i++) {
      final key = (target, texts[i]);
      if (_cache.containsKey(key)) {
        out[i] = _cache[key];
      } else if (texts[i].trim().isNotEmpty && asked.add(texts[i])) {
        todo.add(i);
      }
    }
    // 같은 양으로 나눠 동시에 3개까지
    final chunks = <List<String>>[];
    var cur = <String>[];
    var size = 0;
    for (final i in todo) {
      final t = texts[i];
      if (cur.isNotEmpty && (cur.length >= _chunkItems || size + t.length > _chunkChars)) {
        chunks.add(cur);
        cur = [];
        size = 0;
      }
      cur.add(t);
      size += t.length;
    }
    if (cur.isNotEmpty) chunks.add(cur);
    for (var i = 0; i < chunks.length; i += 3) {
      await Future.wait([for (final c in chunks.skip(i).take(3)) _ask(c, target)]);
    }
    if (_cache.length > _cacheMax) _cache.clear();
    for (var i = 0; i < texts.length; i++) {
      final key = (target, texts[i]);
      if (_cache.containsKey(key)) out[i] = _cache[key];
    }
    return out;
  }

  Future<void> _ask(List<String> texts, String target) async {
    final url = Uri.https('translate.googleapis.com', '/translate_a/t',
        {'client': 'gtx', 'sl': 'auto', 'tl': target, 'format': 'text'});
    final body = texts.map((t) => 'q=${Uri.encodeQueryComponent(t)}').join('&');
    final res = parseGoogleResponse(await _post(url, body), texts.length);
    for (var i = 0; i < texts.length; i++) {
      final (text, lang) = res[i];
      _cache[(target, texts[i])] = sameLanguage(lang, target) || text == texts[i] ? null : text;
    }
  }

  /// 응답: `[["번역","en"], ...]` (원문 언어 자동 감지) 또는 `["번역", ...]`
  static List<(String, String)> parseGoogleResponse(String body, int count) {
    final v = jsonDecode(body);
    if (v is! List || v.length != count) {
      throw FormatException('번역 응답의 개수가 다릅니다 (${v is List ? v.length : '?'} / $count)');
    }
    return [
      for (final x in v)
        x is List ? ('${x.isEmpty ? '' : x[0]}', x.length > 1 ? '${x[1]}' : '') : ('$x', ''),
    ];
  }

  static Future<String> _httpPost(Uri url, String body) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    try {
      final req = await client.postUrl(url);
      req.headers.contentType = ContentType('application', 'x-www-form-urlencoded', charset: 'utf-8');
      req.add(utf8.encode(body));
      final res = await req.close().timeout(const Duration(seconds: 20));
      final text = await res.transform(utf8.decoder).join().timeout(const Duration(seconds: 20));
      if (res.statusCode != 200) throw HttpException('번역 서버 응답 ${res.statusCode}', uri: url);
      return text;
    } finally {
      client.close(force: true);
    }
  }
}
