import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'languages.dart';

/// 인터넷 자막 검색 조건
class SubtitleQuery {
  final String title;
  final int? year;
  final int? season;
  final int? episode;

  /// OpenSubtitles 영상 해시 (같은 파일용 자막을 정확히 찾음)
  final String? movieHash;
  final List<Language> languages;

  const SubtitleQuery({
    required this.title,
    this.year,
    this.season,
    this.episode,
    this.movieHash,
    this.languages = const [],
  });
}

/// 검색 결과 한 건
class SubtitleSearchResult {
  final String provider;
  final String id;

  /// 받을 때 쓰는 값 (OpenSubtitles file_id 등)
  final String fileId;
  final Language language;
  final String release;
  final String fileName;
  final int downloads;
  final double rating;

  /// 영상 해시가 일치 = 이 파일에 맞춘 자막
  final bool hashMatch;
  final bool machineTranslated;
  final bool hearingImpaired;
  final String? uploader;
  final String? featureTitle;

  const SubtitleSearchResult({
    required this.provider,
    required this.id,
    required this.fileId,
    required this.language,
    required this.release,
    this.fileName = '',
    this.downloads = 0,
    this.rating = 0,
    this.hashMatch = false,
    this.machineTranslated = false,
    this.hearingImpaired = false,
    this.uploader,
    this.featureTitle,
  });
}

/// 정렬: 해시 일치 → 사람이 만든 자막 → 다운로드 수
List<SubtitleSearchResult> rankResults(Iterable<SubtitleSearchResult> list) {
  final out = list.toList();
  int score(SubtitleSearchResult r) => (r.hashMatch ? 1 : 0) * 2 + (r.machineTranslated ? 0 : 1);
  out.sort((a, b) {
    final s = score(b).compareTo(score(a));
    return s != 0 ? s : b.downloads.compareTo(a.downloads);
  });
  return out;
}

/// 파일명 → 검색 조건 추정
///
/// 예) "The.Matrix.1999.1080p.BluRay.x264-GROUP.mkv" → 제목 "The Matrix", 1999
///     "Breaking.Bad.S02E05.720p.WEB-DL.mkv" → 제목 "Breaking Bad", 시즌 2, 에피소드 5
SubtitleQuery guessQuery(String videoPath, {List<Language> languages = const []}) {
  var name = p.basenameWithoutExtension(videoPath);
  // [그룹] (메모) 제거
  name = name.replaceAll(RegExp(r'\[[^\]]*\]|\{[^}]*\}'), ' ');
  name = name.replaceAll(RegExp(r'[._]+'), ' ');

  int? season, episode, year;
  var cut = name.length;

  final se = RegExp(r'\b[Ss](\d{1,2})[ ._-]?[Ee](\d{1,3})\b').firstMatch(name) ??
      RegExp(r'\b(\d{1,2})x(\d{2,3})\b').firstMatch(name);
  if (se != null) {
    season = int.parse(se[1]!);
    episode = int.parse(se[2]!);
    cut = se.start;
  }
  final y = RegExp(r'[(\s]((?:19|20)\d{2})[)\s]').firstMatch('$name ');
  if (y != null && y.start < cut) {
    year = int.parse(y[1]!);
    cut = y.start;
  }
  // 화질·코덱 등 릴리스 정보가 시작되는 곳에서 자름
  final junk = RegExp(
      r'\b(2160p|1080p|1080i|720p|480p|4k|uhd|hdr|bluray|blu-ray|brrip|bdrip|web-?dl|webrip|hdtv|dvdrip|x264|x265|h264|h265|hevc|aac|ac3|dts|remux|proper|repack|extended|unrated)\b',
      caseSensitive: false).firstMatch(name);
  if (junk != null && junk.start < cut) cut = junk.start;

  final title = name.substring(0, cut).replaceAll(RegExp(r'[()\-]+\s*$'), '').replaceAll(RegExp(r'\s+'), ' ').trim();
  return SubtitleQuery(
    title: title.isEmpty ? p.basenameWithoutExtension(videoPath) : title,
    year: year,
    season: season,
    episode: episode,
    languages: languages,
  );
}

/// OpenSubtitles 영상 해시: 파일 크기 + 앞 64KB + 뒤 64KB 의 64비트 합 (16자리 16진수)
///
/// [head], [tail] 은 각각 파일 앞·뒤 최대 65536 바이트.
String openSubtitlesHash(int fileSize, Uint8List head, Uint8List tail) {
  final mask = BigInt.parse('FFFFFFFFFFFFFFFF', radix: 16);
  var hash = BigInt.from(fileSize);
  BigInt sum(Uint8List b) {
    var s = BigInt.zero;
    final bd = ByteData.sublistView(b);
    for (var i = 0; i + 8 <= b.length; i += 8) {
      s += BigInt.from(bd.getUint32(i, Endian.little)) +
          (BigInt.from(bd.getUint32(i + 4, Endian.little)) << 32);
    }
    return s;
  }

  hash = (hash + sum(head) + sum(tail)) & mask;
  return hash.toRadixString(16).padLeft(16, '0');
}

/// 받은 자막 저장 경로 규칙: 파일명_언어코드.srt (이미 쓰는 이름이면 _2, _3 …)
String nextFreeName(String base, Set<String> used) {
  if (!used.contains(base.toLowerCase())) return base;
  final ext = p.extension(base);
  final stem = base.substring(0, base.length - ext.length);
  for (var n = 2;; n++) {
    final c = '${stem}_$n$ext';
    if (!used.contains(c.toLowerCase())) return c;
  }
}
