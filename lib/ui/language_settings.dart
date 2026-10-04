import 'package:flutter/material.dart';

import '../app/i18n_controller.dart';
import '../core/languages.dart';
import '../l10n/tr.dart';
import '../services/ai_services.dart';
import 'theme.dart';

/// 환경 설정 맨 위: 화면 언어 고르기 · 언어 추가 (AI 자동 번역) · 더한 언어 삭제
class LanguageSettings extends StatelessWidget {
  const LanguageSettings({super.key});

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: i18n,
        builder: (context, _) {
          final added = i18n.available.where((c) => !I18nController.builtIn.contains(c)).toList();
          return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            ListTile(
              leading: const Icon(Icons.translate, color: JjColors.accent),
              // 읽을 수 없는 언어를 골라도 찾을 수 있게 영어를 함께
              title: Text(uiLanguage == 'en' ? 'Language' : '${tr('화면 언어')} · Language'),
              subtitle: Text(tr('프로그램의 모든 글자를 고른 언어로 보여 줍니다. 목록에 없는 언어는 [언어 추가] 로 '
                  '이 기기의 AI 번역 모델이 자동 번역해 넣습니다.')),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(72, 0, 16, 8),
              child: Wrap(spacing: 12, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
                DropdownButton<String>(
                  value: i18n.available.contains(uiLanguage) ? uiLanguage : 'ko',
                  items: [
                    for (final code in i18n.available)
                      DropdownMenuItem(value: code, child: Text(I18nController.nativeName(code))),
                  ],
                  onChanged: (v) => i18n.apply(v!),
                ),
                OutlinedButton.icon(
                  onPressed: i18n.canTranslate ? () => addLanguageDialog(context) : null,
                  icon: const Icon(Icons.add, size: 18),
                  label: Text(tr('언어 추가')),
                ),
                if (!i18n.canTranslate)
                  Text(tr('(AI 번역을 쓸 수 없는 기기라 언어를 더할 수 없습니다)'),
                      style: const TextStyle(fontSize: 12, color: JjColors.textDim)),
              ]),
            ),
            for (final code in added)
              ListTile(
                dense: true,
                contentPadding: const EdgeInsets.fromLTRB(72, 0, 16, 0),
                title: Text(I18nController.nativeName(code)),
                subtitle: Text(tr('더한 언어 (AI 자동 번역)')),
                trailing: IconButton(
                  tooltip: tr('이 언어 지우기'),
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () => i18n.removeLanguage(code),
                ),
              ),
          ]);
        },
      );
}

/// 언어 추가: 언어를 고르고, AI 로 화면 글자를 번역한 뒤 그 언어로 바꾼다
Future<void> addLanguageDialog(BuildContext context) async {
  final pick = await showDialog<Language>(
    context: context,
    builder: (ctx) => SimpleDialog(
      title: Text(tr('언어 추가')),
      children: [
        SizedBox(
          width: 360,
          height: 420,
          child: ListView(children: [
            for (final l in i18n.addable)
              ListTile(
                title: Text(I18nController.nativeName(l.code)),
                subtitle: Text('${l.name} (${l.code})'),
                onTap: () => Navigator.pop(ctx, l),
              ),
          ]),
        ),
      ],
    ),
  );
  if (pick == null || !context.mounted) return;
  final state = ValueNotifier<(String, double)>((tr('준비 중…'), 0));
  final messenger = ScaffoldMessenger.maybeOf(context);
  var dialogOpen = true;
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => AlertDialog(
      title: Text(trf('{0} 추가', [I18nController.nativeName(pick.code)])),
      content: ValueListenableBuilder<(String, double)>(
        valueListenable: state,
        builder: (_, s, _) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(s.$1),
          const SizedBox(height: 12),
          LinearProgressIndicator(value: s.$2),
          const SizedBox(height: 8),
          Text(tr('화면 글자 전체를 이 기기에서 번역합니다. 몇 분 걸릴 수 있습니다.'),
              style: const TextStyle(fontSize: 12, color: JjColors.textDim)),
        ]),
      ),
      actions: [TextButton(onPressed: i18n.cancel, child: Text(tr('취소')))],
    ),
  ).whenComplete(() => dialogOpen = false);
  String? error;
  try {
    await i18n.addLanguage(pick, onProgress: (phase, x) => state.value = (phase, x));
  } on AiCancelled {
    error = tr('취소했습니다.');
  } catch (e) {
    error = '$e';
  }
  if (dialogOpen && context.mounted) Navigator.of(context, rootNavigator: true).pop();
  if (error == null) {
    await i18n.apply(pick.code);
  } else {
    messenger?.showSnackBar(SnackBar(content: Text(trf('언어를 더하지 못했습니다: {0}', [error]))));
  }
}
