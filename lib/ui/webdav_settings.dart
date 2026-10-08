import 'package:flutter/material.dart';

import '../app/app_controller.dart';
import '../core/webdav.dart';
import '../l10n/tr.dart';
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
            '(위쪽 "SD 카드" 옆 탭). 비밀번호는 이 기기의 설정 파일에만 저장합니다.')),
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
            subtitle: Text('${s.url}${s.user.isEmpty ? '' : '  ·  ${s.user}'}${s.insecure ? '  ·  ${tr('인증서 확인 안 함')}' : ''}',
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
                onPressed: () => c.updateSettings((x) => x.webdavServers = [for (final y in x.webdavServers) if (y.id != s.id) y]),
              ),
            ]),
          ),
        ),
    ]);
  }
}

/// WebDAV 서버 추가 · 고치기 창. 저장한 서버를 돌려준다 (취소면 null).
Future<DavServer?> editDavServer(BuildContext context, AppController c, {DavServer? old}) async {
  final name = TextEditingController(text: old?.name ?? '');
  final url = TextEditingController(text: old?.url ?? 'https://');
  final user = TextEditingController(text: old?.user ?? '');
  final pass = TextEditingController(text: old?.password ?? '');
  var insecure = old?.insecure ?? false;
  var hide = true;
  String? result; // 연결 확인 결과
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
          });
          final client = DavClient(current());
          try {
            final items = await client.list('/');
            final (free, _) = await client.quota();
            passed = true;
            result = trf('연결됨: 항목 {0}개{1}', [items.length, free == null ? '' : ' · ${tr('남은 용량')} ${(free / (1 << 30)).toStringAsFixed(1)}GB']);
          } catch (e) {
            passed = false;
            result = trf('연결 실패: {0}', [e]);
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
