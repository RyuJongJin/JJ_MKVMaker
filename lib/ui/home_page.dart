import 'dart:io';

import 'package:flutter/material.dart';

import '../app/app_controller.dart';
import '../app/bookmarks_controller.dart';
import '../app/download_manager.dart';
import '../core/charset_detector.dart';
import '../core/encode_options.dart';
import '../core/languages.dart';
import '../core/models.dart';
import '../core/output_paths.dart';
import 'ai_dialog.dart';
import 'app_actions.dart';
import 'downloads_page.dart';
import 'player_page.dart';
import 'subtitle_editor_page.dart';
import 'subtitle_search_dialog.dart';
import 'theme.dart';
import 'translate_dialog.dart';
import 'work_panel.dart';

class HomePage extends StatelessWidget {
  final AppController c;

  /// 다운로드 (없으면 "다운로딩" 상자 숨김)
  final DownloadManager? downloads;

  /// 종료 버튼 (없으면 숨김)
  final VoidCallback? onExit;

  /// 즐겨찾기 (없으면 브라우저 버튼 숨김)
  final BookmarksController? bookmarks;

  const HomePage({super.key, required this.c, this.downloads, this.onExit, this.bookmarks});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) => Scaffold(
        // 끌어다 놓기는 앱 전체에서 받는다 (ui/app_drop.dart 의 AppDropArea - 어느 화면에서 놓아도 이 목록에 추가)
        body: SizedBox(
          child: Column(
          children: [
            _TopBar(c: c, downloads: downloads, onExit: onExit, bookmarks: bookmarks),
            const Divider(height: 1),
            _EncodeBar(c: c),
            const Divider(height: 1),
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(width: 320, child: _VideoList(c: c)),
                  const VerticalDivider(width: 1),
                  Expanded(
                    child: c.selected == null
                        ? const _EmptyHint()
                        : _VideoDetail(c: c, v: c.selected!),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            if (c.settings.showLog)
              SizedBox(
                // 화면이 낮은 기기 (휴대폰 가로) 에서 목록 · 자세히 보기를 가리지 않도록 화면 높이에 맞춘다
                height: (MediaQuery.sizeOf(context).height * 0.22).clamp(80.0, 140.0),
                child: _LogPanel(
                  logs: c.logs,
                  onClose: () => c.updateSettings((s) => s.showLog = false),
                ),
              )
            else
              _LogStrip(
                last: c.logs.isEmpty ? '' : c.logs.last,
                onOpen: () => c.updateSettings((s) => s.showLog = true),
              ),
          ],
        ),
        ),
      ),
    );
  }
}

// ───────── 상단 바 ─────────

class _TopBar extends StatelessWidget {
  final AppController c;
  final DownloadManager? downloads;
  final VoidCallback? onExit;
  final BookmarksController? bookmarks;
  const _TopBar({required this.c, this.downloads, this.onExit, this.bookmarks});

  /// 고른 동영상이 없을 때: 목록 전체를 만들지 묻는다
  /// 보고 있는 동영상의 결과 폴더 (jj_mkv) 를 탐색기 · 파일 앱으로. 아직 없으면 알린다.
  Future<void> _openOutput(BuildContext context) async {
    final v = c.selected;
    if (v == null) return;
    final dir = outputDirFor(v.path);
    if (!await Directory(dir).exists()) {
      if (context.mounted) {
        ScaffoldMessenger.maybeOf(context)
            ?.showSnackBar(SnackBar(content: Text('아직 만든 MKV · 자막이 없습니다: $dir')));
      }
      return;
    }
    await c.services.shell.revealFile(dir);
  }

