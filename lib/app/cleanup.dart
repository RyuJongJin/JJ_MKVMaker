import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../l10n/tr.dart';
import 'app_controller.dart';
import 'download_manager.dart';

/// 정리할 파일 · 폴더 하나
class CleanupItem {
  final String path;
  final int bytes;
  final bool isDir;
  const CleanupItem(this.path, this.bytes, {this.isDir = false});
}

/// 정리 묶음 (작업 임시 파일 · 받다 만 다운로드 …)
class CleanupGroup {
  final String id;
  final String title;
  final String hint;
  final List<CleanupItem> items;

  /// 작업 중이라 이번에는 건너뛰는 이유 (있으면 지우지 않음)
  final String? skipped;
  CleanupGroup(this.id, this.title, this.hint, this.items, {this.skipped});

  int get bytes => items.fold(0, (a, i) => a + i.bytes);
}

/// 저장 공간 정리 (환경 설정 > 저장 공간 정리): 작업하다 남은 임시 파일 · 받다 만 다운로드 조각 (.part 등) ·
/// 받다 만 AI 모델 · 업데이트 · 설치하고 남은 파일 · 지난 작업 기록을 찾아 지운다.
/// 진행 중인 작업 · 다운로드가 쓰는 곳은 건너뛴다 (이어받기 · 작업이 깨지지 않게).
class Cleaner {
  final AppController c;
  final DownloadManager? downloads;

  /// 앱 설정 폴더 (테스트에서 바꿔 끼움)
  final String? dataDir;

  /// 시스템 임시 폴더 (Windows 의 업데이트 · 도구 설치 남은 파일. 테스트에서 바꿔 끼움)
  final String? systemTemp;

  Cleaner(this.c, {this.downloads, this.dataDir, this.systemTemp});

  /// 받다 만 다운로드 조각: yt-dlp (.part · .ytdl · .part-Frag · .temp. · 합치기 전 영상.f137.mp4) · aria2 (.aria2)
  static final downloadLeftover =
      RegExp(r'\.part$|\.part-frag\d+|\.ytdl$|\.temp\.|\.f\d+\.[a-z0-9]+$|\.aria2$', caseSensitive: false);

  static int _size(FileSystemEntity e) {
    try {
      if (e is File) return e.lengthSync();
      if (e is Directory) {
        var n = 0;
        for (final f in e.listSync(recursive: true, followLinks: false)) {
          if (f is File) n += f.lengthSync();
        }
        return n;
      }
    } catch (_) {}
    return 0;
  }

  static List<FileSystemEntity> _list(String dir, {bool recursive = false}) {
    try {
      final d = Directory(dir);
      if (!d.existsSync()) return const [];
      return d.listSync(recursive: recursive, followLinks: false);
    } catch (_) {
      return const [];
    }
  }

  CleanupItem _item(FileSystemEntity e) => CleanupItem(e.path, _size(e), isDir: e is Directory);

  /// 정리할 것 찾기
  Future<List<CleanupGroup>> scan() async {
    final working = c.busy;
    final downloading = (downloads?.activeCount ?? 0) > 0;
    final data = dataDir ?? (await getApplicationSupportDirectory()).path;
    final groups = <CleanupGroup>[];

    // 1. 작업 임시 파일: 앱 임시 폴더 전체 + 설정 파일을 저장하다 남은 이름.12345.tmp
    final tmpDir = await c.services.storage.tempDirectory();
    groups.add(CleanupGroup(
      'work',
      tr('작업 임시 파일'),
      tr('AI 자막용 음성 (wav) · 자막 변환 사본 · 미리보기 그림 등 작업하다 남은 파일'),
      [
        for (final e in _list(tmpDir)) _item(e),
        for (final e in _list(data))
          if (e is File && RegExp(r'\.\d+\.tmp$').hasMatch(e.path)) _item(e),
      ],
      skipped: working ? tr('MKV 만들기 · AI 자막 작업 중이라 이번에는 건너뜁니다') : null,
    ));

    // 2. 받다 만 다운로드 조각
    final s = c.settings;
    groups.add(CleanupGroup(
      'download',
      tr('받다 만 다운로드'),
      tr('취소 · 실패한 다운로드가 남긴 .part · .ytdl · .aria2 · 합치기 전 조각 파일 (jj_yt-dlp · jj_aria2)'),
      [
        for (final dir in {s.ytDlpDir, s.aria2Dir})
          for (final e in _list(dir, recursive: true))
            if (e is File && downloadLeftover.hasMatch(p.basename(e.path))) _item(e),
      ],
      skipped: downloading ? tr('받는 중이거나 일시정지한 다운로드가 있어 건너뜁니다 (이어받기가 깨지지 않게)') : null,
    ));

    // 3. 받다 만 AI 모델 (.part) · 모델 변환하다 남은 .tmp
    final models = await c.services.models.directory();
    groups.add(CleanupGroup(
      'models',
      tr('받다 만 AI 모델'),
      tr('내려받다 끊긴 모델 (.part) · 변환하다 남은 파일 (.tmp)'),
      [
        for (final e in _list(models, recursive: true))
          if (e is File && (e.path.endsWith('.part') || e.path.endsWith('.tmp'))) _item(e),
      ],
      skipped: working ? tr('AI 작업 중이라 이번에는 건너뜁니다') : null,
    ));

    // 4. 업데이트 · 도구 설치하고 남은 파일 (Windows 임시 폴더)
    final sysTmp = systemTemp ?? (Platform.isWindows ? Directory.systemTemp.path : null);
    if (sysTmp != null) {
      final mine = RegExp(r'^(jj_mkvmaker_update|jj_cef_|jj_tool_|jj_[\w.-]+\.download$|jj_mkvmaker_update\.(ps1|log)$)');
      groups.add(CleanupGroup(
        'update',
        tr('업데이트 · 설치하고 남은 파일'),
        tr('받은 업데이트 · 필수 프로그램 · Chrome 엔진을 설치하고 남은 임시 파일'),
        [
          for (final e in _list(sysTmp))
            if (mine.hasMatch(p.basename(e.path))) _item(e),
        ],
      ));
    }

    // 5. 지난 작업 기록 (지금 쓰는 app.log 는 남김)
    final log = c.logFile;
    if (log != null) {
      groups.add(CleanupGroup(
        'logs',
        tr('지난 작업 기록'),
        tr('오래된 작업 기록 파일 (app.log.1 등). 지금 쓰는 기록은 남깁니다'),
        [
          for (final e in _list(p.dirname(log)))
            if (e is File && !p.equals(e.path, log)) _item(e),
        ],
      ));
    }
    return groups;
  }

  /// 고른 묶음 지우기 (건너뛴 묶음은 지우지 않음). (지운 개수, 비운 용량)
  Future<(int, int)> clean(Iterable<CleanupGroup> groups) async {
    var n = 0, bytes = 0;
    for (final g in groups) {
      if (g.skipped != null) continue;
      for (final i in g.items) {
        try {
          if (i.isDir) {
            await Directory(i.path).delete(recursive: true);
          } else {
            await File(i.path).delete();
          }
          n++;
          bytes += i.bytes;
        } catch (_) {
          // 쓰는 중이거나 지울 수 없는 파일은 그대로
        }
      }
    }
    return (n, bytes);
  }

  /// "12.3 MB" · "850 KB"
  static String sizeText(int bytes) {
    if (bytes >= 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
    if (bytes >= 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    if (bytes >= 1024) return '${(bytes / 1024).round()} KB';
    return '$bytes B';
  }
}
