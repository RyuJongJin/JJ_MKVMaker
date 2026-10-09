import 'package:flutter/material.dart';

import '../app/app_controller.dart';

/// 103: 코덱이 저절로 바뀌었으면 (크기 · 보정 때문에, 또는 원래대로 돌려서) 짧게 알린다
void showEncodeNotice(BuildContext context, AppController c) {
  final text = c.encodeNotice;
  if (text == null) return;
  c.encodeNotice = null;
  ScaffoldMessenger.maybeOf(context)
    ?..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text), duration: const Duration(seconds: 4)));
}
