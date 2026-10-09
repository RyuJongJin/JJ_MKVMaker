import 'package:flutter/material.dart';

import '../core/languages.dart';
import '../l10n/tr.dart';

/// 61: 기본 자막 언어 고르기 - 화면 언어 따르기 (처음 값) · 한국어 · English · 日本語 · 中文 · 직접 고르기 (자막 언어 목록)
class SubtitleLanguagePicker extends StatelessWidget {
  final String value;
  final ValueChanged<String> onChanged;

  const SubtitleLanguagePicker({super.key, required this.value, required this.onChanged});

  /// 바로 고를 수 있는 것 (언어 이름은 그 언어로 - 화면 언어와 상관없이 알아보게)
  static const quick = [('ko', '한국어'), ('en', 'English'), ('ja', '日本語'), ('zh-Hans', '中文')];

  static const _other = '\u0000other';

  @override
  Widget build(BuildContext context) {
    final inQuick = value.isEmpty || quick.any((q) => q.$1 == value);
    return DropdownButton<String>(
      value: inQuick ? value : _other,
      items: [
        DropdownMenuItem(value: '', child: Text(tr('화면 언어 따르기'))),
        for (final (code, name) in quick) DropdownMenuItem(value: code, child: Text(name)), // l10n-skip: 언어 이름은 그 언어로
        DropdownMenuItem(
          value: _other,
          child: Text(inQuick ? tr('직접 고르기…') : trf('직접 고르기: {0}', [languageOf(value).name])),
        ),
      ],
      onChanged: (v) async {
        if (v == null) return;
        if (v != _other) return onChanged(v);
        final picked = await showDialog<String>(
          context: context,
          builder: (ctx) => SimpleDialog(
            title: Text(tr('기본 자막 언어')),
            children: [
              SizedBox(
                width: 360,
                height: 420,
                child: ListView(children: [
                  for (final l in languages)
                    ListTile(
                      dense: true,
                      selected: l.code == value,
                      title: Text(l.name),
                      subtitle: Text(l.code),
                      onTap: () => Navigator.pop(ctx, l.code),
                    ),
                ]),
              ),
            ],
          ),
        );
        if (picked != null) onChanged(picked);
      },
    );
  }
}
