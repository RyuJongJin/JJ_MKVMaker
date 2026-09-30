import 'package:path/path.dart' as p;

import 'languages.dart';

/// ffprobe 로 읽은 스트림 정보
class StreamInfo {
  final int index;
  final String type; // video / audio / subtitle / attachment / data
  final String codec;
  final String language; // MKV 태그 원본 (kor 등), 없으면 ''
  final String? title;
  final bool isDefault;
  final int? width;
  final int? height;

  const StreamInfo({
    required this.index,
    required this.type,
    required this.codec,
    this.language = '',
    this.title,
    this.isDefault = false,
    this.width,
    this.height,
  });
}

class MediaInfo {
  final Duration? duration;
  final List<StreamInfo> streams;

  const MediaInfo({this.duration, this.streams = const []});

  Iterable<StreamInfo> ofType(String type) =>
      streams.where((s) => s.type == type);
}

enum SubtitleKind { embedded, external }

/// 출력 MKV 에 들어갈 자막 1개 (내장 트랙 또는 외부 파일)
class SubtitleEntry {
  final SubtitleKind kind;

  /// 외부 자막 파일 경로
  final String? path;

  /// 내장 자막의 원본 스트림 번호
  final int? streamIndex;

  /// 코덱 (subrip, ass, mov_text ...) 또는 외부 파일 확장자 (srt, smi ...)
  final String codec;

  Language language;
  String? title;

  /// 외부 텍스트 자막의 문자셋 (UTF-8, CP949 ...)
  String? charset;

  /// false 이면 출력에서 제외 (= 삭제)
  bool enabled;

  SubtitleEntry.embedded({
    required int this.streamIndex,
    required this.codec,
    required this.language,
    this.title,
    this.enabled = true,
  })  : kind = SubtitleKind.embedded,
        path = null;

  SubtitleEntry.external({
    required String this.path,
    required this.language,
    this.charset,
    this.title,
    this.enabled = true,
  })  : kind = SubtitleKind.external,
        streamIndex = null,
        codec = p.extension(path).replaceFirst('.', '').toLowerCase();

  String get displayName => kind == SubtitleKind.external
      ? p.basename(path!)
      : '트랙 #$streamIndex ($codec)${title != null ? ' - $title' : ''}';
}

enum JobStatus { ready, running, done, failed }

class VideoItem {
  final String path;
  MediaInfo? info;
  final List<SubtitleEntry> subtitles = [];
  JobStatus status = JobStatus.ready;
  double progress = 0;

  /// 진행 중인 단계 설명 (예: "음성인식 중")
  String? phase;
  String? message;
  String? outputPath;

  VideoItem(this.path);

  String get fileName => p.basename(path);
  String get directory => p.dirname(path);
  String get baseName => p.basenameWithoutExtension(path);
}
