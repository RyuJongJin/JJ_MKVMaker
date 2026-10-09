import 'package:flutter/material.dart';

import '../app/app_controller.dart';
import '../core/file_ops.dart' show formatSize;
import '../core/vfs.dart';
import '../core/webdav.dart' show DavRegistry;
import '../l10n/tr.dart';
import 'theme.dart';

/// WebDAV 파일은 열거나 재생하려면 임시 폴더로 받는다 (받는 동안 진행 창 · 취소). 로컬은 그대로. 받지 못하면 null.
Future<String?> fetchDav(BuildContext context, AppController c, String path) async {
  if (!isDav(path)) return path;
  final temp = await c.services.storage.tempDirectory();
  if (!context.mounted) return null;
  final messenger = ScaffoldMessenger.maybeOf(context);
  final nav = Navigator.of(context);
  final progress = ValueNotifier<(int, int)>((0, 0));
  var cancelled = false;
  final dialog = showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => AlertDialog(
      scrollable: true,
      title: Text(tr('WebDAV 에서 받는 중')),
      content: ValueListenableBuilder<(int, int)>(
        valueListenable: progress,
        builder: (_, v, _) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(vBasename(path)),
          const SizedBox(height: 10),
          LinearProgressIndicator(value: v.$2 > 0 ? v.$1 / v.$2 : null),
          const SizedBox(height: 6),
          Text('${formatSize(v.$1)}${v.$2 > 0 ? ' / ${formatSize(v.$2)}' : ''}',
              style: const TextStyle(fontSize: 12, color: JjColors.textDim)),
        ]),
      ),
      actions: [
        TextButton(
          onPressed: () {
            cancelled = true;
            Navigator.pop(ctx);
          },
          child: Text(tr('취소')),
        ),
      ],
    ),
  );
  try {
    final local = await vLocalCopy(path, temp, onProgress: (d, t) => progress.value = (d, t));
    return cancelled ? null : local;
  } catch (e) {
    if (!cancelled) messenger?.showSnackBar(SnackBar(content: Text(trf('받지 못했습니다: {0}', [e]))));
    return null;
  } finally {
    if (!cancelled && nav.mounted) nav.pop();
    await dialog;
    progress.dispose();
  }
}

/// 로그인이 필요한 WebDAV 서버의 파일인지 (아이디나 비밀번호가 있음)
bool davNeedsLogin(String path) {
  if (!isDav(path)) return false;
  final s = DavRegistry.server(DavPath.parse(path).server);
  return s != null && (s.user.isNotEmpty || s.password.isNotEmpty);
}

/// 외부 프로그램 · 다른 앱으로 연다 ([program]: 'system' 이나 실행 파일).
/// 55: 다른 앱으로 넘기는 주소에는 아이디 · 비밀번호를 넣지 않는다. 그래서 로그인이 필요한 WebDAV 파일이면
/// 조용히 실패하지 않게 먼저 묻는다: [받아서 열기] (임시로 받은 뒤 열기 - 어느 앱이든 열림) · [주소로 열기] (받는 앱이 아이디를 물어야 열림).
Future<void> openExternalPlayable(BuildContext context, AppController c, String program, List<String> files) async {
  if (!files.any(davNeedsLogin)) {
    await c.services.shell.openExternal(program, files.map(vPlayable).toList());
    return;
  }
  // 102: 환경 설정 (매번 묻기 · 늘 받아서 · 늘 주소로)
  final pick = switch (c.settings.davExternalOpen) {
    'fetch' => 'fetch',
    'url' => 'url',
    _ => await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      scrollable: true,
      title: Text(tr('이 WebDAV 서버는 로그인이 필요합니다')),
      content: SizedBox(
        width: 520,
        child: Text(tr('다른 앱에는 아이디 · 비밀번호를 넘기지 않습니다.\n\n'
            '• 받아서 열기: 임시 폴더로 받은 뒤 엽니다. 어느 앱에서나 열리지만 다 받을 때까지 기다려야 합니다.\n'
            '• 주소로 열기: 받지 않고 바로 재생합니다. 그 앱이 아이디 · 비밀번호를 물으면 넣어 주세요 (VLC 등). '
            '묻지 않는 앱에서는 열리지 않습니다.')),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('취소'))),
        TextButton(onPressed: () => Navigator.pop(ctx, 'url'), child: Text(tr('주소로 열기'))),
        FilledButton(onPressed: () => Navigator.pop(ctx, 'fetch'), child: Text(tr('받아서 열기'))),
      ],
    ),
  ),
  };
  if (pick == 'url') {
    await c.services.shell.openExternal(program, files.map(vPlayable).toList());
  } else if (pick == 'fetch') {
    final local = <String>[];
    for (final f in files) {
      if (!context.mounted) return;
      final l = await fetchDav(context, c, f);
      if (l == null) return; // 취소 · 실패
      local.add(l);
    }
    await c.services.shell.openExternal(program, local);
  }
}
