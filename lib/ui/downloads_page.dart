import 'dart:io';

import 'package:flutter/material.dart';

import '../app/download_manager.dart';
import '../core/download_detect.dart';
import '../services/downloader.dart';
import 'app_actions.dart';
import 'theme.dart';
import '../l10n/tr.dart';

/// 다운로드 목록
class DownloadsPage extends StatefulWidget {
  final DownloadManager d;
  const DownloadsPage({super.key, required this.d});

  @override
  State<DownloadsPage> createState() => _DownloadsPageState();

  /// 다운로드 목록 화면의 경로 이름 (이미 열려 있으면 그 화면으로 돌아가기 위해)
  static const routeName = 'downloads';

  /// 열려 있는 다운로드 목록 화면 수
  static int _open = 0;

  /// 다운로드 목록으로: 이미 열려 있으면 그 화면으로 돌아가고, 없으면 새로 연다.
  /// 위쪽 [다운로드 목록] 버튼 · 브라우저의 "목록 보기" · 작업 현황 등 어디서 열어도 같다.
  static Future<void> open(NavigatorState nav, DownloadManager d) async {
    if (_open > 0) {
      var found = false;
      nav.popUntil((r) {
        if (r.settings.name == routeName) found = true;
        return found || r.isFirst;
      });
      if (found) return;
    }
    await nav.push(MaterialPageRoute<void>(
      settings: const RouteSettings(name: routeName),
      builder: (_) => DownloadsPage(d: d),
    ));
  }
}

class _DownloadsPageState extends State<DownloadsPage> {
  final _url = TextEditingController();

  @override
  void initState() {
    super.initState();
    DownloadsPage._open++;
  }

  @override
  void dispose() {
    DownloadsPage._open--;
    _url.dispose();
    super.dispose();
  }

