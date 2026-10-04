import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../app/app_controller.dart';
import '../app/i18n_controller.dart' show I18nController;
import '../core/download_detect.dart';
import '../core/playlist.dart';
import '../core/subtitle_detector.dart';
import '../services/app_shell.dart';
import 'setup_dialog.dart';
import 'update_dialog.dart';
import '../app/settings.dart';
import '../platform/windows/cef_runtime.dart';
import '../platform/android/android_shell.dart' show applyScreenOrientation;
import 'folder_picker.dart';
import 'language_settings.dart';
import 'app_actions.dart';
import 'cef_setup.dart';
import 'cleanup_dialog.dart';
import 'explorer_look.dart' show ExplorerStyle;
import 'theme.dart';
import '../l10n/tr.dart';

/// 동시 작업 수 고르기: 1 · 5 · 10 · 무한(0) · 직접 입력
class CountSelector extends StatelessWidget {
  final int value;
  final ValueChanged<int> onChanged;
  const CountSelector({super.key, required this.value, required this.onChanged});

  static const _presets = [1, 5, 10, 0];
  static String label(int n) => n <= 0 ? tr('무한') : trf('{0}개', [n]);

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
        DropdownMenuItem(value: -1, child: Text(tr('직접 입력…'))),
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
        title: Text(tr('직접 입력')),
        content: TextField(
          controller: _ctrl,
          autofocus: true,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          decoration: InputDecoration(labelText: tr('동시에 처리할 개수 (0 = 무한)'), border: OutlineInputBorder()),
          onSubmitted: (t) => Navigator.pop(context, int.tryParse(t)),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('취소'))),
          FilledButton(onPressed: () => Navigator.pop(context, int.tryParse(_ctrl.text)), child: Text(tr('확인'))),
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
      title: Text(tr('확장자별 재생 프로그램')),
      subtitle: Text(map.isEmpty
          ? tr('모두 내장 플레이어')
          : map.entries.map((e) => '${e.key}: ${e.value == 'system' ? tr('기본 프로그램') : e.value.split(RegExp(r'[\\/]')).last}').join(', ')),
      children: [
        for (final ext in videoExtensions)
          ListTile(
            dense: true,
            title: Text('.$ext'),
            trailing: DropdownButton<String>(
              value: map[ext] ?? '',
              items: [
                DropdownMenuItem(value: '', child: Text(tr('내장 플레이어'))),
                DropdownMenuItem(value: 'system', child: Text(tr('Windows 기본 프로그램'))),
                if (vlc != null) DropdownMenuItem(value: vlc, child: const Text('VLC')),
                if (map[ext] != null && map[ext] != 'system' && map[ext] != vlc)
                  DropdownMenuItem(value: map[ext], child: Text(map[ext]!.split(RegExp(r'[\\/]')).last)),
                DropdownMenuItem(value: '*pick', child: Text(tr('프로그램 직접 선택…'))),
              ],
              onChanged: (v) async {
                if (v == '*pick') {
                  final r = await FilePicker.pickFile(
                      dialogTitle: trf('.{0} 재생 프로그램 (exe)', [ext]), type: FileType.custom, allowedExtensions: const ['exe']);
                  if (r?.path != null) await set(ext, r!.path);
                } else {
                  await set(ext, v);
                }
              },
            ),
          ),
        if (vlc == null)
          Padding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(tr('VLC 가 설치되어 있지 않습니다. 설치하면 목록에 나타납니다 (videolan.org).'),
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
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('등록 중 일부가 실패했습니다.'))));
      }
    }
    await _refresh();
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) => ListTile(
        title: Text(tr('탐색기 오른쪽 클릭 메뉴')),
        subtitle: Text(_registered == true
            ? tr('등록됨: "JJ_MKVMaker 로 재생" · "JJ_MKVMaker 로 자막 만들기" (Windows 11: 더 많은 옵션 표시)')
            : tr('동영상 파일을 오른쪽 클릭해 바로 재생하거나 자막을 만들 수 있게 합니다 (현재 사용자만)')),
        trailing: _registered == null
            ? null
            : OutlinedButton(
                onPressed: _busy ? null : _toggle,
                child: Text(_registered! ? tr('해제') : tr('등록')),
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

  /// 폴더 고르기. Android 는 앱 안 화면 (내장 저장소 · SD 카드 · USB 를 실제 경로로 고를 수 있음)
  Future<String?> _pickDir(String title, [String? initial]) => pickFolder(context, title, initial);

  Future<void> _applyHotkey() async {
    final text = _hotkey.text.trim();
    if (parseHotkey(text) == null) {
      setState(() => _hotkeyError = tr('예: Ctrl+Shift+X (Ctrl·Shift·Alt·Win + 영문자·숫자·F1~F12)'));
      return;
    }
    final ok = await c.services.shell.setHotkey(text);
    setState(() => _hotkeyError = ok ? null : tr('이 단축키를 등록할 수 없습니다 (다른 프로그램이 사용 중일 수 있음)'));
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
                Text(tr('환경 설정'), style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                const Spacer(),
                Text(tr('바꾸면 바로 저장됩니다'), style: TextStyle(fontSize: 12, color: JjColors.textDim)),
                const SizedBox(width: 8),
                AppActions(c: c, onSettingsPage: true),
              ]),
            ),
            // 묶음 바로가기 (누르면 그 묶음으로). 스크롤해도 위에 그대로
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
              child: _groupBar(desk),
            ),
            Expanded(
              // 모든 묶음을 한 번에 그린다 (ListView 는 화면 밖 묶음을 그리지 않아 바로가기로 갈 수 없었음)
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(24, 4, 24, 16),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  _group('general', Icons.tune, tr('일반'), [
                    // 화면 언어 (읽을 수 없는 언어를 골라도 바로 찾아 되돌릴 수 있게 맨 위)
                    const LanguageSettings(),
                    _appIconTile(c, desk),
                    if (c.services.updater != null) ...[
                      ListTile(
                        leading: const Icon(Icons.system_update_alt, color: JjColors.accent),
                        title: FutureBuilder<String>(
                          future: c.services.updater!.currentVersion(),
                          builder: (_, v) => Text('JJ_MKVMaker v${v.data ?? '…'}'),
                        ),
                        subtitle: Text(tr('GitHub 의 최신 버전과 비교해, 새 버전이 있으면 받아서 설치합니다')),
                        trailing: FilledButton.icon(
                          onPressed: () => checkForUpdate(context, c, manual: true),
                          icon: const Icon(Icons.refresh, size: 18),
                          label: Text(tr('최신 버전 확인')),
                        ),
                      ),
                      SwitchListTile(
                        value: s.autoCheckUpdates,
                        onChanged: (v) => c.updateSettings((x) => x.autoCheckUpdates = v),
                        title: Text(tr('시작할 때 새 버전 확인 (하루 한 번)')),
                      ),
                    ],
                    ListTile(
                      title: Text(tr('홈 화면')),
                      subtitle: Text(tr('프로그램을 켰을 때, 그리고 위쪽 왼쪽 JJ 아이콘을 눌렀을 때 보일 화면')),
                      trailing: DropdownButton<String>(
                        value: s.startScreen,
                        items: [
                          DropdownMenuItem(value: 'home', child: Text(tr('MKV 화면 (기본)'))),
                          DropdownMenuItem(value: 'browser', child: Text(tr('웹 브라우저 (홈 주소)'))),
                          DropdownMenuItem(value: 'files', child: Text(tr('파일 탐색기'))),
                        ],
                        onChanged: (v) => c.updateSettings((x) => x.startScreen = v!),
                      ),
                    ),
                  ]),
                  _group('display', Icons.aspect_ratio, tr('화면'), [
                    if (!desk)
                      ListTile(
                        title: Text(tr('화면 방향')),
                        subtitle: Text(tr('가로 고정 · 세로 고정, 또는 자동 (기기를 돌리는 대로, 기기의 자동 회전 설정을 따름)')),
                        trailing: DropdownButton<String>(
                          value: s.screenOrientation,
                          items: [
                            DropdownMenuItem(value: 'landscape', child: Text(tr('가로 고정 (기본)'))),
                            DropdownMenuItem(value: 'portrait', child: Text(tr('세로 고정'))),
                            DropdownMenuItem(value: 'auto', child: Text(tr('자동'))),
                          ],
                          onChanged: (v) {
                            c.updateSettings((x) => x.screenOrientation = v!);
                            applyScreenOrientation(v!);
                          },
                        ),
                      ),
                    ListTile(
                      title: Text(tr('기본 화면 크기')),
                      subtitle: Text(trf('글자 · 버튼 크기입니다. 위쪽 막대의 − · + 로 그때그때 바꿀 수 있고, 가운데 숫자를 누르면 이 크기로 돌아갑니다 ' '(지금 {0}%)', [(s.uiScale * 100).round()])),
                      trailing: DropdownButton<double>(
                        value: s.uiScaleDefault,
                        items: [
                          for (var v = AppSettings.uiScaleMin; v <= AppSettings.uiScaleMax + 0.001; v += 0.1)
                            DropdownMenuItem(
                                value: AppSettings.clampUiScale(v),
                                child: Text('${(v * 100).round()}%${(v - 1).abs() < 0.001 ? tr(' (보통)') : ''}')),
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
                  ]),
                  _group('mkv', Icons.movie_creation_outlined, tr('MKV 만들기'), [
                    ListTile(
                      title: Text(tr('동시 MKV 변환 수')),
                      subtitle: Text(tr('여러 동영상을 MKV 로 만들 때 동시에 처리할 개수 (재인코딩은 CPU 를 많이 씁니다)')),
                      trailing: CountSelector(
                        value: s.maxParallelJobs,
                        onChanged: (n) => c.updateSettings((x) => x.maxParallelJobs = n),
                      ),
                    ),
                    ListTile(
                      title: Text(tr('마지막 인코딩 설정을 기억합니다')),
                      subtitle: Text(trf('{0} · {1}' '{2}  (메인 화면 상단에서 변경)', [c.encode.resolution.label, c.encode.codec.label, c.encode.reencode ? ' · ${c.encode.quality.label}' : ''])),
                    ),
                    _folderTile(
                      title: tr('MKV · 자막 (jj_mkv)'),
                      value: s.mkvOutputRoot,
                      defaultText: tr('동영상이 있는 폴더 아래 jj_mkv (기본)'),
                      onPick: () async {
                        final d = await _pickDir(tr('MKV · 자막 저장 위치'), s.mkvOutputRoot);
                        if (d != null) await c.updateSettings((x) => x.mkvOutputRoot = d);
                      },
                      onReset: () => c.updateSettings((x) => x.mkvOutputRoot = null),
                    ),
                    _subTitle(tr('이동 버튼 (세부 정보 오른쪽 아래, 위로 하나씩)')),
                    for (var i = 0; i < s.moveTargets.length; i++) _moveTargetTile(i, s.moveTargets[i]),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                      child: Row(children: [
                        OutlinedButton.icon(
                          onPressed: () async {
                            final d = await _pickDir(tr('이동 버튼의 폴더'));
                            if (d == null) return;
                            final name = p.basename(d).isEmpty ? tr('이동') : p.basename(d);
                            await c.updateSettings((x) => x.moveTargets = [...x.moveTargets, MoveTarget(name, d)]);
                          },
                          icon: const Icon(Icons.add, size: 18),
                          label: Text(tr('이동 버튼 추가')),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            s.moveTargets.isEmpty
                                ? tr('없음: 세부 정보의 [이동] 을 처음 누를 때 폴더를 골라 하나 만듭니다')
                                : tr('표시 이름은 바로 고칠 수 있습니다. 동영상 줄을 세 번 누르면 첫 번째 버튼의 폴더로 옮깁니다'),
                            style: const TextStyle(fontSize: 12, color: JjColors.textDim),
                          ),
                        ),
                      ]),
                    ),
                  ]),
                  _group('subtitle', Icons.subtitles_outlined, tr('자막 (AI · 인터넷)'), [
                    SwitchListTile(
                      value: s.askAiOptions,
                      onChanged: (v) => c.updateSettings((x) => x.askAiOptions = v),
                      title: Text(tr('시작할 때마다 설정 창 보기')),
                      subtitle: Text(trf('끄면 마지막 설정으로 바로 시작: 원어 {0}, ' '언어 {1}, {2}', [c.aiOptions.source.name, c.aiOptions.targets.map((t) => t.code).join('/'), c.aiOptions.whisper.label])),
                    ),
                    _subTitle(tr('인터넷 자막 (OpenSubtitles.com)')),
                    _textTile(tr('API 키 (필수, 무료)'), s.openSubtitlesKey,
                        tr('가입 → 프로필 → API consumers → New consumer'),
                        (v) => c.updateSettings((x) => x.openSubtitlesKey = v.trim())),
                    _textTile(tr('아이디 (선택)'), s.openSubtitlesUser, tr('로그인하면 하루 받기 횟수가 늘어납니다'),
                        (v) => c.updateSettings((x) => x.openSubtitlesUser = v.trim())),
                    _textTile(tr('비밀번호 (선택)'), s.openSubtitlesPassword, trf('이 {0}의 설정 파일에 저장됩니다', [desk ? 'PC' : tr('기기')]),
                        (v) => c.updateSettings((x) => x.openSubtitlesPassword = v), obscure: true),
                  ]),
                  _group('play', Icons.play_circle_outline, tr('재생'), [
                    ListTile(
                      title: Text(tr('동영상 하나를 재생할 때')),
                      subtitle: Text(tr('시리즈: file_001 · file_002, S01E01 · S01E02 처럼 번호만 다른 파일')),
                      trailing: DropdownButton<PlaylistMode>(
                        value: s.playlistMode,
                        items: [
                          for (final m in PlaylistMode.values) DropdownMenuItem(value: m, child: Text(m.label)),
                        ],
                        onChanged: (m) => c.updateSettings((x) => x.playlistMode = m!),
                      ),
                    ),
                    ListTile(
                      title: Text(desk ? tr('탐색기에서 동영상을 열 때') : tr('다른 앱에서 동영상을 열 때')),
                      subtitle: Text(desk
                          ? tr('더블클릭 · 연결 프로그램으로 JJ_MKVMaker 를 골랐을 때 (오른쪽 클릭 메뉴는 그대로)')
                          : tr('파일 앱의 "다음으로 열기" · 공유에서 JJ_MKVMaker 를 골랐을 때')),
                      trailing: DropdownButton<String>(
                        value: s.openFileAction,
                        items: [
                          DropdownMenuItem(value: 'play', child: Text(tr('바로 재생 (기본)'))),
                          DropdownMenuItem(value: 'add', child: Text(tr('편집 목록에 추가 (MKV 만들기 대상)'))),
                        ],
                        onChanged: (v) => c.updateSettings((x) => x.openFileAction = v!),
                      ),
                    ),
                    if (desk) ...[
                    ListTile(
                      title: Text(tr('탐색기에서 연 동영상을 재생할 창')),
                      subtitle: Text(tr('프로그램이 이미 켜져 있을 때. 새 창은 재생만 하는 창이며 닫으면 그 창만 끝납니다')),
                      trailing: DropdownButton<String>(
                        value: s.openFileWindow,
                        items: [
                          DropdownMenuItem(value: 'same', child: Text(tr('켜져 있는 창에서 (기본)'))),
                          DropdownMenuItem(value: 'new', child: Text(tr('새 창에서'))),
                        ],
                        onChanged: (v) => c.updateSettings((x) => x.openFileWindow = v!),
                      ),
                    ),
                    _ExternalPlayers(c: c),
                    _ContextMenuTile(c: c),
                    ],
                  ]),
                  _group('browser', Icons.public, tr('웹 브라우저'), [
                    _textTile(tr('홈 주소'), s.homeUrl, tr('웹 브라우저의 시작 · 🏠 주소'),
                        (v) => c.updateSettings((x) => x.homeUrl = v.trim().isEmpty ? 'https://www.youtube.com/' : v.trim())),
                    SwitchListTile(
                      value: s.youtubeAdSkip,
                      onChanged: (v) => c.updateSettings((x) => x.youtubeAdSkip = v),
                      title: Text(tr('YouTube 광고 자동 건너뛰기')),
                      subtitle: Text(tr('앱 안 웹 브라우저: [건너뛰기] 를 대신 누르고, 건너뛸 수 없는 광고는 소리를 끄고 빨리 넘깁니다 ' '(넘기는 동안 화면 위쪽에 "광고 건너뛰는 중…")')),
                    ),
                    SwitchListTile(
                      value: s.youtubeAdHide,
                      onChanged: (v) => c.updateSettings((x) => x.youtubeAdHide = v),
                      title: Text(tr('YouTube 광고 배너 숨기기')),
                      subtitle: Text(tr('목록 · 영상 옆 · 영상 위에 나오는 광고 영역을 감춥니다')),
                    ),
                    SwitchListTile(
                      value: s.webTranslate,
                      onChanged: (v) => c.updateSettings((x) => x.webTranslate = v),
                      title: Text(tr('웹 페이지 자동 번역')),
                      subtitle: Text(trf(
                          '다른 언어로 된 페이지를 화면 언어 ({0}) 로 번역합니다. 페이지의 글을 Google 번역으로 보냅니다. '
                          '주소창 옆 번역 버튼으로 원문 · 번역을 바꿀 수 있습니다.',
                          [I18nController.nativeName(s.uiLanguage)])),
                    ),
                    SwitchListTile(
                      value: s.webJavaScript,
                      onChanged: (v) => c.updateSettings((x) => x.webJavaScript = v),
                      title: Text(tr('JavaScript 사용')),
                      subtitle: Text(desk
                          ? tr('끄면 페이지의 스크립트를 실행하지 않습니다 (광고 · 추적이 줄지만 YouTube 처럼 스크립트로 만든 사이트는 보이지 않음). '
                              'Chrome 엔진은 끄면 페이지 번역 · 동영상 찾기도 멈춥니다.')
                          : tr('끄면 페이지의 스크립트를 실행하지 않습니다 (광고 · 추적이 줄지만 YouTube 처럼 스크립트로 만든 사이트는 보이지 않음). '
                              '끄면 페이지 번역 · 동영상 찾기도 멈춥니다.')),
                    ),
                    if (desk) ...[
                    ListTile(
                      title: Text(tr('브라우저 엔진 (앱 안)')),
                      subtitle: Text(
                          trf('Edge: Windows 에 들어 있어 따로 설치하지 않습니다. 여기서 YouTube 에 로그인하면 다운로드에도 그 로그인이 쓰입니다.\n' 'Chrome: 고르면 약 {0}MB 를 내려받고 다시 시작한 뒤 쓸 수 있습니다 ' '(Google 로그인은 막힐 수 있음).' '{1}' '{2}', [CefRuntime.approxDownloadMb, CefRuntime.installed ? trf(' 지금 설치됨 ({0}MB)', [CefRuntime.installedMb()]) : '', s.browserEngine == 'chrome' && !CefRuntime.readyThisRun ? tr(' · 다시 시작해야 Chrome 으로 바뀝니다') : ''])),
                      isThreeLine: true,
                      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                        if (s.browserEngine == 'edge' && CefRuntime.installed && !CefRuntime.readyThisRun)
                          IconButton(
                            tooltip: tr('내려받은 Chrome 엔진 지우기'),
                            icon: const Icon(Icons.delete_outline, color: JjColors.textDim),
                            onPressed: () async {
                              final ok = await CefRuntime.uninstall();
                              c.note(ok ? tr('내장 Chrome 엔진을 지웠습니다.') : tr('내장 Chrome 엔진을 지우지 못했습니다 (사용 중).'));
                              setState(() {});
                            },
                          ),
                        DropdownButton<String>(
                          value: s.browserEngine,
                          items: [
                            DropdownMenuItem(value: 'edge', child: Text(tr('Edge (내장)'))),
                            DropdownMenuItem(
                                value: 'chrome',
                                child: Text(CefRuntime.installed ? tr('Chrome (내장)') : tr('Chrome (내려받기)'))),
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
                      title: Text(tr('외부 브라우저')),
                      subtitle: Text(tr('"외부 브라우저로 열기" 에 쓸 브라우저 (이 PC 에 설치된 것)')),
                      trailing: DropdownButton<String>(
                        value: s.externalBrowser,
                        items: [
                          DropdownMenuItem(value: 'system', child: Text(tr('Windows 기본 브라우저'))),
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
                  ]),
                  _group('files', Icons.folder_copy_outlined, tr('파일 탐색기'), [
                    ListTile(
                      title: Text(tr('누르기')),
                      subtitle: Text(tr('길게 누르기 · 오른쪽 클릭은 늘 기능 메뉴 (복사 · 이동 · 삭제 · 이름 변경 …). '
                          'Ctrl + 클릭: 여러 개 고르기')),
                      trailing: DropdownButton<String>(
                        value: s.explorerClick,
                        items: [
                          DropdownMenuItem(value: 'select', child: Text(tr('한 번: 선택 · 두 번: 실행 (기본)'))),
                          DropdownMenuItem(value: 'open', child: Text(tr('한 번: 바로 실행'))),
                        ],
                        onChanged: (v) => c.updateSettings((x) => x.explorerClick = v!),
                      ),
                    ),
                    ListTile(
                      title: Text(tr('스타일')),
                      subtitle: Text(tr('아이콘 · 목록 모양: X-plore (썸네일 · 두 줄) · Windows 탐색기 (컬러 아이콘 · 열) · '
                          'Total Commander (촘촘한 목록 · [폴더])')),
                      trailing: DropdownButton<String>(
                        value: s.explorerStyle,
                        items: [
                          for (final st in ExplorerStyle.values)
                            DropdownMenuItem(value: st.name, child: Text(tr(st.label))),
                        ],
                        onChanged: (v) => c.updateSettings((x) => x.explorerStyle = v!),
                      ),
                    ),
                    ListTile(
                      title: Text(tr('창 배치')),
                      subtitle: Text(tr('파일 탐색기 위쪽 ⋮ 메뉴에서도 바꿀 수 있습니다 (좌우 · 위아래 · 버튼 줄 위치 · 버튼 구성)')),
                      trailing: DropdownButton<String>(
                        value: s.explorerLayout,
                        items: [
                          DropdownMenuItem(value: 'dual', child: Text(tr('두 창'))),
                          DropdownMenuItem(value: 'split', child: Text(tr('폴더 + 파일 목록'))),
                          DropdownMenuItem(value: 'single', child: Text(tr('한 창'))),
                        ],
                        onChanged: (v) => c.updateSettings((x) => x.explorerLayout = v!),
                      ),
                    ),
                  ]),
                  _group('download', Icons.download_outlined, tr('다운로드'), [
                    if (desk)
                    SwitchListTile(
                      value: s.clipboardWatch,
                      onChanged: (v) => c.updateSettings((x) => x.clipboardWatch = v),
                      title: Text(tr('복사(Ctrl+C)한 주소 자동 다운로드')),
                      subtitle: Text(tr('YouTube → yt-dlp, 마그넷 · .torrent → aria2 (완료 후 올려 주기 안 함)')),
                    ),
                    SwitchListTile(
                      value: s.addFinishedDownloads,
                      onChanged: (v) => c.updateSettings((x) => x.addFinishedDownloads = v),
                      title: Text(tr('완료시 자동 동영상추가')),
                      subtitle: Text(tr('다 받는 대로 MKV 만들기의 동영상 목록에 넣고, 다운로드 목록에서는 뺍니다 (다운로드 화면의 체크 상자와 같음)')),
                    ),
                    ListTile(
                      title: Text(tr('YouTube 받을 형식')),
                      subtitle: Text(tr('기본: MP4. 음성만 받으면 MP3 · M4A 로 저장')),
                      trailing: DropdownButton<YtContainer>(
                        value: s.ytContainer,
                        items: [for (final v in YtContainer.values) DropdownMenuItem(value: v, child: Text(v.label))],
                        onChanged: (v) => c.updateSettings((x) => x.ytContainer = v!),
                      ),
                    ),
                    ListTile(
                      enabled: !s.ytContainer.audioOnly,
                      title: Text(tr('YouTube 화질')),
                      subtitle: Text(tr('고른 크기 이하에서 가장 좋은 화질 (영상에 없는 크기면 가까운 것)')),
                      trailing: DropdownButton<YtQuality>(
                        value: s.ytQuality,
                        items: [for (final v in YtQuality.values) DropdownMenuItem(value: v, child: Text(v.label))],
                        onChanged: s.ytContainer.audioOnly ? null : (v) => c.updateSettings((x) => x.ytQuality = v!),
                      ),
                    ),
                    SwitchListTile(
                      value: s.ytExpandPlaylists,
                      onChanged: (v) => c.updateSettings((x) => x.ytExpandPlaylists = v),
                      title: Text(tr('재생목록 주소면 목록 전체 받기')),
                      subtitle: Text(tr('영상마다 한 줄씩 보여 주고 jj_yt-dlp\\재생목록 이름\\ 에 저장 (믹스 목록 제외)')),
                    ),
                    ListTile(
                      title: Text(tr('YouTube 쿠키 (로봇 확인이 나올 때)')),
                      subtitle: Text(s.ytCookiesFile.isNotEmpty
                          ? 'cookies.txt: ${s.ytCookiesFile}'
                          : s.ytCookiesBrowser == internalBrowserCookies
                              ? tr('앱 안 브라우저의 로그인 사용 (브라우저 화면에서 YouTube 에 로그인하세요)')
                              : s.ytCookiesBrowser.isNotEmpty
                                  ? trf('{0} 브라우저의 YouTube 로그인 쿠키 사용 (Chrome · Edge 는 브라우저를 닫아야 읽힐 수 있음)', [s.ytCookiesBrowser])
                                  : tr('사용 안 함. "Sign in to confirm you\'re not a bot" 오류가 나오면 설정하세요')),
                      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                        DropdownButton<String>(
                          value: s.ytCookiesFile.isNotEmpty ? '*file' : s.ytCookiesBrowser,
                          items: [
                            DropdownMenuItem(value: '', child: Text(tr('사용 안 함'))),
                            DropdownMenuItem(value: internalBrowserCookies, child: Text(tr('앱 안 브라우저 (권장)'))),
                            // PC 브라우저의 쿠키는 Windows 에서만
                            if (desk)
                              for (final b in const ['firefox', 'chrome', 'edge', 'brave', 'whale', 'opera'])
                                DropdownMenuItem(value: b, child: Text(b[0].toUpperCase() + b.substring(1))),
                            DropdownMenuItem(value: '*file', child: Text(tr('cookies.txt 파일…'))),
                          ],
                          onChanged: (v) async {
                            if (v == '*file') {
                              final f = await FilePicker.pickFile(
                                  dialogTitle: tr('cookies.txt (Netscape 형식)'),
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
                      title: Text(tr('동시 다운로드 수')),
                      subtitle: Text(tr('나머지는 대기했다가 차례로 받습니다')),
                      trailing: CountSelector(
                        value: s.maxParallelDownloads,
                        onChanged: (n) => c.updateSettings((x) => x.maxParallelDownloads = n),
                      ),
                    ),
                    _folderTile(
                      title: tr('다운로드 (jj_yt-dlp · jj_aria2)'),
                      value: s.downloadRoot,
                      defaultText: trf('{0} (기본): {1}', [desk ? tr('프로그램 폴더') : tr('내장 저장소'), s.resolvedDownloadRoot()]),
                      onPick: () async {
                        final d = await _pickDir(tr('다운로드 위치'), s.resolvedDownloadRoot());
                        if (d != null) await c.updateSettings((x) => x.downloadRoot = d);
                      },
                      onReset: () => c.updateSettings((x) => x.downloadRoot = null),
                    ),
                  ]),
                  if (desk)
                  _group('run', Icons.power_settings_new, tr('실행 · 종료'), [
                    ListTile(
                      title: Text(tr('종료 (창 닫기 ✕ · 종료 버튼) 를 누르면')),
                      subtitle: Text(trf('백그라운드: 창만 숨기고 다운로드 · 변환은 계속합니다. {0} 또는 트레이 아이콘으로 다시 엽니다.\n' '완전히 끝내려면 트레이 아이콘 오른쪽 클릭 > 종료 (어느 설정이든 항상 종료)', [s.showHotkey])),
                      isThreeLine: true,
                      trailing: DropdownButton<String>(
                        value: s.closeAction,
                        items: [
                          DropdownMenuItem(value: 'background', child: Text(tr('백그라운드로 계속 (기본)'))),
                          DropdownMenuItem(value: 'quit', child: Text(tr('다운로드 · 변환도 모두 종료 (묻지 않음)'))),
                          DropdownMenuItem(value: 'ask', child: Text(tr('매번 고르기'))),
                        ],
                        onChanged: (v) => c.updateSettings((x) => x.closeAction = v!),
                      ),
                    ),
                    SwitchListTile(
                      value: s.minimizeToTray,
                      onChanged: (v) => c.updateSettings((x) => x.minimizeToTray = v),
                      title: Text(tr('최소화하면 트레이로 (백그라운드 실행)')),
                      subtitle: Text(tr('트레이 아이콘을 누르거나 아래 단축키로 다시 엽니다')),
                    ),
                    ListTile(
                      title: Text(tr('창 보이기 / 숨기기 단축키')),
                      subtitle: _hotkeyError == null
                          ? Text(tr('어디서나 누르면 JJ_MKVMaker 창이 나타납니다'))
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
                          OutlinedButton(onPressed: _applyHotkey, child: Text(tr('적용'))),
                        ]),
                      ),
                    ),
                  ]),
                  _group('cleanup', Icons.cleaning_services_outlined, tr('저장 공간 정리'), [
                    ListTile(
                      title: Text(tr('임시 파일 · 남은 조각 정리')),
                      subtitle: Text(tr('작업하다 남은 임시 파일 · 받다 만 다운로드 (.part 등) · 받다 만 AI 모델 · '
                          '업데이트하고 남은 파일 · 지난 작업 기록을 찾아 지웁니다. '
                          '받은 동영상 · 만든 MKV · 자막은 지우지 않고, 진행 중인 작업 · 다운로드가 쓰는 것은 건너뜁니다')),
                      isThreeLine: true,
                      trailing: FilledButton.icon(
                        onPressed: () => showCleanup(context, c, AppScope.maybeOf(context)?.downloads),
                        icon: const Icon(Icons.cleaning_services_outlined, size: 18),
                        label: Text(tr('정리…')),
                      ),
                    ),
                  ]),
                  _group('about', Icons.info_outline, tr('프로그램 정보'), [
                    if (desk) ...[
                    ListTile(
                      title: Text(tr('필수 프로그램 점검')),
                      subtitle: Text(tr('FFmpeg · yt-dlp · aria2 · Deno 가 없으면 내려받아 설치합니다')),
                      trailing: OutlinedButton(
                        onPressed: () => checkRequiredTools(context, c.services.shell, quietIfOk: false),
                        child: Text(tr('점검')),
                      ),
                    ),
                    ],
                    ListTile(
                      title: Text(tr('오픈 소스 라이선스')),
                      subtitle: Text(tr('포함된 구성 요소와 라이선스 (THIRD_PARTY_NOTICES.txt)')),
                      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                        if (desk) OutlinedButton(
                          onPressed: () => c.services.shell.openExternal('system', [
                            '${File(Platform.resolvedExecutable).parent.path}\\THIRD_PARTY_NOTICES.txt',
                          ]),
                          child: Text(tr('고지 문서')),
                        ),
                        if (desk) const SizedBox(width: 6),
                        OutlinedButton(
                          onPressed: () => showLicensePage(context: context, applicationName: 'JJ_MKVMaker'),
                          child: Text(tr('패키지 라이선스')),
                        ),
                      ]),
                    ),
                  ]),
                ]),
              ),
            ),
          ]),
        );
      },
    );
  }

  /// 이동 버튼 하나: 표시 이름 (바로 고침) · 폴더 · 순서 올리기 · 폴더 바꾸기 · 지우기
  Widget _moveTargetTile(int i, MoveTarget t) {
    final s = c.settings;
    void update(List<MoveTarget> Function(List<MoveTarget>) f) =>
        c.updateSettings((x) => x.moveTargets = f([...x.moveTargets]));
    return ListTile(
      key: ValueKey('move_${i}_${t.dir}'),
      leading: const Icon(Icons.drive_file_move_outline, color: JjColors.accent),
      title: TextFormField(
        initialValue: t.name,
        decoration: InputDecoration(isDense: true, labelText: tr('표시 이름')),
        onChanged: (v) => update((l) => l..[i] = t.copyWith(name: v.trim().isEmpty ? tr('이동') : v.trim())),
      ),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Text(t.dir, maxLines: 2, overflow: TextOverflow.ellipsis),
      ),
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        IconButton(
          tooltip: tr('위로'),
          icon: const Icon(Icons.arrow_upward, size: 18),
          onPressed: i == 0 ? null : () => update((l) => l..insert(i - 1, l.removeAt(i))),
        ),
        OutlinedButton(
          onPressed: () async {
            final d = await _pickDir(tr('이동 버튼의 폴더'), t.dir);
            if (d != null) update((l) => l..[i] = t.copyWith(dir: d));
          },
          child: Text(tr('폴더 선택')),
        ),
        IconButton(
          tooltip: tr('이 이동 버튼 지우기'),
          icon: const Icon(Icons.delete_outline),
          onPressed: s.moveTargets.length > i ? () => update((l) => l..removeAt(i)) : null,
        ),
      ]),
    );
  }

  /// 묶음 이름 → 위치 (바로가기 버튼으로 그 묶음까지 스크롤)
  final _groupKeys = <String, GlobalKey>{};

  static const _groupIds = [
    'general', 'display', 'mkv', 'subtitle', 'play', 'browser', 'files', 'download', 'run', 'cleanup', 'about', //
  ];

  String _groupTitle(String id) => switch (id) {
        'general' => tr('일반'),
        'display' => tr('화면'),
        'mkv' => tr('MKV 만들기'),
        'subtitle' => tr('자막 (AI · 인터넷)'),
        'play' => tr('재생'),
        'browser' => tr('웹 브라우저'),
        'files' => tr('파일 탐색기'),
        'download' => tr('다운로드'),
        'run' => tr('실행 · 종료'),
        'cleanup' => tr('저장 공간 정리'),
        _ => tr('프로그램 정보'),
      };

  /// 맨 위 바로가기: 묶음 이름을 누르면 그 묶음으로 스크롤
  Widget _groupBar(bool desk) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Wrap(spacing: 8, runSpacing: 8, children: [
          for (final id in _groupIds)
            if (id != 'run' || desk)
              ActionChip(
                label: Text(_groupTitle(id), style: const TextStyle(fontSize: 13)),
                onPressed: () {
                  final ctx = _groupKeys[id]?.currentContext;
                  if (ctx != null) {
                    // 그 묶음의 제목이 맨 위에 오게
                    Scrollable.ensureVisible(ctx,
                        alignment: 0, duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
                  }
                },
              ),
        ]),
      );

  /// 묶음 하나: 제목 (아이콘) 과 항목들을 한 카드에
  Widget _group(String id, IconData icon, String title, List<Widget> children) => Card(
        key: _groupKeys.putIfAbsent(id, GlobalKey.new),
        margin: const EdgeInsets.only(bottom: 16),
        color: JjColors.panel,
        clipBehavior: Clip.antiAlias,
        child: Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Container(
              color: JjColors.panelHigh,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Row(children: [
                Icon(icon, size: 20, color: JjColors.accent),
                const SizedBox(width: 10),
                Text(title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
              ]),
            ),
            ...children,
          ]),
        ),
      );

  /// 묶음 안의 작은 제목
  /// 앱 아이콘 고르기: 그림을 누르면 바로 바뀐다
  Widget _appIconTile(AppController c, bool desk) {
    final now = appIconOf(c.settings.appIcon);
    return ListTile(
      title: Text(tr('앱 아이콘')),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(desk
              ? tr('창 · 작업 표시줄 · 트레이와 앱 안 왼쪽 위 버튼의 아이콘입니다 (실행 파일 · 바탕 화면 바로 가기 아이콘은 그대로)')
              : tr('앱 목록 · 홈 화면과 앱 안 왼쪽 위 버튼의 아이콘입니다. 바꾸면 홈 화면에 둔 아이콘이 없어질 수 있어 앱 목록에서 다시 끌어다 놓아야 할 수 있습니다')),
          const SizedBox(height: 8),
          Wrap(spacing: 10, runSpacing: 10, children: [
            for (final id in appIconIds)
              Tooltip(
                message: id == appIconIds.first ? '${_appIconName(id)} (${tr('기본')})' : _appIconName(id),
                child: InkWell(
                  borderRadius: BorderRadius.circular(14),
                  onTap: id == now
                      ? null
                      : () {
                          c.updateSettings((x) => x.appIcon = id);
                          c.services.shell.setAppIcon(id);
                        },
                  child: Container(
                    padding: const EdgeInsets.all(4),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: id == now ? JjColors.accent : Colors.transparent, width: 3),
                    ),
                    child: Image.asset(appIconPreviewAsset(id), width: 56, height: 56, filterQuality: FilterQuality.medium),
                  ),
                ),
              ),
          ]),
        ]),
      ),
    );
  }

  static String _appIconName(String id) => switch (id) {
        'yellow' => tr('노랑'),
        'black' => tr('검정'),
        'film_jj' => tr('필름 + JJ'),
        'film' => tr('필름'),
        _ => tr('처음 아이콘 (파랑)'),
      };

  Widget _subTitle(String t) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
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
          OutlinedButton(onPressed: onPick, child: Text(tr('폴더 선택'))),
          if (value != null) ...[
            const SizedBox(width: 6),
            TextButton(onPressed: onReset, child: Text(tr('기본값'))),
          ],
        ]),
      );
}
