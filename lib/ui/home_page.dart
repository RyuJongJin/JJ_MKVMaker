import 'dart:math' as math;
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;

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
import 'exit_guard.dart';
import 'package:path/path.dart' as p;

import '../app/settings.dart' show MoveTarget;
import 'folder_picker.dart';
import 'player_page.dart';
import 'subtitle_editor_page.dart';
import 'subtitle_search_dialog.dart';
import 'confirm.dart';
import 'encode_notice.dart';
import 'theme.dart';
import 'translate_dialog.dart';
import 'video_adjust_dialog.dart';
import 'work_panel.dart';
import '../l10n/tr.dart';

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
      builder: (context, _) => ExitGuard(
        c: c,
        downloads: downloads,
        child: Scaffold(
        // 끌어다 놓기는 앱 전체에서 받는다 (ui/app_drop.dart 의 AppDropArea - 어느 화면에서 놓아도 이 목록에 추가)
        body: SwipeNav(
          current: 'mkv',
          child: Column(
          children: [
            _TopBar(c: c, downloads: downloads, onExit: onExit, bookmarks: bookmarks),
            const Divider(height: 1),
            _EncodeBar(c: c),
            const Divider(height: 1),
            Expanded(
              // 좁은 화면 (접은 폴드 · 휴대폰 세로): 목록을 위에, 자세히 보기를 아래에
              child: isCompact(context) && c.videos.isEmpty
                  // 8: 좁은 화면에 동영상이 없으면 빈 목록 · 안내로 나누지 않고 한 화면에 안내 + [동영상 추가]
                  ? _EmptyHint(onAdd: c.pickVideos)
                  : isCompact(context)
                  ? Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        SizedBox(
                            height: (MediaQuery.sizeOf(context).height * 0.32).clamp(160.0, 420.0),
                            child: _VideoList(c: c)),
                        const Divider(height: 1),
                        Expanded(
                          child: c.selected == null
                              ? _EmptyHint(onAdd: c.pickVideos)
                              : _VideoDetail(c: c, v: c.selected!),
                        ),
                      ],
                    )
                  : Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        // 13: 큰 화면 (태블릿 세로 등) 은 목록도 넓게 - 제목이 앞부분만 보여 구분이 안 되던 것
                        SizedBox(
                            width: (MediaQuery.sizeOf(context).width * 0.4).clamp(320.0, 640.0),
                            child: _VideoList(c: c)),
                        const VerticalDivider(width: 1),
                        Expanded(
                          child: c.selected == null
                              ? _EmptyHint(onAdd: c.pickVideos)
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
  /// 45: 대기 중인 작업이 있으면 지금 작업만 / 모두 고르게 한다 (없으면 지금 작업을 바로 멈춤 - 예전처럼)
  Future<void> _cancelJobs(BuildContext context) async {
    final waiting = c.pendingJobs.length;
    if (waiting == 0) {
      c.cancel();
      return;
    }
    final pick = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        scrollable: true,
        title: Text(tr('작업 취소')),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(trf('지금: {0}', [c.currentJob ?? ''])),
          const SizedBox(height: 4),
          Text(trf('대기 중: {0}', [c.pendingJobs.join(' · ')]), style: const TextStyle(fontSize: 12, color: JjColors.textDim)),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('닫기'))),
          TextButton(onPressed: () => Navigator.pop(ctx, 'current'), child: Text(trf('지금 작업만 (대기 {0}개는 계속)', [waiting]))),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: JjColors.danger),
            onPressed: () => Navigator.pop(ctx, 'all'),
            child: Text(trf('모두 취소 (대기 {0}개 포함)', [waiting])),
          ),
        ],
      ),
    );
    if (pick == 'current') c.cancelCurrent();
    if (pick == 'all') c.cancel();
  }

  Future<void> _openOutput(BuildContext context) async {
    final v = c.selected;
    if (v == null) return;
    final dir = outputDirFor(v.path);
    if (!await Directory(dir).exists()) {
      if (context.mounted) {
        ScaffoldMessenger.maybeOf(context)
            ?.showSnackBar(SnackBar(content: Text(trf('아직 만든 MKV · 자막이 없습니다: {0}', [dir]))));
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
        scrollable: true,
        title: Text(tr('MKV 만들기')),
        content: Text(trf('선택한 동영상이 없습니다.\n목록 전체 {0}개 ' '(이미 만든 것을 빼면 {1}개) 를 MKV 로 만들까요?\n\n' '일부만 만들려면 취소하고 동영상 목록에서 체크하세요.', [c.videos.length, todo])),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('취소'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr('전체 만들기'))),
        ],
      ),
    );
    if (ok == true) await c.buildAll();
  }

  static String _batchHint(AppController c, String what) => c.checked.isEmpty
      ? trf('지금 보고 있는 동영상의 {0} (여러 개는 목록에서 체크)', [what])
      : trf('체크한 동영상 {0}개의 {1}', [c.checked.length, what]);

  @override
  Widget build(BuildContext context) {
    final canBuild = c.videos.isNotEmpty && c.ffmpegVersion != null;
    // 일괄 작업 대상: 체크한 동영상, 없으면 지금 보고 있는 한 개
    final batch = c.batchTargets;
    final canBatch = batch.isNotEmpty && c.ffmpegVersion != null;
    final count = c.checked.isEmpty ? '' : ' (${c.checked.length})';
    // 창 너비에 맞춰 차례로 줄인다: 제목 글 → 왼쪽 버튼을 아이콘만 → 재생 · 브라우저를 아이콘만 → CPU · MEM 숨김.
    // (오른쪽의 화면 크기 · 환경 설정 · 종료 버튼은 어떤 너비에서도 밀려나지 않게)
    final compact = isCompact(context);
    return LayoutBuilder(builder: (context, box) {
      final hasAi = c.aiAvailable;
      final hasPlayer = c.services.createMediaPlayer != null;
      var title = true, leftText = true, rightText = true, usage = c.usage != null, jobText = true;
      // 아주 좁을 때: 다운로드 상자 숨김 (왼쪽 공통 버튼으로 열 수 있음) → MKV 만들기도 아이콘만
      var dlBox = downloads != null, mkvText = true;
      // 각 부분의 너비 (실제 화면에서 잰 값 - 한국어 글 기준)
      // 61: 다른 언어는 버튼 글이 더 길 수 있어 (일본어 "字幕作成 & MKV 作成") 그 차이를 재어 더한다 - 안 하면 줄이기 전에 잘렸다
      final style = Theme.of(context).textTheme.labelLarge ?? const TextStyle(fontSize: 14);
      double textW(String s) => (TextPainter(text: TextSpan(text: s, style: style), textDirection: TextDirection.ltr, maxLines: 1)
            ..layout())
          .width;
      double more(String ko) => uiLanguage == 'ko' ? 0 : math.max(0, textW(tr(ko).replaceAll('{0}', '').replaceAll('{1}', '')) - textW(ko.replaceAll('{0}', '').replaceAll('{1}', '')));
      final leftMore = more('동영상 추가') + (hasAi ? more('자막 만들기{0}') + more('자막 만들기 & MKV 만들기{0}') : 0);
      final playMore = more('선택한 파일 재생{0}'), mkvMore = more('MKV 만들기{0}{1}'), outMore = more('결과 폴더');
      // 좁은 화면: 이동 버튼 · 설정 · 종료는 첫 줄에 있으므로 둘째 줄 (가운데 도구) 만 잰다
      double need() =>
          (compact ? 0 : 8 + appBarRightPadding + AppNavButtons.width + 8) + (title ? 126 : 0) + 24 +
          (leftText ? 153 + (hasAi ? 161 + 298 : 0) + leftMore : 40 + (hasAi ? 96 : 0)) + 8 +
          (c.busy ? (jobText ? 350 : 60) : 0) +
          (hasPlayer ? (rightText ? 201 + playMore : 48) : 0) +
          (mkvText ? 166 + mkvMore + (c.busy && jobText ? 60 : 0) : 48) +
          (rightText ? 166 + outMore : 48) + // 결과 폴더
          (dlBox ? 162 : 0) +
          (compact ? 0 : (usage ? 220 : 0) + 96 + 92) +
          (c.checked.isEmpty ? 0 : 3 * 26) +
          8; // 여유
      final w = box.maxWidth;
      if (compact) title = false;
      if (need() > w) title = false;
      if (need() > w) jobText = false;
      if (need() > w) leftText = false;
      if (need() > w) rightText = false;
      if (need() > w) usage = false;
      if (need() > w) dlBox = false;
      if (need() > w) mkvText = false;

      // 7: 폰에는 "탐색기에서 끌어다 놓기" 가 없다
      final addTip = Platform.isAndroid ? tr('동영상 추가') : tr('동영상 추가 (탐색기에서 끌어다 놓아도 됩니다)');

      // 글이 있는 버튼, 또는 (좁을 때) 아이콘만 있는 버튼
      // 138: [ai] 는 AI 가 들어가는 버튼 (보라 테두리 · 글자) - 청록 [MKV 만들기] 와 한눈에 구별되게
      Widget action(IconData icon, String label, VoidCallback? onPressed,
          {required bool text, required String tip, Color? color, bool ai = false}) {
        final fg = ai ? aiColor : null;
        final side = BorderSide(color: ai && onPressed != null ? aiColor.withValues(alpha: 0.7) : JjColors.border);
        return Tooltip(
          message: tip,
          child: text
              ? OutlinedButton.icon(
                  style: ai ? OutlinedButton.styleFrom(foregroundColor: fg, side: side) : null,
                  onPressed: onPressed,
                  icon: Icon(icon, size: 18, color: color ?? fg),
                  label: Text(label))
              : IconButton.outlined(
                  onPressed: onPressed,
                  icon: Icon(icon, size: 20, color: onPressed == null ? null : color ?? fg),
                  style: IconButton.styleFrom(
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)), side: side)),
        );
      }

      // AI 버튼 둘 (자막 만들기 · 자막 만들기 & MKV 만들기)
      List<Widget> aiButtons(bool text) => [
            action(Icons.auto_awesome, trf('자막 만들기{0}', [count]),
                canBatch ? () => showAiDialog(context, c, batch.first, targets: batch) : null,
                text: text, ai: true, tip: trf('자막 만들기: {0}', [_batchHint(c, tr('AI 자막을 만듭니다'))])),
            const SizedBox(width: 8),
            action(Icons.auto_awesome_motion, trf('자막 만들기 & MKV 만들기{0}', [count]),
                canBatch ? () => showAiDialog(context, c, batch.first, targets: batch, thenBuild: true) : null,
                text: text,
                ai: true,
                tip: trf('자막 만들기 & MKV 만들기: {0}', [_batchHint(c, tr('AI 자막을 만들고 이어서 MKV 로 만듭니다'))])),
          ];

      // 2: 좁은 화면 (폰 세로) 에서는 버튼 글자를 숨기지 않고 옆으로 밀어 본다. 가장 많이 쓰는 [MKV 만들기] 를 맨 앞에.
      if (compact) {
        VoidCallback? build0() =>
            !canBuild ? null : (batch.isEmpty ? () => _confirmBuildAll(context) : () => c.buildVideos(batch));
        return AppTopBar(
          nav: const AppNavButtons(onMkvPage: true),
          actions: AppActions(c: c, onExit: onExit, showUsage: false),
          middle: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(children: [
              Tooltip(
                message: trf('MKV 만들기{0}', [count]),
                child: FilledButton.icon(
                  onPressed: build0(),
                  icon: Icon(c.busy ? Icons.playlist_add : Icons.play_arrow, size: 20),
                  label: Text(trf('MKV 만들기{0}{1}', [count, c.busy ? tr(' (대기열)') : ''])),
                ),
              ),
              const SizedBox(width: 8),
              action(Icons.add, tr('동영상 추가'), c.pickVideos, text: true, tip: addTip),
              if (hasPlayer) ...[
                const SizedBox(width: 8),
                action(
                    Icons.playlist_play,
                    trf('선택한 파일 재생{0}', [count]),
                    batch.isEmpty ? null : () => playFiles(context, c, [for (final v in batch) v.path], keepOrder: true),
                    text: true,
                    tip: tr('선택한 파일 재생: 지금 보고 있는 동영상 (여러 개는 목록에서 체크)')),
              ],
              const SizedBox(width: 8),
              action(Icons.folder_special_outlined, tr('결과 폴더'), c.selected == null ? null : () => _openOutput(context),
                  text: true, tip: tr('결과 폴더 열기')),
              // 138: AI 버튼은 [MKV 만들기] 와 떨어뜨려 맨 뒤에, 구분선 너머로
              if (hasAi) ...[
                const SizedBox(width: 8),
                const SizedBox(height: 28, child: VerticalDivider(width: 16, color: JjColors.border)),
                ...aiButtons(true),
              ],
              if (c.busy) ...[
                const SizedBox(width: 8),
                JobIndicator(c: c, compact: true, iconOnly: false),
                const SizedBox(width: 8),
                action(Icons.stop, tr('취소'), () => _cancelJobs(context), text: true, tip: tr('작업 취소'), color: JjColors.danger),
              ],
            ]),
          ),
        );
      }

      return AppTopBar(
        // 모든 화면 공통: [JJ 홈] [MKV 화면] [뒤로] [다운로드 목록]
        nav: const AppNavButtons(onMkvPage: true),
        // 화면 크기 · 환경 설정 · 종료: 모든 화면에서 같은 자리
        actions: AppActions(c: c, onExit: onExit, showUsage: usage),
        middle: Row(
          children: [
            if (title) const Text('JJ_MKVMaker', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
            SizedBox(width: compact ? 0 : 24),
            // 왼쪽 묶음: 그래도 모자라면 옆으로 밀어 볼 수 있게
            Expanded(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(children: [
                  action(Icons.add, tr('동영상 추가'), c.pickVideos,
                      text: leftText, tip: addTip),
                  // 138: AI 버튼 (보라) 은 왼쪽, [MKV 만들기] (청록) 는 오른쪽 - 떨어져 있다
                  if (hasAi) ...[
                    const SizedBox(width: 8),
                    ...aiButtons(leftText),
                  ],
                ]),
              ),
            ),
            const SizedBox(width: 8),
            if (c.busy) ...[
              JobIndicator(c: c, compact: !jobText, iconOnly: !jobText),
              const SizedBox(width: 8),
              action(Icons.stop, tr('취소'), () => _cancelJobs(context), text: jobText, tip: tr('작업 취소'), color: JjColors.danger),
              const SizedBox(width: 8),
            ],
            // 체크한 동영상을 목록에 보이는 순서대로 이어서 재생 (체크가 없으면 보고 있는 한 개)
            if (hasPlayer) ...[
              action(
                  Icons.playlist_play,
                  trf('선택한 파일 재생{0}', [count]),
                  batch.isEmpty
                      ? null
                      : () => playFiles(context, c, [for (final v in batch) v.path], keepOrder: true),
                  text: rightText,
                  tip: c.checked.isEmpty
                      ? tr('선택한 파일 재생: 지금 보고 있는 동영상 (여러 개는 목록에서 체크)')
                      : trf('선택한 파일 재생: 체크한 동영상 {0}개를 목록 순서대로 이어서', [c.checked.length])),
              const SizedBox(width: 8),
            ],
            // 체크한 동영상이 있으면 그것만, 없으면 "전체 만들기 / 취소" 를 묻는다
            Tooltip(
              message: trf('MKV 만들기{0}', [count]),
              child: mkvText
                  ? FilledButton.icon(
                      onPressed: !canBuild ? null : (batch.isEmpty ? () => _confirmBuildAll(context) : () => c.buildVideos(batch)),
                      icon: Icon(c.busy ? Icons.playlist_add : Icons.play_arrow, size: 20),
                      label: Text(trf('MKV 만들기{0}{1}', [count, c.busy && jobText ? tr(' (대기열)') : ''])),
                    )
                  : IconButton.filled(
                      onPressed: !canBuild ? null : (batch.isEmpty ? () => _confirmBuildAll(context) : () => c.buildVideos(batch)),
                      icon: Icon(c.busy ? Icons.playlist_add : Icons.play_arrow, size: 20),
                    ),
            ),
            // 만든 MKV 가 있는 폴더 (jj_mkv). 웹 브라우저 버튼은 왼쪽 공통 버튼으로 옮김
            const SizedBox(width: 8),
            action(Icons.folder_special_outlined, tr('결과 폴더'), c.selected == null ? null : () => _openOutput(context),
                text: rightText,
                tip: c.selected == null
                    ? tr('결과 폴더 열기 (동영상을 고르세요)')
                    : trf('결과 폴더 열기: {0}', [outputDirFor(c.selected!.path)])),
            if (dlBox) ...[
              const SizedBox(width: 12),
              _DownloadBox(d: downloads!),
            ],
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
                            ? trf('다운로딩 {0}{1}', [n, p == null ? '' : ' · ${(p * 100).toStringAsFixed(0)}%'])
                            : trf('다운로드 {0}', [d.tasks.length]),
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
    // 32: MKV 를 만드는 동안만 (AI 자막 · 번역 중에는 다음 MKV 설정을 바꿀 수 있다)
    final locked = c.buildingMkv;
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
                  text(i) + ((enabled?.call(i) ?? true) ? '' : tr(' (사용 불가)')),
                  style: TextStyle(
                      color: (enabled?.call(i) ?? true) ? null : JjColors.textDim),
                ),
              ),
          ],
          onChanged: locked ? null : (v) => onChanged(v as T),
        );

    final compact = isCompact(context);
    final row = Row(children: [
        label(tr('화면 크기')),
        drop(s.resolution, ResolutionChoice.values, (r) => r.label, (r) {
          c.setResolution(r);
          showEncodeNotice(context, c);
        }),
        const SizedBox(width: 20),
        label(tr('코덱')),
        drop(s.codec, VideoCodecChoice.values, (v) => v.label, c.setCodec,
            enabled: c.isCodecAvailable),
        const SizedBox(width: 20),
        if (s.reencode) ...[
          label(tr('화질')),
          drop(s.quality, QualityChoice.values, (q) => q.label, c.setQuality),
          const SizedBox(width: 20),
        ],
        // 화면 비율 (가로 · 세로) · 회전 · 색 보정: 미리보기를 보며 고르는 창
        Tooltip(
          message: s.adjusts ? '${tr('화면 · 색 보정')}: ${s.adjustSummary}' : tr('화면 비율 (가로 · 세로) · 회전 · 밝기 · 대비 · 채도 · 색온도'),
          child: (s.adjusts ? FilledButton.tonalIcon : OutlinedButton.icon)(
            onPressed: locked ? null : () => showVideoAdjust(context, c),
            icon: const Icon(Icons.tune, size: 18),
            label: Text(tr('화면 · 색 보정')),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          // 31: "⚠ 원본보다 커서" 경고는 화면 너비와 상관없이 늘 보이게 맨 앞에 (넓은 화면에서 한 줄이 넘치면 설명 · 보정 요약 쪽이 잘린다)
          child: Text(
            '${s.reencode && up > 0 ? '${trf('⚠ {0}개는 원본보다 커서 화질 향상 없이 용량만 늘어납니다', [up])} · ' : ''}'
            '${s.adjusts ? s.adjustSummary : !s.reencode ? tr('영상·음성을 그대로 복사합니다 (빠름, 화질 손실 없음)') : tr('영상을 다시 인코딩합니다 (시간이 오래 걸림, 음성은 그대로)')}',
            overflow: compact ? null : TextOverflow.ellipsis,
            style: TextStyle(
                fontSize: 12, color: up > 0 && s.reencode ? JjColors.danger : JjColors.textDim),
          ),
        ),
      ]);
    if (compact) {
      return Container(
        width: double.infinity,
        color: JjColors.panel,
        padding: const EdgeInsets.fromLTRB(8, 4, 8, 6),
        child: Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          runSpacing: 6,
          // 31: 설명 · "⚠ 원본보다 커서 용량만 늘어납니다" 경고는 빼지 않고 한 줄을 다 써서 보여 준다
          children: [
            for (final w in row.children)
              w is Expanded ? SizedBox(width: double.infinity, child: w.child) : w,
          ],
        ),
      );
    }
    return Container(
      height: 44,
      color: JjColors.panel,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: row,
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
      tooltip: trf('{0} 순으로 정렬' '{1}', [name, on ? (c.sortAscending ? tr(' (지금: 오름차순 · 다시 누르면 내림차순)') : tr(' (지금: 내림차순 · 다시 누르면 오름차순)')) : '']),
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
                  // 좁으면 글자를 줄여서 한 줄에 다 보이게
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Text(
                        c.checked.isEmpty
                            ? trf('동영상 {0}개 · 전체 선택', [c.videos.length])
                            : trf('선택 {0} / {1}개', [c.checked.length, c.videos.length]),
                        maxLines: 1,
                        style: const TextStyle(color: JjColors.textDim, fontSize: 12)),
                  ),
                ),
              ),
              // 정렬: 같은 것을 다시 누르면 반대 순서
              _sortButton('name', Icons.sort_by_alpha, tr('파일 이름')),
              _sortButton('date', Icons.calendar_month, tr('날짜')),
              if (c.checked.isNotEmpty)
                IconButton(
                  tooltip: tr('선택한 동영상을 목록에서 제거'),
                  iconSize: 18,
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.playlist_remove, color: JjColors.textDim),
                  onPressed: c.removeChecked,
                ),
              IconButton(
                tooltip: tr('모두 지우기'),
                iconSize: 18,
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.clear_all, color: JjColors.textDim),
                // 46: 확인 뒤 (목록에서만 빼고 파일은 그대로)
                onPressed: c.busy || c.videos.isEmpty
                    ? null
                    : () async {
                        final ok = await confirmAction(
                          context,
                          title: tr('목록을 모두 비울까요?'),
                          body: trf('동영상 {0}개를 MKV 목록에서 뺍니다. 파일은 지우지 않습니다.', [c.videos.length]),
                          ok: tr('모두 지우기'),
                        );
                        if (ok) c.clearVideos();
                      },
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
        item('folder', Icons.folder_open, tr('대상 폴더 열기')),
        if (c.services.createMediaPlayer != null) item('play', Icons.play_arrow, tr('재생')),
        const PopupMenuDivider(),
        if (c.aiAvailable)
          item('ai', Icons.auto_awesome, tr('AI 자막 만들기'), enabled: !busy && c.ffmpegVersion != null),
        if (c.subtitleProvider != null)
          item('search', Icons.travel_explore, tr('인터넷 자막 찾기'), enabled: !busy),
        item('subtitle', Icons.subtitles_outlined, tr('자막 파일 추가'), enabled: !busy),
        const PopupMenuDivider(),
        item('remove', Icons.close, tr('목록에서 빼기 (파일은 그대로)'), enabled: !busy),
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

  // 연달아 누른 횟수 (두 번이면 재생, 세 번 이상이면 이동). 마지막으로 누르고 잠시 뒤에 정한다.
  static VideoItem? _tapItem;
  static int _taps = 0;
  static Timer? _tapTimer;

  void _tapped(BuildContext context) {
    c.select(v);
    _taps = _tapItem == v ? _taps + 1 : 1;
    _tapItem = v;
    _tapTimer?.cancel();
    _tapTimer = Timer(const Duration(milliseconds: 350), () {
      final n = _taps;
      _taps = 0;
      _tapItem = null;
      if (!context.mounted) return;
      if (n == 2) {
        playFiles(context, c, [v.path]);
      } else if (n >= 3 && c.settings.tripleTapAction == 'move') {
        // 47: 잘못 세 번 눌러도 파일이 옮겨지지 않게 묻는다
        moveToTarget(context, c, [v], confirm: true);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final isSel = c.selected == v;
    final subs = v.subtitles.where((s) => s.enabled).length;
    // 51: 터치 화면에서는 길게 누르면 오른쪽 클릭과 같은 메뉴 (누른 자리에)
    return GestureDetector(
      onLongPressStart: (d) {
        HapticFeedback.selectionClick();
        _menu(context, d.globalPosition);
      },
      child: InkWell(
      // 한 번: 보기 · 두 번: 재생 · 세 번 이상: 이동 폴더로 옮기기
      onTap: () => _tapped(context),
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
                      v.status == JobStatus.failed ? tr('실패') : trf('자막 {0}개', [subs]),
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
                tooltip: tr('다시 만들기 대기로'),
                iconSize: 16,
                onPressed: () => c.resetStatus(v),
                icon: const Icon(Icons.refresh, color: JjColors.textDim),
              ),
            IconButton(
              tooltip: tr('목록에서 제거'),
              iconSize: 16,
              onPressed: v.status == JobStatus.running ? null : () => c.removeVideo(v),
              icon: const Icon(Icons.close, color: JjColors.textDim),
            ),
          ],
        ),
      ),
    ));
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
  final VoidCallback? onAdd;
  const _EmptyHint({this.onAdd});

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.video_library_outlined, size: 56, color: JjColors.textDim),
              const SizedBox(height: 12),
              Text(tr('"동영상 추가" 로 파일을 선택하세요'), textAlign: TextAlign.center, style: const TextStyle(color: JjColors.textDim)),
              const SizedBox(height: 4),
              Text(tr('같은 폴더의 자막은 자동으로 추가됩니다'),
                  textAlign: TextAlign.center, style: const TextStyle(color: JjColors.textDim, fontSize: 12)),
              if (onAdd != null) ...[
                const SizedBox(height: 16),
                FilledButton.icon(onPressed: onAdd, icon: const Icon(Icons.add), label: Text(tr('동영상 추가'))),
              ],
            ],
          ),
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

    // 오른쪽 아래 이동 버튼들 (환경 설정 > MKV 만들기 > 이동 버튼): 표시 이름으로, 위로 하나씩.
    // 체크한 동영상이 있으면 그것들, 없으면 지금 보고 있는 이 동영상을 그 버튼의 폴더로 옮긴다.
    final moving = c.checked.isEmpty ? [v] : c.batchTargets;
    final canMove = moving.any((x) => x.status != JobStatus.running);
    final count = c.checked.isEmpty ? '' : ' (${c.checked.length})';
    final buttons = c.settings.moveTargets;
    Widget button(MoveTarget? t) => Tooltip(
          message: t == null
              ? tr('이동: 옮길 폴더를 골라 이동 버튼을 만듭니다 (환경 설정 > MKV 만들기 > 이동 버튼에서 여러 개 만들 수 있음)')
              : c.checked.isEmpty
                  ? trf('{0}: 이 동영상을 {1} 로 옮깁니다', [t.name, t.dir])
                  : trf('{0}: 체크한 동영상 {1}개를 {2} 로 옮깁니다', [t.name, c.checked.length, t.dir]),
          child: FloatingActionButton.extended(
            heroTag: null,
            onPressed: canMove ? () => moveToTarget(context, c, moving, target: t) : null,
            icon: const Icon(Icons.drive_file_move_outline),
            label: Text('${t?.name ?? tr('이동')}$count'),
          ),
        );
    return Stack(children: [
      _list(context, info, video, audioCount, locked),
      Positioned(
        right: 16,
        bottom: 16,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            if (buttons.isEmpty) button(null),
            // 첫 번째 버튼이 맨 아래 (예전 [이동] 자리), 다음 버튼은 그 위로
            for (var i = buttons.length - 1; i >= 0; i--) ...[
              button(buttons[i]),
              if (i > 0) const SizedBox(height: 10),
            ],
          ],
        ),
      ),
    ]);
  }

  Widget _list(BuildContext context, MediaInfo? info, StreamInfo? video, int audioCount, bool locked) {
    final side = isCompact(context) ? 12.0 : 20.0;
    return ListView(
      padding: EdgeInsets.fromLTRB(side, side, side, 88),
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
              label: Text(tr('재생')),
            ),
          ],
          const SizedBox(width: 8),
          OutlinedButton.icon(
            onPressed: () => c.services.shell.revealFile(v.path),
            icon: const Icon(Icons.folder_open, size: 18),
            label: Text(tr('폴더 열기')),
          ),
        ]),
        const SizedBox(height: 4),
        SelectableText(v.path,
            style: const TextStyle(color: JjColors.textDim, fontSize: 12)),
        const SizedBox(height: 12),
        Wrap(spacing: 8, runSpacing: 8, children: [
          if (info?.duration != null) _Chip(trf('길이 {0}', [_fmt(info!.duration!)])),
          if (video != null) ...[
            if (video.width != null) _Chip('${video.width}×${video.height}'),
            _Chip(trf('영상 {0}', [video.codec])),
          ],
          _Chip(trf('음성 {0}개', [audioCount])),
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
        // 좁으면 버튼이 다음 줄로 (오른쪽 정렬)
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(tr('자막'), style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Wrap(alignment: WrapAlignment.end, spacing: 8, runSpacing: 8, children: [
              if (c.aiAvailable)
                FilledButton.icon(
                  onPressed: locked || c.ffmpegVersion == null ? null : () => showAiDialog(context, c, v),
                  icon: const Icon(Icons.auto_awesome, size: 18),
                  label: Text(tr('AI 자막 만들기')),
                ),
              if (c.subtitleProvider != null)
                OutlinedButton.icon(
                  onPressed: locked ? null : () => showSubtitleSearch(context, c, v),
                  icon: const Icon(Icons.travel_explore, size: 18),
                  label: Text(tr('인터넷 자막 찾기')),
                ),
              OutlinedButton.icon(
                onPressed: locked ? null : () => c.pickSubtitlesFor(v),
                icon: const Icon(Icons.subtitles_outlined, size: 18),
                label: Text(tr('자막 파일 추가')),
              ),
            ]),
          ),
        ]),
        const SizedBox(height: 8),
        if (v.subtitles.isEmpty)
          Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: Text(tr('자막이 없습니다.'), style: TextStyle(color: JjColors.textDim)),
          ),
        for (final s in v.subtitles)
          _SubtitleRow(c: c, v: v, s: s, locked: locked),
        const SizedBox(height: 24),
        Text(trf('출력: {0}', [outputMkvPath(v.path)]),
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
            child: Text(embedded ? tr('내장') : tr('외부'),
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
            tooltip: c.canEdit(s) ? tr('내용 편집 · 문자셋 변환') : tr('이미지 자막은 편집할 수 없습니다'),
            iconSize: 18,
            onPressed: locked || off || !c.canEdit(s)
                ? null
                : () => openSubtitleEditor(context, c, v, s),
            icon: const Icon(Icons.edit_note, color: JjColors.accent),
          ),
          if (c.services.createTranslator != null)
            IconButton(
              tooltip: c.canEdit(s) ? trf('다른 언어로 번역 (AI · 이 {0}에서)', [Platform.isAndroid ? tr('기기') : 'PC']) : tr('이미지 자막은 번역할 수 없습니다'),
              iconSize: 18,
              onPressed: locked || off || !c.canEdit(s) ? null : () => showTranslateDialog(context, c, v, s),
              icon: const Icon(Icons.translate, color: JjColors.accent),
            ),
          IconButton(
            tooltip: embedded ? (off ? tr('되살리기') : tr('삭제 (출력에서 제외)')) : tr('목록에서 제거'),
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
            child: Text(l == undetermined ? tr('언어: 미지정') : '${l.name} (${l.code})'),
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
              tooltip: tr('작업 기록 숨기기'),
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
              Text(tr('작업 기록 보기'), style: TextStyle(fontSize: 11, color: JjColors.accent)),
              const Icon(Icons.expand_less, size: 16, color: JjColors.accent),
              const SizedBox(width: 12),
            ]),
          ),
        ),
      );
}

