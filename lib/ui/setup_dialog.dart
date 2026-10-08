import 'package:flutter/material.dart';

import '../services/app_shell.dart';
import 'theme.dart';
import '../l10n/tr.dart';

/// 필수 프로그램 점검. 없으면 물어보고 내려받은 뒤 다시 시작한다.
/// [quietIfOk] 가 false 면 모두 있을 때도 알려 준다 (환경 설정에서 누른 경우).
Future<void> checkRequiredTools(BuildContext context, AppShell shell, {bool quietIfOk = true}) async {
  final missing = await shell.missingTools();
  if (!context.mounted) return;
  if (missing.isEmpty) {
    if (!quietIfOk) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(tr('필수 프로그램이 모두 설치되어 있습니다.'))));
    }
    return;
  }
  final go = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
        scrollable: true,
      title: Text(tr('필수 프로그램 설치')),
      content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(tr('아래 프로그램이 없어 일부 기능을 쓸 수 없습니다. 공식 배포처에서 내려받아 프로그램 폴더에 설치할까요?')),
        const SizedBox(height: 12),
        for (final m in missing) Text('• $m'),
        const SizedBox(height: 12),
        Text(tr('설치가 끝나면 프로그램이 다시 시작됩니다.'), style: TextStyle(fontSize: 12, color: JjColors.textDim)),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('나중에'))),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr('내려받기'))),
      ],
    ),
  );
  if (go != true || !context.mounted) return;

  final progress = ValueNotifier<(String, double)>(('', 0));
  String? error;
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => AlertDialog(
        scrollable: true,
      title: Text(tr('내려받는 중')),
      content: ValueListenableBuilder<(String, double)>(
        valueListenable: progress,
        builder: (_, v, _) => Column(mainAxisSize: MainAxisSize.min, children: [
          Text(v.$1.isEmpty ? tr('준비 중…') : '${v.$1}  ${(v.$2 * 100).round()}%'),
          const SizedBox(height: 12),
          LinearProgressIndicator(value: v.$1.isEmpty ? null : v.$2),
        ]),
      ),
    ),
  );
  try {
    await shell.installMissingTools((name, p) => progress.value = (name, p));
  } catch (e) {
    error = '$e';
  }
  if (!context.mounted) return;
  Navigator.of(context).pop();
  if (error != null) {
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        scrollable: true,
        title: Text(tr('설치 실패')),
        content: SelectableText(trf('인터넷 연결을 확인한 뒤 환경 설정 > 필수 프로그램 점검에서 다시 시도하세요.\n\n{0}', [error])),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('닫기')))],
      ),
    );
    return;
  }
  await shell.restart();
}
