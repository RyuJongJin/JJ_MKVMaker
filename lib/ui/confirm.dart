import 'package:flutter/material.dart';

import '../l10n/tr.dart';
import 'theme.dart';

/// 되돌리기 어려운 일 전에 한 번 묻는다 (46 · 47 등). [danger] 면 확인 버튼이 빨강. 확인하면 true
Future<bool> confirmAction(
  BuildContext context, {
  required String title,
  required String body,
  required String ok,
  bool danger = true,
}) async {
  final r = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      scrollable: true,
      title: Text(title),
      content: Text(body),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('취소'))),
        FilledButton(
          style: danger ? FilledButton.styleFrom(backgroundColor: JjColors.danger) : null,
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(ok),
        ),
      ],
    ),
  );
  return r == true;
}
