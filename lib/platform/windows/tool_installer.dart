import 'dart:convert';
import 'dart:io';
import '../../l10n/tr.dart';

import 'package:path/path.dart' as p;

/// 필수 프로그램
class RequiredTool {
  final String name;
  final String purpose;

  /// 프로그램 폴더 기준 설치 위치
  final String relPath;

  /// 대략적인 받는 크기 (MB)
  final int sizeMb;

  const RequiredTool(this.name, this.purpose, this.relPath, this.sizeMb);
}

final requiredTools = [
  RequiredTool('FFmpeg', tr('MKV 만들기 · 인코딩 · 음성 추출'), r'ffmpeg\ffmpeg.exe', 100),
  RequiredTool('yt-dlp', tr('YouTube 다운로드'), r'tools\yt-dlp.exe', 17),
  RequiredTool('aria2', tr('토렌트 · 마그넷 다운로드'), r'tools\aria2c.exe', 3),
  RequiredTool('Deno', tr('yt-dlp 의 YouTube 화질 목록 추출'), r'tools\deno.exe', 41),
];

/// 처음 실행 시 없는 필수 프로그램을 찾아 내려받는다 (공식 배포처에서 다운로드만).
class ToolInstaller {
  final String appDir;
  final HttpClient _http = HttpClient()..userAgent = 'JJMKVMaker';

  ToolInstaller([String? appDir]) : appDir = appDir ?? p.dirname(Platform.resolvedExecutable);

  /// 프로그램 폴더에 없고 PATH 에서도 찾을 수 없는 것
  Future<List<RequiredTool>> missing() async {
    final out = <RequiredTool>[];
    for (final t in requiredTools) {
      if (File(p.join(appDir, t.relPath)).existsSync()) continue;
      final exe = p.basename(t.relPath);
      final where = await Process.run('where', [exe]);
      if (where.exitCode == 0) continue;
      out.add(t);
    }
    return out;
  }

  Future<String> _latestAsset(String repo, RegExp pattern) async {
    final req = await _http.getUrl(Uri.parse('https://api.github.com/repos/$repo/releases/latest'));
    req.headers.set('Accept', 'application/vnd.github+json');
    final res = await req.close();
    final json = jsonDecode(await res.transform(utf8.decoder).join()) as Map;
    for (final a in (json['assets'] as List)) {
      if (pattern.hasMatch(a['name'] as String)) return a['browser_download_url'] as String;
    }
    throw HttpException(trf('{0} 에서 받을 파일을 찾지 못했습니다', [repo]));
  }

  Future<void> _download(String url, String target, void Function(int got, int total) onBytes) async {
    final req = await _http.getUrl(Uri.parse(url));
    final res = await req.close();
    if (res.statusCode != 200) throw HttpException(trf('내려받기 실패 ({0}): {1}', [res.statusCode, url]));
    await Directory(p.dirname(target)).create(recursive: true);
    final part = File('$target.part');
    final sink = part.openWrite();
    var got = 0;
    await for (final c in res) {
      sink.add(c);
      got += c.length;
      onBytes(got, res.contentLength);
    }
    await sink.close();
    if (await File(target).exists()) await File(target).delete();
    await part.rename(target);
  }

  /// zip 을 풀어 [names] 파일을 [destDir] 로 복사 (Windows 내장 tar 사용)
  Future<void> _extract(String zip, String destDir, Map<String, String> names) async {
    final tmp = await Directory.systemTemp.createTemp('jj_tool_');
    try {
      final r = await Process.run('tar', ['-xf', zip, '-C', tmp.path]);
      if (r.exitCode != 0) throw ProcessException('tar', [zip], '${r.stderr}', r.exitCode);
      await Directory(destDir).create(recursive: true);
      final all = await tmp.list(recursive: true).where((e) => e is File).toList();
      for (final e in names.entries) {
        final f = all.firstWhere((x) => p.basename(x.path).toLowerCase() == e.key.toLowerCase(),
            orElse: () => throw FileSystemException(tr('압축 파일 안에 없습니다'), e.key));
        await File(f.path).copy(p.join(destDir, e.value));
      }
    } finally {
      await tmp.delete(recursive: true);
      await File(zip).delete().catchError((_) => File(zip));
    }
  }

  /// [tools] 설치. [onProgress] (지금 받는 프로그램 이름, 0~1)
  Future<void> install(List<RequiredTool> tools, void Function(String, double) onProgress) async {
    for (final t in tools) {
      void prog(int got, int total) =>
          onProgress(t.name, total > 0 ? got / total : (got / (t.sizeMb * 1e6)).clamp(0, 0.99));
      final tmp = p.join(Directory.systemTemp.path, 'jj_${t.name}.download');
      switch (t.name) {
        case 'FFmpeg':
          await _download('https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip', tmp, prog);
          await _extract(tmp, p.join(appDir, 'ffmpeg'),
              {'ffmpeg.exe': 'ffmpeg.exe', 'LICENSE': 'FFMPEG_LICENSE.txt'});
        case 'yt-dlp':
          await _download(await _latestAsset('yt-dlp/yt-dlp', RegExp(r'^yt-dlp\.exe$')),
              p.join(appDir, 'tools', 'yt-dlp.exe'), prog);
        case 'aria2':
          await _download(await _latestAsset('aria2/aria2', RegExp(r'win-64bit.*\.zip$')), tmp, prog);
          await _extract(tmp, p.join(appDir, 'tools'),
              {'aria2c.exe': 'aria2c.exe', 'COPYING': 'ARIA2_COPYING.txt'});
        case 'Deno':
          await _download(
              await _latestAsset('denoland/deno', RegExp(r'^deno-x86_64-pc-windows-msvc\.zip$')), tmp, prog);
          await _extract(tmp, p.join(appDir, 'tools'), {'deno.exe': 'deno.exe'});
      }
      onProgress(t.name, 1);
    }
  }
}
