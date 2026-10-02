import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import 'package:flutter/services.dart';

import '../app/app_controller.dart';
import '../core/download_detect.dart';
import '../core/playlist.dart';
import '../core/subtitle_detector.dart';
import '../services/app_shell.dart';
import 'setup_dialog.dart';
import 'update_dialog.dart';
import '../app/settings.dart';
import '../platform/windows/cef_runtime.dart';
import 'app_actions.dart';
import 'cef_setup.dart';
import 'theme.dart';

/// 동시 작업 수 고르기: 1 · 5 · 10 · 무한(0) · 직접 입력
class CountSelector extends StatelessWidget {
  final int value;
  final ValueChanged<int> onChanged;
  const CountSelector({super.key, required this.value, required this.onChanged});

  static const _presets = [1, 5, 10, 0];
  static String label(int n) => n <= 0 ? '무한' : '$n개';

  Future<void> _custom(BuildContext context) async {
    // 목록 메뉴가 완전히 닫힌 뒤 입력 창을 연다
    await Future<void>.delayed(Duration.zero);
    if (!context.mounted) return;
    final n = await showDialog<int>(
      context: context,
      builder: (_) => _CountInputDialog(initial: value),
    );
    if (n != null && n >= 0) onChanged(n);
  }

  @override
  Widget build(BuildContext context) {
    final items = {..._presets, value};
    return DropdownButton<int>(
      value: value,
      items: [
        for (final n in items) DropdownMenuItem(value: n, child: Text(label(n))),
        const DropdownMenuItem(value: -1, child: Text('직접 입력…')),
      ],
      onChanged: (n) => n == -1 ? _custom(context) : onChanged(n!),
    );
  }
}

/// 개수 직접 입력 창 (입력칸은 창이 닫히는 애니메이션이 끝난 뒤 정리)
class _CountInputDialog extends StatefulWidget {
  final int initial;
  const _CountInputDialog({required this.initial});

  @override
  State<_CountInputDialog> createState() => _CountInputDialogState();
}

class _CountInputDialogState extends State<_CountInputDialog> {
  late final _ctrl = TextEditingController(text: widget.initial > 0 ? '${widget.initial}' : '');

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('직접 입력'),
        content: TextField(
          controller: _ctrl,
          autofocus: true,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          decoration: const InputDecoration(labelText: '동시에 처리할 개수 (0 = 무한)', border: OutlineInputBorder()),
          onSubmitted: (t) => Navigator.pop(context, int.tryParse(t)),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('취소')),
          FilledButton(onPressed: () => Navigator.pop(context, int.tryParse(_ctrl.text)), child: const Text('확인')),
        ],
      );
}

/// 확장자별 재생 프로그램 (내장 / 기본 프로그램 / VLC / 직접 지정)
class _ExternalPlayers extends StatelessWidget {
  final AppController c;
  const _ExternalPlayers({required this.c});

  @override
  Widget build(BuildContext context) {
    final map = c.settings.externalPlayers;
    final vlc = c.services.shell.vlcPath;
    Future<void> set(String ext, String? v) => c.updateSettings((x) {
          if (v == null || v.isEmpty) {
            x.externalPlayers.remove(ext);
          } else {
            x.externalPlayers[ext] = v;
          }
        });

    return ExpansionTile(
      title: const Text('확장자별 재생 프로그램'),
      subtitle: Text(map.isEmpty
          ? '모두 내장 플레이어'
          : map.entries.map((e) => '${e.key}: ${e.value == 'system' ? '기본 프로그램' : e.value.split(RegExp(r'[\\/]')).last}').join(', ')),
      children: [
        for (final ext in videoExtensions)
          ListTile(
            dense: true,
            title: Text('.$ext'),
            trailing: DropdownButton<String>(
              value: map[ext] ?? '',
              items: [
                const DropdownMenuItem(value: '', child: Text('내장 플레이어')),
                const DropdownMenuItem(value: 'system', child: Text('Windows 기본 프로그램')),
                if (vlc != null) DropdownMenuItem(value: vlc, child: const Text('VLC')),
                if (map[ext] != null && map[ext] != 'system' && map[ext] != vlc)
                  DropdownMenuItem(value: map[ext], child: Text(map[ext]!.split(RegExp(r'[\\/]')).last)),
                const DropdownMenuItem(value: '*pick', child: Text('프로그램 직접 선택…')),
              ],
              onChanged: (v) async {
                if (v == '*pick') {
                  final r = await FilePicker.pickFile(
                      dialogTitle: '.$ext 재생 프로그램 (exe)', type: FileType.custom, allowedExtensions: const ['exe']);
                  if (r?.path != null) await set(ext, r!.path);
                } else {
                  await set(ext, v);
                }
              },
            ),
          ),
        if (vlc == null)
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text('VLC 가 설치되어 있지 않습니다. 설치하면 목록에 나타납니다 (videolan.org).',
                style: TextStyle(fontSize: 12, color: JjColors.textDim)),
          ),
      ],
    );
  }
}