  Future<void> _confirmBuildAll(BuildContext context) async {
    final todo = c.videos.where((v) => v.status != JobStatus.done).length;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('MKV 만들기'),
        content: Text('선택한 동영상이 없습니다.\n목록 전체 ${c.videos.length}개 '
            '(이미 만든 것을 빼면 $todo개) 를 MKV 로 만들까요?\n\n'
            '일부만 만들려면 취소하고 동영상 목록에서 체크하세요.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('취소')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('전체 만들기')),
        ],
      ),
    );
    if (ok == true) await c.buildAll();
  }

  static String _batchHint(AppController c, String what) => c.checked.isEmpty
      ? '지금 보고 있는 동영상의 $what (여러 개는 목록에서 체크)'
      : '체크한 동영상 ${c.checked.length}개의 $what';

  @override
  Widget build(BuildContext context) {
    final canBuild = c.videos.isNotEmpty && c.ffmpegVersion != null;
    // 일괄 작업 대상: 체크한 동영상, 없으면 지금 보고 있는 한 개
    final batch = c.batchTargets;
    final canBatch = batch.isNotEmpty && c.ffmpegVersion != null;
    final count = c.checked.isEmpty ? '' : ' (${c.checked.length})';
    // 창 너비에 맞춰 차례로 줄인다: 제목 글 → 왼쪽 버튼을 아이콘만 → 재생 · 브라우저를 아이콘만 → CPU · MEM 숨김.
    // (오른쪽의 화면 크기 · 환경 설정 · 종료 버튼은 어떤 너비에서도 밀려나지 않게)
    return LayoutBuilder(builder: (context, box) {
      final hasAi = c.aiAvailable;
      final hasPlayer = c.services.createMediaPlayer != null;
      var title = true, leftText = true, rightText = true, usage = c.usage != null, jobText = true;
      // 아주 좁을 때: 다운로드 상자 숨김 (왼쪽 공통 버튼으로 열 수 있음) → MKV 만들기도 아이콘만
      var dlBox = downloads != null, mkvText = true;
      // 각 부분의 너비 (실제 화면에서 잰 값)
      double need() =>
          8 + appBarRightPadding + AppNavButtons.width + 8 + (title ? 126 : 0) + 24 +
          (leftText ? 153 + (hasAi ? 161 + 298 : 0) : 40 + (hasAi ? 96 : 0)) + 8 +
          (c.busy ? (jobText ? 350 : 60) : 0) +
          (hasPlayer ? (rightText ? 201 : 48) : 0) +
          (mkvText ? 166 + (c.busy && jobText ? 60 : 0) : 48) +
          (rightText ? 166 : 48) + // 결과 폴더
          (dlBox ? 162 : 0) +
          (usage ? 220 : 0) + 96 + 92 +
          (c.checked.isEmpty ? 0 : 3 * 26) +
          8; // 여유
      final w = box.maxWidth;
      if (need() > w) title = false;
      if (need() > w) jobText = false;
      if (need() > w) leftText = false;
      if (need() > w) rightText = false;
      if (need() > w) usage = false;
      if (need() > w) dlBox = false;
      if (need() > w) mkvText = false;

      // 글이 있는 버튼, 또는 (좁을 때) 아이콘만 있는 버튼
      Widget action(IconData icon, String label, VoidCallback? onPressed,
          {required bool text, required String tip, Color? color}) {
        return Tooltip(
          message: tip,
          child: text
              ? OutlinedButton.icon(
                  onPressed: onPressed, icon: Icon(icon, size: 18, color: color), label: Text(label))
              : IconButton.outlined(
                  onPressed: onPressed,
                  icon: Icon(icon, size: 20, color: onPressed == null ? null : color),
                  style: IconButton.styleFrom(
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      side: const BorderSide(color: JjColors.border))),
        );
      }

      return Container(
        height: appBarHeight,
        color: JjColors.panel,
        padding: const EdgeInsets.only(left: 8, right: appBarRightPadding),
        child: Row(
          children: [
            // 모든 화면 공통: [JJ 홈] [MKV 화면] [뒤로] [다운로드 목록]
            const AppNavButtons(),
            const SizedBox(width: 8),
            if (title) const Text('JJ_MKVMaker', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
            const SizedBox(width: 24),
            // 왼쪽 묶음: 그래도 모자라면 옆으로 밀어 볼 수 있게
            Expanded(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(children: [
                  action(Icons.add, '동영상 추가', c.pickVideos,
                      text: leftText, tip: '동영상 추가 (탐색기에서 끌어다 놓아도 됩니다)'),
                  if (hasAi) ...[
                    const SizedBox(width: 8),
                    action(Icons.auto_awesome, '자막 만들기$count',
                        canBatch ? () => showAiDialog(context, c, batch.first, targets: batch) : null,
                        text: leftText, tip: '자막 만들기: ${_batchHint(c, 'AI 자막을 만듭니다')}'),
                    const SizedBox(width: 8),
                    action(
                        Icons.auto_mode,
                        '자막 만들기 & MKV 만들기$count',
                        canBatch
                            ? () => showAiDialog(context, c, batch.first, targets: batch, thenBuild: true)
                            : null,
                        text: leftText,
                        tip: '자막 만들기 & MKV 만들기: ${_batchHint(c, 'AI 자막을 만들고 이어서 MKV 로 만듭니다')}'),
                  ],
                ]),
              ),
            ),
            const SizedBox(width: 8),
            if (c.busy) ...[
              JobIndicator(c: c, compact: !jobText, iconOnly: !jobText),
              const SizedBox(width: 8),
              action(Icons.stop, '취소', c.cancel, text: jobText, tip: '작업 취소', color: JjColors.danger),
              const SizedBox(width: 8),
            ],
            // 체크한 동영상을 목록에 보이는 순서대로 이어서 재생 (체크가 없으면 보고 있는 한 개)
            if (hasPlayer) ...[
              action(
                  Icons.playlist_play,
                  '선택한 파일 재생$count',
                  batch.isEmpty
                      ? null
                      : () => playFiles(context, c, [for (final v in batch) v.path], keepOrder: true),
                  text: rightText,
                  tip: c.checked.isEmpty
                      ? '선택한 파일 재생: 지금 보고 있는 동영상 (여러 개는 목록에서 체크)'
                      : '선택한 파일 재생: 체크한 동영상 ${c.checked.length}개를 목록 순서대로 이어서'),
              const SizedBox(width: 8),
            ],
            // 체크한 동영상이 있으면 그것만, 없으면 "전체 만들기 / 취소" 를 묻는다
            Tooltip(
              message: 'MKV 만들기$count',
              child: mkvText
                  ? FilledButton.icon(
                      onPressed: !canBuild ? null : (c.checked.isEmpty ? () => _confirmBuildAll(context) : () => c.buildVideos(batch)),
                      icon: Icon(c.busy ? Icons.playlist_add : Icons.play_arrow, size: 20),
                      label: Text('MKV 만들기$count${c.busy && jobText ? ' (대기열)' : ''}'),
                    )
                  : IconButton.filled(
                      onPressed: !canBuild ? null : (c.checked.isEmpty ? () => _confirmBuildAll(context) : () => c.buildVideos(batch)),
                      icon: Icon(c.busy ? Icons.playlist_add : Icons.play_arrow, size: 20),
                    ),
            ),
            // 만든 MKV 가 있는 폴더 (jj_mkv). 웹 브라우저 버튼은 왼쪽 공통 버튼으로 옮김
            const SizedBox(width: 8),
            action(Icons.folder_special_outlined, '결과 폴더', c.selected == null ? null : () => _openOutput(context),
                text: rightText,
                tip: c.selected == null
                    ? '결과 폴더 열기 (동영상을 고르세요)'
                    : '결과 폴더 열기: ${outputDirFor(c.selected!.path)}'),
            if (dlBox) ...[
              const SizedBox(width: 12),
              _DownloadBox(d: downloads!),
            ],
            // 화면 크기 · 환경 설정 · 종료: 모든 화면에서 같은 자리
            AppActions(c: c, onExit: onExit, showUsage: usage),
          ],
        ),
      );
    });
  }
}

