import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:window_manager/window_manager.dart';

import 'app/app_controller.dart';
import 'app/bookmarks_controller.dart';
import 'app/download_manager.dart';
import 'app/settings.dart';
import 'core/app_update.dart';
import 'core/playlist.dart';
import 'platform/android/android_download_tools.dart';
import 'platform/android/android_storage.dart';
import 'platform/windows/app_paths.dart';
import 'platform/windows/cef_runtime.dart';
import 'platform/windows/com_guard.dart';
import 'platform/windows/desktop_shell.dart';
import 'platform/windows/exit_trace.dart';
import 'platform/windows/session_marker.dart';
import 'platform/windows/single_instance.dart';
import 'platform/windows/window_memory.dart';
import 'services/platform_services.dart';
import 'ui/ai_dialog.dart';
import 'ui/app_actions.dart';
import 'ui/app_drop.dart';
import 'ui/browser_page.dart';
import 'ui/downloads_page.dart';
import 'ui/exit_dialog.dart';
import 'ui/home_page.dart';
import 'ui/player_page.dart';
import 'ui/setup_dialog.dart';
import 'ui/update_dialog.dart';
import 'ui/theme.dart';

/// 제목 표시줄 글: "JJ_MKVMaker v1.2.3"
String appTitle = 'JJ_MKVMaker';

