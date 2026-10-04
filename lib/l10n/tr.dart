/// 화면 글자 번역 (한국어 원문 → 고른 언어).
///
/// 코드의 화면 글자는 한국어 원문을 그대로 열쇠로 쓴다: `tr('MKV 만들기')`, `trf('동영상 {0}개', [n])`.
/// 고른 언어의 사전에 없으면 영어 사전, 그래도 없으면 한국어 원문을 보여 준다.
/// 사전은 앱이 시작할 때 (그리고 언어를 바꿀 때) [setTranslations] 로 넣는다 (lib/app/i18n_controller.dart).
library;

String _lang = 'ko';
Map<String, String> _dict = const {};
Map<String, String> _fallback = const {};

/// 지금 화면 언어 코드 (ko · en · ja · zh-Hans …)
String get uiLanguage => _lang;

/// 화면 언어와 사전을 바꾼다. [fallback] 은 사전에 없는 글자를 찾을 사전 (보통 영어).
void setTranslations(String lang, Map<String, String> dict, [Map<String, String> fallback = const {}]) {
  _lang = lang;
  _dict = dict;
  _fallback = fallback;
}

/// 한국어 원문 → 지금 언어
String tr(String ko) {
  if (_lang == 'ko') return ko;
  return _dict[ko] ?? _fallback[ko] ?? ko;
}

final _slot = RegExp(r'\{(\d+)\}');

/// 자리 표시 ({0}, {1} …) 가 있는 글자: `trf('동영상 {0}개', [n])`
String trf(String ko, List<Object?> args) => tr(ko).replaceAllMapped(_slot, (m) {
      final i = int.parse(m.group(1)!);
      return i < args.length ? '${args[i]}' : m.group(0)!;
    });
