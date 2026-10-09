import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jj_mkvmaker/app/i18n_controller.dart';
import 'package:jj_mkvmaker/core/webdav.dart';
import 'package:jj_mkvmaker/l10n/tr.dart';
import 'package:jj_mkvmaker/ui/file_error.dart';

void main() {
  test('50: Android 가 막은 폴더 (Android/data · obb) 알아보기', () {
    for (final p in [
      '/storage/emulated/0/Android/data',
      '/storage/emulated/0/Android/data/com.example.app',
      '/storage/emulated/0/Android/obb/',
      '/storage/1234-ABCD/Android/data/x',
    ]) {
      expect(isAndroidRestricted(p, android: true), isTrue, reason: p);
    }
    for (final p in [
      '/storage/emulated/0/Android',
      '/storage/emulated/0/Android/media',
      '/storage/emulated/0/Download/Android/datas',
      '/storage/emulated/0/Movies',
    ]) {
      expect(isAndroidRestricted(p, android: true), isFalse, reason: p);
    }
    // Windows 등은 해당 없음
    expect(isAndroidRestricted('/storage/emulated/0/Android/data', android: false), isFalse);
  });

  test('50: 막힌 폴더는 "이 폴더는 Android 가 막아 볼 수 없습니다" 와 할 일', () {
    final (title, body) = explainFileError(androidRestrictedError, dav: false);
    expect(title, '이 폴더는 Android 가 막아 볼 수 없습니다');
    expect(body, contains('내보내기'));
  });

  test('59: WebDAV 오류 글이 화면 언어로 오고, 바뀐 글로도 오류 종류를 가른다 (ja)', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    // 시험 바인딩은 HttpClient 를 늘 400 을 돌려주는 가짜로 바꾼다 - 이 시험은 진짜 로컬 서버에 닿아야 한다
    final saved = HttpOverrides.current;
    HttpOverrides.global = null;
    addTearDown(() => HttpOverrides.global = saved);
    await i18n.apply('ja', save: false);
    addTearDown(() => i18n.apply('ko', save: false));
    for (final (status, title) in [(401, '아이디 또는 비밀번호가 맞지 않습니다'), (403, '이 폴더를 볼 권한이 없습니다'), (404, '폴더가 없습니다')]) {
      final srv = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      srv.listen((r) async {
        await r.drain<void>(); // 본문을 다 읽고 답한다 (실제 서버처럼)
        if (status == 401) r.response.headers.set(HttpHeaders.wwwAuthenticateHeader, 'Basic realm="t"');
        r.response.statusCode = status;
        await r.response.close();
      });
      final c = DavClient(DavServer(id: 'e', name: 'e', url: 'http://127.0.0.1:${srv.port}/dav', user: 'u', password: 'p'));
      final e = await c.list('/x').then<Object?>((_) => null, onError: (Object e) => e);
      c.close();
      await srv.close(force: true);
      expect(e, isA<DavException>(), reason: '$status');
      final msg = '$e';
      expect(RegExp('[가-힣]').hasMatch(msg), isFalse, reason: '$status: 한국어가 남음 - $msg');
      expect(explainFileError(msg, dav: true).$1, tr(title), reason: '$status: $msg');
    }
  });
}