/// 버전을 읽어 제목을 정하고, 설정 폴더를 돌려준다
Future<String> _prepare() async {
  try {
    final info = await PackageInfo.fromPlatform();
    appTitle = 'JJ_MKVMaker v${formatVersion('${info.version}+${info.buildNumber}')}';
  } catch (_) {}
  return (await getApplicationSupportDirectory()).path;
}

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  final dataDir = await _prepare();
  if (Platform.isAndroid) return runAndroid(dataDir);

  // 이미 실행 중이면 인수(탐색기에서 고른 파일)를 넘기고 끝낸다
  final request = LaunchRequest.parse(args);
  final newWindow = wantsNewPlayerWindow(request, await SettingsStore().load());
  final instance = SingleInstance();
  if (!await instance.claim(request, waitForExit: args.contains('--restart'), forward: !newWindow)) {
    // 설정이 "새 창에서" 이고 이미 켜져 있으면: 재생만 하는 창으로 따로 뜬다
    if (newWindow) return runSecondWindow(request.files.where(isVideoFile).toList(), dataDir);
    exit(0);
  }

  final services = PlatformServices.create();
  // 작업 기록: 배포 폴더의 Logs (쓸 수 없으면 설정 폴더 아래 Logs)
  final logsDir = AppPaths.logsDir(dataDir);
  // 내장 Chrome 엔진이 이번 실행 시작 때 있었는지 (실행 파일이 그때 준비함)
  CefRuntime.rememberStartState();
  final controller = AppController(services, settingsStore: SettingsStore())
    ..logFile = p.join(logsDir, 'app.log');
  ExitTrace.file = p.join(logsDir, 'exit.log');
  // 지난 실행이 정상으로 끝났는지 (아니면 알려 주고 기록에 남긴다)
  final session = SessionMarker(p.join(dataDir, 'session.json'));
  final crashed = session.start();
  controller.note('── 시작 $appTitle (${AppPaths.exeDir}) ──');
  // 예전 구조 (한 폴더) 에서 Lib 구조로 바뀐 뒤 맨 위에 남은 예전 프로그램 파일 정리
  final cleaned = AppPaths.cleanupOldLayout();
  if (cleaned.isNotEmpty) controller.note('예전 구조의 프로그램 파일 정리 (${cleaned.length}개): ${cleaned.join(', ')}');
  if (crashed != null) {
    String hm(DateTime t) => '${t.month}/${t.day} ${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
    controller.note('⚠ 지난 실행이 정상적으로 끝나지 않았습니다 (시작 ${hm(crashed.$1)}, 마지막 확인 ${hm(crashed.$2)}). '
        '그 전의 기록은 Logs 폴더의 app.log 에 있습니다.');
  }
  await controller.init();

  final bookmarks = BookmarksController();
  await bookmarks.load();

  final downloads = DownloadManager(
    backends: services.createDownloadBackends?.call(() => controller.settings) ?? const [],
    settings: () => controller.settings,
  );
  final navigatorKey = GlobalKey<NavigatorState>();
  final messengerKey = GlobalKey<ScaffoldMessengerState>();

  final memory = WindowMemory(p.join(dataDir, 'window.json'), 'main');

  /// 종료 요청. true 를 돌려주면 프로그램을 끝낸다.
  ///  - 창 ✕ · 종료 버튼: 설정 "종료를 누르면" 에 따라 백그라운드로 (창만 숨김) / 묻지 않고 종료 / 고르기
  ///  - 트레이 "종료" · 업데이트 설치 ([force]): 항상 종료 (받는 중인 다운로드가 있으면 확인)
  Future<bool> confirmQuit({bool force = false}) async {
    final shell = services.shell;
    final desktop = shell is DesktopShell ? shell : null;
    var mode = force || (desktop?.closeFromTray ?? false) ? 'force' : controller.settings.closeAction;
    // 트레이 아이콘이 없으면 숨긴 창을 끝낼 방법이 없다 → 고르게 한다
    if (mode == 'background' && !(desktop?.hasTray ?? false)) mode = 'ask';
    if (mode == 'ask') {
      final ctx = navigatorKey.currentContext;
      if (ctx == null || !ctx.mounted) return false;
      final n = downloads.activeCount;
      final pick = await showCloseChoice(ctx,
          running: [
            if (controller.currentJob != null) controller.currentJob!,
            if (n > 0) '다운로드 $n개',
          ].join(' · ').ifEmptyText('진행 중인 작업 없음'),
          hotkey: controller.settings.showHotkey);
      if (pick == null) return false;
      if (pick.$2) controller.updateSettings((x) => x.closeAction = pick.$1);
      mode = pick.$1;
    }
    if (mode == 'background') {
      await shell.hide();
      return false;
    }
    if (mode == 'force') {
      final ctx = navigatorKey.currentContext;
      if (ctx != null && ctx.mounted && !await confirmExit(ctx, downloads)) return false;
    }
    ExitTrace.start();
    final job = controller.currentJob;
    final wait = controller.pendingJobs.length;
    final steps = [
      ExitStep(job == null ? '작업 확인 (진행 중인 작업 없음)' : '작업 중지: $job${wait > 0 ? ' · 대기 $wait개' : ''}',
          () async => controller.cancel()),
      ExitStep('다운로드 정리 (yt-dlp · aria2 종료)', downloads.shutdown),
      ExitStep('쓰레드 확인 (AI · 변환 작업이 멈출 때까지)', () async {
        while (controller.busy) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
      }),
      ExitStep('동영상 목록 · 창 위치 저장', () async {
        controller.stopVideoListShare();
        await memory.save();
        controller.note('── 정상 종료 ──');
        session.markClean();
      }),
      ExitStep('창 종료', () async {}),
    ];
    final ctx2 = navigatorKey.currentContext;
    if (ctx2 != null && ctx2.mounted) {
      await showExitProgress(ctx2, lastWork: lastWorkText(controller), steps: [
        for (final s in steps)
          ExitStep(s.label, () async {
            try {
              await s.run();
            } finally {
              ExitTrace.mark('끝: ${s.label}');
            }
          }),
      ]);
      ExitTrace.mark('종료 창 닫힘');
    } else {
      for (final s in steps) {
        try {
          await s.run().timeout(const Duration(seconds: 8));
        } catch (_) {}
      }
    }
    return true;
  }

  await services.shell.init(
    hotkey: controller.settings.showHotkey,
    minimizeToTray: () => controller.settings.minimizeToTray,
    onCloseRequested: confirmQuit,
    onDownloadsRequested: () => navigatorKey.currentState
        ?.push(MaterialPageRoute<void>(builder: (_) => DownloadsPage(d: downloads))),
  );
  // 제목 표시줄에 버전 · 지난번 창 위치에서 열기 · 동영상 목록 불러오기 (창끼리 공유)
  await windowManager.setTitle(appTitle);
  final shell = services.shell;
  if (shell is DesktopShell) memory.paused = () => shell.isPopup;
  await memory.restoreAndWatch();
  unawaited(controller.shareVideoList(p.join(dataDir, 'videos.json')));

  // 클립보드로 추가된 다운로드 알림 · 트레이 글
  downloads.onAdded.listen((t) => messengerKey.currentState
      ?.showSnackBar(SnackBar(content: Text('다운로드 추가: ${t.source}'))));
  downloads.addListener(() {
    final n = downloads.downloadingCount;
    services.shell.setTooltip(n > 0 ? 'JJ_MKVMaker - 다운로드 $n개' : 'JJ_MKVMaker');
  });
  // 다 받은 동영상 → 편집 목록 (설정에서 끌 수 있음)
  downloads.onFinished.listen((t) async {
    if (!controller.settings.addFinishedDownloads) return;
    final files = DownloadManager.videoFilesOf(t);
    if (files.isEmpty) return;
    final n = await controller.addDownloaded(files);
    // MKV 만들기 목록으로 넘어갔으므로 다운로드 목록에서는 뺀다 (받은 파일은 그대로)
    downloads.dropFromList(t);
    if (n > 0) {
      messengerKey.currentState?.showSnackBar(SnackBar(content: Text('동영상 목록에 추가: ${t.title}')));
    }
  });
  downloads.setAutoAdd = (on) async {
    await controller.updateSettings((x) => x.addFinishedDownloads = on);
    downloads.refresh();
  };
  // COM 준비 상태 지킴이: 풀려 있으면 (앱 안 브라우저가 "CoInitialize 가 호출되지 않았습니다" 로 안 뜨는 원인)
  // 다시 준비하고 작업 기록에 남긴다. 바로 앞의 기록을 보면 무엇을 한 뒤에 풀렸는지 알 수 있다.
  Timer.periodic(const Duration(seconds: 3), (_) {
    if (ComGuard.repairIfNeeded()) {
      controller.note('⚠ Windows COM 준비 상태가 풀려 있어 다시 준비했습니다 (브라우저 · 끌어다 놓기에 필요)');
    }
  });
  downloads.addToEditList = controller.addDownloaded;
  downloads.log = controller.note;
  unawaited(downloads.startClipboardWatch());

  // 탐색기 메뉴 · 두 번째 실행에서 온 요청 처리
  instance.listen((req) async {
    await services.shell.show();
    if (req.files.isEmpty) return;
    // 프로그램을 파일과 함께 처음 켠 경우: 첫 화면이 뜰 때까지 (최대 10초) 기다린다
    for (var i = 0; i < 100 && navigatorKey.currentContext == null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    final ctx = navigatorKey.currentContext;
    if (ctx == null || !ctx.mounted) return;
    switch (req.action) {
      case LaunchAction.play:
        // 재생한 동영상도 MKV 화면의 목록에 넣는다
        unawaited(controller.addVideos(req.files.where(isVideoFile).toList(), allowOutputFolder: true));
        await playFiles(ctx, controller, req.files);
      case LaunchAction.subtitle:
        await controller.addVideos(req.files.where(isVideoFile).toList());
        final targets = controller.videos
            .where((v) => req.files.any((f) => p.equals(f, v.path)))
            .toList();
        if (targets.isNotEmpty && ctx.mounted) {
          controller.select(targets.first);
          await showAiDialog(ctx, controller, targets.first, targets: targets);
        }
      case LaunchAction.add:
        // 탐색기 더블클릭 · 연결 프로그램: 설정에 따라 재생 또는 편집 목록에 추가
        final videos = req.files.where(isVideoFile).toList();
        if (videos.isEmpty) return;
        // 어느 쪽이든 MKV 화면의 목록에는 들어간다
        final added = controller.addVideos(videos, allowOutputFolder: true);
        if (controller.settings.openFileAction == 'add') {
          await added;
          final first = controller.videos.where((v) => videos.any((f) => p.equals(f, v.path))).firstOrNull;
          if (first != null) controller.select(first);
        } else {
          unawaited(added);
          await playFiles(ctx, controller, videos);
        }
    }
  });

  controller.confirmQuit = () => confirmQuit(force: true); // 업데이트 설치: 항상 종료

  // 처음 화면이 뜬 뒤: 필수 프로그램 점검 (없으면 물어보고 설치) → 새 버전 확인 (하루 한 번)
  WidgetsBinding.instance.addPostFrameCallback((_) async {
    final ctx = navigatorKey.currentContext;
    if (ctx == null) return;
    if (crashed != null) {
      messengerKey.currentState?.showSnackBar(SnackBar(
        duration: const Duration(seconds: 10),
        content: Text('지난 실행이 정상적으로 끝나지 않았습니다 (마지막 확인 '
            '${crashed.$2.hour.toString().padLeft(2, '0')}:${crashed.$2.minute.toString().padLeft(2, '0')}). '
            '작업 기록에 남겨 두었습니다.'),
      ));
    }
    // 시작 화면을 "웹 브라우저" 로 정했으면 브라우저를 연다 (MKV 화면은 그 아래에 있음)
    if (controller.settings.startScreen == 'browser') {
      navigatorKey.currentState?.push(MaterialPageRoute<void>(
          builder: (_) => BrowserPage(c: controller, downloads: downloads, bookmarks: bookmarks)));
    }
    await checkRequiredTools(ctx, services.shell);
    final ctx2 = navigatorKey.currentContext;
    if (ctx2 != null && ctx2.mounted) await checkForUpdate(ctx2, controller);
  });

  runApp(JjCapCutApp(
    controller: controller,
    downloads: downloads,
    bookmarks: bookmarks,
    navigatorKey: navigatorKey,
    messengerKey: messengerKey,
    onExit: () async {
      if (await confirmQuit()) await services.shell.quit();
    },
  ));
}