  void _add() {
    final t = widget.d.add(_url.text);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(t == null
            ? tr('YouTube 주소 · 마그넷 링크 · .torrent 주소가 아니거나 이미 받는 중입니다.')
            : trf('다운로드 추가: {0}', [t.source]))));
    if (t != null) _url.clear();
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.d;
    return ListenableBuilder(
      listenable: d,
      builder: (context, _) {
        final hasSel = d.selected.isNotEmpty;
        final allSel = d.tasks.isNotEmpty && d.selected.length == d.tasks.length;
        return Scaffold(
          body: Column(children: [
            Container(
              height: appBarHeight,
              color: JjColors.panel,
              padding: const EdgeInsets.only(left: 8, right: appBarRightPadding),
              child: Row(children: [
                const AppNavButtons(onDownloadsPage: true),
                const SizedBox(width: 8),
                Text(trf('다운로드 ({0})', [d.tasks.length]),
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                const SizedBox(width: 20),
                Expanded(
                  child: TextField(
                    controller: _url,
                    style: const TextStyle(fontSize: 13),
                    decoration: InputDecoration(
                      isDense: true,
                      // Android 는 클립보드를 감시하지 않는다
                      hintText: Platform.isAndroid
                          ? tr('YouTube 주소 · 마그넷 링크 · .torrent 주소 붙여넣기')
                          : tr('YouTube 주소 · 마그넷 링크 · .torrent 주소 붙여넣기 (Ctrl+C 만 해도 자동 추가)'),
                      border: OutlineInputBorder(),
                    ),
                    onSubmitted: (_) => _add(),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(onPressed: _add, child: Text(tr('추가'))),
                const AppActions(),
              ]),
            ),
            Container(
              color: JjColors.bg,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Row(children: [
                InkWell(
                  borderRadius: BorderRadius.circular(4),
                  onTap: d.tasks.isEmpty ? null : () => allSel ? d.selectNone() : d.selectAll(),
                  child: Row(children: [
                    Checkbox(
                      value: allSel ? true : (hasSel ? null : false),
                      tristate: true,
                      onChanged: d.tasks.isEmpty ? null : (_) => allSel ? d.selectNone() : d.selectAll(),
                    ),
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: Text(hasSel ? trf('{0}개 선택', [d.selected.length]) : tr('전체 선택'),
                          style: const TextStyle(fontSize: 12, color: JjColors.textDim)),
                    ),
                  ]),
                ),
                const Spacer(),
                if (d.addToEditList != null) ...[
                  _btn(Icons.playlist_add, tr('동영상 추가'),
                      hasSel && d.selectedVideoFiles.isNotEmpty ? () => _addToEditList(context) : null),
                  // 켜면: 다 받는 대로 MKV 만들기 목록에 넣고 이 목록에서는 뺀다
                  if (d.setAutoAdd != null)
                    Tooltip(
                      message: tr('다 받으면 MKV 만들기의 동영상 목록에 자동으로 넣고, 이 다운로드 목록에서는 뺍니다 (받은 파일은 그대로)'),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(4),
                        onTap: () => d.setAutoAdd!(!d.settings().addFinishedDownloads),
                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                          Checkbox(
                            visualDensity: VisualDensity.compact,
                            value: d.settings().addFinishedDownloads,
                            onChanged: (v) => d.setAutoAdd!(v ?? false),
                          ),
                          Padding(
                            padding: EdgeInsets.only(right: 8),
                            child: Text(tr('완료시 자동 동영상추가'), style: TextStyle(fontSize: 12)),
                          ),
                        ]),
                      ),
                    ),
                ],
                _btn(Icons.pause, tr('일시정지'), hasSel ? d.pauseSelected : null),
                _btn(Icons.play_arrow, tr('재개'), hasSel ? d.resumeSelected : null),
                _btn(Icons.stop, tr('취소'), hasSel ? d.cancelSelected : null),
                _btn(Icons.delete_outline, tr('삭제'), hasSel ? () => _confirmRemove(context) : null),
                const SizedBox(width: 12),
                _btn(Icons.cleaning_services_outlined, tr('완료 정리'),
                    d.tasks.any((t) => !t.unfinished) ? d.cleanupFinished : null),
              ]),
            ),
            const Divider(height: 1),
            Expanded(
              child: d.tasks.isEmpty
                  ? Center(
                      child: Text(
                          Platform.isAndroid
                              ? tr('다운로드가 없습니다.\nYouTube 주소 · 마그넷 링크를 위 칸에 붙여 넣거나, 웹 브라우저에서 [다운로드] 를 누르세요.')
                              : tr('다운로드가 없습니다.\nYouTube 주소나 마그넷 링크를 복사(Ctrl+C)하면 자동으로 받습니다.'),
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: JjColors.textDim)))
                  : ListView.builder(
                      itemCount: d.tasks.length,
                      itemBuilder: (_, i) => _DownloadRow(d: d, t: d.tasks[i]),
                    ),
            ),
          ]),
        );
      },
    );
  }

  Widget _btn(IconData icon, String label, VoidCallback? onTap) => Padding(
        padding: const EdgeInsets.only(left: 6),
        child: OutlinedButton.icon(
          onPressed: onTap,
          icon: Icon(icon, size: 16),
          label: Text(label, style: const TextStyle(fontSize: 12)),
        ),
      );

  /// 고른 (다 받은) 동영상을 MKV 만들기의 동영상 목록에 추가
  Future<void> _addToEditList(BuildContext context) async {
    final files = widget.d.selectedVideoFiles;
    final m = ScaffoldMessenger.of(context);
    final n = await widget.d.addToEditList!(files);
    m.showSnackBar(SnackBar(
        content: Text(n > 0
            ? trf('MKV 만들기 목록에 동영상 {0}개를 추가했습니다.', [n])
            : trf('이미 목록에 있는 동영상입니다 ({0}개).', [files.length]))));
  }

  Future<void> _confirmRemove(BuildContext context) async {
    final n = widget.d.selected.length;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('삭제')),
        content: Text(trf('선택한 {0}개를 목록에서 삭제합니다.\n받는 중인 항목은 중지하고 받던 파일도 지웁니다. (완료된 파일은 남습니다)', [n])),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('취소'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr('삭제'))),
        ],
      ),
    );
    if (ok == true) await widget.d.removeSelected();
  }
}

class _DownloadRow extends StatelessWidget {
  final DownloadManager d;
  final DownloadTask t;
  const _DownloadRow({required this.d, required this.t});

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (t.state) {
      DownloadState.queued => (tr('대기'), JjColors.textDim),
      DownloadState.downloading => (tr('받는 중'), JjColors.accent),
      DownloadState.paused => (tr('일시정지'), Colors.amber),
      DownloadState.done => (tr('완료'), JjColors.success),
      DownloadState.failed => (tr('실패'), JjColors.danger),
      DownloadState.cancelled => (tr('취소됨'), JjColors.textDim),
    };
    return InkWell(
      onTap: () => d.toggle(t),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: d.selected.contains(t.id) ? JjColors.accent.withValues(alpha: 0.08) : null,
          border: const Border(bottom: BorderSide(color: JjColors.border)),
        ),
        child: Row(children: [
          Checkbox(value: d.selected.contains(t.id), onChanged: (_) => d.toggle(t)),
          Icon(t.kind == DownloadKind.video ? Icons.smart_display_outlined : Icons.cloud_download_outlined,
              color: JjColors.textDim),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(t.title, maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13)),
              const SizedBox(height: 4),
              if (t.state != DownloadState.cancelled) DownloadProgressBar(t: t),
              const SizedBox(height: 4),
              Text(
                [
                  label,
                  if (t.speed.isNotEmpty) t.speed,
                  if (t.eta.isNotEmpty) t.eta.contains(RegExp(r'\d')) ? trf('남은 시간 {0}', [t.eta]) : t.eta, // 숫자가 없으면 "합치는 중" 같은 단계
                  if (t.error != null) t.error!.split('\n').first,
                ].join('  ·  '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11, color: t.error != null ? JjColors.danger : color),
              ),
            ]),
          ),
          IconButton(
            tooltip: tr('폴더 열기'),
            icon: const Icon(Icons.folder_open, size: 18, color: JjColors.textDim),
            onPressed: () {
              if (Platform.isWindows) {
                Process.run('explorer', [t.dir]);
              } else {
                // Android: 파일 앱으로
                AppScope.maybeOf(context)?.controller.services.shell.revealFile(t.dir);
              }
            },
          ),
        ]),
      ),
    );
  }
}

