import 'package:flutter/material.dart';

import '../app/app_controller.dart';
import '../app/bookmarks_controller.dart';
import '../app/download_manager.dart';
import '../app/settings.dart';
import '../services/app_shell.dart' show appIconButtonAsset;
import '../services/system_usage.dart';
import 'browser_page.dart';
import 'downloads_page.dart';
import 'settings_page.dart';
import 'theme.dart';
import '../l10n/tr.dart';

/// 모든 화면의 위쪽 막대 높이 · 오른쪽 여백 (환경 설정 · 종료 버튼이 어느 화면에서나 같은 자리에 오도록)
const double appBarHeight = 56;
const double appBarRightPadding = 12;

/// 앱 전체에서 쓰는 것 (환경 설정을 열 컨트롤러 · 종료 동작) 을 화면들에 내려 준다
class AppScope extends InheritedWidget {
  final AppController controller;

  /// 종료 버튼을 눌렀을 때 (없으면 버튼을 숨김)
  final VoidCallback? onExit;

  /// 다운로드 목록 · 웹 브라우저 (홈 화면이 브라우저일 때). 새 창 (재생 창) 에서는 없음.
  final DownloadManager? downloads;
  final BookmarksController? bookmarks;

  const AppScope(
      {super.key, required this.controller, this.onExit, this.downloads, this.bookmarks, required super.child});

  static AppScope? maybeOf(BuildContext context) => context.dependOnInheritedWidgetOfExactType<AppScope>();

  @override
  bool updateShouldNotify(AppScope old) =>
      controller != old.controller || onExit != old.onExit || downloads != old.downloads || bookmarks != old.bookmarks;
}

/// 모든 화면의 위쪽 막대 맨 왼쪽 (같은 자리 · 같은 순서):
///   [JJ] 홈 화면 (환경 설정의 "홈 화면": MKV 화면 또는 웹 브라우저)
///   [▤] MKV 화면으로   [←] 뒤로   [⇩] 다운로드 목록
class AppNavButtons extends StatelessWidget {
  /// 다운로드 목록 화면 자신 (그 버튼을 "지금 여기" 로 표시)
  final bool onDownloadsPage;

  /// 웹 브라우저 화면 자신
  final bool onBrowserPage;
  const AppNavButtons({super.key, this.onDownloadsPage = false, this.onBrowserPage = false});

  static const double width = 5 * 40;

  /// MKV 화면 (맨 처음 화면) 까지 돌아가기
  static void toMkv(BuildContext context) => Navigator.of(context).popUntil((r) => r.isFirst);

  /// 홈 화면으로: MKV 화면까지 돌아간 뒤, 홈 화면이 웹 브라우저면 브라우저를 연다
  static void toHome(BuildContext context) {
    final scope = AppScope.maybeOf(context);
    final nav = Navigator.of(context);
    nav.popUntil((r) => r.isFirst);
    if (scope != null && scope.controller.settings.startScreen == 'browser' && scope.bookmarks != null) {
      BrowserPage.open(nav, c: scope.controller, downloads: scope.downloads, bookmarks: scope.bookmarks!);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.maybeOf(context);
    final nav = Navigator.maybeOf(context);
    final atRoot = !(nav?.canPop() ?? false);
    final homeIsBrowser = scope?.controller.settings.startScreen == 'browser' && scope?.bookmarks != null;
    final downloads = scope?.downloads;
    Widget btn(Widget icon, String tip, VoidCallback? f, {bool here = false}) => SizedBox(
          width: 40,
          height: 40,
          child: IconButton(
            tooltip: tip,
            padding: EdgeInsets.zero,
            isSelected: here,
            icon: icon,
            onPressed: f,
          ),
        );
    return SizedBox(
      width: width,
      child: Row(children: [
        btn(
          Image.asset(appIconButtonAsset(scope?.controller.settings.appIcon),
              width: 26, height: 26, filterQuality: FilterQuality.medium),
          trf('홈 화면 ({0}) · 환경 설정에서 바꿈', [homeIsBrowser ? tr('웹 브라우저') : tr('MKV 화면')]),
          scope == null ? null : () => toHome(context),
        ),
        btn(
          Icon(Icons.video_library_outlined, color: atRoot ? JjColors.accent : null),
          atRoot ? tr('MKV 화면 (지금 여기)') : tr('MKV 화면으로'),
          atRoot ? null : () => toMkv(context),
          here: atRoot,
        ),
        // 웹 브라우저: MKV 화면 버튼 다음 (모든 화면 같은 자리)
        btn(
          Icon(Icons.public, color: onBrowserPage ? JjColors.accent : null),
          onBrowserPage ? tr('웹 브라우저 (지금 여기)') : tr('웹 브라우저'),
          scope?.bookmarks == null || onBrowserPage
              ? null
              : () => BrowserPage.open(Navigator.of(context),
                  c: scope!.controller, downloads: scope.downloads, bookmarks: scope.bookmarks!),
          here: onBrowserPage,
        ),
        btn(const Icon(Icons.arrow_back), tr('뒤로'), atRoot ? null : () => Navigator.maybePop(context)),
        btn(
          Icon(Icons.download_for_offline_outlined, color: onDownloadsPage ? JjColors.accent : null),
          onDownloadsPage ? tr('다운로드 목록 (지금 여기)') : tr('다운로드 목록'),
          downloads == null || onDownloadsPage
              ? null
              : () => DownloadsPage.open(Navigator.of(context), downloads),
          here: onDownloadsPage,
        ),
      ]),
    );
  }
}

/// "CPU 23%  MEM 61%" (90% 넘으면 빨갛게). 글자 폭이 바뀌어도 옆 버튼이 움직이지 않게 너비를 고정한다.
class UsageView extends StatelessWidget {
  final UsageMonitor usage;
  const UsageView({super.key, required this.usage});

