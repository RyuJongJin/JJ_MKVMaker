import 'dart:async';

import 'package:flutter/material.dart';

import '../app/app_controller.dart';
import '../app/master_lock.dart';
import '../app/settings.dart';
import '../core/secret_gate.dart';
import '../services/secret_store.dart';
import '../l10n/tr.dart';
import 'confirm.dart';
import 'theme.dart';

/// 124: 마스터 비밀번호 입력 창.
/// - 마스터를 넣으면 풀린다 (앱이 켜져 있는 동안).
/// - 최상 비밀번호를 넣으면 초기화 창 ([forChange] 면 최상도 바꾸기 · 끄기 허락으로 받는다).
/// - [비밀번호를 잊었습니다]: 저장된 비밀번호를 지우고 마스터를 초기화 (비밀번호가 새어 나가지 않게).
/// 써도 되면 true.
Future<bool> askMaster(BuildContext context, AppController c, MasterLock lock,
    {String? reason, bool forChange = false}) async {
  final r = await showDialog<_Result>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _MasterDialog(lock: lock, reason: reason, forChange: forChange),
  );
  if (!context.mounted) return false;
  switch (r) {
    case _Result.ok:
      return true;
    case _Result.superPassword:
      if (forChange) return true;
      await showSuperReset(context, c, lock);
      return lock.unlocked || !lock.hasMaster;
    case _Result.forgot:
      return forgotMaster(context, c, lock);
    case _Result.cancel:
    case null:
      return false;
  }
}

enum _Result { ok, superPassword, forgot, cancel }

class _MasterDialog extends StatefulWidget {
  const _MasterDialog({required this.lock, this.reason, required this.forChange});
  final MasterLock lock;
  final String? reason;
  final bool forChange;

  @override
  State<_MasterDialog> createState() => _MasterDialogState();
}

class _MasterDialogState extends State<_MasterDialog> {
  final _text = TextEditingController();
  bool _busy = false;
  String? _error;
  Timer? _tick;

  MasterLock get lock => widget.lock;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && lock.waitUntil != null) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    _text.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy || _text.text.isEmpty || lock.waiting != null) return;
    setState(() => _busy = true);
    final r = await lock.check(_text.text);
    if (!mounted) return;
    setState(() => _busy = false);
    switch (r) {
      case MasterInput.master:
        Navigator.pop(context, _Result.ok);
      case MasterInput.superPassword:
        Navigator.pop(context, _Result.superPassword);
      case MasterInput.wrong:
      case MasterInput.wait:
        _text.clear();
        setState(() => _error = trf('비밀번호가 틀렸습니다 ({0}번)', [lock.fails]));
    }
  }

  @override
  Widget build(BuildContext context) {
    final wait = lock.waiting;
    return AlertDialog(
      scrollable: true,
      icon: const Icon(Icons.lock_outline),
      title: Text(widget.forChange ? tr('지금 마스터 (또는 최상) 비밀번호') : tr('마스터 비밀번호')),
      content: SizedBox(
        width: 420,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(widget.reason ?? tr('저장된 비밀번호를 쓰는 기능 · 설정을 열려면 마스터 비밀번호를 넣으세요. 앱을 끌 때까지 다시 묻지 않습니다.')),
          const SizedBox(height: 12),
          TextField(
            controller: _text,
            obscureText: true,
            autofocus: true,
            enabled: !_busy && wait == null,
            decoration: InputDecoration(labelText: tr('비밀번호'), errorText: _error),
            onSubmitted: (_) => _submit(),
          ),
          if (wait != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(trf('여러 번 틀려 {0}초 뒤에 다시 넣을 수 있습니다', [wait.inSeconds + 1]),
                  style: const TextStyle(color: Colors.redAccent)),
            ),
          if (_busy) const Padding(padding: EdgeInsets.only(top: 8), child: LinearProgressIndicator()),
          if (!widget.forChange)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: _busy ? null : () => Navigator.pop(context, _Result.forgot),
                child: Text(tr('비밀번호를 잊었습니다')),
              ),
            ),
        ]),
      ),
      actions: [
        TextButton(onPressed: _busy ? null : () => Navigator.pop(context, _Result.cancel), child: Text(tr('취소'))),
        FilledButton(onPressed: _busy || wait != null ? null : _submit, child: Text(tr('확인'))),
      ],
    );
  }
}

/// 저장된 실제 비밀번호 · API 키를 지운다 (서버 목록 · 아이디는 남김)
Future<void> clearStoredSecrets(AppController c) => c.updateSettings((s) => s
  ..webdavServers = [for (final x in s.webdavServers) x.copyWith(password: '')]
  ..openSubtitlesKey = ''
  ..openSubtitlesPassword = '');

/// 앱 설정 전체를 처음 상태로 (다음에 켤 때부터 모두 적용되도록 앱을 다시 켜 달라고 한다)
Future<void> resetAllSettings(AppController c) async {
  c.settings = AppSettings();
  await c.updateSettings((_) {});
}

