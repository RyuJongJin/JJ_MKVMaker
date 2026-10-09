import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jj_mkvmaker/core/file_ops.dart' show SourceUnreadableException;
import 'package:jj_mkvmaker/core/sync_preview.dart';
import 'package:path/path.dart' as p;

/// 72: Rsync 실행 전 비교
void main() {
  late Directory tmp;
  late String a, b;
  final old = DateTime(2020), newer = DateTime(2024);
  void f(String dir, String rel, String text, DateTime t) => (File(p.join(dir, rel))
        ..createSync(recursive: true)
        ..writeAsStringSync(text))
      .setLastModifiedSync(t);
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('jj_preview_');
    a = p.join(tmp.path, 'a');
    b = p.join(tmp.path, 'b');
    f(a, 'new.txt', 'n', newer); // 왼쪽에만
    f(a, 'sub/changed.txt', 'left', newer); // 양쪽, 왼쪽이 새것
    f(b, 'sub/changed.txt', 'r', old);
    f(a, 'same.txt', 's', old);
    f(b, 'same.txt', 's', old);
    f(a, 'leftold.txt', 'aaaa', old); // 양쪽, 오른쪽이 새것
    f(b, 'leftold.txt', 'bb', newer);
    f(b, 'only_b.txt', 'o', old); // 오른쪽에만
    f(b, 'half.mkv.jjpart', 'x', old); // 만들다 만 파일은 세지 않음
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  Map<String, PreviewAction> m(List<PreviewItem> xs) => {for (final x in xs) x.rel: x.action};

  test('옵션: --delete · -u 알아보기', () {
    expect(optionsDelete('-avPog --delete'), isTrue);
    expect(optionsDelete('-avPog --delete-after'), isTrue);
    expect(optionsDelete('-avPog'), isFalse);
    expect(optionsUpdate('-avPogu'), isTrue);
    expect(optionsUpdate('-avPog --update'), isTrue);
    expect(optionsUpdate('-avPog'), isFalse);
    // 97: --del (--delete-during 별칭) 도 지우기
    expect(optionsDelete('-avPog --del'), isTrue);
    expect(optionsDelete('-avPog --delete-excluded'), isTrue);
    expect(withoutDeleteOptions('-av --del --delete-after -u'), '-av -u');
    // 106: 따옴표는 그대로 (제외할 폴더가 둘로 갈라지지 않게)
    expect(withoutDeleteOptions('-av --exclude="My Folder" --delete'), '-av --exclude="My Folder"');
    expect(withoutDeleteOptions("-av --exclude='a b' --del"), "-av --exclude='a b'");
  });

  test('→ 지우기 없이: 새로 · 바뀜 · 받는 쪽에만 있음 (그대로)', () async {
    final r = m(await previewSync(a, b, toRight: true));
    expect(r, {
      'new.txt': PreviewAction.add,
      'sub/changed.txt': PreviewAction.update,
      'leftold.txt': PreviewAction.update,
      'only_b.txt': PreviewAction.onlyTarget,
    });
  });

  test('→ --delete -u: 받는 쪽에만 있는 것은 지워짐 · 받는 쪽이 새것이면 건너뜀', () async {
    final r = m(await previewSync(a, b, toRight: true, delete: true, update: true));
    expect(r['only_b.txt'], PreviewAction.delete);
    expect(r.containsKey('leftold.txt'), isFalse);
    expect(r.containsKey('half.mkv.jjpart'), isFalse);
  });

  test('⇄: 한쪽에만 있는 것은 서로 건너가고, 다른 파일은 새것 쪽에서 (한 번만)', () async {
    final xs = await previewBoth(a, b);
    final r = {for (final x in xs) x.rel: (x.action, x.toRight)};
    expect(r, {
      'new.txt': (PreviewAction.add, true),
      'sub/changed.txt': (PreviewAction.update, true),
      'leftold.txt': (PreviewAction.update, false),
      'only_b.txt': (PreviewAction.add, false),
    });
  });

  test('93: 원본 폴더를 읽지 못하면 비교 실패 (지우는 실행을 막는다)', () async {
    await expectLater(previewSync(p.join(tmp.path, 'none'), b, toRight: true, delete: true),
        throwsA(isA<SourceUnreadableException>()));
  });

  test('⇄ + --delete: 먼저 도는 → 에서 오른쪽에만 있는 것이 지워지고 ← 로 건너가지 않는다', () async {
    final r = {for (final x in await previewBoth(a, b, delete: true)) x.rel: (x.action, x.toRight)};
    expect(r['only_b.txt'], (PreviewAction.delete, true));
    expect(r['new.txt'], (PreviewAction.add, true));
  });
}
