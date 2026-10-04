import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:tray_manager/tray_manager.dart' as tray;
import 'package:screen_retriever/screen_retriever.dart';
import 'package:window_manager/window_manager.dart';

import '../../services/app_shell.dart';
import 'exit_trace.dart';
import 'shell_integration.dart';
import 'tool_installer.dart';
import '../../l10n/tr.dart';

/// Windows 데스크톱: 트레이 아이콘 · 전역 단축키 · 창 닫기 가로채기
class DesktopShell with WindowListener implements AppShell {
  tray.TrayIcon? _tray;
  HotKey? _hotkey;
  late bool Function() _minimizeToTray;
  late Future<bool> Function() _onClose;
  void Function()? _onDownloads;
  bool _closing = false;

  @override
  Future<void> init({
    required String hotkey,
    required bool Function() minimizeToTray,
    required Future<bool> Function() onCloseRequested,
    void Function()? onDownloadsRequested,
  }) async {
    _minimizeToTray = minimizeToTray;
    _onClose = onCloseRequested;
    _onDownloads = onDownloadsRequested;

    await windowManager.ensureInitialized();
    await windowManager.setPreventClose(true);
    windowManager.addListener(this);

    _initTray();
    await hotKeyManager.unregisterAll();
    await setHotkey(hotkey);
  }

  /// 고른 앱 아이콘 (init 전에 [setAppIcon] 으로 정해 둘 수 있음)
  String _icon = appIconIds.first;

  tray.Image? _trayImage() =>
      tray.ImageAsset.fromAsset('assets/icon/variants/$_icon.ico') ??
      tray.ImageAsset.fromAsset('assets/tray_icon.ico') ??
      tray.Image.fromFile(Platform.resolvedExecutable);

  /// 창 · 작업 표시줄 · 트레이 아이콘 (exe 파일 아이콘 · 바탕 화면 바로 가기는 그대로)
  @override
  Future<void> setAppIcon(String id) async {
    _icon = appIconOf(id);
    final ico = p.join(p.dirname(Platform.resolvedExecutable), 'data', 'flutter_assets', 'assets', 'icon', 'variants',
        '$_icon.ico');
    try {
      if (File(ico).existsSync()) await windowManager.setIcon(ico);
    } catch (_) {}
    final t = _tray;
    if (t != null) t.icon = _trayImage();
  }

  void _initTray() {
    final t = tray.TrayIcon.create();
    if (t == null) return;
    t.icon = _trayImage();
    t.setTooltip('JJ_MKVMaker');

    final menu = tray.Menu.create()!;
    tray.MenuItem item(String label, void Function() onClick) {
      final i = tray.MenuItem.createWithLabelAndType(label, tray.MenuItemType.normal)!;
      i.addListener((e) {
        if (e is tray.MenuItemClickedEvent) onClick();
      });
      menu.addItem(i);
      return i;
    }

    item(tr('열기'), show);
    item(tr('다운로드 목록'), () async {
      await show();
      _onDownloads?.call();
    });
    menu.addSeparator();
    item(tr('종료'), () => _requestClose(fromTray: true));
    t.setContextMenu(menu);
    t.setContextMenuTrigger(tray.ContextMenuTrigger.rightClicked);
    t.addListener((e) {
      if (e is tray.TrayIconClickedEvent || e is tray.TrayIconDoubleClickedEvent) show();
    });
    t.setVisible(true);
    _tray = t;
  }

  @override
  Future<bool> setHotkey(String text) async {
    final parsed = parseHotkey(text);
    if (parsed == null) return false;
    final (mods, key) = parsed;
    final physical = _keyOf(key);
    if (physical == null) return false;
    final hk = HotKey(
      key: physical,
      modifiers: [
        for (final m in mods)
          switch (m) {
            'ctrl' => HotKeyModifier.control,
            'shift' => HotKeyModifier.shift,
            'alt' => HotKeyModifier.alt,
            _ => HotKeyModifier.meta,
          },
      ],
      scope: HotKeyScope.system,
    );
    if (_hotkey != null) await hotKeyManager.unregister(_hotkey!);
    await hotKeyManager.register(hk, keyDownHandler: (_) => toggle());
    _hotkey = hk;
    return true;
  }

