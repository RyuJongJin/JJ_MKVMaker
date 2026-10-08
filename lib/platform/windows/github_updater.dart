import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;

import 'app_paths.dart';

import '../../core/app_update.dart';
import '../../services/updater.dart';
import '../../l10n/tr.dart';

/// GitHub Release 로 업데이트 (Windows)
///
/// 1. releases/latest 조회 → 2. zip 받기 · SHA256 확인 · 압축 풀기
/// 3. 업데이트 스크립트 예약: 앱이 끝나면 파일 교체 (받은 파일 · 모델 · 설정은 그대로) → 새 버전 실행
class GitHubUpdater implements Updater {
  final String apiBase;
  final String appDir;
  final String? versionOverride;
  final HttpClient _http = HttpClient()
    ..userAgent = 'JJ_MKVMaker-updater'
    ..connectionTimeout = const Duration(seconds: 20);

  GitHubUpdater({
    this.apiBase = 'https://api.github.com',
    String? appDir,
    this.versionOverride,
  }) : appDir = appDir ?? AppPaths.root; // Lib 구조면 배포 폴더 맨 위

  @override
  bool get installsInPlace => false;

  @override
  Future<String> currentVersion() async {
    if (versionOverride != null) return versionOverride!;
    // pubspec 의 "2026.9.30+1" → "2026.09.30_001"
    final info = await PackageInfo.fromPlatform();
    return formatVersion('${info.version}+${info.buildNumber}');
  }

  @override
  Future<ReleaseInfo?> latest() async {
    final req = await _http.getUrl(Uri.parse('$apiBase/repos/$updateRepo/releases/latest'));
    req.headers.set('Accept', 'application/vnd.github+json');
    final res = await req.close();
    final body = await res.transform(utf8.decoder).join();
    if (res.statusCode == 404) return null;
    if (res.statusCode != 200) {
      throw UpdateException(trf('최신 버전을 확인할 수 없습니다 ({0})', [res.statusCode]));
    }
    return parseLatestRelease(jsonDecode(body) as Map<String, dynamic>);
  }

  @override
  Future<List<ReleaseInfo>> releases() async {
    final req = await _http.getUrl(Uri.parse('$apiBase/repos/$updateRepo/releases?per_page=100'));
    req.headers.set('Accept', 'application/vnd.github+json');
    final res = await req.close();
    final body = await res.transform(utf8.decoder).join();
    if (res.statusCode != 200) {
      throw UpdateException(trf('버전 목록을 읽을 수 없습니다 ({0})', [res.statusCode]));
    }
    return parseReleaseList(jsonDecode(body) as List<dynamic>);
  }

