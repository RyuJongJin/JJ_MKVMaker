import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app/app_controller.dart';
import '../app/live_sync.dart';
import '../app/settings.dart';
import '../core/file_ops.dart' show isSameOrInside;
import '../core/sync_tools.dart';
import '../core/vfs.dart' show vDisplay;
import '../l10n/tr.dart';
import '../platform/windows/rsync_installer.dart';
import 'confirm.dart';
import 'folder_picker.dart';
import 'path_label.dart';
import 'rsync_setup.dart';
import 'schedule_editor.dart';
import 'theme.dart';
import 'setting_tile.dart';

/// 환경 설정의 복사 · 동기화 부분.
/// - 파일 탐색기 ([rsync] false): 파일 / 폴더 복사 방법 (현재 방식 · robocopy), robocopy 옵션, 속도 제한
/// - Rsync ([rsync] true): rsync 옵션, rsync 가져오기, 실시간 동기화 (lsync) · 백그라운드로 실행
class CopySyncSettings extends StatefulWidget {
  final AppController c;
  final bool rsync;
  const CopySyncSettings({super.key, required this.c, this.rsync = false});

  @override
  State<CopySyncSettings> createState() => _CopySyncSettingsState();
}

class _CopySyncSettingsState extends State<CopySyncSettings> {
  AppController get c => widget.c;
  String? _rsync; // 쓸 수 있는 rsync 경로
  bool _checking = true;

  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    final r = await rsyncExecutable(c.settings);
    if (mounted) {
      setState(() {
        _rsync = r;
        _checking = false;
      });
    }
  }

  /// 파일 탐색기의 방법 (rsync 는 Rsync 화면에서)
  List<DropdownMenuItem<String>> _methods() => [
        for (final m in CopyMethod.values)
          if (m != CopyMethod.rsync && copyMethodAvailable(m, c.settings))
            DropdownMenuItem(value: m.name, child: Text(tr(m.label))),
      ];

  String _valid(String v) => v == 'robocopy' && Platform.isWindows ? v : 'builtin';

  /// 옵션 입력칸 (바꾸면 바로 저장, ↺ 로 기본값)
  Widget _options(String title, String hint, String value, String def, void Function(AppSettings, String) set) => SettingTile(
        title: Text(title),
        subtitle: Text(hint),
        trailing: SizedBox(
          width: 380,
          child: TextFormField(
            key: ValueKey('$title|$value' == '$title|$def' ? '$title-def' : title),
            initialValue: value,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
            decoration: InputDecoration(
              isDense: true,
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(
                tooltip: trf('기본값으로 ({0})', [def]),
                icon: const Icon(Icons.restart_alt, size: 18),
                onPressed: () async {
                  await c.updateSettings((x) => set(x, def));
                  setState(() {});
                },
              ),
            ),
            onTapOutside: (_) => FocusManager.instance.primaryFocus?.unfocus(),
            onChanged: (v) => c.updateSettings((x) => set(x, v.trim())),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) => widget.rsync ? _rsyncPart() : _explorerPart();

  /// 파일 탐색기: 복사 · 이동 방법 (현재 방식 · robocopy) · 옵션 · 속도 제한
  Widget _explorerPart() {
    final s = c.settings;
    final desk = Platform.isWindows;
    return Column(children: [
      const Divider(height: 1),
      if (desk) ...[
        SettingTile(
          title: Text(tr('파일 복사 · 이동 방법')),
          subtitle: Text(tr('파일만 골랐을 때')),
          trailing: DropdownButton<String>(
            value: _valid(s.copyMethodFile),
            items: _methods(),
            onChanged: (v) => c.updateSettings((x) => x.copyMethodFile = v!),
          ),
        ),
        SettingTile(
          title: Text(tr('폴더 복사 · 이동 방법')),
          subtitle: Text(tr('폴더가 들어 있을 때')),
          trailing: DropdownButton<String>(
            value: _valid(s.copyMethodFolder),
            items: _methods(),
            onChanged: (v) => c.updateSettings((x) => x.copyMethodFolder = v!),
          ),
        ),
        _options(tr('robocopy 옵션'), tr('예: /E /COPY:DAT /DCOPY:T /R:2 /W:2. 이동은 /MOVE 를 자동으로 붙임'), s.robocopyOptions,
            defaultRobocopyOptions, (x, v) => x.robocopyOptions = v),
      ],
      SettingTile(
        title: Text(tr('속도 제한 (KB/s)')),
        subtitle: Text(tr('0 = 제한 없음. 모든 방법에 적용: rsync --bwlimit, 현재 방식은 앱이 조절, robocopy 는 /IPG 로 비슷하게. '
            '옵션 칸에 직접 넣어도 됩니다 (그쪽이 우선)')),
        trailing: SizedBox(
          width: 140,
          child: TextFormField(
            initialValue: '${s.copyBandwidthKBps}',
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: const InputDecoration(isDense: true, border: OutlineInputBorder(), suffixText: 'KB/s'),
            onTapOutside: (_) => FocusManager.instance.primaryFocus?.unfocus(),
            onChanged: (v) => c.updateSettings((x) => x.copyBandwidthKBps = int.tryParse(v) ?? 0),
          ),
        ),
      ),
    ]);
  }

  /// Rsync 화면: rsync 옵션 · rsync 가져오기 · 실시간 동기화 (lsync)
  Widget _rsyncPart() {
    final s = c.settings;
    final desk = Platform.isWindows;
    return Column(children: [
      // 111: 이미 실행한 쌍은 기억한 옵션을 쓴다는 것을 알린다
      _options(tr('rsync 옵션'), tr('예: -avPog (보관 · 자세히 · 진행 · 소유자 · 그룹). 속도 제한은 파일 탐색기의 속도 제한을 함께 씀. '
              '새로 맞추는 폴더 쌍에 씁니다 - 이미 실행한 쌍은 기억한 옵션을 쓰며 모니터링 > 복사 · rsync 에서 따로 고칩니다'),
          s.rsyncOptions, defaultRsyncOptions, (x, v) => x.rsyncOptions = v),
      SettingTile(
        title: Text(tr('rsync 가져오기')),
        subtitle: Text(_checking
            ? tr('확인 중…')
            : _rsync != null
                ? trf('사용: {0}', [_rsync!])
                : s.rsyncSource == 'download'
                    ? (desk
                        ? tr('이 설치본에는 rsync 가 들어 있지 않습니다 (rsync 로 복사할 때 · 오른쪽 [내려받기] 로 받습니다)')
                        : tr('이 설치본에는 rsync 가 들어 있지 않습니다. 직접 지정하세요.'))
                    : tr('지정한 파일이 없습니다')),
        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
          // 내려받기 · 내려받은 것 지우기 (앱에 들어 있는 것을 쓰면 보이지 않음)
          if (desk && s.rsyncSource == 'download' && !_checking && (_rsync == null || _rsync != bundledRsync))
            _rsync == null
                ? TextButton(
                    onPressed: () async {
                      await installRsyncWithDialog(context);
                      await _check();
                    },
                    child: Text(tr('내려받기')),
                  )
                : IconButton(
                    tooltip: tr('내려받은 rsync 지우기'),
                    icon: const Icon(Icons.delete_outline, color: JjColors.textDim),
                    onPressed: () async {
                      await RsyncInstaller.uninstall();
                      await _check();
                    },
                  ),
          const SizedBox(width: 8),
          DropdownButton<String>(
            value: s.rsyncSource,
            items: [
              DropdownMenuItem(value: 'download', child: Text(tr('앱에 들어 있는 것 (기본)'))),
              DropdownMenuItem(value: 'custom', child: Text(tr('직접 지정'))),
            ],
            onChanged: (v) async {
              await c.updateSettings((x) => x.rsyncSource = v!);
              await _check();
            },
          ),
        ]),
      ),
      if (s.rsyncSource == 'custom')
        SettingTile(
          title: Text(tr('rsync 실행 파일')),
          subtitle: Text(s.rsyncPath.isEmpty ? tr('고르지 않음') : s.rsyncPath),
          trailing: TextButton(
            onPressed: () async {
              final r = await FilePicker.pickFiles(dialogTitle: tr('rsync 실행 파일'));
              final path = r.isEmpty ? null : r.single.path;
              if (path == null) return;
              await c.updateSettings((x) => x.rsyncPath = path);
              await _check();
            },
            child: Text(tr('고르기')),
          ),
        ),
      _LiveSyncTile(c: c),
    ]);
  }
}

