import 'package:flutter/material.dart';

import '../app/app_controller.dart';
import '../core/app_update.dart';
import 'theme.dart';
import '../l10n/tr.dart';

/// 새 버전 확인 → 알림 → 받기 · 검증 → 종료 후 설치 · 다시 시작
///
/// [manual]: 환경 설정에서 "지금 확인" 을 누른 경우 (최신이어도 알려 주고, 건너뛴 버전도 보여 줌)
Future<void> checkForUpdate(BuildContext context, AppController c, {bool manual = false}) async {
  final up = c.services.updater;
  if (up == null) return;
  final s = c.settings;
  final String current;
  try {
    current = await up.currentVersion();
  } catch (_) {
    return;
  }
  if (!manual &&
      (!s.autoCheckUpdates ||
          !updateCheckDue(s.lastUpdateCheck, DateTime.now(), checkedBy: s.lastUpdateCheckVersion, current: current))) {
    return;
  }

  void snack(String t) {
    if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t)));
  }

  final ReleaseInfo? r;
  try {
    r = await up.latest();
  } catch (e) {
    c.note(trf('새 버전을 확인할 수 없습니다: {0}', [e]));
    if (manual) snack(trf('새 버전을 확인할 수 없습니다: {0}', [e]));
    return;
  }
  await c.updateSettings((x) => x
    ..lastUpdateCheck = DateTime.now().toIso8601String()
    ..lastUpdateCheckVersion = current);
  // 작업 기록에 남긴다 (업데이트가 안 될 때 원인을 찾을 수 있게)
  c.note(trf('새 버전 확인: 지금 v{0} · 최신 v{1}', [current, r?.version ?? '-']));
  if (r == null || !r.isNewerThan(current)) {
    if (manual) snack(trf('최신 버전입니다 (v{0})', [current]));
    return;
  }
  if (!manual && s.skippedVersion == r.version) return;
  if (!context.mounted) return;

  final choice = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(trf('새 버전 v{0}', [r!.version])),
      content: SizedBox(
        width: 560,
        height: 380,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(trf('지금 쓰는 버전: v{0}  →  새 버전: v{1}', [current, r.version])),
          if (r.zipSize > 0)
            Text(trf('받는 크기: 약 {0}MB · 받은 파일 · AI 모델 · 설정은 그대로 둡니다', [(r.zipSize / 1e6).round()]),
                style: const TextStyle(fontSize: 12, color: JjColors.textDim)),
          const SizedBox(height: 12),
          Text(tr('바뀐 내용'), style: TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          Expanded(
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(color: JjColors.bg, borderRadius: BorderRadius.circular(6)),
              child: SingleChildScrollView(
                child: SelectableText(r.notes.isEmpty ? tr('(설명 없음)') : r.notes,
                    style: const TextStyle(fontSize: 12, height: 1.5)),
              ),
            ),
          ),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, 'skip'), child: Text(tr('이 버전 건너뛰기'))),
        TextButton(onPressed: () => Navigator.pop(ctx, 'page'), child: Text(tr('페이지 열기'))),
        TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('나중에'))),
        FilledButton.icon(
          onPressed: () => Navigator.pop(ctx, 'update'),
          icon: const Icon(Icons.system_update_alt, size: 18),
          label: Text(tr('업데이트')),
        ),
      ],
    ),
  );
  switch (choice) {
    case 'skip':
      await c.updateSettings((x) => x.skippedVersion = r!.version);
      return;
    case 'page':
      await up.openPage(r);
      return;
    case 'update':
      break;
    default:
      return;
  }

  if (c.busy) {
    snack(tr('MKV 만들기 · AI 자막 작업이 끝난 뒤 업데이트하세요.'));
    return;
  }
  // 프로그램 폴더에 쓸 수 없으면 (예: Program Files) 페이지에서 직접 받도록
  if (r.zipUrl == null || !await up.canInstall()) {
    snack(tr('자동 설치를 할 수 없는 위치입니다. 페이지에서 직접 받아 주세요.'));
    await up.openPage(r);
    return;
  }
  if (!context.mounted) return;

  final progress = ValueNotifier<double>(0);
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => AlertDialog(
      title: Text(trf('v{0} 받는 중', [r!.version])),
      content: ValueListenableBuilder<double>(
        valueListenable: progress,
        builder: (_, v, _) => Column(mainAxisSize: MainAxisSize.min, children: [
          Text(v >= 1 ? (up.installsInPlace ? tr('파일 확인 중…') : tr('확인 · 압축 푸는 중…')) : '${(v * 100).round()}%'),
          const SizedBox(height: 12),
          LinearProgressIndicator(value: v >= 1 ? null : v),
        ]),
      ),
    ),
  );
  String dir;
  try {
    dir = await up.download(r, (x) => progress.value = x);
  } catch (e) {
    if (context.mounted) Navigator.of(context).pop();
    snack(trf('업데이트 실패: {0}', [e]));
    return;
  }
  if (!context.mounted) return;
  Navigator.of(context).pop();

  final go = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(tr('설치 준비 완료')),
      content: Text(trf('v{0} 을 받았고 파일 검증(SHA256)을 마쳤습니다.\n' '{1}', [r!.version, up.installsInPlace ? tr('Android 설치 화면에서 [설치] 를 누르세요. 설정 · 받은 파일 · AI 모델은 그대로 남습니다.\n' '(처음이면 "이 출처의 앱 설치 허용" 을 켜야 할 수 있습니다)') : tr('프로그램을 종료하고 설치한 뒤 자동으로 다시 시작합니다.')])),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('나중에'))),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr('지금 설치'))),
      ],
    ),
  );
  if (go != true) return;
  // Android: 설치 화면만 연다 (앱을 끝내지 않음, 설치되면 Android 가 앱을 다시 띄움)
  if (up.installsInPlace) {
    try {
      await up.scheduleInstall(dir);
    } catch (e) {
      snack(trf('설치 화면을 열 수 없습니다: {0}', [e]));
    }
    return;
  }
  // 다운로드 중이면 기존 종료 확인 절차
  final ok = await (c.confirmQuit?.call() ?? Future.value(true));
  if (!ok) return;
  await up.scheduleInstall(dir);
  await c.services.shell.quit();
}