  static PhysicalKeyboardKey? _keyOf(String k) {
    const letters = [
      PhysicalKeyboardKey.keyA, PhysicalKeyboardKey.keyB, PhysicalKeyboardKey.keyC,
      PhysicalKeyboardKey.keyD, PhysicalKeyboardKey.keyE, PhysicalKeyboardKey.keyF,
      PhysicalKeyboardKey.keyG, PhysicalKeyboardKey.keyH, PhysicalKeyboardKey.keyI,
      PhysicalKeyboardKey.keyJ, PhysicalKeyboardKey.keyK, PhysicalKeyboardKey.keyL,
      PhysicalKeyboardKey.keyM, PhysicalKeyboardKey.keyN, PhysicalKeyboardKey.keyO,
      PhysicalKeyboardKey.keyP, PhysicalKeyboardKey.keyQ, PhysicalKeyboardKey.keyR,
      PhysicalKeyboardKey.keyS, PhysicalKeyboardKey.keyT, PhysicalKeyboardKey.keyU,
      PhysicalKeyboardKey.keyV, PhysicalKeyboardKey.keyW, PhysicalKeyboardKey.keyX,
      PhysicalKeyboardKey.keyY, PhysicalKeyboardKey.keyZ,
    ];
    const digits = [
      PhysicalKeyboardKey.digit0, PhysicalKeyboardKey.digit1, PhysicalKeyboardKey.digit2,
      PhysicalKeyboardKey.digit3, PhysicalKeyboardKey.digit4, PhysicalKeyboardKey.digit5,
      PhysicalKeyboardKey.digit6, PhysicalKeyboardKey.digit7, PhysicalKeyboardKey.digit8,
      PhysicalKeyboardKey.digit9,
    ];
    const fkeys = [
      PhysicalKeyboardKey.f1, PhysicalKeyboardKey.f2, PhysicalKeyboardKey.f3,
      PhysicalKeyboardKey.f4, PhysicalKeyboardKey.f5, PhysicalKeyboardKey.f6,
      PhysicalKeyboardKey.f7, PhysicalKeyboardKey.f8, PhysicalKeyboardKey.f9,
      PhysicalKeyboardKey.f10, PhysicalKeyboardKey.f11, PhysicalKeyboardKey.f12,
    ];
    if (k.length == 1) {
      final c = k.codeUnitAt(0);
      if (c >= 65 && c <= 90) return letters[c - 65];
      if (c >= 48 && c <= 57) return digits[c - 48];
    }
    if (k.startsWith('F')) {
      final n = int.tryParse(k.substring(1));
      if (n != null && n >= 1 && n <= 12) return fkeys[n - 1];
    }
    return null;
  }

  @override
  Future<void> show() async {
    if (await windowManager.isMinimized()) await windowManager.restore();
    await windowManager.show();
    await windowManager.focus();
  }

  /// 단축키: 창이 앞에 보이면 트레이로 숨기고, 숨겨져 있거나 다른 창 뒤에 있으면 앞으로 가져온다
  Future<void> toggle() async {
    final front = await windowManager.isVisible() &&
        !await windowManager.isMinimized() &&
        await windowManager.isFocused();
    if (front && !_closing) {
      await hide();
    } else {
      await show();
    }
  }

  /// 숨긴 창은 작업 표시줄에도 나타나지 않는다.
  /// (window_manager 0.5.2 의 setSkipTaskbar 는 Windows 에서 충돌하므로 쓰지 않음)
  @override
  Future<void> hide() => windowManager.hide();

  @override
  Future<void> setTooltip(String text) async => _tray?.setTooltip(text);

  /// 트레이 아이콘이 있는지 (없으면 창을 숨긴 뒤 끝낼 방법이 없으므로 백그라운드로 보내지 않는다)
  bool get hasTray => _tray != null;

  /// 지금 처리 중인 종료 요청이 트레이 메뉴 "종료" 에서 왔는지 (항상 완전히 종료)
  bool closeFromTray = false;

  Future<void> _requestClose({bool fromTray = false}) async {
    if (_closing) return;
    _closing = true;
    closeFromTray = fromTray;
    try {
      // 트레이에서 종료: 진행 창을 보여 주려고 창을 연다. 창의 ✕ 는 이미 보이는 상태.
      if (fromTray) await show();
      if (await _onClose()) await quit();
    } finally {
      _closing = false;
      closeFromTray = false;
    }
  }

  @override
  void onWindowClose() => _requestClose();

  @override
  void onWindowMinimize() {
    if (_minimizeToTray()) hide();
  }

  // ───────── 플레이어 창 ─────────

  Rect? _beforePopup;
  bool _popup = false;

  /// 팝업 보기 중 (이때의 작은 창 크기는 기억하지 않는다)
  bool get isPopup => _popup;

  @override
  Future<void> setFullScreen(bool on) async {
    if (on && _popup) await setPopup(false);
    await windowManager.setFullScreen(on);
  }

  @override
  Future<bool> isFullScreen() => windowManager.isFullScreen();

