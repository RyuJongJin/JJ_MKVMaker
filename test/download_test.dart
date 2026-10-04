import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:jj_mkvmaker/app/download_manager.dart';
import 'package:jj_mkvmaker/app/settings.dart';
import 'package:jj_mkvmaker/core/download_detect.dart';
import 'package:jj_mkvmaker/core/encode_options.dart';
import 'package:jj_mkvmaker/platform/windows/aria2_backend.dart';
import 'package:jj_mkvmaker/platform/windows/ytdlp_backend.dart';
import 'package:jj_mkvmaker/services/app_shell.dart';
import 'package:jj_mkvmaker/services/downloader.dart';
import 'package:jj_mkvmaker/ui/downloads_page.dart';
import 'package:path/path.dart' as p;

class _FakeBackend implements DownloadBackend {
  @override
  final DownloadKind kind;
  final started = <String>[];
  _FakeBackend(this.kind);

  /// 재생목록 흉내 (null 이면 재생목록 아님)
  (String, List<PlaylistEntry>)? playlist;

  @override
  Future<(String, List<PlaylistEntry>)?> expandPlaylist(String url) async => playlist;

  @override
  Future<void> start(DownloadTask t, void Function() changed) async {
    started.add(t.source);
    t.state = DownloadState.downloading;
    changed();
  }

  @override
  Future<void> pause(DownloadTask t) async => t.state = DownloadState.paused;
  @override
  Future<void> cancel(DownloadTask t) async => t.state = DownloadState.cancelled;
  @override
  Future<void> shutdown() async {}
}

final _tools = p.join(Directory.current.path, 'third_party', 'tools', 'windows');