/// 상단 "다운로딩" 상자: 누르면 다운로드 목록
class _DownloadBox extends StatelessWidget {
  final DownloadManager d;
  const _DownloadBox({required this.d});

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: d,
        builder: (context, _) {
          final n = d.downloadingCount;
          final p = d.overallProgress;
          return InkWell(
            borderRadius: BorderRadius.circular(6),
            onTap: () => DownloadsPage.open(Navigator.of(context), d),
            child: Container(
              width: 150,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                border: Border.all(color: n > 0 ? JjColors.accent : JjColors.border),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Icon(Icons.downloading, size: 16,
                        color: n > 0 ? JjColors.accent : JjColors.textDim),
                    const SizedBox(width: 6),
                    Text(
                        n > 0
                            ? '다운로딩 $n${p == null ? '' : ' · ${(p * 100).toStringAsFixed(0)}%'}'
                            : '다운로드 ${d.tasks.length}',
                        style: const TextStyle(fontSize: 12)),
                  ]),
                  if (n > 0) ...[
                    const SizedBox(height: 4),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(2),
                      child: LinearProgressIndicator(
                          value: p, minHeight: 4, backgroundColor: JjColors.panelHigh),
                    ),
                  ],
                ],
              ),
            ),
          );
        },
      );
}

// ───────── 화면 크기 · 코덱 · 화질 ─────────