/// 실시간 동기화 쌍 추가 (원본 · 대상 폴더 고르기 → 방법 · 지우기 · 일정)
Future<void> addLiveSyncPairDialog(BuildContext context, AppController c) => _LiveSyncTile._add(context, c);

/// 실시간 동기화 쌍 고치기 (원본 · 대상 · 방법 · 지우기 · 일정) - 모니터링 카드 · 환경 설정 (69)
Future<void> editLiveSyncPairDialog(BuildContext context, AppController c, LiveSyncPair old) =>
    _LiveSyncTile._edit(context, c, old: old);

/// 실시간 동기화 쌍 지우기 - 확인 뒤 (46). 폴더 · 파일은 그대로
Future<void> removeLiveSyncPair(BuildContext context, AppController c, LiveSyncPair x) async {
  final ok = await confirmAction(
    context,
    title: tr('실시간 동기화를 지울까요?'),
    body: '${shortPath(x.source)}\n→ ${shortPath(x.target)}\n\n${tr('동기화 설정만 지웁니다. 폴더 · 파일은 그대로 둡니다.')}',
    ok: tr('지우기'),
  );
  if (!ok) return;
  await c.updateSettings((y) => y.liveSyncPairs = [
        for (final o in y.liveSyncPairs) if (!(o.source == x.source && o.target == x.target)) o,
      ]);
}

