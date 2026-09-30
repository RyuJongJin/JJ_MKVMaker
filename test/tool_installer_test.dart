import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jj_mkvmaker/platform/windows/tool_installer.dart';
import 'package:path/path.dart' as p;

void main() {
  test('필수 프로그램: 없는 것 찾기 · aria2 내려받아 설치 (JJ_NET_TESTS=1)', () async {
    if (!Platform.isWindows) return markTestSkipped('Windows 전용');
    final dir = Directory.systemTemp.createTempSync('jj_inst_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final inst = ToolInstaller(dir.path);

    // PATH 에 없는 도구는 빠진 것으로 나온다 (이 PC 는 ffmpeg 가 PATH 에 있음)
    final missing = await inst.missing();
    expect(missing.map((t) => t.name), containsAll(['yt-dlp', 'aria2', 'Deno']));

    if (Platform.environment['JJ_NET_TESTS'] != '1') return markTestSkipped('인터넷 테스트 꺼짐');
    final steps = <String>[];
    await inst.install(missing.where((t) => t.name == 'aria2').toList(), (n, x) => steps.add('$n $x'));
    final exe = File(p.join(dir.path, 'tools', 'aria2c.exe'));
    expect(exe.existsSync(), isTrue);
    expect(File(p.join(dir.path, 'tools', 'ARIA2_COPYING.txt')).existsSync(), isTrue);
    expect(steps.last, 'aria2 1.0');
    final r = await Process.run(exe.path, ['--version']);
    expect('${r.stdout}', contains('aria2 version'));
    expect((await inst.missing()).map((t) => t.name), isNot(contains('aria2')));
  }, timeout: const Timeout(Duration(minutes: 3)));
}
