import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../app/app_controller.dart';
import '../app/model_backup.dart';
import '../app/version_snapshot.dart';
import '../l10n/tr.dart';
import 'update_dialog.dart' show gbText, rollbackModelRoots, withProgressDialog;

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
  bool autoBackup = false,
}) async {
  final snap = VersionSnapshot.instance;
  if (snap == null || current.isEmpty) return;
  String? from;
  String? message;
  if (autoBackup) {
    // 115: 앱을 다시 깔자 Android 자동 백업이 설정을 말없이 되살렸다 → 무엇이 어디서 돌아왔는지 알리고,
    // 공용 폴더의 보관본이 있으면 그것으로 되살릴 수도 있게 (자동 백업은 하루에 한 번쯤이라 최근 것이 빠질 수 있다)
    if (!context.mounted) return;
    final now = VersionSnapshot.summaryOf(snap.dataDir);
    from = snap.sharedFor(current);
    final kept = from == null ? null : VersionSnapshot.summaryOf(from);
    final ok = await showAutoBackupNotice(context, restored: now, kept: kept, keptName: from == null ? null : p.basename(from));
    if (ok == true && from != null) {
      try {
        await snap.restoreFrom(from);
        c.note(trf('보관해 둔 설정을 되살렸습니다: {0}', [from]));
        await restart();
        return;
      } catch (e) {
        c.note(trf('설정을 되살리지 못했습니다: {0}', [e]));
      }
    }
    c.note(trf('Android 자동 백업에서 이전 설정을 되살렸습니다 (동영상 목록 {0}개 · WebDAV 서버 {1}개)', [now.videos, now.servers.length]));
    from = null;
  } else if (freshInstall) {
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

typedef SettingsSummary = ({int videos, List<String> servers, DateTime? saved});

/// 115: 자동 백업에서 되살아난 것 [restored] 를 알린다. [kept] (공용 폴더의 보관본) 가 있으면 그것으로 되살릴지도 묻는다.
/// 보관본으로 되살리기를 고르면 true
Future<bool?> showAutoBackupNotice(BuildContext context,
    {required SettingsSummary restored, SettingsSummary? kept, String? keptName}) {
  String servers(List<String> s) => s.isEmpty ? tr('없음') : s.join(', ');
  final text = StringBuffer(trf(
      '앱을 다시 설치하자 Android 자동 백업 (Google 백업) 이 이전 설정을 되살렸습니다.\n'
      '· 동영상 목록 {0}개\n· WebDAV 서버: {1}', [restored.videos, servers(restored.servers)]));
  text.write('\n\n');
  text.write(tr('비밀번호 · 자막 API 키는 백업하지 않으므로 다시 넣어 주세요. '
      '자동 백업은 하루에 한 번쯤 만들어져 그 뒤에 바꾼 것은 빠졌을 수 있습니다.'));
  if (kept != null) {
    text.write('\n\n');
    text.write(trf('Download/JJ_MKVMaker 에 보관한 설정 (v{0}{1}) 도 있습니다:\n· 동영상 목록 {2}개\n· WebDAV 서버: {3}', [
      keptName ?? '',
      kept.saved == null ? '' : ' · ${kept.saved!.toLocal().toString().substring(0, 16)}',
      kept.videos,
      servers(kept.servers),
    ]));
  }
  return showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      scrollable: true,
      title: Text(tr('이전 설정을 되살렸습니다')),
      content: SizedBox(width: 520, child: Text(text.toString())),
      actions: [
        if (kept == null)
          FilledButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('확인')))
        else ...[
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('자동 백업 그대로'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr('보관한 설정으로 되살리고 다시 시작'))),
        ],
      ],
    ),
  );
}

/// P0: 되돌리느라 공용 폴더에 옮겨 둔 받은 AI 모델이 있으면 되살린다 (SHA-256 확인, 다 되면 공용 폴더의 사본을 지움).
/// 이 기능이 있는 판이 켜질 때 (되돌린 뒤 다시 설치했거나, 예전 판에서 이 판으로 다시 올렸을 때) 한 번.
Future<void> restoreModelBackup(BuildContext context, AppController c) async {
  final backup = ModelBackup.shared;
  if (backup == null || !backup.exists) return;
  final roots = await rollbackModelRoots(c);
  if (!context.mounted) return;
  final size = gbText(backup.savedSize);
  RestoreResult? result;
  final err = await withProgressDialog(context, trf('복사해 둔 AI 모델 ({0}) 을 되살리는 중', [size]), (onProgress) async {
    result = await backup.restore(roots, onProgress: onProgress);
    return null;
  });
  final r = result;
  final text = err != null
      ? trf('복사해 둔 AI 모델을 되살리지 못했습니다 (사본은 Download/JJ_MKVMaker/AI 모델 보관 에 그대로): {0}', [err])
      : r!.failed.isEmpty
          ? trf('복사해 둔 AI 모델 ({0}) 을 되살렸습니다', [size])
          : trf('AI 모델 {0}개는 확인 (SHA-256) 이 맞지 않아 되살리지 않았습니다. 사본은 공용 폴더에 남겨 두었습니다: {1}',
              [r.failed.length, r.failed.take(3).join(', ')]);
  c.note(text);
  if (context.mounted) ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(text)));
}
