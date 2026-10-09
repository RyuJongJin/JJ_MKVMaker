import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jj_mkvmaker/app/app_controller.dart';
import 'package:jj_mkvmaker/app/live_sync.dart';
import 'package:jj_mkvmaker/app/settings.dart';
import 'package:jj_mkvmaker/core/webdav.dart';
import 'package:jj_mkvmaker/platform/windows/desktop_storage_service.dart';
import 'package:jj_mkvmaker/platform/windows/process_media_tool.dart';
import 'package:jj_mkvmaker/services/app_shell.dart';
import 'package:jj_mkvmaker/services/platform_services.dart';
import 'package:jj_mkvmaker/services/secret_store.dart';
import 'package:jj_mkvmaker/ui/dav_external.dart';
import 'package:jj_mkvmaker/ui/migration_notice.dart';
import 'package:path/path.dart' as p;

class _Shell extends NoopShell {
  final opened = <List<String>>[];
  @override
  Future<void> openExternal(String program, List<String> files) async => opened.add(files);
}

/// 102: 사용자에게 물어 정한 것 · 1차 판단은 환경 설정에서 바꿀 수 있고, 기본값은 그 답
void main() {
  test('기본값 = 정한 답 · 저장 · 읽기', () {
    final s = AppSettings();
    expect([
      s.startMenuShortcut, s.syncStopToast, s.swipeWrap, s.migrationNotice, s.allowInnerToOuter,
      s.rememberPasswords, s.recycleOnDelete, s.readerSystemBars,
    ], everyElement(isTrue));
    expect(s.cleanupPrechecked, ['work', 'download']);
    expect(s.tripleTapAction, 'move');
    expect(s.davExternalOpen, 'ask');
    // 이미 있던 설정의 기본값도 결정대로
    expect([s.webPauseOnLeave, s.autoCheckUpdates, s.youtubeAdSkip, s.youtubeAdHide, s.runInBackground, s.swipeNav],
        everyElement(isTrue));
    expect([s.liveSyncOnStart, s.liveSyncIntervalSec, s.explorerLayout, s.zipComic], ['auto', 30, 'auto', false]);
    expect([AppSettings.uiScaleMin, AppSettings.uiScaleMax], [0.5, 2.5]);
    // 바꾼 값은 남는다
    final b = AppSettings.fromJson((AppSettings()
          ..startMenuShortcut = false
          ..syncStopToast = false
          ..swipeWrap = false
          ..migrationNotice = false
          ..allowInnerToOuter = false
          ..rememberPasswords = false
          ..recycleOnDelete = false
          ..cleanupPrechecked = ['logs']
          ..tripleTapAction = 'none'
          ..davExternalOpen = 'url')
        .toJson());
    expect([b.startMenuShortcut, b.syncStopToast, b.swipeWrap, b.migrationNotice, b.allowInnerToOuter, b.rememberPasswords,
        b.recycleOnDelete], everyElement(isFalse));
    expect([b.cleanupPrechecked, b.tripleTapAction, b.davExternalOpen], [['logs'], 'none', 'url']);
  });

  test('안쪽 → 바깥 허용을 끄면 늘 막는다', () {
    final x = LiveSyncPair(r'C:\a\in', r'C:\a');
    expect(LiveSync.nestingProblem(x), isNull);
    expect(LiveSync.nestingProblem(x, allowInnerToOuter: false), isNotNull);
  });

  test('비밀번호 기억을 끄면 안전 저장소에 두지 않고 있던 것도 지운다', () async {
    final dir = Directory.systemTemp.createTempSync('jj_remember_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final secrets = MemorySecretStore();
    final st = SettingsStore(p.join(dir.path, 'settings.json'), secrets);
    final s = await st.load();
    s.webdavServers = [const DavServer(id: 'd', name: 'n', url: 'https://n', user: 'u', password: 'pw')];
    await st.save(s);
    expect(secrets.values['dav.pw.d'], 'pw');
    s.rememberPasswords = false;
    await st.save(s);
    expect(secrets.values, isEmpty);
    expect(File(p.join(dir.path, 'settings.json')).readAsStringSync(), isNot(contains('"pw"')));
  });

  for (final mode in ['fetch', 'url']) {
    testWidgets('로그인이 필요한 WebDAV 를 다른 앱으로 - "$mode" 로 정해 두면 묻지 않는다', (tester) async {
      final shell = _Shell();
      final c = AppController(PlatformServices(mediaTool: ProcessMediaTool('x', 'y'), storage: DesktopStorageService(), shell: shell));
      c.settings.davExternalOpen = mode;
      DavRegistry.configure([const DavServer(id: 'n', name: 'n', url: 'http://127.0.0.1:9', user: 'u', password: 'p')]);
      addTearDown(() => DavRegistry.configure([]));
      await tester.pumpWidget(const MaterialApp(home: Scaffold(body: SizedBox())));
      final ctx = tester.element(find.byType(SizedBox));
      if (mode == 'url') {
        await openExternalPlayable(ctx, c, 'vlc.exe', ['dav://n/a.mkv']);
        expect(find.text('이 WebDAV 서버는 로그인이 필요합니다'), findsNothing);
        expect(shell.opened.single.single, startsWith('http://127.0.0.1:9'));
      } else {
        // 받아서 열기: 묻는 창 없이 바로 받으러 간다 (이 시험의 서버는 없으므로 받기는 실패로 끝남), 주소로 열지 않음
        var finished = false;
        unawaited(openExternalPlayable(ctx, c, 'vlc.exe', ['dav://n/a.mkv']).whenComplete(() => finished = true));
        for (var i = 0; i < 100 && !finished; i++) {
          await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
          await tester.pump();
          expect(find.text('이 WebDAV 서버는 로그인이 필요합니다'), findsNothing);
        }
        expect(finished, isTrue);
        expect(shell.opened, isEmpty);
        await tester.pump(const Duration(seconds: 5));
      }
    });
  }

  test('116: 예전 판의 "권한 안내 보임" 표시는 읽지 않는다 (권한이 없으면 이 판에서 한 번 더 안내)', () {
    expect(AppSettings.fromJson({'allFilesHintShown': true}).allFilesHintShown, isFalse);
    expect(AppSettings.fromJson((AppSettings()..allFilesHintShown = true).toJson()).allFilesHintShown, isTrue);
  });

  testWidgets('126: "바뀐 기본 설정" 창을 닫으면 바로 저장 - 강제 종료 뒤 켜도 다시 뜨지 않음', (tester) async {
    final dir = Directory.systemTemp.createTempSync('jj_migr_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = p.join(dir.path, 'settings.json');
    // 예전 판이 남긴 설정 (두 창 배치 '화면 모양 따라')
    File(file).writeAsStringSync('{"explorerOrientation": "auto", "explorerV2": true, "orientationV2": true}');
    final store = SettingsStore(file, MemorySecretStore());
    final c = AppController(PlatformServices(mediaTool: ProcessMediaTool('x', 'y'), storage: DesktopStorageService()),
        settingsStore: store);
    await tester.runAsync(c.init);
    expect(c.settings.migrated, contains('explorerOrientation'));
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: SizedBox())));
    final ctx = tester.element(find.byType(SizedBox));
    unawaited(showMigrationNotice(ctx, c));
    await tester.pumpAndSettle();
    expect(find.text('이번 업데이트로 바뀐 기본 설정'), findsOneWidget);
    await tester.tap(find.text('확인'));
    // 파일 쓰기 (진짜 입출력) 가 끝나게 몇 번 돌려 준다
    for (var i = 0; i < 20; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
    }
    // 강제 종료 뒤 다시 켬 = 파일을 새로 읽음
    final again = await tester.runAsync(() => SettingsStore(file, MemorySecretStore()).load());
    expect(again!.migrated, isEmpty);
    expect(again.explorerOrientation, 'side');
  });
}
