import 'package:flutter/material.dart';

import '../app/app_controller.dart';
import '../app/components.dart';
import '../l10n/tr.dart';
import 'setting_tile.dart';
import 'theme.dart';

/// 환경 설정 > 컴포넌트: 기능 묶음 설치 (켜기) · 제거 (끄기), 화면 순서 (끌어서 바꿈), 좌우로 밀어 화면 이동.
/// 화면이 하나만 남으면 위쪽 이동 버튼 줄에는 그것만 보인다.
class ComponentSettings extends StatelessWidget {
  final AppController c;
  const ComponentSettings({super.key, required this.c});

  @override
  Widget build(BuildContext context) {
    final s = c.settings;
    final installed = s.components;
    final pages = AppComponent.pages(installed, s.navOrder);

    Future<void> setInstalled(AppComponent x, bool on) async {
      // 화면 있는 것이 하나도 남지 않게는 못 한다
      if (!on && x.page && pages.length <= 1 && pages.first.id == x.id) {
        ScaffoldMessenger.maybeOf(context)
            ?.showSnackBar(SnackBar(content: Text(tr('화면이 있는 컴포넌트는 하나 이상 남아 있어야 합니다.'))));
        return;
      }
      await c.updateSettings((v) => v.components = [
            for (final id in v.components) if (id != x.id) id,
            if (on) x.id,
          ]);
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SwitchListTile(
        value: s.swipeNav,
        onChanged: (v) => c.updateSettings((x) => x.swipeNav = v),
        title: Text(tr('좌우로 밀어 화면 이동')),
        subtitle: Text(tr('화면 가운데를 왼쪽으로 밀면 다음 화면, 오른쪽으로 밀면 이전 화면 (마지막 다음은 처음으로).')),
      ),
      for (final x in AppComponent.all)
        SettingTile(
          leading: Icon(x.icon, color: installed.contains(x.id) ? JjColors.accent : JjColors.textDim),
          title: Text(tr(x.name)),
          subtitle: Text(x.needsDownload ? '${tr(x.description)}\n${tr('설치하면 필요한 파일을 내려받습니다 (준비 중)')}' : tr(x.description)),
          trailing: Switch(
            value: installed.contains(x.id),
            onChanged: x.needsDownload && !installed.contains(x.id) ? null : (v) => setInstalled(x, v),
          ),
        ),
      const Divider(),
      SettingTile(
        leading: const Icon(Icons.swap_vert),
        title: Text(tr('화면 순서')),
        subtitle: Text(tr('위쪽 이동 버튼과 좌우로 밀기의 순서입니다. 줄을 끌어 바꿉니다.')),
      ),
      ReorderableListView(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        buildDefaultDragHandles: false,
        onReorderItem: (from, to) {
          final ids = [for (final p in pages) p.id];
          ids.insert(to, ids.removeAt(from));
          // 설치하지 않은 화면은 원래 자리 순서대로 뒤에
          c.updateSettings((v) => v.navOrder = [...ids, ...AppComponent.defaultOrder.where((x) => !ids.contains(x))]);
        },
        children: [
          for (final (i, p) in pages.indexed)
            ReorderableDragStartListener(
              key: ValueKey(p.id),
              index: i,
              child: ListTile(
                dense: true,
                leading: Text('${i + 1}', style: const TextStyle(color: JjColors.textDim)),
                title: Row(children: [Icon(p.icon, size: 18), const SizedBox(width: 10), Text(tr(p.name))]),
                trailing: const Icon(Icons.drag_handle),
              ),
            ),
        ],
      ),
    ]);
  }
}
