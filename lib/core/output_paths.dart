import 'package:path/path.dart' as p;

import 'languages.dart';
import 'subtitle_detector.dart';

/// 출력 폴더명
const outputFolderName = 'jj_mkv';

/// 환경 설정의 저장 위치. null 이면 동영상이 있는 폴더 아래 jj_mkv (기본)
String? outputRootOverride;

String outputDirFor(String videoPath) =>
    p.join(outputRootOverride ?? p.dirname(videoPath), outputFolderName);

/// jj_mkv/동일파일명.mkv
String outputMkvPath(String videoPath) => p.join(
    outputDirFor(videoPath), '${p.basenameWithoutExtension(videoPath)}.mkv');

/// jj_mkv/파일명_AI.srt (음성인식 원본)
String aiSubtitlePath(String videoPath) => p.join(outputDirFor(videoPath),
    '${p.basenameWithoutExtension(videoPath)}_$aiSuffix.srt');

/// jj_mkv/파일명_ko.srt (언어별)
String languageSubtitlePath(String videoPath, Language lang) => p.join(
    outputDirFor(videoPath),
    '${p.basenameWithoutExtension(videoPath)}_${lang.code}.srt');
