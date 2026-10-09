import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jj_mkvmaker/app/app_controller.dart';
import 'package:jj_mkvmaker/app/settings.dart';
import 'package:jj_mkvmaker/core/webdav.dart';
import 'package:jj_mkvmaker/platform/windows/desktop_storage_service.dart';
import 'package:jj_mkvmaker/platform/windows/process_media_tool.dart';
import 'package:jj_mkvmaker/services/platform_services.dart';
import 'package:jj_mkvmaker/services/secret_store.dart';
import 'package:jj_mkvmaker/ui/secret_issue.dart';
import 'package:path/path.dart' as p;

/// 40-1 · 40-3: 비밀번호를 저장하지 못했으면 화면 위에 분명히 알리고 [다시 시도] 로 저장한다
void main() {
  testWidgets('저장 실패 알림 → [다시 시도] 로 저장되면 알림이 사라진다', (tester) async {
    final dir = Directory.systemTemp.createTempSync('jj_secret_ui_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final secrets = MemorySecretStore()..failWrite = true;
    // 저장 순서용 Future 가 시험의 가짜 시간 영역에 묶이지 않게 실제 영역에서 만든다
    late SettingsStore store;
    late AppController c;
    await tester.runAsync(() async {
      store = SettingsStore(p.join(dir.path, 'settings.json'), secrets);
      c = AppController(
          PlatformServices(mediaTool: ProcessMediaTool('x', 'y'), storage: DesktopStorageService()),
          settingsStore: store);
      c.settings = await store.load();
      await c.updateSettings((s) => s.webdavServers = [
            const DavServer(id: 'd1', name: 'nas', url: 'https://nas', user: 'u', password: 'pw'),
          ]);
    });
    final key = GlobalKey<ScaffoldMessengerState>();
    await tester.pumpWidget(MaterialApp(scaffoldMessengerKey: key, home: const Scaffold(body: SizedBox())));
    watchSecretIssue(key, c);
    await tester.pumpAndSettle();
    expect(find.text('이 기기의 안전 저장소를 쓸 수 없어 비밀번호를 저장하지 못했습니다'), findsOneWidget);
    secrets.failWrite = false;
    await tester.tap(find.text('다시 시도'));
    for (var i = 0; i < 100 && secrets.values.isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
    await tester.pumpAndSettle();
    expect(secrets.values['dav.pw.d1'], 'pw');
    expect(find.text('이 기기의 안전 저장소를 쓸 수 없어 비밀번호를 저장하지 못했습니다'), findsNothing);
    DavRegistry.configure([]);
  }, timeout: const Timeout(Duration(seconds: 60)));

  testWidgets('90 · 91: 예전 비밀번호로 돌아간다고 알림 · [닫기] 하면 같은 상황에서는 다시 안 뜸 · [다시 시도] 실패도 알림', (tester) async {
    final dir = Directory.systemTemp.createTempSync('jj_secret_ui2_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final secrets = MemorySecretStore()..values['dav.pw.d1'] = 'old';
    late SettingsStore store;
    late AppController c;
    await tester.runAsync(() async {
      store = SettingsStore(p.join(dir.path, 'settings.json'), secrets);
      c = AppController(
          PlatformServices(mediaTool: ProcessMediaTool('x', 'y'), storage: DesktopStorageService()),
          settingsStore: store);
      c.settings = await store.load();
      await c.updateSettings((s) => s.webdavServers = [
            const DavServer(id: 'd1', name: 'nas', url: 'https://nas', user: 'u', password: 'old'),
          ]);
      secrets.failWrite = true;
      await c.updateSettings((s) => s.webdavServers = [s.webdavServers.single.copyWith(password: 'new')]);
    });
    expect(store.secretIssue.value?.revertsToOld, isTrue);
    final key = GlobalKey<ScaffoldMessengerState>();
    await tester.pumpWidget(MaterialApp(scaffoldMessengerKey: key, home: const Scaffold(body: SizedBox())));
    watchSecretIssue(key, c);
    await tester.pumpAndSettle();
    expect(find.text('새 비밀번호는 아직 저장되지 않았습니다. 앱을 끄면 예전 비밀번호로 돌아갑니다.'), findsOneWidget);
    // [다시 시도] 가 또 실패해도 결과를 알린다
    await tester.tap(find.text('다시 시도'));
    for (var i = 0; i < 50 && find.text('아직 저장하지 못했습니다. 잠시 뒤 다시 시도하세요').evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
    expect(find.text('아직 저장하지 못했습니다. 잠시 뒤 다시 시도하세요'), findsOneWidget);
    // 닫으면 설정을 바꿔도 (같은 상황) 다시 뜨지 않는다
    await tester.tap(find.text('닫기'));
    await tester.pumpAndSettle();
    await tester.runAsync(() => c.updateSettings((s) => s.homeUrl = 'https://x.example'));
    await tester.pumpAndSettle();
    expect(find.text('새 비밀번호는 아직 저장되지 않았습니다. 앱을 끄면 예전 비밀번호로 돌아갑니다.'), findsNothing);
    DavRegistry.configure([]);
  }, timeout: const Timeout(Duration(seconds: 60)));
}
