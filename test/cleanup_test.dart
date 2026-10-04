import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jj_mkvmaker/app/app_controller.dart';
import 'package:jj_mkvmaker/app/cleanup.dart';
import 'package:jj_mkvmaker/app/download_manager.dart';
import 'package:jj_mkvmaker/core/download_detect.dart';
import 'package:jj_mkvmaker/platform/windows/desktop_storage_service.dart';
import 'package:jj_mkvmaker/platform/windows/process_media_tool.dart';
import 'package:jj_mkvmaker/services/downloader.dart';
import 'package:jj_mkvmaker/services/model_store.dart';
import 'package:jj_mkvmaker/services/platform_services.dart';
import 'package:path/path.dart' as p;

/// 앱 임시 폴더를 시험 폴더로
class _Storage extends DesktopStorageService {
  final String tmp;
  _Storage(this.tmp);
  @override
  Future<String> tempDirectory() async => tmp;
}

class _Backend implements DownloadBackend {
  @override
  DownloadKind get kind => DownloadKind.video;
  @override
  Future<(String, List<PlaylistEntry>)?> expandPlaylist(String url) async => null;
  @override
  Future<void> start(DownloadTask t, void Function() changed) async => t.state = DownloadState.downloading;
  @override
  Future<void> pause(DownloadTask t) async {}
  @override
  Future<void> cancel(DownloadTask t) async {}
  @override
  Future<void> shutdown() async {}
}

void main() {
  late Directory root;
  late AppController c;
  late String tmp, data, models, sysTmp, logs;

  File make(String path, [int size = 100]) => File(path)
    ..parent.createSync(recursive: true)
    ..writeAsBytesSync(List.filled(size, 1));

  setUp(() {
    root = Directory.systemTemp.createTempSync('jj_clean_');
    tmp = p.join(root.path, 'apptmp');
    data = p.join(root.path, 'data');
    models = p.join(root.path, 'models');
    sysTmp = p.join(root.path, 'systemp');
    logs = p.join(data, 'Logs');
    c = AppController(PlatformServices(
      mediaTool: ProcessMediaTool('x', 'y'),
      storage: _Storage(tmp),
      models: ModelStore(models),
    ));
    c.settings.downloadRoot = p.join(root.path, 'dl');
    c.logFile = p.join(logs, 'app.log');

    // 지울 것
    make(p.join(tmp, 'ai_123', 'audio.wav'), 5000);
    make(p.join(tmp, 'jj_adjust_after_1.png'));
    make(p.join(data, 'settings.json.4567.tmp'));
    make(p.join(c.settings.ytDlpDir, '영상 [abc].mp4.part'), 3000);
    make(p.join(c.settings.ytDlpDir, '영상 [abc].f137.mp4'), 2000);
    make(p.join(c.settings.ytDlpDir, '영상 [abc].mp4.ytdl'));
    make(p.join(c.settings.ytDlpDir, '재생목록', '두번째 [def].webm.part-Frag12'));
    make(p.join(c.settings.aria2Dir, 'movie.mkv.aria2'));
    make(p.join(models, 'whisper', 'ggml-small.bin.part'), 4000);
    make(p.join(sysTmp, 'jj_mkvmaker_update_2026.10.04_001', 'JJ_MKVMaker.zip'), 6000);
    make(p.join(sysTmp, 'jj_ffmpeg.download'));
    make(p.join(logs, 'app.log.1'), 700);

    // 남길 것
    make(p.join(c.settings.ytDlpDir, '영상 [abc].mp4'), 9000);
    make(p.join(c.settings.ytDlpDir, 'jj_mkv', '영상 [abc].mkv'));
    make(p.join(c.settings.aria2Dir, 'movie.mkv'));
    make(p.join(models, 'whisper', 'ggml-base.bin'));
    make(p.join(data, 'settings.json'));
    make(p.join(sysTmp, 'other_app.tmp'));
    make(p.join(logs, 'app.log'));
  });
  tearDown(() => root.deleteSync(recursive: true));

  test('찾기: 묶음별로 남은 조각만 찾고, 받은 동영상 · MKV · 모델 · 설정 · 지금 기록은 건드리지 않는다', () async {
    final groups = await Cleaner(c, dataDir: data, systemTemp: sysTmp).scan();
    Map<String, List<String>> names = {
      for (final g in groups) g.id: [for (final i in g.items) p.basename(i.path)]..sort(),
    };
    expect(names['work'], ['ai_123', 'jj_adjust_after_1.png', 'settings.json.4567.tmp']);
    expect(names['download'], [
      'movie.mkv.aria2',
      '두번째 [def].webm.part-Frag12',
      '영상 [abc].f137.mp4',
      '영상 [abc].mp4.part',
      '영상 [abc].mp4.ytdl',
    ]);
    expect(names['models'], ['ggml-small.bin.part']);
    expect(names['update'], ['jj_ffmpeg.download', 'jj_mkvmaker_update_2026.10.04_001']);
    expect(names['logs'], ['app.log.1']);
    expect(groups.firstWhere((g) => g.id == 'work').bytes, 5000 + 100 + 100);
    expect(groups.every((g) => g.skipped == null), isTrue);

    final (n, bytes) = await Cleaner(c, dataDir: data, systemTemp: sysTmp).clean(groups);
    expect(n, 3 + 5 + 1 + 2 + 1);
    expect(bytes, greaterThan(20000));
    // 남길 것은 그대로
    for (final keep in [
      p.join(c.settings.ytDlpDir, '영상 [abc].mp4'),
      p.join(c.settings.ytDlpDir, 'jj_mkv', '영상 [abc].mkv'),
      p.join(c.settings.aria2Dir, 'movie.mkv'),
      p.join(models, 'whisper', 'ggml-base.bin'),
      p.join(data, 'settings.json'),
      p.join(sysTmp, 'other_app.tmp'),
      p.join(logs, 'app.log'),
    ]) {
      expect(File(keep).existsSync(), isTrue, reason: keep);
    }
    // 다시 찾으면 없음
    final again = await Cleaner(c, dataDir: data, systemTemp: sysTmp).scan();
    expect(again.every((g) => g.items.isEmpty), isTrue);
  });

  test('다운로드 중 (일시정지 포함) 이면 받다 만 다운로드는 건너뛴다', () async {
    final d = DownloadManager(backends: [_Backend()], settings: () => c.settings, readClipboard: () async => null);
    addTearDown(d.dispose);
    d.addPage('https://www.youtube.com/watch?v=abc');
    await Future<void>.delayed(Duration.zero);
    expect(d.activeCount, 1);
    final groups = await Cleaner(c, downloads: d, dataDir: data, systemTemp: sysTmp).scan();
    final dl = groups.firstWhere((g) => g.id == 'download');
    expect(dl.skipped, isNotNull);
    await Cleaner(c, downloads: d, dataDir: data, systemTemp: sysTmp).clean(groups);
    expect(File(p.join(c.settings.ytDlpDir, '영상 [abc].mp4.part')).existsSync(), isTrue, reason: '이어받기용 조각은 그대로');
    expect(Directory(p.join(tmp, 'ai_123')).existsSync(), isFalse, reason: '다른 묶음은 정리');
  });

  test('크기 글', () {
    expect(Cleaner.sizeText(512), '512 B');
    expect(Cleaner.sizeText(2048), '2 KB');
    expect(Cleaner.sizeText(5 * 1024 * 1024), '5.0 MB');
    expect(Cleaner.sizeText(3 * 1024 * 1024 * 1024), '3.0 GB');
  });
}
