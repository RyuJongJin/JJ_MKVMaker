import 'package:flutter/material.dart';

import '../app/app_controller.dart';
import '../app/settings.dart';
import '../core/vfs.dart';
import '../core/secret_gate.dart';
import '../core/webdav.dart';
import '../l10n/tr.dart';
import 'confirm.dart';
import 'theme.dart';
import 'setting_tile.dart';

/// 환경 설정 > 파일 탐색기 > WebDAV: 서버 목록 (추가 · 고치기 · 지우기 · 연결 확인).
/// 서버마다 파일 탐색기 · Rsync 화면 위쪽 "SD 카드" 옆에 탭이 생긴다.
class WebDavSettings extends StatelessWidget {
  final AppController c;
  const WebDavSettings({super.key, required this.c});

  @override
  Widget build(BuildContext context) {
    final servers = c.settings.webdavServers;
    return Column(children: [
      SettingTile(
        leading: const Icon(Icons.cloud_outlined),
        title: const Text('WebDAV'),
        subtitle: Text(tr('NAS · 클라우드의 WebDAV 폴더를 파일 탐색기 · Rsync 화면에서 열고 복사 · 동기화합니다 '
            '(위쪽 "SD 카드" 옆 탭). 비밀번호는 이 기기의 안전 저장소에만 두고 설정 파일에는 쓰지 않습니다. 한 번 넣으면 업데이트 뒤에도 남습니다.')),
        trailing: TextButton.icon(
          onPressed: () => editDavServer(context, c),
          icon: const Icon(Icons.add, size: 18),
          label: Text(tr('추가')),
        ),
      ),
      for (final s in servers)
        Padding(
          padding: const EdgeInsets.only(left: 16),
          child: SettingTile(
            dense: true,
            leading: const Icon(Icons.cloud, color: JjColors.accent),
            title: Text(s.label),
            subtitle: Text(
                '${s.url}${s.user.isEmpty ? '' : '  ·  ${s.user}'}${s.insecure ? '  ·  ${tr('인증서 확인 안 함')}' : ''}'
                '${isPlainHttp(s.url) ? '  ·  ⚠ ${tr('암호화 안 됨 (http)')}' : ''}',
                maxLines: 1, overflow: TextOverflow.ellipsis),
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              IconButton(
                tooltip: tr('고치기'),
                icon: const Icon(Icons.edit_outlined, size: 18),
                onPressed: () => editDavServer(context, c, old: s),
              ),
              IconButton(
                tooltip: tr('지우기'),
                icon: const Icon(Icons.delete_outline, size: 18, color: JjColors.textDim),
                // 46: 확인 뒤 (저장된 비밀번호도 함께 지워진다)
                onPressed: () async {
                  // 124: 이 서버를 쓰는 실시간 동기화 쌍 · 기억된 작업을 먼저 알린다
                  final users = davServerUsers(c.settings, s.id);
                  final ok = await confirmAction(
                    context,
                    title: trf('WebDAV 서버 "{0}" 을(를) 지울까요?', [s.label]),
                    body: tr('서버 설정과 이 기기에 저장된 비밀번호를 지웁니다. 서버의 파일은 그대로입니다. '
                            '이 서버를 쓰는 동기화 · 복사는 다시 넣을 때까지 연결되지 않습니다.') +
                        (users.isEmpty
                            ? ''
                            : '\n\n${trf('이 서버를 쓰는 것 {0}개 (지워도 목록에는 남고, 실행하면 서버가 없다고 알립니다):', [users.length])}\n'
                                '${users.take(8).map((u) => '• $u').join('\n')}${users.length > 8 ? '\n…' : ''}'),
                    ok: tr('지우기'),
                  );
                  if (ok) await c.updateSettings((x) => x.webdavServers = [for (final y in x.webdavServers) if (y.id != s.id) y]);
                },
              ),
            ]),
          ),
        ),
    ]);
  }
}

/// 56: 암호화하지 않는 http:// 주소인지
bool isPlainHttp(String url) => url.trim().toLowerCase().startsWith('http://');

/// 124: 서버 [id] 를 쓰는 실시간 동기화 쌍 · 기억된 작업 (모니터링) 의 설명
List<String> davServerUsers(AppSettings s, String id) {
  bool on(String path) => isDav(path) && DavPath.parse(path).server == id;
  return [
    for (final x in s.liveSyncPairs)
      if (on(x.source) || on(x.target)) trf('실시간 동기화: {0} → {1}', [vDisplay(x.source), vDisplay(x.target)]),
    for (final t in s.copyTasks)
      if (on(t.dest) || t.sources.any(on)) trf('기억된 작업: {0} → {1}', [t.sources.map(vDisplay).join(', '), vDisplay(t.dest)]),
  ];
}

