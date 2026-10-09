import 'dart:async';
import 'dart:io';

import 'package:flutter/cupertino.dart' show CupertinoLocalizations, DefaultCupertinoLocalizations;
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:window_manager/window_manager.dart';

import 'app/app_controller.dart';
import 'app/live_sync.dart';
import 'app/model_backup.dart';
import 'app/version_snapshot.dart';
import 'app/install_marker.dart';
import 'app/component_store.dart';
import 'ui/settings_problem.dart';
import 'ui/exit_guard.dart' show confirmStopCopies;
import 'app/copy_center.dart';
import 'ui/migration_notice.dart';
import 'app/ai_local.dart';
import 'ui/license_texts.dart';
import 'platform/windows/data_dir_override.dart';
import 'ui/master_prompt.dart';
import 'ui/secret_issue.dart';
import 'ui/sync_alert.dart';
import 'app/bookmarks_controller.dart';
import 'app/download_manager.dart';
import 'app/settings.dart';
import 'core/app_update.dart';
import 'core/playlist.dart';
import 'platform/android/android_download_tools.dart';
import 'platform/android/android_keep_alive.dart';
import 'platform/android/android_shell.dart' show applyScreenOrientation;
import 'platform/android/android_storage.dart';
import 'ui/all_files_guide.dart';
import 'platform/windows/app_paths.dart';
import 'platform/windows/cef_runtime.dart';
import 'platform/windows/com_guard.dart';
import 'platform/windows/desktop_shell.dart';
import 'platform/windows/exit_trace.dart';
import 'platform/windows/session_marker.dart';
import 'platform/windows/single_instance.dart';
import 'platform/windows/start_menu.dart';
import 'platform/windows/window_memory.dart';
import 'services/platform_services.dart';
import 'ui/ai_dialog.dart';
import 'ui/app_actions.dart';
import 'ui/app_drop.dart';
import 'ui/browser_page.dart';
import 'ui/downloads_page.dart';
import 'ui/exit_dialog.dart';
import 'ui/home_page.dart';
import 'ui/monitor_page.dart' show askLiveSyncStart, MonitorPage;
import 'ui/player_page.dart';
import 'ui/setup_dialog.dart';
import 'ui/update_dialog.dart';
import 'ui/version_restore.dart';
import 'ui/theme.dart';
import 'ui/work_panel.dart';
import 'l10n/tr.dart';
import 'app/i18n_controller.dart';
import 'platform/android/android_updater.dart';

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
  // 62 · 63 · 64 · 123: GPL · LGPL 원문 · 고지 문서 · AI 구성 요소 · 모델을 앱 안 라이선스 화면에
  registerAppLicenses();
  applyDataDirOverride(); // 시험판: 사용자 데이터와 다른 폴더 (JJ_MKVMAKER_DATA)
  final dataDir = await _prepare();
  if (Platform.isAndroid) return runAndroid(dataDir);

  // 이미 실행 중이면 인수(탐색기에서 고른 파일)를 넘기고 끝낸다
  final request = LaunchRequest.parse(args);
  final newWindow = wantsNewPlayerWindow(request, await SettingsStore().load());
  // 시험판은 사용자가 켜 둔 앱에 넘기지 않고 따로 뜬다
  final instance = SingleInstance(port: dataDirOverride == null ? 47821 : 47822);
  if (!await instance.claim(request, waitForExit: args.contains('--restart'), forward: !newWindow)) {
    // 설정이 "새 창에서" 이고 이미 켜져 있으면: 재생만 하는 창으로 따로 뜬다
    if (newWindow) return runSecondWindow(request.files.where(isVideoFile).toList(), dataDir);
    endProcessNow(); // exit(0) 은 막 뜬 엔진을 정리하다 coremessaging.dll 에서 꺼진다

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
  controller.note(trf('── 시작 {0} ({1}) ──', [appTitle, AppPaths.exeDir]));
  // 예전 구조 (한 폴더) 에서 Lib 구조로 바뀐 뒤 맨 위에 남은 예전 프로그램 파일 정리
  final cleaned = AppPaths.cleanupOldLayout();
  if (cleaned.isNotEmpty) controller.note(trf('예전 구조의 프로그램 파일 정리 ({0}개): {1}', [cleaned.length, cleaned.join(', ')]));
  if (crashed != null) {
    String hm(DateTime t) => '${t.month}/${t.day} ${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
    controller.note(trf('⚠ 지난 실행이 정상적으로 끝나지 않았습니다 (시작 {0}, 마지막 확인 {1}). ' '그 전의 기록은 Logs 폴더의 app.log 에 있습니다.', [hm(crashed.$1), hm(crashed.$2)]));
  }
  // 버전별 설정 보관 (업데이트 · 예전 버전으로 되돌리기): 시작할 때 설정 파일이 없었는지 (새로 설치)
  final freshInstall = !File(p.join(dataDir, 'settings.json')).existsSync();
  ComponentStore.dataDirectory = dataDir;
  AiStore.instance = AiStore(dataDir); // 123 · 121: AI 모델 · 엔진 (앱 데이터 폴더의 ai)
  VersionSnapshot.instance = VersionSnapshot(dataDir);
  await controller.init();
  await setupMasterLock(controller); // 124: 저장된 비밀번호를 쓰기 전에 (실시간 동기화보다 먼저)
  // 실시간 동기화 (환경 설정 > 파일 탐색기): 앱이 켜져 있는 동안. 다시 켤 때 바로 / 골라서 / 시작 안 함
  await findBundledRsync(); // 앱에 들어 있는 rsync
  final live = LiveSync(controller)..start(hold: controller.settings.liveSyncOnStart != 'auto');
  // 화면 언어 (환경 설정 > 화면 언어)
  i18n.init(controller, dataDir);
  await i18n.apply(controller.settings.uiLanguage, save: false);

  final bookmarks = BookmarksController();
  await bookmarks.load();

  final downloads = DownloadManager(
    backends: services.createDownloadBackends?.call(() => controller.settings) ?? const [],
    settings: () => controller.settings,
  );
  final navigatorKey = GlobalKey<NavigatorState>();
  final messengerKey = GlobalKey<ScaffoldMessengerState>();
  attachMasterPrompt(navigatorKey);

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
            if (n > 0) trf('다운로드 {0}개', [n]),
            if ((CopyCenter.peekOf(controller)?.activeCount ?? 0) > 0)
              trf('복사 · 이동 {0}개', [CopyCenter.peekOf(controller)!.activeCount]),
          ].join(' · ').ifEmptyText(tr('진행 중인 작업 없음')),
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
    // 43: 복사 · 이동 중이면 (설정이 "묻지 않고 종료" 여도) 한 번 묻는다
    {
      final ctx = navigatorKey.currentContext;
      if (ctx != null && ctx.mounted && !await confirmStopCopies(ctx, controller)) return false;
    }
    ExitTrace.start();
    final job = controller.currentJob;
    final wait = controller.pendingJobs.length;
    final steps = [
      ExitStep(job == null ? tr('작업 확인 (진행 중인 작업 없음)') : trf('작업 중지: {0}{1}', [job, wait > 0 ? trf(' · 대기 {0}개', [wait]) : '']),
          () async => controller.cancel()),
      ExitStep(tr('다운로드 정리 (yt-dlp · aria2 종료)'), downloads.shutdown),
      ExitStep(tr('쓰레드 확인 (AI · 변환 작업이 멈출 때까지)'), () async {
        while (controller.busy) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
      }),
      ExitStep(tr('동영상 목록 · 창 위치 저장'), () async {
        controller.stopVideoListShare();
        await memory.save();
        controller.note(tr('── 정상 종료 ──'));
        session.markClean();
      }),
      ExitStep(tr('창 종료'), () async {}),
    ];
    final ctx2 = navigatorKey.currentContext;
    if (ctx2 != null && ctx2.mounted) {
      await showExitProgress(ctx2, lastWork: lastWorkText(controller), steps: [
        for (final s in steps)
          ExitStep(s.label, () async {
            try {
              await s.run();
            } finally {
              ExitTrace.mark(trf('끝: {0}', [s.label]));
            }
          }),
      ]);
      ExitTrace.mark(tr('종료 창 닫힘'));
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
    onDownloadsRequested: () {
      final nav = navigatorKey.currentState;
      if (nav != null) unawaited(DownloadsPage.open(nav, downloads));
    },
  );
  await services.shell.setAppIcon(controller.settings.appIcon);
  // 99: 시작 메뉴 바로 가기 (앱 ID) · jjmkvmaker:// 연결 - 알림이 JJ_MKVMaker 로 보이고 눌러서 열린다 (설정에서 끔)
  StartMenu.setProcessAppId();
  final shell0 = services.shell;
  if (controller.settings.startMenuShortcut) {
    unawaited(StartMenu.ensure().then((ok) {
      if (shell0 is DesktopShell) shell0.toastAppReady = ok;
    }));
  } else {
    unawaited(StartMenu.remove());
  }
  // 제목 표시줄에 버전 · 지난번 창 위치에서 열기 · 동영상 목록 불러오기 (창끼리 공유)
  await windowManager.setTitle(appTitle);
  final shell = services.shell;
  if (shell is DesktopShell) memory.paused = () => shell.isPopup;
  await memory.restoreAndWatch();
  unawaited(controller.shareVideoList(p.join(dataDir, 'videos.json')));

  // 클립보드로 추가된 다운로드 알림 · 트레이 글
  downloads.onAdded.listen((t) => messengerKey.currentState
      ?.showSnackBar(SnackBar(content: Text(trf('다운로드 추가: {0}', [t.source])))));
  // 92: 트레이에 둔 채 실시간 동기화가 멈추면 Windows 알림 · 트레이 툴팁, 누르면 모니터링 > lsync 카드로
  final syncAlert = SyncAlert(live, services.shell,
      toastEnabled: () => controller.settings.syncStopToast,
      openLsync: () {
        final nav = navigatorKey.currentState;
        if (nav != null) unawaited(nav.push(MaterialPageRoute<void>(builder: (_) => MonitorPage(c: controller, initialTab: 1))));
      },
      baseTooltip: () {
        final n = downloads.downloadingCount;
        return n > 0 ? trf('JJ_MKVMaker - 다운로드 {0}개', [n]) : 'JJ_MKVMaker';
      });
  downloads.addListener(() => services.shell.setTooltip(syncAlert.tooltip()));
  // 다 받은 동영상 → 편집 목록 (설정에서 끌 수 있음)
  downloads.onFinished.listen((t) async {
    if (!controller.settings.addFinishedDownloads) return;
    final files = DownloadManager.videoFilesOf(t);
    if (files.isEmpty) return;
    final n = await controller.addDownloaded(files);
    // MKV 만들기 목록으로 넘어갔으므로 다운로드 목록에서는 뺀다 (받은 파일은 그대로)
    downloads.dropFromList(t);
    if (n > 0) {
      messengerKey.currentState?.showSnackBar(SnackBar(content: Text(trf('동영상 목록에 추가: {0}', [t.title]))));
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
      controller.note(tr('⚠ Windows COM 준비 상태가 풀려 있어 다시 준비했습니다 (브라우저 · 끌어다 놓기에 필요)'));
    }
  });
  downloads.addToEditList = controller.addDownloaded;
  downloads.log = controller.note;
  unawaited(downloads.startClipboardWatch());

  // 탐색기 메뉴 · 두 번째 실행에서 온 요청 처리
  instance.listen((req) async {
    await services.shell.show();
    // 99: 동기화가 멈췄다는 알림을 누름 → 실시간 동기화 화면
    if (req.action == LaunchAction.lsync) {
      for (var i = 0; i < 100 && navigatorKey.currentState == null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      final nav = navigatorKey.currentState;
      if (nav != null) unawaited(nav.push(MaterialPageRoute<void>(builder: (_) => MonitorPage(c: controller, initialTab: 1))));
      return;
    }
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
        await controller.addVideos(req.files.where(isVideoFile).toList(), allowOutputFolder: true);
        final targets = controller.videos
            .where((v) => req.files.any((f) => p.equals(f, v.path)))
            .toList();
        if (targets.isNotEmpty && ctx.mounted) {
          controller.select(targets.first);
          await showAiDialog(ctx, controller, targets.first, targets: targets);
        }
      case LaunchAction.lsync:
        break; // 위에서 처리
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
    // 124: "처음 시작 시" 면 마스터 비밀번호
    await askMasterAtStartup(ctx, controller);
    if (!ctx.mounted) return;
    if (crashed != null) {
      messengerKey.currentState?.showSnackBar(SnackBar(
        duration: const Duration(seconds: 10),
        content: Text(trf('지난 실행이 정상적으로 끝나지 않았습니다 (마지막 확인 ' '{0}:{1}). ' '작업 기록에 남겨 두었습니다.', [crashed.$2.hour.toString().padLeft(2, '0'), crashed.$2.minute.toString().padLeft(2, '0')])),
      ));
    }
    // 홈 화면이 MKV 화면이 아니면 (또는 MKV 만들기를 제거했으면) 그 화면을 연다 (MKV 화면은 그 아래에 있음)
    final home = AppNavButtons.homeId(controller.settings);
    final nav0 = navigatorKey.currentState;
    if (home != 'mkv' && nav0 != null) {
      unawaited(AppNavButtons.openPage(nav0, home, c: controller, downloads: downloads, bookmarks: bookmarks));
    }
    if (controller.settings.liveSyncOnStart == 'ask' && ctx.mounted) await askLiveSyncStart(ctx, live);
    // 설정 파일을 읽지 못했으면 (백업으로 되살렸거나 처음 설정으로 켰으면) 알린다
    if (ctx.mounted) await showSettingsProblem(ctx, controller);
    watchSecretIssue(messengerKey, controller);
    // 업데이트로 예전 기본값을 새 기본값으로 옮겼으면 한 번 알린다
    if (ctx.mounted) await showMigrationNotice(ctx, controller);
    // 다른 버전을 쓰다가 이 버전으로 돌아왔으면 보관해 둔 이 버전의 설정을 되살릴지
    final current = await _currentVersion(services);
    if (ctx.mounted) {
      await checkVersionRestore(ctx, controller, current: current, freshInstall: freshInstall, restart: services.shell.restart);
    }
    if (!ctx.mounted) return;
    await checkRequiredTools(ctx, services.shell);
    final ctx2 = navigatorKey.currentContext;
    if (ctx2 != null && ctx2.mounted) await checkForUpdate(ctx2, controller);
  });

  runApp(JjMkvMakerApp(
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

/// Android: 다른 앱 (파일 앱 "다음으로 열기" · 공유) 에서 받은 동영상.
/// 설정 "다른 앱에서 동영상을 열 때" 에 따라 바로 재생 (기본) 또는 MKV 목록에 추가. 실제 경로를 모르는 것은 재생만.
Future<void> openFromOtherApp(
    GlobalKey<NavigatorState> navigatorKey, AppController c, List<Map<Object?, Object?>> files) async {
  final paths = [for (final f in files) f['path'] as String?].whereType<String>().toList();
  final uris = [
    for (final f in files)
      if (f['path'] == null) f['uri'] as String,
  ];
  c.note(trf('다른 앱에서 열기: {0}', [files.map((f) => f['name'] ?? f['uri']).join(', ')]));
  // MKV 화면으로 돌아온 뒤 (재생 중이었다면 그 화면은 닫는다)
  navigatorKey.currentState?.popUntil((r) => r.isFirst);
  final ctx = navigatorKey.currentContext;
  if (ctx == null || !ctx.mounted) return;
  if (paths.isNotEmpty) {
    final added = c.addVideos(paths, allowOutputFolder: true);
    if (c.settings.openFileAction == 'add') {
      await added;
      final first = c.videos.where((v) => paths.any((f) => p.equals(f, v.path))).firstOrNull;
      if (first != null) c.select(first);
    } else {
      unawaited(added);
      await playFiles(ctx, c, paths);
    }
  } else if (uris.isNotEmpty) {
    // 파일 위치를 알려 주지 않는 앱: 재생만 (MKV 만들기 · 자막은 파일 고르기로 추가해야 함)
    ScaffoldMessenger.maybeOf(ctx)?.showSnackBar(SnackBar(
        content: Text(tr('파일 위치를 알 수 없어 재생만 합니다. MKV 를 만들려면 "동영상 추가" 로 고르세요.'))));
    final create = c.services.createMediaPlayer;
    if (create != null) {
      await Navigator.of(ctx).push(MaterialPageRoute<void>(
          builder: (_) => PlayerPage(c: c, player: create(), files: uris, start: 0)));
    }
  }
}

/// 탐색기에서 연 동영상을 새 재생 창으로 띄울지 (재생 요청 + 설정 "새 창에서")
bool wantsNewPlayerWindow(LaunchRequest r, AppSettings s) =>
    s.openFileWindow == 'new' &&
    r.files.any(isVideoFile) &&
    (r.action == LaunchAction.play || (r.action == LaunchAction.add && s.openFileAction == 'play'));

extension on String {
  String ifEmptyText(String other) => isEmpty ? other : this;
}

/// 지금 실행 중인 버전 (예: 2026.10.05_003). 모르면 ''.
Future<String> _currentVersion(PlatformServices services) async {
  try {
    return await services.updater?.currentVersion() ?? '';
  } catch (_) {
    return '';
  }
}

/// 종료 창에 보일 "바로 전 작업": 하던 작업, 없으면 마지막 작업 기록 (시각 표시는 뺀다)
String lastWorkText(AppController c) {
  if (c.currentJob != null) return c.currentJob!;
  if (c.logs.isEmpty) return tr('없음');
  return c.logs.last.replaceFirst(RegExp(r'^\[[\d:]+\]\s*'), '').split('\n').first;
}

/// Android: 창 하나. 트레이 · 단축키 · 탐색기 연결 · 다운로드 (yt-dlp · aria2) · 업데이트는 없다.
/// 화면 방향은 기본이 자동 (기기를 돌리는 대로). 환경 설정 > 화면 방향에서 가로 · 세로 고정.
Future<void> runAndroid(String dataDir) async {
  final services = PlatformServices.create();
  final logs = Directory(p.join(dataDir, 'Logs'))..createSync(recursive: true);
  final controller = AppController(services, settingsStore: SettingsStore())..logFile = p.join(logs.path, 'app.log');
  controller.note(trf('── 시작 {0} (Android) ──', [appTitle]));
  // 버전별 설정 보관: 앱을 지웠다 다시 설치해도 남도록 공용 Download/JJ_MKVMaker 에도 (예전 버전으로 되돌릴 때)
  final freshInstall = !File(p.join(dataDir, 'settings.json')).existsSync();
  // 115: 다시 설치한 뒤 처음 켰는데 설정이 있으면 Android 자동 백업이 되살린 것 (표시 파일은 백업에서 뺐다)
  final marker = InstallMarker(dataDir);
  var autoBackup = false;
  try {
    final info = await PackageInfo.fromPlatform();
    autoBackup = restoredByAutoBackup(
        settingsExisted: !freshInstall, markerExists: marker.exists, installTime: info.installTime, updateTime: info.updateTime);
  } catch (_) {}
  marker.write();
  if (autoBackup) controller.note(tr('Android 자동 백업에서 되살린 설정으로 시작합니다'));
  ComponentStore.dataDirectory = dataDir;
  AiStore.instance = AiStore(dataDir); // 123 · 121: AI 모델 · 엔진 (앱 데이터 폴더의 ai)
  String? sharedSnapshots;
  try {
    final root = await const MethodChannel('jj_mkvmaker/android').invokeMethod<String>('storageRoot');
    // l10n-skip: 실제 폴더 이름 (예전 보관을 찾아야 하므로 바꾸지 않음)
    if (root != null) sharedSnapshots = p.join(root, 'Download', 'JJ_MKVMaker', '설정 보관');
    if (root != null) ModelBackup.sharedRoot = p.join(root, 'Download', 'JJ_MKVMaker');
  } catch (_) {}
  VersionSnapshot.instance = VersionSnapshot(dataDir, sharedDir: sharedSnapshots);
  await controller.init();
  await setupMasterLock(controller); // 124: 저장된 비밀번호를 쓰기 전에 (실시간 동기화보다 먼저)
  // 실시간 동기화 (환경 설정 > 파일 탐색기): 앱이 켜져 있는 동안. 다시 켤 때 바로 / 골라서 / 시작 안 함
  await findBundledRsync(); // 앱에 들어 있는 rsync
  final live = LiveSync(controller)..start(hold: controller.settings.liveSyncOnStart != 'auto');
  // 화면 언어 (환경 설정 > 화면 언어)
  i18n.init(controller, dataDir);
  await i18n.apply(controller.settings.uiLanguage, save: false);
  await applyScreenOrientation(controller.settings.screenOrientation);
  unawaited(services.shell.setAppIcon(controller.settings.appIcon));
  final bookmarks = BookmarksController();
  await bookmarks.load();
  final navigatorKey = GlobalKey<NavigatorState>();
  final messengerKey = GlobalKey<ScaffoldMessengerState>();
  AndroidStorageService.navigatorKey = navigatorKey;
  attachMasterPrompt(navigatorKey);

  // 다운로드 (앱 안 브라우저의 [다운로드] · 다운로드 목록): 앱에 넣은 yt-dlp · aria2c. 클립보드 감시는 하지 않는다.
  AndroidDownloadTools.log = controller.note;
  final downloads = DownloadManager(
    backends: services.createDownloadBackends?.call(() => controller.settings) ?? const [],
    settings: () => controller.settings,
  );
  downloads.onAdded.listen((t) => messengerKey.currentState
      ?.showSnackBar(SnackBar(content: Text(trf('다운로드 추가: {0}', [t.source])))));
  // 다 받은 동영상 → 편집 목록 (설정에서 끌 수 있음)
  downloads.onFinished.listen((t) async {
    if (!controller.settings.addFinishedDownloads) return;
    final files = DownloadManager.videoFilesOf(t);
    if (files.isEmpty) return;
    final n = await controller.addDownloaded(files);
    downloads.dropFromList(t);
    if (n > 0) {
      messengerKey.currentState?.showSnackBar(SnackBar(content: Text(trf('동영상 목록에 추가: {0}', [t.title]))));
    }
  });
  downloads.setAutoAdd = (on) async {
    await controller.updateSettings((x) => x.addFinishedDownloads = on);
    downloads.refresh();
  };
  downloads.addToEditList = controller.addDownloaded;
  downloads.log = controller.note;
  // 진행 중인 일이 있으면 화면에서 내려가도 계속 (알림에 진행 상황)
  AndroidKeepAlive(controller, downloads);
  // 170: 업데이트 설치의 첫 시도 실패 원문을 작업 기록에
  final updater = services.updater;
  if (updater is AndroidUpdater) updater.log = controller.note;
  // 백그라운드로 실행: 화면 (Activity) 을 닫아도 엔진은 살아 있다가 다시 열면 새 화면에 붙는다 → 화면 방향을 다시 적용
  // (웹뷰는 텍스처로 그려 새 화면에 붙어도 그대로 보인다: browser_page _webSettings)
  // 116: 권한 ("모든 파일에 대한 접근") 이 없어 분석에 실패한 동영상은 허용하고 돌아오면 저절로 다시 분석
  controller.fileAccess = AndroidAccess.hasAllFiles;
  var hadAccess = await AndroidAccess.hasAllFiles();
  if (hadAccess) await allFilesGuideDue(controller, hasAccess: true);
  AppLifecycleListener(onResume: () async {
    await applyScreenOrientation(controller.settings.screenOrientation);
    final now = await AndroidAccess.hasAllFiles();
    if (now && !hadAccess) await controller.reanalyzeFailed();
    if (now) await allFilesGuideDue(controller, hasAccess: true);
    hadAccess = now;
  });
  // 동영상 목록 기억 (앱을 껐다 켜도 그대로, 없어진 파일은 뺀다) - Windows 와 같은 파일
  unawaited(controller.shareVideoList(p.join(dataDir, 'videos.json')));

  // 연결 프로그램 · 공유로 받은 동영상: 앱이 켜져 있을 때 (MainActivity.onNewIntent)
  const android = MethodChannel('jj_mkvmaker/android');
  android.setMethodCallHandler((call) async {
    if (call.method == 'showJobs') {
      // 작업 알림을 눌렀다: 작업 현황 화면으로
      final nav = navigatorKey.currentState;
      if (nav != null) unawaited(WorkStatusPage.open(nav, controller, downloads));
      return null;
    }
    if (call.method == 'openFiles') {
      await openFromOtherApp(navigatorKey, controller, (call.arguments as List).cast<Map<Object?, Object?>>());
    }
    return null;
  });

  WidgetsBinding.instance.addPostFrameCallback((_) async {
    // 연결 프로그램 · 공유로 앱을 켠 경우: 그 동영상부터
    try {
      if (await android.invokeMethod<bool>('takeShowJobs') ?? false) {
        final nav = navigatorKey.currentState;
        if (nav != null) unawaited(WorkStatusPage.open(nav, controller, downloads));
      }
      final opened = await android.invokeMethod<List<Object?>>('takeOpenedFiles') ?? const [];
      if (opened.isNotEmpty) {
        unawaited(openFromOtherApp(navigatorKey, controller, opened.cast<Map<Object?, Object?>>()));
        return;
      }
    } catch (_) {}
    // 동영상을 읽고 옆에 MKV 를 만들려면 저장소 전체 접근이 필요하다.
    // 39: 켤 때마다 띄우지 않고 한 번만. 그 뒤로는 파일 탐색기 위의 안내 · 동영상 항목의 안내가 알려 준다
    // 116: 다른 안내 · 분석 오류보다 먼저 (허용하고 돌아오면 실패한 분석을 다시 한다 - onResume)
    final ctxA = navigatorKey.currentContext;
    if (ctxA != null && ctxA.mounted && await allFilesGuideDue(controller, hasAccess: hadAccess) && ctxA.mounted) {
      await showAllFilesGuide(ctxA, AndroidAccess.request);
    }
    // 124: "처음 시작 시" 면 마스터 비밀번호
    final ctxM = navigatorKey.currentContext;
    if (ctxM != null && ctxM.mounted) await askMasterAtStartup(ctxM, controller);
    final home = AppNavButtons.homeId(controller.settings);
    final nav0 = navigatorKey.currentState;
    if (home != 'mkv' && nav0 != null) {
      unawaited(AppNavButtons.openPage(nav0, home, c: controller, downloads: downloads, bookmarks: bookmarks));
    }
    // 다시 켤 때 실시간 동기화를 골라서 시작
    final ctx0 = navigatorKey.currentContext;
    if (controller.settings.liveSyncOnStart == 'ask' && ctx0 != null && ctx0.mounted) await askLiveSyncStart(ctx0, live);
    // 다른 버전을 쓰다가 돌아왔거나 앱을 다시 설치했으면 보관해 둔 설정을 되살릴지 (되살리면 앱을 끝내고 다시 켜 달라고)
    final current = await _currentVersion(services);
    final ctxV = navigatorKey.currentContext;
    if (ctxV != null && ctxV.mounted) await showSettingsProblem(ctxV, controller);
    watchSecretIssue(messengerKey, controller);
    if (ctxV != null && ctxV.mounted) await showMigrationNotice(ctxV, controller);
    if (ctxV != null && ctxV.mounted) {
      await checkVersionRestore(ctxV, controller, current: current, freshInstall: freshInstall, autoBackup: autoBackup,
          restart: () async {
        messengerKey.currentState?.showSnackBar(SnackBar(content: Text(tr('설정을 되살렸습니다. 앱을 끝냅니다 - 다시 켜 주세요.'))));
        await Future<void>.delayed(const Duration(seconds: 2));
        await services.shell.quit();
      });
    }
    // P0: 되돌리느라 공용 폴더에 옮겨 둔 받은 AI 모델 되살리기
    final ctxModels = navigatorKey.currentContext;
    if (ctxModels != null && ctxModels.mounted) await restoreModelBackup(ctxModels, controller);
    // 새 버전 확인 (하루 한 번, 환경 설정에서 끌 수 있음)
    final ctx = navigatorKey.currentContext;
    if (ctx != null && ctx.mounted) unawaited(checkForUpdate(ctx, controller));
  });

  runApp(JjMkvMakerApp(
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
            title: Text(tr('종료')),
            content: Text(trf('진행 중인 작업이 있습니다: {0}\n중지하고 끝낼까요?', [controller.currentJob ?? ''])),
            actions: [
              TextButton(onPressed: () => Navigator.pop(c, false), child: Text(tr('취소'))),
              FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(tr('종료'))),
            ],
          ),
        );
        if (ok != true) return;
      }
      controller.cancel();
      await downloads.shutdown();
      controller.note(tr('── 정상 종료 ──'));
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
  // 화면 언어 (환경 설정 > 화면 언어)
  i18n.init(controller, dataDir);
  await i18n.apply(controller.settings.uiLanguage, save: false);
  final store = SettingsStore();
  controller.settings = await store.load();
  final navigatorKey = GlobalKey<NavigatorState>();
  // 124: 이 창도 저장된 비밀번호 (WebDAV 재생) 를 쓰기 전에 마스터를 묻는다 (풀린 상태는 창마다)
  await setupMasterLock(controller, secrets: store.secrets);
  attachMasterPrompt(navigatorKey);
  runApp(JjMkvMakerApp(controller: controller, navigatorKey: navigatorKey, onExit: endProcessNow));
  WidgetsBinding.instance.addPostFrameCallback((_) async {
    await controller.shareVideoList(p.join(dataDir, 'videos.json'));
    unawaited(controller.addVideos(files, allowOutputFolder: true));
    final ctx = navigatorKey.currentContext;
    if (ctx != null && ctx.mounted) await playFiles(ctx, controller, files);
  });
}

class JjMkvMakerApp extends StatelessWidget {
  final AppController controller;
  final DownloadManager? downloads;
  final BookmarksController? bookmarks;
  final GlobalKey<NavigatorState>? navigatorKey;
  final GlobalKey<ScaffoldMessengerState>? messengerKey;
  final VoidCallback? onExit;

  const JjMkvMakerApp({
    super.key,
    required this.controller,
    this.downloads,
    this.bookmarks,
    this.navigatorKey,
    this.messengerKey,
    this.onExit,
  });

  /// 140 · 158: Flutter 기본 글 (뒤로 · Licenses 등) 을 화면 언어로 - 앱 언어 코드 → Locale
  /// 앱이 더한 언어 (기계 번역 사전) 도 Flutter 가 아는 언어면 그 언어로, 모르는 언어일 때만 영어로 (한국어가 섞이지 않게).
  /// "zh-Hant" · "pt-BR" 같은 코드는 글자 체계 (4글자) · 나라 (2글자 · 숫자) 로 나눈다.
  static Locale localeOf(String code) {
    final parts = code.split(RegExp('[-_]'));
    String? script;
    String? country;
    for (final s in parts.skip(1)) {
      if (s.length == 4) {
        script = s;
      } else if (s.isNotEmpty) {
        country = s;
      }
    }
    final l = Locale.fromSubtags(languageCode: parts.first.toLowerCase(), scriptCode: script, countryCode: country?.toUpperCase());
    return GlobalMaterialLocalizations.delegate.isSupported(l) ? l : const Locale('en');
  }

  /// Flutter 기본 글 사전들. Material 은 알고 Cupertino 는 모르는 언어 (예: ps) 에서도 Cupertino 글이 비지 않게 영어로 채운다.
  static const localizationsDelegates = [...GlobalMaterialLocalizations.delegates, _CupertinoFallbackDelegate()];

  /// Flutter 가 아는 모든 언어. 지금 언어를 맨 앞에 두어 글자 체계 · 나라까지 그대로 고르게 ("zh-Hant" 가 간체로 바뀌지 않게).
  static List<Locale> supportedLocalesFor(Locale current) => [
        current,
        for (final c in kMaterialSupportedLanguages)
          if (c != current.languageCode || current.scriptCode != null || current.countryCode != null) Locale(c),
      ];

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        // 화면 언어를 바꾸면 (i18n) Flutter 기본 글도 그 언어로
        listenable: i18n,
        builder: (context, _) => _app(context),
      );

  Widget _app(BuildContext context) {
    final locale = localeOf(uiLanguage);
    return MaterialApp(
        locale: locale,
        supportedLocales: supportedLocalesFor(locale),
        localizationsDelegates: localizationsDelegates,
        title: appTitle,
        debugShowCheckedModeBanner: false,
        theme: buildTheme(),
        navigatorKey: navigatorKey,
        scaffoldMessengerKey: messengerKey,
        navigatorObservers: [browserRouteObserver],
        // 모든 화면에: 환경 설정 · 종료 버튼이 쓸 것 + 끌어다 놓은 동영상을 목록에 추가
        builder: (context, child) => AppScope(
            controller: controller,
            onExit: onExit,
            downloads: downloads,
            bookmarks: bookmarks,
            child: AppDropArea(c: controller, child: _SystemBarsArea(child: UiScaler(c: controller, child: child!)))),
        home: HomePage(c: controller, downloads: downloads, onExit: onExit, bookmarks: bookmarks),
      );
  }
}

/// Cupertino 글이 없는 언어만 영어로 (GlobalCupertinoLocalizations 뒤에 두어 그쪽이 아는 언어는 그쪽이 먼저)
class _CupertinoFallbackDelegate extends LocalizationsDelegate<CupertinoLocalizations> {
  const _CupertinoFallbackDelegate();

  @override
  bool isSupported(Locale locale) => true;

  @override
  Future<CupertinoLocalizations> load(Locale locale) => DefaultCupertinoLocalizations.load(locale);

  @override
  bool shouldReload(_CupertinoFallbackDelegate old) => false;
}

/// Android: 앱 화면이 상태 표시줄 · 아래쪽 작업 표시줄 밑까지 그려지므로 (Android 15 부터 기본)
/// 위쪽 버튼 줄이 시계 · 배터리 표시와 겹치지 않게 그만큼 띄운다. 전체 화면 재생 중에는 표시줄이 숨어 여백도 없다.
class _SystemBarsArea extends StatelessWidget {
  final Widget child;
  const _SystemBarsArea({required this.child});

  @override
  Widget build(BuildContext context) => Platform.isAndroid
      ? ColoredBox(color: Theme.of(context).scaffoldBackgroundColor, child: SafeArea(child: child))
      : child;
}
