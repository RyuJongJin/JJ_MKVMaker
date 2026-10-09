import 'package:flutter/material.dart';

import '../app/app_controller.dart';
import '../l10n/tr.dart';
import 'settings_page.dart';

/// 업데이트하면서 예전 기본값을 새 기본값으로 한 번 옮겼으면, 켤 때 무엇이 바뀌었는지와
/// 환경 설정에서 되돌릴 수 있다는 것을 한 번 알린다 ([AppSettings.migrated]).
Future<void> showMigrationNotice(BuildContext context, AppController c) async {
  if (!c.settings.migrationNotice) return; // 102: 환경 설정에서 끌 수 있음
  final items = c.settings.migrated;
  if (items.isEmpty) return;
  String line(String id) => switch (id) {
        'orientation' => tr('화면 방향: 가로 고정 → 자동 (기기를 돌리는 대로). 되돌리기: 환경 설정 > 화면 > 화면 방향'),
        'explorerLayout' =>
          tr('파일 탐색기 창: 두 창 → 화면 크기 따라 (폰 세로는 한 창). 되돌리기: 환경 설정 > 파일 탐색기 > 창 배치'),
        'explorerClick' => tr('파일 탐색기 누르기: 한 번 누르면 선택 → 한 번 누르면 바로 실행. 되돌리기: 환경 설정 > 파일 탐색기 > 누르기'),
        'explorerOrientation' => tr(
            '파일 탐색기 두 창 배치: 화면 모양 따라 → 좌우. 되돌리기: 파일 탐색기의 [좌우 ⇆ / 위아래 ⇅] 버튼 또는 창 배치'),
        'zipComic' => tr('ZIP · CBZ 두 번 누르기: 만화 보기 → 목록. 되돌리기: 환경 설정 > 파일 탐색기 > ZIP · CBZ 를 만화로 보기'),
        'background' =>
          tr('백그라운드로 실행: 꺼짐 → 켜짐 (← 나 최근 앱에서 밀어도 작업이 계속됨). 되돌리기: 환경 설정 > Rsync > 백그라운드로 실행'),
        _ => id,
      };
  final open = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      scrollable: true,
      icon: const Icon(Icons.update),
      title: Text(tr('이번 업데이트로 바뀐 기본 설정')),
      content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(tr('직접 고른 적이 없는 예전 기본값을 새 기본값으로 바꿨습니다. 원래대로 쓰려면 환경 설정에서 되돌리세요.')),
        const SizedBox(height: 10),
        for (final id in items)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('• '),
              Expanded(child: Text(line(id), style: const TextStyle(fontSize: 13))),
            ]),
          ),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr('환경 설정 열기'))),
        FilledButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('확인'))),
      ],
    ),
  );
  c.settings.migrated = [];
  if (open == true && context.mounted) {
    await Navigator.push(context, MaterialPageRoute<void>(builder: (_) => SettingsPage(c: c)));
  }
}
