import 'package:path/path.dart' as p;

import 'languages.dart';

/// 외부 자막으로 인식하는 확장자
const subtitleExtensions = ['srt', 'ass', 'ssa', 'smi', 'sami', 'vtt'];

/// 선택 가능한 동영상 확장자
const videoExtensions = [
  'mkv', 'mp4', 'avi', 'mov', 'wmv', 'm4v', 'ts', 'm2ts', 'webm', 'flv', //
  // 29: 예전 캠코더 · 휴대폰 · DVD 형식도 (FFmpeg · 내장 플레이어가 연다)
  'mpg', 'mpeg', 'vob', '3gp', '3g2', 'mts', 'ogv', 'asf', //
];

/// 음악 (내장 플레이어로도 재생할 수 있게 - 29)
const audioExtensions = ['mp3', 'flac', 'm4a', 'aac', 'ogg', 'opus', 'wav', 'wma'];

/// 파일명 규칙 (확정 사항 2)
const aiSuffix = 'AI';

class DetectedSubtitle {
  final String path;
  final Language language;

  /// 파일명_AI.srt (음성인식 원본)
  final bool isAi;

  const DetectedSubtitle(this.path, this.language, {this.isAi = false});
}

/// 같은 폴더의 파일 목록에서 동영상과 짝이 되는 자막을 찾는다.
///
/// 인식 예: 영화.srt / 영화.ko.srt / 영화_ko.srt / 영화.korean.srt / 영화_AI.srt
List<DetectedSubtitle> findSiblingSubtitles(
    String videoPath, Iterable<String> filesInFolder) {
  final base = p.basenameWithoutExtension(videoPath).toLowerCase();
  final result = <DetectedSubtitle>[];

  for (final f in filesInFolder) {
    final ext = p.extension(f).replaceFirst('.', '').toLowerCase();
    if (!subtitleExtensions.contains(ext)) continue;

    final name = p.basenameWithoutExtension(f);
    final lower = name.toLowerCase();
    if (lower == base) {
      result.add(DetectedSubtitle(f, undetermined));
      continue;
    }
    if (!lower.startsWith(base)) continue;

    // 기본 이름 뒤 구분자(. _ -)로 시작하는 꼬리만 인정
    final tail = name.substring(base.length);
    if (tail.isEmpty || !'._-'.contains(tail[0])) continue;

    final tokens =
        tail.split(RegExp(r'[._\-\s]+')).where((t) => t.isNotEmpty).toList();
    if (tokens.isEmpty) continue;

    if (tokens.any((t) => t == aiSuffix || t.toLowerCase() == 'jj')) {
      result.add(DetectedSubtitle(f, undetermined, isAi: true));
      continue;
    }
    // zh-Hant 처럼 하이픈이 들어간 코드를 먼저 확인한 뒤,
    // 뒤쪽 토큰부터 언어 확인 (예: 영화.forced.ko)
    var lang = languageOf(tail.substring(1));
    for (final t in tokens.reversed) {
      if (lang != undetermined) break;
      lang = languageOf(t);
    }
    result.add(DetectedSubtitle(f, lang));
  }

  result.sort((a, b) => a.path.compareTo(b.path));
  return result;
}
