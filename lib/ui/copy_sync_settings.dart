import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app/app_controller.dart';
import '../app/live_sync.dart';
import '../app/settings.dart';
import '../core/sync_tools.dart';
import '../l10n/tr.dart';
import '../platform/windows/rsync_installer.dart';
import 'folder_picker.dart';
import 'rsync_setup.dart';
import 'schedule_editor.dart';
import 'theme.dart';

/// 환경 설정 > 파일 탐색기 의 복사 · 이동 · 동기화 부분:
/// 파일 / 폴더 복사 방법 (현재 방식 · rsync · robocopy), 옵션, 여러 개 실행 방식, 속도 제한, rsync 가져오기, 실시간 동기화.
class CopySyncSettings extends StatefulWidget {
  final AppController c;
  const CopySyncSettings({super.key, required this.c});

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

  List<DropdownMenuItem<String>> _methods() => [
        for (final m in CopyMethod.values)
          if (copyMethodAvailable(m, c.settings)) DropdownMenuItem(value: m.name, child: Text(tr(m.label))),
      ];

  String _valid(String v) => copyMethodAvailable(CopyMethod.of(v), c.settings) ? v : 'builtin';

  /// 옵션 입력칸 (바꾸면 바로 저장, ↺ 로 기본값)
  Widget _options(String title, String hint, String value, String def, void Function(AppSettings, String) set) => ListTile(
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
  Widget build(BuildContext context) {
    final s = c.settings;
    final desk = Platform.isWindows;
    final rsyncUsable = copyMethodAvailable(CopyMethod.rsync, s);
    return Column(children: [
      const Divider(height: 1),
      ListTile(
        title: Text(tr('파일 복사 · 이동 방법')),
        subtitle: Text(tr('파일만 골랐을 때')),
        trailing: DropdownButton<String>(
          value: _valid(s.copyMethodFile),
          items: _methods(),
          onChanged: (v) => c.updateSettings((x) => x.copyMethodFile = v!),
        ),
      ),
      ListTile(
        title: Text(tr('폴더 복사 · 이동 방법')),
        subtitle: Text(tr('폴더가 들어 있을 때')),
        trailing: DropdownButton<String>(
          value: _valid(s.copyMethodFolder),
          items: _methods(),
          onChanged: (v) => c.updateSettings((x) => x.copyMethodFolder = v!),
        ),
      ),
      if (rsyncUsable)
        _options(tr('rsync 옵션'), tr('예: -avPog (보관 · 자세히 · 진행 · 소유자 · 그룹). 이동은 --remove-source-files 를 자동으로 붙임'),
            s.rsyncOptions, defaultRsyncOptions, (x, v) => x.rsyncOptions = v),
      if (desk)
        _options(tr('robocopy 옵션'), tr('예: /E /COPY:DAT /DCOPY:T /R:2 /W:2. 이동은 /MOVE 를 자동으로 붙임'), s.robocopyOptions,
            defaultRobocopyOptions, (x, v) => x.robocopyOptions = v),
      ListTile(
        title: Text(tr('여러 개를 골랐을 때')),
        subtitle: Text(tr('rsync 를 항목마다 따로 실행하거나, 한 번에 실행 (robocopy 는 늘 폴더마다)')),
        trailing: DropdownButton<String>(
          value: s.copyRunMode,
          items: [
            DropdownMenuItem(value: 'each', child: Text(tr('항목마다 따로 (기본)'))),
            DropdownMenuItem(value: 'once', child: Text(tr('한 번에'))),
          ],
          onChanged: (v) => c.updateSettings((x) => x.copyRunMode = v!),
        ),
      ),
      ListTile(
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
      ListTile(
        title: Text(tr('rsync 가져오기')),
        subtitle: Text(_checking
            ? tr('확인 중…')
            : _rsync != null
                ? trf('사용: {0}', [_rsync!])
                : s.rsyncSource == 'download'
                    ? (desk ? tr('아직 없음 (rsync 로 복사할 때 · 아래 [내려받기] 로 받습니다)') : tr('Android 는 rsync 를 내려받을 수 없습니다. 직접 지정하세요.'))
                    : tr('지정한 파일이 없습니다')),
        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
          if (desk && s.rsyncSource == 'download' && !_checking)
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
              DropdownMenuItem(value: 'download', child: Text(desk ? tr('처음 쓸 때 내려받기 (기본)') : tr('내려받기 (Windows 만)'))),
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
        ListTile(
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
      SwitchListTile(
        value: s.copyMonitor,
        onChanged: (v) => c.updateSettings((x) => x.copyMonitor = v),
        title: Text(tr('복사 모니터링')),
        subtitle: Text(tr('파일 탐색기 가운데에 [모니터링] 버튼: 복사 · 이동을 기억해 진행 · 대상 디스크 용량 · 옵션을 보여 주고, '
            '옵션을 고쳐 다시 실행 · 재개하거나 lsync 로 옮깁니다 (복사 · rsync 와 lsync 를 따로).')),
      ),
      _LiveSyncTile(c: c),
    ]);
  }
}

/// 실시간 동기화 쌍 추가 (원본 · 대상 폴더 고르기 → 방법 · 지우기 · 일정)
Future<void> addLiveSyncPairDialog(BuildContext context, AppController c) => _LiveSyncTile._add(context, c);

/// 실시간 동기화 (lsyncd 처럼): 폴더 쌍 목록 · 추가 · 켜기 / 끄기 · 일정 · 지금 맞추기 · 지우기
class _LiveSyncTile extends StatelessWidget {
  final AppController c;
  const _LiveSyncTile({required this.c});

  static Future<void> _add(BuildContext context, AppController c) async {
    final src = await pickFolder(context, tr('실시간 동기화: 원본 폴더'));
    if (src == null || !context.mounted) return;
    final dst = await pickFolder(context, tr('실시간 동기화: 대상 폴더'));
    if (dst == null || !context.mounted) return;
    var method = copyMethodAvailable(CopyMethod.rsync, c.settings) ? 'rsync' : 'builtin';
    var delete = false;
    var schedule = <String>[];
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => AlertDialog(
          title: Text(tr('실시간 동기화 추가')),
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('$src\n→ $dst', style: const TextStyle(fontSize: 13)),
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
            ListTile(
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
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr('추가'))),
          ],
        ),
      ),
    );
    if (ok != true) return;
    await c.updateSettings(
        (x) => x.liveSyncPairs = [...x.liveSyncPairs, LiveSyncPair(src, dst, method: method, delete: delete, schedule: schedule)]);
  }

  @override
  Widget build(BuildContext context) {
    final live = LiveSync.instance;
    final pairs = c.settings.liveSyncPairs;
    Widget body() => Column(children: [
          ListTile(
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
          for (var i = 0; i < pairs.length; i++)
            Padding(
              padding: const EdgeInsets.only(left: 16),
              child: ListTile(
                dense: true,
                leading: Icon(Icons.sync, color: pairs[i].enabled ? JjColors.accent : JjColors.textDim),
                title: Text('${pairs[i].source}  →  ${pairs[i].target}', maxLines: 2, overflow: TextOverflow.ellipsis),
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
                    tooltip: tr('지우기'),
                    icon: const Icon(Icons.delete_outline, size: 18, color: JjColors.textDim),
                    onPressed: () => c.updateSettings(
                        (x) => x.liveSyncPairs = [for (var k = 0; k < pairs.length; k++) if (k != i) pairs[k]]),
                  ),
                ]),
              ),
            ),
        ]);
    return live == null ? body() : ListenableBuilder(listenable: live, builder: (_, _) => body());
  }
}
