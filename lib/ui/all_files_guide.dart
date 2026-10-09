import 'package:flutter/material.dart';

import '../app/app_controller.dart';
import '../l10n/tr.dart';

/// 39 · 116: 지금 권한 안내 창을 띄울 차례인지. 같은 안내를 거듭 띄우지 않되,
/// 권한이 있으면 표시를 지워 두어 권한이 없어진 뒤 (사용자가 끔 · 재설치) 다음에 켤 때 한 번 더 띄운다.
Future<bool> allFilesGuideDue(AppController c, {required bool hasAccess}) async {
  if (hasAccess) {
    if (c.settings.allFilesHintShown) await c.updateSettings((s) => s.allFilesHintShown = false);
    return false;
  }
  if (c.settings.allFilesHintShown) return false;
  await c.updateSettings((s) => s.allFilesHintShown = true);
  return true;
}

/// 116: 처음 켤 때 "모든 파일에 대한 접근" 안내 (분석 오류보다 먼저). [허용] 은 Android 설정 화면을 연다.
/// 허용하고 돌아오면 앱이 실패한 분석을 저절로 다시 한다.
Future<void> showAllFilesGuide(BuildContext context, Future<void> Function() request) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      scrollable: true,
      title: Text(tr('파일 접근 권한')),
      content: SizedBox(
        width: 480,
        child: Text('${tr('동영상을 고르고 MKV 를 만들려면 "모든 파일에 대한 접근" 권한이 필요합니다.')}\n\n'
            '${tr('[허용] 을 누르면 Android 설정이 열립니다. JJ_MKVMaker 를 허용하고 돌아오면, 읽지 못했던 동영상을 저절로 다시 분석합니다.')}'),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('나중에'))),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr('허용'))),
      ],
    ),
  );
  if (ok == true) await request();
}
