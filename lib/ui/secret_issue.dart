import 'package:flutter/material.dart';

import '../app/app_controller.dart';
import '../app/settings.dart';
import '../l10n/tr.dart';

/// 안전 저장소 문제 (40-1 · 40-3 · 40-5) 를 화면 위 알림으로 보여 준다: 생길 때마다 · 켤 때 이미 있으면 바로.
/// 비밀번호를 평문으로 몰래 저장하지 않는 대신, 저장되지 않았다는 것을 분명히 알리고 [다시 시도] 를 둔다.
void watchSecretIssue(GlobalKey<ScaffoldMessengerState> messengerKey, AppController c) {
  final store = c.settingsStore;
  if (store == null) return;
  // 90: [닫기] 한 상황은 바뀔 때까지 다시 띄우지 않는다
  SecretIssue? dismissed;
  SecretIssue? shown;
  void show() {
    final m = messengerKey.currentState;
    if (m == null) return;
    final issue = store.secretIssue.value;
    if (issue == shown && issue != null) return;
    m.clearMaterialBanners();
    shown = null;
    if (issue == null || issue == dismissed) return;
    shown = issue;
    m.showMaterialBanner(secretIssueBanner(
      issue,
      onRetry: () async {
        final ok = await c.retrySecrets();
        // 90: 결과는 늘 짧게 알린다
        messengerKey.currentState?.showSnackBar(SnackBar(
          content: Text(ok ? tr('비밀번호를 안전 저장소에 저장했습니다') : tr('아직 저장하지 못했습니다. 잠시 뒤 다시 시도하세요')),
        ));
      },
      onClose: () {
        dismissed = issue;
        shown = null;
        m.hideCurrentMaterialBanner();
      },
    ));
  }

  store.secretIssue.addListener(show);
  show();
}

MaterialBanner secretIssueBanner(SecretIssue issue, {required VoidCallback onRetry, required VoidCallback onClose}) {
  final lost = issue.kind == SecretIssueKind.lost;
  return MaterialBanner(
    leading: const Icon(Icons.key_off_outlined, color: Colors.orangeAccent),
    content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(
        lost ? tr('저장된 비밀번호를 되살리지 못했습니다') : tr('이 기기의 안전 저장소를 쓸 수 없어 비밀번호를 저장하지 못했습니다'),
        style: const TextStyle(fontWeight: FontWeight.bold),
      ),
      const SizedBox(height: 4),
      Text(switch (issue.kind) {
        SecretIssueKind.lost => trf('이 PC 의 안전 저장소를 풀 수 없었습니다. WebDAV · OpenSubtitles 비밀번호를 한 번만 다시 넣어 주세요. 풀지 못한 파일은 지우지 않고 보관했습니다: {0}',
            [issue.kept ?? '-']),
        SecretIssueKind.readFailed => tr('이번 실행에서 넣은 비밀번호는 앱을 끄면 사라집니다 (설정 파일에 평문으로 쓰지 않습니다). [다시 시도] 를 눌러 보세요.'),
        SecretIssueKind.writeFailed => tr('백신 프로그램 등이 막았을 수 있습니다. [다시 시도] 를 누르세요. 예전 설정 파일에 있던 비밀번호는 저장될 때까지 지우지 않습니다.'),
      }),
      // 91: 새로 넣은 비밀번호가 앱을 끄면 어떻게 되는지 분명히
      if (issue.revertsToOld)
        Text(tr('새 비밀번호는 아직 저장되지 않았습니다. 앱을 끄면 예전 비밀번호로 돌아갑니다.'),
            style: const TextStyle(color: Colors.orangeAccent, fontWeight: FontWeight.w600)),
      if (issue.lostOnExit && !issue.revertsToOld)
        Text(tr('새로 넣은 비밀번호는 아직 저장되지 않았습니다. 앱을 끄면 사라집니다.'),
            style: const TextStyle(color: Colors.orangeAccent, fontWeight: FontWeight.w600)),
    ]),
    actions: [
      if (!lost) TextButton(onPressed: onRetry, child: Text(tr('다시 시도'))),
      TextButton(onPressed: onClose, child: Text(tr('닫기'))),
    ],
  );
}
