import 'package:flutter/material.dart';

import 'theme.dart';
import '../l10n/tr.dart';

/// 종료할 때 하는 일 한 가지
class ExitStep {
  final String label;
  final Future<void> Function() run;
  const ExitStep(this.label, this.run);
}

/// 종료를 눌렀을 때 고르기: 'quit' 모두 종료 / 'background' 백그라운드로 / null 취소.
/// 두 번째 값이 true 면 "다음부터 묻지 않기" (고른 것을 설정에 저장).
Future<(String, bool)?> showCloseChoice(BuildContext context, {required String running, required String hotkey}) =>
    showDialog<(String, bool)>(context: context, builder: (_) => _CloseChoice(running: running, hotkey: hotkey));

class _CloseChoice extends StatefulWidget {
  final String running, hotkey;
  const _CloseChoice({required this.running, required this.hotkey});

  @override
  State<_CloseChoice> createState() => _CloseChoiceState();
}

class _CloseChoiceState extends State<_CloseChoice> {
  bool _remember = false;

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(tr('종료할까요?')),
        content: SizedBox(
          width: 440,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(trf('지금: {0}', [widget.running]), style: const TextStyle(fontSize: 13)),
            const SizedBox(height: 10),
            Text(trf('· 백그라운드로: 창만 숨기고 다운로드 · 변환을 계속합니다 ({0} 또는 트레이 아이콘으로 다시 열기)\n' '· 모두 종료: 다운로드 · 변환을 멈추고 프로그램을 끝냅니다', [widget.hotkey]),
                style: const TextStyle(fontSize: 12, color: JjColors.textDim)),
            const SizedBox(height: 8),
            InkWell(
              onTap: () => setState(() => _remember = !_remember),
              child: Row(children: [
                Checkbox(value: _remember, onChanged: (v) => setState(() => _remember = v ?? false)),
                Flexible(
                    child: Text(tr('다음부터 묻지 않기 (환경 설정 > 실행 에서 바꿀 수 있음)'), style: TextStyle(fontSize: 12))),
              ]),
            ),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('취소'))),
          OutlinedButton(
              onPressed: () => Navigator.pop(context, ('quit', _remember)), child: Text(tr('모두 종료'))),
          FilledButton(
              autofocus: true,
              onPressed: () => Navigator.pop(context, ('background', _remember)),
              child: Text(tr('백그라운드로'))),
        ],
      );
}

/// 종료 진행 창: "종료 중입니다." → 바로 전 작업 → 단계별 진행 → "Have You Good Time"
///
/// 각 단계는 실패해도 (또는 [stepTimeout] 을 넘겨도) 다음으로 넘어간다 - 종료가 멈추면 안 되므로.
Future<void> showExitProgress(
  BuildContext context, {
  required String lastWork,
  required List<ExitStep> steps,
  Duration stepTimeout = const Duration(seconds: 8),
  Duration farewell = const Duration(milliseconds: 700),
}) =>
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _ExitProgress(lastWork: lastWork, steps: steps, stepTimeout: stepTimeout, farewell: farewell),
    );

class _ExitProgress extends StatefulWidget {
  final String lastWork;
  final List<ExitStep> steps;
  final Duration stepTimeout, farewell;
  const _ExitProgress(
      {required this.lastWork, required this.steps, required this.stepTimeout, required this.farewell});

  @override
  State<_ExitProgress> createState() => _ExitProgressState();
}

class _ExitProgressState extends State<_ExitProgress> {
  int _done = 0;
  bool _bye = false;

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    // 첫 화면 ("종료 중입니다.") 이 보인 뒤 시작
    await Future<void>.delayed(const Duration(milliseconds: 150));
    for (final s in widget.steps) {
      // 너무 빨리 지나가 읽을 수 없지 않도록 단계마다 잠깐은 보여 준다
      final shown = Future<void>.delayed(const Duration(milliseconds: 150));
      try {
        await s.run().timeout(widget.stepTimeout);
      } catch (_) {}
      await shown;
      if (!mounted) return;
      setState(() => _done++);
    }
    setState(() => _bye = true);
    await Future<void>.delayed(widget.farewell);
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) => PopScope(
        canPop: false,
        child: AlertDialog(
          title: Text(_bye ? 'Have You Good Time' : tr('종료 중입니다.')),
          content: SizedBox(
            width: 420,
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(trf('바로 전 작업: {0}', [widget.lastWork]),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12, color: JjColors.textDim)),
              const SizedBox(height: 12),
              for (final (i, s) in widget.steps.indexed)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Row(children: [
                    SizedBox(
                      width: 18,
                      height: 18,
                      child: i < _done
                          ? const Icon(Icons.check_circle, size: 18, color: JjColors.success)
                          : i == _done
                              ? const CircularProgressIndicator(strokeWidth: 2)
                              : const Icon(Icons.circle_outlined, size: 18, color: JjColors.textDim),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(s.label,
                          style: TextStyle(fontSize: 13, color: i <= _done ? JjColors.text : JjColors.textDim)),
                    ),
                  ]),
                ),
            ]),
          ),
        ),
      );
}
