import 'package:flutter/material.dart';

import '../app/app_controller.dart';
import '../app/bookmarks_controller.dart';
import '../app/components.dart';
import '../app/download_manager.dart';
import '../app/settings.dart';
import '../services/app_shell.dart' show appIconButtonAsset;
import '../services/system_usage.dart';
import 'browser_page.dart';
import 'downloads_page.dart';
import 'ai_image_page.dart';
import 'explorer_page.dart';
import 'settings_page.dart';
import 'theme.dart';
import '../l10n/tr.dart';

/// 모든 화면의 위쪽 막대 높이 · 오른쪽 여백 (환경 설정 · 종료 버튼이 어느 화면에서나 같은 자리에 오도록)
const double appBarHeight = 56;
const double appBarRightPadding = 12;

/// 이보다 좁으면 (접은 폴드 · 휴대폰 세로 등) 위쪽 막대를 두 줄로: 위 = 화면 이동 · 설정 · 종료, 아래 = 화면의 도구
const double compactWidth = 720;
bool isCompact(BuildContext context) => MediaQuery.sizeOf(context).width < compactWidth;

/// 모든 화면의 위쪽 막대: [nav] [middle (남는 너비)] [actions].
/// 좁은 화면에서는 두 줄 - 위: [nav] … [actions], 아래: [middle] 이 한 줄을 다 쓴다.
class AppTopBar extends StatelessWidget {
  final Widget nav;
  final Widget middle;
  final Widget actions;
  const AppTopBar({super.key, required this.nav, required this.middle, required this.actions});

  @override
  Widget build(BuildContext context) {
    if (!isCompact(context)) {
      return Container(
        height: appBarHeight,
        color: JjColors.panel,
        padding: const EdgeInsets.only(left: 8, right: appBarRightPadding),
        child: Row(children: [nav, const SizedBox(width: 8), Expanded(child: middle), actions]),
      );
    }
    return Container(
      color: JjColors.panel,
      padding: const EdgeInsets.only(left: 4, right: 4),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        // 아주 좁으면 왼쪽 이동 버튼 묶음을 줄여서라도 설정 · 종료가 밀려나지 않게
        SizedBox(
          height: 48,
          child: Row(children: [
            Expanded(child: Align(alignment: Alignment.centerLeft, child: FittedBox(fit: BoxFit.scaleDown, child: nav))),
            actions,
          ]),
        ),
        SizedBox(height: 48, child: Padding(padding: const EdgeInsets.only(left: 6), child: middle)),
      ]),
    );
  }
}

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
///   [JJ] 홈 화면 (환경 설정의 "홈 화면": MKV 화면 · 웹 브라우저 · 파일 탐색기)
///   [▤] MKV 화면으로   [🌐] 웹 브라우저   [📁] 파일 탐색기   [←] 뒤로   [⇩] 다운로드 목록
class AppNavButtons extends StatelessWidget {
  /// 다운로드 목록 화면 자신 (그 버튼을 "지금 여기" 로 표시)
  final bool onDownloadsPage;

  /// 웹 브라우저 화면 자신
  final bool onBrowserPage;

  /// 파일 탐색기 화면 자신
  final bool onExplorerPage;

  /// Rsync 화면 자신
  final bool onRsyncPage;

  /// AI 그림 화면 자신 (123)
  final bool onAiPage;
  const AppNavButtons(
      {super.key,
      this.onDownloadsPage = false,
      this.onBrowserPage = false,
      this.onExplorerPage = false,
      this.onRsyncPage = false,
      this.onAiPage = false});

  /// 버튼 줄의 가장 넓은 폭 (JJ · 화면 6개 · 뒤로)
  static const double width = 8 * 40;

  /// MKV 화면 (맨 처음 화면) 까지 돌아가기
  static void toMkv(BuildContext context) => Navigator.of(context).popUntil((r) => r.isFirst);

  /// 홈 화면 (환경 설정의 "홈 화면") 의 컴포넌트 id. 그 컴포넌트를 제거했으면 설치된 첫 화면.
  static String homeId(AppSettings s) {
    final want = switch (s.startScreen) { 'browser' => 'browser', 'files' => 'explorer', _ => 'mkv' };
    final pages = AppComponent.pages(s.components, s.navOrder);
    if (pages.any((p) => p.id == want)) return want;
    return pages.isEmpty ? 'mkv' : pages.first.id;
  }

