import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../app/ai_local.dart' show AiStore;
import '../app/app_controller.dart';
import '../app/copy_center.dart' show diskSpace;
import '../app/model_backup.dart';
import '../app/version_snapshot.dart';
import '../core/app_update.dart';
import '../services/updater.dart' show InstallPermissionNeeded, Updater;
import 'theme.dart';
import '../l10n/tr.dart';

/// 새 버전 확인 → 알림 → 받기 · 검증 → 종료 후 설치 · 다시 시작 (하루 한 번 자동 확인 · 최신 버전만)
///
/// [manual]: "지금 확인" (최신이어도 알려 주고, 건너뛴 버전도 보여 줌)
/// [onResult]: 164 - 직접 확인할 때 결과를 알림 대신 버튼 옆에 (최신 · 새 버전 · 확인 못 함)
Future<void> checkForUpdate(BuildContext context, AppController c, {bool manual = false, void Function(String result)? onResult}) async {
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
    if (onResult != null) return onResult(t);
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
  onResult?.call(trf('새 버전 v{0} 이 있습니다', [r.version]));
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
          Text(tr('바뀐 내용'), style: const TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          Expanded(child: _Notes(r.notes)),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, 'skip'), child: Text(tr('이 버전 건너뛰기'))),
        TextButton(onPressed: () => Navigator.pop(ctx, 'versions'), child: Text(tr('다른 버전 고르기'))),
        TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('나중에'))),
        FilledButton.icon(
          onPressed: () => Navigator.pop(ctx, 'update'),
          icon: const Icon(Icons.system_update_alt, size: 18),
          label: Text(tr('업데이트')),
        ),
      ],
    ),
  );
  if (!context.mounted) return;
  switch (choice) {
    case 'skip':
      await c.updateSettings((x) => x.skippedVersion = r!.version);
    case 'versions':
      await chooseVersion(context, c);
    case 'update':
      await installRelease(context, c, r, current);
  }
}

/// 환경 설정 > [업데이트]: GitHub 에 올려 둔 모든 버전을 보여 주고 골라 설치한다.
/// 최신으로 올리기뿐 아니라 예전 (정상이던) 버전으로 되돌리기 · 같은 버전 다시 설치도 된다.
Future<void> chooseVersion(BuildContext context, AppController c) async {
  final up = c.services.updater;
  if (up == null) return;
  final String current;
  try {
    current = await up.currentVersion();
  } catch (_) {
    return;
  }
  if (!context.mounted) return;
  final picked = await showDialog<ReleaseInfo>(
    context: context,
    builder: (_) => _VersionPicker(up: up, current: current),
  );
  if (picked == null || !context.mounted) return;
  await installRelease(context, c, picked, current);
}

/// 169: 버전 고르기 창에서 처음 고를 버전: 이 기기용 파일이 있는 것 중 가장 새것, 없으면 지금 버전 (목록은 새것이 앞)
ReleaseInfo initialVersionPick(List<ReleaseInfo> all, String current) =>
    all.firstWhere((r) => r.zipUrl != null, orElse: () => all.firstWhere((r) => r.version == current, orElse: () => all.first));

/// 164: [최신 버전 확인] 과 그 결과 (버튼 옆에 - 최신입니다 · 새 버전이 있습니다 · 확인할 수 없습니다)
class UpdateCheckButton extends StatefulWidget {
  final AppController c;
  const UpdateCheckButton({super.key, required this.c});

  @override
  State<UpdateCheckButton> createState() => _UpdateCheckButtonState();
}

class _UpdateCheckButtonState extends State<UpdateCheckButton> {
  bool _busy = false;
  String? _result;

