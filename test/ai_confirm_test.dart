import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jj_mkvmaker/app/app_controller.dart';
import 'package:jj_mkvmaker/core/languages.dart';
import 'package:jj_mkvmaker/core/models.dart';
import 'package:jj_mkvmaker/platform/windows/desktop_storage_service.dart';
import 'package:jj_mkvmaker/platform/windows/process_media_tool.dart';
import 'package:jj_mkvmaker/services/model_store.dart';
import 'package:jj_mkvmaker/services/platform_services.dart';
import 'package:jj_mkvmaker/ui/ai_dialog.dart';

/// 138: [MKV 만들기] 와 헷갈려 오래 걸리는 AI 작업이 돌지 않게 - AI 쪽은 늘 할 일 · 대상 수 · 자막 언어 · 예상 시간을 보이고 묻는다
void main() {
  test('예상 시간: 영상 1시간 ≈ 음성인식 15~30분 + 번역할 언어마다 10~20분', () {
    expect(aiEstimateMinutes(const Duration(hours: 1), 0), (15, 30));
    expect(aiEstimateMinutes(const Duration(hours: 2), 2), (70, 140));
    expect(aiEstimateMinutes(Duration.zero, 2), isNull);
    final ko = languageOf('ko'), en = languageOf('en'), ja = languageOf('ja');
    expect(aiTranslateCount(AiOptions(source: ko, targets: {ko, en, ja}, whisper: whisperModels.first)), 2);
    expect(aiTranslateCount(AiOptions(targets: {ko, en, ja}, whisper: whisperModels.first)), 2, reason: '자동 감지면 하나는 원어로');
  });

  testWidgets('"매번 묻기" 를 끄면 묻지 않되 (사용자 설정) 3초 알림 [취소] 뒤에 시작 - [취소] 면 시작하지 않음', (tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final c = AppController(PlatformServices(mediaTool: ProcessMediaTool('x', 'y'), storage: DesktopStorageService()));
    c.settings.askAiOptions = false;
    final v1 = VideoItem(r'C:\v\a.mp4')..info = const MediaInfo(duration: Duration(minutes: 30));
    final v2 = VideoItem(r'C:\v\b.mp4')..info = const MediaInfo(duration: Duration(minutes: 30));
    late BuildContext ctx;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: Builder(builder: (context) {
      ctx = context;
      return const SizedBox();
    }))));
    final logs0 = c.logs.length;
    final done = showAiDialog(ctx, c, v1, targets: [v1, v2], thenBuild: true);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(AlertDialog), findsNothing, reason: '묻는 창은 띄우지 않는다 (사용자 설정)');
    expect(find.text('AI 자막 → MKV (동영상 2개 · 약 35~70분) 을 시작합니다'), findsOneWidget);
    expect(c.busy, isFalse, reason: '3초 동안은 시작하지 않음');
    await tester.tap(find.text('취소'));
    await tester.pump(const Duration(seconds: 4));
    await done;
    expect(c.busy, isFalse);
    expect(c.logs.length, logs0, reason: '[취소] 면 아무것도 하지 않음');
  });

  test('3초 알림 글: 길이를 모르면 시간 없이', () {
    final o = AiOptions(targets: {languageOf('ko')}, whisper: whisperModels.first);
    expect(aiStartNotice([VideoItem(r'C:\v\a.mp4')], o, thenBuild: false), 'AI 자막 (동영상 1개) 을 시작합니다');
  });

  testWidgets('묻기가 켜져 있으면 (처음 값) 설정 창 맨 위에 계획 (할 일 · 대상 · 언어 · 예상 시간)', (tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final c = AppController(PlatformServices(mediaTool: ProcessMediaTool('x', 'y'), storage: DesktopStorageService()));
    expect(c.settings.askAiOptions, isTrue);
    final v1 = VideoItem(r'C:\v\a.mp4')..info = const MediaInfo(duration: Duration(hours: 1));
    late BuildContext ctx;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: Builder(builder: (context) {
      ctx = context;
      return const SizedBox();
    }))));
    final done = showAiDialog(ctx, c, v1, targets: [v1]);
    await tester.pumpAndSettle();
    expect(find.text('AI 자막 만들기 (MKV 는 만들지 않음)'), findsOneWidget);
    expect(find.text('동영상 1개'), findsOneWidget);
    expect(find.text('예상 시간'), findsOneWidget);
    expect(find.textContaining('1시간 0분'), findsOneWidget);
    await tester.tap(find.text('취소'));
    await tester.pumpAndSettle();
    await done;
    expect(c.busy, isFalse);
  });
}