  /// 그 화면으로 (이미 열려 있으면 그 화면으로 돌아감). 'mkv' 는 맨 처음 화면.
  static Future<void> openPage(NavigatorState nav, String id,
      {required AppController c, DownloadManager? downloads, BookmarksController? bookmarks}) async {
    switch (id) {
      case 'mkv':
        nav.popUntil((r) => r.isFirst);
      case 'browser':
        if (bookmarks != null) await BrowserPage.open(nav, c: c, downloads: downloads, bookmarks: bookmarks);
      case 'explorer':
        await ExplorerPage.open(nav, c: c);
      case 'rsync':
        await ExplorerPage.openRsync(nav, c: c);
      case 'downloads':
        if (downloads != null) await DownloadsPage.open(nav, downloads);
      case 'aiimage':
        await AiImagePage.open(nav, c: c);
    }
  }

  /// 이 창에서 열 수 있는 화면 (브라우저 · 다운로드가 없는 새 창에서는 그 둘을 뺀다)
  static List<AppComponent> pagesOf(AppScope scope) => [
        for (final p in AppComponent.pages(scope.controller.settings.components, scope.controller.settings.navOrder))
          if ((p.id != 'browser' || scope.bookmarks != null) && (p.id != 'downloads' || scope.downloads != null)) p,
      ];

  static void open(BuildContext context, String id) {
    final scope = AppScope.maybeOf(context);
    if (scope == null) return;
    openPage(Navigator.of(context), id, c: scope.controller, downloads: scope.downloads, bookmarks: scope.bookmarks);
  }

  /// 홈 화면으로: MKV 화면까지 돌아간 뒤, 홈 화면이 다른 화면이면 그 화면을 연다
  static void toHome(BuildContext context) {
    final scope = AppScope.maybeOf(context);
    final nav = Navigator.of(context);
    nav.popUntil((r) => r.isFirst);
    if (scope == null) return;
    final id = homeId(scope.controller.settings);
    if (id != 'mkv') open(context, id);
  }

  /// 지금 화면에서 [step] 만큼 (−1 이전 · +1 다음) 옮긴 화면으로. 끝 다음은 처음으로.
  static void step(BuildContext context, String current, int step) {
    final scope = AppScope.maybeOf(context);
    if (scope == null) return;
    final pages = pagesOf(scope);
    if (pages.length < 2) return;
    var i = pages.indexWhere((p) => p.id == current);
    if (i < 0) i = 0;
    final j = i + step;
    // 102 · 66: 끝에서 처음으로 돌기를 끄면 끝에서 멈춘다
    final wraps = j < 0 || j >= pages.length;
    if (!scope.controller.settings.swipeWrap && wraps) {
      _hint(context, step > 0 ? tr('마지막 화면입니다') : tr('첫 화면입니다'));
      return;
    }
    final target = pages[j % pages.length];
    // 66-2: 민 방향으로 미끄러져 들어오게 (다음 = 오른쪽에서, 이전 = 왼쪽에서). 이미 열린 화면으로 돌아가면 그 화면의 전환대로
    NavSlide.pending = step > 0 ? 1 : -1;
    Future<void>.delayed(const Duration(milliseconds: 600), () => NavSlide.pending = 0);
    // 66-2: 끝에서 처음으로 (처음에서 끝으로) 넘어갈 때 알린다 - 어디로 갔는지 몰라 헤매지 않게
    if (wraps) {
      _hint(context, step > 0 ? trf('처음으로: {0}', [tr(target.name)]) : trf('마지막으로: {0}', [tr(target.name)]));
    }
    open(context, target.id);
  }

