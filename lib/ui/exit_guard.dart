import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app/app_controller.dart';
import '../app/download_manager.dart';
import '../app/copy_center.dart';
import '../app/live_sync.dart';
import '../services/downloader.dart' show DownloadState;
import '../l10n/tr.dart';

/// 끝내기 전에: 복사 · 이동이 돌고 있으면 묻는다 (멈추면 그 파일은 만들다 만 .jjpart 로 남지 않게 지운다). 끝내도 되면 true
Future<bool> confirmStopCopies(BuildContext context, AppController c) async {
  final n = CopyCenter.peekOf(c)?.activeCount ?? 0;
  if (n == 0) return true;
  final go = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      scrollable: true,
      title: Text(tr('복사 · 이동 중입니다')),
      content: Text(trf('복사 · 이동 {0}개가 아직 끝나지 않았습니다. 끝내면 멈추고, 복사하던 파일은 완성되지 않은 채로 남지 않게 지웁니다.', [n])),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('취소'))),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr('끝내기'))),
      ],
    ),
  );
  if (go == true) {
    for (final j in CopyCenter.peekOf(c)!.jobs.values) {
      if (!j.finished) j.cancel();
    }
  }
  return go == true;
}

/// Android 첫 화면에서 ← 로 앱을 끝낼 때: "백그라운드로 실행" 이 꺼져 있고 작업 (MKV · AI 자막 · 다운로드 · 실시간 동기화) 이
/// 돌고 있으면 그냥 끝내지 않고 묻는다 (멈추면 작업이 사라지므로). 백그라운드로 실행이 켜져 있으면 앱은 뒤로 가고 작업은 계속된다.
class ExitGuard extends StatelessWidget {
  final AppController c;
  final DownloadManager? downloads;
  final Widget child;
  const ExitGuard({super.key, required this.c, this.downloads, required this.child});

  static const _ch = MethodChannel('jj_mkvmaker/android');

  /// 시험용: Android 가 아니어도 Android 처럼
  @visibleForTesting
  static bool forceAndroid = false;

  /// 돌고 있는 작업 (글로)
  List<String> _running() {
    final live = LiveSync.instance;
    final dl = downloads?.tasks.where((t) => t.state == DownloadState.downloading || t.state == DownloadState.queued).length ?? 0;
    final copies = CopyCenter.peekOf(c)?.activeCount ?? 0;
    return [
      if (c.busy) c.currentJob ?? tr('MKV · AI 작업'),
      if (copies > 0) trf('복사 · 이동 {0}개', [copies]),
      if (dl > 0) trf('다운로드 {0}개', [dl]),
      if (live != null && live.watching.isNotEmpty) trf('실시간 동기화 {0}쌍', [live.watching.length]),
    ];
  }

  bool get _guard => (Platform.isAndroid || forceAndroid) && !c.settings.runInBackground && _running().isNotEmpty;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: c,
        builder: (context, _) => PopScope(
          canPop: !_guard,
          onPopInvokedWithResult: (didPop, _) async {
            if (didPop) return;
            final running = _running();
            final pick = await showDialog<String>(
              context: context,
              builder: (ctx) => AlertDialog(
                scrollable: true,
                title: Text(tr('작업이 진행 중입니다')),
                content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                  for (final r in running) Text('• $r'),
                  const SizedBox(height: 10),
                  Text(tr('"백그라운드로 실행" 이 꺼져 있어 앱을 끝내면 작업이 멈춥니다.')),
                ]),
                actions: [
                  TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('취소'))),
                  TextButton(onPressed: () => Navigator.pop(ctx, 'exit'), child: Text(tr('끝내기 (작업 멈춤)'))),
                  FilledButton(onPressed: () => Navigator.pop(ctx, 'back'), child: Text(tr('뒤로 보내고 계속'))),
                ],
              ),
            );
            if (pick == 'back') {
              try {
                await _ch.invokeMethod<void>('moveToBack');
              } catch (_) {}
            } else if (pick == 'exit') {
              await SystemNavigator.pop();
            }
          },
          child: child,
        ),
      );
}
