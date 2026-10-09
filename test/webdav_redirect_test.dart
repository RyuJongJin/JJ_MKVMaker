import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jj_mkvmaker/core/webdav.dart';

/// http 주소의 서버가 https 로 옮기라고 하면 (301 등) 이유와 할 일을 알린다
void main() {
  test('301 → https: wantsHttps · 안내 글', () async {
    final srv = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    srv.listen((r) {
      r.response
        ..statusCode = 301
        ..headers.set(HttpHeaders.locationHeader, 'https://nas.example/dav/')
        ..close();
    });
    addTearDown(() => srv.close(force: true));
    final c = DavClient(DavServer(id: 'r', name: 'r', url: 'http://127.0.0.1:${srv.port}/dav'));
    addTearDown(c.close);
    final e = await c.list('/').then<Object?>((_) => null, onError: (Object e) => e);
    expect(e, isA<DavException>());
    final d = e as DavException;
    expect(d.wantsHttps, isTrue);
    expect(d.message, contains('https'));
    expect(d.status, 301);
  });
}
