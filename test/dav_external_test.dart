import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jj_mkvmaker/app/app_controller.dart';
import 'package:jj_mkvmaker/core/webdav.dart';
import 'package:jj_mkvmaker/platform/windows/desktop_storage_service.dart';
import 'package:jj_mkvmaker/platform/windows/process_media_tool.dart';
import 'package:jj_mkvmaker/services/app_shell.dart';
import 'package:jj_mkvmaker/services/platform_services.dart';
import 'package:jj_mkvmaker/ui/dav_external.dart';
import 'package:path/path.dart' as p;

import 'support/dav_server.dart';

class _Shell extends NoopShell {
  final opened = <(String, List<String>)>[];
  @override
  Future<void> openExternal(String program, List<String> files) async => opened.add((program, files));
}

/// 55: 로그인이 필요한 WebDAV 동영상을 다른 앱으로 열 때 - 주소에 비밀번호를 넣지 않고, 조용히 실패하지 않게 고르게 한다
void main() {
  late Directory tmp;
  late TestDavServer server;
  late _Shell shell;
  late AppController c;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('jj_dav_ext_');
    final remote = Directory(p.join(tmp.path, 'remote'))..createSync();
    File(p.join(remote.path, '1화.mkv')).writeAsStringSync('video');
    server = TestDavServer(remote);
    await server.start();
    DavRegistry.configure([DavServer(id: 'n', name: 'nas', url: server.url, user: 'user', password: 'pass')]);
    shell = _Shell();
    c = AppController(PlatformServices(
        mediaTool: ProcessMediaTool('x', 'y'), storage: DesktopStorageService(), shell: shell));
  });
  tearDown(() async {
    DavRegistry.configure([]);
    await server.stop();
    tmp.deleteSync(recursive: true);
  });

  Future<BuildContext> pump(WidgetTester tester) async {
    HttpOverrides.global = null;
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: SizedBox())));
    return tester.element(find.byType(SizedBox));
  }

  testWidgets('로컬 파일은 묻지 않고 바로 연다', (tester) async {
    final ctx = await pump(tester);
    await openExternalPlayable(ctx, c, 'system', [r'C:\a.mkv']);
    expect(shell.opened.single.$1, 'system');
    expect(shell.opened.single.$2, [r'C:\a.mkv']);
  });

  testWidgets('로그인이 필요한 서버: 안내 창 → [주소로 열기] 는 비밀번호 없는 주소 · [받아서 열기] 는 받은 파일', (tester) async {
    final ctx = await pump(tester);
    unawaited(openExternalPlayable(ctx, c, 'vlc.exe', ['dav://n/1화.mkv']));
    await tester.pumpAndSettle();
    expect(find.text('이 WebDAV 서버는 로그인이 필요합니다'), findsOneWidget);
    expect(shell.opened, isEmpty);
    await tester.tap(find.text('주소로 열기'));
    await tester.pumpAndSettle();
    final url = shell.opened.single.$2.single;
    expect(url, startsWith(server.url));
    expect(url, isNot(contains('pass')));

    shell.opened.clear();
    final done = openExternalPlayable(ctx, c, 'vlc.exe', ['dav://n/1화.mkv']);
    await tester.pumpAndSettle();
    await tester.tap(find.text('받아서 열기'));
    for (var i = 0; i < 200 && shell.opened.isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
    await tester.pumpAndSettle();
    await done;
    final local = shell.opened.single.$2.single;
    expect(File(local).readAsStringSync(), 'video');
    await tester.pump(const Duration(seconds: 20)); // HTTP 연결 유휴 타이머
  });
}
