import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../app/app_controller.dart';
import '../app/copy_center.dart';
import '../app/live_sync.dart';
import '../app/settings.dart';
import '../app/transfer_job.dart';
import '../core/file_ops.dart';
import '../core/sync_tools.dart';
import '../l10n/tr.dart';
import 'app_actions.dart';
import 'copy_sync_settings.dart' show addLiveSyncPairDialog, LiveSyncRunOptions;
import 'rsync_setup.dart';
import 'schedule_editor.dart';
import 'theme.dart';

/// 모니터링 (파일 탐색기 > 모니터링): 복사 · rsync 와 lsync (실시간 동기화) 를 따로 보여 준다.
class MonitorPage extends StatelessWidget {
  final AppController c;
  final int initialTab;
  const MonitorPage({super.key, required this.c, this.initialTab = 0});

  static Future<void> open(BuildContext context, AppController c, {int tab = 0}) => Navigator.of(context)
      .push(MaterialPageRoute<void>(builder: (_) => MonitorPage(c: c, initialTab: tab)));

  @override
  Widget build(BuildContext context) => DefaultTabController(
        length: 2,
        initialIndex: initialTab,
        child: Scaffold(
          body: Column(children: [
            Container(
              height: appBarHeight,
              color: JjColors.panel,
              padding: const EdgeInsets.only(left: 8, right: appBarRightPadding),
              child: Row(children: [
                const AppNavButtons(),
                const SizedBox(width: 8),
                Text(tr('모니터링'), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                const SizedBox(width: 16),
                Expanded(
                  child: TabBar(
                    isScrollable: true,
                    tabAlignment: TabAlignment.start,
                    tabs: [
                      Tab(icon: const Icon(Icons.copy_all_outlined, size: 18), text: tr('복사 · rsync')),
                      Tab(icon: const Icon(Icons.sync, size: 18), text: tr('lsync (실시간 동기화)')),
                    ],
                  ),
                ),
                AppActions(c: c),
              ]),
            ),
            Expanded(
              child: TabBarView(children: [
                _CopyTab(c: c),
                _LiveTab(c: c),
              ]),
            ),
          ]),
        ),
      );
}

String _hm(String iso) {
  final d = DateTime.tryParse(iso);
  if (d == null) return '';
  String two(int x) => x.toString().padLeft(2, '0');
  return '${d.month}/${d.day} ${two(d.hour)}:${two(d.minute)}';
}

/// 대상 디스크 남은 용량 / 전체
class _DiskInfo extends StatelessWidget {
  final String path;
  const _DiskInfo({required this.path});

  @override
  Widget build(BuildContext context) {
    var dir = path;
    while (!Directory(dir).existsSync() && p.dirname(dir) != dir) {
      dir = p.dirname(dir);
    }
    return FutureBuilder<(int, int)?>(
      future: diskSpace(dir),
      builder: (_, s) {
        final d = s.data;
        if (d == null) return Text(tr('대상 디스크: 알 수 없음'), style: const TextStyle(fontSize: 12, color: JjColors.textDim));
        final (free, total) = d;
        final used = total == 0 ? 0.0 : (total - free) / total;
        return Row(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.storage, size: 14, color: JjColors.textDim),
          const SizedBox(width: 4),
          Text(trf('대상 디스크: 남은 {0} / 전체 {1}', [formatSize(free), formatSize(total)]), style: const TextStyle(fontSize: 12)),
          const SizedBox(width: 8),
          SizedBox(
            width: 90,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                minHeight: 6,
                value: used,
                color: used > 0.9 ? Colors.redAccent : JjColors.accent,
                backgroundColor: JjColors.border,
              ),
            ),
          ),
        ]);
      },
    );
  }
}

