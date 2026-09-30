import 'package:flutter/material.dart';

import '../app/app_controller.dart';
import '../app/download_manager.dart';
import '../core/models.dart';
import '../services/downloader.dart';
import 'downloads_page.dart';
import 'theme.dart';

/// 브라우저 오른쪽 "작업 현황" (화면 분할): 자막 · MKV 작업과 다운로드 진행을 보면서 인터넷을 볼 수 있게.
class WorkPanel extends StatelessWidget {
  final AppController c;
  final DownloadManager? downloads;
  final VoidCallback onClose;

  /// MKV (편집) 화면으로 돌아가기
  final VoidCallback onOpenHome;

  const WorkPanel({
    super.key,
    required this.c,
    required this.downloads,
    required this.onClose,
    required this.onOpenHome,
  });

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: Listenable.merge([c, ?downloads]),
        builder: (context, _) => Container(
          color: JjColors.panel,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            _header(context),
            const Divider(height: 1),
            Expanded(
              child: ListView(padding: const EdgeInsets.fromLTRB(12, 8, 12, 12), children: [
                ..._jobs(),
                _title('편집 목록 ${c.videos.length}개'),
                if (c.videos.isEmpty) const _Dim('아직 없습니다. 영상을 다 받으면 자동으로 들어옵니다 (설정에서 변경).'),
                for (final v in c.videos) _VideoRow(v: v),
                if (downloads != null) ...[
                  const SizedBox(height: 12),
                  _title('다운로드 ${downloads!.tasks.length}개',
                      action: TextButton(
                        onPressed: () => Navigator.push(
                            context, MaterialPageRoute<void>(builder: (_) => DownloadsPage(d: downloads!))),
                        child: const Text('전체 목록', style: TextStyle(fontSize: 12)),
                      )),
                  if (downloads!.tasks.isEmpty) const _Dim('동영상 페이지에서 [다운로드] 를 누르세요.'),
                  for (final t in downloads!.tasks.reversed.take(30)) _DownloadRow(c: c, t: t),
                ],
              ]),
            ),
          ]),
        ),
      );

  Widget _header(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
        child: Row(children: [
          const Icon(Icons.dashboard_outlined, size: 18, color: JjColors.accent),
          const SizedBox(width: 6),
          const Expanded(child: Text('작업 현황', style: TextStyle(fontWeight: FontWeight.w600))),
          IconButton(tooltip: '동영상 추가', iconSize: 18, icon: const Icon(Icons.add), onPressed: c.pickVideos),
          IconButton(
            tooltip: c.busy ? 'MKV 만들기 (대기열에 추가)' : 'MKV 만들기',
            iconSize: 18,
            icon: const Icon(Icons.play_arrow, color: JjColors.accent),
            onPressed: c.videos.isEmpty || c.ffmpegVersion == null ? null : c.buildAll,
          ),
          if (c.busy)
            IconButton(
              tooltip: '모든 작업 취소',
              iconSize: 18,
              icon: const Icon(Icons.stop, color: JjColors.danger),
              onPressed: c.cancel,
            ),
          IconButton(
            tooltip: 'MKV 화면으로 (전체 화면)',
            iconSize: 18,
            icon: const Icon(Icons.open_in_full),
            onPressed: onOpenHome,
          ),
          IconButton(tooltip: '작업 현황 닫기', iconSize: 18, icon: const Icon(Icons.close), onPressed: onClose),
        ]),
      );

  List<Widget> _jobs() => [
        _title('작업'),
        if (!c.busy)
          const _Dim('쉬는 중')
        else ...[
          Text('▶ ${c.currentJob ?? '작업 중'}', style: const TextStyle(fontSize: 12, color: JjColors.accent)),
          for (final (i, j) in c.pendingJobs.indexed)
            Text('${i + 1}. $j  (대기)', style: const TextStyle(fontSize: 12, color: JjColors.textDim)),
        ],
        const SizedBox(height: 12),
      ];

  Widget _title(String t, {Widget? action}) => Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Row(children: [
          Expanded(
              child: Text(t,
                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: JjColors.textDim))),
          ?action,
        ]),
      );
}

