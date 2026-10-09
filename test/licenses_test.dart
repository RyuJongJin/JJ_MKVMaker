import 'dart:io';

import 'package:flutter/foundation.dart' show LicenseRegistry;
import 'package:flutter_test/flutter_test.dart';
import 'package:jj_mkvmaker/core/ai_catalog.dart';
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
    expect(entries.any((e) => e.packages.any((p) => p.contains('LibreOffice'))), false, reason: 'LGPL 은 libmpv 이름으로');
    expect(find('PDFium'), contains('The PDFium Authors'));
    expect(find('yt-dlp (실행 파일에 묶인'), contains('THIRD-PARTY LICENSES'));
    final notices = find('JJ_MKVMaker');
    for (final s in ['GPL-3.0-or-later', 'yt-dlp 2026', 'chromium/7811', 'H2Orestart/tree/v0.7.14', 'rsync-3.5.1.tar.gz',
        'ffmpeg-9.0.2', 'Android 판은 위의 GPLv3']) {
      expect(notices, contains(s));
    }
  });

  test('175: MIT · BSD 항목은 저작권 줄과 허가 문구 원문을 함께 (이름 · 주소 한 줄이 아니라)', () async {
    registerAppLicenses();
    final entries = await LicenseRegistry.licenses.toList();
    String find(String name) {
      final e = entries.firstWhere((e) => e.packages.any((p) => p.startsWith(name)), orElse: () => throw 'no entry: $name');
      return e.paragraphs.map((p) => p.text).join('\n');
    }

    const mit = 'Permission is hereby granted';
    const bsd = 'Redistribution and use';
    // (라이선스 화면 이름, 꼭 있어야 할 저작권 줄, 허가 문구)
    final want = [
      ('stable-diffusion.cpp', 'Copyright (c) 2023 leejet', mit),
      ('stable-diffusion.cpp', 'The ggml authors', mit), // 함께 묶인 ggml
      ('stable-diffusion.cpp', 'Copyright (c) 2010, Google Inc.', bsd), // libwebp · libwebm
      ('stable-diffusion.cpp', 'K.Kosako', bsd), // Oniguruma
      ('stable-diffusion.cpp', 'Niels Lohmann', mit), // nlohmann/json
      ('stable-diffusion.cpp', 'Rich Geldreich', mit), // miniz
      ('stable-diffusion.cpp', 'Sean Barrett', mit), // stb
      ('whisper.cpp', 'The ggml authors', mit),
      ('ONNX Runtime', 'Copyright (c) Microsoft Corporation', mit),
      ('Whisper 모델', 'Copyright (c) 2022 OpenAI', mit),
      ('TAESD', 'Ollin Boer Bohan', mit),
      ('Real-ESRGAN x4plus (사진)', 'Copyright (c) 2021, Xintao Wang', bsd),
      ('Real-ESRGAN x4plus anime', 'Copyright (c) 2021, Xintao Wang', bsd),
    ];
    for (final (name, copyright, grant) in want) {
      final t = find(name);
      expect(t, contains(copyright), reason: name);
      expect(t, contains(grant), reason: name);
    }
    // OpenRAIL 계열은 원문 (부속서 A 의 용도 제한까지)
    expect(find('Stable Diffusion v1.5'), contains('Attachment A'));
    expect(find('Stable Diffusion v1.5'), contains('Copyright (c) 2022 Robin Rombach'));
    expect(find('LCM-LoRA'), contains('CreativeML Open RAIL++-M'));
    expect(find('LCM-LoRA'), contains('Attachment A'));
    // NLLB: CC BY-NC 4.0 원문 (비상업적 이용만)
    expect(find('NLLB-200'), contains('Attribution-NonCommercial 4.0 International'));
    expect(find('NLLB-200'), contains('NonCommercial means not primarily intended for or directed towards'));
  });

  test('175: AI 받기 목록의 MIT · BSD · OpenRAIL 파일은 원문 asset 이 있고, 그 파일이 실제로 있다', () {
    for (final f in aiCatalog) {
      if (f.license.contains('NVIDIA')) continue; // CUDA 런타임: NVIDIA EULA (주소)
      expect(f.licenseAsset, isNotNull, reason: f.id);
      expect(File(f.licenseAsset!).existsSync(), isTrue, reason: f.licenseAsset);
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

  test('64: Android 고지 문서에는 Windows 파일 · 경로가 없고 [패키지 라이선스] 로 안내', () {
    final a = File('assets/licenses/THIRD_PARTY_NOTICES_ANDROID.txt').readAsStringSync();
    for (final w in ['libmpv-2.dll', 'flutter_assets', '.exe', r'tools\', r'ffmpeg\']) {
      expect(a, isNot(contains(w)), reason: w);
    }
    expect(a, contains('[패키지 라이선스]'));
    expect(a, contains('GPLv3'));
  });
}