class _EncodeBar extends StatelessWidget {
  final AppController c;
  const _EncodeBar({required this.c});

  @override
  Widget build(BuildContext context) {
    final s = c.encode;
    final locked = c.busy;
    final up = c.upscaleCount;

    Widget label(String t) => Padding(
          padding: const EdgeInsets.only(right: 6),
          child: Text(t, style: const TextStyle(fontSize: 12, color: JjColors.textDim)),
        );
    Widget drop<T>(T value, List<T> items, String Function(T) text,
            ValueChanged<T> onChanged, {bool Function(T)? enabled}) =>
        DropdownButton<T>(
          value: value,
          isDense: true,
          underline: const SizedBox(),
          style: const TextStyle(fontSize: 13, color: JjColors.text),
          items: [
            for (final i in items)
              DropdownMenuItem(
                value: i,
                enabled: enabled?.call(i) ?? true,
                child: Text(
                  text(i) + ((enabled?.call(i) ?? true) ? '' : ' (사용 불가)'),
                  style: TextStyle(
                      color: (enabled?.call(i) ?? true) ? null : JjColors.textDim),
                ),
              ),
          ],
          onChanged: locked ? null : (v) => onChanged(v as T),
        );

    return Container(
      height: 44,
      color: JjColors.panel,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(children: [
        label('화면 크기'),
        drop(s.resolution, ResolutionChoice.values, (r) => r.label, c.setResolution),
        const SizedBox(width: 20),
        label('코덱'),
        drop(s.codec, VideoCodecChoice.values, (v) => v.label, c.setCodec,
            enabled: c.isCodecAvailable),
        const SizedBox(width: 20),
        if (s.reencode) ...[
          label('화질'),
          drop(s.quality, QualityChoice.values, (q) => q.label, c.setQuality),
          const SizedBox(width: 20),
        ],
        Expanded(
          child: Text(
            !s.reencode
                ? '영상·음성을 그대로 복사합니다 (빠름, 화질 손실 없음)'
                : '영상을 다시 인코딩합니다 (시간이 오래 걸림, 음성은 그대로)'
                    '${up > 0 ? ' · ⚠ $up개는 원본보다 커서 화질 향상 없이 용량만 늘어납니다' : ''}',
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
                fontSize: 12, color: up > 0 && s.reencode ? JjColors.danger : JjColors.textDim),
          ),
        ),
      ]),
    );
  }
}

// ───────── 왼쪽: 동영상 목록 ─────────

class _VideoList extends StatelessWidget {
  final AppController c;
  const _VideoList({required this.c});