  Future<void> _check() async {
    setState(() {
      _busy = true;
      _result = null;
    });
    try {
      await checkForUpdate(context, widget.c, manual: true, onResult: (r) {
        if (mounted) setState(() => _result = r);
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Wrap(spacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
        OutlinedButton(onPressed: _busy ? null : _check, child: Text(tr('최신 버전 확인'))),
        if (_busy) const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
        if (_result != null) Text(_result!, style: const TextStyle(fontSize: 12, color: JjColors.textDim)),
      ]);
}

/// 버전 고르기 창
class _VersionPicker extends StatefulWidget {
  final Updater up;
  final String current;
  const _VersionPicker({required this.up, required this.current});

  @override
  State<_VersionPicker> createState() => _VersionPickerState();
}

class _VersionPickerState extends State<_VersionPicker> {
  late final Future<List<ReleaseInfo>> _list = widget.up.releases();
  ReleaseInfo? _sel;

  @override
  void initState() {
    super.initState();
    // 169: 처음엔 최신 버전 (이 기기용 파일이 있는 것 중 가장 새것) 을 골라 둔다 - 이 창을 여는 사람은 대개 업데이트하려는 것.
    // 이 기기용 파일이 하나도 없으면 지금 쓰는 버전. (목록을 다 읽은 뒤 버튼 글도 맞게)
    _list.then((all) {
      if (!mounted || _sel != null || all.isEmpty) return;
      setState(() => _sel = initialVersionPick(all, widget.current));
    }, onError: (_) {});
  }

  String _date(DateTime? d) {
    if (d == null) return '';
    final l = d.toLocal();
    String two(int x) => x.toString().padLeft(2, '0');
    return '${l.year}-${two(l.month)}-${two(l.day)} ${two(l.hour)}:${two(l.minute)}';
  }

  /// 고른 버전으로 무엇을 하게 되는지 (버튼 글)
  String _action(ReleaseInfo r) {
    final d = compareVersions(r.version, widget.current);
    return d > 0 ? tr('이 버전으로 업데이트') : d < 0 ? tr('이 버전으로 되돌리기') : tr('다시 설치');
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(tr('버전 고르기')),
        content: SizedBox(
          width: 720,
          height: 480,
          child: FutureBuilder<List<ReleaseInfo>>(
            future: _list,
            builder: (context, snap) {
              if (snap.hasError) return Center(child: Text(trf('버전 목록을 읽을 수 없습니다: {0}', [snap.error])));
              if (!snap.hasData) return const Center(child: CircularProgressIndicator());
              final all = snap.data!;
              if (all.isEmpty) return Center(child: Text(tr('올려 둔 버전이 없습니다.')));
              final newest = all.first.version;
              return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                SizedBox(
                  width: 300,
                  child: ListView(children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
                      child: Text(trf('지금 쓰는 버전: v{0}', [widget.current]),
                          style: const TextStyle(fontSize: 12, color: JjColors.textDim)),
                    ),
                    for (final r in all)
                      ListTile(
                        dense: true,
                        selected: _sel?.version == r.version,
                        selectedTileColor: JjColors.accent.withValues(alpha: 0.15),
                        title: Row(children: [
                          Text('v${r.version}', style: const TextStyle(fontWeight: FontWeight.w600)),
                          if (r.version == widget.current) _Badge(tr('지금'), JjColors.accent),
                          if (r.version == newest) _Badge(tr('최신'), Colors.greenAccent),
                          if (r.prerelease) _Badge(tr('시험판'), Colors.orangeAccent),
                        ]),
                        subtitle: Text(r.zipUrl == null ? '${_date(r.published)} · ${tr('이 기기용 파일 없음')}' : _date(r.published),
                            style: const TextStyle(fontSize: 11)),
                        enabled: r.zipUrl != null,
                        onTap: () => setState(() => _sel = r),
                      ),
                  ]),
                ),
                const VerticalDivider(width: 16),
                Expanded(
                  child: _sel == null
                      ? const SizedBox()
                      : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text('v${_sel!.version}', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                          if (compareVersions(_sel!.version, widget.current) < 0)
                            Padding(
                              padding: const EdgeInsets.only(top: 6),
                              child: Text(
                                  [
                                    tr('예전 버전으로 되돌립니다. 지금 버전의 설정 (동영상 목록 · 즐겨찾기 포함) 은 보관해 두었다가, '
                                        '나중에 이 버전으로 다시 오면 되살릴 수 있습니다.'),
                                    // P0: Android 는 앱을 지운 뒤 설치한다 - 무엇이 사라지는지는 다음 창에서
                                    if (Platform.isAndroid)
                                      tr('Android 에서는 앱을 지운 뒤 예전 버전을 설치합니다. 받은 AI 모델 · 비밀번호 · 브라우저 로그인 등은 '
                                          '사라집니다 (남는 것과 사라지는 것은 다음 창에서 보여 줍니다).'),
                                  ].join('\n'),
                                  style: const TextStyle(fontSize: 12, color: Colors.orangeAccent)),
                            ),
                          const SizedBox(height: 8),
                          Text(tr('바뀐 내용'), style: const TextStyle(fontWeight: FontWeight.w600)),
                          const SizedBox(height: 4),
                          Expanded(child: _Notes(_sel!.notes)),
                        ]),
                ),
              ]);
            },
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('닫기'))),
          FilledButton.icon(
            onPressed: _sel == null || _sel!.zipUrl == null ? null : () => Navigator.pop(context, _sel),
            icon: const Icon(Icons.system_update_alt, size: 18),
            label: Text(_sel == null ? tr('업데이트') : _action(_sel!)),
          ),
        ],
      );
}

