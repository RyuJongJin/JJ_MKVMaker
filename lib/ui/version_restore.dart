import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../app/app_controller.dart';
import '../app/version_snapshot.dart';
import '../l10n/tr.dart';

/// 시작할 때: 다른 버전을 쓰다가 이 버전으로 돌아왔으면 (또는 Android 에서 앱을 다시 설치해 설정이 없으면)
/// 보관해 둔 설정을 되살릴지 묻는다. 되살리면 [restart] (다시 시작) 를 부른다. 끝나면 [lastRunVersion] 을 이 버전으로.
///
/// [freshInstall]: 시작할 때 설정 파일이 없었다 (앱을 새로 설치함)
Future<void> checkVersionRestore(
  BuildContext context,
  AppController c, {
  required String current,
  required bool freshInstall,
  required Future<void> Function() restart,
}) async {
  final snap = VersionSnapshot.instance;
  if (snap == null || current.isEmpty) return;
  String? from;
  String? message;
  if (freshInstall) {
    // Android 에서 예전 버전으로 되돌리느라 앱을 지웠다가 설치한 경우: 공용 폴더의 보관본
    from = snap.sharedFor(current);
    if (from != null) {
      message = trf('앱을 새로 설치해 설정이 없습니다. 저장해 둔 v{0} 의 설정 (동영상 목록 · 즐겨찾기 포함) 을 되살릴까요?\n'
          '(자막 API 키 · 비밀번호는 저장하지 않았으니 다시 넣어 주세요)', [p.basename(from)]);
    }
  } else if (snap.shouldOffer(current, c.settings.lastRunVersion)) {
    from = snap.dirOf(current);
    message = trf('다른 버전 ({0}) 을 쓰다가 v{1} 로 돌아왔습니다. 그 버전은 이 버전의 설정 일부를 모를 수 있습니다.\n'
        'v{1} 를 마지막으로 쓸 때 보관해 둔 설정 (동영상 목록 · 즐겨찾기 포함) 으로 되돌릴까요?',
        [c.settings.lastRunVersion.isEmpty ? tr('예전 버전') : 'v${c.settings.lastRunVersion}', current]);
  }
  if (from != null && message != null && context.mounted) {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        scrollable: true,
        title: Text(tr('설정 되살리기')),
        content: SizedBox(width: 520, child: Text(message!)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('지금 설정 그대로'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr('되살리고 다시 시작'))),
        ],
      ),
    );
    if (ok == true) {
      try {
        await snap.restoreFrom(from);
        c.note(trf('보관해 둔 설정을 되살렸습니다: {0}', [from]));
        await restart();
        return;
      } catch (e) {
        c.note(trf('설정을 되살리지 못했습니다: {0}', [e]));
      }
    }
  }
  if (c.settings.lastRunVersion != current) await c.updateSettings((x) => x.lastRunVersion = current);
}