  /// 정렬 아이콘: 지금 적용된 정렬은 강조색 + 방향 화살표
  Widget _sortButton(String by, IconData icon, String name) {
    final on = c.sortedBy == by;
    return IconButton(
      tooltip: '$name 순으로 정렬'
          '${on ? (c.sortAscending ? ' (지금: 오름차순 · 다시 누르면 내림차순)' : ' (지금: 내림차순 · 다시 누르면 오름차순)') : ''}',
      iconSize: 18,
      visualDensity: VisualDensity.compact,
      onPressed: c.videos.length < 2 ? null : () => c.sortVideos(by),
      icon: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, color: on ? JjColors.accent : JjColors.textDim),
        if (on)
          Icon(c.sortAscending ? Icons.arrow_upward : Icons.arrow_downward, size: 12, color: JjColors.accent),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: JjColors.panel,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 전체 선택 · 선택 개수 · 선택 제거 · 모두 지우기
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 6, 4, 2),
            child: Row(children: [
              Checkbox(
                visualDensity: VisualDensity.compact,
                tristate: true,
                value: c.videos.isEmpty || c.checked.isEmpty
                    ? false
                    : (c.checked.length == c.videos.length ? true : null),
                onChanged: c.videos.isEmpty ? null : (_) => c.toggleAllChecked(),
              ),
              Expanded(
                child: InkWell(
                  onTap: c.videos.isEmpty ? null : c.toggleAllChecked,
                  child: Text(
                      c.checked.isEmpty
                          ? '동영상 ${c.videos.length}개 · 전체 선택'
                          : '선택 ${c.checked.length} / ${c.videos.length}개',
                      style: const TextStyle(color: JjColors.textDim, fontSize: 12)),
                ),
              ),
              // 정렬: 같은 것을 다시 누르면 반대 순서
              _sortButton('name', Icons.sort_by_alpha, '파일 이름'),
              _sortButton('date', Icons.calendar_month, '날짜'),
              if (c.checked.isNotEmpty)
                IconButton(
                  tooltip: '선택한 동영상을 목록에서 제거',
                  iconSize: 18,
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.playlist_remove, color: JjColors.textDim),
                  onPressed: c.removeChecked,
                ),
              IconButton(
                tooltip: '모두 지우기',
                iconSize: 18,
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.clear_all, color: JjColors.textDim),
                onPressed: c.busy || c.videos.isEmpty ? null : c.clearVideos,
              ),
            ]),
          ),
          Expanded(
            child: ListView.builder(
              itemCount: c.videos.length,
              itemBuilder: (_, i) => _VideoTile(c: c, v: c.videos[i]),
            ),
          ),
        ],
      ),
    );
  }
}

class _VideoTile extends StatelessWidget {
  final AppController c;
  final VideoItem v;
  const _VideoTile({required this.c, required this.v});

