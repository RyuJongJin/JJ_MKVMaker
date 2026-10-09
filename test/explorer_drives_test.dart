import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jj_mkvmaker/app/app_controller.dart';
import 'package:jj_mkvmaker/core/file_ops.dart';
import 'package:jj_mkvmaker/platform/windows/desktop_storage_service.dart';
import 'package:jj_mkvmaker/platform/windows/process_media_tool.dart';
import 'package:jj_mkvmaker/services/platform_services.dart';
import 'package:jj_mkvmaker/ui/explorer_page.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory tmp;
  late AppController c;
  late Completer<bool> stuck;
  var dead = <String>{};

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('jj_drives_');
    File(p.join(tmp.path, 'left', 'doc.txt'))
      ..createSync(recursive: true)
      ..writeAsStringSync('x');
    Directory(p.join(tmp.path, 'right')).createSync();
    c = AppController(PlatformServices(mediaTool: ProcessMediaTool('x', 'y'), storage: DesktopStorageService()));
    c.settings.explorerPaths = [p.join(tmp.path, 'left'), p.join(tmp.path, 'right')];
    stuck = Completer<bool>();
    dead = {r'R:\'};
    // T: 시험 폴더 (정상) · Q: 응답 없는 네트워크 드라이브 · R: 연결 안 된 드라이브
    ExplorerPage.debugVolumes = () => [(tmp.path, 'T:'), (r'Q:\', 'Q:'), (r'R:\', 'R:')];
    ExplorerPage.probeDrive = (path) => path == r'Q:\' ? stuck.future : Future.value(!dead.contains(path));
  });
  tearDown(() {
    ExplorerPage.debugVolumes = null;
    ExplorerPage.probeDrive = (path) => Directory(path).exists();
    if (!stuck.isCompleted) stuck.complete(false);
    tmp.deleteSync(recursive: true);
  });

  Future<void> settle(WidgetTester tester, bool Function() done) async {
    for (var i = 0; i < 50 && !done(); i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
    }
  }

  testWidgets('165: 응답 없는 드라이브가 있어도 첫 화면이 바로 뜨고, 연결 안 된 드라이브는 숨기지 않고 "연결 안 됨" · 누르면 다시 연결', (tester) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final sw = Stopwatch()..start();
    await tester.runAsync(() => tester.pumpWidget(MaterialApp(home: ExplorerPage(c: c))));
    await settle(tester, () => find.text('doc.txt').evaluate().isNotEmpty);
    // Q: 는 끝내 대답하지 않지만 목록 · 두 창은 바로 (Q: 를 기다리지 않음)
    expect(find.text('doc.txt'), findsOneWidget);
    expect(sw.elapsed, lessThan(const Duration(seconds: 5)));
    expect(find.text('Q:'), findsWidgets, reason: '응답 없는 드라이브도 목록에 (확인 중)');
    // R: 는 숨기지 않고 "연결 안 됨"
    await settle(tester, () => find.textContaining('연결 안 됨').evaluate().isNotEmpty);
    expect(find.textContaining('R: · 연결 안 됨'), findsWidgets);
    // 누르면 다시 연결: 아직 안 되면 알림
    await tester.tap(find.textContaining('R: · 연결 안 됨').first);
    await settle(tester, () => find.textContaining('R:\\ 에 연결할 수 없습니다').evaluate().isNotEmpty);
    expect(find.textContaining(r'R:\ 에 연결할 수 없습니다'), findsOneWidget);
    // 연결되면 "연결 안 됨" 이 사라진다
    dead = {};
    await tester.tap(find.textContaining('R: · 연결 안 됨').first);
    await settle(tester, () => find.textContaining('R: · 연결 안 됨').evaluate().isEmpty);
    expect(find.textContaining('R: · 연결 안 됨'), findsNothing);
  });

  test('165: 드라이브 목록은 열어 보지 않고 Windows 에게 받는다 (빠름)', () {
    final sw = Stopwatch()..start();
    final d = windowsDrives();
    expect(sw.elapsedMilliseconds, lessThan(500));
    expect(d.map((e) => e.$2), contains('C:'));
  }, skip: !Platform.isWindows);
}