/// 마스터를 잊었을 때: 저장된 비밀번호를 지우고 마스터를 초기화한다 (확인 뒤). 했으면 true
Future<bool> forgotMaster(BuildContext context, AppController c, MasterLock lock) async {
  final ok = await confirmAction(
    context,
    title: tr('저장된 비밀번호를 지우고 마스터 초기화'),
    body: tr('마스터 비밀번호를 모르면 저장된 비밀번호를 쓸 수 없습니다. 비밀번호가 새어 나가지 않도록, '
        '저장된 WebDAV · OpenSubtitles 비밀번호와 API 키를 지우고 마스터 비밀번호를 초기화합니다. '
        '서버 목록 · 아이디 · 다른 설정은 그대로이며, 비밀번호는 다시 넣어야 합니다.'),
    ok: tr('지우고 초기화'),
  );
  if (!ok || !context.mounted) return false;
  await clearStoredSecrets(c);
  await lock.clearMaster();
  if (context.mounted) {
    await _done(context, c, lock, [tr('저장된 비밀번호 · API 키를 지웠습니다'), tr('마스터 비밀번호를 초기화했습니다')]);
  }
  return true;
}

/// 최상 비밀번호를 넣었을 때: 무엇을 초기화할지 고른다 (처음 체크는 마스터만) → 한 번 더 확인 → 하고 알림
Future<void> showSuperReset(BuildContext context, AppController c, MasterLock lock) async {
  var master = lock.hasMaster, secrets = false, settings = false;
  final go = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, set) => AlertDialog(
        scrollable: true,
        icon: const Icon(Icons.restart_alt),
        title: Text(tr('최상 비밀번호 - 초기화')),
        content: SizedBox(
          width: 460,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(tr('초기화할 것을 고르세요.')),
            CheckboxListTile(
              value: master,
              onChanged: lock.hasMaster ? (v) => set(() => master = v!) : null,
              title: Text(tr('마스터 비밀번호')),
            ),
            CheckboxListTile(
              value: secrets,
              onChanged: (v) => set(() => secrets = v!),
              title: Text(tr('저장된 실제 비밀번호 · API 키')),
              subtitle: Text(tr('WebDAV · OpenSubtitles 등. 서버 목록과 아이디는 남깁니다')),
            ),
            CheckboxListTile(
              value: settings,
              onChanged: (v) => set(() => settings = v!),
              title: Text(tr('앱 설정 전체 (처음 상태로)')),
              subtitle: Text(tr('WebDAV 서버 목록과 그 저장된 비밀번호도 지워집니다. 동영상 목록 · 즐겨찾기 · 파일은 그대로입니다')),
            ),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('취소'))),
          FilledButton(
            onPressed: master || secrets || settings ? () => Navigator.pop(ctx, true) : null,
            child: Text(tr('초기화')),
          ),
        ],
      ),
    ),
  );
  if (go != true || !context.mounted) return;
  final what = [
    if (master) tr('마스터 비밀번호'),
    if (secrets) tr('저장된 실제 비밀번호 · API 키'),
    if (settings) tr('앱 설정 전체 (처음 상태로)'),
  ];
  final sure = await confirmAction(
    context,
    title: tr('정말 초기화할까요?'),
    body: '${what.map((x) => '• $x').join('\n')}\n\n${tr('되돌릴 수 없습니다.')}',
    ok: tr('초기화'),
  );
  if (!sure || !context.mounted) return;
  final done = <String>[];
  if (secrets) {
    await clearStoredSecrets(c);
    done.add(tr('저장된 비밀번호 · API 키를 지웠습니다'));
  }
  if (settings) {
    await resetAllSettings(c);
    done.add(tr('앱 설정을 처음 상태로 돌렸습니다 (모두 적용하려면 앱을 다시 켜 주세요)'));
  }
  if (master) {
    await lock.clearMaster();
    done.add(tr('마스터 비밀번호를 초기화했습니다'));
  } else {
    lock.unlocked = true; // 최상을 아는 사람
  }
  if (context.mounted) await _done(context, c, lock, done);
}

/// 무엇을 했는지 알리고, 마스터가 없어졌으면 새로 정할 수 있게
Future<void> _done(BuildContext context, AppController c, MasterLock lock, List<String> done) async {
  final setNew = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      icon: const Icon(Icons.check_circle_outline, color: JjColors.accent),
      title: Text(tr('초기화했습니다')),
      content: Text(done.map((x) => '• $x').join('\n')),
      actions: [
        if (!lock.hasMaster)
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr('새 마스터 비밀번호 정하기'))),
        FilledButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('닫기'))),
      ],
    ),
  );
  if (setNew == true && context.mounted) await setPasswordDialog(context, c, lock, superPassword: false);
}