/// 실시간 동기화 (lsyncd 처럼): 폴더 쌍 목록 · 추가 · 켜기 / 끄기 · 일정 · 지금 맞추기 · 지우기
class _LiveSyncTile extends StatelessWidget {
  final AppController c;
  const _LiveSyncTile({required this.c});

  static Future<void> _add(BuildContext context, AppController c) => _edit(context, c);

  /// 추가 ([old] 없음: 원본 · 대상을 먼저 고른다) · 고치기 ([old])
  static Future<void> _edit(BuildContext context, AppController c, {LiveSyncPair? old}) async {
    var src = old?.source ?? await pickFolderOrDav(context, tr('실시간 동기화: 원본 폴더'));
    if (src == null || !context.mounted) return;
    var dst = old?.target ?? await pickFolderOrDav(context, tr('실시간 동기화: 대상 폴더'));
    if (dst == null || !context.mounted) return;
    var method = old?.method ?? (copyMethodAvailable(CopyMethod.rsync, c.settings) ? 'rsync' : 'builtin');
    var delete = old?.delete ?? false;
    var schedule = old?.schedule ?? <String>[];
    // 경로 줄: 짧게 (끝 폴더가 보이게 - 67) + 전체 경로는 작게, 고치기면 [바꾸기]
    Widget pathRow(BuildContext ctx, String label, String path, void Function(String) onPick) => Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('$label  ${shortPath(path)}', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                Text(vDisplay(path), style: const TextStyle(fontSize: 11, color: JjColors.textDim)),
              ]),
            ),
            TextButton(
              onPressed: () async {
                final r = await pickFolderOrDav(ctx, label);
                if (r != null) onPick(r);
              },
              child: Text(tr('바꾸기')),
            ),
          ]),
        );
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => AlertDialog(
        scrollable: true,
          title: Text(old == null ? tr('실시간 동기화 추가') : tr('실시간 동기화 고치기')),
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            pathRow(ctx, tr('원본'), src!, (v) => set(() => src = v)),
            pathRow(ctx, tr('대상'), dst!, (v) => set(() => dst = v)),
            // 34: 안쪽 → 바깥은 지우기 없이만, 바깥 → 안쪽은 안 됨 (끝없이 돎)
            if (LiveSync.nestingProblem(LiveSyncPair(src!, dst!, delete: delete), allowInnerToOuter: c.settings.allowInnerToOuter)
                case final nest?)
              Text(nest, style: const TextStyle(fontSize: 12, color: Colors.redAccent))
            else if (isSameOrInside(src!, dst!))
              Text(tr('원본이 대상 폴더 안에 있습니다: 원본의 내용이 대상 폴더 바로 아래에 복사됩니다 (지우기는 쓸 수 없음).'),
                  style: const TextStyle(fontSize: 12, color: Colors.orangeAccent)),
            const SizedBox(height: 12),
            Wrap(spacing: 6, children: [
              for (final m in CopyMethod.values)
                if (copyMethodAvailable(m, c.settings))
                  ChoiceChip(label: Text(tr(m.label)), selected: method == m.name, onSelected: (_) => set(() => method = m.name)),
            ]),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: delete,
              onChanged: (v) => set(() => delete = v ?? false),
              title: Text(tr('원본에 없는 것을 대상에서 지우기')),
              subtitle: Text(tr('rsync --delete · robocopy /PURGE. 끄면 대상에 더하기 · 바꾸기만')),
            ),
            SettingTile(
              contentPadding: EdgeInsets.zero,
              leading: WeekGridPreview(lines: schedule, width: 96),
              title: Text(scheduleSummary(schedule)),
              subtitle: Text(tr('동기화 시간 (계속 / 시간 지정)')),
              trailing: TextButton(
                onPressed: () async {
                  final r = await editSchedule(ctx, schedule);
                  if (r != null) set(() => schedule = r);
                },
                child: Text(tr('바꾸기')),
              ),
            ),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('취소'))),
            FilledButton(
              onPressed: LiveSync.nestingProblem(LiveSyncPair(src!, dst!, delete: delete), allowInnerToOuter: c.settings.allowInnerToOuter) !=
                      null
                  ? null
                  : () => Navigator.pop(ctx, true),
              child: Text(old == null ? tr('추가') : tr('저장')),
            ),
          ],
        ),
      ),
    );
    if (ok != true) return;
    if (old == null) {
      await c.updateSettings((x) =>
          x.liveSyncPairs = [...x.liveSyncPairs, LiveSyncPair(src!, dst!, method: method, delete: delete, schedule: schedule)]);
      return;
    }
    // 원본 · 대상이 바뀌면 새 쌍 (지우기 확인도 새로 - 42), 아니면 방법 · 지우기 · 일정만
    final same = src == old.source && dst == old.target;
    final now = same
        ? old.copyWith(method: method, delete: delete, schedule: schedule)
        : LiveSyncPair(src!, dst!, method: method, delete: delete, schedule: schedule, enabled: old.enabled);
    await c.updateSettings((x) => x.liveSyncPairs = [
          for (final o in x.liveSyncPairs) o.source == old.source && o.target == old.target ? now : o,
        ]);
  }

  @override
  Widget build(BuildContext context) {
    final live = LiveSync.instance;
    final pairs = c.settings.liveSyncPairs;
    Widget body() => Column(children: [
          SettingTile(
            title: Text(tr('실시간 동기화 (lsyncd 처럼)')),
            subtitle: Text(Platform.isWindows
                ? tr('원본 폴더가 바뀌면 곧바로 대상 폴더에 맞춥니다 (앱이 켜져 있는 동안). 시작할 때 한 번 맞춥니다.')
                : trf('{0}초마다 원본 폴더를 살펴 대상 폴더에 맞춥니다 (앱이 켜져 있는 동안).', [c.settings.liveSyncIntervalSec])),
            trailing: TextButton.icon(
              onPressed: () => _add(context, c),
              icon: const Icon(Icons.add, size: 18),
              label: Text(tr('추가')),
            ),
          ),
          Padding(padding: const EdgeInsets.only(left: 16), child: LiveSyncRunOptions(c: c)),
          // 17: 살펴보는 간격 (Android 와 WebDAV 원본은 폴더 감시가 안 되어 이 간격마다 살핀다. 기본 30초)
          Padding(
            padding: const EdgeInsets.only(left: 16),
            child: SettingTile(
              dense: true,
              title: Text(tr('바뀐 것을 살펴보는 간격')),
              subtitle: Text(Platform.isWindows
                  ? tr('WebDAV 원본에 씁니다 (PC 의 폴더는 바뀌면 바로 맞춤). 짧을수록 빨리 맞추지만 서버 · 배터리를 더 씁니다.')
                  : tr('짧을수록 빨리 맞추지만 배터리를 더 씁니다.')),
              trailing: DropdownButton<int>(
                value: c.settings.liveSyncIntervalSec,
                items: [
                  for (final v in {5, 10, 15, 30, 60, 120, 300, 600, 1800, 3600, c.settings.liveSyncIntervalSec}.toList()..sort())
                    DropdownMenuItem(value: v, child: Text(v < 60 ? trf('{0}초', [v]) : trf('{0}분', [v ~/ 60]))),
                ],
                onChanged: (v) {
                  if (v != null) c.updateSettings((x) => x.liveSyncIntervalSec = v);
                },
              ),
            ),
          ),
          for (var i = 0; i < pairs.length; i++)
            Padding(
              padding: const EdgeInsets.only(left: 16),
              child: SettingTile(
                dense: true,
                leading: Icon(Icons.sync, color: pairs[i].enabled ? JjColors.accent : JjColors.textDim),
                // 67: 끝 폴더가 보이게 짧게 (전체 경로는 길게 누르거나 마우스를 올리면)
                title: Tooltip(
                  message: '${vDisplay(pairs[i].source)}\n→ ${vDisplay(pairs[i].target)}',
                  child: Text('${shortPath(pairs[i].source)}  →  ${shortPath(pairs[i].target)}',
                      maxLines: 2, overflow: TextOverflow.ellipsis),
                ),
                subtitle: Text([
                  tr(CopyMethod.of(pairs[i].method).label),
                  if (pairs[i].delete) tr('지우기 포함'),
                  scheduleSummary(pairs[i].schedule),
                  if (live?.isRunning(pairs[i]) ?? false) tr('맞추는 중…'),
                  if (live?.status[LiveSync.keyOf(pairs[i])] case final st?)
                    '${st.$1.hour.toString().padLeft(2, '0')}:${st.$1.minute.toString().padLeft(2, '0')} ${st.$2}',
                ].join(' · ')),
                trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                  IconButton(
                    tooltip: tr('동기화 시간 (계속 / 시간 지정)'),
                    icon: const Icon(Icons.schedule, size: 18),
                    onPressed: () async {
                      final r = await editSchedule(context, pairs[i].schedule);
                      if (r == null) return;
                      await c.updateSettings((x) => x.liveSyncPairs = [
                            for (var k = 0; k < pairs.length; k++) k == i ? pairs[k].copyWith(schedule: r) : pairs[k],
                          ]);
                    },
                  ),
                  IconButton(
                    tooltip: tr('지금 맞추기'),
                    icon: const Icon(Icons.sync, size: 18),
                    onPressed: live == null ? null : () => live.syncNow(pairs[i]),
                  ),
                  Switch(
                    value: pairs[i].enabled,
                    onChanged: (v) => c.updateSettings(
                        (x) => x.liveSyncPairs = [for (var k = 0; k < pairs.length; k++) k == i ? pairs[k].copyWith(enabled: v) : pairs[k]]),
                  ),
                  IconButton(
                    tooltip: tr('고치기'),
                    icon: const Icon(Icons.edit_outlined, size: 18),
                    onPressed: () => editLiveSyncPairDialog(context, c, pairs[i]),
                  ),
                  IconButton(
                    tooltip: tr('지우기'),
                    icon: const Icon(Icons.delete_outline, size: 18, color: JjColors.textDim),
                    onPressed: () => removeLiveSyncPair(context, c, pairs[i]),
                  ),
                ]),
              ),
            ),
        ]);
    return live == null ? body() : ListenableBuilder(listenable: live, builder: (_, _) => body());
  }
}

