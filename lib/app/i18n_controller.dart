import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;

import '../core/languages.dart';
import '../l10n/tr.dart';
import '../services/ai_services.dart';
import '../services/media_tool.dart' show MediaToolException;
import '../services/model_store.dart';
import 'app_controller.dart';

/// 화면 언어 (환경 설정 > 화면 언어).
///
/// - 기본 언어 (한국어 · English · 日本語 · 简体中文) 는 프로그램에 사전이 들어 있다 (assets/l10n).
/// - 그 밖의 언어는 [addLanguage] 로 더할 수 있다: 이 기기의 AI 번역 모델 (NLLB) 로 화면 글자 전체를
///   영어 사전에서 자동 번역해 설정 폴더의 l10n/<코드>.json 에 저장한다. 더한 언어는 지울 수 있다.
/// - 언어를 바꾸면 화면 전체를 그 자리에서 다시 그린다 (보던 화면 · 웹 페이지는 그대로).
class I18nController extends ChangeNotifier {
  /// 프로그램에 들어 있는 언어 (지울 수 없음)
  static const builtIn = ['ko', 'en', 'ja', 'zh-Hans'];

  /// 언어 고르기에 보일 이름 (그 언어로 쓴 이름. 읽을 수 없는 언어를 골라도 되돌릴 수 있게)
  static const nativeNames = {
    'ko': '한국어',
    'en': 'English',
    'ja': '日本語',
    'zh-Hans': '简体中文',
    'zh-Hant': '繁體中文',
    'es': 'Español',
    'fr': 'Français',
    'de': 'Deutsch',
    'ru': 'Русский',
    'pt': 'Português',
    'it': 'Italiano',
    'vi': 'Tiếng Việt',
    'th': 'ไทย',
    'id': 'Bahasa Indonesia',
    'ms': 'Bahasa Melayu',
    'tl': 'Tagalog',
    'ar': 'العربية',
    'hi': 'हिन्दी',
    'tr': 'Türkçe',
    'pl': 'Polski',
    'nl': 'Nederlands',
    'uk': 'Українська',
    'sv': 'Svenska',
    'cs': 'Čeština',
    'el': 'Ελληνικά',
    'he': 'עברית',
    'fi': 'Suomi',
    'da': 'Dansk',
    'no': 'Norsk',
    'hu': 'Magyar',
    'ro': 'Română',
    'fa': 'فارسی',
    'bn': 'বাংলা',
    'ur': 'اردو',
    'ta': 'தமிழ்',
    'ne': 'नेपाली',
    'mn': 'Монгол',
    'km': 'ខ្មែរ',
    'lo': 'ລາວ',
    'my': 'မြန်မာ',
  };

  static String nativeName(String code) => nativeNames[code] ?? code;

  /// 앱이 시작할 때 [init] 으로 연결 (그 전에는 기본 언어만)
  AppController? _app;
  AppController get _c => _app!;

  /// 더한 언어의 사전 폴더 (설정 폴더/l10n)
  String _dir = '';

  /// 사전 읽기 (기본 언어). 테스트에서 바꿔 끼운다.
  Future<String> Function(String asset) loadAsset = rootBundle.loadString;

  void init(AppController c, String dataDir) {
    _app = c;
    _dir = p.join(dataDir, 'l10n');
  }

  /// 고를 수 있는 언어: 기본 + 더한 것
  List<String> get available => [...builtIn, ...?_app?.settings.uiLanguagesAdded];

  /// 더할 수 있는 언어 (AI 번역 모델이 아는 언어 중 아직 없는 것)
  List<Language> get addable => [
        for (final l in languages)
          if (l.nllb.isNotEmpty && !available.contains(l.code)) l,
      ];

  /// 더한 언어를 자동 번역할 수 있는지 (AI 번역이 되는 기기)
  bool get canTranslate => _app?.services.createTranslator != null;

  Future<Map<String, String>> _read(String code) async {
    try {
      final text = builtIn.contains(code)
          ? await loadAsset('assets/l10n/$code.json')
          : await File(p.join(_dir, '$code.json')).readAsString();
      return Map<String, String>.from(jsonDecode(text) as Map);
    } catch (_) {
      return const {};
    }
  }

  /// 화면 언어 바꾸기 (설정에 저장하고 화면 전체를 다시 그린다)
  Future<void> apply(String code, {bool save = true}) async {
    if (code != 'ko' && !available.contains(code)) code = 'ko';
    final dict = code == 'ko' ? const <String, String>{} : await _read(code);
    final fallback = code == 'ko' || code == 'en' ? const <String, String>{} : await _read('en');
    setTranslations(code, dict, fallback);
    if (save && _app != null && _c.settings.uiLanguage != code) {
      await _c.updateSettings((x) => x.uiLanguage = code);
    }
    rebuildAll();
    notifyListeners();
  }

