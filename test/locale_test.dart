import 'package:flutter/cupertino.dart' show CupertinoLocalizations;
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jj_mkvmaker/main.dart';

void main() {
  test('140 · 158: 앱 화면 언어 → Flutter 기본 글의 언어', () {
    expect(JjMkvMakerApp.localeOf('ko'), const Locale('ko'));
    expect(JjMkvMakerApp.localeOf('en'), const Locale('en'));
    expect(JjMkvMakerApp.localeOf('ja'), const Locale('ja'));
    expect(JjMkvMakerApp.localeOf('zh-Hans'), const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hans'));
    expect(JjMkvMakerApp.localeOf('zh-Hant'), const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant'));
    expect(JjMkvMakerApp.localeOf('pt-BR'), const Locale('pt', 'BR'));
    // 앱이 더한 언어 (기계 번역 사전) 도 Flutter 가 알면 그 언어로 - 한국어가 섞이지 않게
    expect(JjMkvMakerApp.localeOf('de'), const Locale('de'));
    expect(JjMkvMakerApp.localeOf('vi'), const Locale('vi'));
    // Flutter 가 모르는 언어만 영어
    expect(JjMkvMakerApp.localeOf('xx'), const Locale('en'));
    expect(JjMkvMakerApp.localeOf('tlh'), const Locale('en'));
  });

  Future<String> backTooltip(WidgetTester tester, String code) async {
    final locale = JjMkvMakerApp.localeOf(code);
    late String text;
    await tester.pumpWidget(MaterialApp(
      key: ValueKey(code),
      locale: locale,
      supportedLocales: JjMkvMakerApp.supportedLocalesFor(locale),
      localizationsDelegates: JjMkvMakerApp.localizationsDelegates,
      home: Builder(builder: (context) {
        text = MaterialLocalizations.of(context).backButtonTooltip;
        return const SizedBox();
      }),
    ));
    await tester.pumpAndSettle();
    return text;
  }

  testWidgets('140 · 158: 뒤로 버튼 이름이 화면 언어로 (모르는 언어만 영어)', (tester) async {
    expect(await backTooltip(tester, 'ko'), '뒤로');
    expect(await backTooltip(tester, 'de'), 'Zurück');
    expect(await backTooltip(tester, 'xx'), 'Back');
  });

  testWidgets('140 · 158: Material 만 아는 언어 (Cupertino 글 없음) 도 열림 - Cupertino 글은 영어', (tester) async {
    final only = kMaterialSupportedLanguages.where((c) => !GlobalCupertinoLocalizations.delegate.isSupported(Locale(c))).toList();
    for (final c in only.isEmpty ? ['ko'] : only) {
      final locale = JjMkvMakerApp.localeOf(c);
      expect(locale, Locale(c));
      late String cup;
      await tester.pumpWidget(MaterialApp(
        key: ValueKey(c),
        locale: locale,
        supportedLocales: JjMkvMakerApp.supportedLocalesFor(locale),
        localizationsDelegates: JjMkvMakerApp.localizationsDelegates,
        home: Builder(builder: (context) {
          cup = CupertinoLocalizations.of(context).cutButtonLabel;
          return const SizedBox();
        }),
      ));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: c);
      expect(cup, isNotEmpty, reason: c);
    }
  });

  testWidgets('140 · 158: 번체 중국어는 간체로 바뀌지 않음 (글자 체계까지 고름)', (tester) async {
    late Locale got;
    final locale = JjMkvMakerApp.localeOf('zh-Hant');
    await tester.pumpWidget(MaterialApp(
      locale: locale,
      supportedLocales: JjMkvMakerApp.supportedLocalesFor(locale),
      localizationsDelegates: JjMkvMakerApp.localizationsDelegates,
      home: Builder(builder: (context) {
        got = Localizations.localeOf(context);
        return const SizedBox();
      }),
    ));
    await tester.pumpAndSettle();
    expect(got.scriptCode, 'Hant');
  });
}
