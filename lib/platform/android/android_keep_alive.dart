import 'dart:async';

import 'package:flutter/services.dart';

import '../../app/app_controller.dart';
import '../../app/i18n_controller.dart';
import '../../app/ai_local.dart';
import '../../app/download_manager.dart';
import '../../app/copy_center.dart';
import '../../app/live_sync.dart';
import '../../services/downloader.dart';
import '../../l10n/tr.dart';

/// Android: 다운로드 · MKV 만들기 · AI 자막이 진행 중이면 포그라운드 서비스 (MainActivity.kt · KeepAliveService.kt)
/// 를 띄워 앱이 화면에서 내려가도 계속하게 하고, 알림에 진행 상황을 보여 준다. 모두 끝나면 내린다.
/// [AppSettings.runInBackground] 를 켜면 실시간 동기화를 지켜보는 동안에도 띄워 두고, 앱을 닫아도 (← · 최근 앱에서 밀기)
/// Dart 엔진을 살려 둔다 (MainActivity.setBackground).
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
    AiJobs.instance.addListener(_changed); // 123: AI 그림도 화면을 닫아도 계속
    i18n.addListener(_changed); // 57: 알림 글 · 채널 이름도 화면 언어로
    _changed();
  }

  LiveSync? _live;
  CopyCenter? _copies;
  AiStore? _ai;
  bool? _background;
  String? _textsKey;

  /// 57: 알림 제목 · "작업 멈춤" 알림 · 알림 채널 이름 (Android 설정 > 알림 에 보이는 이름) 을 화면 언어로
  static Map<String, String> notificationTexts() => {
        'working': tr('JJ_MKVMaker 작업 중'),
        'stoppedTitle': tr('JJ_MKVMaker 작업이 멈췄습니다'),
        'stoppedText': tr("앱을 닫아 진행 중이던 작업이 멈췄습니다. 닫아도 계속하려면 환경 설정에서 '백그라운드로 실행' 을 켜세요."),
        'stoppedLong': tr("앱을 닫아 진행 중이던 작업 (MKV · 다운로드 · 동기화) 이 멈췄습니다. 앱을 닫아도 계속하려면 환경 설정 > Rsync > '백그라운드로 실행' 을 켜세요."),
        'jobsChannel': tr('작업 진행'),
        'jobsChannelDesc': tr('다운로드 · MKV 만들기 · AI 자막 · 동기화 진행 상황'),
        'doneChannel': tr('끝난 작업'),
        'doneChannelDesc': tr('AI 해상도 올리기 등 오래 걸린 작업이 끝났을 때'),
      };

  /// 진행률 알림은 자주 바뀌므로 1초에 한 번만 보낸다
  void _changed() => _timer ??= Timer(const Duration(seconds: 1), _apply);

  Future<void> _apply() async {
    _timer = null;
    // 실시간 동기화 (나중에 만들어질 수도 있다)
    final live = LiveSync.instance;
    if (live != _live) {
      _live?.removeListener(_changed);
      _live = live?..addListener(_changed);
    }
    final texts = notificationTexts();
    final textsKey = texts.values.join('\u0000');
    if (textsKey != _textsKey) {
      try {
        await _ch.invokeMethod<void>('notificationTexts', texts);
        _textsKey = textsKey;
      } catch (_) {}
    }
    final bg = c.settings.runInBackground;
    if (bg != _background) {
      _background = bg;
      try {
        await _ch.invokeMethod<void>('setBackground', {'on': bg});
      } catch (_) {}
    }
    // 일시정지한 다운로드는 세지 않는다 (받는 중 · 대기 중만)
    final running = downloads.tasks
        .where((t) => t.state == DownloadState.downloading || t.state == DownloadState.queued)
        .length;
    final syncs = bg && live != null ? live.watching.length : 0;
    // 43: 탐색기 · Rsync 화면의 복사 · 이동도 백그라운드에서 살려 둔다
    final copies = CopyCenter.peekOf(c);
    if (copies != _copies) {
      _copies?.removeListener(_changed);
      _copies = copies?..addListener(_changed);
    }
    final copying = copies?.activeCount ?? 0;
    // 149: AI 모델 받기도 화면을 끄거나 다른 앱으로 가도 계속 (진행 알림)
    final store = AiStore.instance;
    if (store != _ai) {
      _ai?.removeListener(_changed);
      _ai = store?..addListener(_changed);
    }
    final ai = [AiJobs.instance.statusLine, store?.statusLine].nonNulls.join(' · ').trim();
    var (text, progress) =
        status(c.currentJob, c.busy, running, downloads.overallProgress,
            syncs: syncs, syncing: live?.anyRunning ?? false, copies: copying, stopped: live?.problems.length ?? 0);
    if (ai.isNotEmpty) {
      // 진행 알림에 남은 장 수와 예상 시간 (발열 · 배터리 때문에 쉬어 가지는 않는다 - 사용자 결정)
      text = text == null ? ai : '$ai · $text';
      final p = AiJobs.instance.progress ?? store?.progress.values.firstOrNull;
      if (!c.busy && running == 0 && p != null) progress = (p * 100).round().clamp(0, 100);
    }
    try {
      if (text == null) {
        if (_on) await _ch.invokeMethod<void>('stopKeepAlive');
        _on = false;
        _last = '';
        return;
      }
      // 알림 아이콘: 받는 중이면 내려받기, 아니면 (동기화 · 작업) 좌우로 오가는 화살표
      final icon = running > 0 ? 'download' : 'sync';
      final key = '$text|$progress|$icon';
      if (_on && key == _last) return;
      await _ch.invokeMethod<void>('keepAlive', {'text': text, 'progress': progress, 'icon': icon});
      _on = true;
      _last = key;
    } catch (_) {}
  }

  /// 알림 글과 진행률 (0~100, 모르면 -1). 진행 중인 일이 없으면 글이 null.
  /// [syncs] 백그라운드로 지켜보는 실시간 동기화 수 ([syncing] 지금 맞추는 중)
  static (String?, int) status(String? job, bool busy, int downloads, double? downloadProgress,
      {int syncs = 0, bool syncing = false, int copies = 0, int stopped = 0}) {
    final parts = [
      // 68: 원본을 읽지 못해 멈춘 동기화 (화면을 보지 않아도 알 수 있게 맨 앞에)
      if (stopped > 0) trf('⚠ 동기화 멈춤 {0}개 · 원본 확인 필요', [stopped]),
      if (busy) job ?? tr('작업 중'),
      if (copies > 0) trf('복사 · 이동 {0}개', [copies]),
      if (downloads > 0) trf('다운로드 {0}개{1}', [downloads, downloadProgress == null ? '' : ' · ${(downloadProgress * 100).round()}%']),
      if (syncs > 0) syncing ? trf('동기화 {0}개 · 맞추는 중', [syncs]) : trf('동기화 {0}개 지켜보는 중', [syncs]),
    ];
    if (parts.isEmpty) return (null, -1);
    // 진행률 막대는 다운로드만 있을 때 (작업 진행률은 동영상마다 따로라 하나로 합치기 어렵다)
    final p = !busy && downloadProgress != null ? (downloadProgress * 100).round().clamp(0, 100) : -1;
    return (parts.join(' · '), p);
  }
}
