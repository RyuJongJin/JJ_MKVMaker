import 'encode_options.dart';
import 'models.dart';
import 'languages.dart';
import '../l10n/tr.dart';

/// MKV 에 그대로 복사 가능한 자막 코덱
const _copyableSubtitleCodecs = {
  'subrip', 'ass', 'ssa', 'hdmv_pgs_subtitle', 'dvd_subtitle', 'dvb_subtitle',
  'webvtt', //
};

/// 외부 파일 확장자 → 출력 자막 코덱 (MKV 는 UTF-8 텍스트만 허용하므로 항상 재인코딩)
String _externalCodec(String ext) => switch (ext) {
      'ass' || 'ssa' => 'ass',
      _ => 'srt', // srt, smi, sami, vtt
    };

/// 기본 자막으로 표시할 언어 (MKV 태그). 61: 화면 언어를 따른다 (예전에는 늘 한국어 'kor').
/// 화면 언어가 자막 언어 목록에 없으면 한국어.
String get preferredDefaultLanguage {
  final l = languageOf(uiLanguage);
  return l == undetermined ? 'kor' : l.mkv;
}

/// 동영상 + 자막 → MKV 로 합치는 FFmpeg 인수.
///
/// [encode] 가 재인코딩이면 영상은 선택한 코덱·크기로 인코딩하고, 음성은 항상 그대로 복사한다.
///
/// [utf8Copies]: UTF-8 로 바꿔 둔 외부 자막 사본 (원래 항목 → 사본 경로). 사본은 문자셋 지정 없이 읽는다.
List<String> buildMuxArgs(
  VideoItem video,
  String outputPath, {
  EncodeSettings encode = const EncodeSettings(),
  Set<String> encoders = const {},
  Map<SubtitleEntry, String> utf8Copies = const {},
}) {
  final externals = video.subtitles
      .where((s) => s.enabled && s.kind == SubtitleKind.external)
      .toList();
  final embedded = video.subtitles
      .where((s) => s.enabled && s.kind == SubtitleKind.embedded)
      .toList();

  final args = <String>['-hide_banner', '-nostdin', '-y'];

  // 입력 0: 동영상
  args.addAll(['-i', video.path]);

  // 입력 1..n: 외부 자막 (-sub_charenc 는 입력 옵션이므로 -i 앞에 둔다)
  for (final s in externals) {
    final copy = utf8Copies[s];
    final cs = s.charset;
    // UTF-8 / UTF-16(BOM) 은 FFmpeg 가 스스로 처리
    if (copy == null && cs != null && !cs.startsWith('UTF-')) {
      args.addAll(['-sub_charenc', cs]);
    }
    args.addAll(['-i', copy ?? s.path!]);
  }

  // 영상(표지 그림 제외)·음성 트랙 전부, 첨부 파일(폰트) 유지
  args.addAll(['-map', '0:V?', '-map', '0:a?']);
  for (final s in embedded) {
    args.addAll(['-map', '0:${s.streamIndex}']);
  }
  for (var i = 0; i < externals.length; i++) {
    args.addAll(['-map', '${i + 1}:0']);
  }
  args.addAll(['-map', '0:t?']);

  args.addAll(['-c', 'copy']);
  args.addAll(buildVideoEncodeArgs(
      encode, encoders, video.info?.ofType('video').firstOrNull));

  // 출력 자막 순서: 내장 → 외부
  final ordered = [...embedded, ...externals];
  final defaultIdx = _pickDefault(ordered);
  for (var j = 0; j < ordered.length; j++) {
    final s = ordered[j];
    final codec = s.kind == SubtitleKind.external
        ? _externalCodec(s.codec)
        : (_copyableSubtitleCodecs.contains(s.codec) ? 'copy' : 'srt');
    args.addAll(['-c:s:$j', codec]);
    args.addAll(['-metadata:s:s:$j', 'language=${s.language.mkv}']);
    final title = s.title ?? (s.language.code == 'und' ? null : s.language.name);
    if (title != null) args.addAll(['-metadata:s:s:$j', 'title=$title']);
    args.addAll(['-disposition:s:$j', j == defaultIdx ? 'default' : '0']);
  }

  args.addAll(['-progress', 'pipe:1', '-nostats', outputPath]);
  return args;
}

/// 이미지 자막 (텍스트 편집 불가)
const bitmapSubtitleCodecs = {
  'hdmv_pgs_subtitle', 'dvd_subtitle', 'dvb_subtitle', 'xsub', //
};

/// 자막(내장 트랙 또는 smi/ass/vtt 파일) → UTF-8 SRT 로 변환하는 인수.
/// [streamIndex] 가 없으면 입력 파일의 첫 자막을 사용한다.
List<String> buildToSrtArgs({
  required String input,
  required String output,
  int? streamIndex,
  String? charset,
}) =>
    [
      '-hide_banner', '-nostdin', '-y',
      if (charset != null && !charset.startsWith('UTF-')) ...['-sub_charenc', charset],
      '-i', input,
      '-map', streamIndex == null ? '0:s:0' : '0:$streamIndex',
      '-c:s', 'srt', output,
    ];

int _pickDefault(List<SubtitleEntry> subs) {
  if (subs.isEmpty) return -1;
  final i = subs.indexWhere((s) => s.language.mkv == preferredDefaultLanguage);
  return i >= 0 ? i : 0;
}