/// 동영상을 이동 버튼의 폴더로 옮긴다 (세부 정보의 이동 버튼 · 세 번 누르기). [target] 이 없으면 첫 번째 버튼,
/// 이동 버튼이 하나도 없으면 폴더를 골라 하나 만든다 (표시 이름은 폴더 이름).
/// [confirm]: 옮기기 전에 묻는다 (세 번 누르기 - 47)
Future<void> moveToTarget(BuildContext context, AppController c, List<VideoItem> videos,
    {MoveTarget? target, bool confirm = false}) async {
  if (videos.isEmpty) return;
  final messenger = ScaffoldMessenger.maybeOf(context);
  var t = target ?? c.settings.moveTargets.firstOrNull;
  if (t == null) {
    final d = await pickFolder(context, tr('이동 폴더 (환경 설정에서 바꿀 수 있음)'));
    if (d == null) return;
    t = MoveTarget(p.basename(d).isEmpty ? tr('이동') : p.basename(d), d);
    final add = t;
    await c.updateSettings((x) => x.moveTargets = [...x.moveTargets, add]);
  } else if (confirm && context.mounted) {
    final ok = await confirmAction(
      context,
      title: tr('파일 옮기기'),
      body: '${trf('"{0}" 을(를) "{1}" 폴더로 옮길까요?', [videos.length == 1 ? videos.single.fileName : trf('{0}개', [videos.length]), t.name])}'
          '\n${t.dir}\n\n${tr('(동영상을 세 번 누르면 옮깁니다)')}',
      ok: tr('옮기기'),
      danger: false,
    );
    if (!ok) return;
  }
  final (moved, errors) = await c.moveVideos(videos, t.dir);
  messenger?.showSnackBar(SnackBar(
    content: Text([
      if (moved > 0) trf('{0}개를 옮겼습니다 → {1} ({2})', [moved, t.name, t.dir]),
      ...errors,
    ].join('\n')),
  ));
}
