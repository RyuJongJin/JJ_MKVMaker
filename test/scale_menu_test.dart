import 'dart:io';

import 'package:flutter/gestures.dart' show kSecondaryButton;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jj_mkvmaker/app/app_controller.dart';
import 'package:jj_mkvmaker/app/bookmarks_controller.dart';
import 'package:jj_mkvmaker/app/download_manager.dart';
import 'package:jj_mkvmaker/app/settings.dart';
import 'package:jj_mkvmaker/core/models.dart';
import 'package:jj_mkvmaker/platform/windows/desktop_storage_service.dart';
import 'package:jj_mkvmaker/platform/windows/process_media_tool.dart';
import 'package:jj_mkvmaker/services/app_shell.dart';
import 'package:jj_mkvmaker/services/platform_services.dart';
import 'package:jj_mkvmaker/services/system_usage.dart';
import 'package:jj_mkvmaker/ui/app_actions.dart';
import 'package:jj_mkvmaker/ui/home_page.dart';
import 'package:path/path.dart' as p;

class _Shell extends NoopShell {
  final revealed = <String>[];
  @override
  Future<void> revealFile(String path) async => revealed.add(path);
}

void main() {
  test('화면 크기 설정: 범위 · 5% 단위 · 저장', () {
    expect(AppSettings.clampUiScale(null), 1.0);
    expect(AppSettings.clampUiScale(0.1), 0.5);
    expect(AppSettings.clampUiScale(9), 2.5);
    expect(AppSettings.clampUiScale(2.5), 2.5);
    expect(AppSettings.clampUiScale(1.1000000001), 1.1);
    final s = AppSettings()
      ..uiScale = 1.2
      ..uiScaleDefault = 0.9;
    final back = AppSettings.fromJson(s.toJson());
    expect([back.uiScale, back.uiScaleDefault], [1.2, 0.9]);
  });

  testWidgets('화면 크기 버튼: − · + 로 10% 씩, 숫자를 누르면 기본 크기로, 화면이 실제로 커진다', (tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final c = AppController(PlatformServices(mediaTool: ProcessMediaTool('x', 'y'), storage: DesktopStorageService()));
    await tester.pumpWidget(MaterialApp(
      builder: (context, child) => UiScaler(c: c, child: child!),
      home: Scaffold(
        body: Column(children: [
          Row(children: [const Spacer(), AppActions(c: c, onExit: () {})]),
          const SizedBox(width: 100, height: 100, key: Key('box')),
        ]),
      ),
    ));
    expect(find.text('100%'), findsOneWidget);
    expect(tester.getSize(find.byKey(const Key('box'))), const Size(100, 100));
    final settingsAt = tester.getCenter(find.byTooltip('환경 설정'));
    // − · 숫자 · + 는 환경 설정 버튼의 왼쪽
    expect(tester.getCenter(find.byTooltip('화면 크게')).dx, lessThan(settingsAt.dx));

    await tester.tap(find.byTooltip('화면 크게'));
    await tester.pump();
    await tester.tap(find.byTooltip('화면 크게'));
    await tester.pump();
    expect(c.settings.uiScale, 1.2);
    expect(find.text('120%'), findsOneWidget);
    // 화면에 그려지는 크기가 1.2 배
    final r = tester.getRect(find.byKey(const Key('box')));
    expect(r.width, closeTo(120, 0.01));
    // 안쪽은 1200/1.2 = 1000 너비의 화면이라고 여기고 배치 → 오른쪽 끝 버튼은 여전히 창 오른쪽 끝
    expect(tester.getRect(find.byTooltip('종료')).right, closeTo(1200, 10));

    await tester.tap(find.byTooltip('화면 작게'));
    await tester.pump();
    expect(c.settings.uiScale, 1.1);

    // 기본 크기 90% 로 정해 두고 숫자를 누르면 그 크기로
    c.settings.uiScaleDefault = 0.9;
    await tester.tap(find.text('110%'));
    await tester.pump();
    expect(c.settings.uiScale, 0.9);
    expect(find.text('90%'), findsOneWidget);

    // 끝까지 줄이면 − 가 꺼진다
    c.settings.uiScale = AppSettings.uiScaleMin;
    c.updateSettings((_) {});
    await tester.pump();
    expect(tester.widget<IconButton>(find.widgetWithIcon(IconButton, Icons.remove)).onPressed, isNull);
  });

  testWidgets('동영상 목록 오른쪽 클릭 메뉴 · [폴더 열기] 버튼', (tester) async {
    tester.view.physicalSize = const Size(1500, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final shell = _Shell();
    final c = AppController(
        PlatformServices(mediaTool: ProcessMediaTool('x', 'y'), storage: DesktopStorageService(), shell: shell));
    c.videos.addAll([VideoItem(r'D:\v\첫째.mp4'), VideoItem(r'D:\v\둘째.mp4')]);
    c.selected = c.videos.first;
    await tester.pumpWidget(MaterialApp(home: HomePage(c: c)));

    // [폴더 열기] (재생 버튼 옆): 지금 보고 있는 동영상
    await tester.tap(find.text('폴더 열기'));
    expect(shell.revealed, [r'D:\v\첫째.mp4']);

    // 둘째 줄에서 오른쪽 클릭 → 그 줄이 선택되고 메뉴
    await tester.tapAt(tester.getCenter(find.text('둘째.mp4').first), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    expect(c.selected, c.videos[1]);
    for (final label in ['대상 폴더 열기', '자막 파일 추가', '삭제 (목록에서 제거)']) {
      expect(find.text(label), findsWidgets, reason: label);
    }
    await tester.tap(find.text('대상 폴더 열기'));
    await tester.pumpAndSettle();
    expect(shell.revealed.last, r'D:\v\둘째.mp4');

    // 삭제
    await tester.tapAt(tester.getCenter(find.text('둘째.mp4').first), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text('삭제 (목록에서 제거)'));
    await tester.pumpAndSettle();
    expect([for (final v in c.videos) v.fileName], ['첫째.mp4']);
  });

  testWidgets('MKV 화면 위쪽 막대: 창이 좁아도 넘치지 않고 설정 · 종료 버튼이 창 안에 있다', (tester) async {
    addTearDown(tester.view.reset);
    final dir = Directory.systemTemp.createTempSync('jj_bar_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final c = AppController(PlatformServices(
      mediaTool: ProcessMediaTool('x', 'y'),
      storage: DesktopStorageService(),
      createRecognizer: () => throw UnimplementedError(),
      createTranslator: () => throw UnimplementedError(),
      createMediaPlayer: () => throw UnimplementedError(),
      usage: _Usage(),
    ));
    c.videos.addAll([VideoItem(r'D:\v\a.mp4'), VideoItem(r'D:\v\b.mp4')]);
    c.selected = c.videos.first;
    c.toggleChecked(c.videos.first);
    final d = DownloadManager(backends: const [], settings: () => c.settings, readClipboard: () async => null);
    final bm = BookmarksController(p.join(dir.path, 'bm.json'));

    for (final width in [2300.0, 1600.0, 1300.0, 1100.0, 900.0]) {
      tester.view.physicalSize = Size(width, 800);
      tester.view.devicePixelRatio = 1;
      await tester.pumpWidget(MaterialApp(
          key: UniqueKey(), home: HomePage(c: c, downloads: d, bookmarks: bm, onExit: () {})));
      await tester.pump();
      expect(tester.takeException(), isNull, reason: '너비 $width 에서 넘침');
      final exit = tester.getRect(find.byTooltip('종료'));
      expect(exit.right, lessThanOrEqualTo(width), reason: '너비 $width: 종료 버튼이 창 밖');
      expect(tester.getRect(find.byTooltip('화면 크게')).left, greaterThan(0));
      // 넓을 때는 글이 있는 버튼, 좁을 때는 아이콘만 (기능은 그대로)
      expect(find.text('자막 만들기 & MKV 만들기 (1)'), width >= 2300 ? findsOneWidget : anything);
      // MKV 만들기: 아주 좁으면 아이콘만 (체크 수는 마우스를 올리면)
      expect(find.byTooltip('MKV 만들기 (1)'), findsOneWidget);
      if (width >= 1300) expect(find.textContaining('MKV 만들기 (1)'), findsWidgets);
    }
    // 가장 좁을 때: 아이콘만 남고 설명은 마우스를 올리면
    expect(find.text('동영상 추가'), findsNothing);
    expect(find.byTooltip(RegExp('^동영상 추가')), findsOneWidget);
    expect(find.byTooltip(RegExp('^선택한 파일 재생')), findsOneWidget);
    d.dispose();
  });
}

class _Usage implements SystemUsage {
  @override
  UsageSample? read() => const UsageSample(cpu: 0.5, memUsed: 8 << 30, memTotal: 16 << 30);
  @override
  (int, int)? disk(String path) => (100 << 30, 500 << 30);
}