/// 진행 두 줄 (위: 전체 항목 · 아래: 지금 폴더의 파일)
class TransferProgressLines extends StatelessWidget {
  final TransferJob job;
  const TransferProgressLines({super.key, required this.job});

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: job,
        builder: (_, _) {
          final cur = (job.index < job.total ? job.index : job.total - 1).clamp(0, job.total - 1);
          String pct(double v) => '${(v * 100).round()}%';
          Widget line(String label, double v, String right) => Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Row(children: [
                  SizedBox(width: 220, child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12))),
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(3),
                      child: LinearProgressIndicator(
                          minHeight: 7, value: job.counting ? null : v, color: JjColors.accent, backgroundColor: JjColors.border),
                    ),
                  ),
                  SizedBox(
                      width: 130,
                      child: Text(right, textAlign: TextAlign.end, style: const TextStyle(fontSize: 12, color: JjColors.textDim))),
                ]),
              );
          return Column(children: [
            line(trf('전체 {0}개 중 {1}번째', [job.total, cur + 1]), job.overall,
                '${pct(job.overall)} · ${trf('파일 {0}/{1}', [job.allDone, job.allFiles])}'),
            line(job.counting ? tr('파일 세는 중…') : trf('{0} 안의 파일', [p.basename(job.sources[cur])]), job.current,
                '${pct(job.current)} · ${trf('파일 {0}/{1}', [job.filesDone[cur], job.filesTotal[cur]])}'),
          ]);
        },
      );
}

// ───────── 복사 · rsync ─────────

class _CopyTab extends StatelessWidget {
  final AppController c;
  const _CopyTab({required this.c});

  @override
  Widget build(BuildContext context) {
    final center = CopyCenter.of(c);
    return ListenableBuilder(
      listenable: Listenable.merge([center, c]),
      builder: (context, _) {
        final tasks = center.tasks;
        if (tasks.isEmpty) {
          return Center(
            child: Text(tr('실행한 rsync 가 없습니다. Rsync 화면에서 → · ← · ⇄ 로 실행하면 여기에 자동으로 등록됩니다.'),
                style: const TextStyle(color: JjColors.textDim)),
          );
        }
        return ListView(
          padding: const EdgeInsets.all(12),
          children: [for (final t in tasks) _CopyCard(key: ValueKey(t.id), c: c, task: t)],
        );
      },
    );
  }
}

class _CopyCard extends StatefulWidget {
  final AppController c;
  final CopyTask task;
  const _CopyCard({super.key, required this.c, required this.task});

  @override
  State<_CopyCard> createState() => _CopyCardState();
}

class _CopyCardState extends State<_CopyCard> {
  CopyCenter get center => CopyCenter.of(widget.c);
  late String _method = widget.task.method;
  late final _options = TextEditingController(text: widget.task.options);
  late final _bw = TextEditingController(text: '${widget.task.bandwidthKBps}');
  late bool _once = widget.task.once;

  bool get _dirty =>
      _method != widget.task.method ||
      _options.text.trim() != widget.task.options ||
      (int.tryParse(_bw.text) ?? 0) != widget.task.bandwidthKBps ||
      _once != widget.task.once;

  @override
  void dispose() {
    _options.dispose();
    _bw.dispose();
    super.dispose();
  }

