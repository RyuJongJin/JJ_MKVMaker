import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:jj_mkvmaker/app/settings.dart';
import 'package:jj_mkvmaker/core/web_translate.dart';

void main() {
  test('화면 언어 → Google 언어 코드 · 같은 언어 판단', () {
    expect(googleLang('ko'), 'ko');
    expect(googleLang('zh-Hans'), 'zh-CN');
    expect(googleLang('zh-Hant'), 'zh-TW');
    expect(googleLang('he'), 'iw');
    expect(sameLanguage('ko-KR', 'ko'), isTrue);
    expect(sameLanguage('en', 'ko'), isFalse);
    expect(sameLanguage('zh-CN', 'zh-TW'), isFalse);
    expect(sameLanguage('zh', 'zh-CN'), isTrue);
    expect(sameLanguage('iw', 'he'), isTrue);
    expect(sameLanguage('', 'ko'), isFalse);
  });

  test('모은 글자 읽기: JSON 문자열 · 두 번 감싼 문자열 · Map · 잘못된 값', () {
    const json = '{"items":[[0,"Hello"],[3,"Sign in"]],"more":true}';
    for (final raw in [json, jsonEncode(json), jsonDecode(json)]) {
      final c = CollectedText.parse(raw)!;
      expect(c.ids, [0, 3]);
      expect(c.texts, ['Hello', 'Sign in']);
      expect(c.more, isTrue);
    }
    expect(CollectedText.parse('{"items":[],"same":true}')!.same, isTrue);
    expect(CollectedText.parse(null), isNull);
    expect(CollectedText.parse('not json'), isNull);
  });

  test('Google 번역: 한 번에 보내고, 이미 그 언어인 글은 null, 같은 글은 다시 묻지 않음', () async {
    final asked = <List<String>>[];
    final urls = <Uri>[];
    final t = WebPageTranslator(post: (url, body) async {
      urls.add(url);
      final q = body.split('&').map((x) => Uri.decodeQueryComponent(x.substring(2))).toList();
      asked.add(q);
      return jsonEncode([
        for (final x in q)
          x == '안녕' ? [x, 'ko'] : ['[ko] $x', 'en'],
      ]);
    });
    final r = await t.translate(['Hello', '안녕', 'Hello', 'Sign in & go'], 'ko');
    expect(r, ['[ko] Hello', null, '[ko] Hello', '[ko] Sign in & go']);
    expect(asked, [
      ['Hello', '안녕', 'Sign in & go'], // 같은 글은 한 번만
    ]);
    expect(urls.single.queryParameters, containsPair('tl', 'ko'));
    expect(urls.single.queryParameters, containsPair('sl', 'auto'));
    expect(urls.single.queryParameters, containsPair('format', 'text'));

    // 두 번째는 기억해 둔 것으로 (서버에 묻지 않음)
    expect(await t.translate(['Sign in & go', '안녕'], 'ko'), ['[ko] Sign in & go', null]);
    expect(asked, hasLength(1));
    // 대상 언어가 바뀌면 다시 묻는다
    await t.translate(['Hello'], 'ja');
    expect(asked, hasLength(2));
  });

  test('Google 번역: 많으면 나눠 보낸다 (100개 · 3000자)', () async {
    final sizes = <int>[];
    final t = WebPageTranslator(post: (url, body) async {
      final q = body.split('&').map((x) => Uri.decodeQueryComponent(x.substring(2))).toList();
      sizes.add(q.length);
      return jsonEncode([for (final x in q) ['T$x', 'en']]);
    });
    final texts = [for (var i = 0; i < 250; i++) 'line $i'];
    final r = await t.translate(texts, 'ko');
    expect(r.first, 'Tline 0');
    expect(r.last, 'Tline 249');
    expect(sizes, [100, 100, 50]);

    sizes.clear();
    await t.translate([for (var i = 0; i < 4; i++) 'x' * 1000 + '$i'], 'ko');
    expect(sizes, [2, 2]);
  });

  test('Google 응답이 이상하면 오류 (개수가 다름)', () async {
    final t = WebPageTranslator(post: (url, body) async => '[["a","en"]]');
    expect(() => t.translate(['a', 'b'], 'ko'), throwsFormatException);
    expect(WebPageTranslator.parseGoogleResponse('["가","나"]', 2), [('가', ''), ('나', '')]);
  });

  test('스크립트: CEF 가 앞에 return 을 붙여도 되게 줄바꿈 없이 시작 · 대상 언어 · 번역 값이 들어간다', () {
    final collect = webTranslateCollectScript('zh-CN', force: true);
    expect(collect, startsWith('(function(tl,force,max){'));
    expect(collect, endsWith('("zh-CN",true,300)'));
    final apply = webTranslateApplyScript({0: '안녕 "세상"', 2: null}, same: true);
    expect(apply, startsWith('(function(m,same){'));
    expect(apply, endsWith('({"0":"안녕 \\"세상\\"","2":null},true)'));
    expect(webTranslateRestoreScript, startsWith('(function(){'));
  });

  test('설정: 번역 (기본 끔) · JavaScript (기본 켬) 저장 · 읽기', () {
    final d = AppSettings();
    expect(d.webTranslate, isFalse);
    expect(d.webJavaScript, isTrue);
    final s = AppSettings.fromJson(jsonDecode(jsonEncode((AppSettings()
          ..webTranslate = true
          ..webJavaScript = false)
        .toJson())) as Map<String, dynamic>);
    expect(s.webTranslate, isTrue);
    expect(s.webJavaScript, isFalse);
  });
}
