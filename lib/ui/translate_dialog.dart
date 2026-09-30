import 'package:flutter/material.dart';

import '../app/app_controller.dart';
import '../core/languages.dart';
import '../core/models.dart';
import '../services/model_store.dart';
import 'theme.dart';

/// 있는 자막 (예: 영어) 을 다른 언어로 번역해 MKV 자막에 추가하는 창
Future<void> showTranslateDialog(BuildContext context, AppController c, VideoItem v, SubtitleEntry s) async {
  final targets = await showDialog<Set<Language>>(
    context: context,
    builder: (_) => _TranslateDialog(c: c, s: s),
  );
  if (targets == null || targets.isEmpty) return;
  await c.translateSubtitle(v, s, targets);
}

/// 기본으로 고를 언어: 한국어 (원어가 한국어면 영어)
Set<Language> defaultTranslateTargets(Language source) {
  final ko = languages.firstWhere((l) => l.code == 'ko');
  final en = languages.firstWhere((l) => l.code == 'en');
  return {source.code == 'ko' ? en : ko};
}

class _TranslateDialog extends StatefulWidget {
  final AppController c;
  final SubtitleEntry s;
  const _TranslateDialog({required this.c, required this.s});

  @override
  State<_TranslateDialog> createState() => _TranslateDialogState();
}

class _TranslateDialogState extends State<_TranslateDialog> {
  late Set<Language> _targets = defaultTranslateTargets(widget.s.language);
  bool? _installed;

  @override
  void initState() {
    super.initState();
    widget.c.services.models.isInstalled(nllbModel).then((ok) {
      if (mounted) setState(() => _installed = ok);
    });
  }

  @override
  Widget build(BuildContext context) {
    final src = widget.s.language;
    final extra = languages.where((l) => !_targets.contains(l) && l.code != src.code).toList();
    return AlertDialog(
      title: const Text('자막 번역'),
      content: SizedBox(
        width: 480,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(widget.s.displayName, style: const TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            Text(
                src == undetermined
                    ? '원어: 자동 감지 (글자로 추정)'
                    : '원어: ${src.name} (${src.code})',
                style: const TextStyle(fontSize: 12, color: JjColors.textDim)),
            const SizedBox(height: 16),
            const Text('번역할 언어 (jj_mkv\\파일명_언어코드.srt 로 저장 후 MKV 에 추가)',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            Wrap(spacing: 6, runSpacing: 6, children: [
              for (final l in _targets)
                InputChip(
                  label: Text('${l.name} (${l.code})'),
                  onDeleted: _targets.length > 1 ? () => setState(() => _targets = {..._targets}..remove(l)) : null,
                ),
              PopupMenuButton<Language>(
                tooltip: '언어 추가',
                itemBuilder: (_) => [
                  for (final l in extra) PopupMenuItem(value: l, child: Text('${l.name} (${l.code})')),
                ],
                onSelected: (l) => setState(() => _targets = {..._targets, l}),
                child: const Chip(avatar: Icon(Icons.add, size: 16), label: Text('언어 추가')),
              ),
            ]),
            const SizedBox(height: 16),
            Row(children: [
              const Text('번역 모델: NLLB-200 (이 PC 에서만)  ', style: TextStyle(fontSize: 13)),
              if (_installed != null)
                Text(_installed! ? '설치됨' : '처음 사용 시 내려받기 ${nllbModel.sizeLabel}',
                    style: TextStyle(fontSize: 11, color: _installed! ? JjColors.success : JjColors.textDim)),
            ]),
            const SizedBox(height: 8),
            const Text('※ 다른 작업 중이면 대기열에 넣고 차례대로 합니다. 번역하는 동안 브라우저를 써도 됩니다.',
                style: TextStyle(fontSize: 11, color: JjColors.textDim)),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('취소')),
        FilledButton.icon(
          onPressed: () => Navigator.pop(context, _targets),
          icon: const Icon(Icons.translate, size: 18),
          label: const Text('번역 시작'),
        ),
      ],
    );
  }
}