  Future<void> _run(CopyTask t) async {
    String? exe;
    if (t.method == 'rsync') {
      exe = await rsyncExecutable(widget.c.settings);
      if (exe == null && Platform.isWindows && widget.c.settings.rsyncSource == 'download' && mounted) {
        exe = await installRsyncWithDialog(context);
      }
      if (exe == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('rsync 실행 파일을 찾을 수 없습니다. 환경 설정 > 파일 탐색기에서 경로를 확인하세요.'))));
        }
        return;
      }
    }
    final problem = transferProblem(t.sources, t.dest, move: t.move);
    await center.start(t, rsyncExe: exe);
    if (problem != null && mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(problem)));
  }

  /// 옵션 저장 → 지금 실행할지 묻기 (현재 유지 / 반영 후 실행)
  Future<void> _save() async {
    final t = widget.task.copyWith(
      method: _method,
      options: _options.text.trim(),
      bandwidthKBps: int.tryParse(_bw.text) ?? 0,
      once: _once,
    );
    await center.update(t);
    if (!mounted) return;
    final running = center.isRunning(t.id);
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('옵션을 저장했습니다')),
        content: Text(running
            ? tr('지금 도는 복사는 앞의 옵션으로 돌고 있습니다. 멈추고 새 옵션으로 다시 실행할까요?')
            : tr('이 복사를 다시 할 때 이 옵션을 씁니다. 지금 새 옵션으로 실행할까요?')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('현재 유지'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr('설정 반영 후 실행'))),
        ],
      ),
    );
    if (go != true) return;
    if (running) {
      final old = center.jobs[t.id]!;
      old.cancel();
      await old.done;
    }
    await _run(t);
  }

  Future<void> _toLive(CopyTask t) async {
    final n = await center.toLiveSync(t);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(n == 0 ? tr('폴더만 lsync 로 옮길 수 있습니다.') : trf('{0}개 폴더를 lsync (실시간 동기화) 로 옮겼습니다.', [n]))));
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.task;
    final job = center.jobs[t.id];
    final running = job != null && !job.finished;
    final s = widget.c.settings;
    final (icon, color, status) = running
        ? (Icons.sync, JjColors.accent, job.move ? tr('옮기는 중') : tr('복사하는 중'))
        : switch (t.lastResult) {
            'done' => (Icons.check_circle, Colors.greenAccent, trf('끝 · {0} · 파일 {1}개', [_hm(t.lastRun), t.lastFiles])),
            'failed' => (Icons.error, Colors.redAccent, trf('실패 · {0}', [_hm(t.lastRun)])),
            'cancelled' => (Icons.pause_circle, Colors.orangeAccent, trf('멈춤 · {0}', [_hm(t.lastRun)])),
            _ => (Icons.schedule, JjColors.textDim, tr('아직 실행 안 함')),
          };
    final optsHint = switch (CopyMethod.of(_method)) {
      CopyMethod.rsync => defaultRsyncOptions,
      CopyMethod.robocopy => defaultRobocopyOptions,
      CopyMethod.builtin => tr('(현재 방식은 옵션 없음)'),
    };
    return Card(
      color: JjColors.panel,
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(icon, color: color, size: 20),
            const SizedBox(width: 8),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(
                  '${t.sources.length == 1 ? t.sources.first : trf('{0} 외 {1}개', [p.basename(t.sources.first), t.sources.length - 1])}'
                  '${t.contents ? '/' : ''}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                Text('→  ${t.dest}', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
              ]),
            ),
            Chip(
              visualDensity: VisualDensity.compact,
              label: Text('${t.move ? tr('이동') : tr('복사')} · ${tr(CopyMethod.of(t.method).label)}'),
            ),
          ]),
          Padding(
            padding: const EdgeInsets.only(left: 28, top: 2),
            child: Wrap(spacing: 16, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
              Text(status, style: TextStyle(fontSize: 12, color: color)),
              _DiskInfo(path: t.dest),
            ]),
          ),
          if (t.lastResult == 'failed' && !running && t.lastMessage.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 28, top: 4),
              child: Text(t.lastMessage, maxLines: 3, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11, color: Colors.redAccent)),
            ),
          if (job != null && (running || job.finished && job.error == null))
            Padding(padding: const EdgeInsets.only(left: 28, top: 6), child: TransferProgressLines(job: job)),
          const SizedBox(height: 8),
          // 옵션 (고치면 [저장] → 지금 실행할지 묻기)
          Padding(
            padding: const EdgeInsets.only(left: 28),
            child: Wrap(spacing: 10, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
              DropdownButton<String>(
                value: _method,
                items: [
                  for (final m in CopyMethod.values)
                    if (copyMethodAvailable(m, s) || m.name == _method) DropdownMenuItem(value: m.name, child: Text(tr(m.label))),
                ],
                onChanged: (v) => setState(() {
                  if (v != _method && _options.text.trim().isEmpty || _options.text.trim() == defaultRsyncOptions || _options.text.trim() == defaultRobocopyOptions) {
                    _options.text = v == 'robocopy' ? s.robocopyOptions : v == 'rsync' ? s.rsyncOptions : '';
                  }
                  _method = v!;
                }),
              ),
              SizedBox(
                width: 320,
                child: TextField(
                  controller: _options,
                  enabled: _method != 'builtin',
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
                  decoration: InputDecoration(isDense: true, border: const OutlineInputBorder(), labelText: tr('옵션'), hintText: optsHint),
                  onChanged: (_) => setState(() {}),
                ),
              ),
              SizedBox(
                width: 130,
                child: TextField(
                  controller: _bw,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: InputDecoration(isDense: true, border: const OutlineInputBorder(), labelText: tr('속도 제한'), suffixText: 'KB/s'),
                  onChanged: (_) => setState(() {}),
                ),
              ),
              if (t.sources.length > 1 && _method == 'rsync')
                FilterChip(label: Text(tr('한 번에')), selected: _once, onSelected: (v) => setState(() => _once = v)),
              if (_dirty) FilledButton.tonal(onPressed: _save, child: Text(tr('저장'))),
            ]),
          ),
          const SizedBox(height: 6),
          Row(children: [
            const Spacer(),
            if (running)
              TextButton.icon(onPressed: () => center.cancel(t.id), icon: const Icon(Icons.stop, size: 18), label: Text(tr('취소')))
            else
              FilledButton.icon(
                onPressed: () => _run(t),
                icon: const Icon(Icons.play_arrow, size: 18),
                label: Text(t.lastResult == 'cancelled' || t.lastResult == 'failed' ? tr('재개') : tr('실행')),
              ),
            const SizedBox(width: 6),
            TextButton.icon(
              onPressed: running ? null : () => _toLive(t),
              icon: const Icon(Icons.sync_alt, size: 18),
              label: Text(tr('lsync 로 이동')),
            ),
            IconButton(
              tooltip: tr('목록에서 지우기 (파일은 그대로)'),
              icon: const Icon(Icons.delete_outline, color: JjColors.textDim),
              onPressed: () => center.remove(t.id),
            ),
          ]),
        ]),
      ),
    );
  }
}