/// 탐색기에서 연 동영상을 새 재생 창으로 띄울지 (재생 요청 + 설정 "새 창에서")
bool wantsNewPlayerWindow(LaunchRequest r, AppSettings s) =>
    s.openFileWindow == 'new' &&
    r.files.any(isVideoFile) &&
    (r.action == LaunchAction.play || (r.action == LaunchAction.add && s.openFileAction == 'play'));

extension on String {
  String ifEmptyText(String other) => isEmpty ? other : this;
}

/// 종료 창에 보일 "바로 전 작업": 하던 작업, 없으면 마지막 작업 기록 (시각 표시는 뺀다)
String lastWorkText(AppController c) {
  if (c.currentJob != null) return c.currentJob!;
  if (c.logs.isEmpty) return '없음';
  return c.logs.last.replaceFirst(RegExp(r'^\[[\d:]+\]\s*'), '').split('\n').first;
}

/// Android: 창 하나. 트레이 · 단축키 · 탐색기 연결 · 다운로드 (yt-dlp · aria2) · 업데이트는 없다.
/// 데스크톱 화면을 그대로 쓰므로 가로 화면으로 띄운다.
Future<void> runAndroid(String dataDir) async {
  await SystemChrome.setPreferredOrientations(
      [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]);
  final services = PlatformServices.create();
  final logs = Directory(p.join(dataDir, 'Logs'))..createSync(recursive: true);
  final controller = AppController(services, settingsStore: SettingsStore())..logFile = p.join(logs.path, 'app.log');
  controller.note('── 시작 $appTitle (Android) ──');
  await controller.init();
  final bookmarks = BookmarksController();
  await bookmarks.load();
  final navigatorKey = GlobalKey<NavigatorState>();
  final messengerKey = GlobalKey<ScaffoldMessengerState>();
  AndroidStorageService.navigatorKey = navigatorKey;

  // 다운로드 (앱 안 브라우저의 [다운로드] · 다운로드 목록): 앱에 넣은 yt-dlp · aria2c. 클립보드 감시는 하지 않는다.
  AndroidDownloadTools.log = controller.note;
  final downloads = DownloadManager(
    backends: services.createDownloadBackends?.call(() => controller.settings) ?? const [],
    settings: () => controller.settings,
  );
  downloads.onAdded.listen((t) => messengerKey.currentState
      ?.showSnackBar(SnackBar(content: Text('다운로드 추가: ${t.source}'))));
  // 다 받은 동영상 → 편집 목록 (설정에서 끌 수 있음)
  downloads.onFinished.listen((t) async {
    if (!controller.settings.addFinishedDownloads) return;
    final files = DownloadManager.videoFilesOf(t);
    if (files.isEmpty) return;
    final n = await controller.addDownloaded(files);
    downloads.dropFromList(t);
    if (n > 0) {
      messengerKey.currentState?.showSnackBar(SnackBar(content: Text('동영상 목록에 추가: ${t.title}')));
    }
  });
  downloads.setAutoAdd = (on) async {
    await controller.updateSettings((x) => x.addFinishedDownloads = on);
    downloads.refresh();
  };
  downloads.addToEditList = controller.addDownloaded;
  downloads.log = controller.note;

  WidgetsBinding.instance.addPostFrameCallback((_) async {
    if (controller.settings.startScreen == 'browser') {
      navigatorKey.currentState?.push(MaterialPageRoute<void>(
          builder: (_) => BrowserPage(c: controller, downloads: downloads, bookmarks: bookmarks)));
    }
    // 동영상을 읽고 옆에 MKV 를 만들려면 저장소 전체 접근이 필요하다
    if (!await AndroidAccess.hasAllFiles()) {
      messengerKey.currentState?.showSnackBar(SnackBar(
        duration: const Duration(seconds: 20),
        content: const Text('동영상을 고르고 MKV 를 만들려면 "모든 파일에 대한 접근" 권한이 필요합니다.'),
        action: SnackBarAction(label: '허용', onPressed: AndroidAccess.request),
      ));
    }
  });

  runApp(JjCapCutApp(
    controller: controller,
    downloads: downloads,
    bookmarks: bookmarks,
    navigatorKey: navigatorKey,
    messengerKey: messengerKey,
    onExit: () async {
      final ctx = navigatorKey.currentContext;
      if (ctx != null && ctx.mounted && !await confirmExit(ctx, downloads)) return;
      if (controller.busy && ctx != null && ctx.mounted) {
        final ok = await showDialog<bool>(
          context: ctx,
          builder: (c) => AlertDialog(
            title: const Text('종료'),
            content: Text('진행 중인 작업이 있습니다: ${controller.currentJob ?? ''}\n중지하고 끝낼까요?'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('취소')),
              FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('종료')),
            ],
          ),
        );
        if (ok != true) return;
      }
      controller.cancel();
      await downloads.shutdown();
      controller.note('── 정상 종료 ──');
      await services.shell.quit();
    },
  ));
}