/// 백그라운드로 실행 · 앱을 다시 켤 때 동기화 (환경 설정 > 파일 탐색기 > 실시간 동기화, 모니터링 > lsync 위)
class LiveSyncRunOptions extends StatelessWidget {
  final AppController c;

  /// 모니터링: 한 줄로 짧게
  final bool dense;
  const LiveSyncRunOptions({super.key, required this.c, this.dense = false});

  static String backgroundHelp() => Platform.isWindows
      ? tr('창을 닫아도 (✕) 트레이에서 동기화 · MKV 만들기 · 다운로드를 계속합니다. 끄면 닫을 때 모두 끝냅니다. (실행 · 종료의 "종료를 누르면" 과 같은 설정)')
      : tr('← 로 닫거나 최근 앱 목록에서 밀어도 동기화 · MKV 만들기 · 다운로드를 계속합니다 (알림에 표시). 끄면 지금처럼 닫을 때 끝납니다. 완전히 끝내려면 [종료].');

  @override
  Widget build(BuildContext context) {
    final s = c.settings;
    final onStart = DropdownButton<String>(
      value: s.liveSyncOnStart,
      isDense: dense,
      items: [
        DropdownMenuItem(value: 'auto', child: Text(tr('바로 시작 (기본)'))),
        DropdownMenuItem(value: 'ask', child: Text(tr('골라서 시작'))),
        DropdownMenuItem(value: 'off', child: Text(tr('시작 안 함 (모니터링에서 시작)'))),
      ],
      onChanged: (v) => c.updateSettings((x) => x.liveSyncOnStart = v!),
    );
    void setBackground(bool? v) => c.updateSettings((x) => x.backgroundRun = v ?? false);
    if (dense) {
      return Wrap(spacing: 12, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
        Tooltip(
          message: backgroundHelp(),
          child: InkWell(
            onTap: () => setBackground(!s.backgroundRun),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Checkbox(value: s.backgroundRun, onChanged: setBackground),
              Text(tr('백그라운드로 실행'), style: const TextStyle(fontSize: 13)),
            ]),
          ),
        ),
        Row(mainAxisSize: MainAxisSize.min, children: [
          Text(tr('다시 켤 때 동기화'), style: const TextStyle(fontSize: 13, color: JjColors.textDim)),
          const SizedBox(width: 8),
          onStart,
        ]),
      ]);
    }
    return Column(children: [
      CheckboxListTile(
        dense: true,
        value: s.backgroundRun,
        onChanged: setBackground,
        title: Text(tr('백그라운드로 실행')),
        subtitle: Text(backgroundHelp()),
      ),
      SettingTile(
        dense: true,
        title: Text(tr('앱을 다시 켤 때 동기화')),
        subtitle: Text(tr('바로 시작: 켜진 동기화를 모두 시작 · 골라서 시작: 켤 때 고르기 · 시작 안 함: 모니터링 > lsync 의 시작 버튼으로')),
        trailing: onStart,
      ),
    ]);
  }
}
