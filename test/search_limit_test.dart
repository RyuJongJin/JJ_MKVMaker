import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jj_mkvmaker/core/file_ops.dart';
import 'package:path/path.dart' as p;

/// 24: 찾기 - 한도에서 멈추고, 읽지 못한 폴더를 알린다
void main() {
  test('한도 개수에서 멈춤 · 읽지 못한 폴더는 onSkipped 로', () async {
    final tmp = Directory.systemTemp.createTempSync('jj_search_');
    addTearDown(() => tmp.deleteSync(recursive: true));
    for (var i = 0; i < 30; i++) {
      File(p.join(tmp.path, 'ep$i.mkv')).writeAsStringSync('');
    }
    final found = await searchFiles(tmp.path, 'ep', limit: 10).toList();
    expect(found, hasLength(10));

    final skipped = <String>[];
    final none = await searchFiles(p.join(tmp.path, 'gone'), 'ep', onSkipped: (d, _) => skipped.add(d)).toList();
    expect(none, isEmpty);
    expect(skipped, [p.join(tmp.path, 'gone')]);
  });
}
