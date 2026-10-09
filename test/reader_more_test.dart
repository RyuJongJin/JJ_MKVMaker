import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jj_mkvmaker/app/app_controller.dart';
import 'package:jj_mkvmaker/app/settings.dart';
import 'package:jj_mkvmaker/core/reader_sources.dart';
import 'package:jj_mkvmaker/platform/windows/desktop_storage_service.dart';
import 'package:jj_mkvmaker/platform/windows/process_media_tool.dart';
import 'package:jj_mkvmaker/services/platform_services.dart';
import 'package:jj_mkvmaker/ui/reader_page.dart';

/// 크기를 정한 그림들 (가로로 긴 것 = 두 쪽이 붙은 그림)
class _Sized extends ReaderSource {
  final List<ui.Image> images;
  final widths = <int, List<int>>{};
  _Sized(this.images);
  @override
  String get title => 'comic';
  @override
  int get length => images.length;
  @override
  String pageName(int i) => 'p$i.png';
  @override
  Future<ReaderImage> load(int i, {required int maxWidth}) async {
    (widths[i] ??= []).add(maxWidth);
    return ReaderImage(image: images[i].clone());
  }
}

void main() {
  late List<bool> screenOn;
  setUp(() {
    screenOn = [];
    ReaderPage.keepScreenOn = (on) async => screenOn.add(on);
  });

  AppController controller() =>
      AppController(PlatformServices(mediaTool: ProcessMediaTool('x', 'y'), storage: DesktopStorageService()));

  Future<_Sized> source(WidgetTester t, List<(int, int)> sizes) async {
    final images = <ui.Image>[];
    await t.runAsync(() async {
      for (final (w, h) in sizes) {
        images.add(await createTestImage(width: w, height: h));
      }
    });
    return _Sized(images);
  }

  Future<void> open(WidgetTester t, AppController c, ReaderSource src, {double width = 900, int start = 0}) async {
    t.view.physicalSize = Size(width, 1200);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(home: ReaderPage(c: c, source: src, start: start)));
    await t.pumpAndSettle();
  }

  Future<void> tapAt(WidgetTester t, double x) async {
    await t.tapAt(Offset(x, 600));
    await t.pumpAndSettle();
  }

  test('117 · 119 설정: 처음 값 3초 · 자동, 1 ~ 60 초', () {
    final s = AppSettings.fromJson({});
    expect((s.readerAutoSeconds, s.readerSplit), (3, 'auto'));
    final b = AppSettings.fromJson((AppSettings()
          ..readerAutoSeconds = 12
          ..readerSplit = 'on')
        .toJson());
    expect((b.readerAutoSeconds, b.readerSplit), (12, 'on'));
    expect(AppSettings.fromJson({'readerAutoSeconds': 500}).readerAutoSeconds, 60);
    expect(AppSettings.fromJson({'readerAutoSeconds': 0}).readerAutoSeconds, 1);
    expect(AppSettings.fromJson({'readerSplit': 'x'}).readerSplit, 'auto');
  });

  testWidgets('119: 자동이면 가로로 긴 그림만 반씩 (12-1 · 12-2), 표지 (세로) 는 통째 · 반쪽은 두 배 너비로 읽음', (t) async {
    final c = controller();
    final src = await source(t, [(100, 200), (200, 100), (100, 200)]);
    await open(t, c, src);
    expect(find.text('1 / 3'), findsOneWidget);
    await tapAt(t, 850);
    expect(find.text('2-1 / 3장'), findsOneWidget);
    expect(src.widths[1], contains(1800), reason: '반쪽이 화면 가득이어도 흐리지 않게');
    await tapAt(t, 850);
    expect(find.text('2-2 / 3장'), findsOneWidget);
    await tapAt(t, 850);
    expect(find.text('3 / 3장'), findsOneWidget);
    await tapAt(t, 50);
    expect(find.text('2-2 / 3장'), findsOneWidget);

    // 버튼: 자동 → 켜기 (모든 장) → 끄기 → 자동
    await t.tap(find.byTooltip('두 쪽 나눠 보기: 자동 - 가로로 긴 그림만 (누르면 켜기)'));
    await t.pumpAndSettle();
    expect(c.settings.readerSplit, 'on');
    expect(find.text('2-2 / 3장'), findsOneWidget, reason: '보던 쪽 그대로');
    await tapAt(t, 850);
    expect(find.text('3-1 / 3장'), findsOneWidget);
    await t.tap(find.byTooltip('두 쪽 나눠 보기: 켜기 (누르면 끄기)'));
    await t.pumpAndSettle();
    expect(c.settings.readerSplit, 'off');
    expect(find.text('3 / 3'), findsOneWidget);
    await t.tap(find.byTooltip('두 쪽 나눠 보기: 끄기 (누르면 자동)'));
    await t.pumpAndSettle();
    expect(c.settings.readerSplit, 'auto');
  });

  testWidgets('119: 오른쪽 → 왼쪽으로 읽으면 오른쪽 반부터', (t) async {
    final c = controller()..settings.readerRtl = true;
    final src = await source(t, [(200, 100)]);
    await open(t, c, src);
    expect(find.text('1-1 / 1장'), findsOneWidget);
    Align half() => t.widget<Align>(find.descendant(of: find.byType(ClipRect), matching: find.byType(Align)).first);
    expect(half().alignment, Alignment.centerRight);
    await tapAt(t, 50); // 만화: 왼쪽 = 다음
    expect(find.text('1-2 / 1장'), findsOneWidget);
    expect(half().alignment, Alignment.centerLeft);
  });

  testWidgets('120: 회전하면 회전한 뒤의 가로 · 세로로 나누기를 다시 판단 · 상하 반전 · 파일은 그대로', (t) async {
    final c = controller();
    final src = await source(t, [(100, 200), (100, 200)]);
    await open(t, c, src);
    expect(find.text('1 / 2'), findsOneWidget);
    await t.tap(find.byTooltip('90° 회전 (시계 방향)'));
    await t.pumpAndSettle();
    expect(t.widget<RotatedBox>(find.descendant(of: find.byType(FittedBox), matching: find.byType(RotatedBox)).first)
        .quarterTurns, 1);
    expect(find.text('1-1 / 2장'), findsOneWidget, reason: '돌리니 가로로 길어져 반씩');
    await t.tap(find.byTooltip('반대로 90° 회전'));
    await t.pumpAndSettle();
    expect(find.text('1 / 2'), findsOneWidget);
    expect(find.descendant(of: find.byType(FittedBox), matching: find.byType(RotatedBox)), findsNothing);
    await t.tap(find.byTooltip('상하 반전'));
    await t.pumpAndSettle();
    expect(find.byWidgetPredicate((w) => w is Transform && w.transform.storage[5] == -1), findsWidgets);
    // 다음 장에도 같이
    await tapAt(t, 850);
    expect(find.text('2 / 2'), findsOneWidget);
    expect(find.byWidgetPredicate((w) => w is Transform && w.transform.storage[5] == -1), findsWidgets);
  });

  testWidgets('117: 계속 보기 - 정한 초마다 다음 장, ▲ · ▼ 로 간격, 마지막 장에서 멈춤, 화면 켜 두기', (t) async {
    final c = controller();
    final src = await source(t, [(100, 200), (100, 200), (100, 200), (100, 200)]);
    await open(t, c, src);
    await t.tap(find.byTooltip('계속 보기 간격 늘리기 (지금 3초)'));
    await t.pumpAndSettle();
    expect(c.settings.readerAutoSeconds, 4);
    expect(find.text('4초'), findsOneWidget);
    await t.tap(find.byTooltip('계속 보기 간격 줄이기 (지금 4초)'));
    await t.pumpAndSettle();
    await t.tap(find.byTooltip('계속 보기 간격 줄이기 (지금 3초)'));
    await t.pumpAndSettle();
    expect(c.settings.readerAutoSeconds, 2);

    await t.tap(find.byTooltip('계속 보기 (2초마다 다음 장)'));
    await t.pump();
    expect(screenOn, [true]);
    await t.pump(const Duration(milliseconds: 1900));
    expect(find.text('1 / 4'), findsOneWidget);
    await t.pump(const Duration(milliseconds: 200));
    expect(find.text('2 / 4'), findsOneWidget);
    await t.pump(const Duration(seconds: 2));
    await t.pump(const Duration(seconds: 2));
    expect(find.text('4 / 4'), findsOneWidget);
    await t.pump(const Duration(seconds: 2));
    expect(find.byTooltip('계속 보기 (2초마다 다음 장)'), findsOneWidget, reason: '마지막 장에서 멈춤');
    expect(screenOn, [true, false]);
    await t.pumpAndSettle(const Duration(seconds: 3));
  });

  testWidgets('117: 화면을 누르면 멈추고 그 누름으로는 넘기지 않음 · 손으로 밀어도 멈춤', (t) async {
    final c = controller();
    final src = await source(t, [(100, 200), (100, 200), (100, 200), (100, 200)]);
    await open(t, c, src);
    await t.tap(find.byTooltip('계속 보기 (3초마다 다음 장)'));
    await t.pump();
    await tapAt(t, 850);
    expect(find.text('1 / 4'), findsOneWidget);
    expect(find.byTooltip('계속 보기 (3초마다 다음 장)'), findsOneWidget);
    expect(screenOn, [true, false]);
    await t.pump(const Duration(seconds: 7));
    expect(find.text('1 / 4'), findsOneWidget);
    // 다음 누름은 다시 넘긴다
    await tapAt(t, 850);
    expect(find.text('2 / 4'), findsOneWidget);
    // 밀어서 멈춤 (민 만큼은 넘어감)
    await t.tap(find.byTooltip('계속 보기 (3초마다 다음 장)'));
    await t.pump();
    await t.dragFrom(const Offset(700, 600), const Offset(-500, 0));
    await t.pumpAndSettle();
    expect(find.text('3 / 4'), findsOneWidget);
    await t.pump(const Duration(seconds: 7));
    expect(find.text('3 / 4'), findsOneWidget);
    expect(screenOn, [true, false, true, false]);
    await t.pumpAndSettle(const Duration(seconds: 3));
  });

  testWidgets('좁은 화면 (폰 세로): 못 들어간 버튼은 ⋮ 메뉴로 - 없어지지 않음', (t) async {
    final c = controller();
    final src = await source(t, [(100, 200), (100, 200)]);
    await open(t, c, src, width: 400);
    expect(find.byTooltip('더 보기'), findsOneWidget);
    expect(find.byTooltip('계속 보기 (3초마다 다음 장)'), findsOneWidget, reason: '계속 보기는 막대에 남음');
    expect(find.byTooltip('넘기는 방향: 왼쪽 → 오른쪽'), findsNothing);
    await t.tap(find.byTooltip('더 보기'));
    await t.pumpAndSettle();
    for (final s in ['상하 반전', '한 쪽 맞추기', '넘기는 방향: 왼쪽 → 오른쪽', '밝게', '화면 가득 (시스템 막대 숨기기)']) {
      expect(find.text(s), findsOneWidget, reason: s);
    }
    await t.tap(find.text('넘기는 방향: 왼쪽 → 오른쪽'));
    await t.pumpAndSettle();
    expect(c.settings.readerRtl, isTrue);
    // 넓으면 메뉴 없이 모두
    await open(t, c, src, width: 1200);
    expect(find.byTooltip('더 보기'), findsNothing);
    expect(find.byTooltip('상하 반전'), findsOneWidget);
  });
}
