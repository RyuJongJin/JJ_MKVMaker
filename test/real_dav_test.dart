import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jj_mkvmaker/core/file_ops.dart';
import 'package:jj_mkvmaker/core/vfs.dart';
import 'package:jj_mkvmaker/core/webdav.dart';
import 'package:path/path.dart' as p;

/// 실제 WebDAV 서버 (예: wsgidav · NAS) 로 확인. JJ_REAL_DAV=주소 (JJ_REAL_DAV_USER · JJ_REAL_DAV_PASS) 일 때만.
/// 서버의 맨 위에 jj_real_dav_test 폴더를 만들고 끝나면 지운다.
void main() {
  final url = Platform.environment['JJ_REAL_DAV'];
  final skip = url == null ? 'JJ_REAL_DAV 일 때만' : null;
  const id = 'real';
  const top = 'dav://$id/jj_real_dav_test';
  late Directory tmp;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('jj_real_dav_');
    DavRegistry.configure([
      DavServer(id: id, name: 'real', url: url!, user: Platform.environment['JJ_REAL_DAV_USER'] ?? '',
          password: Platform.environment['JJ_REAL_DAV_PASS'] ?? ''),
    ]);
    if (await vExists(top)) await vDelete(top);
    await vMkdirs(top);
  });
  tearDown(() async {
    if (await vExists(top)) await vDelete(top);
    DavRegistry.configure([]);
    tmp.deleteSync(recursive: true);
  });

  test('실제 서버: 올리기 · 목록 · 동기화 · 이름 바꾸기 · 이동 · 받기 · 지우기 (한글 · 빈칸 이름)', () async {
    final src = Directory(p.join(tmp.path, '원본 폴더'));
    File(p.join(src.path, 'a b.txt'))
      ..createSync(recursive: true)
      ..writeAsStringSync('aa');
    File(p.join(src.path, '하위', '큰.bin'))
      ..createSync(recursive: true)
      ..writeAsBytesSync(List.filled(3 << 20, 7));
    final ops = FileOps();
    expect(await ops.copy([src.path], top), ['$top/원본 폴더']);
    final list = sortEntries(await listEntries('$top/원본 폴더'), SortBy.name);
    expect(list.map((e) => (e.name, e.isDir, e.size)), [('하위', true, 0), ('a b.txt', false, 2)]);
    expect((await vStat('$top/원본 폴더/하위/큰.bin'))!.size, 3 << 20);
    // 동기화: 바뀐 것 없음 → 0, 하나 바꾸면 1
    expect(await ops.mirror(src.path, '$top/원본 폴더'), 0);
    File(p.join(src.path, 'a b.txt')).writeAsStringSync('aaaa');
    expect(await ops.mirror(src.path, '$top/원본 폴더'), 1);
    // 이름 바꾸기 · 같은 서버 안 이동
    expect(await FileOps.rename('$top/원본 폴더/a b.txt', '새 이름.txt'), '$top/원본 폴더/새 이름.txt');
    await FileOps.makeFolder(top, '상자');
    await ops.move(['$top/원본 폴더/하위'], '$top/상자');
    expect(await vIsDir('$top/상자/하위'), isTrue);
    expect(await vExists('$top/원본 폴더/하위'), isFalse);
    // 받기 (원격 → 로컬 동기화 · 임시로 받기)
    final back = p.join(tmp.path, 'back');
    expect(await ops.mirror(top, back), 2);
    expect(File(p.join(back, '원본 폴더', '새 이름.txt')).readAsStringSync(), 'aaaa');
    expect(await ops.mirror(top, back), 0);
    final got = await vLocalCopy('$top/상자/하위/큰.bin', p.join(tmp.path, 'cache'));
    expect(File(got).lengthSync(), 3 << 20);
    expect(await vCountFiles(top), 2);
    // 빈 폴더 정리 · 지우기
    await vMkdirs('$top/빈/더 빈');
    expect(await removeEmptyDirs(top, keepRoot: true), 2);
    await ops.delete(['$top/상자']);
    expect(await vExists('$top/상자'), isFalse);
  }, skip: skip, timeout: const Timeout(Duration(minutes: 3)));
}
