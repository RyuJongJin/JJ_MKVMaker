import 'package:flutter/material.dart';

import 'app_actions.dart' show isCompact;

/// 환경 설정의 한 줄 (ListTile 과 같은 쓰임새).
/// 좁은 화면 (접은 폴드 · 휴대폰 세로) 에서는 오른쪽의 넓은 조절 (고르기 상자 · 입력 칸 · 버튼) 을 설명 아래로 내려
/// 제목 · 설명이 한두 글자 폭으로 눌리지 않게 한다. 스위치 · 체크 상자 · 아이콘 버튼은 그대로 오른쪽에.
class SettingTile extends StatelessWidget {
  final Widget? leading;
  final Widget? title;
  final Widget? subtitle;
  final Widget? trailing;
  final bool isThreeLine;
  final bool enabled;
  final bool? dense;
  final VoidCallback? onTap;
  final EdgeInsetsGeometry? contentPadding;

  const SettingTile({
    super.key,
    this.leading,
    this.title,
    this.subtitle,
    this.trailing,
    this.isThreeLine = false,
    this.enabled = true,
    this.dense,
    this.onTap,
    this.contentPadding,
  });

  static bool _small(Widget w) => w is Switch || w is Checkbox || w is Icon || w is IconButton || w is Radio;

  @override
  Widget build(BuildContext context) {
    final t = trailing;
    if (t == null || _small(t) || !isCompact(context)) {
      return ListTile(
        leading: leading,
        title: title,
        subtitle: subtitle,
        trailing: t,
        isThreeLine: isThreeLine,
        enabled: enabled,
        dense: dense,
        onTap: onTap,
        contentPadding: contentPadding,
      );
    }
    return ListTile(
      leading: leading,
      title: title,
      subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        ?subtitle,
        const SizedBox(height: 6),
        Align(alignment: Alignment.centerLeft, child: t),
      ]),
      enabled: enabled,
      dense: dense,
      onTap: onTap,
      contentPadding: contentPadding,
    );
  }
}