/// 새 마스터 · 최상 비밀번호를 정한다 (두 번 넣기). 정했으면 true
Future<bool> setPasswordDialog(BuildContext context, AppController c, MasterLock lock, {required bool superPassword}) async {
  final a = TextEditingController(), b = TextEditingController();
  String? error;
  var busy = false;
  final ok = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, set) {
        Future<void> save() async {
          if (a.text.isEmpty) return set(() => error = tr('비밀번호를 넣으세요'));
          if (a.text != b.text) return set(() => error = tr('두 번 넣은 비밀번호가 다릅니다'));
          set(() => busy = true);
          final fine = superPassword ? await lock.setSuper(a.text) : await lock.setMaster(a.text);
          if (!ctx.mounted) return;
          if (!fine) {
            return set(() {
              busy = false;
              error = superPassword
                  ? tr('마스터 비밀번호와 같게 정할 수 없습니다')
                  : tr('최상 비밀번호와 같게 정할 수 없습니다');
            });
          }
          Navigator.pop(ctx, true);
        }

        return AlertDialog(
          scrollable: true,
          title: Text(superPassword ? tr('최상 비밀번호 정하기') : tr('마스터 비밀번호 정하기')),
          content: SizedBox(
            width: 420,
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(superPassword
                  ? tr('최상 비밀번호는 모든 것을 초기화하는 열쇠입니다. 마스터 입력 창에 넣으면 초기화 창이 열립니다.')
                  : tr('저장된 비밀번호 · 설정 · 비밀번호가 필요한 기능을 쓸 때 묻습니다. 잊으면 최상 비밀번호로 초기화하거나, '
                      '저장된 비밀번호를 지우고 초기화할 수 있습니다.')),
              const SizedBox(height: 8),
              Text(tr('이 기기에는 원문이 아니라 되돌릴 수 없는 해시만 남습니다.'),
                  style: const TextStyle(fontSize: 12, color: JjColors.textDim)),
              TextField(
                  controller: a,
                  obscureText: true,
                  autofocus: true,
                  enabled: !busy,
                  decoration: InputDecoration(labelText: tr('새 비밀번호'))),
              TextField(
                controller: b,
                obscureText: true,
                enabled: !busy,
                decoration: InputDecoration(labelText: tr('한 번 더'), errorText: error),
                onSubmitted: (_) => save(),
              ),
              if (busy) const Padding(padding: EdgeInsets.only(top: 8), child: LinearProgressIndicator()),
            ]),
          ),
          actions: [
            TextButton(onPressed: busy ? null : () => Navigator.pop(ctx, false), child: Text(tr('취소'))),
            FilledButton(onPressed: busy ? null : save, child: Text(tr('저장'))),
          ],
        );
      },
    ),
  );
  a.dispose();
  b.dispose();
  // 처음 정하면 묻는 때는 "비밀번호가 저장된 기능을 쓸 때" (안전 저장소에 값이 없으면 그렇게 본다 - [MasterLock.ask])
  return ok == true;
}

/// 묻는 창을 띄울 화면 ([attachMasterPrompt])
GlobalKey<NavigatorState>? _masterNav;

/// 앱을 켤 때 (설정을 읽은 바로 뒤, 실시간 동기화 등이 서버에 붙기 전): 마스터 잠금을 만들고
/// (안전 저장소의 해시 읽기) 저장된 비밀번호를 쓰는 곳들이 지나는 문에 건다.
/// [secrets]: 설정 저장소가 없는 창 (재생만 하는 두 번째 창) 이 쓰는 안전 저장소
Future<MasterLock> setupMasterLock(AppController c, {SecretStore? secrets}) async {
  final lock = MasterLock(secrets ?? c.settingsStore?.secrets ?? SecretStore.platform());
  try {
    await lock.load();
  } catch (_) {}
  MasterLock.instance = lock;
  MasterLock.prompt = (reason) async {
    // 화면이 아직 없으면 (켜는 중) 뜰 때까지 조금 기다린다
    for (var i = 0; i < 60; i++) {
      final ctx = _masterNav?.currentContext;
      if (ctx != null && ctx.mounted) return askMaster(ctx, c, lock, reason: reason);
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    return false;
  };
  SecretGate.check = (force) => lock.ensure(force: force);
  return lock;
}

/// 마스터를 묻는 창을 띄울 화면
void attachMasterPrompt(GlobalKey<NavigatorState> navigatorKey) => _masterNav = navigatorKey;

/// "처음 시작 시" 로 정해 두었으면 켤 때 한 번 묻는다. 배경 작업 (실시간 동기화 등) 과 같은 창 하나로 (128).
/// 취소해도 앱은 쓸 수 있고, 이번 실행 동안 배경 작업은 묻지 않고 건너뛴다 (사용자가 직접 누르면 다시 묻는다).
Future<void> askMasterAtStartup(BuildContext context, AppController c) async {
  final lock = MasterLock.instance;
  if (lock == null || !lock.needsPrompt(startup: true) || lock.ask != 'startup') return;
  await lock.ensure(force: true);
}
