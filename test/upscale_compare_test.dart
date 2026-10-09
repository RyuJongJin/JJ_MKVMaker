import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:jj_mkvmaker/ui/ai_upscale_ui.dart';
import 'package:path/path.dart' as p;

/// 160: 비교 화면을 저장하지 않고 닫으면 (올린 그림이 지워지므로) 묻는다 - 닫기 버튼 · 뒤로 키
void main() {
  late Directory dir;
  late String a, b;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('jj_cmp_');
    a = p.join(dir.path, 'a.png');
    b = p.join(dir.path, 'b.png');
    File(a).writeAsBytesSync(img.encodePng(img.Image(width: 4, height: 4)));
    File(b).writeAsBytesSync(img.encodePng(img.Image(width: 16, height: 16)));
  });
  tearDown(() => dir.deleteSync(recursive: true));

  Future<Future<bool?>> open(WidgetTester tester) async {
    late NavigatorState nav;
    await tester.pumpWidget(MaterialApp(home: Builder(builder: (context) {
      nav = Navigator.of(context);
      return const SizedBox();
    })));
    final r = nav.push<bool>(MaterialPageRoute(builder: (_) => UpscaleCompareView(original: a, upscaled: b, title: 't')));
    await tester.pumpAndSettle();
    return r;
  }

  testWidgets('[닫기] → 묻기: [취소] 면 그대로 · [저장하지 않고 닫기] 면 false', (tester) async {
    final r = await open(tester);
    await tester.tap(find.byTooltip('닫기'));
    await tester.pumpAndSettle();
    expect(find.text('저장하지 않고 닫을까요?'), findsOneWidget);
    await tester.tap(find.text('취소'));
    await tester.pumpAndSettle();
    expect(find.byType(UpscaleCompareView), findsOneWidget, reason: '닫지 않음');
    await tester.tap(find.byTooltip('닫기'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('저장하지 않고 닫기'));
    await tester.pumpAndSettle();
    expect(find.byType(UpscaleCompareView), findsNothing);
    expect(await r, isFalse);
  });

  testWidgets('뒤로 키도 묻고, 묻는 창의 [저장] 이면 true', (tester) async {
    final r = await open(tester);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('저장하지 않고 닫을까요?'), findsOneWidget);
    expect(find.byType(UpscaleCompareView), findsOneWidget);
    await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.widgetWithText(FilledButton, '저장')));
    await tester.pumpAndSettle();
    expect(await r, isTrue);
  });

  testWidgets('위쪽 [저장] 은 묻지 않고 바로 true', (tester) async {
    final r = await open(tester);
    await tester.tap(find.widgetWithText(FilledButton, '저장'));
    await tester.pumpAndSettle();
    expect(find.text('저장하지 않고 닫을까요?'), findsNothing);
    expect(await r, isTrue);
  });
}
