import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'app_paths.dart';

/// 내장 Chrome (CEF) 실행 파일: 환경 설정에서 "내장 Chrome" 을 고른 사람만 내려받는다.
///
/// 공식 배포처의 *Minimal Distribution* 을 받아 `Release\*` (libcef.dll 등) 와 `Resources\*` (pak · locales)
/// 를 `<프로그램 폴더>\cef` 에 푼다. 실행 파일은 시작할 때 이 폴더에 libcef.dll 이 있으면 Chrome 엔진을 준비한다
/// (windows/runner/main.cpp) → 내려받은 뒤에는 프로그램을 다시 시작해야 쓸 수 있다.
class CefRuntime {
  /// packages/webview_cef/third/download.cmake 의 CEF_VERSION 과 같아야 한다 (빌드에 쓴 것과 같은 버전)
  static const version = '149.0.4+g2f1bfd8+chromium-149.0.7827.156';
  static const _cdn = 'https://cef-builds.spotifycdn.com';

  /// 내려받을 크기 (안내용, 실제 크기는 받을 때 서버가 알려 준 값)
  static const approxDownloadMb = 155;

  static String get dir => dirOverride ?? p.join(AppPaths.exeDir, 'cef');

  /// 시험용: 설치 위치 바꾸기
  static String? dirOverride;

  static bool get installed => File(p.join(dir, 'libcef.dll')).existsSync();

  /// 이번 실행이 시작할 때 Chrome 엔진이 있었는지 (실행 파일이 그때 준비했는지).
  /// 실행 중에 내려받은 경우는 false → 다시 시작해야 한다. 시작할 때 [rememberStartState] 로 기록.
  static bool readyThisRun = false;
  static void rememberStartState() => readyThisRun = installed;

  static Uri get downloadUri {
    final name = 'cef_binary_${version}_windows64_minimal.tar.bz2';
    return Uri.parse('$_cdn/${Uri.encodeComponent(name)}');
  }

  /// 내려받아 설치. [onProgress] 는 0~1 (받기 0~0.85, 풀기 0.85~1). [isCancelled] 가 true 면 멈춘다.
  static Future<void> install({
    required void Function(double progress, String stage) onProgress,
    bool Function()? isCancelled,
    HttpClient? client,
  }) async {
    final work = await Directory.systemTemp.createTemp('jj_cef_');
    final http = client ?? (HttpClient()..userAgent = 'JJ_MKVMaker');
    try {
      // 1. 받기
      final archive = File(p.join(work.path, 'cef.tar.bz2'));
      final req = await http.getUrl(downloadUri);
      final res = await req.close();
      if (res.statusCode != 200) throw HttpException('Chrome 엔진을 받을 수 없습니다 (HTTP ${res.statusCode})');
      final total = res.contentLength;
      var got = 0;
      final sink = archive.openWrite();
      try {
        await for (final chunk in res) {
          if (isCancelled?.call() ?? false) throw const _Cancelled();
          sink.add(chunk);
          got += chunk.length;
          if (total > 0) onProgress(0.85 * got / total, '받는 중');
        }
      } finally {
        await sink.close();
      }

      // 2. 풀기 (Windows 기본 tar 가 bzip2 를 푼다)
      onProgress(0.86, '푸는 중');
      final out = Directory(p.join(work.path, 'x'))..createSync();
      final r = await Process.run('tar', ['-xf', archive.path, '-C', out.path]);
      if (r.exitCode != 0) throw ProcessException('tar', [], '압축을 풀 수 없습니다: ${r.stderr}', r.exitCode);
      await archive.delete();
      final root = out.listSync().whereType<Directory>().firstOrNull ?? out;
      final release = Directory(p.join(root.path, 'Release'));
      final resources = Directory(p.join(root.path, 'Resources'));
      if (!File(p.join(release.path, 'libcef.dll')).existsSync()) {
        throw const FileSystemException('받은 파일에 libcef.dll 이 없습니다.');
      }

      // 3. 설치: 새 폴더에 모은 뒤 이름 바꾸기 (중간에 실패해도 반쯤 깔린 폴더가 남지 않게)
      onProgress(0.95, '설치하는 중');
      final staging = Directory('$dir.new');
      if (staging.existsSync()) staging.deleteSync(recursive: true);
      staging.createSync(recursive: true);
      for (final src in [release, resources]) {
        if (!src.existsSync()) continue;
        for (final e in src.listSync(recursive: true)) {
          final rel = p.relative(e.path, from: src.path);
          final lower = e.path.toLowerCase();
          if (lower.endsWith('.lib') || lower.endsWith('.pdb')) continue; // 빌드용 파일
          final to = p.join(staging.path, rel);
          if (e is Directory) {
            Directory(to).createSync(recursive: true);
          } else if (e is File) {
            Directory(p.dirname(to)).createSync(recursive: true);
            e.copySync(to);
          }
        }
      }
      final old = Directory(dir);
      if (old.existsSync()) old.deleteSync(recursive: true);
      staging.renameSync(dir);
      onProgress(1, '완료');
    } on _Cancelled {
      throw const FileSystemException('취소했습니다.');
    } finally {
      if (client == null) http.close(force: true);
      try {
        work.deleteSync(recursive: true);
      } catch (_) {}
    }
  }

  /// 내려받은 Chrome 엔진 지우기 (다시 시작한 뒤에 지울 수 있다 - 쓰는 중에는 잠겨 있음)
  static Future<bool> uninstall() async {
    try {
      final d = Directory(dir);
      if (d.existsSync()) await d.delete(recursive: true);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 설치된 크기 (MB, 안내용)
  static int installedMb() {
    try {
      var n = 0;
      for (final e in Directory(dir).listSync(recursive: true)) {
        if (e is File) n += e.lengthSync();
      }
      return n ~/ (1024 * 1024);
    } catch (_) {
      return 0;
    }
  }
}

class _Cancelled implements Exception {
  const _Cancelled();
}
