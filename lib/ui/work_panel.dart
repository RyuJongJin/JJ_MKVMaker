import 'package:flutter/material.dart';

import '../app/app_controller.dart';
import '../app/download_manager.dart';
import '../core/models.dart';
import '../services/downloader.dart';
import 'downloads_page.dart';
import 'theme.dart';
import '../l10n/tr.dart';

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
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _header(context),
          const Divider(height: 1),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
              children: [
                ..._jobs(),
                _title(trf('편집 목록 {0}개', [c.videos.length])),
                if (c.videos.isEmpty)
                  _Dim(tr('아직 없습니다. 영상을 다 받으면 자동으로 들어옵니다 (설정에서 변경).')),
                for (final v in c.videos) _VideoRow(v: v),
                if (downloads != null) ...[
                  const SizedBox(height: 12),
                  _title(
                    trf('다운로드 {0}개', [downloads!.tasks.length]),
                    action: TextButton(
                      onPressed: () => DownloadsPage.open(Navigator.of(context), downloads!),
                      child: Text(
                        tr('전체 목록'),
                        style: TextStyle(fontSize: 12),
                      ),
                    ),
                  ),
                  if (downloads!.tasks.isEmpty)
                    _Dim(tr('동영상 페이지에서 [다운로드] 를 누르세요.')),
                  for (final t in downloads!.tasks.reversed.take(30))
                    _DownloadRow(c: c, t: t),
                ],
              ],
            ),
          ),
        ],
      ),
    ),
  );

  Widget _header(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
    child: Row(
      children: [
        const Icon(Icons.dashboard_outlined, size: 18, color: JjColors.accent),
        const SizedBox(width: 6),
        Expanded(
          child: Text(tr('작업 현황'), style: TextStyle(fontWeight: FontWeight.w600)),
        ),
        IconButton(
          tooltip: tr('동영상 추가'),
          iconSize: 18,
          icon: const Icon(Icons.add),
          onPressed: c.pickVideos,
        ),
        IconButton(
          tooltip: c.busy ? tr('MKV 만들기 (대기열에 추가)') : tr('MKV 만들기'),
          iconSize: 18,
          icon: const Icon(Icons.play_arrow, color: JjColors.accent),
          onPressed: c.videos.isEmpty || c.ffmpegVersion == null
              ? null
              : c.buildAll,
        ),
        if (c.busy)
          IconButton(
            tooltip: tr('모든 작업 취소'),
            iconSize: 18,
            icon: const Icon(Icons.stop, color: JjColors.danger),
            onPressed: c.cancel,
          ),
        IconButton(
          tooltip: tr('MKV 화면으로 (전체 화면)'),
          iconSize: 18,
          icon: const Icon(Icons.open_in_full),
          onPressed: onOpenHome,
        ),
        IconButton(
          tooltip: tr('작업 현황 닫기'),
          iconSize: 18,
          icon: const Icon(Icons.close),
          onPressed: onClose,
        ),
      ],
    ),
  );

  List<Widget> _jobs() => [
    _title(tr('작업')),
    if (!c.busy)
      _Dim(tr('쉬는 중'))
    else ...[
      Text(
        '▶ ${c.currentJob ?? tr('작업 중')}',
        style: const TextStyle(fontSize: 12, color: JjColors.accent),
      ),
      for (final (i, j) in c.pendingJobs.indexed)
        Text(
          trf('{0}. {1}  (대기)', [i + 1, j]),
          style: const TextStyle(fontSize: 12, color: JjColors.textDim),
        ),
    ],
    const SizedBox(height: 12),
  ];

  Widget _title(String t, {Widget? action}) => Padding(
    padding: const EdgeInsets.only(bottom: 4),
    child: Row(
      children: [
        Expanded(
          child: Text(
            t,
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: JjColors.textDim,
            ),
          ),
        ),
        ?action,
      ],
    ),
  );
}

class _Dim extends StatelessWidget {
  final String text;
  const _Dim(this.text);
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Text(
      text,
      style: const TextStyle(fontSize: 12, color: JjColors.textDim),
    ),
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
                JobStatus.done => tr('MKV 완성'),
                JobStatus.failed => trf('실패: {0}', [v.message ?? '']),
                _ => trf('자막 {0}개', [v.subtitles.where((s) => s.enabled).length]),
              };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 6),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  v.fileName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12),
                ),
                if (v.status == JobStatus.running)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: LinearProgressIndicator(
                      value: v.progress <= 0 ? null : v.progress,
                      minHeight: 3,
                    ),
                  ),
                Text(
                  sub,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    color: v.status == JobStatus.failed
                        ? JjColors.danger
                        : color,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _DownloadRow extends StatelessWidget {
  final AppController c;
  final DownloadTask t;
  const _DownloadRow({required this.c, required this.t});

  @override
  Widget build(BuildContext context) {
    final files = t.state == DownloadState.done
        ? DownloadManager.videoFilesOf(t)
        : const <String>[];
    final inList =
        files.isNotEmpty &&
        files.every(
          (f) => c.videos.any((v) => v.path.toLowerCase() == f.toLowerCase()),
        );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  t.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12),
                ),
                const SizedBox(height: 2),
                if (t.state != DownloadState.cancelled)
                  DownloadProgressBar(t: t, height: 12),
              ],
            ),
          ),
          if (files.isNotEmpty)
            IconButton(
              tooltip: inList ? tr('편집 목록에 있음') : tr('편집 목록에 추가'),
              iconSize: 16,
              visualDensity: VisualDensity.compact,
              icon: Icon(
                inList ? Icons.playlist_add_check : Icons.playlist_add,
                color: inList ? JjColors.success : JjColors.accent,
              ),
              onPressed: inList ? null : () => c.addDownloaded(files),
            ),
        ],
      ),
    );
  }
}

/// 지금 하는 작업 + 대기 개수 (상단 바 · 브라우저에서 같이 씀)
class JobIndicator extends StatelessWidget {
  final AppController c;
  final bool compact;

  /// 돌아가는 표시만 (글은 마우스를 올리면)
  final bool iconOnly;
  const JobIndicator({
    super.key,
    required this.c,
    this.compact = false,
    this.iconOnly = false,
  });

  @override
  Widget build(BuildContext context) {
    if (!c.busy) return const SizedBox();
    final running = c.videos
        .where((v) => v.status == JobStatus.running)
        .toList();
    final p = running.isEmpty
        ? null
        : running.map((v) => v.progress).reduce((a, b) => a + b) /
              running.length;
    final wait = c.pendingJobs.length;
    return Tooltip(
      message: [
        trf('지금: {0}', [c.currentJob ?? '']),
        for (final v in running)
          '  · ${v.fileName} — ${v.phase ?? ''} ${(v.progress * 100).round()}%',
        if (wait > 0) trf('대기 {0}개:', [wait]),
        for (final j in c.pendingJobs) '  · $j',
      ].join('\n'),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              value: p == null || p == 0 ? null : p,
            ),
          ),
          if (!iconOnly) const SizedBox(width: 6),
          if (!iconOnly)
            ConstrainedBox(
              constraints: BoxConstraints(maxWidth: compact ? 160 : 240),
              child: Text(
                '${c.currentJob ?? tr('작업 중')}${p == null ? '' : ' ${(p * 100).round()}%'}${wait > 0 ? trf(' · 대기 {0}', [wait]) : ''}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12, color: JjColors.accent),
              ),
            ),
        ],
      ),
    );
  }
}
