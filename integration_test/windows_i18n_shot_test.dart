import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart' show kSecondaryButton;
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:jj_mkvmaker/app/app_controller.dart';
import 'package:jj_mkvmaker/app/i18n_controller.dart';
import 'package:jj_mkvmaker/main.dart';
import 'package:jj_mkvmaker/platform/windows/desktop_storage_service.dart';
import 'package:jj_mkvmaker/platform/windows/process_media_tool.dart';
import 'package:jj_mkvmaker/services/platform_services.dart';
import 'package:jj_mkvmaker/ui/license_texts.dart';
import 'package:path/path.dart' as p;

/// 140 · 158 기기 감독 확인용 (Windows): 실제 앱 (JjMkvMakerApp) 에서 Flutter 기본 화면 · 버튼이 화면 언어로 나오는지 PNG (JJ_SHOT_DIR).
/// 라이선스 화면 · 글 칸의 복사 · 붙여넣기 메뉴 · 뒤로 버튼 이름. 설정은 메모리에만 (저장하지 않음).
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final out = Platform.environment['JJ_SHOT_DIR'] ?? p.join(Directory.systemTemp.path, 'jj_shots_i18n');
  final navKey = GlobalKey<NavigatorState>();
  final shotKey = GlobalKey();
  registerAppLicenses();

  Future<void> settle(WidgetTester t, [int rounds = 10]) async {
    for (var i = 0; i < rounds; i++) {
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await t.pump();
    }
  }

  Future<void> shot(WidgetTester t, String name) async {
    await settle(t, 3);
    // 앱 전체 (창 · 메뉴 · 말풍선까지 - 앱을 감싼 경계)
    final b = shotKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final img = await t.runAsync(() => b.toImage());
    final bytes = await t.runAsync(() => img!.toByteData(format: ui.ImageByteFormat.png));
    Directory(out).createSync(recursive: true);
    File(p.join(out, '$name.png')).writeAsBytesSync(bytes!.buffer.asUint8List());
  }

  for (final lang in ['ko', 'ja']) {
    testWidgets('140 · 158: Flutter 기본 화면 · 버튼이 화면 언어로 ($lang)', (t) async {
      t.view.physicalSize = const Size(1280, 800);
      t.view.devicePixelRatio = 1;
      final c = AppController(PlatformServices(mediaTool: ProcessMediaTool('x', 'y'), storage: DesktopStorageService()));
      await t.runAsync(() => i18n.apply(lang, save: false));
      await t.runAsync(() => t.pumpWidget(RepaintBoundary(key: shotKey, child: JjMkvMakerApp(controller: c, navigatorKey: navKey))));
      await settle(t);
      // 1) 라이선스 화면 (제목 · 뒤로)
      showLicensePage(context: navKey.currentContext!, applicationName: 'JJ_MKVMaker');
      await settle(t, 15);
      await shot(t, 'i18n_${lang}_licenses');
      // 목록을 다 읽은 뒤 (줄마다 "라이선스 n개" 같은 개수 글이 화면 언어로)
      for (var i = 0; i < 600 && find.text('aria2').evaluate().isEmpty; i++) {
        await settle(t, 1);
      }
      await shot(t, 'i18n_${lang}_licenses_loaded');
      // 2) 뒤로 버튼 이름 (말풍선)
      await t.longPress(find.byType(BackButton).first);
      await settle(t, 5);
      await shot(t, 'i18n_${lang}_back_tooltip');
      navKey.currentState!.pop();
      await settle(t, 5);
      // 3) 글 칸의 복사 · 붙여넣기 메뉴 (오른쪽 클릭)
      final ctl = TextEditingController(text: 'JJ_MKVMaker 123');
      showDialog<void>(
        context: navKey.currentContext!,
        builder: (_) => AlertDialog(content: SizedBox(width: 360, child: TextField(controller: ctl))),
      );
      await settle(t, 5);
      await t.tapAt(t.getCenter(find.byType(TextField)), buttons: kSecondaryButton);
      await settle(t, 5);
      await shot(t, 'i18n_${lang}_text_menu');
      await t.runAsync(() => i18n.apply('ko', save: false));
    });
  }
}