/// "받은 크기 / 전체 크기" (다 받았으면 전체 크기만, 모르면 빈 글)
String downloadSizeText(DownloadTask t) {
  final got = t.receivedBytes, all = t.totalBytes;
  if (t.state == DownloadState.done) {
    final n = all ?? got;
    return n == null || n <= 0 ? '' : formatBytes(n);
  }
  if (all != null && all > 0) return '${formatBytes(got ?? 0)} / ${formatBytes(all)}';
  return got != null && got > 0 ? formatBytes(got) : '';
}

/// 퍼센트가 보이는 진행 막대
class DownloadProgressBar extends StatelessWidget {
  final DownloadTask t;
  final double height;
  const DownloadProgressBar({super.key, required this.t, this.height = 18});

  @override
  Widget build(BuildContext context) {
    final done = t.state == DownloadState.done;
    final value = done ? 1.0 : t.progress;
    final color = switch (t.state) {
      DownloadState.done => JjColors.success,
      DownloadState.failed => JjColors.danger,
      DownloadState.paused => Colors.amber,
      DownloadState.cancelled => JjColors.textDim,
      _ => JjColors.accent,
    };
    // "45.3% · 166MB / 367MB" (크기를 모르면 퍼센트만)
    final size = downloadSizeText(t);
    final text = value == null
        ? (t.state == DownloadState.queued ? tr('대기') : tr('준비 중…'))
        : '${(value * 100).toStringAsFixed(1)}%${size.isEmpty ? '' : ' · $size'}';
    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: SizedBox(
        height: height,
        child: Stack(fit: StackFit.expand, children: [
          LinearProgressIndicator(
            // 진행률을 모를 때(받기 준비 · 마그넷 정보 받는 중)는 움직이는 막대
            value: value ?? (t.state == DownloadState.downloading ? null : 0),
            minHeight: height,
            backgroundColor: JjColors.panelHigh,
            color: color.withValues(alpha: 0.85),
          ),
          Center(
            child: Text(
              text,
              style: TextStyle(
                fontSize: height * 0.62,
                height: 1,
                fontWeight: FontWeight.w600,
                color: Colors.white,
                shadows: const [Shadow(blurRadius: 2, color: Colors.black)],
              ),
            ),
          ),
        ]),
      ),
    );
  }
}

/// 종료 확인. 받는 중인 다운로드가 있으면 목록을 보여 주고 한 번 더 확인한다.
Future<bool> confirmExit(BuildContext context, DownloadManager d) async {
  if (d.activeCount == 0) return true;
  final go = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _ExitDialog(d: d),
  );
  return go ?? false;
}

class _ExitDialog extends StatelessWidget {
  final DownloadManager d;
  const _ExitDialog({required this.d});

  Future<void> _quit(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('종료')),
        content: Text(tr('다운로드를 종료하시겠습니까?')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('취소'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr('종료'))),
        ],
      ),
    );
    if (ok == true && context.mounted) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: d,
        builder: (context, _) {
          final active = d.tasks.where((t) => t.unfinished).toList();
          return AlertDialog(
            titlePadding: const EdgeInsets.fromLTRB(24, 16, 8, 0),
            title: Row(children: [
              Text(trf('받는 중인 다운로드 {0}개', [active.length])),
              const Spacer(),
              IconButton(
                tooltip: tr('종료'),
                icon: const Icon(Icons.close),
                onPressed: () => _quit(context),
              ),
            ]),
            content: SizedBox(
              width: 520,
              height: 300,
              child: active.isEmpty
                  ? Center(child: Text(tr('받는 중인 다운로드가 없습니다.')))
                  : ListView(children: [
                      for (final t in active)
                        ListTile(
                          dense: true,
                          leading: Icon(t.kind == DownloadKind.video
                              ? Icons.smart_display_outlined
                              : Icons.cloud_download_outlined),
                          title: Text(t.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                          subtitle: Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: DownloadProgressBar(t: t, height: 14),
                          ),
                          trailing: IconButton(
                            tooltip: tr('삭제 (중지하고 받던 파일 삭제)'),
                            icon: const Icon(Icons.delete_outline),
                            onPressed: () => d.remove([t]),
                          ),
                        ),
                    ]),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(context, false), child: Text(tr('돌아가기'))),
              FilledButton(
                onPressed: () => active.isEmpty ? Navigator.pop(context, true) : _quit(context),
                child: Text(tr('종료')),
              ),
            ],
          );
        },
      );
}
