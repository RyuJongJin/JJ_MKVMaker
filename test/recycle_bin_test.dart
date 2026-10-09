import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jj_mkvmaker/platform/windows/recycle_bin.dart';
import 'package:path/path.dart' as p;

/// 시험이 휴지통에 넣은 것만 (원래 위치가 이 시험의 임시 폴더인 항목) 휴지통에서 지운다. 사용자 항목은 건드리지 않는다.
Future<int> _purgeFromRecycleBin(String fromDir) async {
  final dir = fromDir.replaceAll("'", "''");
  final r = await Process.run('powershell.exe', [
    '-NoProfile',
    '-NonInteractive',
    '-Command',
    '''
\$rb = (New-Object -ComObject Shell.Application).Namespace(10)
\$n = 0
foreach (\$it in @(\$rb.Items())) {
  if (\$rb.GetDetailsOf(\$it, 1) -ne '$dir') { continue }
  \$path = \$it.Path; \$d = Split-Path \$path; \$leaf = Split-Path \$path -Leaf
  Remove-Item -LiteralPath \$path -Recurse -Force -Confirm:\$false
  \$info = Join-Path \$d ('\$I' + \$leaf.Substring(2))
  if (Test-Path -LiteralPath \$info) { Remove-Item -LiteralPath \$info -Force -Confirm:\$false }
  \$n++
}
\$n
''',
  ]);
  return int.tryParse('${r.stdout}'.trim().split('\n').last.trim()) ?? -1;
}

