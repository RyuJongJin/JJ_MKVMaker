import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jj_mkvmaker/app/app_controller.dart';
import 'package:jj_mkvmaker/app/download_manager.dart';
import 'package:jj_mkvmaker/app/settings.dart';
import 'package:jj_mkvmaker/core/download_detect.dart';
import 'package:jj_mkvmaker/platform/windows/desktop_storage_service.dart';
import 'package:jj_mkvmaker/platform/windows/process_media_tool.dart';
import 'package:jj_mkvmaker/platform/windows/session_marker.dart';
import 'package:jj_mkvmaker/services/downloader.dart';
import 'package:jj_mkvmaker/services/platform_services.dart';
import 'package:path/path.dart' as p;

class _Backend implements DownloadBackend {
  void Function()? changed;
  @override
  DownloadKind get kind => DownloadKind.video;
  @override
  Future<(String, List<PlaylistEntry>)?> expandPlaylist(String url) async => null;
  @override
  Future<void> start(DownloadTask t, void Function() changed) async {
    this.changed = changed;
    t.state = DownloadState.downloading;
    changed();
  }

  @override
  Future<void> pause(DownloadTask t) async {}
  @override
  Future<void> cancel(DownloadTask t) async {}
  @override
  Future<void> shutdown() async {}
}

void main() {
  test('지난 실행: 정상 종료면 조용히, "실행 중" 으로 남아 있으면 비정상 종료로 알린다', () {
    final dir = Directory.systemTemp.createTempSync('jj_session_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = p.join(dir.path, 'session.json');

    expect(SessionMarker(file).start(), isNull); // 처음
    // 그대로 끝남 (markClean 없이) → 다음에 켤 때 알림
    final crashed = SessionMarker(file).start();
    expect(crashed, isNotNull);
    expect(crashed!.$2.isAfter(crashed.$1) || crashed.$2 == crashed.$1, isTrue);

    final s = SessionMarker(file);
    s.start();
    s.markClean(); // 종료 버튼으로 끝남
    expect(SessionMarker(file).start(), isNull);
  });

  test('작업 기록 파일: 날짜 · 시각과 함께 남고, 2MB 가 넘으면 app.log.1 로 넘긴다', () {
    final dir = Directory.systemTemp.createTempSync('jj_applog_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = p.join(dir.path, 'app.log');
    final c = AppController(PlatformServices(mediaTool: ProcessMediaTool('x', 'y'), storage: DesktopStorageService()))
      ..logFile = file;
    c.note('첫 줄');
    c.note('둘째 줄');
    final lines = File(file).readAsLinesSync();
    expect(lines, hasLength(2));
    expect(lines.first, matches(RegExp(r'^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d  첫 줄$')));

    File(file).writeAsStringSync('x' * (2 * 1024 * 1024 + 10));
    c.note('새 파일');
    expect(File('$file.1').existsSync(), isTrue);
    expect(File(file).readAsLinesSync().single, endsWith('새 파일'));
  });

  test('다운로드 시작 · 완료 · 실패를 작업 기록에 남긴다', () async {
    final b = _Backend();
    final d = DownloadManager(backends: [b], settings: () => AppSettings(), readClipboard: () async => null);
    final logged = <String>[];
    d.log = logged.add;
    final t = d.addPage('https://vimeo.com/1')!..title = '영상';
    await Future<void>.delayed(Duration.zero);
    t
      ..state = DownloadState.done
      ..totalBytes = 5 << 20;
    b.changed!();
    final t2 = d.addPage('https://vimeo.com/2')!..title = '두 번째';
    await Future<void>.delayed(Duration.zero);
    t2
      ..state = DownloadState.failed
      ..error = '볼 수 없는 영상입니다';
    b.changed!();
    expect(logged, [
      '다운로드 시작: https://vimeo.com/1', // 시작할 때는 아직 제목을 모름
      '다운로드 완료: 영상 (https://vimeo.com/1) (5.0MB)',
      '다운로드 시작: https://vimeo.com/2',
      '다운로드 실패: 두 번째 (https://vimeo.com/2) - 볼 수 없는 영상입니다',
    ]);
    d.dispose();
  });
}
