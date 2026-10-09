import 'package:flutter/material.dart';

import '../app/app_controller.dart';
import '../app/master_lock.dart';
import '../l10n/tr.dart';
import 'confirm.dart';
import 'master_prompt.dart';
import 'setting_tile.dart';

/// 124: 환경 설정 > 보안 - 최상 비밀번호 (모두 초기화하는 열쇠) · 마스터 비밀번호 (저장된 비밀번호 · 설정 · 비밀번호가 필요한 기능)
/// · 마스터를 묻는 때. 이미 정한 것을 바꾸거나 끄려면 지금 마스터 (또는 최상) 를 넣는다.
class SecuritySettings extends StatelessWidget {
  final AppController c;
  const SecuritySettings({super.key, required this.c});

  @override
  Widget build(BuildContext context) {
    final lock = MasterLock.instance;
    if (lock == null) return const SizedBox();
    return ListenableBuilder(
      listenable: lock,
      builder: (context, _) {
        // 바꾸기 · 끄기 전에 지금 비밀번호 (마스터 또는 최상)
        Future<bool> current() => askMaster(context, c, lock,
            forChange: true, reason: tr('바꾸거나 끄려면 지금 마스터 비밀번호 (또는 최상 비밀번호) 를 넣으세요.'));
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          SettingTile(
            leading: const Icon(Icons.lock_outline),
            title: Text(tr('마스터 비밀번호')),
            // 132: 버튼은 설명 아래에 (넓은 화면의 오른쪽 칸에서는 둘째 버튼이 잘려 안 보였다)
            subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(lock.hasMaster
                  ? tr('정해 둠. 저장된 비밀번호 · 설정 · 비밀번호가 필요한 기능을 쓸 때 묻습니다 (앱을 끌 때까지 한 번)')
                  : tr('정하지 않음. 정하면 저장된 비밀번호 (WebDAV · OpenSubtitles · API 키) 와 설정을 쓰기 전에 묻습니다')),
              const SizedBox(height: 6),
              Wrap(spacing: 6, runSpacing: 6, children: [
              if (!lock.hasMaster)
                FilledButton.tonal(
                  onPressed: () => setPasswordDialog(context, c, lock, superPassword: false),
                  child: Text(tr('정하기')),
                )
              else ...[
                OutlinedButton(
                  onPressed: () async {
                    if (await current() && context.mounted) await setPasswordDialog(context, c, lock, superPassword: false);
                  },
                  child: Text(tr('바꾸기')),
                ),
                OutlinedButton(
                  onPressed: () async {
                    if (!await current() || !context.mounted) return;
                    final ok = await confirmAction(context,
                        title: tr('마스터 비밀번호를 끌까요?'),
                        body: tr('저장된 비밀번호 · 설정을 쓸 때 더는 묻지 않습니다.'),
                        ok: tr('끄기'));
                    if (!ok) return;
                    await lock.clearMaster();
                  },
                  child: Text(tr('끄기')),
                ),
              ],
            ]),
            ]),
          ),
          SettingTile(
            enabled: lock.hasMaster,
            leading: const Icon(Icons.schedule),
            title: Text(tr('마스터 비밀번호를 묻는 때')),
            trailing: DropdownButton<String>(
              value: lock.ask,
              items: [
                DropdownMenuItem(value: 'never', child: Text(tr('물어보지 않기'))),
                DropdownMenuItem(value: 'startup', child: Text(tr('처음 시작 시'))),
                DropdownMenuItem(value: 'onUse', child: Text(tr('비밀번호가 저장된 기능을 쓸 때'))),
              ],
              // 129: 바꾸는 것도 지금 마스터를 넣어야 (자물쇠를 아무나 끄지 못하게)
              onChanged: !lock.hasMaster
                  ? null
                  : (v) async {
                      if (v == lock.ask) return;
                      if (await current()) await lock.setAsk(v!);
                    },
            ),
          ),
          SettingTile(
            leading: const Icon(Icons.key_outlined),
            title: Text(tr('최상 비밀번호')),
            subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(lock.hasSuper
                  ? tr('정해 둠. 마스터 입력 창에 넣으면 초기화 창이 열립니다 (마스터 · 저장된 비밀번호 · 앱 설정 전체 중 고름)')
                  : tr('정하지 않음. 마스터를 잊으면 저장된 비밀번호를 지우고 마스터를 초기화하는 것만 할 수 있습니다')),
              const SizedBox(height: 6),
              Wrap(spacing: 6, runSpacing: 6, children: [
              if (!lock.hasSuper)
                FilledButton.tonal(
                  onPressed: () async {
                    // 마스터가 있으면 그것을 먼저 (아무나 최상을 정하지 못하게)
                    if (lock.hasMaster && !await current()) return;
                    if (context.mounted) await setPasswordDialog(context, c, lock, superPassword: true);
                  },
                  child: Text(tr('정하기')),
                )
              else ...[
                OutlinedButton(
                  onPressed: () async {
                    if (await current() && context.mounted) await setPasswordDialog(context, c, lock, superPassword: true);
                  },
                  child: Text(tr('바꾸기')),
                ),
                OutlinedButton(
                  onPressed: () async {
                    if (!await current() || !context.mounted) return;
                    final ok = await confirmAction(context, title: tr('최상 비밀번호를 끌까요?'), body: '', ok: tr('끄기'));
                    if (ok) await lock.clearSuper();
                  },
                  child: Text(tr('끄기')),
                ),
              ],
            ]),
            ]),
          ),
        ]);
      },
    );
  }
}
