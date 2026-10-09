import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jj_mkvmaker/app/app_controller.dart';
import 'package:jj_mkvmaker/app/i18n_controller.dart';
import 'package:jj_mkvmaker/app/settings.dart';
import 'package:jj_mkvmaker/core/languages.dart';
import 'package:jj_mkvmaker/core/playlist.dart';
import 'package:jj_mkvmaker/l10n/tr.dart';
import 'package:jj_mkvmaker/platform/windows/desktop_storage_service.dart';
import 'package:jj_mkvmaker/platform/windows/process_media_tool.dart';
import 'package:jj_mkvmaker/services/ai_services.dart';
import 'package:jj_mkvmaker/services/model_store.dart';
import 'package:jj_mkvmaker/services/platform_services.dart';
import 'package:jj_mkvmaker/ui/home_page.dart';
import 'package:path/path.dart' as p;

/// 설치된 것처럼 보이는 모델 저장소 (내려받지 않음)
class _Models extends ModelStore {
  _Models(super.dir);
  @override
  Future<bool> isInstalled(ModelSpec m) async => true;
}

/// 가짜 번역기: "[대상] 원문" (자리 표시는 그대로)
class _Translator implements Translator {
  @override
  Future<void> load(String modelDir) async {}
  @override
  Future<List<String>> translate(List<String> lines,
          {required String source, required String target, AiProgress? onProgress}) async =>
      [for (final l in lines) l.startsWith('Make') ? 'Faire' : '[$target] $l'];
  @override
  void cancel() {}
  @override
  Future<void> dispose() async {}
}

Map<String, String> _asset(String code) =>
    Map<String, String>.from(jsonDecode(File('assets/l10n/$code.json').readAsStringSync()) as Map);

void main() {
  late Directory dir;
  late AppController c;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('jj_i18n_');
    c = AppController(PlatformServices(
      mediaTool: ProcessMediaTool('x', 'y'),
      storage: DesktopStorageService(),
      createTranslator: _Translator.new,
      models: _Models(dir.path),
    ));
    i18n
      ..init(c, dir.path)
      ..loadAsset = (path) async => File(path).readAsString();
  });
  tearDown(() async {
    setTranslations('ko', const {});
    dir.deleteSync(recursive: true);
  });

  test('기본 사전: 영어 · 일본어 · 중국어가 같은 열쇠를 모두 가진다', () {
    final en = _asset('en'), ja = _asset('ja'), zh = _asset('zh-Hans');
    expect(en.length, greaterThan(700));
    expect(ja.keys.toSet(), en.keys.toSet());
    expect(zh.keys.toSet(), en.keys.toSet());
    expect(en['MKV 만들기'], 'Make MKV');
    expect(ja['환경 설정'], '環境設定');
    expect(zh['취소'], '取消');
  });

  test('언어 바꾸기: tr · trf · 선택 목록 이름 · 언어 이름이 그 언어로, 한국어로 되돌리기', () async {
    expect(tr('MKV 만들기'), 'MKV 만들기');
    await i18n.apply('en');
    expect(c.settings.uiLanguage, 'en');
    expect(tr('MKV 만들기'), 'Make MKV');
    expect(trf('동영상 {0}개 · 전체 선택', [3]), '3 videos · select all');
    expect(PlaylistMode.folder.label, 'All videos in the same folder');
    expect(languageOf('ja').name, 'Japanese');
    expect(tr('사전에 없는 글자'), '사전에 없는 글자'); // 없으면 원문
    await i18n.apply('ja');
    expect(tr('환경 설정'), '環境設定');
    await i18n.apply('ko');
    expect(tr('환경 설정'), '환경 설정');
    expect(AppSettings.fromJson(c.settings.toJson()).uiLanguage, 'ko');
  });

  test('58 · 102: 시스템 언어 따르기 - 설정에는 system, 화면은 기기 언어 (들어 있지 않으면 English), 처음 설치의 기본', () async {
    expect(I18nController.systemCode('ko_KR'), 'ko');
    expect(I18nController.systemCode('ja_JP'), 'ja');
    expect(I18nController.systemCode('zh_Hans_CN'), 'zh-Hans');
    expect(I18nController.systemCode('zh_CN'), 'zh-Hans');
    expect(I18nController.systemCode('en_US'), 'en');
    expect(I18nController.systemCode('fr_FR'), 'en');
    expect(AppSettings().uiLanguage, I18nController.system); // 처음 설치
    expect(AppSettings.fromJson({'uiLanguage': 'ko'}).uiLanguage, 'ko'); // 고른 언어는 그대로
    await i18n.apply(I18nController.system);
    expect(c.settings.uiLanguage, I18nController.system);
    expect(uiLanguage, I18nController.systemCode());
    await i18n.apply('ko');
  });

  test('사전 번역: 여러 줄은 줄마다, 자리 표시가 사라지면 영어 그대로', () async {
    final out = await translateDictionary(
      {'a': 'Line one\nLine two', 'b': 'Make {0} MKVs', 'c': '', 'd': '{0} videos'},
      (lines, onProgress) async => [for (final l in lines) l.startsWith('Make') ? 'Faire' : 'X:$l'],
    );
    expect(out['a'], 'X:Line one\nX:Line two');
    expect(out['b'], 'Make {0} MKVs'); // {0} 이 사라져서 영어 그대로
    expect(out['c'], '');
    expect(out['d'], 'X:{0} videos');
  });

  test('언어 추가 (AI 번역) → 고르기 → 지우기', () async {
    final fr = languageOf('fr');
    expect(i18n.addable.map((l) => l.code), contains('fr'));
    expect(i18n.addable.map((l) => l.code), isNot(contains('en')));
    await i18n.addLanguage(fr);
    expect(c.settings.uiLanguagesAdded, ['fr']);
    expect(i18n.available, ['ko', 'en', 'ja', 'zh-Hans', 'fr']);
    expect(File(p.join(dir.path, 'l10n', 'fr.json')).existsSync(), isTrue);
    await i18n.apply('fr');
    expect(tr('취소'), '[fra_Latn] Cancel');
    expect(trf('{0}개 선택', [2]), '[fra_Latn] 2 selected');
    await i18n.removeLanguage('fr');
    expect(c.settings.uiLanguagesAdded, isEmpty);
    expect(uiLanguage, 'ko', reason: '쓰던 언어를 지우면 한국어로');
    expect(File(p.join(dir.path, 'l10n', 'fr.json')).existsSync(), isFalse);
  });

  testWidgets('화면 언어를 바꾸면 열려 있는 화면이 바로 그 언어로 다시 그려진다', (tester) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: HomePage(c: c, onExit: () {})));
    expect(find.text('동영상 추가'), findsWidgets);
    await tester.runAsync(() => i18n.apply('en'));
    await tester.pump();
    expect(find.text('Add videos'), findsWidgets);
    expect(find.text('동영상 추가'), findsNothing);
    await tester.runAsync(() => i18n.apply('zh-Hans'));
    await tester.pump();
    expect(find.text('添加视频'), findsWidgets);
  });
}
