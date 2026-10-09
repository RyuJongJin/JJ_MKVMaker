import 'dart:io';

import 'package:flutter/foundation.dart' show LicenseRegistry;
import 'package:flutter_test/flutter_test.dart';
import 'package:jj_mkvmaker/ui/license_texts.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('62 · 63 · 64: GPL · LGPL 원문 · 고지 문서 · PDFium · yt-dlp 가 라이선스 화면에', () async {
    registerAppLicenses();
    final entries = await LicenseRegistry.licenses.toList();
    String find(String name) {
      final e = entries.firstWhere((e) => e.packages.any((p) => p.startsWith(name)));
      return e.paragraphs.map((p) => p.text).join('\n');
    }

    expect(find('aria2'), contains('GNU GENERAL PUBLIC LICENSE'));
    expect(find('aria2'), contains('Version 2'));
    expect(find('H2Orestart'), contains('Version 3, 29 June 2007'));
    expect(find('libmpv'), contains('LESSER GENERAL PUBLIC LICENSE'));
    expect(find('PDFium'), contains('The PDFium Authors'));
    expect(find('yt-dlp (실행 파일에 묶인'), contains('THIRD-PARTY LICENSES'));
    final notices = find('JJ_MKVMaker');
    for (final s in ['GPL-3.0-or-later', 'yt-dlp 2026', 'chromium/7811', 'H2Orestart/tree/v0.7.14', 'rsync-3.5.1.tar.gz',
        'ffmpeg-9.0.2', 'Android 판은 위의 GPLv3']) {
      expect(notices, contains(s));
    }
  });

  test('Windows 설치: 실행 파일 옆 · tools · rsync 에 원문을 둔다 (CMake)', () {
    final cmake = File('windows/CMakeLists.txt').readAsStringSync();
    expect(cmake, contains('assets/licenses'));
    expect(cmake, contains('YT-DLP_THIRD_PARTY_LICENSES.txt'));
    expect(cmake, contains('RSYNC_COPYING.txt'));
    for (final f in ['THIRD_PARTY_NOTICES.txt', 'GPL-2.0.txt', 'GPL-3.0.txt', 'LGPL-2.1.txt', 'PDFIUM_LICENSES.txt']) {
      expect(File('assets/licenses/$f').existsSync(), true, reason: f);
    }
  });
}
