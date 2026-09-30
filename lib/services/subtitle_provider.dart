import 'dart:typed_data';

import '../core/subtitle_search.dart';

class SubtitleProviderException implements Exception {
  final String message;
  const SubtitleProviderException(this.message);
  @override
  String toString() => message;
}

/// 인터넷 자막 사이트 경계 (OpenSubtitles 등). 검색·다운로드만 하고 업로드는 하지 않는다.
abstract class SubtitleProvider {
  String get name;

  /// 사용 준비 여부 (API 키 등)
  bool get configured;

  /// 설정 안내 (configured 가 false 일 때 화면에 표시)
  String get setupHint;

  Future<List<SubtitleSearchResult>> search(SubtitleQuery q);

  /// 자막 파일 내용
  Future<Uint8List> download(SubtitleSearchResult r);
}
