import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jj_mkvmaker/ui/toast_status.dart';

void main() {
  const off = '\r\nHKEY_CURRENT_USER\\Software\\Microsoft\\Windows\\CurrentVersion\\PushNotifications\r\n'
      '    ToastEnabled    REG_DWORD    0x0\r\n';
  const on = '    ToastEnabled    REG_DWORD    0x1\r\n';
  const appOff = '    ShowInActionCenter    REG_DWORD    0x1\r\n    Enabled    REG_DWORD    0x0\r\n';

  test('reg query 읽기: 전체 꺼짐 · 이 앱만 꺼짐 · 값 없음 = 켜짐', () {
    expect(regDword(off, 'ToastEnabled'), 0);
    expect(regDword(appOff, 'Enabled'), 0);
    expect(regDword(appOff, 'ShowInActionCenter'), 1);
    expect(toastBlockFrom(global: off, app: ''), ToastBlock.all);
    expect(toastBlockFrom(global: on, app: appOff), ToastBlock.app);
    expect(toastBlockFrom(global: '', app: appOff), ToastBlock.app);
    expect(toastBlockFrom(global: on, app: ''), isNull);
    expect(toastBlockFrom(global: '', app: ''), isNull);
  });

  testWidgets('꺼져 있으면 안내 + [Windows 알림 설정 열기] · 켜면 다시 확인해서 사라짐', (t) async {
    ToastBlock? state = ToastBlock.all;
    var opened = 0;
    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ToastStatusHint(check: () async => state, openSettings: () async => opened++),
      ),
    ));
    await t.pump();
    expect(find.text('Windows 알림이 꺼져 있어 보이지 않습니다'), findsOneWidget);
    await t.tap(find.text('Windows 알림 설정 열기'));
    await t.pump();
    expect(opened, 1);

    state = ToastBlock.app;
    await t.tap(find.byIcon(Icons.refresh));
    await t.pump();
    expect(find.text('Windows 에서 이 앱의 알림이 꺼져 있어 보이지 않습니다'), findsOneWidget);

    state = null;
    await t.tap(find.byIcon(Icons.refresh));
    await t.pump();
    expect(find.text('Windows 알림 설정 열기'), findsNothing);
  });
}