  static String _gb(int bytes) => (bytes / (1024 * 1024 * 1024)).toStringAsFixed(1);

  /// 남은 용량: "128GB" · "1.8TB" · "950MB"
  static String _size(int bytes) {
    const gb = 1024 * 1024 * 1024;
    if (bytes >= 1000 * gb) return '${(bytes / (1024 * gb)).toStringAsFixed(1)}TB';
    if (bytes >= gb) return '${(bytes / gb).toStringAsFixed(bytes < 10 * gb ? 1 : 0)}GB';
    return '${(bytes / (1024 * 1024)).round()}MB';
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<UsageSample?>(
        valueListenable: usage,
        builder: (context, s, _) {
          Widget cell(String label, String value, bool hot, double width) {
            return SizedBox(
              width: width,
              child: Text.rich(
                TextSpan(children: [
                  TextSpan(text: '$label ', style: const TextStyle(color: JjColors.textDim)),
                  TextSpan(
                      text: value,
                      style: TextStyle(
                          color: hot ? JjColors.danger : JjColors.text, fontWeight: FontWeight.w600)),
                ]),
                maxLines: 1,
                softWrap: false,
                style: const TextStyle(fontSize: 11, fontFamily: 'Consolas'),
              ),
            );
          }

          Widget item(String label, double? v) =>
              cell(label, v == null ? '--%' : '${(v * 100).round()}%', v != null && v >= 0.9, 62);
          final free = s?.diskFree;

          return Tooltip(
            message: s == null
                ? tr('PC 전체 CPU · 메모리 사용량')
                : trf('PC 전체 사용량\nCPU {0}%\n' '메모리 {1} / {2}GB ({3}%)' '{4}', [(s.cpu * 100).round(), _gb(s.memUsed), _gb(s.memTotal), (s.mem * 100).round(), free == null ? '' : trf('\n다운로드 디스크 {0} 남은 용량 {1}' '{2}', [s.disk, _size(free), s.diskTotal == null ? '' : trf(' / 전체 {0}', [_size(s.diskTotal!)])])]),
            child: Padding(
              padding: const EdgeInsets.only(left: 8),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                item('CPU', s?.cpu),
                item('MEM', s?.mem),
                // 다운로드 대상 디스크의 남은 용량
                if (free != null) cell('DISK', _size(free), s!.diskLow, 84),
              ]),
            ),
          );
        },
      );
}

/// 화면 크기 조절: [−] [100%] [+]. 10% 씩 바꾸고, 가운데 숫자를 누르면 환경 설정의 기본 크기로.
class ScaleButtons extends StatelessWidget {
  final AppController c;
  const ScaleButtons({super.key, required this.c});