  Future<void> _menu(BuildContext context, Offset global) async {
    c.select(v);
    final busy = v.status == JobStatus.running;
    PopupMenuItem<String> item(String id, IconData icon, String label, {bool enabled = true}) => PopupMenuItem(
          value: id,
          enabled: enabled,
          height: 36,
          child: Row(children: [
            Icon(icon, size: 18, color: enabled ? JjColors.text : JjColors.textDim),
            const SizedBox(width: 10),
            Text(label, style: const TextStyle(fontSize: 13)),
          ]),
        );
    // 화면 크기 배율이 걸려 있어도 누른 자리에 뜨도록 메뉴가 그려질 곳 기준으로 바꾼다
    final overlay = Overlay.of(context).context.findRenderObject()! as RenderBox;
    final at = overlay.globalToLocal(global);
    final pick = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(at.dx, at.dy, overlay.size.width - at.dx, overlay.size.height - at.dy),
      items: [
        item('folder', Icons.folder_open, '대상 폴더 열기'),
        if (c.services.createMediaPlayer != null) item('play', Icons.play_arrow, '재생'),
        const PopupMenuDivider(),
        if (c.aiAvailable)
          item('ai', Icons.auto_awesome, 'AI 자막 만들기', enabled: !busy && c.ffmpegVersion != null),
        if (c.subtitleProvider != null)
          item('search', Icons.travel_explore, '인터넷 자막 찾기', enabled: !busy),
        item('subtitle', Icons.subtitles_outlined, '자막 파일 추가', enabled: !busy),
        const PopupMenuDivider(),
        item('remove', Icons.close, '삭제 (목록에서 제거)', enabled: !busy),
      ],
    );
    if (pick == null || !context.mounted) return;
    switch (pick) {
      case 'folder':
        await c.services.shell.revealFile(v.path);
      case 'play':
        await playFiles(context, c, [v.path]);
      case 'ai':
        await showAiDialog(context, c, v, targets: [v]);
      case 'search':
        await showSubtitleSearch(context, c, v);
      case 'subtitle':
        await c.pickSubtitlesFor(v);
      case 'remove':
        c.removeVideo(v);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isSel = c.selected == v;
    final subs = v.subtitles.where((s) => s.enabled).length;
    return InkWell(
      onTap: () => c.select(v),
      onDoubleTap: () => playFiles(context, c, [v.path]),
      // 오른쪽 클릭: 이 동영상으로 할 수 있는 일
      onSecondaryTapDown: (d) => _menu(context, d.globalPosition),
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        padding: const EdgeInsets.fromLTRB(2, 10, 4, 10),
        decoration: BoxDecoration(
          color: isSel ? JjColors.panelHigh : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
              color: isSel ? JjColors.accent.withValues(alpha: 0.6) : Colors.transparent),
        ),
        child: Row(
          children: [
            // 체크: 여러 개를 골라 일괄 작업 (줄을 누르면 지금처럼 한 개 보기)
            Checkbox(
              visualDensity: VisualDensity.compact,
              value: c.checked.contains(v),
              onChanged: (_) => c.toggleChecked(v),
            ),
            _StatusIcon(v.status),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(v.fileName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 13)),
                  const SizedBox(height: 4),
                  if (v.status == JobStatus.running) ...[
                    LinearProgressIndicator(value: v.progress, minHeight: 3),
                    if (v.phase != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 3),
                        child: Text(v.phase!,
                            style: const TextStyle(fontSize: 11, color: JjColors.accent)),
                      ),
                  ] else if (v.phase != null)
                    Text(v.phase!, style: const TextStyle(fontSize: 11, color: JjColors.textDim))
                  else
                    Text(
                      v.status == JobStatus.failed ? '실패' : '자막 $subs개',
                      style: TextStyle(
                          fontSize: 11,
                          color: v.status == JobStatus.failed
                              ? JjColors.danger
                              : JjColors.textDim),
                    ),
                ],
              ),
            ),
            if (v.status == JobStatus.done || v.status == JobStatus.failed)
              IconButton(
                tooltip: '다시 만들기 대기로',
                iconSize: 16,
                onPressed: () => c.resetStatus(v),
                icon: const Icon(Icons.refresh, color: JjColors.textDim),
              ),
            IconButton(
              tooltip: '목록에서 제거',
              iconSize: 16,
              onPressed: v.status == JobStatus.running ? null : () => c.removeVideo(v),
              icon: const Icon(Icons.close, color: JjColors.textDim),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusIcon extends StatelessWidget {
  final JobStatus s;
  const _StatusIcon(this.s);

  @override
  Widget build(BuildContext context) => switch (s) {
        JobStatus.ready =>
          const Icon(Icons.movie_outlined, size: 20, color: JjColors.textDim),
        JobStatus.running =>
          const Icon(Icons.autorenew, size: 20, color: JjColors.accent),
        JobStatus.done =>
          const Icon(Icons.check_circle, size: 20, color: JjColors.success),
        JobStatus.failed =>
          const Icon(Icons.error, size: 20, color: JjColors.danger),
      };
}

// ───────── 오른쪽: 선택한 동영상 ─────────

class _EmptyHint extends StatelessWidget {
  const _EmptyHint();

  @override
  Widget build(BuildContext context) => const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.video_library_outlined, size: 56, color: JjColors.textDim),
            SizedBox(height: 12),
            Text('"동영상 추가" 로 파일을 선택하세요',
                style: TextStyle(color: JjColors.textDim)),
            SizedBox(height: 4),
            Text('같은 폴더의 자막은 자동으로 추가됩니다',
                style: TextStyle(color: JjColors.textDim, fontSize: 12)),
          ],
        ),
      );
}

class _VideoDetail extends StatelessWidget {
  final AppController c;
  final VideoItem v;
  const _VideoDetail({required this.c, required this.v});

