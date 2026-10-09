import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jj_mkvmaker/app/ai_local.dart';
import 'package:jj_mkvmaker/app/app_controller.dart';
import 'package:jj_mkvmaker/app/model_backup.dart';
import 'package:jj_mkvmaker/app/version_snapshot.dart';
import 'package:jj_mkvmaker/core/app_update.dart';
import 'package:jj_mkvmaker/platform/windows/desktop_storage_service.dart';
import 'package:jj_mkvmaker/platform/windows/process_media_tool.dart';
import 'package:jj_mkvmaker/services/model_store.dart';
import 'package:jj_mkvmaker/services/platform_services.dart';
import 'package:jj_mkvmaker/services/updater.dart';
import 'package:jj_mkvmaker/ui/update_dialog.dart';
import 'package:path/path.dart' as p;

Map<String, dynamic> _release(String tag, {String? digest, String body = '', bool draft = false, String? url}) => {
      'tag_name': tag,
      'name': 'JJ_MKVMaker $tag',
      'body': body,
      'draft': draft,
      'prerelease': false,
      'html_url': 'https://github.com/$updateRepo/releases/tag/$tag',
      'assets': [
        {
          'name': 'JJ_MKVMaker_${tag}_win64.zip',
          'size': 1234,
          'browser_download_url': url ?? 'https://example.com/x.zip',
          'digest': ?digest,
        },
      ],
    };

class _FakeUpdater implements Updater {
  @override
  bool installsInPlace = false;

  /// 설치할 때 "설치 허용 필요" 로 실패할 횟수 (Android)
  int needPermission = 0;
  ReleaseInfo? next;
  List<ReleaseInfo> all = [];

  /// 받은 파일 (없으면 C:\tmp\new)
  String? downloaded;
  final calls = <String>[];
  @override
  Future<List<ReleaseInfo>> releases() async => all;
  @override
  Future<void> uninstallSelf() async => calls.add('uninstall');
  @override
  Future<String> currentVersion() async => '1.0.1';
  @override
  Future<ReleaseInfo?> latest() async => next;
  @override
  Future<bool> canInstall() async => true;
  @override
  Future<String> download(ReleaseInfo r, void Function(double) onProgress) async {
    calls.add('download ${r.version}');
    onProgress(1);
    return downloaded ?? r'C:\tmp\new';
  }

  @override
  Future<void> scheduleInstall(String dir) async {
    calls.add('install $dir');
    if (needPermission > 0) {
      needPermission--;
      throw const InstallPermissionNeeded('허용 필요');
    }
  }
  @override
  Future<void> openPage(ReleaseInfo r) async => calls.add('page');
}

/// 실제 파일 작업 (크기 재기 · 남은 공간 · 복사) 이 끝날 때까지
Future<void> settleIo(WidgetTester tester, {required bool Function() until}) async {
  // 위젯 시험 안의 파일 읽기 · 쓰기는 pump 마다 조금씩 나아간다 - 넉넉히 (끝나면 바로 나옴)
  for (var i = 0; i < 600 && !until(); i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pump();
  }
  await tester.pumpAndSettle();
}

