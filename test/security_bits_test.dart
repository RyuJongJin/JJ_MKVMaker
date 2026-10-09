import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jj_mkvmaker/ui/browser_page.dart' show deleteExportedCookies;
import 'package:jj_mkvmaker/core/file_ops.dart' show SourceUnreadableException;
import 'package:jj_mkvmaker/app/settings.dart';
import 'package:jj_mkvmaker/core/download_detect.dart';
import 'package:jj_mkvmaker/core/secret_gate.dart';
import 'package:jj_mkvmaker/core/webdav.dart';
import 'package:jj_mkvmaker/ui/webdav_settings.dart';
import 'package:path/path.dart' as p;

import 'support/dav_server.dart';

void main() {
  group('124: 저장된 비밀번호를 쓰기 전의 문', () {
    late Directory tmp;
    late TestDavServer server;
    setUp(() async {
      tmp = Directory.systemTemp.createTempSync('jj_gate_');
      File(p.join(tmp.path, 'a.txt')).writeAsStringSync('a');
      server = TestDavServer(tmp);
      await server.start();
    });
    tearDown(() async {
      SecretGate.check = null;
      await server.stop();
      tmp.deleteSync(recursive: true);
    });

    test('마스터를 넣지 않으면 (문이 닫힘) 비밀번호로 접속하지 않는다 · 열리면 접속', () async {
      var asked = 0;
      var allow = false;
      SecretGate.check = (_) async {
        asked++;
        return allow;
      };
      final c = DavClient(DavServer(id: 'n', name: 'n', url: server.url, user: 'user', password: 'pass'));
      // 128: "읽지 못함" 이 아니라 "마스터를 기다리는 중" 으로 구분된다
      await expectLater(c.list(''), throwsA(isA<DavLockedException>().having((e) => e.message, 'message', secretGateMessage)));
      try {
        await c.list('');
      } catch (e) {
        expect(SourceUnreadableException('dav://n/', cause: e).locked, isTrue);
      }
      expect(SourceUnreadableException('dav://n/', cause: const DavException('401')).locked, isFalse);
      expect(asked, 2, reason: '부를 때마다 문을 지난다');
      allow = true;
      expect((await c.list('')).map((e) => e.rel), anyElement(contains('a.txt')));
    });

    test('비밀번호가 없는 서버는 묻지 않는다', () async {
      var asked = 0;
      SecretGate.check = (_) async {
        asked++;
        return false;
      };
      final c = DavClient(DavServer(id: 'o', name: 'o', url: server.url));
      try {
        await c.list(''); // 시험 서버는 로그인을 요구해 401 - 묻지 않고 그냥 접속해 본 것만 확인
      } on DavException catch (e) {
        expect(e, isNot(isA<DavLockedException>()));
      }
      expect(asked, 0);
    });
  });

  test('124-1: 지우려는 서버를 쓰는 실시간 동기화 · 기억된 작업을 찾는다', () {
    final s = AppSettings()
      ..liveSyncPairs = [
        LiveSyncPair(r'C:\영상', 'dav://nas/백업'),
        LiveSyncPair(r'C:\a', r'D:\b'),
        LiveSyncPair('dav://other/x', r'C:\y'),
      ]
      ..copyTasks = [
        CopyTask(id: 't', sources: const ['dav://nas/사진'], dest: r'C:\사진', method: 'builtin', options: '', once: false),
      ];
    final users = davServerUsers(s, 'nas');
    expect(users, hasLength(2));
    expect(users.first, contains('실시간 동기화'));
    expect(users.last, contains('기억된 작업'));
    expect(davServerUsers(s, 'none'), isEmpty);
  });

  test('56: http:// 주소는 암호화 안 됨으로 알린다', () {
    expect(isPlainHttp('http://nas.local/dav'), isTrue);
    expect(isPlainHttp(' HTTP://x'), isTrue);
    expect(isPlainHttp('https://nas.local/dav'), isFalse);
  });

  group('53: 브라우저 쿠키', () {
    tearDown(() {
      CookieExport.sites = loginCookieDomains;
      CookieExport.enabled = true;
    });

    test('고른 사이트의 쿠키만 넘긴다 (처음은 모두)', () {
      expect(AppSettings().loginCookieSites, loginCookieDomains);
      expect(isLoginCookieDomain('.instagram.com'), isTrue);
      CookieExport.sites = ['youtube.com', 'google.com'];
      expect(isLoginCookieDomain('.youtube.com'), isTrue);
      expect(isLoginCookieDomain('.instagram.com'), isFalse);
      expect(isLoginCookieDomain('netflix.com'), isFalse);
      final b = AppSettings.fromJson((AppSettings()..loginCookieSites = ['x.com']).toJson());
      expect(b.loginCookieSites, ['x.com']);
      expect(AppSettings.fromJson({'loginCookieSites': ['x.com', 'evil.com']}).loginCookieSites, ['x.com']);
    });

    test('앱 안 브라우저 쿠키를 쓰던 사람에게 넘기는 사이트가 넓어진 것을 한 번 알린다', () {
      expect(AppSettings.fromJson({'ytCookiesBrowser': internalBrowserCookies}).migrated, contains('cookieScope'));
      expect(AppSettings.fromJson({'ytCookiesBrowser': ''}).migrated, isNot(contains('cookieScope')));
      expect(AppSettings.fromJson({}).migrated, isNot(contains('cookieScope')), reason: '새로 설치');
      expect(AppSettings.fromJson(AppSettings().toJson()).migrated, isNot(contains('cookieScope')));
    });
  });

  test('131: 내보낸 쿠키 파일 지우기', () async {
    final dir = Directory.systemTemp.createTempSync('jj_cookie_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final f = File(p.join(dir.path, CookieExport.fileName))..writeAsStringSync('# Netscape HTTP Cookie File');
    File('${f.path}.tmp').writeAsStringSync('x');
    await deleteExportedCookies(dir.path);
    expect(f.existsSync(), isFalse);
    expect(File('${f.path}.tmp').existsSync(), isFalse);
  });
}