  /// 화면의 모든 위젯을 다시 그린다 (상태는 그대로)
  static void rebuildAll() {
    void visit(Element e) {
      e.markNeedsBuild();
      e.visitChildren(visit);
    }

    WidgetsBinding.instance.rootElement?.visitChildren(visit);
  }

  bool _cancel = false;
  void cancel() => _cancel = true;

  /// 언어 더하기: 영어 사전을 AI 번역 모델로 그 언어로 번역해 저장한다 (모델이 없으면 먼저 내려받음).
  /// [onProgress] (단계 설명, 0.0~1.0). 취소하면 [AiCancelled].
  Future<void> addLanguage(Language l, {void Function(String phase, double progress)? onProgress}) async {
    if (!canTranslate) throw MediaToolException(tr('이 기기에서는 AI 번역을 쓸 수 없습니다.'));
    _cancel = false;
    final models = _c.services.models;
    if (!await models.isInstalled(nllbModel)) {
      await models.download(nllbModel,
          isCancelled: () => _cancel,
          onProgress: (x) => onProgress?.call(trf('번역 모델 내려받는 중 {0}%', [(x * 100).round()]), x * 0.3));
    }
    if (_cancel) throw const AiCancelled();
    onProgress?.call(tr('번역 모델 불러오는 중'), 0.3);
    final translator = _c.services.createTranslator!();
    try {
      await translator.load(await models.folderOf(nllbModel));
      final en = await _read('en');
      final dict = await translateDictionary(
        en,
        (lines, onLine) => translator.translate(lines,
            source: 'eng_Latn', target: l.nllb, onProgress: (x) {
              if (_cancel) translator.cancel();
              onLine(x);
            }),
        onProgress: (x) => onProgress?.call(trf('{0} 로 번역 중 {1}%', [nativeName(l.code), (x * 100).round()]), 0.35 + 0.65 * x),
      );
      if (_cancel) throw const AiCancelled();
      await Directory(_dir).create(recursive: true);
      await File(p.join(_dir, '${l.code}.json'))
          .writeAsString(const JsonEncoder.withIndent(' ').convert(dict));
      await _c.updateSettings((x) => x.uiLanguagesAdded = [...x.uiLanguagesAdded, l.code]);
    } finally {
      await translator.dispose();
    }
    notifyListeners();
  }

  /// 더한 언어 지우기 (지금 쓰는 언어면 한국어로)
  Future<void> removeLanguage(String code) async {
    if (builtIn.contains(code)) return;
    try {
      await File(p.join(_dir, '$code.json')).delete();
    } catch (_) {}
    await _c.updateSettings((x) => x.uiLanguagesAdded = [...x.uiLanguagesAdded]..remove(code));
    if (uiLanguage == code) {
      await apply('ko');
    } else {
      notifyListeners();
    }
  }
}

/// 영어 사전 (한국어 원문 → 영어) 을 다른 언어로 번역한 사전 (한국어 원문 → 그 언어).
/// 여러 줄은 줄마다 번역하고, 자리 표시 ({0} …) 가 사라진 번역은 영어 그대로 둔다.
Future<Map<String, String>> translateDictionary(
  Map<String, String> en,
  Future<List<String>> Function(List<String> lines, void Function(double) onProgress) translate, {
  void Function(double progress)? onProgress,
}) async {
  final keys = en.keys.toList();
  final lines = <String>[];
  final spans = <(int, int)>[];
  for (final k in keys) {
    final parts = en[k]!.split('\n');
    spans.add((lines.length, parts.length));
    lines.addAll(parts);
  }
  // 빈 줄은 번역기에 넘기지 않는다
  final todo = [for (var i = 0; i < lines.length; i++) if (lines[i].trim().isNotEmpty) i];
  final out = List<String>.of(lines);
  final got = await translate([for (final i in todo) lines[i]], (x) => onProgress?.call(x));
  for (var j = 0; j < todo.length && j < got.length; j++) {
    out[todo[j]] = got[j];
  }
  final slot = RegExp(r'\{\d+\}');
  final dict = <String, String>{};
  for (var i = 0; i < keys.length; i++) {
    final (start, n) = spans[i];
    final text = out.sublist(start, start + n).join('\n');
    final want = slot.allMatches(en[keys[i]]!).map((m) => m.group(0)).toSet();
    final have = slot.allMatches(text).map((m) => m.group(0)).toSet();
    dict[keys[i]] = want.length == have.length && have.containsAll(want) ? text : en[keys[i]]!;
  }
  return dict;
}

/// 앱 전체에서 쓰는 화면 언어 관리
final i18n = I18nController();
