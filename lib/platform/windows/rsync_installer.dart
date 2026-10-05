import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../core/sync_tools.dart';

/// Windows 용 rsync: 처음 쓸 때 MSYS2 공식 저장소에서 패키지를 받아 (SHA256 고정 검증)
/// 설정 폴더의 rsync\ 에 rsync.exe 와 필요한 DLL 만 풀어 둔다 (앱 업데이트로 지워지지 않게).
class RsyncInstaller {
  /// 시험용으로 바꿀 수 있는 설치 폴더
  static String? dirOverride;

  static Future<String> dir() async =>
      dirOverride ?? p.join((await getApplicationSupportDirectory()).path, 'rsync');

  static Future<String?> installedPath() async {
    final f = File(p.join(await dir(), 'rsync.exe'));
    return await f.exists() ? f.path : null;
  }

  /// 내려받기 · 검증 · 풀기. [onProgress] 0~1. 설치된 rsync.exe 경로를 돌려준다.
  static Future<String> install({void Function(double progress, String file)? onProgress}) async {
    final target = await dir();
    final work = Directory(p.join(Directory.systemTemp.path, 'jj_rsync_${DateTime.now().millisecondsSinceEpoch}'));
    await work.create(recursive: true);
    final http = HttpClient()..userAgent = 'JJ_MKVMaker';
    try {
      final total = msys2RsyncPackages.length;
      for (var i = 0; i < total; i++) {
        final (name, sha) = msys2RsyncPackages[i];
        onProgress?.call(i / total, name);
        final f = File(p.join(work.path, name));
        final req = await http.getUrl(Uri.parse('$msys2Repo$name'));
        final res = await req.close();
        if (res.statusCode != 200) throw HttpException('$name 을(를) 받지 못했습니다 (${res.statusCode})');
        await res.pipe(f.openWrite());
        final got = (await sha256.bind(f.openRead()).first).toString();
        if (got != sha) throw StateError('$name 의 SHA256 이 다릅니다 (손상되었거나 다른 파일). 설치를 멈췄습니다.');
        final t = await Process.run('tar', ['-xf', f.path, '-C', work.path, 'usr/bin']);
        if (t.exitCode != 0) throw ProcessException('tar', [f.path], '${t.stderr}', t.exitCode);
      }
      final bin = Directory(p.join(work.path, 'usr', 'bin'));
      await Directory(target).create(recursive: true);
      for (final n in msys2RsyncFiles) {
        final src = File(p.join(bin.path, n));
        if (!await src.exists()) throw StateError('패키지에 $n 이 없습니다');
        await src.copy(p.join(target, n));
      }
      final exe = p.join(target, 'rsync.exe');
      final v = await Process.run(exe, ['--version']);
      if (v.exitCode != 0) throw ProcessException(exe, ['--version'], '${v.stderr}', v.exitCode);
      onProgress?.call(1, '');
      return exe;
    } finally {
      http.close(force: true);
      try {
        await work.delete(recursive: true);
      } catch (_) {}
    }
  }

  /// 내려받은 rsync 지우기
  static Future<void> uninstall() async {
    final d = Directory(await dir());
    if (await d.exists()) await d.delete(recursive: true);
  }
}