  @override
  Widget build(BuildContext context) {
    final info = v.info;
    final video = info?.ofType('video').firstOrNull;
    final audioCount = info?.ofType('audio').length ?? 0;
    // 이 동영상을 처리하는 중일 때만 잠금 (다른 작업 중이면 대기열에 넣는다)
    final locked = v.status == JobStatus.running;

    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Row(children: [
          Expanded(
            child: Text(v.fileName,
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
          ),
          if (c.services.createMediaPlayer != null) ...[
            const SizedBox(width: 8),
            FilledButton.icon(
              onPressed: () => playFiles(context, c, [v.path]),
              icon: const Icon(Icons.play_arrow, size: 18),
              label: const Text('재생'),
            ),
          ],
          const SizedBox(width: 8),
          OutlinedButton.icon(
            onPressed: () => c.services.shell.revealFile(v.path),
            icon: const Icon(Icons.folder_open, size: 18),
            label: const Text('폴더 열기'),
          ),
        ]),
        const SizedBox(height: 4),
        SelectableText(v.path,
            style: const TextStyle(color: JjColors.textDim, fontSize: 12)),
        const SizedBox(height: 12),
        Wrap(spacing: 8, runSpacing: 8, children: [
          if (info?.duration != null) _Chip('길이 ${_fmt(info!.duration!)}'),
          if (video != null) ...[
            if (video.width != null) _Chip('${video.width}×${video.height}'),
            _Chip('영상 ${video.codec}'),
          ],
          _Chip('음성 $audioCount개'),
        ]),
        if (v.message != null) ...[
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: JjColors.danger.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(6),
            ),
            child: SelectableText(v.message!,
                style: const TextStyle(color: JjColors.danger, fontSize: 12)),
          ),
        ],
        const SizedBox(height: 24),
        Row(children: [
          const Text('자막',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
          const Spacer(),
          if (c.aiAvailable) ...[
            FilledButton.icon(
              onPressed: locked || c.ffmpegVersion == null ? null : () => showAiDialog(context, c, v),
              icon: const Icon(Icons.auto_awesome, size: 18),
              label: const Text('AI 자막 만들기'),
            ),
            const SizedBox(width: 8),
          ],
          if (c.subtitleProvider != null) ...[
            OutlinedButton.icon(
              onPressed: locked ? null : () => showSubtitleSearch(context, c, v),
              icon: const Icon(Icons.travel_explore, size: 18),
              label: const Text('인터넷 자막 찾기'),
            ),
            const SizedBox(width: 8),
          ],
          OutlinedButton.icon(
            onPressed: locked ? null : () => c.pickSubtitlesFor(v),
            icon: const Icon(Icons.subtitles_outlined, size: 18),
            label: const Text('자막 파일 추가'),
          ),
        ]),
        const SizedBox(height: 8),
        if (v.subtitles.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: Text('자막이 없습니다.', style: TextStyle(color: JjColors.textDim)),
          ),
        for (final s in v.subtitles)
          _SubtitleRow(c: c, v: v, s: s, locked: locked),
        const SizedBox(height: 24),
        Text('출력: ${outputMkvPath(v.path)}',
            style: const TextStyle(color: JjColors.textDim, fontSize: 12)),
      ],
    );
  }

  static String _fmt(Duration d) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.inHours}:${two(d.inMinutes % 60)}:${two(d.inSeconds % 60)}';
  }
}

class _Chip extends StatelessWidget {
  final String text;
  const _Chip(this.text);

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: JjColors.panelHigh,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(text, style: const TextStyle(fontSize: 12)),
      );
}

class _SubtitleRow extends StatelessWidget {
  final AppController c;
  final VideoItem v;
  final SubtitleEntry s;
  final bool locked;
  const _SubtitleRow(
      {required this.c, required this.v, required this.s, required this.locked});

  @override
  Widget build(BuildContext context) {
    final embedded = s.kind == SubtitleKind.embedded;
    final off = !s.enabled;
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: JjColors.panel,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: JjColors.border),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: (embedded ? JjColors.textDim : JjColors.accent)
                  .withValues(alpha: 0.18),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(embedded ? '내장' : '외부',
                style: TextStyle(
                    fontSize: 11,
                    color: embedded ? JjColors.textDim : JjColors.accent)),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              s.displayName,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13,
                color: off ? JjColors.textDim : JjColors.text,
                decoration: off ? TextDecoration.lineThrough : null,
              ),
            ),
          ),
          const SizedBox(width: 8),
          _LanguageDropdown(
            value: s.language,
            onChanged: locked || off ? null : (l) => c.setLanguage(s, l),
          ),
          if (!embedded) ...[
            const SizedBox(width: 8),
            _CharsetDropdown(
              value: s.charset ?? 'UTF-8',
              onChanged: locked ? null : (cs) => c.setCharset(s, cs),
            ),
          ],
          const SizedBox(width: 4),
          IconButton(
            tooltip: c.canEdit(s) ? '내용 편집 · 문자셋 변환' : '이미지 자막은 편집할 수 없습니다',
            iconSize: 18,
            onPressed: locked || off || !c.canEdit(s)
                ? null
                : () => openSubtitleEditor(context, c, v, s),
            icon: const Icon(Icons.edit_note, color: JjColors.accent),
          ),
          if (c.services.createTranslator != null)
            IconButton(
              tooltip: c.canEdit(s) ? '다른 언어로 번역 (AI · 이 ${Platform.isAndroid ? '기기' : 'PC'} 에서)' : '이미지 자막은 번역할 수 없습니다',
              iconSize: 18,
              onPressed: locked || off || !c.canEdit(s) ? null : () => showTranslateDialog(context, c, v, s),
              icon: const Icon(Icons.translate, color: JjColors.accent),
            ),
          IconButton(
            tooltip: embedded ? (off ? '되살리기' : '삭제 (출력에서 제외)') : '목록에서 제거',
            iconSize: 18,
            onPressed: locked ? null : () => c.removeSubtitle(v, s),
            icon: Icon(
              embedded && off ? Icons.undo : Icons.delete_outline,
              color: JjColors.textDim,
            ),
          ),
        ],
      ),
    );
  }
}

