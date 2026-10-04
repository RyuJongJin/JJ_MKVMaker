import 'dart:async';

import 'package:flutter/services.dart';

import '../../app/app_controller.dart';
import '../../app/download_manager.dart';
import '../../services/downloader.dart';
import '../../l10n/tr.dart';

/// Android: 다운로드 · MKV 만들기 · AI 자막이 진행 중이면 포그라운드 서비스 (MainActivity.kt · KeepAliveService.kt)
/// 를 띄워 앱이 화면에서 내려가도 계속하게 하고, 알림에 진행 상황을 보여 준다. 모두 끝나면 내린다.
class AndroidKeepAlive {
  static const _ch = MethodChannel('jj_mkvmaker/android');

  final AppController c;
  final DownloadManager downloads;
  Timer? _timer;
  bool _on = false;
  String _last = '';

  AndroidKeepAlive(this.c, this.downloads) {
    c.addListener(_changed);
    downloads.addListener(_changed);
  }

  /// 진행률 알림은 자주 바뀌므로 1초에 한 번만 보낸다
  void _changed() => _timer ??= Timer(const Duration(seconds: 1), _apply);

  Future<void> _apply() async {
    _timer = null;
    // 일시정지한 다운로드는 세지 않는다 (받는 중 · 대기 중만)
    final running = downloads.tasks
        .where((t) => t.state == DownloadState.downloading || t.state == DownloadState.queued)
        .length;
    final (text, progress) = status(c.currentJob, c.busy, running, downloads.overallProgress);
    try {
      if (text == null) {
        if (_on) await _ch.invokeMethod<void>('stopKeepAlive');
        _on = false;
        _last = '';
        return;
      }
      final key = '$text|$progress';
      if (_on && key == _last) return;
      await _ch.invokeMethod<void>('keepAlive', {'text': text, 'progress': progress});
      _on = true;
      _last = key;
    } catch (_) {}
  }

  /// 알림 글과 진행률 (0~100, 모르면 -1). 진행 중인 일이 없으면 글이 null.
  static (String?, int) status(String? job, bool busy, int downloads, double? downloadProgress) {
    final parts = [
      if (busy) job ?? tr('작업 중'),
      if (downloads > 0) trf('다운로드 {0}개{1}', [downloads, downloadProgress == null ? '' : ' · ${(downloadProgress * 100).round()}%']),
    ];
    if (parts.isEmpty) return (null, -1);
    // 진행률 막대는 다운로드만 있을 때 (작업 진행률은 동영상마다 따로라 하나로 합치기 어렵다)
    final p = !busy && downloadProgress != null ? (downloadProgress * 100).round().clamp(0, 100) : -1;
    return (parts.join(' · '), p);
  }
}