class _Dim extends StatelessWidget {
  final String text;
  const _Dim(this.text);
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Text(text, style: const TextStyle(fontSize: 12, color: JjColors.textDim)),
      );
}

class _VideoRow extends StatelessWidget {
  final VideoItem v;
  const _VideoRow({required this.v});

  @override
  Widget build(BuildContext context) {
    final (icon, color) = switch (v.status) {
      JobStatus.ready => (Icons.movie_outlined, JjColors.textDim),
      JobStatus.running => (Icons.autorenew, JjColors.accent),
      JobStatus.done => (Icons.check_circle, JjColors.success),
      JobStatus.failed => (Icons.error, JjColors.danger),
    };
    final sub = v.status == JobStatus.running
        ? '${v.phase ?? ''} ${(v.progress * 100).round()}%'
        : v.phase ??
            switch (v.status) {
              JobStatus.done => 'MKV 완성',
              JobStatus.failed => '실패: ${v.message ?? ''}',
              _ => '자막 ${v.subtitles.where((s) => s.enabled).length}개',
            };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 6),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(v.fileName, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12)),
            if (v.status == JobStatus.running)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: LinearProgressIndicator(value: v.progress <= 0 ? null : v.progress, minHeight: 3),
              ),
            Text(sub,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11, color: v.status == JobStatus.failed ? JjColors.danger : color)),
          ]),
        ),
      ]),
    );
  }
}

class _DownloadRow extends StatelessWidget {
  final AppController c;
  final DownloadTask t;
  const _DownloadRow({required this.c, required this.t});

  @override
  Widget build(BuildContext context) {
    final files = t.state == DownloadState.done ? DownloadManager.videoFilesOf(t) : const <String>[];
    final inList =
        files.isNotEmpty && files.every((f) => c.videos.any((v) => v.path.toLowerCase() == f.toLowerCase()));
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(t.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12)),
            const SizedBox(height: 2),
            if (t.state != DownloadState.cancelled) DownloadProgressBar(t: t, height: 12),
          ]),
        ),
        if (files.isNotEmpty)
          IconButton(
            tooltip: inList ? '편집 목록에 있음' : '편집 목록에 추가',
            iconSize: 16,
            visualDensity: VisualDensity.compact,
            icon: Icon(inList ? Icons.playlist_add_check : Icons.playlist_add,
                color: inList ? JjColors.success : JjColors.accent),
            onPressed: inList ? null : () => c.addDownloaded(files),
          ),
      ]),
    );
  }
}

/// 지금 하는 작업 + 대기 개수 (상단 바 · 브라우저에서 같이 씀)
class JobIndicator extends StatelessWidget {
  final AppController c;
  final bool compact;
  const JobIndicator({super.key, required this.c, this.compact = false});

  @override
  Widget build(BuildContext context) {
    if (!c.busy) return const SizedBox();
    final running = c.videos.where((v) => v.status == JobStatus.running).toList();
    final p = running.isEmpty ? null : running.map((v) => v.progress).reduce((a, b) => a + b) / running.length;
    final wait = c.pendingJobs.length;
    return Tooltip(
      message: [
        '지금: ${c.currentJob ?? ''}',
        for (final v in running) '  · ${v.fileName} — ${v.phase ?? ''} ${(v.progress * 100).round()}%',
        if (wait > 0) '대기 $wait개:',
        for (final j in c.pendingJobs) '  · $j',
      ].join('\n'),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2, value: p == null || p == 0 ? null : p)),
        const SizedBox(width: 6),
        ConstrainedBox(
          constraints: BoxConstraints(maxWidth: compact ? 160 : 240),
          child: Text(
            '${c.currentJob ?? '작업 중'}${p == null ? '' : ' ${(p * 100).round()}%'}${wait > 0 ? ' · 대기 $wait' : ''}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12, color: JjColors.accent),
          ),
        ),
      ]),
    );
  }
}
