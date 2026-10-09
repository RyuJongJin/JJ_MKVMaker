import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jj_mkvmaker/core/playlist.dart';
import 'package:jj_mkvmaker/platform/windows/start_menu.dart';
import 'package:path/path.dart' as p;

/// 99: 시작 메뉴 바로 가기 (앱 ID 포함) · 알림을 누르면 jjmkvmaker://lsync 로 실시간 동기화 화면
/// (시험은 임시 폴더에 만든다 - 사용자의 시작 메뉴 · 레지스트리는 건드리지 않음)
void main() {
  test('바로 가기를 앱 ID (AUMID) 와 함께 만들고, 실행 파일이 바뀌면 고친다', () async {
    final tmp = Directory.systemTemp.createTempSync('jj_lnk_');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final lnk = p.join(tmp.path, 'JJ_MKVMaker.lnk');
    final exe1 = Platform.resolvedExecutable;
    expect(await StartMenu.ensure(exe: exe1, lnk: lnk, registerProtocol: false), isTrue);
    expect(File(lnk).existsSync(), isTrue);
    Future<String> read(String what) async => '${(await Process.run('powershell.exe', [
          '-NoProfile',
          '-Command',
          what == 'id'
              ? "(New-Object -ComObject Shell.Application).Namespace('${tmp.path}').ParseName('JJ_MKVMaker.lnk').ExtendedProperty('System.AppUserModel.ID')"
              : "(New-Object -ComObject WScript.Shell).CreateShortcut('$lnk').TargetPath",
        ])).stdout}'
        .trim();
    expect(await read('id'), StartMenu.aumid);
    expect((await read('target')).toLowerCase(), exe1.toLowerCase());
    // 앱 폴더를 옮긴 경우: 다음 실행 때 새 위치로
    final exe2 = p.join(Platform.environment['SystemRoot'] ?? r'C:\Windows', 'notepad.exe');
    expect(await StartMenu.ensure(exe: exe2, lnk: lnk, registerProtocol: false), isTrue);
    expect((await read('target')).toLowerCase(), exe2.toLowerCase());
    expect(await read('id'), StartMenu.aumid);
  }, skip: !Platform.isWindows, timeout: const Timeout(Duration(minutes: 2)));

  test('알림을 누르면 오는 주소 (jjmkvmaker://lsync) 는 실시간 동기화 화면 요청', () {
    expect(LaunchRequest.parse(['jjmkvmaker://lsync/']).action, LaunchAction.lsync);
    expect(LaunchRequest.parse(['jjmkvmaker://lsync/']).files, isEmpty);
    expect(LaunchRequest.parse(['--lsync']).action, LaunchAction.lsync);
    expect(LaunchRequest.parse(LaunchRequest(LaunchAction.lsync, const []).toArgs()).action, LaunchAction.lsync);
    expect(LaunchRequest.parse(['jjmkvmaker://other']).files, isEmpty); // 모르는 주소를 파일로 열지 않음
  });
}
