import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:jj_mkvmaker/platform/windows/start_menu.dart';
import 'package:path/path.dart' as p;

/// 99: 실제 시작 메뉴 · HKCU 등록 · 이 앱 이름의 알림 (JJ_TEST_START_MENU=1 일 때만 - 사용자의 시작 메뉴를 바꾸므로).
/// 끝나면 만든 바로 가기와 jjmkvmaker:// 등록을 지워 시험 전 상태로 돌린다.
/// JJ_TEST_LAUNCHER: 바로 가기가 가리킬 시험용 배포 폴더의 jj_mkvmaker.exe
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final launcher = Platform.environment['JJ_TEST_LAUNCHER'] ?? '';
  final shot = Platform.environment['JJ_TEST_SHOT'] ?? '';

  Future<String> ps(String cmd) async => '${(await Process.run('powershell.exe', ['-NoProfile', '-Command', cmd])).stdout}'.trim();

  testWidgets('시작 메뉴 바로 가기 (AUMID) · jjmkvmaker:// · JJ_MKVMaker 이름의 알림 · 폴더를 옮기면 고침 · 정리', (t) async {
    final lnk = StartMenu.shortcutPath;
    expect(File(lnk).existsSync(), isFalse, reason: '시험 전에는 없어야 한다');
    try {
      expect(await StartMenu.ensure(exe: launcher), isTrue);
      expect(File(lnk).existsSync(), isTrue);
      final dir = p.dirname(lnk), name = p.basename(lnk);
      expect(await ps("(New-Object -ComObject Shell.Application).Namespace('$dir').ParseName('$name').ExtendedProperty('System.AppUserModel.ID')"),
          StartMenu.aumid);
      expect((await ps("(New-Object -ComObject WScript.Shell).CreateShortcut('$lnk').TargetPath")).toLowerCase(), launcher.toLowerCase());
      final cmd = await ps(r"(Get-ItemProperty -LiteralPath 'HKCU:\Software\Classes\jjmkvmaker\shell\open\command').'(default)'");
      expect(cmd.toLowerCase(), contains(launcher.toLowerCase()));
      // 이 앱 이름으로 알림 (보낸 이 확인용으로 화면을 찍어 둔다)
      expect(await StartMenu.toast('JJ_MKVMaker 알림 시험 (99)', '실시간 동기화가 멈췄습니다 - 시험입니다\n무시해도 됩니다'), isTrue);
      if (shot.isNotEmpty) {
        await Future<void>.delayed(const Duration(seconds: 2));
        await ps('Add-Type -AssemblyName System.Windows.Forms,System.Drawing; '
            r'$b = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds; '
            r'$bmp = New-Object System.Drawing.Bitmap $b.Width, $b.Height; '
            r'$g = [System.Drawing.Graphics]::FromImage($bmp); $g.CopyFromScreen($b.Location, [System.Drawing.Point]::Empty, $b.Size); '
            "\$bmp.Save('$shot')");
      }
      // 앱 폴더를 옮긴 경우: 다음 실행 때 새 위치로 고친다
      final moved = p.join(p.dirname(launcher), 'Lib', p.basename(launcher));
      expect(await StartMenu.ensure(exe: moved), isTrue);
      expect((await ps("(New-Object -ComObject WScript.Shell).CreateShortcut('$lnk').TargetPath")).toLowerCase(), moved.toLowerCase());
    } finally {
      await StartMenu.remove();
    }
    expect(File(lnk).existsSync(), isFalse);
    expect(await ps(r"Test-Path 'HKCU:\Software\Classes\jjmkvmaker'"), 'False');
  }, skip: !Platform.isWindows || Platform.environment['JJ_TEST_START_MENU'] != '1');
}
