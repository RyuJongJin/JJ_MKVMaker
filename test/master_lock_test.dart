import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jj_mkvmaker/app/app_controller.dart';
import 'package:jj_mkvmaker/app/master_lock.dart';
import 'package:jj_mkvmaker/app/settings.dart';
import 'package:jj_mkvmaker/core/webdav.dart';
import 'package:jj_mkvmaker/platform/windows/desktop_storage_service.dart';
import 'package:jj_mkvmaker/platform/windows/process_media_tool.dart';
import 'package:jj_mkvmaker/services/platform_services.dart';
import 'package:jj_mkvmaker/services/secret_store.dart';
import 'package:jj_mkvmaker/ui/master_prompt.dart';
import 'package:jj_mkvmaker/ui/settings_page.dart';

String hex(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

void main() {
  group('124: 해시', () {
    test('PBKDF2-HMAC-SHA256 이 알려진 값과 같다 (RFC 6070 방식 시험 값)', () {
      expect(hex(pbkdf2Sha256(utf8.encode('password'), utf8.encode('salt'), 1, 32)),
          '120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b');
      expect(hex(pbkdf2Sha256(utf8.encode('password'), utf8.encode('salt'), 2, 32)),
          'ae4d0c95af6b46d32d0adff928f06dd02a303f8ef3c251dfd6e2d85a95474c43');
      expect(hex(pbkdf2Sha256(utf8.encode('password'), utf8.encode('salt'), 4096, 32)),
          'c5e478d59288c841aa530db6845c4c8d962893a001ce4e11a4963873aa98134a');
      // 64 바이트보다 긴 열쇠 · 32 바이트보다 긴 결과
      expect(hex(pbkdf2Sha256(utf8.encode('passwordPASSWORDpassword'), utf8.encode('saltSALTsaltSALTsaltSALTsaltSALTsalt'),
              4096, 40)),
          '348c89dbcbd32b2f32d814b8116e84cf2b17347ebc1800181c4e2a1fb8dd53e1c635518c7dac47e9');
      // 64 바이트보다 긴 비밀번호 (열쇠를 먼저 해시) · 딱 64 바이트 - 값은 Python hashlib.pbkdf2_hmac 으로 구함
      expect(hex(pbkdf2Sha256(utf8.encode('긴비밀번호' * 10), utf8.encode('saltSALT'), 1000, 32)),
          '1b2d0e02ae0a189fe6958ca9b786239b9b03c65c9c46276a0c1a673f06a6df7c');
      expect(hex(pbkdf2Sha256(utf8.encode('x' * 64), utf8.encode('salt'), 3, 32)),
          '0582d52c2133ec90a168409527adb1a18782d00151ca2939679a72dedca074b5');
    });

    test('원문은 남지 않고, 솔트가 달라 같은 비밀번호도 해시가 다르다 · 맞는 것만 통과', () {
      final a = PasswordHash.make('내 비밀번호', iterations: 1000);
      final b = PasswordHash.make('내 비밀번호', iterations: 1000);
      expect(a, isNot(contains('내 비밀번호')));
      expect(a, startsWith('pbkdf2-sha256\$1000\$'));
      expect(a, isNot(b));
      expect(PasswordHash.verify('내 비밀번호', a), isTrue);
      expect(PasswordHash.verify('내 비밀번호 ', a), isFalse);
      expect(PasswordHash.verify('x', 'garbage'), isFalse);
    });
  });

  group('124: 마스터 · 최상', () {
    late MemorySecretStore secrets;
    late DateTime clock;
    MasterLock make() => MasterLock(secrets, now: () => clock);
    setUp(() {
      secrets = MemorySecretStore();
      clock = DateTime(2026, 10, 9, 12);
    });

    test('정하기 · 안전 저장소에 해시만 · 둘이 같으면 못 정함 · 다시 읽기', () async {
      final l = make();
      expect(await l.setMaster('m-pass'), isTrue);
      expect(await l.setSuper('m-pass'), isFalse, reason: '마스터와 같음');
      expect(await l.setSuper('s-pass'), isTrue);
      expect(await l.setMaster('s-pass'), isFalse, reason: '최상과 같음');
      expect(secrets.values[MasterLock.masterKey], startsWith('pbkdf2-sha256\$'));
      expect(secrets.values.values.any((v) => v.contains('m-pass') || v.contains('s-pass')), isFalse);
      final again = make();
      await again.load();
      expect((again.hasMaster, again.hasSuper, again.unlocked), (true, true, false));
      expect(await again.check('m-pass'), MasterInput.master);
      expect(again.unlocked, isTrue);
      final third = make();
      await third.load();
      expect(await third.check('s-pass'), MasterInput.superPassword);
      expect(third.unlocked, isFalse, reason: '최상은 초기화 창으로 (풀지는 않음)');
    });

    test('묻는 때: 물어보지 않기 · 처음 시작 시 · 쓸 때 / 풀면 앱을 끌 때까지 묻지 않음', () async {
      final l = make();
      expect(l.needsPrompt(), isFalse, reason: '마스터가 없으면 묻지 않음');
      await l.setMaster('m');
      final x = make();
      await x.load();
      expect(x.ask, 'onUse', reason: '처음 정하면 쓸 때 묻기');
      await x.setAsk('never');
      expect((x.needsPrompt(startup: true), x.needsPrompt()), (false, false));
      await x.setAsk('startup');
      expect((x.needsPrompt(startup: true), x.needsPrompt()), (true, true));
      await x.setAsk('onUse');
      expect((x.needsPrompt(startup: true), x.needsPrompt()), (false, true));
      await x.check('m');
      expect(x.needsPrompt(), isFalse);
    });

    test('129: 묻는 때는 안전 저장소에 - 값이 없거나 틀리면 쓸 때 묻기 (설정 파일을 지우거나 고쳐도 자물쇠가 꺼지지 않음)', () async {
      final l = make();
      await l.setMaster('m');
      await l.setAsk('never');
      expect(secrets.values[MasterLock.askKey], 'never');
      // 사용자가 고른 '물어보지 않기' 는 그대로
      final a = make();
      await a.load();
      expect(a.ask, 'never');
      // 값이 사라지거나 (예전 판 보관본 · 앱 설정 전체 초기화) 망가지면 쓸 때 묻기
      secrets.values.remove(MasterLock.askKey);
      final b = make();
      await b.load();
      expect(b.ask, 'onUse');
      secrets.values[MasterLock.askKey] = 'garbage';
      final c = make();
      await c.load();
      expect(c.ask, 'onUse');
      // 마스터를 끄면 묻지 않음 · 값도 지움
      await c.clearMaster();
      expect((c.ask, secrets.values.containsKey(MasterLock.askKey)), ('never', false));
    });

    test('128: 한 번 취소하면 자동 · 배경 호출은 다시 묻지 않고, 사용자가 직접 연 곳 (force) 만 다시 묻는다', () async {
      final l = make();
      await l.setMaster('m');
      final x = make();
      await x.load();
      var shown = 0;
      var answer = false;
      MasterLock.prompt = (_) async {
        shown++;
        if (answer) await x.check('m');
        return answer;
      };
      addTearDown(() => MasterLock.prompt = null);
      expect(await x.ensure(), isFalse); // 배경: 처음엔 묻고 취소
      expect(shown, 1);
      for (var i = 0; i < 5; i++) {
        expect(await x.ensure(), isFalse); // 30초마다 와도 다시 띄우지 않음
      }
      expect(shown, 1);
      answer = true;
      expect(await x.ensure(force: true), isTrue); // 사용자가 직접 누름
      expect(shown, 2);
      expect(await x.ensure(), isTrue);
      expect(shown, 2, reason: '풀린 뒤로는 묻지 않음');
    });

    test('여러 번 틀리면 기다리게 하고, 껐다 켜도 남는다 · 맞히면 풀림', () async {
      final l = make();
      await l.setMaster('m');
      final x = make();
      await x.load();
      for (var i = 0; i < 4; i++) {
        expect(await x.check('bad'), MasterInput.wrong);
      }
      expect(x.waiting, isNull);
      expect(await x.check('bad'), MasterInput.wrong);
      expect(x.waiting, const Duration(seconds: 30));
      expect(await x.check('m'), MasterInput.wait, reason: '기다리는 동안은 맞아도 안 받음');
      final restarted = make();
      await restarted.load();
      expect(restarted.waiting, isNotNull);
      clock = clock.add(const Duration(seconds: 31));
      expect(await restarted.check('m'), MasterInput.master);
      expect(restarted.fails, 0);
      expect(MasterLock.waitFor(6), const Duration(minutes: 1));
      expect(MasterLock.waitFor(40), const Duration(minutes: 15));
    });

    test('쓸 때 묻기: 여러 곳에서 동시에 불러도 창은 하나 · 취소하면 막힘', () async {
      final l = make();
      await l.setMaster('m');
      final x = make();
      await x.load();
      var shown = 0;
      MasterLock.prompt = (_) async {
        shown++;
        await Future<void>.delayed(const Duration(milliseconds: 10));
        return false;
      };
      addTearDown(() => MasterLock.prompt = null);
      final r = await Future.wait([x.ensure(), x.ensure(), x.ensure()]);
      expect(r, [false, false, false]);
      expect(shown, 1);
    });
  });

  group('124: 창', () {
    AppController controller() {
      final c = AppController(PlatformServices(mediaTool: ProcessMediaTool('x', 'y'), storage: DesktopStorageService()));
      c.settings
        ..webdavServers = [const DavServer(id: 'n', name: 'NAS', url: 'https://nas', user: 'u', password: 'pw')]
        ..openSubtitlesKey = 'k'
        ..openSubtitlesUser = 'ou'
        ..openSubtitlesPassword = 'op';
      return c;
    }

    Future<BuildContext> host(WidgetTester t) async {
      await t.pumpWidget(const MaterialApp(home: Scaffold(body: SizedBox())));
      return t.element(find.byType(SizedBox));
    }

    Future<void> work(WidgetTester t) async {
      for (var i = 0; i < 30; i++) {
        await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await t.pump();
      }
    }

    testWidgets('마스터 창에 최상을 넣으면 초기화 창 - 처음 체크는 마스터만, 한 번 더 확인 뒤 하고 알림', (t) async {
      final c = controller();
      final lock = MasterLock(MemorySecretStore());
      await t.runAsync(() async {
        await lock.setMaster('m');
        await lock.setSuper('s');
      });
      lock.unlocked = false;
      final ctx = await host(t);
      bool? result;
      askMaster(ctx, c, lock).then((r) => result = r);
      await t.pumpAndSettle();
      await t.enterText(find.byType(TextField), 's');
      await t.tap(find.text('확인'));
      await work(t);
      expect(find.text('최상 비밀번호 - 초기화'), findsOneWidget);
      final boxes = t.widgetList<CheckboxListTile>(find.byType(CheckboxListTile)).map((x) => x.value).toList();
      expect(boxes, [true, false, false]);
      await t.tap(find.widgetWithText(FilledButton, '초기화'));
      await t.pumpAndSettle();
      expect(find.text('정말 초기화할까요?'), findsOneWidget);
      await t.tap(find.widgetWithText(FilledButton, '초기화'));
      await work(t);
      expect(find.text('초기화했습니다'), findsOneWidget);
      expect(find.textContaining('마스터 비밀번호를 초기화했습니다'), findsOneWidget);
      await t.tap(find.text('닫기'));
      await work(t);
      expect(result, isTrue);
      expect(lock.hasMaster, isFalse);
      expect(c.settings.webdavServers.single.password, 'pw', reason: '마스터만 골랐으니 비밀번호는 그대로');
    });

    testWidgets('잊었습니다: 저장된 비밀번호 · API 키를 지우고 마스터 초기화 (서버 목록 · 아이디는 남김)', (t) async {
      final c = controller();
      final lock = MasterLock(MemorySecretStore());
      await t.runAsync(() => lock.setMaster('m'));
      lock.unlocked = false;
      final ctx = await host(t);
      askMaster(ctx, c, lock);
      await t.pumpAndSettle();
      await t.tap(find.text('비밀번호를 잊었습니다'));
      await t.pumpAndSettle();
      await t.tap(find.widgetWithText(FilledButton, '지우고 초기화'));
      await work(t);
      expect(find.text('초기화했습니다'), findsOneWidget);
      expect(c.settings.webdavServers.single.password, '');
      expect(c.settings.webdavServers.single.user, 'u');
      expect((c.settings.openSubtitlesKey, c.settings.openSubtitlesPassword, c.settings.openSubtitlesUser), ('', '', 'ou'));
      expect(lock.hasMaster, isFalse);
    });

    testWidgets('틀리면 다시 묻고 몇 번째인지 보여 줌', (t) async {
      final c = controller();
      final lock = MasterLock(MemorySecretStore());
      await t.runAsync(() => lock.setMaster('m'));
      lock.unlocked = false;
      final ctx = await host(t);
      askMaster(ctx, c, lock);
      await t.pumpAndSettle();
      await t.enterText(find.byType(TextField), 'bad');
      await t.tap(find.text('확인'));
      await work(t);
      expect(find.text('비밀번호가 틀렸습니다 (1번)'), findsOneWidget);
      expect(lock.unlocked, isFalse);
    });

    test('최상으로 "앱 설정 전체" 를 지우면 처음 상태', () async {
      final c = controller()..settings.explorerLayout = 'single';
      await resetAllSettings(c);
      expect(c.settings.explorerLayout, AppSettings().explorerLayout);
      expect(c.settings.webdavServers, isEmpty);
    });
  });

  testWidgets('124: 환경 설정은 마스터를 넣기 전에는 잠김 · 넣으면 보안 묶음까지 보임', (t) async {
    t.view.physicalSize = const Size(1400, 900);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    // 설정 화면의 rsync 확인이 앱 폴더를 묻는다 (시험 환경에는 path_provider 가 없음)
    final tmp = Directory.systemTemp.createTempSync('jj_master_pp_');
    addTearDown(() => tmp.deleteSync(recursive: true));
    const pp = MethodChannel('plugins.flutter.io/path_provider');
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(pp, (_) async => tmp.path);
    addTearDown(() => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(pp, null));
    final lock = MasterLock(MemorySecretStore());
    await t.runAsync(() async {
      await lock.setMaster('m');
      await lock.setSuper('s');
    });
    lock.unlocked = false;
    MasterLock.instance = lock;
    addTearDown(() => MasterLock.instance = null);
    final c = AppController(PlatformServices(mediaTool: ProcessMediaTool('x', 'y'), storage: DesktopStorageService()));
    // 앱처럼: 묻는 창은 화면에 (setupMasterLock 이 하는 것)
    final nav = GlobalKey<NavigatorState>();
    MasterLock.prompt = (reason) => askMaster(nav.currentContext!, c, lock, reason: reason);
    addTearDown(() => MasterLock.prompt = null);
    await t.pumpWidget(MaterialApp(navigatorKey: nav, home: SettingsPage(c: c)));
    await t.pumpAndSettle();
    expect(find.text('마스터 비밀번호'), findsOneWidget, reason: '열자마자 묻는다');
    await t.tap(find.text('취소'));
    await t.pumpAndSettle();
    expect(find.text('마스터 비밀번호로 잠겨 있습니다'), findsOneWidget);
    expect(find.text('바뀌면 바로 저장됩니다'), findsNothing);
    await t.tap(find.text('마스터 비밀번호 넣기'));
    await t.pumpAndSettle();
    await t.enterText(find.byType(TextField), 'm');
    await t.tap(find.text('확인'));
    for (var i = 0; i < 30; i++) {
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await t.pump();
    }
    await t.pumpAndSettle();
    expect(find.text('마스터 비밀번호로 잠겨 있습니다'), findsNothing);
    expect(find.text('최상 비밀번호'), findsOneWidget);
    expect(find.text('마스터 비밀번호를 묻는 때'), findsOneWidget);
    // 132: 넓은 화면에서도 최상의 [끄기] 가 보이고 (잘리지 않음), 지금 비밀번호 · 확인을 거쳐 끈다
    final offs = find.widgetWithText(OutlinedButton, '끄기');
    expect(offs, findsNWidgets(2), reason: '마스터 · 최상 모두');
    await t.ensureVisible(offs.last);
    await t.tap(offs.last);
    await t.pumpAndSettle();
    await t.enterText(find.byType(TextField).last, 'm');
    await t.tap(find.text('확인'));
    for (var i = 0; i < 30; i++) {
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await t.pump();
    }
    await t.pumpAndSettle();
    expect(find.text('최상 비밀번호를 끌까요?'), findsOneWidget);
    await t.tap(find.widgetWithText(FilledButton, '끄기'));
    for (var i = 0; i < 10; i++) {
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await t.pump();
    }
    expect(lock.hasSuper, isFalse);
  });
}