  @override
  Future<bool> canInstall() async {
    try {
      final probe = File(p.join(appDir, '.jj_update_test'));
      await probe.writeAsString('x');
      await probe.delete();
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<String> download(ReleaseInfo r, void Function(double progress) onProgress) async {
    final url = r.zipUrl;
    if (url == null) throw UpdateException(tr('이 버전에는 Windows 용 zip 이 없습니다.'));
    final work = Directory(p.join(Directory.systemTemp.path, 'jj_mkvmaker_update_${r.version}'));
    if (await work.exists()) await work.delete(recursive: true);
    await work.create(recursive: true);
    final zip = File(p.join(work.path, r.zipName ?? 'update.zip'));

    // 받기
    final req = await _http.getUrl(Uri.parse(url));
    final res = await req.close();
    if (res.statusCode != 200) throw UpdateException(trf('내려받기 실패 ({0})', [res.statusCode]));
    final total = res.contentLength > 0 ? res.contentLength : r.zipSize;
    final sink = zip.openWrite();
    var got = 0;
    await for (final chunk in res) {
      sink.add(chunk);
      got += chunk.length;
      if (total > 0) onProgress((got / total).clamp(0.0, 0.99));
    }
    await sink.close();

    // 검증: GitHub 가 알려 준 SHA256 과 비교
    if (r.sha256 != null) {
      final hash = (await sha256.bind(zip.openRead()).first).toString();
      if (hash != r.sha256) {
        await work.delete(recursive: true);
        throw UpdateException(tr('받은 파일이 손상되었거나 다른 파일입니다 (SHA256 불일치). 설치를 중단했습니다.'));
      }
    }

    // 압축 풀기 (Windows 내장 tar)
    final out = Directory(p.join(work.path, 'extract'));
    await out.create();
    final t = await Process.run('tar', ['-xf', zip.path, '-C', out.path]);
    if (t.exitCode != 0) throw UpdateException(trf('압축을 풀 수 없습니다: {0}', [t.stderr]));
    await zip.delete();
    final exeName = p.basename(Platform.resolvedExecutable).toLowerCase();
    // 배포 폴더 맨 위 = 가장 얕은 곳의 jj_mkvmaker.exe (Lib 구조면 시작 프로그램, 예전 구조면 프로그램 자신)
    final exes = await out
        .list(recursive: true)
        .where((e) => e is File && {'jj_mkvmaker.exe', exeName}.contains(p.basename(e.path).toLowerCase()))
        .map((e) => e.path)
        .toList();
    if (exes.isEmpty) throw UpdateException(tr('압축 파일 안에 프로그램이 없습니다.'));
    exes.sort((a, b) => p.split(a).length.compareTo(p.split(b).length));
    onProgress(1);
    return p.dirname(exes.first);
  }

  /// 파일 교체 스크립트 (영문만: Windows PowerShell 5.1 이 BOM 없는 UTF-8 을 잘못 읽는 문제 방지)
  static const script = r'''
param([int]$ParentPid, [string]$Source, [string]$Target, [string]$Exe, [switch]$NoRestart)
$ErrorActionPreference = 'Continue'
try { Wait-Process -Id $ParentPid -Timeout 90 -ErrorAction Stop } catch {}
Start-Sleep -Milliseconds 800
$log = Join-Path $env:TEMP 'jj_mkvmaker_update.log'
# keep downloads, models and user data
$lib = Join-Path $Source 'Lib'
if (Test-Path $lib) {
  # Lib layout: make the program folder exactly this version (also when going back to an older version),
  # then copy the top files (launcher, readme). User folders are excluded (not copied, not deleted).
  robocopy $lib (Join-Path $Target 'Lib') /MIR /R:10 /W:1 /XD jj_yt-dlp jj_aria2 models /NFL /NDL /NP /LOG:$log | Out-Null
  if ($LASTEXITCODE -ge 8) { Start-Process notepad.exe $log; exit 1 }
  robocopy $Source $Target /R:10 /W:1 /XD Lib /NFL /NDL /NP /LOG+:$log | Out-Null
} else {
  # old single-folder layout: copy over
  robocopy $Source $Target /E /R:10 /W:1 /XD jj_yt-dlp jj_aria2 models /NFL /NDL /NP /LOG:$log | Out-Null
}
if ($LASTEXITCODE -ge 8) { Start-Process notepad.exe $log; exit 1 }
if (-not $NoRestart) { Start-Process -FilePath $Exe }
exit 0
''';

  /// 스크립트 실행. [waitPid] 가 끝나기를 기다렸다가 교체한다.
  Future<Process> runInstallScript(String source, {required int waitPid, bool restart = true}) async {
    final ps1 = File(p.join(Directory.systemTemp.path, 'jj_mkvmaker_update.ps1'));
    await ps1.writeAsString(script);
    return Process.start(
      'powershell.exe',
      [
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', ps1.path,
        '-ParentPid', '$waitPid', '-Source', source, '-Target', appDir,
        '-Exe', p.join(appDir, 'jj_mkvmaker.exe'),
        if (!restart) '-NoRestart',
      ],
      mode: restart ? ProcessStartMode.detached : ProcessStartMode.normal,
    );
  }

  @override
  Future<void> scheduleInstall(String extractedDir) async {
    await runInstallScript(extractedDir, waitPid: pid);
  }

  @override
  Future<void> uninstallSelf() async {}

  @override
  Future<void> openPage(ReleaseInfo r) =>
      Process.start('explorer.exe', [r.pageUrl], mode: ProcessStartMode.detached);
}