class _Badge extends StatelessWidget {
  final String text;
  final Color color;
  const _Badge(this.text, this.color);

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.only(left: 6),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        decoration: BoxDecoration(border: Border.all(color: color), borderRadius: BorderRadius.circular(8)),
        child: Text(text, style: TextStyle(fontSize: 10, color: color)),
      );
}

class _Notes extends StatelessWidget {
  final String notes;
  const _Notes(this.notes);

  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(color: JjColors.bg, borderRadius: BorderRadius.circular(6)),
        child: SingleChildScrollView(
          child: SelectableText(notes.isEmpty ? tr('(설명 없음)') : notes, style: const TextStyle(fontSize: 12, height: 1.5)),
        ),
      );
}

/// 받기 (진행 창) → 받은 파일 경로. 실패하면 null.
Future<String?> _download(BuildContext context, Updater up, ReleaseInfo r) async {
  final progress = ValueNotifier<double>(0);
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => AlertDialog(
        scrollable: true,
      title: Text(trf('v{0} 받는 중', [r.version])),
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
  try {
    final dir = await up.download(r, (x) => progress.value = x);
    if (context.mounted) Navigator.of(context).pop();
    return dir;
  } catch (e) {
    if (context.mounted) {
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(trf('업데이트 실패: {0}', [e]))));
    }
    return null;
  }
}