/// 탐색기 오른쪽 클릭 메뉴 등록 / 해제
class _ContextMenuTile extends StatefulWidget {
  final AppController c;
  const _ContextMenuTile({required this.c});

  @override
  State<_ContextMenuTile> createState() => _ContextMenuTileState();
}

class _ContextMenuTileState extends State<_ContextMenuTile> {
  bool? _registered;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final r = await widget.c.services.shell.isContextMenuRegistered();
    if (mounted) setState(() => _registered = r);
  }

  Future<void> _toggle() async {
    setState(() => _busy = true);
    final shell = widget.c.services.shell;
    if (_registered == true) {
      await shell.unregisterContextMenu();
    } else {
      final ok = await shell.registerContextMenu();
      if (!ok && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('등록 중 일부가 실패했습니다.')));
      }
    }
    await _refresh();
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) => ListTile(
        title: const Text('탐색기 오른쪽 클릭 메뉴'),
        subtitle: Text(_registered == true
            ? '등록됨: "JJ_MKVMaker 로 재생" · "JJ_MKVMaker 로 자막 만들기" (Windows 11: 더 많은 옵션 표시)'
            : '동영상 파일을 오른쪽 클릭해 바로 재생하거나 자막을 만들 수 있게 합니다 (현재 사용자만)'),
        trailing: _registered == null
            ? null
            : OutlinedButton(
                onPressed: _busy ? null : _toggle,
                child: Text(_registered! ? '해제' : '등록'),
              ),
      );
}

/// 환경 설정
class SettingsPage extends StatefulWidget {
  final AppController c;
  const SettingsPage({super.key, required this.c});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  AppController get c => widget.c;
  late final _hotkey = TextEditingController(text: c.settings.showHotkey);
  String? _hotkeyError;

  @override
  void dispose() {
    _hotkey.dispose();
    super.dispose();
  }

  Future<String?> _pickDir(String title) => FilePicker.getDirectoryPath(dialogTitle: title);