// ───────── lsync (실시간 동기화) ─────────

class _LiveTab extends StatefulWidget {
  final AppController c;
  const _LiveTab({required this.c});

  @override
  State<_LiveTab> createState() => _LiveTabState();
}

class _LiveTabState extends State<_LiveTab> {
  AppController get c => widget.c;

  @override
  void initState() {
    super.initState();
    // 열 때 맞출 것을 새로 센다
    final live = LiveSync.instance;
    if (live != null) {
      for (final x in c.settings.liveSyncPairs) {
        live.refreshPending(x);
      }
    }
  }

  Future<void> _replace(LiveSyncPair old, LiveSyncPair now) => c.updateSettings((x) => x.liveSyncPairs = [
        for (final y in x.liveSyncPairs) y.source == old.source && y.target == old.target ? now : y,
      ]);

  @override
  Widget build(BuildContext context) {
    final live = LiveSync.instance;
    return ListenableBuilder(
      listenable: Listenable.merge([c, ?live]),
      builder: (context, _) {
        final pairs = c.settings.liveSyncPairs;
        return ListView(padding: const EdgeInsets.all(12), children: [
          Row(children: [
            Expanded(
              child: Text(
                tr('원본이 바뀌면 대상에 맞춥니다. 일정을 정하면 그 시간에만 맞추고, 그 밖의 시간에는 바뀐 것을 모아 두었다가 다음 시작 시간에 맞춥니다.'),
                style: const TextStyle(fontSize: 12, color: JjColors.textDim),
              ),
            ),
            TextButton.icon(onPressed: () => addLiveSyncPairDialog(context, c), icon: const Icon(Icons.add), label: Text(tr('추가'))),
          ]),
          // 백그라운드로 실행 · 다시 켤 때 동기화 (환경 설정과 같은 값) · 모두 시작 / 멈춤
          Wrap(spacing: 12, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
            LiveSyncRunOptions(c: c, dense: true),
            if (live != null && pairs.any((x) => x.enabled))
              live.paused.isEmpty
                  ? TextButton.icon(
                      onPressed: live.pauseAll, icon: const Icon(Icons.pause, size: 18), label: Text(tr('모두 멈춤')))
                  : FilledButton.tonalIcon(
                      onPressed: live.resumeAll,
                      icon: const Icon(Icons.play_arrow, size: 18),
                      label: Text(trf('모두 시작 (멈춘 것 {0}개)', [pairs.where(live.isPaused).length]))),
          ]),
          const SizedBox(height: 8),
          if (pairs.isEmpty)
            Padding(
              padding: const EdgeInsets.all(24),
              child: Center(child: Text(tr('실시간 동기화가 없습니다. [추가] 하거나 복사 · rsync 탭에서 [lsync 로 이동] 하세요.'),
                  style: const TextStyle(color: JjColors.textDim))),
            ),
          for (final x in pairs) _liveCard(context, live, x),
        ]);
      },
    );
  }

  Widget _liveCard(BuildContext context, LiveSync? live, LiveSyncPair x) {
    final k = LiveSync.keyOf(x);
    final pend = live?.pending[k];
    final st = live?.status[k];
    final active = LiveSync.activeNow(x);
    final running = live?.isRunning(x) ?? false;
    final held = live?.isPaused(x) ?? false;
    return Card(
      color: JjColors.panel,
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(
                running
                    ? Icons.sync
                    : !x.enabled
                        ? Icons.sync_disabled
                        : held
                            ? Icons.pause_circle_outline
                            : active
                                ? Icons.sync
                                : Icons.bedtime_outlined,
                color: x.enabled && !held ? (active ? JjColors.accent : Colors.orangeAccent) : JjColors.textDim),
            const SizedBox(width: 8),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${x.source}/', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
                Text('→  ${x.target}/', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
              ]),
            ),
            Chip(
              visualDensity: VisualDensity.compact,
              label: Text([tr(CopyMethod.of(x.method).label), if (x.delete) tr('지우기 포함')].join(' · ')),
            ),
            // 이번 실행 동안 멈춤 / 시작 (설정의 켜기 · 끄기는 오른쪽 스위치)
            if (live != null && x.enabled)
              IconButton(
                tooltip: held ? tr('시작') : tr('멈춤 (이번 실행 동안)'),
                icon: Icon(held ? Icons.play_arrow : Icons.pause, color: held ? JjColors.accent : null),
                onPressed: () => held ? live.resume(x) : live.pause(x),
              ),
            Switch(value: x.enabled, onChanged: (v) => _replace(x, x.copyWith(enabled: v))),
          ]),
          if (held)
            Padding(
              padding: const EdgeInsets.only(left: 32, top: 2),
              child: Text(tr('멈춤 (이번 실행 동안) · 시작 버튼을 누르면 다시 동기화합니다'),
                  style: const TextStyle(fontSize: 12, color: Colors.orangeAccent)),
            ),
          Padding(
            padding: const EdgeInsets.only(left: 32, top: 4),
            child: Wrap(spacing: 16, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
              // 일정: 계속 / 시간 지정 (cron) + 작은 격자
              InkWell(
                onTap: () async {
                  final r = await editSchedule(context, x.schedule);
                  if (r != null) await _replace(x, x.copyWith(schedule: r));
                },
                borderRadius: BorderRadius.circular(6),
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    WeekGridPreview(lines: x.schedule, width: 120),
                    const SizedBox(width: 8),
                    Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                      Text(scheduleSummary(x.schedule), style: TextStyle(fontSize: 12, color: active ? JjColors.accent : Colors.orangeAccent)),
                      if (x.schedule.isNotEmpty)
                        Text(x.schedule.join('  |  '), style: const TextStyle(fontSize: 11, fontFamily: 'monospace', color: JjColors.textDim)),
                      Text(tr('누르면 일정 바꾸기'), style: const TextStyle(fontSize: 10, color: JjColors.textDim)),
                    ]),
                  ]),
                ),
              ),
              if (st != null)
                Text('${tr('마지막')}: ${st.$1.hour.toString().padLeft(2, '0')}:${st.$1.minute.toString().padLeft(2, '0')} ${st.$2}',
                    style: const TextStyle(fontSize: 12, color: JjColors.textDim)),
              _DiskInfo(path: x.target),
            ]),
          ),
          // 맞출 것 (바뀐 파일) - 자동으로 다시 셈
          Padding(
            padding: const EdgeInsets.only(left: 32, top: 8),
            child: pend == null
                ? Text(tr('맞출 것을 세는 중…'), style: const TextStyle(fontSize: 12, color: JjColors.textDim))
                : pend.isEmpty
                    ? Text(tr('맞출 것 없음 (원본과 대상이 같습니다)'), style: const TextStyle(fontSize: 12, color: Colors.greenAccent))
                    : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(
                          trf('맞출 것 {0}개{1}', [pend.length >= 500 ? '500+' : pend.length, active ? '' : tr(' · 다음 시작 시간에 맞춥니다')]),
                          style: const TextStyle(fontSize: 12, color: Colors.orangeAccent),
                        ),
                        const SizedBox(height: 4),
                        Container(
                          constraints: const BoxConstraints(maxHeight: 140),
                          decoration: BoxDecoration(color: JjColors.bg, borderRadius: BorderRadius.circular(6)),
                          padding: const EdgeInsets.all(8),
                          child: ListView(shrinkWrap: true, children: [
                            for (final f in pend.take(100))
                              Text(f,
                                  style: TextStyle(
                                      fontSize: 11.5, fontFamily: 'monospace', color: f.startsWith('− ') ? Colors.redAccent : null)),
                            if (pend.length > 100) Text(trf('… 외 {0}개', [pend.length - 100]), style: const TextStyle(fontSize: 11)),
                          ]),
                        ),
                      ]),
          ),
          const SizedBox(height: 6),
          Row(children: [
            const Spacer(),
            TextButton.icon(
              onPressed: live == null ? null : () => live.refreshPending(x),
              icon: const Icon(Icons.refresh, size: 18),
              label: Text(tr('다시 세기')),
            ),
            FilledButton.icon(
              onPressed: live == null || running ? null : () => live.syncNow(x),
              icon: const Icon(Icons.sync, size: 18),
              label: Text(tr('지금 맞추기')),
            ),
            const SizedBox(width: 6),
            TextButton.icon(
              onPressed: () async {
                await CopyCenter.of(c).fromLiveSync(x);
                if (context.mounted) {
                  DefaultTabController.of(context).animateTo(0);
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('복사 · rsync 목록으로 옮겼습니다.'))));
                }
              },
              icon: const Icon(Icons.swap_horiz, size: 18),
              label: Text(tr('복사 · rsync 로 이동')),
            ),
            IconButton(
              tooltip: tr('지우기'),
              icon: const Icon(Icons.delete_outline, color: JjColors.textDim),
              onPressed: () => c.updateSettings((y) => y.liveSyncPairs = [
                    for (final o in y.liveSyncPairs) if (!(o.source == x.source && o.target == x.target)) o,
                  ]),
            ),
          ]),
        ]),
      ),
    );
  }
}

