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
import '../core/vfs.dart';
import '../l10n/tr.dart';
import 'app_actions.dart';
import 'copy_sync_settings.dart' show addLiveSyncPairDialog, editLiveSyncPairDialog, removeLiveSyncPair, LiveSyncRunOptions;
import 'path_label.dart';
import 'rsync_setup.dart';
import 'schedule_editor.dart';
import 'sync_preview_view.dart' show confirmDeletingRun;
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
            Builder(builder: (context) {
              // 좁은 화면: 둘째 줄 (높이 48) 에 맞게 탭에 아이콘을 옆으로
              final compact = isCompact(context);
              Tab tab(IconData icon, String text) => compact
                  ? Tab(height: 46, child: Row(mainAxisSize: MainAxisSize.min, children: [Icon(icon, size: 16), const SizedBox(width: 6), Text(text)]))
                  : Tab(icon: Icon(icon, size: 18), text: text);
              return AppTopBar(
                nav: const AppNavButtons(),
                actions: AppActions(c: c),
                middle: Row(children: [
                  Text(tr('모니터링'), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                  const SizedBox(width: 16),
                  Expanded(
                    child: TabBar(
                      isScrollable: true,
                      tabAlignment: TabAlignment.start,
                      tabs: [
                        tab(Icons.copy_all_outlined, tr('복사 · rsync')),
                        tab(Icons.sync, tr('lsync (실시간 동기화)')),
                      ],
                    ),
                  ),
                ]),
              );
            }),
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

/// 실시간 동기화 "지우기" 확인 창 (42): 대상에만 있어 지워질 항목을 보여 주고 [지우기 포함으로 맞추기] · [지우지 않기] · [나중에]
Future<void> confirmLiveDeletes(BuildContext context, LiveSync live, LiveSyncPair x) async {
  final list = live.toDelete[LiveSync.keyOf(x)] ?? const <String>[];
  if (list.isEmpty) return;
  final pick = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(trf('대상에서 {0}개를 지울까요?', [list.length])),
      content: SizedBox(
        width: 560,
        height: 360,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(trf('"{0}" 에는 없고 대상 "{1}" 에만 있는 항목입니다. 지우기 포함으로 맞추면 대상에서 지워집니다 (되돌릴 수 없음).',
              [vDisplay(x.source), vDisplay(x.target)])),
          const SizedBox(height: 8),
          Expanded(
            child: ListView(children: [
              for (final n in list.take(500)) Text(n, style: const TextStyle(fontSize: 12, fontFamily: 'Consolas')),
              if (list.length > 500) Text(trf('… 외 {0}개', [list.length - 500])),
            ]),
          ),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('나중에'))),
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('지우지 않기 (지우기 끄기)'))),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: JjColors.danger),
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(trf('{0}개 지우고 맞추기', [list.length])),
        ),
      ],
    ),
  );
  if (pick == null) return;
  await live.decideDelete(x, delete: pick);
}

