import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:integration_test/integration_test.dart';
import 'package:jj_mkvmaker/platform/windows/desktop_shell.dart';
import 'package:window_manager/window_manager.dart';

/// 실제 Windows: 트레이 · 전역 단축키 · 창 숨기기/보이기
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final steps = File(p.join(Directory.systemTemp.path, 'jj_shell_steps.txt'));
  if (steps.existsSync()) steps.deleteSync();
  void mark(String s) => steps.writeAsStringSync('$s\n', mode: FileMode.append, flush: true);

  testWidgets('DesktopShell', (tester) async {
    mark('start');
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: Text('shell'))));
    final shell = DesktopShell();
    var closeAsked = 0;
    await tester.runAsync(() => shell.init(
          hotkey: 'Ctrl+Shift+X',
          minimizeToTray: () => true,
          onCloseRequested: () async {
            closeAsked++;
            return false; // 종료하지 않음
          },
        ));

    mark('init ok');
    // 단축키 바꾸기 · 잘못된 형식
    expect(await tester.runAsync(() => shell.setHotkey('Ctrl+Alt+F9')), isTrue);
    expect(await tester.runAsync(() => shell.setHotkey('Ctrl+Space')), isFalse);
    expect(await tester.runAsync(() => shell.setHotkey('Ctrl+Shift+X')), isTrue);

    mark('hotkey ok');
    // 트레이로 숨기기 → 다시 보이기
    await tester.runAsync(() async { await shell.hide(); await Future<void>.delayed(const Duration(milliseconds: 500)); });
    expect(await tester.runAsync(() => windowManager.isVisible()), isFalse);
    await tester.runAsync(() async { await shell.show(); await Future<void>.delayed(const Duration(milliseconds: 500)); });
    expect(await tester.runAsync(() => windowManager.isVisible()), isTrue);

    mark('hide/show ok');
    // 최소화하면 트레이로
    await tester.runAsync(() async {
      await windowManager.minimize();
      await Future<void>.delayed(const Duration(milliseconds: 800));
    });
    expect(await tester.runAsync(() => windowManager.isVisible()), isFalse);
    await tester.runAsync(() async { await shell.show(); await Future<void>.delayed(const Duration(milliseconds: 500)); });

    // 창 X → 종료 확인 콜백 (false 이므로 창 유지)
    shell.onWindowClose();
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 500)));
    expect(closeAsked, 1);
    expect(await tester.runAsync(() => windowManager.isVisible()), isTrue);
    await tester.runAsync(() => shell.setTooltip('JJ_MKVMaker - 다운로드 1개'));
  });
}
