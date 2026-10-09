import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// 60: 화면 글자 사전 검사기 (tool/l10n) - 사전에 빠진 번역이 없는지, 검사기가 놓치던 것을 잡는지
void main() {
  final python = Platform.isWindows ? 'python' : 'python3';
  bool hasPython() {
    try {
      return Process.runSync(python, ['--version']).exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  final skip = hasPython() ? false : 'python 이 없음';

  test('사전에 빠진 번역이 없다 (tool/l10n/check.py)', () {
    final r = Process.runSync(python, ['tool/l10n/check.py'], environment: {'PYTHONIOENCODING': 'utf-8'}, stdoutEncoding: utf8);
    expect(r.exitCode, 0, reason: '${r.stdout}');
  }, skip: skip);

  test('검사기: 줄을 바꾼 trf( · tr(변수) 로 쓰는 글을 잡고, // l10n-skip · raw 문자열은 넘긴다', () {
    final dir = Directory.systemTemp.createTempSync('jj_l10n_');
    addTearDown(() => dir.deleteSync(recursive: true));
    Directory(p.join(dir.path, 'lib')).createSync();
    File(p.join(dir.path, 'lib', 'a.dart')).writeAsStringSync('''
String f(int n) => trf(
    '줄을 바꾼 열쇠 {0}', [n]);
String label(bool v) => v ? '위 → 아래' : '좌 → 우';
String g() => tr(label(true));
// l10n-skip: 실제 폴더 이름
const folder = '설정 보관';
final re = RegExp(r'한국어|kor');
''');
    File(p.join(dir.path, 'lib', 'b.dart')).writeAsStringSync('''
// l10n-skip-file: 자료
const words = ['네.', '응.'];
''');
    final keys = p.join(dir.path, 'keys.json'), loose = p.join(dir.path, 'loose.json');
    final r = Process.runSync(python, [p.absolute('tool/l10n/extract_keys.py'), keys, loose],
        workingDirectory: dir.path, environment: {'PYTHONIOENCODING': 'utf-8'});
    expect(r.exitCode, 0, reason: '${r.stderr}');
    expect(jsonDecode(File(keys).readAsStringSync()), contains('줄을 바꾼 열쇠 {0}'));
    final texts = [for (final x in jsonDecode(File(loose).readAsStringSync()) as List) (x as List)[2]];
    expect(texts, unorderedEquals(['위 → 아래', '좌 → 우']));
  }, skip: skip);
}
