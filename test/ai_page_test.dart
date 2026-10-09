import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jj_mkvmaker/app/ai_local.dart';
import 'package:jj_mkvmaker/app/app_controller.dart';
import 'package:jj_mkvmaker/platform/windows/desktop_storage_service.dart';
import 'package:jj_mkvmaker/platform/windows/process_media_tool.dart';
import 'package:jj_mkvmaker/services/image_ai.dart';
import 'package:jj_mkvmaker/services/platform_services.dart';
import 'package:jj_mkvmaker/ui/ai_image_page.dart';

void main() {
  late Directory tmp;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('jj_ai_page_');
    AiStore.instance = AiStore(tmp.path);
  });
  tearDown(() {
    AiStore.instance = null;
    tmp.deleteSync(recursive: true);
  });

  Future<AppController> open(WidgetTester t, {AiService? service}) async {
    t.view.physicalSize = const Size(1200, 1000);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    const pp = MethodChannel('plugins.flutter.io/path_provider');
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(pp, (_) async => tmp.path);
    addTearDown(() => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(pp, null));
    final c = AppController(PlatformServices(mediaTool: ProcessMediaTool('x', 'y'), storage: DesktopStorageService()));
    if (service != null) {
      c.settings
        ..aiServices = [service]
        ..aiEngine = service.id;
    }
    await t.pumpWidget(MaterialApp(home: AiImagePage(c: c)));
    await t.pump();
    return c;
  }

  testWidgets('123: 기기 안 - 모델이 없으면 받기 안내 · 기기 밖 경고 없음', (t) async {
    await open(t);
    expect(find.textContaining('모델을 받아야 합니다'), findsOneWidget);
    expect(find.text('받기 화면으로'), findsOneWidget);
    expect(find.textContaining('기기 밖으로 나갑니다'), findsNothing);
  });

  testWidgets('123: 서비스를 고르면 "그림 · 프롬프트가 기기 밖으로 나갑니다" 를 늘 보인다', (t) async {
    await open(t, service: const AiService(id: 's1', name: 'GPU PC', url: 'http://100.1.2.3:7860', kind: 'a1111'));
    expect(find.textContaining('그림 · 프롬프트가 기기 밖으로 나갑니다 (GPU PC)'), findsOneWidget);
    expect(find.textContaining('모델을 받아야 합니다'), findsNothing);
  });

  testWidgets('123: 프롬프트 없이 만들기 → 안내', (t) async {
    await open(t, service: const AiService(id: 's1', name: 'GPU PC', url: 'http://100.1.2.3:7860', kind: 'a1111'));
    await t.tap(find.text('만들기'));
    await t.pump();
    // 159: 오류 줄 + 바로 보이는 알림 (오류 줄은 화면 밖일 수 있다)
    expect(find.text('그릴 내용을 적어 주세요'), findsNWidgets(2));
  });
}