/// 앱을 다시 켤 때 ([AppSettings.liveSyncOnStart] 'ask'): 어느 실시간 동기화를 시작할지 고르기.
/// 고르지 않은 것은 이번 실행 동안 멈춤 (모니터링 > lsync 에서 ▶ 로 시작).
Future<void> askLiveSyncStart(BuildContext context, LiveSync live) async {
  final pairs = live.c.settings.liveSyncPairs.where((x) => x.enabled).toList();
  if (pairs.isEmpty) return;
  final pick = {for (final x in pairs) LiveSync.keyOf(x)};
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, set) => AlertDialog(
        title: Text(tr('실시간 동기화 시작')),
        content: SizedBox(
          width: 520,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(tr('시작할 동기화를 고르세요. 고르지 않은 것은 이번 실행 동안 멈춥니다 (모니터링 > lsync 에서 시작).'),
                style: const TextStyle(fontSize: 12, color: JjColors.textDim)),
            const SizedBox(height: 8),
            Flexible(
              child: ListView(shrinkWrap: true, children: [
                for (final x in pairs)
                  CheckboxListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    value: pick.contains(LiveSync.keyOf(x)),
                    onChanged: (v) => set(() => v == true ? pick.add(LiveSync.keyOf(x)) : pick.remove(LiveSync.keyOf(x))),
                    title: Text('${x.source}  →  ${x.target}', maxLines: 2, overflow: TextOverflow.ellipsis),
                    subtitle: Text(scheduleSummary(x.schedule)),
                  ),
              ]),
            ),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('모두 나중에'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr('고른 것 시작'))),
        ],
      ),
    ),
  );
  if (ok == true) live.runOnly(pairs.where((x) => pick.contains(LiveSync.keyOf(x))));
}
