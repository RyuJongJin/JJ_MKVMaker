/// 창 · 트레이 · 전역 단축키 경계 (데스크톱 전용 기능)
///
/// Windows: platform/windows/desktop_shell.dart
/// Android·테스트: [NoopShell]
abstract class AppShell {
  /// [onShowRequested]: 트레이 클릭·단축키로 창 보이기
  /// [onCloseRequested]: 창의 X 또는 트레이 "종료" (true 를 돌려주면 종료)
  /// [onDownloadsRequested]: 트레이 "다운로드 목록"
  Future<void> init({
    required String hotkey,
    required bool Function() minimizeToTray,
    required Future<bool> Function() onCloseRequested,
    void Function()? onDownloadsRequested,
  });

  Future<void> show();
  Future<void> hide();

  /// 단축키 변경 (예: "Ctrl+Shift+X"). 형식이 틀리면 false.
  Future<bool> setHotkey(String hotkey);

  /// 트레이 알림 글 (다운로드 개수 등)
  Future<void> setTooltip(String text);

  /// 프로그램 종료
  Future<void> quit();

  // ───────── 플레이어 창 ─────────

  Future<void> setFullScreen(bool on);
  Future<bool> isFullScreen();

  /// 팝업 보기: 작은 창 · 항상 위 · 제목 표시줄 없음. 끄면 원래 크기로.
  Future<void> setPopup(bool on);

  /// 창 크기를 영상 크기의 [factor] 배로 (화면보다 크면 화면에 맞춤)
  Future<void> fitVideo(int width, int height, double factor);

  // ───────── 탐색기 · 외부 프로그램 ─────────

  Future<bool> isContextMenuRegistered();
  Future<bool> registerContextMenu();
  Future<void> unregisterContextMenu();

  /// [program]: 'system' = 기본 연결 프로그램, 그 외 = 실행 파일 경로
  Future<void> openExternal(String program, List<String> files);

  /// 설치된 VLC 경로 (없으면 null)
  String? get vlcPath;

  /// 웹 주소를 외부 브라우저로 열기. [browser]: 'system' · 'chrome' · 'firefox' · 'edge' · 'whale'
  Future<void> openUrl(String url, {String browser = 'system'});

  /// 파일이 있는 폴더를 파일 관리자(탐색기)로 열고 그 파일을 선택해 보여 준다
  Future<void> revealFile(String path);

  /// 설치된 외부 브라우저 ('chrome', 'firefox', 'edge', 'whale' 중)
  List<String> installedBrowsers();

  // ───────── 필수 프로그램 ─────────

  /// 없는 필수 프로그램 설명 (예: "FFmpeg - MKV 만들기 (약 100MB)")
  Future<List<String>> missingTools();

  /// 없는 필수 프로그램을 공식 배포처에서 내려받아 설치
  Future<void> installMissingTools(void Function(String name, double progress) onProgress);

  /// 프로그램 다시 시작 (새로 설치한 프로그램 인식)
  Future<void> restart();
}

class NoopShell implements AppShell {
  @override
  Future<void> init({
    required String hotkey,
    required bool Function() minimizeToTray,
    required Future<bool> Function() onCloseRequested,
    void Function()? onDownloadsRequested,
  }) async {}
  @override
  Future<void> show() async {}
  @override
  Future<void> hide() async {}
  @override
  Future<bool> setHotkey(String hotkey) async => true;
  @override
  Future<void> setTooltip(String text) async {}
  @override
  Future<void> quit() async {}
  @override
  Future<void> setFullScreen(bool on) async {}
  @override
  Future<bool> isFullScreen() async => false;
  @override
  Future<void> setPopup(bool on) async {}
  @override
  Future<void> fitVideo(int width, int height, double factor) async {}
  @override
  Future<bool> isContextMenuRegistered() async => false;
  @override
  Future<bool> registerContextMenu() async => false;
  @override
  Future<void> unregisterContextMenu() async {}
  @override
  Future<void> openExternal(String program, List<String> files) async {}
  @override
  String? get vlcPath => null;
  @override
  Future<void> openUrl(String url, {String browser = 'system'}) async {}
  @override
  Future<void> revealFile(String path) async {}
  @override
  List<String> installedBrowsers() => const [];
  @override
  Future<List<String>> missingTools() async => const [];
  @override
  Future<void> installMissingTools(void Function(String name, double progress) onProgress) async {}
  @override
  Future<void> restart() async {}
}

/// "Ctrl+Shift+X" → (수식키 목록, 키 이름). 형식이 틀리면 null.
(List<String>, String)? parseHotkey(String text) {
  final parts = text.split('+').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
  if (parts.length < 2) return null;
  const mods = {'ctrl', 'shift', 'alt', 'win'};
  final m = parts.sublist(0, parts.length - 1).map((s) => s.toLowerCase()).toList();
  if (m.any((s) => !mods.contains(s)) || m.toSet().length != m.length) return null;
  final key = parts.last.toUpperCase();
  final ok = RegExp(r'^([A-Z0-9]|F([1-9]|1[0-2]))$').hasMatch(key);
  return ok ? (m, key) : null;
}