  @override
  Future<void> setPopup(bool on) async {
    if (on == _popup) return;
    if (on) {
      if (await windowManager.isFullScreen()) await windowManager.setFullScreen(false);
      _beforePopup = await windowManager.getBounds();
      await windowManager.setTitleBarStyle(TitleBarStyle.hidden);
      await windowManager.setAlwaysOnTop(true);
      final area = await _workArea();
      const size = Size(480, 270);
      await windowManager.setBounds(Rect.fromLTWH(
          area.right - size.width - 24, area.bottom - size.height - 24, size.width, size.height));
    } else {
      await windowManager.setAlwaysOnTop(false);
      await windowManager.setTitleBarStyle(TitleBarStyle.normal);
      if (_beforePopup != null) await windowManager.setBounds(_beforePopup!);
    }
    _popup = on;
  }

  Future<Rect> _workArea() async {
    final d = await screenRetriever.getPrimaryDisplay();
    final pos = d.visiblePosition ?? Offset.zero;
    final size = d.visibleSize ?? d.size;
    return pos & size;
  }

  @override
  Future<void> fitVideo(int width, int height, double factor) async {
    if (width <= 0 || height <= 0) return;
    if (await windowManager.isFullScreen()) await windowManager.setFullScreen(false);
    if (_popup) await setPopup(false);
    final area = await _workArea();
    // 조작 막대 · 제목 표시줄 여유
    const extraH = 120.0, extraW = 16.0;
    var w = width * factor, h = height * factor;
    final scale = [1.0, (area.width - extraW) / w, (area.height - extraH) / h].reduce((a, b) => a < b ? a : b);
    w *= scale;
    h *= scale;
    await windowManager.setSize(Size(w + extraW, h + extraH));
    await windowManager.center();
  }

  // ───────── 탐색기 · 외부 프로그램 ─────────

  final _shellMenu = ShellIntegration();

  @override
  Future<bool> isContextMenuRegistered() => _shellMenu.isRegistered();
  @override
  Future<bool> registerContextMenu() => _shellMenu.register();
  @override
  Future<void> unregisterContextMenu() => _shellMenu.unregister();
  @override
  Future<void> openExternal(String program, List<String> files) => openExternally(program, files);
  @override
  String? get vlcPath => findVlc();

  @override
  Future<void> openUrl(String url, {String browser = 'system'}) => openInBrowser(url, browser);

  /// 탐색기로 폴더를 열고 파일을 선택. 파일이 없으면 폴더만 (그것도 없으면 가장 가까운 위 폴더).
  @override
  Future<void> revealFile(String path) async {
    if (File(path).existsSync()) {
      await Process.start('explorer.exe', ['/select,', path], mode: ProcessStartMode.detached);
      return;
    }
    var dir = Directory(path).existsSync() ? Directory(path) : File(path).parent;
    while (!dir.existsSync() && dir.parent.path != dir.path) {
      dir = dir.parent;
    }
    await Process.start('explorer.exe', [dir.path], mode: ProcessStartMode.detached);
  }

  @override
  List<String> installedBrowsers() => [
        for (final b in browserExecutables.keys)
          if (findBrowser(b) != null) b,
      ];

  // ───────── 필수 프로그램 ─────────

  final _installer = ToolInstaller();

  @override
  Future<List<String>> missingTools() async => [
        for (final t in await _installer.missing()) trf('{0} - {1} (약 {2}MB)', [t.name, t.purpose, t.sizeMb]),
      ];

  @override
  Future<void> installMissingTools(void Function(String name, double progress) onProgress) async =>
      _installer.install(await _installer.missing(), onProgress);

  /// 새 프로세스는 --restart 로 시작해 이 창이 닫힐 때까지 기다린다
  @override
  Future<void> restart() async {
    await Process.start(Platform.resolvedExecutable, ['--restart'], mode: ProcessStartMode.detached);
    await quit();
  }

  @override
  Future<void> quit() async {
    ExitTrace.mark(tr('quit 시작'));
    // 단축키 해제가 늦어도 종료를 붙잡지 않게 (프로세스가 끝나면 어차피 풀린다)
    try {
      await hotKeyManager.unregisterAll().timeout(const Duration(milliseconds: 500));
    } catch (_) {}
    ExitTrace.mark(tr('단축키 해제'));
    _tray?.setVisible(false);
    _tray?.dispose();
    ExitTrace.mark(tr('트레이 정리'));
    windowManager.removeListener(this);
    // 창을 숨기고 바로 끝낸다. 엔진 · 웹뷰 · 플레이어를 차례로 닫는 정상 종료는 몇 초씩 걸리는데,
    // 저장할 것은 이미 모두 저장했고 다운로드 · 변환 프로세스도 앞 단계에서 끝냈다.
    try {
      await windowManager.hide().timeout(const Duration(milliseconds: 500));
    } catch (_) {}
    ExitTrace.mark(tr('창 숨김 → 프로세스 종료'));
    // exit() 는 Dart VM · 엔진 · 플러그인 DLL 을 차례로 정리하느라 1~2초 걸린다 → 프로세스를 바로 끝낸다
    Process.killPid(pid);
    exit(0);
  }
}