/// WebDAV 서버 추가 · 고치기 창. 저장한 서버를 돌려준다 (취소면 null).
Future<DavServer?> editDavServer(BuildContext context, AppController c, {DavServer? old}) async {
  // 127: 저장된 비밀번호가 칸에 채워지므로 (눈 버튼으로 보임) 먼저 마스터 비밀번호 (정해 두었으면)
  if (old != null && old.password.isNotEmpty && !await SecretGate.pass(force: true)) return null;
  if (!context.mounted) return null;
  final name = TextEditingController(text: old?.name ?? '');
  final url = TextEditingController(text: old?.url ?? 'https://');
  final user = TextEditingController(text: old?.user ?? '');
  final pass = TextEditingController(text: old?.password ?? '');
  var insecure = old?.insecure ?? false;
  var hide = true;
  String? result; // 연결 확인 결과
  var toHttps = false; // 서버가 https 로 옮기라고 함 → [https 로 바꾸기]
  var passed = false;
  var testing = false;

  DavServer current() => DavServer(
        id: old?.id ?? 'dav${DateTime.now().microsecondsSinceEpoch}',
        name: name.text.trim(),
        url: url.text.trim(),
        user: user.text.trim(),
        password: pass.text,
        insecure: insecure,
      );

  final saved = await showDialog<DavServer>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, set) {
        Future<void> test() async {
          set(() {
            testing = true;
            result = null;
            toHttps = false;
          });
          final client = DavClient(current());
          try {
            final items = await client.list('/');
            final (free, _) = await client.quota();
            passed = true;
            result = trf('연결됨: 항목 {0}개{1}', [items.length, free == null ? '' : ' · ${tr('남은 용량')} ${(free / (1 << 30)).toStringAsFixed(1)}GB']);
          } catch (e) {
            passed = false;
            toHttps = e is DavException && e.wantsHttps;
            final s = '$e'.toLowerCase();
            result = pass.text.isEmpty && (s.contains('401') || s.contains('아이디 · 비밀번호'))
                ? tr('저장된 비밀번호가 없습니다. 한 번만 다시 넣어 주세요')
                : trf('연결 실패: {0}', [e]);
          } finally {
            client.close();
          }
          if (ctx.mounted) set(() => testing = false);
        }

        final ok = Uri.tryParse(url.text.trim())?.hasAuthority ?? false;
        return AlertDialog(
        scrollable: true,
          title: Text(old == null ? tr('WebDAV 서버 추가') : tr('WebDAV 서버 고치기')),
          content: SizedBox(
            width: 520,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(controller: name, decoration: InputDecoration(labelText: tr('이름 (탭에 보임, 비우면 주소)'))),
              TextField(
                controller: url,
                keyboardType: TextInputType.url,
                decoration: InputDecoration(
                  labelText: tr('주소'),
                  helperText: tr('예: https://nas.local:5006/home · https://cloud.example.com/remote.php/dav/files/아이디'),
                ),
                onChanged: (_) => set(() {}),
              ),
              // 56: http:// 는 아이디 · 비밀번호와 파일이 암호화되지 않고 그대로 간다
              if (isPlainHttp(url.text))
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const Icon(Icons.warning_amber_rounded, size: 18, color: Colors.orangeAccent),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                          tr('http:// 주소는 아이디 · 비밀번호와 파일이 암호화되지 않고 그대로 갑니다. 같은 네트워크의 다른 사람이 볼 수 있으니 '
                              '서버가 https 를 지원하면 https:// 로 바꾸세요.'),
                          style: const TextStyle(fontSize: 12, color: Colors.orangeAccent)),
                    ),
                  ]),
                ),
              TextField(controller: user, decoration: InputDecoration(labelText: tr('아이디'))),
              TextField(
                controller: pass,
                obscureText: hide,
                decoration: InputDecoration(
                  labelText: tr('비밀번호'),
                  suffixIcon: IconButton(
                    icon: Icon(hide ? Icons.visibility_outlined : Icons.visibility_off_outlined, size: 18),
                    onPressed: () => set(() => hide = !hide),
                  ),
                ),
              ),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: insecure,
                onChanged: (v) => set(() => insecure = v ?? false),
                title: Text(tr('인증서 확인 안 함')),
                subtitle: Text(tr('자체 서명 인증서를 쓰는 집 NAS 등 (믿을 수 있는 서버에서만)')),
              ),
              if (testing) const LinearProgressIndicator(),
              if (result != null)
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(result!,
                      style: TextStyle(fontSize: 12, color: passed ? Colors.greenAccent : Colors.redAccent)),
                ),
              if (toHttps)
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    icon: const Icon(Icons.lock_outline, size: 16),
                    label: Text(tr('주소를 https 로 바꾸고 다시 확인')),
                    onPressed: () {
                      url.text = url.text.trim().replaceFirst(RegExp('^http://', caseSensitive: false), 'https://');
                      set(() => toHttps = false);
                      test();
                    },
                  ),
                ),
            ]),
          ),
          actions: [
            TextButton(onPressed: !ok || testing ? null : test, child: Text(tr('연결 확인'))),
            TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('취소'))),
            FilledButton(onPressed: ok ? () => Navigator.pop(ctx, current()) : null, child: Text(tr('저장'))),
          ],
        );
      },
    ),
  );
  if (saved == null) return null;
  await c.updateSettings((x) => x.webdavServers = [
        for (final y in x.webdavServers) y.id == saved.id ? saved : y,
        if (!x.webdavServers.any((y) => y.id == saved.id)) saved,
      ]);
  return saved;
}
