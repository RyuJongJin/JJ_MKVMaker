import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jj_mkvmaker/core/file_ops.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('jj_fileops_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  File file(String rel, [String text = 'x']) =>
      File(p.join(tmp.path, rel))
        ..parent.createSync(recursive: true)
        ..writeAsStringSync(text);

  test('폴더 읽기: 숨은 항목 · 정렬 (폴더 먼저, 숫자는 크기로, 크기 · 거꾸로)', () async {
    file('a/ep10.mkv', '1234567890');
    file('a/ep2.mkv', '12');
    file('a/.hidden');
    Directory(p.join(tmp.path, 'a', 'zfolder')).createSync();
    final dir = p.join(tmp.path, 'a');

    final list = await listEntries(dir);
    expect(list.map((e) => e.name), isNot(contains('.hidden')));
    expect((await listEntries(dir, showHidden: true)).map((e) => e.name), contains('.hidden'));

    expect(sortEntries(list, SortBy.name).map((e) => e.name), ['zfolder', 'ep2.mkv', 'ep10.mkv']);
    // 거꾸로여도 폴더는 위
    expect(sortEntries(list, SortBy.size, descending: true).map((e) => e.name), ['zfolder', 'ep10.mkv', 'ep2.mkv']);
    final e = list.firstWhere((x) => x.name == 'ep10.mkv');
    expect([e.ext, e.size, e.isDir], ['mkv', 10, false]);
  });

  test('복사: 폴더째 · 같은 이름은 "이름 (2)" · 진행률 · 자기 안으로는 안 됨', () async {
    file('src/movie.mp4', 'abcdef');
    file('src/sub/s.srt', 'sub');
    file('dst/movie.mp4', 'old');
    final dst = p.join(tmp.path, 'dst');
    var last = 0;
    final made = await FileOps().copy(
        [p.join(tmp.path, 'src', 'movie.mp4'), p.join(tmp.path, 'src', 'sub')], dst,
        onProgress: (_, done, total) {
      last = done;
      expect(total, 9);
    });
    expect(made.map(p.basename), ['movie (2).mp4', 'sub']);
    expect(File(p.join(dst, 'movie (2).mp4')).readAsStringSync(), 'abcdef');
    expect(File(p.join(dst, 'movie.mp4')).readAsStringSync(), 'old');
    expect(File(p.join(dst, 'sub', 's.srt')).readAsStringSync(), 'sub');
    expect(last, 9);
    expect(() => FileOps().copy([p.join(tmp.path, 'src')], p.join(tmp.path, 'src', 'sub')),
        throwsA(isA<FileSystemException>()));
  });

  test('이동 · 삭제 · 이름 바꾸기 · 새 폴더', () async {
    final f = file('a/x.mkv', 'video');
    final b = Directory(p.join(tmp.path, 'b'))..createSync();
    final moved = await FileOps().move([f.path], b.path);
    expect(File(moved.single).readAsStringSync(), 'video');
    expect(f.existsSync(), isFalse);
    // 이미 그 폴더에 있으면 그대로
    expect(await FileOps().move([moved.single], b.path), [moved.single]);

    final renamed = await FileOps.rename(moved.single, 'y.mkv');
    expect(p.basename(renamed), 'y.mkv');
    expect(() => FileOps.rename(renamed, 'bad/name'), throwsA(isA<FileSystemException>()));
    file('b/z.mkv');
    expect(() => FileOps.rename(renamed, 'z.mkv'), throwsA(isA<FileSystemException>()));

    final folder = await FileOps.makeFolder(b.path, '새 폴더');
    expect(Directory(folder).existsSync(), isTrue);
    expect(() => FileOps.makeFolder(b.path, '새 폴더'), throwsA(isA<FileSystemException>()));

    await FileOps().delete([b.path]);
    expect(b.existsSync(), isFalse);
  });

  test('빈 폴더 지우기 (find -type d -empty -delete): 안쪽부터 · 파일 있는 폴더는 그대로 · 원본 폴더 남김 / 지움', () async {
    final root = p.join(tmp.path, 'src');
    Directory(p.join(root, 'a', 'b', 'c')).createSync(recursive: true);
    Directory(p.join(root, 'empty')).createSync();
    file('src/keep/x.txt');
    expect(await removeEmptyDirs(root), 4); // a/b/c, a/b, a, empty
    expect(Directory(p.join(root, 'keep')).existsSync(), isTrue);
    expect(Directory(p.join(root, 'a')).existsSync(), isFalse);
    File(p.join(root, 'keep', 'x.txt')).deleteSync();
    expect(await removeEmptyDirs(root), 1); // keep (원본 폴더는 남김)
    expect(Directory(root).existsSync(), isTrue);
    expect(await removeEmptyDirs(root, keepRoot: false), 1); // 원본 폴더도
    expect(Directory(root).existsSync(), isFalse);
    expect(await removeEmptyDirs(root), 0); // 없으면 아무것도
  });

  test('시작 전 확인: 없는 원본 · 없는 대상 · 자기 안으로 · 같은 폴더로 이동', () {
    final a = Directory(p.join(tmp.path, 'a'))..createSync();
    final inner = Directory(p.join(a.path, 'inner'))..createSync();
    final f = File(p.join(tmp.path, 'f.txt'))..writeAsStringSync('f');
    final other = Directory(p.join(tmp.path, 'other'))..createSync();
    expect(transferProblem([a.path, f.path], other.path, move: false), isNull);
    expect(transferProblem([a.path], other.path, move: true), isNull);
    expect(transferProblem([p.join(tmp.path, 'gone')], other.path, move: false), contains('원본이 없습니다'));
    expect(transferProblem([a.path], p.join(tmp.path, 'nowhere'), move: false), contains('대상 폴더가 없습니다'));
    expect(transferProblem([a.path], a.path, move: false), contains('자기 자신 안으로'));
    expect(transferProblem([a.path], inner.path, move: true), contains('자기 자신 안으로'));
    expect(transferProblem([f.path], tmp.path, move: true), contains('이미 이 폴더에'));
    expect(transferProblem([f.path], tmp.path, move: false), isNull); // 같은 폴더에 복사는 "이름 (2)"
  });

  test('복사 취소: 만들던 파일을 지우고 FileOpCancelled', () async {
    final big = file('big.bin', 'x' * (2 * 1024 * 1024));
    final dst = Directory(p.join(tmp.path, 'dst'))..createSync();
    final ops = FileOps();
    final f = ops.copy([big.path], dst.path, onProgress: (_, done, _) {
      if (done > 0) ops.cancel();
    });
    await expectLater(f, throwsA(isA<FileOpCancelled>()));
    expect(dst.listSync(), isEmpty);
  });

  test('찾기: 하위 폴더까지 · 대소문자 무시 · * 사용', () async {
    file('a/Movie One.mkv');
    file('a/b/movie two.mp4');
    file('a/b/notes.txt');
    final all = await searchFiles(tmp.path, 'MOVIE').map((e) => e.name).toList();
    expect(all.toSet(), {'Movie One.mkv', 'movie two.mp4'});
    expect(await searchFiles(tmp.path, '*.txt').map((e) => e.name).toList(), ['notes.txt']);
    expect(await searchFiles(tmp.path, '').toList(), isEmpty);
  });

  test('같은 경로 · 안쪽 판단, 크기 글자', () {
    final a = p.join(tmp.path, 'a');
    expect(samePath(a, '$a${Platform.pathSeparator}'), isTrue);
    expect(isSameOrInside(p.join(a, 'b'), a), isTrue);
    expect(isSameOrInside(a, p.join(a, 'b')), isFalse);
    expect(formatSize(500), '500B');
    expect(formatSize(1536), '2KB');
    expect(formatSize(5 * 1024 * 1024), '5.0MB');
    expect(formatSize(3 * 1024 * 1024 * 1024), '3.0GB');
  });
}
