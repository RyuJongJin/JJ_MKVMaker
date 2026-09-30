import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';

import '../app/app_controller.dart';
import '../app/bookmarks_controller.dart';
import '../app/download_manager.dart';
import '../core/charset_detector.dart';
import '../core/encode_options.dart';
import '../core/languages.dart';
import '../core/models.dart';
import '../core/output_paths.dart';
import '../core/playlist.dart';
import 'ai_dialog.dart';
import 'browser_page.dart';
import 'downloads_page.dart';
import 'player_page.dart';
import 'settings_page.dart';
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
        // 탐색기에서 동영상 · 폴더를 끌어다 놓으면 동영상만 추가
        body: DropTarget(
          onDragDone: (d) async {
            final videos = await collectVideos(d.files.map((f) => f.path),
                isDirectory: (x) => FileSystemEntity.isDirectory(x),
                listDir: (x) async => Directory(x).list().map((e) => e.path).toList());
            if (videos.isEmpty) {
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('끌어다 놓은 항목에 동영상이 없습니다.')));
              }
              return;
            }
            await c.addVideos(videos);
          },
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
                height: 140,
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

  @override
  Widget build(BuildContext context) {
    final canBuild = c.videos.isNotEmpty && c.ffmpegVersion != null;
    return Container(
      height: 56,
      color: JjColors.panel,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          // 프로그램 아이콘 (tool/make_icon.py 로 생성)
          Image.asset('assets/icon/app_icon_256.png', width: 28, height: 28, filterQuality: FilterQuality.medium),
          const SizedBox(width: 8),
          const Text('JJ_MKVMaker',
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
          const SizedBox(width: 24),
          OutlinedButton.icon(
            onPressed: c.pickVideos,
            icon: const Icon(Icons.add, size: 18),
            label: const Text('동영상 추가'),
          ),
          const SizedBox(width: 8),
          OutlinedButton.icon(
            onPressed: c.busy || c.videos.isEmpty ? null : c.clearVideos,
            icon: const Icon(Icons.clear_all, size: 18),
            label: const Text('모두 지우기'),
          ),
          const Spacer(),
          if (c.busy) ...[
            JobIndicator(c: c),
            const SizedBox(width: 8),
            OutlinedButton.icon(
              onPressed: c.cancel,
              icon: const Icon(Icons.stop, size: 18, color: JjColors.danger),
              label: const Text('취소'),
            ),
            const SizedBox(width: 8),
          ],
          FilledButton.icon(
            onPressed: canBuild ? c.buildAll : null,
            icon: Icon(c.busy ? Icons.playlist_add : Icons.play_arrow, size: 20),
            label: Text(c.busy ? 'MKV 만들기 (대기열)' : 'MKV 만들기'),
          ),
          if (bookmarks != null) ...[
            const SizedBox(width: 8),
            OutlinedButton.icon(
              onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                      builder: (_) => BrowserPage(c: c, downloads: downloads, bookmarks: bookmarks!))),
              icon: const Icon(Icons.public, size: 18),
              label: const Text('브라우저'),
            ),
          ],
          if (downloads != null) ...[
            const SizedBox(width: 12),
            _DownloadBox(d: downloads!),
          ],
          const SizedBox(width: 4),
          IconButton(
            tooltip: '환경 설정',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => Navigator.push(
                context, MaterialPageRoute<void>(builder: (_) => SettingsPage(c: c))),
          ),
          if (onExit != null)
            IconButton(
              tooltip: '종료',
              icon: const Icon(Icons.power_settings_new, color: JjColors.danger),
              onPressed: onExit,
            ),
        ],
      ),
    );
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
            onTap: () => Navigator.push(
                context, MaterialPageRoute<void>(builder: (_) => DownloadsPage(d: d))),
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

  @override
  Widget build(BuildContext context) {
    return Container(
      color: JjColors.panel,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
            child: Text('동영상 ${c.videos.length}개',
                style: const TextStyle(color: JjColors.textDim, fontSize: 12)),
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

  @override
  Widget build(BuildContext context) {
    final isSel = c.selected == v;
    final subs = v.subtitles.where((s) => s.enabled).length;
    return InkWell(
      onTap: () => c.select(v),
      onDoubleTap: () => playFiles(context, c, [v.path]),
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
        decoration: BoxDecoration(
          color: isSel ? JjColors.panelHigh : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
              color: isSel ? JjColors.accent.withValues(alpha: 0.6) : Colors.transparent),
        ),
        child: Row(
          children: [
            _StatusIcon(v.status),
            const SizedBox(width: 10),
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
              tooltip: c.canEdit(s) ? '다른 언어로 번역 (AI · 이 PC 에서)' : '이미지 자막은 번역할 수 없습니다',
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

