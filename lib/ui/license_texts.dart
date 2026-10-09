import 'dart:io';

import 'package:flutter/foundation.dart' show LicenseEntryWithLineBreaks, LicenseRegistry;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;

import '../core/ai_catalog.dart';
import '../l10n/tr.dart';
import 'theme.dart';

/// 62 · 63 · 64: 라이선스 원문 (assets/licenses - Windows 는 실행 파일 옆에도 같은 파일)
/// 64: 고지 문서는 플랫폼마다 (Android 에는 Windows 파일 이름 · 경로를 보이지 않게)
String get licenseNoticesAsset =>
    Platform.isAndroid ? 'assets/licenses/THIRD_PARTY_NOTICES_ANDROID.txt' : 'assets/licenses/THIRD_PARTY_NOTICES.txt';

/// 앱 안 라이선스 화면 (showLicensePage) 에 넣을 것: (구성 요소들, 원문 asset)
List<(List<String>, String)> get _licenseAssets => [
  (['JJ_MKVMaker - THIRD_PARTY_NOTICES'], licenseNoticesAsset),
  (
    [
      'FFmpeg (Windows ffmpeg.exe 9.0.2 · Android FFmpegKit n8.1.2)',
      'yt-dlp (실행 파일 yt-dlp.exe)',
      'rsync',
      'FFmpegKit (ffmpeg_kit_flutter_new_min_gpl)',
      'youtubedl-android',
      'H2Orestart 0.7.14',
    ],
    'assets/licenses/GPL-3.0.txt'
  ),
  (['aria2'], 'assets/licenses/GPL-2.0.txt'),
  (['libmpv (media_kit, LGPL-2.1+)'], 'assets/licenses/LGPL-2.1.txt'),
  (['yt-dlp (실행 파일에 묶인 구성 요소)'], 'assets/licenses/YT-DLP_THIRD_PARTY_LICENSES.txt'),
  (['rsync'], 'assets/licenses/RSYNC_COPYING.txt'),
  (['PDFium'], 'assets/licenses/PDFIUM_LICENSES.txt'),
  // 175: 함께 빌드한 네이티브 라이브러리 (Dart 쪽 패키지 라이선스와 따로)
  (['whisper.cpp · ggml (whisper_ggml 안)'], 'assets/licenses/WHISPER_CPP_LICENSE.txt'),
  (['ONNX Runtime 1.15.1 (Microsoft)'], 'assets/licenses/ONNXRUNTIME_LICENSES.txt'),
  (['Whisper 모델 (OpenAI)'], 'assets/licenses/WHISPER_MODEL_LICENSE.txt'),
  (['NLLB-200 번역 모델 (CC BY-NC 4.0 · 비상업적 이용만)'], nllbLicenseAsset),
];

/// main 에서 한 번: 위 원문과 AI 구성 요소 · 모델 (OpenRAIL-M 용도 제한 포함) 을 라이선스 화면에
void registerAppLicenses() {
  LicenseRegistry.addLicense(() async* {
    for (final (name, text, asset) in aiLicenseTexts()) {
      var full = text;
      if (asset != null) {
        try {
          full = '$text\n\n${await rootBundle.loadString(asset)}';
        } catch (_) {}
      }
      yield LicenseEntryWithLineBreaks([name], full);
    }
    for (final (names, asset) in _licenseAssets) {
      try {
        yield LicenseEntryWithLineBreaks(names, await rootBundle.loadString(asset));
      } catch (_) {}
    }
  });
}

/// [고지 문서]: THIRD_PARTY_NOTICES 를 앱 안에서 (Windows · Android 같은 화면)
Future<void> showNoticesDocument(BuildContext context) => showLicenseDocument(context, tr('고지 문서'), licenseNoticesAsset);

/// 라이선스 원문 한 편을 앱 안에서 (175: AI 받기 화면의 [원문])
Future<void> showLicenseDocument(BuildContext context, String title, String asset) async {
  String text;
  try {
    text = await rootBundle.loadString(asset);
  } catch (e) {
    text = '$e';
  }
  if (!context.mounted) return;
  await Navigator.of(context).push(MaterialPageRoute<void>(
    builder: (_) => Scaffold(
      appBar: AppBar(title: Text(title)),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: SelectableText(text, style: const TextStyle(fontFamily: 'monospace', fontSize: 12, height: 1.4)),
      ),
    ),
  ));
}

/// NLLB-200 번역 모델 (처음 쓸 때 받음) 의 라이선스 원문 - CC BY-NC 4.0
const nllbLicenseAsset = 'assets/licenses/NLLB_CC_BY_NC_4.0.txt';

/// 175: NLLB 를 받는 곳 (AI 자막 · 번역 · 화면 언어 더하기) 에 "비상업적 이용만 허용" 과 [원문]
class NllbLicenseNote extends StatelessWidget {
  const NllbLicenseNote({super.key});

  @override
  Widget build(BuildContext context) => Wrap(crossAxisAlignment: WrapCrossAlignment.center, children: [
        Text(tr('번역 모델 라이선스: CC BY-NC 4.0 (비상업적 이용만 허용)'),
            style: const TextStyle(fontSize: 11, color: JjColors.textDim)),
        TextButton(
          style: TextButton.styleFrom(visualDensity: VisualDensity.compact, padding: const EdgeInsets.symmetric(horizontal: 6)),
          onPressed: () => showLicenseDocument(context, 'CC BY-NC 4.0', nllbLicenseAsset),
          child: Text(tr('원문')),
        ),
      ]);
}
