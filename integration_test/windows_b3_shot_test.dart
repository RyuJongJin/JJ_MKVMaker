import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:jj_mkvmaker/app/app_controller.dart';
import 'package:jj_mkvmaker/services/platform_services.dart';
import 'package:jj_mkvmaker/ui/explorer_page.dart';
import 'package:jj_mkvmaker/ui/theme.dart';
import 'package:path/path.dart' as p;

import '../test/support/recycle_leftovers.dart';

/// 묶음 3 (데이터 쪽) 기기 감독 확인용 (Windows): 실제 앱 화면을 띄워 누르고 단계마다 PNG (JJ_SHOT_DIR) 로 남긴다.
/// 165 (드라이브 · 연결 안 됨) · 48 (같은 이름) · 52 (돌아와도 진행 막대) · 148 (휴지통 되돌리기) · 144 (긴 경로).
/// 시험 폴더 (JJ_SHOT_TMP) 만 쓰고, 설정은 메모리에만 (저장하지 않음). 휴지통에 넣은 것은 되돌리므로 남지 않는다.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final out = Platform.environment['JJ_SHOT_DIR'] ?? p.join(Directory.systemTemp.path, 'jj_shots_b3');
  Directory tempDir(String prefix) {
    final base = Platform.environment['JJ_SHOT_TMP'];
    if (base == null || base.isEmpty) return Directory.systemTemp.createTempSync(prefix);
    Directory(base).createSync(recursive: true);
    return Directory(base).createTempSync(prefix);
  }

  final key = GlobalKey();

  Future<void> settle(WidgetTester t, [int rounds = 12]) async {
    for (var i = 0; i < rounds; i++) {
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 120)));
      await t.pump();
    }
  }

  Future<void> until(WidgetTester t, bool Function() done, {int rounds = 100}) async {
    for (var i = 0; i < rounds && !done(); i++) {
      await settle(t, 1);
    }
  }

  Future<void> shot(WidgetTester t, String name) async {
    await settle(t, 4);
    final b = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final img = await t.runAsync(() => b.toImage());
    final bytes = await t.runAsync(() => img!.toByteData(format: ui.ImageByteFormat.png));
    Directory(out).createSync(recursive: true);
    File(p.join(out, '$name.png')).writeAsBytesSync(bytes!.buffer.asUint8List());
  }

  Future<void> show(WidgetTester t, Widget home, {Size size = const Size(1280, 800)}) async {
    t.view.physicalSize = size;
    t.view.devicePixelRatio = 1;
    await t.runAsync(() => t.pumpWidget(MaterialApp(
          theme: buildTheme(),
          builder: (_, child) => RepaintBoundary(key: key, child: child),
          home: KeyedSubtree(key: UniqueKey(), child: home),
        )));
    await settle(t);
  }

  late Directory tmp;
  late String left, right;
  late AppController c;
  setUp(() {
    tmp = tempDir('jj_shot_b3_');
    left = p.join(tmp.path, 'left');
    right = p.join(tmp.path, 'right');
    File(p.join(left, 'doc.txt'))
      ..createSync(recursive: true)
      ..writeAsStringSync('new');
    File(p.join(right, 'doc.txt'))
      ..createSync(recursive: true)
      ..writeAsStringSync('old');
    c = AppController(PlatformServices.create());
    c.settings.explorerPaths = [left, right];
  });
  tearDown(() async {
    ExplorerPage.debugVolumes = null;
    ExplorerPage.probeDrive = (path) => Directory(path).exists();
    expect(await recycleLeftovers(tmp.path), 0, reason: '사용자 휴지통에 시험 흔적 없음 (하위 폴더 포함)');
    try {
      Directory(r'\\?\' + tmp.absolute.path).deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<void> selectAndPress(WidgetTester t, String item, String button) async {
    await until(t, () => find.text(item).evaluate().isNotEmpty);
    await t.tap(find.text(item).first);
    await settle(t, 3);
    await t.tap(find.text(button).first);
    await settle(t, 4);
  }

  testWidgets('165: 드라이브 탭 - 응답 없는 드라이브 · 연결 안 됨 (첫 화면은 바로)', (t) async {
    final root = p.rootPrefix(tmp.path);
    final stuck = Completer<bool>();
    ExplorerPage.debugVolumes = () => [(root, root.replaceAll(RegExp(r'[\\/]+$'), '')), (r'Q:\', 'Q:'), (r'R:\', 'R:')];
    ExplorerPage.probeDrive = (path) => path == r'Q:\' ? stuck.future : Future.value(path != r'R:\');
    await show(t, ExplorerPage(c: c));
    await until(t, () => find.textContaining('연결 안 됨').evaluate().isNotEmpty);
    await shot(t, 'b3_165_drives');
    await t.tap(find.textContaining('R: · 연결 안 됨').first);
    await settle(t, 6);
    await shot(t, 'b3_165_reconnect_fail');
    stuck.complete(false);
  });

  testWidgets('48: 같은 이름 - 확인 창 (항목 이름 · 고르기) → 덮어쓰기', (t) async {
    await show(t, ExplorerPage(c: c));
    await selectAndPress(t, 'doc.txt', '복사');
    await until(t, () => find.textContaining('같은 이름이 이미 있습니다').evaluate().isNotEmpty);
    await shot(t, 'b3_48_dialog');
    await t.tap(find.text('덮어쓰기 (원래 파일은 없어집니다)'));
    await settle(t, 2);
    await shot(t, 'b3_48_dialog_overwrite');
    await t.tap(find.widgetWithText(FilledButton, '복사'));
    await until(t, () => find.byType(SnackBar).evaluate().isNotEmpty);
    await shot(t, 'b3_48_done');
    expect(File(p.join(right, 'doc.txt')).readAsStringSync(), 'new');
  });

  testWidgets('154 · 155: 처음 열고 아무것도 고르지 않고 [복사] · [이동] → "…할 항목을 고르세요"', (t) async {
    await show(t, ExplorerPage(c: c));
    await until(t, () => find.text('doc.txt').evaluate().isNotEmpty);
    final messenger = ScaffoldMessenger.of(t.element(find.byType(ExplorerPage)));
    messenger.clearSnackBars(); // 앞 단계의 알림이 남지 않게
    await settle(t, 2);
    await t.tap(find.text('복사').first);
    await until(t, () => find.textContaining('복사할 항목을 고르세요').evaluate().isNotEmpty);
    expect(find.textContaining('복사할 항목을 고르세요'), findsOneWidget);
    await shot(t, 'b3_154_nothing_selected');
    messenger.clearSnackBars();
    await settle(t, 2);
    await t.tap(find.text('이동').first);
    await until(t, () => find.textContaining('옮길 항목을 고르세요').evaluate().isNotEmpty);
    expect(find.textContaining('옮길 항목을 고르세요'), findsOneWidget);
    await shot(t, 'b3_155_nothing_selected_move');
    messenger.clearSnackBars();
    await settle(t, 2);
  });

  testWidgets('52: 복사 중에 다른 화면에 갔다 와도 진행 막대', (t) async {
    // 다른 화면에 갔다 와도 아직 복사 중이게 (약 25초)
    File(p.join(left, 'big.bin')).writeAsBytesSync(List.filled(2 * 1024 * 1024, 7));
    c.settings.copyBandwidthKBps = 80;
    await show(t, ExplorerPage(c: c));
    await selectAndPress(t, 'big.bin', '복사');
    await t.tap(find.widgetWithText(FilledButton, '복사'));
    await until(t, () => find.byType(LinearProgressIndicator).evaluate().isNotEmpty);
    await shot(t, 'b3_52_progress');
    await show(t, const Scaffold(body: Center(child: Text('다른 화면'))));
    await show(t, ExplorerPage(c: c));
    await until(t, () => find.byType(LinearProgressIndicator).evaluate().isNotEmpty, rounds: 20);
    await shot(t, 'b3_52_back_progress');
    await until(t, () => File(p.join(right, 'big.bin')).existsSync() && find.text('big.bin').evaluate().length >= 2, rounds: 150);
    await shot(t, 'b3_52_done_refreshed');
  });

  testWidgets('148: 휴지통으로 → [되돌리기]', (t) async {
    await show(t, ExplorerPage(c: c));
    await selectAndPress(t, 'doc.txt', '삭제');
    await shot(t, 'b3_148_confirm');
    await t.tap(find.widgetWithText(FilledButton, '휴지통으로'));
    await until(t, () => find.text('되돌리기').evaluate().isNotEmpty);
    await shot(t, 'b3_148_snack_undo');
    await t.tap(find.text('되돌리기'));
    await until(t, () => find.textContaining('되돌렸습니다').evaluate().isNotEmpty);
    await shot(t, 'b3_148_undone');
    expect(File(p.join(left, 'doc.txt')).existsSync(), isTrue);
    ScaffoldMessenger.of(t.element(find.byType(ExplorerPage))).clearSnackBars();
    await settle(t, 3);
  });

  testWidgets('144: 긴 경로 - 이유 한 줄 · [그대로 두기] / [영구 삭제]', (t) async {
    var deep = p.join(left, 'deep');
    while (deep.length < 250) {
      deep = p.join(deep, 'd' * 30);
    }
    Directory(r'\\?\' + deep).createSync(recursive: true);
    File(r'\\?\' + p.join(deep, 'a_file_name_that_makes_it_longer.txt')).writeAsStringSync('x');
    await show(t, ExplorerPage(c: c));
    await selectAndPress(t, 'deep', '삭제');
    await t.tap(find.widgetWithText(FilledButton, '휴지통으로'));
    await until(t, () => find.textContaining('경로가 너무 길어').evaluate().isNotEmpty);
    await shot(t, 'b3_144_long_path');
    await t.tap(find.textContaining('영구 삭제 (1개'));
    await until(t, () => find.textContaining('영구 삭제했습니다').evaluate().isNotEmpty);
    await shot(t, 'b3_144_deleted');
  });
}
