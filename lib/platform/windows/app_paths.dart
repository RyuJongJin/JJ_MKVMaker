import 'dart:io';

import 'package:path/path.dart' as p;

/// 배포 폴더 구조
///
///   JJ_MKVMaker\jj_mkvmaker.exe   시작 프로그램 (Lib\jj_mkvmaker.exe 를 실행)
///   JJ_MKVMaker\LICENSE.txt · README.md
///   JJ_MKVMaker\Lib\              실제 프로그램 · DLL · data · ffmpeg · tools  (← 지금 실행 중인 exe 가 있는 곳)
///   JJ_MKVMaker\Logs\             작업 기록 (app.log · exit.log)
///
/// 예전처럼 한 폴더에 모두 있는 구조 (exe 옆에 Lib 가 없음) 에서도 그대로 동작한다.
class AppPaths {
  /// 지금 실행 중인 exe 가 있는 폴더 (프로그램 파일)
  static String get exeDir => p.dirname(Platform.resolvedExecutable);

  /// 배포 폴더 (맨 위). exe 가 Lib 안에 있으면 그 위 폴더.
  static String get root {
    final dir = exeDir;
    return p.basename(dir).toLowerCase() == 'lib' ? p.dirname(dir) : dir;
  }

  /// Lib 구조로 실행 중인지
  static bool get inLib => root != exeDir;

  /// 작업 기록 폴더: 배포 폴더의 Logs (쓸 수 없으면 [fallback] 아래 Logs)
  static String logsDir(String fallback) {
    for (final dir in [p.join(root, 'Logs'), p.join(fallback, 'Logs')]) {
      try {
        Directory(dir).createSync(recursive: true);
        final probe = File(p.join(dir, '.jj_write_test'))..writeAsStringSync('x');
        probe.deleteSync();
        return dir;
      } catch (_) {}
    }
    return fallback;
  }

  /// 예전 구조 (한 폴더) 에서 Lib 구조로 업데이트한 뒤 배포 폴더 맨 위에 남은 예전 프로그램 파일을 지운다.
  /// 지우는 것: 프로그램이 넣었던 것으로 확인되는 것만 (DLL · data · ffmpeg · tools · 고지 파일).
  /// 받은 동영상 · 모델 · 사용자가 둔 파일은 건드리지 않는다. 지운 이름 목록을 돌려준다.
  static List<String> cleanupOldLayout() {
    if (!inLib) return const [];
    final top = root;
    final removed = <String>[];
    void del(FileSystemEntity e) {
      try {
        e.deleteSync(recursive: true);
        removed.add(p.basename(e.path));
      } catch (_) {}
    }

    // 맨 위의 DLL: Lib 에도 같은 이름이 있는 것만 (= 프로그램 부속품)
    try {
      for (final e in Directory(top).listSync()) {
        final name = p.basename(e.path);
        final lower = name.toLowerCase();
        if (e is File &&
            (lower.endsWith('.dll') || lower == 'third_party_notices.txt' || lower == 'native_assets.json') &&
            File(p.join(exeDir, name)).existsSync()) {
          del(e);
        }
      }
    } catch (_) {}
    // 폴더: 프로그램 것인지 안의 대표 파일로 확인
    for (final (dir, marker) in [('data', 'app.so'), ('ffmpeg', 'ffmpeg.exe'), ('tools', 'yt-dlp.exe')]) {
      final d = Directory(p.join(top, dir));
      if (d.existsSync() && File(p.join(d.path, marker)).existsSync() && Directory(p.join(exeDir, dir)).existsSync()) {
        del(d);
      }
    }
    return removed;
  }
}