/// 탐색기에서 연 동영상의 새 창: 바로 재생하고, ← 로 나오면 같은 동영상 목록의 MKV 화면.
/// 트레이 · 단축키 · 다운로드 · 브라우저는 원래 창이 맡는다. 닫으면 이 창만 끝난다.
/// 동영상 목록은 원래 창과 같은 파일을 보므로 어느 창에서 넣거나 지워도 서로 맞춰진다.
/// 설정은 읽기만 한다 (원래 창의 설정 파일을 덮어쓰지 않도록 저장하지 않음).
Future<void> runSecondWindow(List<String> files, String dataDir) async {
  await windowManager.ensureInitialized();
  await windowManager.setTitle(appTitle);
  await WindowMemory(p.join(dataDir, 'window.json'), 'second').restoreAndWatch();
  final controller = AppController(PlatformServices.create());
  await controller.init();
  controller.settings = await SettingsStore().load();
  final navigatorKey = GlobalKey<NavigatorState>();
  runApp(JjCapCutApp(controller: controller, navigatorKey: navigatorKey, onExit: () => exit(0)));
  WidgetsBinding.instance.addPostFrameCallback((_) async {
    await controller.shareVideoList(p.join(dataDir, 'videos.json'));
    unawaited(controller.addVideos(files, allowOutputFolder: true));
    final ctx = navigatorKey.currentContext;
    if (ctx != null && ctx.mounted) await playFiles(ctx, controller, files);
  });
}

class JjCapCutApp extends StatelessWidget {
  final AppController controller;
  final DownloadManager? downloads;
  final BookmarksController? bookmarks;
  final GlobalKey<NavigatorState>? navigatorKey;
  final GlobalKey<ScaffoldMessengerState>? messengerKey;
  final VoidCallback? onExit;

  const JjCapCutApp({
    super.key,
    required this.controller,
    this.downloads,
    this.bookmarks,
    this.navigatorKey,
    this.messengerKey,
    this.onExit,
  });

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: appTitle,
        debugShowCheckedModeBanner: false,
        theme: buildTheme(),
        navigatorKey: navigatorKey,
        scaffoldMessengerKey: messengerKey,
        // 모든 화면에: 환경 설정 · 종료 버튼이 쓸 것 + 끌어다 놓은 동영상을 목록에 추가
        builder: (context, child) => AppScope(
            controller: controller,
            onExit: onExit,
            downloads: downloads,
            bookmarks: bookmarks,
            child: AppDropArea(c: controller, child: UiScaler(c: controller, child: child!))),
        home: HomePage(c: controller, downloads: downloads, onExit: onExit, bookmarks: bookmarks),
      );
}