/// 65 · 94 · 98: Windows 휴지통 (실제 휴지통 - 시험 파일 하나 · 폴더 하나, 끝나면 휴지통에서도 지움)
void main() {
  test('파일 · 폴더를 휴지통으로 (실제로 들어갔는지까지) · 없는 것은 그냥 성공', () async {
    final tmp = Directory.systemTemp.createTempSync('jj_recycle_');
    addTearDown(() async {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });
    final f = File(p.join(tmp.path, 'jj_recycle_test.txt'))..writeAsStringSync('x');
    final d = Directory(p.join(tmp.path, 'jj_recycle_dir'))..createSync();
    File(p.join(d.path, 'a.txt')).writeAsStringSync('a');
    try {
      expect(hasRecycleBin(f.path), isTrue); // 임시 폴더는 고정 디스크
      expect(moveToRecycleBin(f.path), RecycleResult.recycled);
      // 수를 세지 않고 휴지통 안의 정보 파일 ($I, 원래 경로) 로 확인할 수 있다
      expect(recycledInfoExists(f.absolute.path, since: DateTime.now().subtract(const Duration(minutes: 1))), isTrue);
      expect(f.existsSync(), isFalse);
      expect(moveToRecycleBin(d.path), RecycleResult.recycled);
      expect(d.existsSync(), isFalse);
      expect(moveToRecycleBin(p.join(tmp.path, 'none.txt')), RecycleResult.recycled);
    } finally {
      // 사용자 휴지통에 시험 항목을 남기지 않는다
      expect(await _purgeFromRecycleBin(tmp.absolute.path), 2);
    }
  }, skip: !Platform.isWindows);

  test('148: 휴지통으로 보낸 파일 · 폴더를 원래 자리로 되돌린다 (휴지통에 남지 않음) · 원래 자리에 같은 이름이 있으면 덮지 않음', () async {
    final tmp = Directory.systemTemp.createTempSync('jj_undo_');
    addTearDown(() async {
      await _purgeFromRecycleBin(tmp.absolute.path); // 실패해 남은 것이 있으면 사용자 휴지통에서 지운다
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });
    final since = DateTime.now().subtract(const Duration(seconds: 2));
    final f = File(p.join(tmp.absolute.path, 'undo.txt'))..writeAsStringSync('keep me');
    final d = Directory(p.join(tmp.absolute.path, 'undo_dir'))..createSync();
    File(p.join(d.path, 'a.txt')).writeAsStringSync('a');
    expect(moveToRecycleBin(f.path), RecycleResult.recycled);
    expect(moveToRecycleBin(d.path), RecycleResult.recycled);
    expect(f.existsSync() || d.existsSync(), isFalse);
    restoreFromRecycleBin(f.path, since: since);
    restoreFromRecycleBin(d.path, since: since);
    expect(f.readAsStringSync(), 'keep me');
    expect(File(p.join(d.path, 'a.txt')).readAsStringSync(), 'a');
    expect(recycledInfoExists(f.path, since: since), isFalse, reason: '휴지통에 남지 않음');
    // 원래 자리에 같은 이름이 생겼으면 덮지 않고 실패 (휴지통의 것은 그대로)
    expect(moveToRecycleBin(f.path), RecycleResult.recycled);
    f.writeAsStringSync('new one');
    expect(() => restoreFromRecycleBin(f.path, since: since), throwsA(isA<FileSystemException>()));
    expect(f.readAsStringSync(), 'new one');
    expect(recycledInfoExists(f.path, since: since), isTrue);
    // 휴지통에 없으면 실패
    expect(() => restoreFromRecycleBin(p.join(tmp.absolute.path, 'never.txt'), since: since), throwsA(isA<FileSystemException>()));
  }, skip: !Platform.isWindows);

  test('148: 원래 폴더가 그사이 지워졌으면 다시 만들지 않고 알린다 · 이 사용자 (SID) 의 휴지통에서만 찾는다', () async {
    expect(currentUserSid(), matches(RegExp(r'^S-1-5-')));
    final tmp = Directory.systemTemp.createTempSync('jj_undo_');
    addTearDown(() async {
      await _purgeFromRecycleBin(tmp.absolute.path);
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });
    final since = DateTime.now().subtract(const Duration(seconds: 2));
    final folder = Directory(p.join(tmp.absolute.path, 'gone'))..createSync();
    final f = File(p.join(folder.path, 'x.txt'))..writeAsStringSync('x');
    expect(moveToRecycleBin(f.path), RecycleResult.recycled);
    folder.deleteSync(); // 사용자가 그 폴더를 지움
    expect(
        () => restoreFromRecycleBin(f.path, since: since),
        throwsA(isA<FileSystemException>()
            .having((e) => e.message, 'message', contains('원래 폴더가 없어 되돌리지 못했습니다'))));
    expect(folder.existsSync(), isFalse, reason: '지운 폴더를 몰래 다시 만들지 않음');
    expect(recycledInfoExists(f.path, since: since), isTrue, reason: '휴지통의 것은 그대로');
  }, skip: !Platform.isWindows);

  test('긴 경로 (260자 넘음) 는 휴지통으로 보내지 않고 이유를 알린다 - 묻지 않고 영구 삭제되던 것 (폴더 안에 있어도)', () {
    if (!Platform.isWindows) return;
    // 긴 경로를 만들고 지우려면 앞에 \\?\ 를 붙인다
    String lp(String s) => r'\\?\' + s;
    final tmp = Directory.systemTemp.createTempSync('jj_rb_long_');
    addTearDown(() => Directory(lp(tmp.path)).deleteSync(recursive: true));
    var deep = p.join(tmp.path, 'outer');
    while (deep.length < 250) {
      deep = p.join(deep, 'd' * 30);
    }
    final file = p.join(deep, 'a_file_name_that_makes_it_longer.txt');
    Directory(lp(deep)).createSync(recursive: true);
    File(lp(file)).writeAsStringSync('x');
    expect(file.length, greaterThan(259));
    expect(longPathInside(file), file);
    expect(() => moveToRecycleBin(file), throwsA(isA<FileSystemException>().having((e) => e.message, 'message', contains('경로가 너무 깁니다'))));
    expect(File(lp(file)).existsSync(), isTrue, reason: '지우지 않음');
    // 폴더 자체는 짧아도 안에 긴 경로가 있으면
    final outer = p.join(tmp.path, 'outer');
    expect(longPathInside(outer), isNotNull);
    expect(() => moveToRecycleBin(outer), throwsA(isA<FileSystemException>()));
    expect(Directory(outer).existsSync(), isTrue);
    final short = File(p.join(tmp.path, 'short.txt'))..writeAsStringSync('x');
    expect(longPathInside(short.path), isNull, reason: '짧은 파일 경로');
  });

  test(r'휴지통 정보 파일 ($I) 에서 원래 경로 읽기 - Windows 10 이상 (판 2) · 예전 (판 1)', () {
    List<int> le(int v, int n) => [for (var i = 0; i < n; i++) v >> (8 * i) & 0xff];
    List<int> utf16(String s) => [for (final u in s.codeUnits) ...le(u, 2)];
    const path = r'C:\영상\a b.mkv';
    final v2 = [...le(2, 8), ...le(1234, 8), ...le(0, 8), ...le(path.length + 1, 4), ...utf16(path), 0, 0];
    expect(recycledInfoPath(v2), path);
    final v1 = [...le(1, 8), ...le(1234, 8), ...le(0, 8), ...utf16(path), ...List.filled(520 - path.length * 2, 0)];
    expect(recycledInfoPath(v1), path);
    expect(recycledInfoPath([9, 9, 9]), isNull);
    expect(recycledInfoPath([...le(7, 8), ...List.filled(40, 0)]), isNull);
  });

  test('94: 휴지통이 없는 곳 (네트워크 공유 · 없는 드라이브) 은 휴지통으로 보내지 않는다 · 98: 이유는 읽을 수 있는 말', () {
    expect(hasRecycleBin(r'\\NAS\share\a.mkv'), isFalse);
    // 쓰지 않는 드라이브 문자
    final unused = 'QRSTUVWXYZ'.split('').firstWhere((l) => !Directory('$l:\\').existsSync(), orElse: () => '');
    if (unused.isNotEmpty) expect(hasRecycleBin('$unused:\\a.mkv'), isFalse);
    expect(recycleErrorText(0x7C), contains('경로가 너무 깁니다'));
    expect(recycleErrorText(0x20), contains('다른 프로그램'));
    expect(recycleErrorText(0x12345), contains('0x12345'));
  }, skip: !Platform.isWindows);
}
