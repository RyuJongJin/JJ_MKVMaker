import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jj_mkvmaker/platform/windows/cef_runtime.dart';
import 'package:path/path.dart' as p;

/// 실제로 내장 Chrome 엔진을 공식 배포처에서 받아 설치 (약 155MB)
/// 실행: JJ_NET_TESTS=1 JJ_CEF_DIR=<설치할 폴더> flutter test test/cef_net_test.dart
void main() {
  test('내장 Chrome 엔진 내려받기 · 설치', () async {
    if (Platform.environment['JJ_NET_TESTS'] != '1') return markTestSkipped('JJ_NET_TESTS=1 일 때만');
    final target = Platform.environment['JJ_CEF_DIR'] ??
        p.join(Directory.systemTemp.createTempSync('jj_cefnet_').path, 'cef');
    CefRuntime.dirOverride = target;
    final stages = <String>{};
    var last = 0.0;
    final sw = Stopwatch()..start();
    await CefRuntime.install(onProgress: (x, s) {
      stages.add(s);
      expect(x, greaterThanOrEqualTo(last - 1e-9)); // 줄어들지 않는다
      last = x;
    });
    // ignore: avoid_print
    print('RESULT ${sw.elapsed.inSeconds}초, 단계 $stages, 설치 ${CefRuntime.installedMb()}MB → $target');
    expect(CefRuntime.installed, isTrue);
    for (final f in ['libcef.dll', 'chrome_elf.dll', 'icudtl.dat', 'resources.pak', 'v8_context_snapshot.bin']) {
      expect(File(p.join(target, f)).existsSync(), isTrue, reason: f);
    }
    expect(Directory(p.join(target, 'locales')).existsSync(), isTrue);
    expect(Directory(target).listSync().where((e) => e.path.endsWith('.lib')), isEmpty);
    expect(Directory('$target.new').existsSync(), isFalse);
  }, timeout: const Timeout(Duration(minutes: 20)));
}