/// 70: 원본이 비어 멈춘 쌍 - 지워질 목록을 보여 주고 [그래도 맞추기] 로 확인받는다 (42 와 같은 창)
Future<void> confirmEmptySourceSync(BuildContext context, LiveSync live, LiveSyncPair x) async {
  final list = live.emptyDeletes[LiveSync.keyOf(x)] ?? const <String>[];
  if (list.isEmpty) return;
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(trf('원본이 비어 있습니다. 대상에서 {0}개를 지울까요?', [list.length])),
      content: SizedBox(
        width: 560,
        height: 360,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(trf('"{0}" 이 비어 있어, 맞추면 대상 "{1}" 의 아래 항목이 모두 지워집니다 (되돌릴 수 없음). '
              '원본을 일부러 비운 경우에만 누르세요.', [vDisplay(x.source), vDisplay(x.target)])),
          const SizedBox(height: 8),
          Expanded(
            child: ListView(children: [
              for (final n in list.take(500)) Text(n, style: const TextStyle(fontSize: 12, fontFamily: 'Consolas')),
              if (list.length > 500) Text(trf('… 외 {0}개', [list.length - 500])),
            ]),
          ),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('취소'))),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: JjColors.danger),
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(trf('그래도 맞추기 ({0}개 지움)', [list.length])),
        ),
      ],
    ),
  );
  if (ok == true) await live.syncEmptyAnyway(x);
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
          final speed = !job.finished && job.speed != null ? '${formatSize(job.speed!.round())}/s' : '';
          // 위: 지금 복사하는 파일 (그 파일의 진행률 · 속도) / 아래: 폴더 전체 (파일 수)
          final fileLabel = job.counting
              ? tr('파일 세는 중…')
              : job.pruning
                  ? (job.finished ? trf('빈 폴더 {0}개 지움', [job.pruned]) : tr('원본의 빈 폴더 정리 중…'))
                  : job.finished
                      ? tr('끝')
                      : job.currentFile.isEmpty
                          ? tr('시작하는 중…')
                          : job.currentFile.split('/').last;
          final fileValue = job.finished ? 1.0 : (job.filePercent ?? 0);
          return Column(children: [
            Tooltip(
              message: job.currentFile,
              child: line(fileLabel, fileValue,
                  [if (job.filePercent != null && !job.finished) pct(fileValue), if (speed.isNotEmpty) speed].join(' · ')),
            ),
            line(trf('{0} 전체', [p.basename(job.sources[cur])]), job.folderProgress,
                '${pct(job.folderProgress)} · ${job.checkTotal > 0 && !job.finished ? trf('항목 {0}/{1}', [job.checked, job.checkTotal]) : trf('파일 {0}/{1}', [job.allDone, job.allFiles])}'),
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
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(tr('실행한 rsync 가 없습니다. Rsync 화면에서 → · ← · ⇄ 로 실행하면 여기에 자동으로 등록됩니다.'),
                  textAlign: TextAlign.center, style: const TextStyle(color: JjColors.textDim)),
            ),
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

/// 이동 (rsync --remove-source-files) 뒤 원본 정리 이름
String pruneLabel(String v) => switch (v) {
      'keep' => tr('빈 폴더 지움 · 원본 폴더는 남김'),
      'all' => tr('빈 폴더 지움 · 원본 폴더도 지움'),
      _ => tr('빈 폴더 그대로'),
    };

/// 원본 정리 고르기: 원본 폴더를 남길지 · 지울지 (빈 폴더는 지움 = find 원본/ -type d -empty -delete)
class PruneChoice extends StatelessWidget {
  final String value;
  final ValueChanged<String> onChanged;
  final bool allowNone;
  const PruneChoice({super.key, required this.value, required this.onChanged, this.allowNone = false});

  @override
  Widget build(BuildContext context) => Wrap(spacing: 6, runSpacing: 6, children: [
        for (final v in [if (allowNone) '', 'keep', 'all'])
          ChoiceChip(label: Text(pruneLabel(v)), selected: value == v, onSelected: (_) => onChanged(v)),
      ]);
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
  late String _prune = widget.task.prune;

  bool get _dirty =>
      _prune != widget.task.prune ||
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
    // 104: 지우기가 들어 있으면 Rsync 화면과 같은 미리 보기를 거친다 (그사이 대상에 생긴 파일을 묻지 않고 지우지 않게)
    if (!await confirmDeletingRun(context, t) || !mounted) return;
    widget.c.note(trf('rsync 시작 ({0}): {1} → {2}', [tr('모니터링의 [실행]'), t.sources.join(', '), t.dest]));
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

  /// 칸에 보이는 (고친) 옵션으로 만든 작업
  CopyTask _edited() => widget.task.copyWith(
        method: _method,
        options: _options.text.trim(),
        bandwidthKBps: int.tryParse(_bw.text) ?? 0,
        once: _once,
        prune: _prune,
      );

  /// 114: [실행] 을 눌렀는데 저장하지 않은 고침이 있으면 묻는다 (칸에 보이는 것과 다른 옵션으로 몰래 돌지 않게).
  /// 저장하고 실행하면 그 옵션으로 (지우기가 있으면 미리 보기 창)
  Future<void> _runPressed(CopyTask t) async {
    if (!_dirty) return _run(t);
    final pick = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        scrollable: true,
        actionsOverflowDirection: VerticalDirection.down,
        title: Text(tr('고친 옵션을 저장하지 않았습니다')),
        content: Text(trf('칸에 보이는 옵션: {0}\n저장된 옵션: {1}\n\n고친 옵션을 저장하고 실행할까요?', [
          '${_method == 'builtin' ? tr('현재 방식') : _method} ${_options.text.trim()}',
          '${t.method == 'builtin' ? tr('현재 방식') : t.method} ${t.options}',
        ])),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('취소'))),
          TextButton(onPressed: () => Navigator.pop(ctx, 'old'), child: Text(tr('저장된 옵션으로 실행'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, 'save'), child: Text(tr('저장하고 실행'))),
        ],
      ),
    );
    if (!mounted || pick == null) return;
    if (pick == 'old') return _run(t);
    final edited = _edited();
    await center.update(edited);
    if (mounted) await _run(edited);
  }

  /// 옵션 저장 → 지금 실행할지 묻기 (현재 유지 / 반영 후 실행)
  Future<void> _save() async {
    final t = _edited();
    await center.update(t);
    if (!mounted) return;
    final running = center.isRunning(t.id);
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        scrollable: true,
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

  /// lsync 로: 끝나지 않은 것 (실행 중 · 실패 · 취소 · 아직 안 함) 도 옮길 수 있다 - 남은 것은 lsync 가 이어서 맞춘다.
  /// 실행 중이면 물어본 뒤 멈추고 옮긴다.
  Future<void> _toLive(CopyTask t) async {
    if (center.isRunning(t.id)) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
        scrollable: true,
          title: Text(tr('lsync 로 이동')),
          content: Text(tr('지금 실행 중입니다. 멈추고 lsync (실시간 동기화) 로 옮길까요? 남은 것은 lsync 가 이어서 맞춥니다.')),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('취소'))),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr('멈추고 옮기기'))),
          ],
        ),
      );
      if (ok != true) return;
      final job = center.jobs[t.id]!;
      job.cancel();
      await job.done;
      if (!mounted) return;
    }
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
              // 112: 끝 폴더가 보이게 짧게, 전체 경로는 작게
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(
                  t.sources.length == 1
                      ? shortPath(t.sources.first)
                      : trf('{0} 외 {1}개', [shortPath(t.sources.first), t.sources.length - 1]),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                Text('→  ${shortPath(t.dest)}', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
                Text('${vDisplay(t.sources.first)}${t.contents ? '/' : ''}  →  ${vDisplay(t.dest)}',
                    maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11, color: JjColors.textDim)),
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
              // 이동 (원본 파일 지우기) 이면: 끝난 뒤 원본의 빈 폴더 · 원본 폴더 정리
              if (t.move && _method == 'rsync')
                DropdownButton<String>(
                  value: _prune,
                  items: [for (final v in ['', 'keep', 'all']) DropdownMenuItem(value: v, child: Text(pruneLabel(v)))],
                  onChanged: (v) => setState(() => _prune = v!),
                ),
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
                onPressed: () => _runPressed(t),
                icon: const Icon(Icons.play_arrow, size: 18),
                label: Text(t.lastResult == 'cancelled' || t.lastResult == 'failed' ? tr('재개') : tr('실행')),
              ),
            const SizedBox(width: 6),
            TextButton.icon(
              onPressed: () => _toLive(t),
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

  /// 최종 정리: 원본의 것을 모두 대상으로 옮기고 (rsync -avHPOg --remove-source-files 원본/ 대상/)
  /// 빈 폴더를 지운다 (find 원본/ -type d -empty -delete). 원본 폴더를 남길지 · 지울지만 고른다.
  /// 원본이 비므로 이 실시간 동기화는 끈다 (켜 둔 채 "지우기 포함" 이면 대상까지 비워 버린다).
  Future<void> _finalize(LiveSyncPair x) async {
    final live = LiveSync.instance;
    final messenger = ScaffoldMessenger.of(context);
    if (live?.isRunning(x) ?? false) {
      messenger.showSnackBar(SnackBar(content: Text(tr('지금 맞추는 중입니다. 끝난 뒤에 하세요.'))));
      return;
    }
    var prune = 'keep';
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => AlertDialog(
        scrollable: true,
          title: Text(tr('최종 정리')),
          content: SizedBox(
            width: 600,
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(tr('원본의 파일을 모두 대상으로 옮기고 (원본에서 지움), 원본에 남은 빈 폴더를 지웁니다.')),
              const SizedBox(height: 10),
              SelectableText(
                  'rsync -avHPOg --remove-source-files ${x.source}/ ${x.target}/\n'
                  'find ${x.source}/ -type d -empty -delete',
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12, color: JjColors.textDim)),
              const SizedBox(height: 14),
              Text(tr('원본 폴더'), style: const TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 6),
              PruneChoice(value: prune, onChanged: (v) => set(() => prune = v)),
              const SizedBox(height: 12),
              Text(tr('원본이 비므로 이 실시간 동기화는 끕니다. 진행은 [복사 · rsync] 탭에서 봅니다.'),
                  style: const TextStyle(fontSize: 12, color: Colors.orangeAccent)),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('취소'))),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr('최종 정리'))),
          ],
        ),
      ),
    );
    if (go != true || !mounted) return;
    var exe = await rsyncExecutable(c.settings);
    if (exe == null && Platform.isWindows && c.settings.rsyncSource == 'download' && mounted) {
      exe = await installRsyncWithDialog(context);
    }
    if (exe == null) {
      messenger.showSnackBar(SnackBar(content: Text(tr('rsync 실행 파일을 찾을 수 없습니다. 환경 설정 > Rsync 에서 확인하세요.'))));
      return;
    }
    final center = CopyCenter.of(c);
    var t = await center.remember([x.source], x.target, move: true, contents: true, method: 'rsync');
    // 처음이면 정해진 옵션 (모니터링에서 고친 것이 있으면 그것)
    t = t.copyWith(prune: prune, options: t.lastRun.isEmpty ? '-avHPOg' : null);
    await center.update(t);
    // 104: 고친 옵션에 지우기가 있으면 미리 보기를 거친다
    if (!mounted || !await confirmDeletingRun(context, t) || !mounted) return;
    await _replace(x, x.copyWith(enabled: false));
    c.note(trf('rsync 시작 ({0}): {1} → {2}', [tr('실시간 동기화의 [최종 정리]'), x.source, x.target]));
    final job = await center.start(t, rsyncExe: exe);
    if (!mounted) return;
    if (job == null) {
      messenger.showSnackBar(SnackBar(content: Text(center.tasks.firstWhere((y) => y.id == t.id).lastMessage)));
      return;
    }
    DefaultTabController.of(context).animateTo(0);
  }

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

  /// 69: 카드의 길게 누르기 · 오른쪽 클릭 메뉴
  Future<void> _pairMenu(BuildContext context, LiveSyncPair x, Offset at) async {
    final pick = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(at.dx, at.dy, at.dx, at.dy),
      items: [
        PopupMenuItem(value: 'edit', child: Text(tr('고치기'))),
        PopupMenuItem(value: 'remove', child: Text(tr('지우기'))),
      ],
    );
    if (!context.mounted) return;
    if (pick == 'edit') {
      await editLiveSyncPairDialog(context, c, x);
    } else if (pick == 'remove') {
      await removeLiveSyncPair(context, c, x);
    }
  }

  /// 원본 문제 안내 (68 · 70)
  Widget _problemPanel(BuildContext context, LiveSync live, LiveSyncPair x, SourceUnreadableException e) {
    final k = LiveSync.keyOf(x);
    final dels = live.emptyDeletes[k] ?? const <String>[];
    final running = live.isRunning(x);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
      decoration: BoxDecoration(
        color: Colors.redAccent.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.redAccent.withValues(alpha: 0.6)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(e.empty ? Icons.folder_off_outlined : Icons.error_outline, color: Colors.redAccent, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              e.empty ? tr('원본 폴더가 비어 있어 멈췄습니다') : tr('원본을 읽을 수 없어 멈췄습니다'),
              style: const TextStyle(fontWeight: FontWeight.w600, color: Colors.redAccent),
            ),
          ),
        ]),
        const SizedBox(height: 4),
        Text(tr('대상 파일은 지우지 않았습니다.'), style: const TextStyle(fontSize: 12)),
        Text(
          e.empty
              ? trf('원본에는 아무것도 없는데 대상에는 {0}개가 있습니다. SD 카드가 빠졌거나 네트워크 · 권한 문제일 수 있습니다. '
                  '일부러 원본을 비웠다면 지울 목록을 보고 [그래도 맞추기] 를 누르세요.', [dels.length])
              : tr('SD 카드가 꽂혀 있는지, 네트워크 (NAS · VPN) 가 연결되어 있는지, 폴더 권한이 있는지 확인한 뒤 [다시 시도] 를 누르세요.'),
          style: const TextStyle(fontSize: 12),
        ),
        const SizedBox(height: 4),
        Text('${vDisplay(x.source)}${e.detail.isEmpty ? '' : '  ·  ${e.detail}'}',
            style: const TextStyle(fontSize: 11, color: JjColors.textDim)),
        const SizedBox(height: 6),
        Wrap(spacing: 8, runSpacing: 4, children: [
          FilledButton.tonalIcon(
            onPressed: running ? null : () => live.syncNow(x),
            icon: const Icon(Icons.refresh, size: 18),
            label: Text(tr('다시 시도')),
          ),
          if (e.empty && dels.isNotEmpty)
            OutlinedButton(
              onPressed: running ? null : () => confirmEmptySourceSync(context, live, x),
              child: Text(tr('지울 목록 보고 결정')),
            ),
        ]),
      ]),
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
              // 67: 끝 폴더가 보이게 짧게 · 69: 길게 누르면 (오른쪽 클릭) 고치기 · 지우기
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onLongPressStart: (d) => _pairMenu(context, x, d.globalPosition),
                onSecondaryTapDown: (d) => _pairMenu(context, x, d.globalPosition),
                child: Tooltip(
                  // 길게 누르기는 메뉴에 (마우스를 올리면 전체 경로)
                  triggerMode: TooltipTriggerMode.manual,
                  message: '${vDisplay(x.source)}\n→ ${vDisplay(x.target)}',
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(shortPath(x.source), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
                    Text('→  ${shortPath(x.target)}', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
                  ]),
                ),
              ),
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
          // 42: 지우기를 아직 확인하지 않았고 지울 것이 있다 → 지우지 않고 맞추는 중. 목록을 보고 결정
          if (live != null && (live.toDelete[k]?.isNotEmpty ?? false))
            Padding(
              padding: const EdgeInsets.only(left: 32, top: 4),
              child: Wrap(spacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
                const Icon(Icons.warning_amber_rounded, size: 16, color: Colors.orangeAccent),
                Text(trf('대상에만 있는 {0}개를 지울지 확인이 필요합니다 (확인 전에는 지우지 않음)', [live.toDelete[k]!.length]),
                    style: const TextStyle(fontSize: 12, color: Colors.orangeAccent)),
                OutlinedButton(
                  onPressed: () => confirmLiveDeletes(context, live, x),
                  child: Text(tr('지울 목록 보고 결정')),
                ),
              ]),
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
                    style: TextStyle(fontSize: 12, color: live?.problems[k] != null ? Colors.redAccent : JjColors.textDim)),
              _DiskInfo(path: x.target),
            ]),
          ),
          // 68 · 70: 원본을 읽지 못함 / 원본이 비어 멈춤 - "맞출 것 없음" 대신 눈에 띄게, 할 일과 [다시 시도]
          if (live?.problems[k] case final prob?)
            Padding(padding: const EdgeInsets.only(left: 32, top: 8), child: _problemPanel(context, live!, x, prob))
          else
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
              onPressed: running ? null : () => _finalize(x),
              icon: const Icon(Icons.cleaning_services_outlined, size: 18),
              label: Text(tr('최종 정리')),
            ),
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
              tooltip: tr('고치기'),
              icon: const Icon(Icons.edit_outlined),
              onPressed: () => editLiveSyncPairDialog(context, c, x),
            ),
            IconButton(
              tooltip: tr('지우기'),
              icon: const Icon(Icons.delete_outline, color: JjColors.textDim),
              onPressed: () => removeLiveSyncPair(context, c, x),
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
                    title: Text('${vDisplay(x.source)}  →  ${vDisplay(x.target)}', maxLines: 2, overflow: TextOverflow.ellipsis),
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