  static void _hint(BuildContext context, String text) {
    final m = ScaffoldMessenger.maybeOf(context);
    m?.hideCurrentSnackBar();
    m?.showSnackBar(SnackBar(content: Text(text), duration: const Duration(milliseconds: 1500)));
  }

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.maybeOf(context);
    // 컴포넌트 설치 · 순서를 바꾸면 바로 다시 그린다 (이 위젯은 const 로 쓰여 부모가 다시 그려도 그대로이므로)
    if (scope == null) return _build(context, null);
    return ListenableBuilder(listenable: scope.controller, builder: (context, _) => _build(context, scope));
  }

  Widget _build(BuildContext context, AppScope? scope) {
    final nav = Navigator.maybeOf(context);
    final atRoot = !(nav?.canPop() ?? false);
    final current = onDownloadsPage
        ? 'downloads'
        : onBrowserPage
            ? 'browser'
            : onExplorerPage
                ? 'explorer'
                : onRsyncPage
                    ? 'rsync'
                    : onAiPage
                        ? 'aiimage'
                        : atRoot
                        ? 'mkv'
                        : '';
    final pages = scope == null ? const <AppComponent>[] : pagesOf(scope);
    final homeName = switch (scope == null ? 'mkv' : homeId(scope.controller.settings)) {
      'browser' => tr('웹 브라우저'),
      'explorer' => tr('파일 탐색기'),
      'rsync' => 'Rsync',
      'downloads' => tr('다운로드 목록'),
      _ => tr('MKV 화면'),
    };
    String tip(String id, bool here) => switch (id) {
          'mkv' => here ? tr('MKV 화면 (지금 여기)') : tr('MKV 화면으로'),
          'browser' => here ? tr('웹 브라우저 (지금 여기)') : tr('웹 브라우저'),
          'explorer' => here ? tr('파일 탐색기 (지금 여기)') : tr('파일 탐색기'),
          'rsync' => here ? tr('Rsync (지금 여기)') : 'Rsync',
          'downloads' => here ? tr('다운로드 목록 (지금 여기)') : tr('다운로드 목록'),
          'aiimage' => here ? tr('AI 그림 (지금 여기)') : tr('AI 그림'),
          _ => id,
        };
    // 좁은 화면 (폰): 아이콘 아래에 짧은 이름 - 글자 없는 작은 아이콘만 늘어서 무엇인지 몰랐던 것
    final labels = isCompact(context);
    Widget btn(Widget icon, String tip, VoidCallback? f, {bool here = false, String label = ''}) => labels
        ? Tooltip(
            message: tip,
            child: InkWell(
              onTap: f,
              borderRadius: BorderRadius.circular(8),
              // 66-2: 지금 화면 아이콘은 파랗게 · 뒤에 옅은 바탕
              child: Container(
                decoration: here
                    ? BoxDecoration(color: JjColors.accent.withValues(alpha: 0.16), borderRadius: BorderRadius.circular(8))
                    : null,
                width: 54,
                height: 46,
                child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                  IconTheme(
                    data: IconThemeData(
                        size: 20, color: here ? JjColors.accent : (f == null ? JjColors.textDim : JjColors.text)),
                    child: icon,
                  ),
                  const SizedBox(height: 2),
                  Text(label,
                      maxLines: 1,
                      overflow: TextOverflow.clip,
                      style: TextStyle(fontSize: 10, color: here ? JjColors.accent : JjColors.textDim)),
                ]),
              ),
            ),
          )
        : SizedBox(
            width: 40,
            height: 40,
            child: IconButton(
              tooltip: tip,
              padding: EdgeInsets.zero,
              isSelected: here,
              // 66-2: 지금 화면 아이콘은 파랗게 · 뒤에 옅은 바탕 (넓은 화면에서도 어디인지 보이게)
              style: here
                  ? IconButton.styleFrom(
                      foregroundColor: JjColors.accent, backgroundColor: JjColors.accent.withValues(alpha: 0.16))
                  : null,
              icon: icon,
              onPressed: f,
            ),
          );
    String short(String id) => switch (id) {
          'mkv' => 'MKV',
          'browser' => tr('브라우저'),
          'explorer' => tr('탐색기'),
          'rsync' => 'Rsync',
          'downloads' => tr('다운로드'),
          'aiimage' => tr('AI 그림'),
          _ => id,
        };
    return Row(mainAxisSize: MainAxisSize.min, children: [
      btn(
        Image.asset(appIconButtonAsset(scope?.controller.settings.appIcon),
            width: labels ? 22 : 26, height: labels ? 22 : 26, filterQuality: FilterQuality.medium),
        trf('홈 화면 ({0}) · 환경 설정에서 바꿈', [homeName]),
        scope == null ? null : () => toHome(context),
        label: tr('홈'),
      ),
      // 설치한 화면들 (환경 설정 > 컴포넌트 의 순서). 하나뿐이면 버튼 줄은 그것만.
      for (final p in pages)
        btn(
          Icon(p.icon, color: p.id == current ? JjColors.accent : null),
          tip(p.id, p.id == current),
          p.id == current ? null : () => open(context, p.id),
          here: p.id == current,
          label: short(p.id),
        ),
      btn(const Icon(Icons.arrow_back), tr('뒤로'),
          // 브라우저 화면: 뒤로 키는 웹 페이지 뒤로 (PopScope) 이지만 이 버튼은 화면 이동이라 바로 닫는다
          atRoot ? null : () => onBrowserPage ? Navigator.pop(context) : Navigator.maybePop(context),
          label: tr('뒤로')),
    ]);
  }
}

