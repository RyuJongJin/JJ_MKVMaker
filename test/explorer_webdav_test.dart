import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jj_mkvmaker/app/app_controller.dart';
import 'package:jj_mkvmaker/core/webdav.dart';
import 'package:jj_mkvmaker/platform/windows/desktop_storage_service.dart';
import 'package:jj_mkvmaker/platform/windows/process_media_tool.dart';
import 'package:jj_mkvmaker/services/app_shell.dart';
import 'package:jj_mkvmaker/services/platform_services.dart';
import 'package:jj_mkvmaker/ui/explorer_page.dart';
import 'package:path/path.dart' as p;

import 'explorer_test.dart' show act, doubleTap, settle;
import 'support/dav_server.dart';

class _Shell extends NoopShell {
  final opened = <String>[];
  @override
  Future<bool> openWith(String path, {bool choose = false}) async {
    opened.add(path);
    return true;
  }
}

void main() {
  late Directory tmp, remote;
  late String left;
  late TestDavServer server;
  late _Shell shell;
  late AppController c;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('jj_explorer_dav_');
    left = p.join(tmp.path, 'left');
    remote = Directory(p.join(tmp.path, 'remote'))..createSync();
    File(p.join(left, 'doc.txt'))
      ..createSync(recursive: true)
      ..writeAsStringSync('hello');
    File(p.join(left, 'sub', 'inner.txt'))
      ..createSync(recursive: true)
      ..writeAsStringSync('inner');
    File(p.join(remote.path, '원격', 'note.txt'))
      ..createSync(recursive: true)
      ..writeAsStringSync('remote');
    server = TestDavServer(remote);
    await server.start();
    shell = _Shell();
    // 이 PC 의 드라이브 (네트워크 드라이브 등) 가 많으면 탭이 밀려 "WebDAV" 탭이 화면 밖으로 간다 - 시험 폴더의 드라이브만
    final root = p.rootPrefix(tmp.path);
    ExplorerPage.debugVolumes = () => [(root, root.replaceAll(RegExp(r'[\\/]+$'), ''))];
    c = AppController(PlatformServices(
        mediaTool: ProcessMediaTool('x', 'y'), storage: DesktopStorageService(), shell: shell));
  });
  tearDown(() async {
    ExplorerPage.debugVolumes = null;
    DavRegistry.configure([]);
    await server.stop();
    tmp.deleteSync(recursive: true);
  });

  Future<void> pump(WidgetTester tester, Widget page) async {
    HttpOverrides.global = null; // testWidgets 는 HttpClient 를 막아 둔다 - 이 시험은 실제 (로컬) 서버에 연결
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.runAsync(() => tester.pumpWidget(MaterialApp(home: page)));
  }

  testWidgets('파일 탐색기: WebDAV 탭 → 서버 추가 (연결 확인) → 목록 · 열기 (받아서) · 로컬 → WebDAV 복사', (tester) async {
    c.settings.explorerPaths = [left, left];
    await pump(tester, ExplorerPage(c: c));
    await settle(tester, () => find.text('doc.txt').evaluate().isNotEmpty);
    // 서버가 없으면 위쪽 저장 장치 옆에 "WebDAV" 탭 (창마다)
    expect(find.text('WebDAV'), findsNWidgets(2));
    await act(tester, () => tester.tap(find.text('WebDAV').last));
    await tester.pumpAndSettle();
    expect(find.text('WebDAV 서버 추가'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextField, '이름 (탭에 보임, 비우면 주소)'), '집 NAS');
    await tester.enterText(find.widgetWithText(TextField, '주소'), server.url);
    await tester.enterText(find.widgetWithText(TextField, '아이디'), 'user');
    await tester.enterText(find.widgetWithText(TextField, '비밀번호'), 'pass');
    await tester.pump();
    await act(tester, () => tester.tap(find.text('연결 확인')));
    await settle(tester, () => find.textContaining('연결됨').evaluate().isNotEmpty);
    expect(find.textContaining('연결됨: 항목 1개'), findsOneWidget);
    await act(tester, () => tester.tap(find.widgetWithText(FilledButton, '저장')));
    // 저장하면 설정에 남고 오른쪽 창이 그 서버로
    await settle(tester, () => find.text('원격').evaluate().isNotEmpty);
    expect(c.settings.webdavServers.single.url, server.url);
    final id = c.settings.webdavServers.single.id;
    expect(find.text('집 NAS'), findsNWidgets(3)); // 두 창의 탭 + 오른쪽 창의 맨 위 줄
    expect(find.text('WebDAV'), findsNothing);

    // WebDAV 폴더 펼치기 · 파일 두 번 누르기 = 임시 폴더로 받아 기본 앱으로
    await act(tester, () => tester.tap(find.text('원격')));
    await settle(tester, () => find.text('note.txt').evaluate().isNotEmpty);
    await doubleTap(tester, find.text('note.txt'));
    await settle(tester, () => shell.opened.isNotEmpty);
    expect(p.split(shell.opened.single), containsAllInOrder(['jj_webdav', id, '원격', 'note.txt']));
    expect(File(shell.opened.single).readAsStringSync(), 'remote');

    // 왼쪽 doc.txt → 오른쪽 (WebDAV 원격 폴더) 으로 복사
    await act(tester, () => tester.tap(find.text('원격')));
    await settle(tester, () => false, rounds: 15);
    await act(tester, () => tester.tap(find.text('doc.txt')));
    await settle(tester, () => false, rounds: 15);
    await act(tester, () => tester.tap(find.text('복사').first));
    await tester.pumpAndSettle();
    expect(find.textContaining('☁ 집 NAS/원격'), findsOneWidget);
    await act(tester, () => tester.tap(find.widgetWithText(FilledButton, '복사')));
    final up = File(p.join(remote.path, '원격', 'doc.txt'));
    await settle(tester, () => up.existsSync() && find.byType(LinearProgressIndicator).evaluate().isEmpty);
    expect(up.readAsStringSync(), 'hello');
  });

  testWidgets('Rsync 화면: 로컬 ↔ WebDAV 폴더 → (앱이 직접 맞춤 · rsync 필요 없음)', (tester) async {
    final s = DavServer(id: 'nas', name: '집 NAS', url: server.url, user: 'user', password: 'pass');
    c.settings
      ..webdavServers = [s]
      ..rsyncPaths = [left, 'dav://nas/'];
    DavRegistry.configure([s]);
    await pump(tester, ExplorerPage(c: c, rsync: true));
    await settle(tester, () => find.text('sub').evaluate().isNotEmpty && find.text('원격').evaluate().isNotEmpty);
    expect(find.byIcon(Icons.cloud), findsOneWidget); // 오른쪽 창 맨 위 줄
    await act(tester, () => tester.tap(find.text('sub')));
    await act(tester, () => tester.tap(find.text('원격')));
    await settle(tester, () => false, rounds: 5);
    await act(tester, () => tester.tap(find.text('좌 → 우')));
    await settle(tester, () => find.textContaining('비교하는 중').evaluate().isEmpty, rounds: 400);
    expect(find.text('→  ☁ 집 NAS › 원격'), findsOneWidget); // 109: 짧은 경로
    // 72: 비교 - 보낼 것 · 받는 쪽 (WebDAV) 에만 있는 것 (지우기 없으니 그대로 둠)
    expect(find.textContaining('→ + inner.txt'), findsOneWidget);
    expect(find.textContaining('= note.txt'), findsOneWidget);
    expect(find.textContaining('WebDAV: rsync 대신 앱이 직접 맞춥니다'), findsOneWidget);
    await act(tester, () => tester.tap(find.widgetWithText(FilledButton, '실행')));
    final got = File(p.join(remote.path, '원격', 'inner.txt'));
    await settle(tester, () => got.existsSync() && find.byType(LinearProgressIndicator).evaluate().isEmpty, rounds: 200);
    expect(got.readAsStringSync(), 'inner');
    expect(File(p.join(remote.path, '원격', 'note.txt')).existsSync(), isTrue); // 지우기 없이
    expect(c.settings.copyTasks.single.dest, 'dav://nas/원격'); // 모니터링에 남음
  });
}
