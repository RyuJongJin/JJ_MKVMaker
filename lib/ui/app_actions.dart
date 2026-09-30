import 'package:flutter/material.dart';

import '../app/app_controller.dart';
import '../services/system_usage.dart';
import 'settings_page.dart';
import 'theme.dart';

/// 모든 화면의 위쪽 막대 높이 · 오른쪽 여백 (환경 설정 · 종료 버튼이 어느 화면에서나 같은 자리에 오도록)
const double appBarHeight = 56;
const double appBarRightPadding = 12;

/// 앱 전체에서 쓰는 것 (환경 설정을 열 컨트롤러 · 종료 동작) 을 화면들에 내려 준다
class AppScope extends InheritedWidget {
  final AppController controller;

  /// 종료 버튼을 눌렀을 때 (없으면 버튼을 숨김)
  final VoidCallback? onExit;

  const AppScope({super.key, required this.controller, this.onExit, required super.child});

  static AppScope? maybeOf(BuildContext context) => context.dependOnInheritedWidgetOfExactType<AppScope>();

  @override
  bool updateShouldNotify(AppScope old) => controller != old.controller || onExit != old.onExit;
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
                ? 'PC 전체 CPU · 메모리 사용량'
                : 'PC 전체 사용량\nCPU ${(s.cpu * 100).round()}%\n'
                    '메모리 ${_gb(s.memUsed)} / ${_gb(s.memTotal)}GB (${(s.mem * 100).round()}%)'
                    '${free == null ? '' : '\n다운로드 디스크 ${s.disk} 남은 용량 ${_size(free)}'
                        '${s.diskTotal == null ? '' : ' / 전체 ${_size(s.diskTotal!)}'}'}',
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

/// 환경 설정 · 종료 버튼. 모든 화면의 위쪽 막대 맨 오른쪽에 같은 크기로 놓는다.
class AppActions extends StatelessWidget {
  /// 직접 주지 않으면 [AppScope] 의 것을 쓴다
  final AppController? c;
  final VoidCallback? onExit;

  /// 환경 설정 화면 자신: 설정 버튼을 "지금 여기" 로 표시하고 누를 수 없게
  final bool onSettingsPage;

  const AppActions({super.key, this.c, this.onExit, this.onSettingsPage = false});

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.maybeOf(context);
    final controller = c ?? scope?.controller;
    final exit = onExit ?? scope?.onExit;
    if (controller == null && exit == null) return const SizedBox();
    final usage = controller?.usage;
    return Row(mainAxisSize: MainAxisSize.min, children: [
      // CPU · MEM: 변환 · AI 작업이 PC 를 얼마나 쓰는지 (PC 전체 기준)
      if (usage != null) UsageView(usage: usage),
      const SizedBox(width: 4),
      if (controller != null)
        IconButton(
          tooltip: '환경 설정',
          icon: Icon(onSettingsPage ? Icons.settings : Icons.settings_outlined,
              color: onSettingsPage ? JjColors.accent : null),
          onPressed: onSettingsPage
              ? null
              : () => Navigator.push(
                  context, MaterialPageRoute<void>(builder: (_) => SettingsPage(c: controller))),
        ),
      if (exit != null)
        IconButton(
          tooltip: '종료',
          icon: const Icon(Icons.power_settings_new, color: JjColors.danger),
          onPressed: exit,
        ),
    ]);
  }
}