class _LanguageDropdown extends StatelessWidget {
  final Language value;
  final ValueChanged<Language>? onChanged;
  const _LanguageDropdown({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final items = [undetermined, ...languages];
    return DropdownButton<Language>(
      value: items.contains(value) ? value : undetermined,
      isDense: true,
      underline: const SizedBox(),
      style: const TextStyle(fontSize: 12, color: JjColors.text),
      items: [
        for (final l in items)
          DropdownMenuItem(
            value: l,
            child: Text(l == undetermined ? '언어: 미지정' : '${l.name} (${l.code})'),
          ),
      ],
      onChanged: onChanged == null ? null : (l) => onChanged!(l!),
    );
  }
}

class _CharsetDropdown extends StatelessWidget {
  final String value;
  final ValueChanged<String>? onChanged;
  const _CharsetDropdown({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) => DropdownButton<String>(
        value: supportedCharsets.containsKey(value) ? value : 'UTF-8',
        isDense: true,
        underline: const SizedBox(),
        style: const TextStyle(fontSize: 12, color: JjColors.text),
        items: [
          for (final e in supportedCharsets.entries)
            DropdownMenuItem(value: e.key, child: Text(e.value)),
        ],
        onChanged: onChanged == null ? null : (v) => onChanged!(v!),
      );
}

// ───────── 아래: 작업 기록 ─────────

class _LogPanel extends StatelessWidget {
  final List<String> logs;
  final VoidCallback onClose;
  const _LogPanel({required this.logs, required this.onClose});

  @override
  Widget build(BuildContext context) => Container(
        color: JjColors.bg,
        child: Stack(children: [
          Positioned.fill(
            child: ListView.builder(
              reverse: true,
              padding: const EdgeInsets.fromLTRB(16, 8, 44, 8),
              itemCount: logs.length,
              itemBuilder: (_, i) => SelectableText(
                logs[logs.length - 1 - i],
                style: const TextStyle(
                    fontSize: 12, fontFamily: 'Consolas', color: JjColors.textDim),
              ),
            ),
          ),
          // 오른쪽 위 ✕: 작업 기록 숨기기
          Positioned(
            top: 2,
            right: 4,
            child: IconButton(
              tooltip: '작업 기록 숨기기',
              iconSize: 16,
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.close, color: JjColors.textDim),
              onPressed: onClose,
            ),
          ),
        ]),
      );
}

/// 작업 기록을 숨겼을 때 맨 아래 얇은 줄: 마지막 기록 + 다시 보기
class _LogStrip extends StatelessWidget {
  final String last;
  final VoidCallback onOpen;
  const _LogStrip({required this.last, required this.onOpen});

  @override
  Widget build(BuildContext context) => Material(
        color: JjColors.bg,
        child: InkWell(
          onTap: onOpen,
          child: SizedBox(
            height: 26,
            child: Row(children: [
              const SizedBox(width: 16),
              Expanded(
                child: Text(last,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 11, fontFamily: 'Consolas', color: JjColors.textDim)),
              ),
              const Text('작업 기록 보기', style: TextStyle(fontSize: 11, color: JjColors.accent)),
              const Icon(Icons.expand_less, size: 16, color: JjColors.accent),
              const SizedBox(width: 12),
            ]),
          ),
        ),
      );
}

