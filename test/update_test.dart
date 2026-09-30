import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jj_mkvmaker/core/app_update.dart';
import 'package:jj_mkvmaker/platform/windows/github_updater.dart';
import 'package:path/path.dart' as p;

// 화면 테스트는 update_ui_test.dart (화면 테스트가 같은 파일에 있으면 실제 네트워크 연결이 막힘)

Map<String, dynamic> _release(String tag, {String? digest, String body = '', bool draft = false, String? url}) => {
      'tag_name': tag,
      'name': 'JJ_MKVMaker $tag',
      'body': body,
      'draft': draft,
      'prerelease': false,
      'html_url': 'https://github.com/$updateRepo/releases/tag/$tag',
      'assets': [
        {
          'name': 'JJ_MKVMaker_${tag}_win64.zip',
          'size': 1234,
          'browser_download_url': url ?? 'https://example.com/x.zip',
          'digest': ?digest,
        },
      ],
    };

void main() {
  group('버전 · Release 해석', () {
    test('버전 비교', () {
      expect(compareVersions('1.0.1', '1.0.0'), greaterThan(0));
      expect(compareVersions('v1.2', '1.2.0'), 0);
      expect(compareVersions('1.10.0', '1.9.9'), greaterThan(0));
      expect(compareVersions('1.0.0+5', 'v1.0.1'), lessThan(0));
    });
    test('버전: 년.월.일_순번', () {
      expect(parseVersion('v2026.09.30_001'), [2026, 9, 30, 1]);
      expect(formatVersion('2026.9.30+1'), '2026.09.30_001'); // pubspec 의 표기 → 보이는 글
      expect(formatVersion('v2026.09.30_012'), '2026.09.30_012');
      expect(formatVersion('2026.10.1+3'), '2026.10.01_003');
      expect(formatVersion('v1.2.3'), '1.2.3'); // 예전 방식은 그대로
      // 같은 날: 순번이 크면 최신. 날이 바뀌면 001 이어도 최신.
      expect(compareVersions('2026.09.30_002', '2026.9.30+1'), greaterThan(0));
      expect(compareVersions('v2026.09.30_001', '2026.9.30+1'), 0);
      expect(compareVersions('2026.10.01_001', '2026.09.30_015'), greaterThan(0));
      expect(compareVersions('2027.01.01_001', '2026.12.31_009'), greaterThan(0));
      // 예전 1.x 에서 쓰던 사람도 새 방식을 업데이트로 받는다
      expect(compareVersions('v2026.09.30_001', '1.1.1'), greaterThan(0));
      final r = parseLatestRelease(_release('v2026.09.30_002'))!;
      expect(r.version, '2026.09.30_002');
      expect(r.isNewerThan('2026.09.30_001'), isTrue);
      expect(r.isNewerThan('2026.09.30_002'), isFalse);
    });
    test('releases/latest 해석', () {
      final r = parseLatestRelease(_release('v1.2.0', digest: 'sha256:${'A' * 64}'))!;
      expect([r.version, r.tag, r.zipName, r.sha256], ['1.2.0', 'v1.2.0', 'JJ_MKVMaker_v1.2.0_win64.zip', 'a' * 64]);
      expect(r.isNewerThan('1.0.1'), isTrue);
      // digest 없으면 설명의 SHA256
      final b = parseLatestRelease(_release('v1.2.0', body: '| zip | `${'B' * 64}` |'))!;
      expect(b.sha256, 'b' * 64);
      expect(parseLatestRelease(_release('v9.0.0', draft: true)), isNull);
    });
    test('하루 한 번', () {
      final now = DateTime(2026, 10, 1, 12);
      expect(updateCheckDue('', now), isTrue);
      expect(updateCheckDue(DateTime(2026, 10, 1, 9).toIso8601String(), now), isFalse);
      expect(updateCheckDue(DateTime(2026, 9, 30, 9).toIso8601String(), now), isTrue);
    });
  });

  test('실제 GitHub: v1.0.0 에서 최신 찾기 · 받기 · 검증 (JJ_NET_TESTS=1)', () async {
    if (Platform.environment['JJ_NET_TESTS'] != '1') return markTestSkipped('인터넷 테스트 꺼짐');
    final tmp = Directory.systemTemp.createTempSync('jj_real_upd_');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final up = GitHubUpdater(appDir: tmp.path, versionOverride: '1.0.0');
    final r = (await up.latest())!;
    expect(r.isNewerThan('1.0.0'), isTrue);
    expect(r.sha256, hasLength(64));
    final dir = await up.download(r, (_) {});
    expect(File(p.join(dir, 'jj_mkvmaker.exe')).existsSync(), isTrue);
    expect(File(p.join(dir, 'ffmpeg', 'ffmpeg.exe')).existsSync(), isTrue);
  }, timeout: const Timeout(Duration(minutes: 10)));

  group('GitHubUpdater (가짜 GitHub 서버 · 실제 스크립트)', () {
    late HttpServer server;
    late Directory tmp;
    late List<int> zipBytes;
    var digest = '';

    setUpAll(() async {
      tmp = Directory.systemTemp.createTempSync('jj_upd_');
      // 새 버전 zip: JJ_MKVMaker\jj_mkvmaker.exe · new.txt · data\app.so
      final src = Directory(p.join(tmp.path, 'pkg', 'JJ_MKVMaker'))..createSync(recursive: true);
      File(p.join(src.path, 'jj_mkvmaker.exe')).writeAsStringSync('NEW EXE');
      File(p.join(src.path, 'new.txt')).writeAsStringSync('new file');
      Directory(p.join(src.path, 'data')).createSync();
      File(p.join(src.path, 'data', 'app.so')).writeAsStringSync('NEW DATA');
      final zip = p.join(tmp.path, 'u.zip');
      final r = await Process.run('tar', ['-a', '-cf', zip, '-C', p.join(tmp.path, 'pkg'), 'JJ_MKVMaker']);
      expect(r.exitCode, 0, reason: '${r.stderr}');
      zipBytes = File(zip).readAsBytesSync();
      digest = sha256.convert(zipBytes).toString();

      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) async {
        final base = 'http://127.0.0.1:${server.port}';
        if (req.uri.path == '/repos/$updateRepo/releases/latest') {
          req.response.headers.contentType = ContentType.json;
          final bad = req.uri.queryParameters['bad'] == '1';
          req.response.write(jsonEncode(_release('v1.9.0',
              digest: 'sha256:${bad ? '0' * 64 : digest}', url: '$base/dl/u.zip')));
        } else if (req.uri.path == '/dl/u.zip') {
          req.response
            ..contentLength = zipBytes.length
            ..add(zipBytes);
        } else {
          req.response.statusCode = 404;
        }
        await req.response.close();
      });
    });
    tearDownAll(() async {
      await server.close(force: true);
      tmp.deleteSync(recursive: true);
    });

    test('최신 확인 → 받기 · SHA256 확인 · 압축 풀기', () async {
      final up = GitHubUpdater(apiBase: 'http://127.0.0.1:${server.port}', appDir: tmp.path, versionOverride: '1.0.1');
      final r = (await up.latest())!;
      expect(r.isNewerThan(await up.currentVersion()), isTrue);
      final progress = <double>[];
      final dir = await up.download(r, progress.add);
      expect(File(p.join(dir, 'jj_mkvmaker.exe')).readAsStringSync(), 'NEW EXE');
      expect(progress.last, 1);
    });

    test('SHA256 이 다르면 설치 거부', () async {
      final up = GitHubUpdater(apiBase: 'http://127.0.0.1:${server.port}', appDir: tmp.path);
      final good = (await up.latest())!;
      final bad = ReleaseInfo(
          version: good.version, tag: good.tag, name: '', notes: '', pageUrl: '',
          zipUrl: good.zipUrl, zipName: good.zipName, sha256: '0' * 64);
      await expectLater(up.download(bad, (_) {}), throwsA(predicate((e) => '$e'.contains('SHA256'))));
    });

    test('업데이트 스크립트: 프로그램 파일만 교체, 받은 파일 · 모델 보존', () async {
      if (!Platform.isWindows) return markTestSkipped('Windows 전용');
      final app = Directory(p.join(tmp.path, 'installed'))..createSync();
      File(p.join(app.path, 'jj_mkvmaker.exe')).writeAsStringSync('OLD EXE');
      File(p.join(app.path, 'old_only.txt')).writeAsStringSync('keep me');
      Directory(p.join(app.path, 'jj_yt-dlp')).createSync();
      File(p.join(app.path, 'jj_yt-dlp', 'video.mp4')).writeAsStringSync('my download');
      Directory(p.join(app.path, 'models')).createSync();
      File(p.join(app.path, 'models', 'm.bin')).writeAsStringSync('model');

      final up = GitHubUpdater(apiBase: 'http://127.0.0.1:${server.port}', appDir: app.path);
      final dir = await up.download((await up.latest())!, (_) {});
      // 이미 끝난 프로세스를 "앱" 으로 두고 실행 (바로 교체 진행)
      final dummy = await Process.start('cmd', ['/c', 'exit']);
      await dummy.exitCode;
      final proc = await up.runInstallScript(dir, waitPid: dummy.pid, restart: false);
      expect(await proc.exitCode, 0);

      expect(File(p.join(app.path, 'jj_mkvmaker.exe')).readAsStringSync(), 'NEW EXE');
      expect(File(p.join(app.path, 'new.txt')).existsSync(), isTrue);
      expect(File(p.join(app.path, 'data', 'app.so')).readAsStringSync(), 'NEW DATA');
      expect(File(p.join(app.path, 'old_only.txt')).readAsStringSync(), 'keep me');
      expect(File(p.join(app.path, 'jj_yt-dlp', 'video.mp4')).readAsStringSync(), 'my download');
      expect(File(p.join(app.path, 'models', 'm.bin')).readAsStringSync(), 'model');
    }, timeout: const Timeout(Duration(minutes: 2)));
  });
}