void main() {
  group('업데이트 창', () {
    late _FakeUpdater up;
    late AppController c;
    setUp(() {
      up = _FakeUpdater();
      c = AppController(PlatformServices(
          mediaTool: ProcessMediaTool('x', 'y'), storage: DesktopStorageService(), updater: up));
    });

    Future<void> open(WidgetTester tester, {bool manual = true}) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => TextButton(
              onPressed: () => checkForUpdate(ctx, c, manual: manual),
              child: const Text('확인'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('확인'));
      await tester.pumpAndSettle();
    }

    testWidgets('최신이면 알림만', (tester) async {
      up.next = parseLatestRelease(_release('v1.0.1'));
      await open(tester);
      expect(find.text('최신 버전입니다 (v1.0.1)'), findsOneWidget);
    });

    testWidgets('새 버전 → 업데이트 → 받기 → 지금 설치', (tester) async {
      up.next = parseLatestRelease(_release('v1.1.0', body: '- 재생목록 전체 받기'));
      await open(tester);
      expect(find.text('새 버전 v1.1.0'), findsOneWidget);
      expect(find.text('지금 쓰는 버전: v1.0.1  →  새 버전: v1.1.0'), findsOneWidget);
      expect(find.text('- 재생목록 전체 받기'), findsOneWidget);
      await tester.tap(find.text('업데이트'));
      await tester.pumpAndSettle();
      expect(find.text('설치 준비 완료'), findsOneWidget);
      await tester.tap(find.text('지금 설치'));
      await tester.pumpAndSettle();
      expect(up.calls, ['download 1.1.0', r'install C:\tmp\new']);
    });

    testWidgets('Android: 설치 허용이 꺼져 있으면 [설치 계속] → 받은 파일로 다시 설치 (다시 받지 않음)', (tester) async {
      up
        ..installsInPlace = true
        ..needPermission = 1
        ..next = parseLatestRelease(_release('v1.1.0'));
      await open(tester);
      await tester.tap(find.text('업데이트'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('지금 설치'));
      await tester.pumpAndSettle();
      expect(find.text('설치 허용 필요'), findsOneWidget);
      await tester.tap(find.text('설치 계속'));
      await tester.pumpAndSettle();
      expect(find.text('설치 허용 필요'), findsNothing);
      expect(up.calls, ['download 1.1.0', r'install C:\tmp\new', r'install C:\tmp\new']);
    });

    testWidgets('이 버전 건너뛰기 → 자동 확인에서 다시 묻지 않음', (tester) async {
      up.next = parseLatestRelease(_release('v1.1.0'));
      await open(tester);
      await tester.tap(find.text('이 버전 건너뛰기'));
      await tester.pumpAndSettle();
      expect(c.settings.skippedVersion, '1.1.0');
      c.settings.lastUpdateCheck = '';
      await open(tester, manual: false);
      expect(find.text('새 버전 v1.1.0'), findsNothing);
    });

    group('버전 고르기 · 되돌리기', () {
      late Directory data;
      setUp(() {
        data = Directory.systemTemp.createTempSync('jj_ver_');
        File(p.join(data.path, 'settings.json'))
            .writeAsStringSync(jsonEncode({'uiLanguage': 'ko', 'openSubtitlesKey': 'SECRET-KEY', 'lastRunVersion': '1.0.1'}));
        File(p.join(data.path, 'videos.json')).writeAsStringSync('[]');
        VersionSnapshot.instance = VersionSnapshot(data.path, sharedDir: p.join(data.path, 'shared', '설정 보관'));
        // P0: 받은 모델 폴더도 시험 폴더 안으로 (시험 프로그램 옆 models 를 건드리지 않게)
        c = AppController(PlatformServices(
            mediaTool: ProcessMediaTool('x', 'y'),
            storage: DesktopStorageService(),
            updater: up,
            models: ModelStore(p.join(data.path, 'models'))));
        AiStore.instance = AiStore(data.path);
        ModelBackup.sharedRoot = p.join(data.path, 'shared');
        up.all = [
          parseRelease(_release('v1.0.2'), allowPrerelease: true)!,
          parseRelease(_release('v1.0.1'), allowPrerelease: true)!,
          parseRelease(_release('v1.0.0'), allowPrerelease: true)!,
        ];
      });
      tearDown(() {
        VersionSnapshot.instance = null;
        AiStore.instance = null;
        ModelBackup.sharedRoot = null;
        data.deleteSync(recursive: true);
      });

      Future<void> openPicker(WidgetTester tester) async {
        tester.view.physicalSize = const Size(1200, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(MaterialApp(
          home: Scaffold(
            body: Builder(builder: (ctx) => TextButton(onPressed: () => chooseVersion(ctx, c), child: const Text('고르기'))),
          ),
        ));
        await tester.tap(find.text('고르기'));
        await tester.pumpAndSettle();
      }

      testWidgets('올려 둔 모든 버전 · 지금 · 최신 표시 → 예전 버전으로 되돌리기 (설치 전 설정 보관, 비밀 값 빼고)', (tester) async {
        await openPicker(tester);
        expect(find.text('버전 고르기'), findsOneWidget);
        for (final v in ['v1.0.2', 'v1.0.1', 'v1.0.0']) {
          expect(find.text(v), findsWidgets);
        }
        expect(find.text('지금'), findsOneWidget);
        expect(find.text('최신'), findsOneWidget);
        expect(find.text('다시 설치'), findsOneWidget); // 처음엔 지금 버전이 골라져 있음
        await tester.tap(find.text('v1.0.2').first);
        await tester.pumpAndSettle();
        expect(find.text('이 버전으로 업데이트'), findsOneWidget);
        await tester.tap(find.text('v1.0.0').first);
        await tester.pumpAndSettle();
        expect(find.text('이 버전으로 되돌리기'), findsOneWidget);
        expect(find.textContaining('예전 버전으로 되돌립니다'), findsOneWidget);
        await tester.tap(find.text('이 버전으로 되돌리기'));
        await tester.pumpAndSettle();
        expect(find.textContaining('예전 버전 (v1.0.0) 으로 되돌린 뒤'), findsOneWidget);
        await tester.tap(find.text('지금 설치'));
        for (var i = 0; i < 50 && up.calls.length < 2; i++) {
          await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
          await tester.pump();
        }
        expect(up.calls, ['download 1.0.0', r'install C:\tmp\new']);
        // 지금 버전 (1.0.1) 의 설정을 보관 (비밀 값은 빼고)
        final kept = File(p.join(data.path, 'version_snapshots', '1.0.1', 'settings.json'));
        expect(kept.existsSync(), isTrue);
        expect(kept.readAsStringSync(), isNot(contains('SECRET-KEY')));
        expect(File(p.join(data.path, 'version_snapshots', '1.0.1', 'videos.json')).existsSync(), isTrue);
      });

      testWidgets('Android: 예전 버전은 APK 와 설정을 Download 에 저장하고 앱 지우기', (tester) async {
        up.installsInPlace = true;
        final apk = File(p.join(data.path, 'dl.apk'))..writeAsStringSync('apk');
        up.downloaded = apk.path;
        await openPicker(tester);
        await tester.tap(find.text('v1.0.0').first);
        await tester.pumpAndSettle();
        await tester.tap(find.text('이 버전으로 되돌리기'));
        await settleIo(tester, until: () => find.text('저장하고 계속').evaluate().isNotEmpty);
        expect(find.textContaining('Android 는 버전이 낮은 앱을'), findsOneWidget);
        // P0: 남는 것 / 사라지는 것을 사실대로 (받은 모델이 없으면 모델 줄은 없음)
        expect(find.text('남는 것'), findsOneWidget);
        expect(find.text('사라지는 것'), findsOneWidget);
        expect(find.textContaining('비밀번호 · API 키'), findsOneWidget);
        expect(find.textContaining('브라우저의 로그인'), findsOneWidget);
        expect(find.textContaining('다시 받아야 합니다'), findsNothing);
        await tester.tap(find.text('저장하고 계속'));
        await tester.pumpAndSettle();
        // 사라지는 것이 있으니 한 번 더
        expect(find.text('정말 되돌릴까요?'), findsOneWidget);
        await tester.tap(find.text('되돌리기 계속'));
        // 받기 · 파일 복사 (실제 파일 작업) 가 끝날 때까지
        for (var i = 0; i < 50 && find.text('저장했습니다').evaluate().isEmpty; i++) {
          await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
          await tester.pump();
        }
        expect(find.text('저장했습니다'), findsOneWidget);
        expect(File(p.join(data.path, 'shared', 'JJ_MKVMaker_v1.0.0_win64.zip')).existsSync(), isTrue); // 설치 파일 사본
        expect(File(p.join(data.path, 'shared', '설정 보관', '1.0.1', 'settings.json')).existsSync(), isTrue);
        await tester.tap(find.text('앱 지우기'));
        await tester.pumpAndSettle();
        expect(up.calls, ['download 1.0.0', 'uninstall']);
      });

      testWidgets('P0 Android: 받은 AI 모델을 복사해 두기 (기본: 남은 공간이 2배 이상이면 켬) · 끄면 "다시 받아야" · 설정에 기억', (tester) async {
        up.installsInPlace = true;
        up.downloaded = (File(p.join(data.path, 'dl.apk'))..writeAsStringSync('apk')).path;
        File(p.join(data.path, 'ai', 'models', 'esrgan.pth'))
          ..createSync(recursive: true)
          ..writeAsBytesSync(List.filled(2 << 20, 1)); // 2MB
        File(p.join(data.path, 'models', 'whisper', 'ggml-base.bin'))
          ..createSync(recursive: true)
          ..writeAsBytesSync(List.filled(1 << 20, 2)); // 1MB
        await openPicker(tester);
        await tester.tap(find.text('v1.0.0').first);
        await tester.pumpAndSettle();
        await tester.tap(find.text('이 버전으로 되돌리기'));
        await settleIo(tester, until: () => find.text('저장하고 계속').evaluate().isNotEmpty);
        // 시험 PC 는 공간이 넉넉하니 처음 값은 켬 → 남는 것에 모델 (공용 폴더가 아직 없어도 상위 폴더로 잼)
        expect(find.textContaining('남은 공간'), findsOneWidget);
        expect(find.textContaining('받은 AI 모델 (3MB) - Download/JJ_MKVMaker/AI 모델 보관'), findsOneWidget);
        // 예전 판 (v1.0.0) 은 옮겨 둔 모델 · 설정을 되살리지 못한다고 사실대로
        expect(find.textContaining('v1.0.0 은 복사해 둔 모델을 되살리지 못합니다'), findsOneWidget);
        expect(find.textContaining('v1.0.0 은 저장해 둔 설정을 되살리지 못해'), findsOneWidget);
        // 끄면 사라지는 것으로 · 설정에 기억
        await tester.tap(find.byType(Checkbox));
        await tester.pumpAndSettle();
        expect(find.textContaining('다시 받아야 합니다 (약 3MB)'), findsOneWidget);
        expect(c.settings.rollbackKeepModels, 'off');
        // 다시 켜고 진행 → 공용 폴더에 모델 사본과 목록
        await tester.tap(find.byType(Checkbox));
        await tester.pumpAndSettle();
        expect(c.settings.rollbackKeepModels, 'on');
        await tester.tap(find.text('저장하고 계속'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('되돌리기 계속'));
        await settleIo(tester, until: () => find.text('저장했습니다').evaluate().isNotEmpty);
        expect(find.text('저장했습니다'), findsOneWidget);
        final kept = ModelBackup.shared!;
        expect(kept.exists, isTrue);
        expect(kept.savedSize, 3 << 20);
        expect(File(p.join(kept.dir, 'ai', 'models', 'esrgan.pth')).lengthSync(), 2 << 20);
        expect(File(p.join(kept.dir, 'models', 'whisper', 'ggml-base.bin')).existsSync(), isTrue);
      });
    });
  });
}
