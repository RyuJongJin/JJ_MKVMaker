import 'package:flutter/material.dart';

import '../app/app_controller.dart';
import '../app/cleanup.dart';
import '../app/download_manager.dart';
import '../l10n/tr.dart';
import 'theme.dart';

/// 저장 공간 정리: 찾은 묶음별 크기를 보여 주고, 고른 것만 지운다
Future<void> showCleanup(BuildContext context, AppController c, DownloadManager? downloads) async {
  final cleaner = Cleaner(c, downloads: downloads);
  final messenger = ScaffoldMessenger.maybeOf(context);
  final result = await showDialog<(int, int)>(
    context: context,
    builder: (_) => _CleanupDialog(cleaner: cleaner),
  );
  if (result == null) return;
  final (n, bytes) = result;
  c.note(trf('저장 공간 정리: 파일 {0}개 · {1}', [n, Cleaner.sizeText(bytes)]));
  messenger?.showSnackBar(SnackBar(
      content: Text(n == 0 ? tr('정리할 파일이 없었습니다.') : trf('정리했습니다: 파일 {0}개 · {1}', [n, Cleaner.sizeText(bytes)]))));
}

class _CleanupDialog extends StatefulWidget {
  final Cleaner cleaner;
  const _CleanupDialog({required this.cleaner});

  @override
  State<_CleanupDialog> createState() => _CleanupDialogState();
}

class _CleanupDialogState extends State<_CleanupDialog> {
  List<CleanupGroup>? _groups;
  final _picked = <String>{};
  bool _cleaning = false;

  @override
  void initState() {
    super.initState();
    widget.cleaner.scan().then((g) {
      if (!mounted) return;
      setState(() {
        _groups = g;
        // 처음에는 작업 임시 파일 · 받다 만 다운로드만 고른 상태로 (사용자 결정 10/8).
        // 받다 만 AI 모델 · 지난 작업 기록 · 업데이트 남은 파일은 직접 체크해야 지운다
        const pre = {'work', 'download'};
        _picked.addAll([for (final x in g) if (x.skipped == null && x.items.isNotEmpty && pre.contains(x.id)) x.id]);
      });
    });
  }

  int get _total => [
        for (final g in _groups ?? const <CleanupGroup>[])
          if (_picked.contains(g.id)) g.bytes,
      ].fold(0, (a, b) => a + b);

  @override
  Widget build(BuildContext context) {
    final groups = _groups;
    return AlertDialog(
      title: Row(children: [
        const Icon(Icons.cleaning_services_outlined, color: JjColors.accent),
        const SizedBox(width: 10),
        Text(tr('저장 공간 정리')),
      ]),
      content: SizedBox(
        width: 560,
        child: groups == null
            ? Padding(
                padding: const EdgeInsets.all(24),
                child: Row(children: [
                  const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                  const SizedBox(width: 12),
                  Text(tr('정리할 파일을 찾는 중…')),
                ]),
              )
            : ListView(shrinkWrap: true, children: [
                for (final g in groups)
                  CheckboxListTile(
                    value: g.skipped == null && _picked.contains(g.id),
                    onChanged: g.skipped != null || g.items.isEmpty || _cleaning
                        ? null
                        : (v) => setState(() => v! ? _picked.add(g.id) : _picked.remove(g.id)),
                    title: Row(children: [
                      Expanded(child: Text(g.title)),
                      Text(
                        g.items.isEmpty ? tr('없음') : trf('{0}개 · {1}', [g.items.length, Cleaner.sizeText(g.bytes)]),
                        style: const TextStyle(fontSize: 13, color: JjColors.textDim),
                      ),
                    ]),
                    subtitle: Text(g.skipped ?? g.hint,
                        style: TextStyle(fontSize: 12, color: g.skipped != null ? Colors.amber : JjColors.textDim)),
                  ),
              ]),
      ),
      actions: [
        TextButton(onPressed: _cleaning ? null : () => Navigator.pop(context), child: Text(tr('닫기'))),
        FilledButton.icon(
          onPressed: groups == null || _picked.isEmpty || _total == 0 && !_hasItems || _cleaning
              ? null
              : () async {
                  setState(() => _cleaning = true);
                  final r = await widget.cleaner.clean(groups.where((g) => _picked.contains(g.id)));
                  if (context.mounted) Navigator.pop(context, r);
                },
          icon: _cleaning
              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.delete_sweep_outlined, size: 18),
          label: Text(groups == null ? tr('정리') : trf('정리 ({0})', [Cleaner.sizeText(_total)])),
        ),
      ],
    );
  }

  bool get _hasItems => (_groups ?? const []).any((g) => _picked.contains(g.id) && g.items.isNotEmpty);
}