/// 화면 가운데를 좌우로 밀면 다음 · 이전 화면으로 (환경 설정 > 컴포넌트 의 순서, 끝 다음은 처음).
/// 안쪽의 옆으로 밀리는 것 (가로 목록 · 막대) 이 먼저 받고, 위 · 아래 가장자리 (1/5) 에서 시작한 것은 무시한다.
class SwipeNav extends StatefulWidget {
  final String current;
  final Widget child;

  /// 높이 어디서 시작해도 (위쪽 막대처럼 작은 곳에 씌울 때)
  final bool anywhere;
  const SwipeNav({super.key, required this.current, required this.child, this.anywhere = false});

  @override
  State<SwipeNav> createState() => _SwipeNavState();
}

class _SwipeNavState extends State<SwipeNav> {
  bool _middle = false;

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.maybeOf(context);
    if (scope == null) return widget.child;
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onHorizontalDragStart: (d) {
        final h = context.size?.height ?? 0;
        _middle = widget.anywhere || (h > 0 && d.localPosition.dy > h * 0.2 && d.localPosition.dy < h * 0.8);
      },
      onHorizontalDragEnd: (d) {
        final v = d.primaryVelocity ?? 0;
        // 켜고 끄기는 밀 때 확인 (이 위젯은 설정이 바뀌어도 다시 그려지지 않을 수 있음)
        if (!scope.controller.settings.swipeNav || !_middle || v.abs() < 500) return;
        // 왼쪽으로 밀면 다음 화면, 오른쪽으로 밀면 이전 화면
        AppNavButtons.step(context, widget.current, v < 0 ? 1 : -1);
      },
      child: widget.child,
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
    final compact = isCompact(context);
    if (compact) {
      return Row(mainAxisSize: MainAxisSize.min, children: [
        if (controller != null)
          IconButton(
            tooltip: tr('환경 설정'),
            icon: Icon(onSettingsPage ? Icons.settings : Icons.settings_outlined,
                color: onSettingsPage ? JjColors.accent : null),
            onPressed: onSettingsPage
                ? null
                : () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => SettingsPage(c: controller))),
          ),
        PopupMenuButton<String>(
          tooltip: tr('화면 크기 · 종료'),
          icon: const Icon(Icons.more_vert),
          onSelected: (v) {
            final s = controller?.settings;
            switch (v) {
              case 'bigger' when s != null:
                controller!.updateSettings((x) => x.uiScale = AppSettings.clampUiScale(s.uiScale + 0.1));
              case 'smaller' when s != null:
                controller!.updateSettings((x) => x.uiScale = AppSettings.clampUiScale(s.uiScale - 0.1));
              case 'default' when s != null:
                controller!.updateSettings((x) => x.uiScale = s.uiScaleDefault);
              case 'exit':
                exit?.call();
            }
          },
          itemBuilder: (_) => [
            if (controller != null) ...[
              PopupMenuItem(
                  value: 'bigger',
                  child: ListTile(leading: const Icon(Icons.zoom_in), title: Text(tr('화면 크게')), dense: true)),
              PopupMenuItem(
                  value: 'smaller',
                  child: ListTile(leading: const Icon(Icons.zoom_out), title: Text(tr('화면 작게')), dense: true)),
              PopupMenuItem(
                  value: 'default',
                  child: ListTile(
                      leading: const Icon(Icons.fit_screen_outlined),
                      title: Text(trf('기본 크기 ({0}%)', [(controller.settings.uiScaleDefault * 100).round()])),
                      subtitle: Text(trf('지금 {0}%', [(controller.settings.uiScale * 100).round()])),
                      dense: true)),
            ],
            if (exit != null) ...[
              const PopupMenuDivider(),
              PopupMenuItem(
                  value: 'exit',
                  child: ListTile(
                      leading: const Icon(Icons.power_settings_new, color: JjColors.danger),
                      title: Text(tr('종료')),
                      dense: true)),
            ],
          ],
        ),
      ]);
    }
    return Row(mainAxisSize: MainAxisSize.min, children: [
      // CPU · MEM: 변환 · AI 작업이 PC 를 얼마나 쓰는지 (PC 전체 기준)
      if (usage != null && showUsage && !compact) UsageView(usage: usage),
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
