import 'package:flutter/material.dart';

import '../l10n/tr.dart';
import '../platform/windows/rsync_installer.dart';
import 'theme.dart';

/// Windows: rsync 내려받기 (MSYS2 공식 저장소 · 약 8MB) 를 묻고, 받는 동안 진행 창을 보인다.
/// 설치된 rsync.exe 경로 (취소 · 실패면 null).
Future<String?> installRsyncWithDialog(BuildContext context) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(tr('rsync 내려받기')),
      content: Text(tr('rsync 는 처음 쓸 때 내려받습니다 (MSYS2 공식 저장소의 rsync 3.5.1 · 약 8MB, 파일마다 SHA256 확인).\n'
          '설정 폴더의 rsync 에 두어 업데이트해도 남습니다. 지금 받을까요?')),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('취소'))),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr('내려받기'))),
      ],
    ),
  );
  if (ok != true || !context.mounted) return null;
  final progress = ValueNotifier<(double, String)>((0, ''));
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => AlertDialog(
      title: Text(tr('rsync 받는 중')),
      content: ValueListenableBuilder<(double, String)>(
        valueListenable: progress,
        builder: (_, v, _) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(v.$2, style: const TextStyle(fontSize: 12, color: JjColors.textDim)),
          const SizedBox(height: 8),
          LinearProgressIndicator(value: v.$1),
        ]),
      ),
    ),
  );
  try {
    final exe = await RsyncInstaller.install(onProgress: (x, f) => progress.value = (x, f));
    if (context.mounted) Navigator.of(context).pop();
    return exe;
  } catch (e) {
    if (context.mounted) {
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(trf('rsync 를 받지 못했습니다: {0}', [e]))));
    }
    return null;
  }
}
