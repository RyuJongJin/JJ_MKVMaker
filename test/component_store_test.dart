import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jj_mkvmaker/app/component_store.dart';
import 'package:path/path.dart' as p;

/// 실제 설치 (LibreOffice 373MB 받기 · 풀기 · H2Orestart · 문서 → PDF): JJ_COMPONENTS_URL=목록 주소 일 때만.
/// JJ_COMPONENTS_DIR 를 주면 그 폴더에 설치하고 남긴다 (여러 번 시험할 때 다시 받지 않게).
void main() {
  test('components.json 읽기: 기기별 파일 · 없는 기기는 null', () {
    final m = ComponentManifest.parse('''
{"format":1,"components":{"docs":{"version":"x","windows":[{"name":"a.msi","kind":"msi","url":"https://e/a.msi","sha256":"AB"}]}}}''');
    expect(m.version('docs'), 'x');
    final f = m.files('docs', 'windows')!.single;
    expect([f.name, f.kind, f.sha256], ['a.msi', 'msi', 'ab']);
    expect(m.files('docs', 'android'), isNull);
    expect(m.files('nope', 'windows'), isNull);
  });

  final url = Platform.environment['JJ_COMPONENTS_URL'];
  test('실제 설치: LibreOffice + H2Orestart → DOCX · HWPX 를 PDF 로', () async {
    final keep = Platform.environment['JJ_COMPONENTS_DIR'];
    final data = keep ?? Directory.systemTemp.createTempSync('jj_comp_').path;
    final store = ComponentStore(data, manifestUrl: url!);
    if (!store.isInstalled('docs')) {
      var last = '';
      await store.install('docs', onProgress: (step, d) {
        final s = '$step ${d == null ? '' : (d * 100).floor()}';
        if (s != last && (d == null || (d * 100).floor() % 10 == 0)) debugPrint(s);
        last = s;
      });
    }
    expect(store.isInstalled('docs'), isTrue);
    expect(store.soffice(), isNotNull);
    // 시험 문서: LibreOffice 로 텍스트 → DOCX 를 만든 뒤 다시 PDF 로
    final tmp = Directory.systemTemp.createTempSync('jj_doc_');
    final txt = File(p.join(tmp.path, 'hello.txt'))..writeAsStringSync('안녕하세요 JJ 문서 미리보기');
    final pdf = await store.convertToPdf(txt.path, p.join(tmp.path, 'out'));
    expect(File(pdf).lengthSync(), greaterThan(1000));
    final hwp = Platform.environment['JJ_HWP_FILE'];
    if (hwp != null) {
      final out = await store.convertToPdf(hwp, p.join(tmp.path, 'out'));
      expect(File(out).lengthSync(), greaterThan(1000));
    }
    tmp.deleteSync(recursive: true);
    if (keep == null) await store.remove('docs');
  }, skip: url == null ? 'JJ_COMPONENTS_URL 일 때만' : null, timeout: const Timeout(Duration(minutes: 30)));
}