  Future<void> _applyHotkey() async {
    final text = _hotkey.text.trim();
    if (parseHotkey(text) == null) {
      setState(() => _hotkeyError = '예: Ctrl+Shift+X (Ctrl·Shift·Alt·Win + 영문자·숫자·F1~F12)');
      return;
    }
    final ok = await c.services.shell.setHotkey(text);
    setState(() => _hotkeyError = ok ? null : '이 단축키를 등록할 수 없습니다 (다른 프로그램이 사용 중일 수 있음)');
    if (ok) await c.updateSettings((s) => s.showHotkey = text);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        final s = c.settings;
        // Android: 창 · 트레이 · 탐색기 · 다운로드 (yt-dlp · aria2) · 내장 Chrome 설정은 없음
        final desk = !Platform.isAndroid;
        return Scaffold(
          body: Column(children: [
            Container(
              height: appBarHeight,
              color: JjColors.panel,
              padding: const EdgeInsets.only(left: 8, right: appBarRightPadding),
              child: Row(children: [
                const AppNavButtons(),
                const SizedBox(width: 8),
                const Text('환경 설정', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                const Spacer(),
                const Text('바꾸면 바로 저장됩니다', style: TextStyle(fontSize: 12, color: JjColors.textDim)),
                const SizedBox(width: 8),
                AppActions(c: c, onSettingsPage: true),
              ]),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                children: [
                  // 맨 위: 지금 버전 · 최신 버전 확인 (Windows · Android)
                  if (c.services.updater != null) ...[
                    _section('프로그램 정보 · 업데이트'),
                    ListTile(
                      leading: const Icon(Icons.system_update_alt, color: JjColors.accent),
                      title: FutureBuilder<String>(
                        future: c.services.updater!.currentVersion(),
                        builder: (_, v) => Text('JJ_MKVMaker v${v.data ?? '…'}'),
                      ),
                      subtitle: const Text('GitHub 의 최신 버전과 비교해, 새 버전이 있으면 받아서 설치합니다'),
                      trailing: FilledButton.icon(
                        onPressed: () => checkForUpdate(context, c, manual: true),
                        icon: const Icon(Icons.refresh, size: 18),
                        label: const Text('최신 버전 확인'),
                      ),
                    ),
                    SwitchListTile(
                      value: s.autoCheckUpdates,
                      onChanged: (v) => c.updateSettings((x) => x.autoCheckUpdates = v),
                      title: const Text('시작할 때 새 버전 확인 (하루 한 번)'),
                    ),
                  ],
                  _section('화면'),
                  ListTile(
                    title: const Text('기본 화면 크기'),
                    subtitle: Text('글자 · 버튼 크기입니다. 위쪽 막대의 − · + 로 그때그때 바꿀 수 있고, 가운데 숫자를 누르면 이 크기로 돌아갑니다 '
                        '(지금 ${(s.uiScale * 100).round()}%)'),
                    trailing: DropdownButton<double>(
                      value: s.uiScaleDefault,
                      items: [
                        for (var v = AppSettings.uiScaleMin; v <= AppSettings.uiScaleMax + 0.001; v += 0.1)
                          DropdownMenuItem(
                              value: AppSettings.clampUiScale(v),
                              child: Text('${(v * 100).round()}%${(v - 1).abs() < 0.001 ? ' (보통)' : ''}')),
                        // 5% 단위로 저장된 값이 목록에 없을 때
                        if (((s.uiScaleDefault * 100).round() % 10) != 0)
                          DropdownMenuItem(
                              value: s.uiScaleDefault, child: Text('${(s.uiScaleDefault * 100).round()}%')),
                      ],
                      // 기본 크기를 바꾸면 지금 크기도 그 크기로
                      onChanged: (v) => c.updateSettings((x) => x
                        ..uiScaleDefault = v!
                        ..uiScale = v),
                    ),
                  ),
                  _section('시작 · 웹 브라우저'),
                  ListTile(
                    title: const Text('홈 화면'),
                    subtitle: const Text('프로그램을 켰을 때, 그리고 위쪽 왼쪽 JJ 아이콘을 눌렀을 때 보일 화면'),
                    trailing: DropdownButton<String>(
                      value: s.startScreen,
                      items: const [
                        DropdownMenuItem(value: 'home', child: Text('MKV 화면 (기본)')),
                        DropdownMenuItem(value: 'browser', child: Text('웹 브라우저 (홈 주소)')),
                      ],
                      onChanged: (v) => c.updateSettings((x) => x.startScreen = v!),
                    ),
                  ),
                  _textTile('홈 주소', s.homeUrl, '웹 브라우저의 시작 · 🏠 주소',
                      (v) => c.updateSettings((x) => x.homeUrl = v.trim().isEmpty ? 'https://www.youtube.com/' : v.trim())),
                  if (desk) ...[
                  ListTile(
                    title: const Text('브라우저 엔진 (앱 안)'),
                    subtitle: Text(
                        'Edge: Windows 에 들어 있어 따로 설치하지 않습니다. 여기서 YouTube 에 로그인하면 다운로드에도 그 로그인이 쓰입니다.\n'
                        'Chrome: 고르면 약 ${CefRuntime.approxDownloadMb}MB 를 내려받고 다시 시작한 뒤 쓸 수 있습니다 '
                        '(Google 로그인은 막힐 수 있음).'
                        '${CefRuntime.installed ? ' 지금 설치됨 (${CefRuntime.installedMb()}MB)' : ''}'
                        '${s.browserEngine == 'chrome' && !CefRuntime.readyThisRun ? ' · 다시 시작해야 Chrome 으로 바뀝니다' : ''}'),
                    isThreeLine: true,
                    trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                      if (s.browserEngine == 'edge' && CefRuntime.installed && !CefRuntime.readyThisRun)
                        IconButton(
                          tooltip: '내려받은 Chrome 엔진 지우기',
                          icon: const Icon(Icons.delete_outline, color: JjColors.textDim),
                          onPressed: () async {
                            final ok = await CefRuntime.uninstall();
                            c.note(ok ? '내장 Chrome 엔진을 지웠습니다.' : '내장 Chrome 엔진을 지우지 못했습니다 (사용 중).');
                            setState(() {});
                          },
                        ),
                      DropdownButton<String>(
                        value: s.browserEngine,
                        items: [
                          const DropdownMenuItem(value: 'edge', child: Text('Edge (내장)')),
                          DropdownMenuItem(
                              value: 'chrome',
                              child: Text(CefRuntime.installed ? 'Chrome (내장)' : 'Chrome (내려받기)')),
                        ],
                        onChanged: (v) async {
                          if (v == 'chrome') {
                            await chooseChromeEngine(context, c);
                            if (mounted) setState(() {});
                          } else {
                            await c.updateSettings((x) => x.browserEngine = 'edge');
                          }
                        },
                      ),
                    ]),
                  ),
                  ListTile(
                    title: const Text('외부 브라우저'),
                    subtitle: const Text('"외부 브라우저로 열기" 에 쓸 브라우저 (이 PC 에 설치된 것)'),
                    trailing: DropdownButton<String>(
                      value: s.externalBrowser,
                      items: [
                        const DropdownMenuItem(value: 'system', child: Text('Windows 기본 브라우저')),
                        for (final b in {...c.services.shell.installedBrowsers(), if (s.externalBrowser != 'system') s.externalBrowser})
                          DropdownMenuItem(value: b, child: Text(switch (b) {
                            'chrome' => 'Chrome',
                            'firefox' => 'Firefox',
                            'edge' => 'Edge',
                            'whale' => 'Whale',
                            _ => b,
                          })),
                      ],
                      onChanged: (v) => c.updateSettings((x) => x.externalBrowser = v!),
                    ),
                  ),
                  ],
                  _section('저장 위치'),
                  _folderTile(
                    title: 'MKV · 자막 (jj_mkv)',
                    value: s.mkvOutputRoot,
                    defaultText: '동영상이 있는 폴더 아래 jj_mkv (기본)',
                    onPick: () async {
                      final d = await _pickDir('MKV · 자막 저장 위치');
                      if (d != null) await c.updateSettings((x) => x.mkvOutputRoot = d);
                    },
                    onReset: () => c.updateSettings((x) => x.mkvOutputRoot = null),
                  ),
                  _folderTile(
                    title: '다운로드 (jj_yt-dlp · jj_aria2)',
                    value: s.downloadRoot,
                    defaultText: '${desk ? '프로그램 폴더' : '내장 저장소'} (기본): ${s.resolvedDownloadRoot()}',
                    onPick: () async {
                      final d = await _pickDir('다운로드 위치');
                      if (d != null) await c.updateSettings((x) => x.downloadRoot = d);
                    },
                    onReset: () => c.updateSettings((x) => x.downloadRoot = null),
                  ),
                  if (desk) _section('다운로드'),
                  if (desk)
                  SwitchListTile(
                    value: s.clipboardWatch,
                    onChanged: (v) => c.updateSettings((x) => x.clipboardWatch = v),
                    title: const Text('복사(Ctrl+C)한 주소 자동 다운로드'),
                    subtitle: const Text('YouTube → yt-dlp, 마그넷 · .torrent → aria2 (완료 후 올려 주기 안 함)'),
                  ),
                  _section('재생'),
                  ListTile(
                    title: const Text('동영상 하나를 재생할 때'),
                    subtitle: const Text('시리즈: file_001 · file_002, S01E01 · S01E02 처럼 번호만 다른 파일'),
                    trailing: DropdownButton<PlaylistMode>(
                      value: s.playlistMode,
                      items: [
                        for (final m in PlaylistMode.values) DropdownMenuItem(value: m, child: Text(m.label)),
                      ],
                      onChanged: (m) => c.updateSettings((x) => x.playlistMode = m!),
                    ),
                  ),
                  if (desk) ...[
                  ListTile(
                    title: const Text('탐색기에서 동영상을 열 때'),
                    subtitle: const Text('더블클릭 · 연결 프로그램으로 JJ_MKVMaker 를 골랐을 때 (오른쪽 클릭 메뉴는 그대로)'),
                    trailing: DropdownButton<String>(
                      value: s.openFileAction,
                      items: const [
                        DropdownMenuItem(value: 'play', child: Text('바로 재생 (기본)')),
                        DropdownMenuItem(value: 'add', child: Text('편집 목록에 추가 (MKV 만들기 대상)')),
                      ],
                      onChanged: (v) => c.updateSettings((x) => x.openFileAction = v!),
                    ),
                  ),
                  ListTile(
                    title: const Text('탐색기에서 연 동영상을 재생할 창'),
                    subtitle: const Text('프로그램이 이미 켜져 있을 때. 새 창은 재생만 하는 창이며 닫으면 그 창만 끝납니다'),
                    trailing: DropdownButton<String>(
                      value: s.openFileWindow,
                      items: const [
                        DropdownMenuItem(value: 'same', child: Text('켜져 있는 창에서 (기본)')),
                        DropdownMenuItem(value: 'new', child: Text('새 창에서')),
                      ],
                      onChanged: (v) => c.updateSettings((x) => x.openFileWindow = v!),
                    ),
                  ),
                  _ExternalPlayers(c: c),
                  _ContextMenuTile(c: c),
                  ],
                  _section('인터넷 자막 (OpenSubtitles.com)'),
                  _textTile('API 키 (필수, 무료)', s.openSubtitlesKey,
                      '가입 → 프로필 → API consumers → New consumer',
                      (v) => c.updateSettings((x) => x.openSubtitlesKey = v.trim())),
                  _textTile('아이디 (선택)', s.openSubtitlesUser, '로그인하면 하루 받기 횟수가 늘어납니다',
                      (v) => c.updateSettings((x) => x.openSubtitlesUser = v.trim())),
                  _textTile('비밀번호 (선택)', s.openSubtitlesPassword, '이 ${desk ? 'PC' : '기기'} 의 설정 파일에 저장됩니다',
                      (v) => c.updateSettings((x) => x.openSubtitlesPassword = v), obscure: true),
                  ListTile(
                    title: const Text('YouTube 받을 형식'),
                    subtitle: const Text('기본: MP4. 음성만 받으면 MP3 · M4A 로 저장'),
                    trailing: DropdownButton<YtContainer>(
                      value: s.ytContainer,
                      items: [for (final v in YtContainer.values) DropdownMenuItem(value: v, child: Text(v.label))],
                      onChanged: (v) => c.updateSettings((x) => x.ytContainer = v!),
                    ),
                  ),
                  ListTile(
                    enabled: !s.ytContainer.audioOnly,
                    title: const Text('YouTube 화질'),
                    subtitle: const Text('고른 크기 이하에서 가장 좋은 화질 (영상에 없는 크기면 가까운 것)'),
                    trailing: DropdownButton<YtQuality>(
                      value: s.ytQuality,
                      items: [for (final v in YtQuality.values) DropdownMenuItem(value: v, child: Text(v.label))],
                      onChanged: s.ytContainer.audioOnly ? null : (v) => c.updateSettings((x) => x.ytQuality = v!),
                    ),
                  ),
                  SwitchListTile(
                    value: s.ytExpandPlaylists,
                    onChanged: (v) => c.updateSettings((x) => x.ytExpandPlaylists = v),
                    title: const Text('재생목록 주소면 목록 전체 받기'),
                    subtitle: const Text('영상마다 한 줄씩 보여 주고 jj_yt-dlp\\재생목록 이름\\ 에 저장 (믹스 목록 제외)'),
                  ),
                  ListTile(
                    title: const Text('YouTube 쿠키 (로봇 확인이 나올 때)'),
                    subtitle: Text(s.ytCookiesFile.isNotEmpty
                        ? 'cookies.txt: ${s.ytCookiesFile}'
                        : s.ytCookiesBrowser == internalBrowserCookies
                            ? '앱 안 브라우저의 로그인 사용 (브라우저 화면에서 YouTube 에 로그인하세요)'
                            : s.ytCookiesBrowser.isNotEmpty
                                ? '${s.ytCookiesBrowser} 브라우저의 YouTube 로그인 쿠키 사용 (Chrome · Edge 는 브라우저를 닫아야 읽힐 수 있음)'
                                : '사용 안 함. "Sign in to confirm you\'re not a bot" 오류가 나오면 설정하세요'),
                    trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                      DropdownButton<String>(
                        value: s.ytCookiesFile.isNotEmpty ? '*file' : s.ytCookiesBrowser,
                        items: [
                          const DropdownMenuItem(value: '', child: Text('사용 안 함')),
                          const DropdownMenuItem(value: internalBrowserCookies, child: Text('앱 안 브라우저 (권장)')),
                          // PC 브라우저의 쿠키는 Windows 에서만
                          if (desk)
                            for (final b in const ['firefox', 'chrome', 'edge', 'brave', 'whale', 'opera'])
                              DropdownMenuItem(value: b, child: Text(b[0].toUpperCase() + b.substring(1))),
                          const DropdownMenuItem(value: '*file', child: Text('cookies.txt 파일…')),
                        ],
                        onChanged: (v) async {
                          if (v == '*file') {
                            final f = await FilePicker.pickFile(
                                dialogTitle: 'cookies.txt (Netscape 형식)',
                                type: FileType.custom,
                                allowedExtensions: const ['txt']);
                            if (f?.path != null) {
                              await c.updateSettings((x) => x
                                ..ytCookiesFile = f!.path!
                                ..ytCookiesBrowser = '');
                            }
                          } else {
                            await c.updateSettings((x) => x
                              ..ytCookiesBrowser = v ?? ''
                              ..ytCookiesFile = '');
                          }
                        },
                      ),
                    ]),
                  ),
                  ListTile(
                    title: const Text('동시 다운로드 수'),
                    subtitle: const Text('나머지는 대기했다가 차례로 받습니다'),
                    trailing: CountSelector(
                      value: s.maxParallelDownloads,
                      onChanged: (n) => c.updateSettings((x) => x.maxParallelDownloads = n),
                    ),
                  ),
                  _section('변환'),
                  ListTile(
                    title: const Text('동시 MKV 변환 수'),
                    subtitle: const Text('여러 동영상을 MKV 로 만들 때 동시에 처리할 개수 (재인코딩은 CPU 를 많이 씁니다)'),
                    trailing: CountSelector(
                      value: s.maxParallelJobs,
                      onChanged: (n) => c.updateSettings((x) => x.maxParallelJobs = n),
                    ),
                  ),
                  if (desk) ...[
                  _section('실행'),
                  ListTile(
                    title: const Text('종료 (창 닫기 ✕ · 종료 버튼) 를 누르면'),
                    subtitle: Text('백그라운드: 창만 숨기고 다운로드 · 변환은 계속합니다. ${s.showHotkey} 또는 트레이 아이콘으로 다시 엽니다.\n'

                        '완전히 끝내려면 트레이 아이콘 오른쪽 클릭 > 종료 (어느 설정이든 항상 종료)'),
                    isThreeLine: true,
                    trailing: DropdownButton<String>(
                      value: s.closeAction,
                      items: const [
                        DropdownMenuItem(value: 'background', child: Text('백그라운드로 계속 (기본)')),
                        DropdownMenuItem(value: 'quit', child: Text('다운로드 · 변환도 모두 종료 (묻지 않음)')),
                        DropdownMenuItem(value: 'ask', child: Text('매번 고르기')),
                      ],
                      onChanged: (v) => c.updateSettings((x) => x.closeAction = v!),
                    ),
                  ),
                  SwitchListTile(
                    value: s.minimizeToTray,
                    onChanged: (v) => c.updateSettings((x) => x.minimizeToTray = v),
                    title: const Text('최소화하면 트레이로 (백그라운드 실행)'),
                    subtitle: const Text('트레이 아이콘을 누르거나 아래 단축키로 다시 엽니다'),
                  ),
                  ListTile(
                    title: const Text('창 보이기 / 숨기기 단축키'),
                    subtitle: _hotkeyError == null
                        ? const Text('어디서나 누르면 JJ_MKVMaker 창이 나타납니다')
                        : Text(_hotkeyError!, style: const TextStyle(color: JjColors.danger)),
                    trailing: SizedBox(
                      width: 260,
                      child: Row(children: [
                        Expanded(
                          child: TextField(
                            controller: _hotkey,
                            decoration: const InputDecoration(isDense: true, border: OutlineInputBorder()),
                            onSubmitted: (_) => _applyHotkey(),
                          ),
                        ),
                        const SizedBox(width: 8),
                        OutlinedButton(onPressed: _applyHotkey, child: const Text('적용')),
                      ]),
                    ),
                  ),
                  SwitchListTile(
                    value: s.addFinishedDownloads,
                    onChanged: (v) => c.updateSettings((x) => x.addFinishedDownloads = v),
                    title: const Text('완료시 자동 동영상추가'),
                    subtitle: const Text('다 받는 대로 MKV 만들기의 동영상 목록에 넣고, 다운로드 목록에서는 뺍니다 (다운로드 화면의 체크 상자와 같음)'),
                  ),
                  ],
                  _section('AI 자막'),
                  SwitchListTile(
                    value: s.askAiOptions,
                    onChanged: (v) => c.updateSettings((x) => x.askAiOptions = v),
                    title: const Text('시작할 때마다 설정 창 보기'),
                    subtitle: Text('끄면 마지막 설정으로 바로 시작: 원어 ${c.aiOptions.source.name}, '
                        '언어 ${c.aiOptions.targets.map((t) => t.code).join('/')}, ${c.aiOptions.whisper.label}'),
                  ),
                  _section('프로그램'),
                  if (desk) ...[
                  ListTile(
                    title: const Text('필수 프로그램 점검'),
                    subtitle: const Text('FFmpeg · yt-dlp · aria2 · Deno 가 없으면 내려받아 설치합니다'),
                    trailing: OutlinedButton(
                      onPressed: () => checkRequiredTools(context, c.services.shell, quietIfOk: false),
                      child: const Text('점검'),
                    ),
                  ),
                  ],
                  ListTile(
                    title: const Text('오픈 소스 라이선스'),
                    subtitle: const Text('포함된 구성 요소와 라이선스 (THIRD_PARTY_NOTICES.txt)'),
                    trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                      if (desk) OutlinedButton(
                        onPressed: () => c.services.shell.openExternal('system', [
                          '${File(Platform.resolvedExecutable).parent.path}\\THIRD_PARTY_NOTICES.txt',
                        ]),
                        child: const Text('고지 문서'),
                      ),
                      if (desk) const SizedBox(width: 6),
                      OutlinedButton(
                        onPressed: () => showLicensePage(context: context, applicationName: 'JJ_MKVMaker'),
                        child: const Text('패키지 라이선스'),
                      ),
                    ]),
                  ),
                  _section('인코딩'),
                  ListTile(
                    title: const Text('마지막 인코딩 설정을 기억합니다'),
                    subtitle: Text('${c.encode.resolution.label} · ${c.encode.codec.label}'
                        '${c.encode.reencode ? ' · ${c.encode.quality.label}' : ''}  (메인 화면 상단에서 변경)'),
                  ),
                ],
              ),
            ),
          ]),
        );
      },
    );
  }

  Widget _section(String t) => Padding(
        padding: const EdgeInsets.only(top: 16, bottom: 4),
        child: Text(t, style: const TextStyle(fontSize: 13, color: JjColors.accent, fontWeight: FontWeight.w600)),
      );

  Widget _textTile(String title, String value, String hint, ValueChanged<String> onSave,
          {bool obscure = false}) =>
      ListTile(
        title: Text(title),
        subtitle: Text(hint),
        trailing: SizedBox(
          width: 320,
          child: TextFormField(
            initialValue: value,
            obscureText: obscure,
            decoration: const InputDecoration(isDense: true, border: OutlineInputBorder()),
            // 입력칸을 벗어나거나 Enter 를 누르면 저장
            onFieldSubmitted: onSave,
            onTapOutside: (_) => FocusManager.instance.primaryFocus?.unfocus(),
            onChanged: onSave,
          ),
        ),
      );

  Widget _folderTile({
    required String title,
    required String? value,
    required String defaultText,
    required VoidCallback onPick,
    required VoidCallback onReset,
  }) =>
      ListTile(
        title: Text(title),
        subtitle: Text(value ?? defaultText, maxLines: 2, overflow: TextOverflow.ellipsis),
        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
          OutlinedButton(onPressed: onPick, child: const Text('폴더 선택')),
          if (value != null) ...[
            const SizedBox(width: 6),
            TextButton(onPressed: onReset, child: const Text('기본값')),
          ],
        ]),
      );
}