/// [r] 버전 설치 (새 버전 · 예전 버전 · 같은 버전 모두). 설치 전에 지금 버전의 설정을 보관한다.
Future<void> installRelease(BuildContext context, AppController c, ReleaseInfo r, String current) async {
  final up = c.services.updater!;
  void snack(String t) {
    if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t)));
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
  final down = compareVersions(r.version, current) < 0;
  // Android 는 낮은 버전을 위에 설치할 수 없다 (앱을 지우고 설치해야 함) → 따로 안내
  if (down && up.installsInPlace) {
    if (context.mounted) await _androidRollback(context, c, up, r, current);
    return;
  }
  if (!context.mounted) return;
  final dir = await _download(context, up, r);
  if (dir == null || !context.mounted) return;

  final go = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
        scrollable: true,
      title: Text(tr('설치 준비 완료')),
      content: Text(trf('v{0} 을 받았고 파일 검증(SHA256)을 마쳤습니다.\n' '{1}', [
        r.version,
        up.installsInPlace
            ? tr('Android 설치 화면에서 [설치] 를 누르세요. 설정 · 받은 파일 · AI 모델은 그대로 남습니다.\n' '(처음이면 "이 출처의 앱 설치 허용" 을 켜야 할 수 있습니다)')
            : down
                ? trf('프로그램을 종료하고 예전 버전 (v{0}) 으로 되돌린 뒤 다시 시작합니다. 프로그램 폴더는 그 버전과 똑같이 맞추고, '
                    '받은 파일 · AI 모델은 그대로 둡니다. 지금 버전 (v{1}) 의 설정은 보관해 둡니다.', [r.version, current])
                : tr('프로그램을 종료하고 설치한 뒤 자동으로 다시 시작합니다.'),
      ])),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('나중에'))),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr('지금 설치'))),
      ],
    ),
  );
  if (go != true) return;
  await _saveSnapshot(c, current);
  // Android: 설치 화면만 연다 (앱을 끝내지 않음, 설치되면 Android 가 앱을 다시 띄움)
  if (up.installsInPlace) {
    while (true) {
      try {
        await up.scheduleInstall(dir);
        return;
      } on InstallPermissionNeeded {
        // 설치 허용 설정 화면이 열렸다: 켜고 돌아와 [설치 계속] → 받은 파일로 다시 (처음부터 다시 받지 않게)
        if (!context.mounted) return;
        final again = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
        scrollable: true,
            title: Text(tr('설치 허용 필요')),
            content: Text(tr('설정 화면에서 "이 출처의 앱 설치 허용" 을 켠 뒤 돌아와 [설치 계속] 을 누르세요. '
                '받은 파일을 그대로 씁니다 (다시 받지 않음).')),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('나중에'))),
              FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr('설치 계속'))),
            ],
          ),
        );
        if (again != true) return;
      } catch (e) {
        snack(trf('설치 화면을 열 수 없습니다: {0}', [e]));
        return;
      }
    }
  }
  // 다운로드 중이면 기존 종료 확인 절차
  final ok = await (c.confirmQuit?.call() ?? Future.value(true));
  if (!ok) return;
  await up.scheduleInstall(dir);
  await c.services.shell.quit();
}

/// 다른 버전을 설치하기 전에 지금 버전의 설정을 보관 (그 버전으로 돌아오면 되살린다)
Future<void> _saveSnapshot(AppController c, String current) async {
  final snap = VersionSnapshot.instance;
  if (snap == null) return;
  try {
    await c.updateSettings((x) => x.lastRunVersion = current); // 보관본이 "이 버전이 쓴 설정" 이 되게
    await snap.save(current);
    c.note(trf('지금 버전 (v{0}) 의 설정을 보관했습니다: {1}', [current, snap.dirOf(current)]));
  } catch (e) {
    c.note(trf('설정을 보관하지 못했습니다: {0}', [e]));
  }
}

/// P0: 되돌리기 때 옮겨 둘 받은 AI 모델 폴더 (그림 · 해상도: 앱 데이터/ai, 자막: 모델 폴더)
Future<Map<String, String>> rollbackModelRoots(AppController c) async => {
      if (AiStore.instance != null) 'ai': AiStore.instance!.root,
      'models': await c.services.models.directory(),
    };

/// 크기를 GB · MB 로
String gbText(int bytes) => bytes >= 1 << 30
    ? '${(bytes / (1 << 30)).toStringAsFixed(1)}GB'
    : '${(bytes / (1 << 20)).toStringAsFixed(0)}MB';

/// 진행 창을 띄우고 [work] 를 한다 (끌 수 없음). 실패하면 그 글
Future<String?> withProgressDialog(
    BuildContext context, String title, Future<Object?> Function(void Function(int done, int total) onProgress) work) async {
  final progress = ValueNotifier<double?>(null);
  final nav = Navigator.of(context);
  // ignore: unawaited_futures
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => AlertDialog(
      title: Text(title),
      content: ValueListenableBuilder<double?>(
        valueListenable: progress,
        builder: (_, v, _) => Column(mainAxisSize: MainAxisSize.min, children: [
          LinearProgressIndicator(value: v),
          const SizedBox(height: 6),
          Text(v == null ? tr('준비하는 중') : '${(v * 100).floor()}%'),
        ]),
      ),
    ),
  );
  String? error;
  try {
    await work((done, total) => progress.value = total == 0 ? null : done / total);
  } catch (e) {
    error = '$e';
  }
  nav.pop();
  return error;
}

