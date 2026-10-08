import 'package:flutter/material.dart';

import '../app/app_controller.dart';
import '../l10n/tr.dart';

/// 설정 파일을 읽지 못했으면 켤 때 알린다: 백업으로 되살렸는지 / 처음 설정으로 켰는지, 읽지 못한 파일을 둔 곳.
Future<void> showSettingsProblem(BuildContext context, AppController c) async {
  final problem = c.settingsStore?.problem;
  if (problem == null) return;
  await showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      scrollable: true,
      icon: const Icon(Icons.warning_amber_rounded),
      title: Text(problem.restoredFromBackup ? tr('설정을 백업으로 되살렸습니다') : tr('설정 파일을 읽지 못했습니다')),
      content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(problem.restoredFromBackup
            ? tr('설정 파일이 깨져 있어, 마지막으로 정상 저장된 설정 (백업) 으로 켰습니다. 그 뒤에 바꾼 것만 다시 확인하세요.')
            : tr('설정 파일이 깨져 있고 백업도 없어 처음 설정으로 켰습니다. WebDAV 서버 · 동기화 쌍 · 언어 등을 다시 확인하세요.')),
        if (problem.brokenCopy != null) ...[
          const SizedBox(height: 10),
          Text(tr('읽지 못한 원래 파일은 지우지 않고 아래에 보관했습니다:'), style: const TextStyle(fontSize: 12)),
          SelectableText(problem.brokenCopy!, style: const TextStyle(fontSize: 12)),
        ],
        const SizedBox(height: 10),
        Text(trf('원인: {0}', [problem.error]), style: const TextStyle(fontSize: 11)),
      ]),
      actions: [FilledButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('확인')))],
    ),
  );
  c.settingsStore?.problem = null;
}
