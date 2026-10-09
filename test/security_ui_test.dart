import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jj_mkvmaker/app/app_controller.dart';
import 'package:jj_mkvmaker/core/secret_gate.dart';
import 'package:jj_mkvmaker/core/webdav.dart';
import 'package:jj_mkvmaker/platform/windows/desktop_storage_service.dart';
import 'package:jj_mkvmaker/platform/windows/process_media_tool.dart';
import 'package:jj_mkvmaker/services/platform_services.dart';
import 'package:jj_mkvmaker/ui/webdav_settings.dart';

void main() {
  testWidgets('127: 비밀번호가 저장된 서버를 고치려면 먼저 마스터 (넣지 않으면 창이 열리지 않아 비밀번호가 보이지 않음)', (t) async {
    var allow = false;
    var forced = false;
    SecretGate.check = (force) async {
      forced = force;
      return allow;
    };
    addTearDown(() => SecretGate.check = null);
    final c = AppController(PlatformServices(mediaTool: ProcessMediaTool('x', 'y'), storage: DesktopStorageService()));
    await t.pumpWidget(const MaterialApp(home: Scaffold(body: SizedBox())));
    final ctx = t.element(find.byType(SizedBox));
    const old = DavServer(id: 'n', name: 'NAS', url: 'https://nas', user: 'u', password: 'secret-pw');
    DavServer? r = const DavServer(id: 'x', name: 'x', url: 'x');
    editDavServer(ctx, c, old: old).then((v) => r = v);
    await t.pumpAndSettle();
    expect(r, isNull);
    expect(forced, isTrue, reason: '사용자가 직접 연 것 - 취소한 적이 있어도 묻는다');
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('secret-pw', findRichText: true), findsNothing);
    allow = true;
    editDavServer(ctx, c, old: old);
    await t.pumpAndSettle();
    expect(find.text('WebDAV 서버 고치기'), findsOneWidget);
    await t.tap(find.text('취소'));
    await t.pumpAndSettle();
    // 비밀번호가 없는 서버는 묻지 않는다
    allow = false;
    forced = false;
    editDavServer(ctx, c, old: const DavServer(id: 'o', name: 'o', url: 'https://o'));
    await t.pumpAndSettle();
    expect(find.text('WebDAV 서버 고치기'), findsOneWidget);
    expect(forced, isFalse);
  });

}