void main() {
  group('주소 판별', () {
    test('YouTube · 마그넷 · torrent', () {
      final links = detectLinks('''
보세요 https://www.youtube.com/watch?v=jNQXAC9IVRw&t=3s, 그리고
https://youtu.be/abc123XYZ_-).
magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567&dn=ubuntu
http://example.com/files/linux.iso.torrent?x=1
https://example.com/page.html
중복 https://youtu.be/abc123XYZ_-
''');
      expect(links.map((l) => '${l.kind.name}:${l.url}'), [
        'video:https://www.youtube.com/watch?v=jNQXAC9IVRw&t=3s',
        'video:https://youtu.be/abc123XYZ_-',
        'torrent:magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567&dn=ubuntu',
        'torrent:http://example.com/files/linux.iso.torrent?x=1',
      ]);
      expect(detectLinks('https://www.youtube.com/shorts/xyz789').single.kind, DownloadKind.video);
      expect(detectLinks('그냥 글입니다'), isEmpty);
    });

    test('yt-dlp 진행 줄', () {
      final pr = parseYtDlpProgress('[JJ] 45.3%|  2.10MiB/s|00:12')!;
      expect(pr.percent, closeTo(0.453, 1e-9));
      expect(pr.speed, '2.10MiB/s');
      expect(pr.eta, '00:12');
      expect(parseYtDlpProgress('[JJ]  N/A%|Unknown B/s|NA')!.percent, isNull);
      expect(parseYtDlpProgress('[download] 50%'), isNull);
      final sized = parseYtDlpProgress('[JJ] 50.0%|1.00MiB/s|00:10|5000000|10000000.0')!;
      expect([sized.received, sized.total], [5000000, 10000000]);
      expect(parseYtDlpProgress('[JJ] 50.0%|1.00MiB/s|00:10|5000|NA')!.total, isNull);
    });

    test('영상 + 음성을 따로 받아도 하나의 진행률 · 크기', () {
      YtDlpProgress p(int got, int all) => YtDlpProgress(got / all, '', '', received: got, total: all);
      final t = YtDlpTotals()..expected = 1000; // 영상 900 + 음성 100
      t.update(p(450, 900));
      expect([t.received, t.total, t.progress], [450, 1000, 0.45]);
      t.update(p(900, 900)); // 영상 다 받음: 100% 가 아니라 90%
      expect(t.progress, 0.9);
      t.nextFile();
      t.update(p(50, 100));
      expect([t.received, t.total, t.progress], [950, 1000, 0.95]);
      t.update(p(100, 100));
      expect(t.progress, 1.0);

      // 전체 크기를 미리 모를 때: 지금 파일 기준, 추정치보다 커지면 큰 쪽
      final u = YtDlpTotals();
      u.update(const YtDlpProgress(0.3, '', ''));
      expect([u.total, u.progress], [null, 0.3]);
      u.update(p(300, 600));
      expect([u.received, u.total, u.progress], [300, 600, 0.5]);
      final small = YtDlpTotals()..expected = 500;
      small.update(p(600, 800));
      expect([small.total, small.progress], [800, 0.75]);
    });

    test('yt-dlp 인수: 진행률이 꺼지지 않게 (--print 는 조용한 모드를 켠다)', () {
      final t = DownloadTask(id: '1', kind: DownloadKind.video, source: 'https://youtu.be/x', dir: r'D:\dl');
      final args = YtDlpBackend(ytdlp: 'yt-dlp').argsFor(t);
      expect(args, containsAll(['--no-quiet', '--progress', '--newline']));
      expect(args.firstWhere((a) => a.startsWith('download:[JJ]')), contains('progress.downloaded_bytes'));
      expect(args, contains('before_dl:[JJS]%(filesize,filesize_approx)s'));
    });

    test('크기 표시 글', () {
      final t = DownloadTask(id: '1', kind: DownloadKind.video, source: 'x', dir: 'd');
      expect(downloadSizeText(t), '');
      t
        ..receivedBytes = 174063616
        ..totalBytes = 384827392;
      expect(downloadSizeText(t), '166MB / 367MB');
      t.totalBytes = null;
      expect(downloadSizeText(t), '166MB');
      t
        ..totalBytes = 384827392
        ..state = DownloadState.done;
      expect(downloadSizeText(t), '367MB');
    });

    test('단축키 형식', () {
      final (m1, k1) = parseHotkey('Ctrl+Shift+X')!;
      expect([m1, k1], [['ctrl', 'shift'], 'X']);
      final (m2, k2) = parseHotkey('alt + f5')!;
      expect([m2, k2], [['alt'], 'F5']);
      expect(parseHotkey('X'), isNull);
      expect(parseHotkey('Ctrl+Ctrl+X'), isNull);
      expect(parseHotkey('Ctrl+Space'), isNull);
    });
  });

  test('설정 저장 · 불러오기', () async {
    final dir = Directory.systemTemp.createTempSync('jj_set_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final store = SettingsStore(p.join(dir.path, 'settings.json'));
    expect((await store.load()).clipboardWatch, isTrue); // 파일 없으면 기본값
    final s = AppSettings()
      ..mkvOutputRoot = r'D:\out'
      ..downloadRoot = r'D:\dl'
      ..clipboardWatch = false
      ..showHotkey = 'Alt+F9'
      ..askAiOptions = false
      ..encode = const EncodeSettings(codec: VideoCodecChoice.vp9, resolution: ResolutionChoice.p720)
      ..aiTargets = ['ko', 'fr'];
    await store.save(s);
    final l = await store.load();
    expect([l.mkvOutputRoot, l.downloadRoot, l.clipboardWatch, l.showHotkey, l.askAiOptions],
        [r'D:\out', r'D:\dl', false, 'Alt+F9', false]);
    expect(l.encode.codec, VideoCodecChoice.vp9);
    expect(l.encode.resolution, ResolutionChoice.p720);
    expect(l.aiTargets, ['ko', 'fr']);
    expect(l.ytDlpDir, p.join(r'D:\dl', 'jj_yt-dlp'));
    expect(l.aria2Dir, p.join(r'D:\dl', 'jj_aria2'));
  });

  group('다운로드 관리자', () {
    late _FakeBackend video, torrent;
    late DownloadManager d;
    late AppSettings settings;
    String clip = 'https://youtu.be/already-there';

    setUp(() {
      video = _FakeBackend(DownloadKind.video);
      torrent = _FakeBackend(DownloadKind.torrent);
      settings = AppSettings()..downloadRoot = r'D:\dl';
      clip = 'https://youtu.be/already-there';
      d = DownloadManager(
          backends: [video, torrent], settings: () => settings, readClipboard: () async => clip);
    });
    tearDown(() => d.dispose());

    test('클립보드: 시작 전 내용 무시, 새 주소만 한 번 추가', () async {
      await d.startClipboardWatch();
      d.stopClipboardWatch(); // 타이머 대신 직접 확인
      expect(await d.checkClipboard(), isEmpty);

      clip = '이거 받아 https://www.youtube.com/watch?v=AAA111';
      final added = await d.checkClipboard();
      expect(added.single.kind, DownloadKind.video);
      expect(added.single.dir, p.join(r'D:\dl', 'jj_yt-dlp'));
      expect(await d.checkClipboard(), isEmpty); // 같은 내용
      clip = 'https://www.youtube.com/watch?v=AAA111'; // 내용은 다르지만 같은 주소
      expect(await d.checkClipboard(), isEmpty);

      clip = 'magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567';
      final t = (await d.checkClipboard()).single;
      expect(t.kind, DownloadKind.torrent);
      expect(t.dir, p.join(r'D:\dl', 'jj_aria2'));
      expect(video.started, ['https://www.youtube.com/watch?v=AAA111']);
      expect(torrent.started, hasLength(1));

      settings.clipboardWatch = false;
      clip = 'https://youtu.be/BBB222';
      expect(await d.checkClipboard(), isEmpty);
    });

    test('선택 · 일시정지 · 재개 · 취소 · 삭제 · 정리', () async {
      final a = d.add('https://youtu.be/A1')!;
      final b = d.add('https://youtu.be/B2')!;
      final c = d.add('magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567')!;
      await Future<void>.delayed(Duration.zero);
      expect(d.add('https://youtu.be/A1'), isNull);
      expect(d.activeCount, 3);

      d.toggle(a);
      d.toggle(b);
      await d.pauseSelected();
      expect([a.state, b.state, c.state],
          [DownloadState.paused, DownloadState.paused, DownloadState.downloading]);
      await d.resumeSelected();
      await Future<void>.delayed(Duration.zero);
      expect(a.state, DownloadState.downloading);

      d.selectNone();
      d.toggle(b);
      await d.cancelSelected();
      expect(b.state, DownloadState.cancelled);
      expect(d.tasks, contains(b)); // 취소는 목록에 남음

      c.state = DownloadState.done;
      d.cleanupFinished(); // 완료·취소 정리
      expect(d.tasks, [a]);

      d.selectAll();
      await d.removeSelected();
      expect(d.tasks, isEmpty);
      expect(d.activeCount, 0);
    });
  });

  group('aria2 (실제 실행)', () {
    late HttpServer server;
    late Directory dir;
    final data = Uint8List.fromList(List.generate(3 * 1024 * 1024, (i) => i % 251));
    var slow = false;

    setUp(() async {
      dir = Directory.systemTemp.createTempSync('jj_aria_');
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) async {
        req.response.headers
          ..contentType = ContentType.binary
          ..contentLength = data.length;
        if (!slow) {
          req.response.add(data);
        } else {
          for (var i = 0; i < data.length; i += 32 * 1024) {
            req.response.add(data.sublist(i, (i + 32 * 1024).clamp(0, data.length)));
            await Future<void>.delayed(const Duration(milliseconds: 100));
          }
        }
        await req.response.close().catchError((_) {});
      });
    });
    tearDown(() async {
      await server.close(force: true);
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    });

    Future<void> waitFor(bool Function() ok) async {
      for (var i = 0; i < 100 && !ok(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }

    test('받기 완료 · 일시정지 · 재개 · 취소(파일 삭제)', () async {
      final exe = p.join(_tools, 'aria2c.exe');
      if (!File(exe).existsSync()) return markTestSkipped('aria2c 없음');
      final b = Aria2Backend(aria2c: exe);
      addTearDown(b.shutdown);

      // 1. 빠르게 받기 → 완료
      slow = false;
      final t1 = DownloadTask(
          id: '1', kind: DownloadKind.torrent, source: 'http://127.0.0.1:${server.port}/a.bin', dir: dir.path);
      await b.start(t1, () {});
      await waitFor(() => t1.state == DownloadState.done);
      expect(t1.state, DownloadState.done, reason: t1.error);
      expect(File(p.join(dir.path, 'a.bin')).readAsBytesSync(), data);

      // 2. 느리게 받기 → 일시정지 → 재개 → 취소
      slow = true;
      final t2 = DownloadTask(
          id: '2', kind: DownloadKind.torrent, source: 'http://127.0.0.1:${server.port}/b.bin', dir: dir.path);
      await b.start(t2, () {});
      await waitFor(() => (t2.progress ?? 0) > 0.05);
      expect(t2.state, DownloadState.downloading);
      await b.pause(t2);
      expect(t2.state, DownloadState.paused);
      await b.start(t2, () {});
      expect(t2.state, DownloadState.downloading);
      await waitFor(() => t2.files.isNotEmpty);
      await b.cancel(t2);
      expect(t2.state, DownloadState.cancelled);
      expect(File(p.join(dir.path, 'b.bin')).existsSync(), isFalse);
      expect(File(p.join(dir.path, 'b.bin.aria2')).existsSync(), isFalse);
    }, timeout: const Timeout(Duration(minutes: 2)));
  });

  test('yt-dlp (실제 YouTube, JJ_NET_TESTS=1 일 때만)', () async {
    final exe = p.join(_tools, 'yt-dlp.exe');
    if (Platform.environment['JJ_NET_TESTS'] != '1' || !File(exe).existsSync()) {
      return markTestSkipped('인터넷 테스트 꺼짐');
    }
    final dir = Directory.systemTemp.createTempSync('jj_yt_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final b = YtDlpBackend(
        ytdlp: exe, ffmpegDir: r'M:\jj_MKVMaker\tools\ffmpeg\bin', deno: p.join(_tools, 'deno.exe'));
    final t = DownloadTask(
        id: 'y', kind: DownloadKind.video, source: 'https://www.youtube.com/watch?v=jNQXAC9IVRw', dir: dir.path);
    final progress = <double>[];
    await b.start(t, () {
      if (t.progress != null) progress.add(t.progress!);
    });
    expect(t.state, DownloadState.done, reason: t.error);
    expect(t.title, 'Me at the zoo');
    expect(t.files.where((f) => File(f).existsSync()), isNotEmpty);
    expect(progress, isNotEmpty);
  }, timeout: const Timeout(Duration(minutes: 3)));
}