/// Android 에서 예전 버전으로: Android 는 버전이 낮은 앱을 위에 설치하지 못하므로 앱을 지운 뒤 설치해야 한다.
/// APK 와 설정 보관본은 앱을 지워도 남는 Download/JJ_MKVMaker 에 두고, 다시 설치한 앱이 시작할 때 설정을 되살린다.
Future<void> _androidRollback(BuildContext context, AppController c, Updater up, ReleaseInfo r, String current) async {
  final snap = VersionSnapshot.instance;
  final shared = snap?.sharedDir;
  if (shared == null) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('공용 저장소 (Download) 를 쓸 수 없어 되돌릴 수 없습니다.'))));
    return;
  }
  // P0: 남는 것 / 사라지는 것을 사실대로. 받은 AI 모델은 공용 폴더에 옮겨 둘 수 있다
  final roots = await rollbackModelRoots(c);
  final modelSize = ModelBackup.sizeOf(roots);
  // 공용 폴더는 처음엔 없을 수 있다 - 있는 가장 가까운 상위 폴더로 남은 공간을 잰다
  var probe = shared;
  while (!Directory(probe).existsSync() && p.dirname(probe) != probe) {
    probe = p.dirname(probe);
  }
  final free = (await diskSpace(probe))?.$1;
  final setting = c.settings.rollbackKeepModels;
  var keep = modelSize > 0 && (setting == 'on' || (setting == '' && free != null && free >= modelSize * 2));
  var keepTouched = false;
  // 옮겨 둔 모델을 되살리는 기능은 이 판 다음부터 들어 있다 (설정 되살리기는 v2026.10.08_001 부터)
  final targetRestoresModels = compareVersions(r.version, '2026.10.09_001') > 0;
  final targetRestoresSettings = compareVersions(r.version, '2026.10.08_001') >= 0;
  if (!context.mounted) return;
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setInner) {
        final size = gbText(modelSize);
        final kept = [
          tr('설정 (WebDAV 서버 목록 포함, 비밀번호는 빼고) · 동영상 목록 · 즐겨찾기 - Download/JJ_MKVMaker/설정 보관'),
          tr('공용 폴더에 받은 파일 (동영상 · 그림 등)'),
          if (keep) trf('받은 AI 모델 ({0}) - Download/JJ_MKVMaker/AI 모델 보관', [size]),
        ];
        final lost = [
          if (modelSize > 0 && !keep) trf('받은 AI 모델 (그림 · 자막) - 다시 받아야 합니다 (약 {0})', [size]),
          tr('비밀번호 · API 키 (WebDAV · OpenSubtitles · AI 서비스)'),
          tr('마스터 · 최상 비밀번호'),
          tr('앱 안 브라우저의 로그인 · 쿠키'),
          tr('작업 기록 · 받다 만 파일'),
        ];
        return AlertDialog(
          scrollable: true,
          title: Text(trf('예전 버전 v{0} 으로 되돌리기', [r.version])),
          content: SizedBox(
            width: 560,
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(trf(
                  'Android 는 버전이 낮은 앱을 지금 앱 위에 설치하지 못합니다. 그래서 v{0} 설치 파일과 아래 "남는 것" 을 '
                  'Download/JJ_MKVMaker 에 저장한 뒤 이 앱을 지우고 (Android 확인 창), 파일 앱에서 그 APK 를 눌러 설치합니다.',
                  [r.version])),
              const SizedBox(height: 10),
              Text(tr('남는 것'), style: const TextStyle(fontWeight: FontWeight.w600)),
              for (final x in kept) Text('· $x'),
              const SizedBox(height: 8),
              Text(tr('사라지는 것'), style: const TextStyle(fontWeight: FontWeight.w600, color: Colors.orangeAccent)),
              for (final x in lost) Text('· $x', style: const TextStyle(color: Colors.orangeAccent)),
              if (modelSize > 0) ...[
                const SizedBox(height: 8),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  value: keep,
                  // 고른 것은 [저장하고 계속] 을 누를 때만 설정에 남긴다 ([취소] 하면 그대로)
                  onChanged: (v) => setInner(() {
                    keep = v ?? false;
                    keepTouched = true;
                  }),
                  title: Text(trf('받은 AI 모델 ({0}) 을 Download/JJ_MKVMaker 에 복사해 두었다가 다시 설치한 뒤 되살리기 (잠시 {0} 더 필요)', [size])),
                  subtitle: Text([
                    if (free != null) trf('남은 공간 {0}', [gbText(free)]),
                    if (!targetRestoresModels)
                      trf('v{0} 은 복사해 둔 모델을 되살리지 못합니다. 이 기능이 있는 판으로 다시 올리면 그때 되살립니다.', [r.version]),
                  ].join(' · ')),
                ),
              ],
              if (!targetRestoresSettings)
                Text(trf('v{0} 은 저장해 둔 설정을 되살리지 못해 설정을 다시 해야 합니다.', [r.version]),
                    style: const TextStyle(color: Colors.orangeAccent)),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('취소'))),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr('저장하고 계속'))),
          ],
        );
      },
    ),
  );
  if (ok != true || !context.mounted) return;
  // 체크를 바꿨으면 이제 설정에 (자동이던 것은 건드리지 않으면 자동 그대로)
  if (keepTouched) await c.updateSettings((x) => x.rollbackKeepModels = keep ? 'on' : 'off');
  if (!context.mounted) return;
  // 사라지는 것이 있으니 한 번 더 (비밀번호 · 로그인은 늘 사라진다)
  final sure = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(tr('정말 되돌릴까요?')),
      content: Text([
        tr('앱을 지우면 다음은 되살릴 수 없습니다:'),
        if (modelSize > 0 && !keep) trf('· 받은 AI 모델 (약 {0}, 다시 받아야 함)', [gbText(modelSize)]),
        tr('· 비밀번호 · API 키 · 마스터 · 최상 비밀번호'),
        tr('· 앱 안 브라우저의 로그인 · 쿠키, 작업 기록'),
      ].join('\n')),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('취소'))),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(tr('되돌리기 계속')),
        ),
      ],
    ),
  );
  if (sure != true || !context.mounted) return;
  final apk = await _download(context, up, r);
  if (apk == null || !context.mounted) return;
  final outDir = p.dirname(shared);
  final saved = p.join(outDir, r.zipName ?? 'JJ_MKVMaker_v${r.version}.apk');
  try {
    await Directory(outDir).create(recursive: true);
    await File(apk).copy(saved);
    await _saveSnapshot(c, current);
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(trf('저장하지 못했습니다: {0}', [e]))));
    }
    return;
  }
  // P0: 받은 AI 모델을 공용 폴더로 (실패하면 앱을 지우지 않는다)
  if (keep && modelSize > 0) {
    final backup = ModelBackup.shared;
    if (backup == null || !context.mounted) return;
    final err = await withProgressDialog(context, tr('AI 모델을 복사해 두는 중'), (onProgress) => backup.save(roots, onProgress: onProgress));
    if (err != null) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(trf('AI 모델을 복사해 두지 못해 멈췄습니다 (앱은 지우지 않음): {0}', [err]))));
      }
      return;
    }
    c.note(trf('되돌리기: AI 모델 {0} 을 복사해 두었습니다: {1}', [gbText(modelSize), backup.dir]));
  }
  if (!context.mounted) return;
  final go = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
        scrollable: true,
      title: Text(tr('저장했습니다')),
      content: Text(trf('설치 파일: {0}\n이제 앱을 지운 뒤, 파일 앱에서 이 파일을 눌러 설치하세요.', [saved])),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('나중에'))),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr('앱 지우기'))),
      ],
    ),
  );
  if (go == true) await up.uninstallSelf();
}