  void _set(double v) => c.updateSettings((s) => s.uiScale = AppSettings.clampUiScale(v));

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: c,
        builder: (context, _) {
          final s = c.settings.uiScale;
          Widget btn(IconData icon, String tip, VoidCallback? f) => SizedBox(
                width: 26,
                height: 32,
                child: IconButton(
                  tooltip: tip,
                  padding: EdgeInsets.zero,
                  iconSize: 16,
                  icon: Icon(icon),
                  onPressed: f,
                ),
              );
          return Padding(
            padding: const EdgeInsets.only(left: 6),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              btn(Icons.remove, tr('화면 작게'), s <= AppSettings.uiScaleMin + 0.001 ? null : () => _set(s - 0.1)),
              Tooltip(
                message: trf('기본 크기 ({0}%) 로 · 기본 크기는 환경 설정 > 화면 에서', [(c.settings.uiScaleDefault * 100).round()]),
                child: InkWell(
                  borderRadius: BorderRadius.circular(4),
                  onTap: () => _set(c.settings.uiScaleDefault),
                  child: SizedBox(
                    width: 40,
                    height: 28,
                    child: Center(
                      child: Text('${(s * 100).round()}%',
                          style: const TextStyle(fontSize: 11, fontFamily: 'Consolas', fontWeight: FontWeight.w600)),
                    ),
                  ),
                ),
              ),
              btn(Icons.add, tr('화면 크게'), s >= AppSettings.uiScaleMax - 0.001 ? null : () => _set(s + 0.1)),
            ]),
          );
        },
      );
}

/// 화면 전체를 [AppSettings.uiScale] 배로 그린다 (안쪽은 그만큼 작은 · 큰 화면이라고 여기고 배치).
/// 앱의 builder 에서 한 번 감싼다 - 대화 상자 · 메뉴 · 안내 글까지 모두 같은 배율.
class UiScaler extends StatelessWidget {
  final AppController c;
  final Widget child;
  const UiScaler({super.key, required this.c, required this.child});

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: c,
        builder: (context, _) {
          final s = c.settings.uiScale;
          if ((s - 1).abs() < 0.001) return child;
          return LayoutBuilder(builder: (context, box) {
            final size = box.biggest / s;
            final mq = MediaQuery.of(context);
            return ClipRect(
              child: OverflowBox(
                alignment: Alignment.topLeft,
                minWidth: size.width,
                maxWidth: size.width,
                minHeight: size.height,
                maxHeight: size.height,
                child: Transform.scale(
                  scale: s,
                  alignment: Alignment.topLeft,
                  child: MediaQuery(data: mq.copyWith(size: size), child: child),
                ),
              ),
            );
          });
        },
      );
}

/// 환경 설정 · 종료 버튼. 모든 화면의 위쪽 막대 맨 오른쪽에 같은 크기로 놓는다.
class AppActions extends StatelessWidget {
  /// 직접 주지 않으면 [AppScope] 의 것을 쓴다
  final AppController? c;
  final VoidCallback? onExit;

  /// 환경 설정 화면 자신: 설정 버튼을 "지금 여기" 로 표시하고 누를 수 없게
  final bool onSettingsPage;

  /// 창이 좁을 때 CPU · MEM · DISK 를 숨긴다 (버튼 자리는 그대로)
  final bool showUsage;

  const AppActions({super.key, this.c, this.onExit, this.onSettingsPage = false, this.showUsage = true});

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.maybeOf(context);
    final controller = c ?? scope?.controller;
    final exit = onExit ?? scope?.onExit;
    if (controller == null && exit == null) return const SizedBox();
    final usage = controller?.usage;
    return Row(mainAxisSize: MainAxisSize.min, children: [
      // CPU · MEM: 변환 · AI 작업이 PC 를 얼마나 쓰는지 (PC 전체 기준)
      if (usage != null && showUsage) UsageView(usage: usage),
      // 화면 크기: −  100%  +
      if (controller != null) ScaleButtons(c: controller),
      const SizedBox(width: 4),
      if (controller != null)
        IconButton(
          tooltip: tr('환경 설정'),
          icon: Icon(onSettingsPage ? Icons.settings : Icons.settings_outlined,
              color: onSettingsPage ? JjColors.accent : null),
          onPressed: onSettingsPage
              ? null
              : () => Navigator.push(
                  context, MaterialPageRoute<void>(builder: (_) => SettingsPage(c: controller))),
        ),
      if (exit != null)
        IconButton(
          tooltip: tr('종료'),
          icon: const Icon(Icons.power_settings_new, color: JjColors.danger),
          onPressed: exit,
        ),
    ]);
  }
}
