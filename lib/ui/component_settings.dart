import 'package:flutter/material.dart';

import 'dart:io';

import '../app/app_controller.dart';
import '../app/component_store.dart';
import '../app/components.dart';
import '../l10n/tr.dart';
import 'setting_tile.dart';
import 'theme.dart';

/// 환경 설정 > 파일 탐색기 > 보기: 그림으로 볼 확장자 · ZIP 만화 보기 (이미지 · PDF · ZIP 보기 컴포넌트)
class ViewerSettings extends StatelessWidget {
  final AppController c;
  const ViewerSettings({super.key, required this.c});

  static const _choices = ['jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp', 'avif', 'heic', 'tif', 'tiff'];

  @override
  Widget build(BuildContext context) {
    final s = c.settings;
    if (!s.components.contains('viewer')) return const SizedBox();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SettingTile(
        leading: const Icon(Icons.photo_library_outlined),
        title: Text(tr('그림 보기 대상')),
        subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(tr('이 확장자의 파일을 두 번 누르면 그림 보기로 엽니다 (오른쪽을 누르면 다음, 왼쪽을 누르면 이전 그림).')),
          const SizedBox(height: 6),
          Wrap(spacing: 6, runSpacing: 6, children: [
            for (final e in _choices)
              FilterChip(
                label: Text(e),
                selected: s.imageExts.contains(e),
                onSelected: (on) => c.updateSettings((x) => x.imageExts = [
                      for (final y in x.imageExts) if (y != e) y,
                      if (on) e,
                    ]),
              ),
          ]),
        ]),
      ),
      SwitchListTile(
        secondary: const Icon(Icons.auto_stories_outlined),
        value: s.zipComic,
        onChanged: (v) => c.updateSettings((x) => x.zipComic = v),
        title: Text(tr('ZIP · CBZ 를 만화로 보기')),
        subtitle: Text(tr('켜면 두 번 눌렀을 때 안의 그림을 바로 넘겨 봅니다. 끄면 목록 (골라서 풀기) 을 엽니다.')),
      ),
    ]);
  }
}

/// 내려받아 설치하는 컴포넌트 켜기 (진행 창 · 취소) · 끄기 (지우기)
Future<void> _setDownloaded(BuildContext context, AppComponent x, bool on) async {
  final c = (context.findAncestorWidgetOfExactType<ComponentSettings>())!.c;
  final store = ComponentStore.shared;
  if (!on) {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        scrollable: true,
        title: Text(trf('{0} 제거', [tr(x.name)])),
        content: Text(tr('내려받은 변환기 파일을 지웁니다. 다시 켜면 다시 내려받습니다.')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('취소'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr('지우기'))),
        ],
      ),
    );
    if (ok != true) return;
    await store.remove(x.id);
    await c.updateSettings((v) => v.components = [for (final id in v.components) if (id != x.id) id]);
    return;
  }
  final step = ValueNotifier<(String, double?)>((tr('목록을 받는 중'), null));
  Object? error;
  var done = false;
  if (!context.mounted) return;
  final dialog = showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => AlertDialog(
      scrollable: true,
      title: Text(trf('{0} 설치', [tr(x.name)])),
      content: ValueListenableBuilder<(String, double?)>(
        valueListenable: step,
        builder: (_, v, _) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(v.$1),
          const SizedBox(height: 10),
          LinearProgressIndicator(value: v.$2),
        ]),
      ),
      actions: [
        TextButton(
          onPressed: () {
            store.cancel();
          },
          child: Text(tr('취소')),
        ),
      ],
    ),
  );
  try {
    // 단계 글 ("받는 중: 파일") 의 앞부분만 번역
    String trStep(String s) {
      for (final k in ['받는 중', '푸는 중', '확장 설치']) {
        if (s.startsWith('$k:')) return '${tr(k)}:${s.substring(k.length + 1)}';
      }
      return s;
    }

    await store.install(x.id, onProgress: (s, d) => step.value = (trStep(s), d));
    done = true;
  } catch (e) {
    error = e;
  }
  if (context.mounted) Navigator.of(context).pop();
  await dialog;
  step.dispose();
  if (done) {
    await c.updateSettings((v) => v.components = [for (final id in v.components) if (id != x.id) id, x.id]);
  }
  if (context.mounted) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
        content: Text(done ? trf('{0} 을(를) 설치했습니다.', [tr(x.name)]) : trf('설치하지 못했습니다: {0}', [error]))));
  }
}

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
      if (x.needsDownload) return _setDownloaded(context, x, on);
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

    // [from] 번째 화면을 [to] 자리로 (설치하지 않은 화면은 원래 순서대로 뒤에)
    void move(int from, int to) {
      final ids = [for (final p in pages) p.id];
      ids.insert(to, ids.removeAt(from));
      c.updateSettings((v) => v.navOrder = [...ids, ...AppComponent.defaultOrder.where((x) => !ids.contains(x))]);
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
          subtitle: Text(x.needsDownload
              ? '${tr(x.description)}\n${Platform.isWindows ? tr('켜면 변환기를 내려받아 설치합니다 (약 420MB). 끄면 지웁니다.') : tr('Windows 에서만 쓸 수 있습니다. 이 기기에서는 문서를 다른 앱으로 엽니다.')}'
              : tr(x.description)),
          trailing: Switch(
            value: installed.contains(x.id),
            onChanged: x.needsDownload && !Platform.isWindows ? null : (v) => setInstalled(x, v),
          ),
        ),
      const Divider(),
      SettingTile(
        leading: const Icon(Icons.swap_vert),
        title: Text(tr('화면 순서')),
        subtitle: Text(tr('위쪽 이동 버튼과 좌우로 밀기의 순서입니다. ▲ ▼ 로 바꿉니다.')),
      ),
      for (final (i, p) in pages.indexed)
        ListTile(
          key: ValueKey(p.id),
          dense: true,
          leading: Text('${i + 1}', style: const TextStyle(color: JjColors.textDim)),
          title: Row(children: [Icon(p.icon, size: 18), const SizedBox(width: 10), Flexible(child: Text(tr(p.name)))]),
          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
            IconButton(
              tooltip: tr('위로'),
              icon: const Icon(Icons.arrow_upward, size: 18),
              onPressed: i == 0 ? null : () => move(i, i - 1),
            ),
            IconButton(
              tooltip: tr('아래로'),
              icon: const Icon(Icons.arrow_downward, size: 18),
              onPressed: i == pages.length - 1 ? null : () => move(i, i + 1),
            ),
          ]),
        ),
    ]);
  }
}
