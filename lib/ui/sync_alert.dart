import '../app/live_sync.dart';
import '../core/vfs.dart';
import '../l10n/tr.dart';
import '../services/app_shell.dart';

/// 92: Windows 에서는 창을 닫아 트레이에 둔 채 실시간 동기화를 돌리는 일이 많다. 그때 원본을 못 읽어 멈추면
/// 카드 · 로그는 아무도 보지 않으므로: 새로 멈춘 쌍이 생기면 (창이 앞에 없을 때) Windows 알림 (토스트),
/// 트레이 툴팁에 "⚠ 동기화 멈춤 N개". 알림 · 트레이를 눌러 창을 열면 [openLsync] (모니터링 > lsync 카드).
class SyncAlert {
  final LiveSync live;
  final AppShell shell;
  final void Function() openLsync;

  /// 트레이 툴팁에 함께 보일 다른 글 (다운로드 개수 등)
  String Function() baseTooltip;

  /// Windows 알림을 띄울지 (환경 설정, 기본 켜짐). 꺼도 트레이 툴팁 경고는 남는다
  bool Function() toastEnabled;

  SyncAlert(this.live, this.shell, {required this.openLsync, required this.baseTooltip, bool Function()? toastEnabled})
      : toastEnabled = toastEnabled ?? (() => true) {
    live.addListener(_changed);
    shell.onTrayShown = () {
      if (live.problems.isNotEmpty) openLsync();
    };
  }

  /// 이미 알린 쌍 (다시 정상이 됐다가 또 멈추면 다시 알린다)
  final _told = <String>{};

  /// 트레이 툴팁 글 (다운로드 등 + 멈춘 동기화)
  String tooltip() {
    final base = baseTooltip();
    final n = live.problems.length;
    return n == 0 ? base : '$base · ${trf('⚠ 동기화 멈춤 {0}개', [n])}';
  }

  Future<void> _changed() async {
    final now = live.problems.keys.toSet();
    final fresh = now.difference(_told);
    _told
      ..removeWhere((k) => !now.contains(k))
      ..addAll(now);
    await shell.setTooltip(tooltip());
    if (fresh.isEmpty || !toastEnabled() || await shell.isInFront()) return;
    final e = live.problems[fresh.first]!;
    final more = fresh.length > 1 ? trf(' 외 {0}개', [fresh.length - 1]) : '';
    await shell.notify(
      tr('실시간 동기화가 멈췄습니다'),
      '${e.empty ? tr('원본 폴더가 비어 있어 멈췄습니다') : tr('원본을 읽을 수 없어 멈췄습니다')}$more\n'
          '${vDisplay(e.path)} · ${tr('대상 파일은 지우지 않았습니다.')}',
      onClick: openLsync,
    );
  }

  void dispose() => live.removeListener(_changed);
}
