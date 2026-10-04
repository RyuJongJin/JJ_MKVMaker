import 'models.dart';
import '../l10n/tr.dart';

/// 영상 코덱 (기본 목록: 별도 설치·설정 없이 동봉 FFmpeg 로 인코딩)
enum VideoCodecChoice {
  copy('원본 유지 (재인코딩 없음)', []),
  h264('H.264', ['libx264']),
  h265('H.265 (HEVC)', ['libx265']),
  vp9('VP9', ['libvpx-vp9']),
  av1('AV1', ['libsvtav1', 'libaom-av1']), // SVT-AV1 이 있으면 우선 (더 빠름)
  mpeg4('MPEG-4 (Xvid)', ['libxvid', 'mpeg4']);

  /// 한국어 원문 (번역 사전의 열쇠)
  final String koLabel;

  /// 화면에 보일 이름 (화면 언어로)
  String get label => tr(koLabel);

  /// 사용할 FFmpeg 인코더 후보 (앞쪽 우선)
  final List<String> encoders;

  const VideoCodecChoice(this.koLabel, this.encoders);

  /// 사용 가능한 인코더 중 첫 번째 (없으면 null)
  String? pickEncoder(Set<String> available) {
    for (final e in encoders) {
      if (available.contains(e)) return e;
    }
    return null;
  }
}

/// 화면 크기 (짧은 변 기준 픽셀)
enum ResolutionChoice {
  original('원본 크기', null),
  p720('720p (HD)', 720),
  p1080('1080p (FHD)', 1080),
  k2('2K (1440p)', 1440),
  k4('4K (2160p)', 2160),
  k8('8K (4320p)', 4320);

  /// 한국어 원문 (번역 사전의 열쇠)
  final String koLabel;

  /// 화면에 보일 이름 (화면 언어로)
  String get label => tr(koLabel);
  final int? shortSide;

  const ResolutionChoice(this.koLabel, this.shortSide);
}

enum QualityChoice {
  high('고화질'),
  normal('표준'),
  small('작은 용량');

  /// 한국어 원문 (번역 사전의 열쇠)
  final String koLabel;

  /// 화면에 보일 이름 (화면 언어로)
  String get label => tr(koLabel);

  const QualityChoice(this.koLabel);
}

class EncodeSettings {
  final VideoCodecChoice codec;
  final ResolutionChoice resolution;
  final QualityChoice quality;

  const EncodeSettings({
    this.codec = VideoCodecChoice.copy,
    this.resolution = ResolutionChoice.original,
    this.quality = QualityChoice.normal,
  });

  bool get reencode => codec != VideoCodecChoice.copy;

  EncodeSettings copyWith({
    VideoCodecChoice? codec,
    ResolutionChoice? resolution,
    QualityChoice? quality,
  }) =>
      EncodeSettings(
        codec: codec ?? this.codec,
        resolution: resolution ?? this.resolution,
        quality: quality ?? this.quality,
      );
}

/// 영상 인코딩 인수 (-c:v 이하). 재인코딩하지 않으면 빈 목록.
///
/// [available] 은 FFmpeg 가 지원하는 인코더 이름 목록.
List<String> buildVideoEncodeArgs(
    EncodeSettings s, Set<String> available, StreamInfo? source) {
  if (!s.reencode) return const [];
  final enc = s.codec.pickEncoder(available);
  if (enc == null) {
    throw ArgumentError(trf('{0} 인코더가 FFmpeg 에 없습니다.', [s.codec.label]));
  }
  final q = s.quality.index; // 0 고화질, 1 표준, 2 작은 용량
  final args = <String>['-c:v', enc];

  switch (enc) {
    case 'libx264':
      args.addAll(['-preset', 'medium', '-crf', '${[18, 23, 28][q]}']);
    case 'libx265':
      args.addAll(['-preset', 'medium', '-crf', '${[22, 28, 32][q]}',
        '-x265-params', 'log-level=error']);
    case 'libvpx-vp9':
      args.addAll(['-b:v', '0', '-crf', '${[28, 33, 38][q]}',
        '-deadline', 'good', '-cpu-used', '4', '-row-mt', '1']);
    case 'libsvtav1':
      args.addAll(['-crf', '${[28, 35, 42][q]}', '-preset', '8']);
    case 'libaom-av1':
      args.addAll(['-b:v', '0', '-crf', '${[26, 32, 38][q]}',
        '-cpu-used', '6', '-row-mt', '1', '-tiles', '2x2']);
    case 'libxvid':
    case 'mpeg4':
      args.addAll(['-q:v', '${[2, 4, 6][q]}']);
  }
  args.addAll(['-pix_fmt', 'yuv420p']);

  final side = s.resolution.shortSide;
  if (side != null) {
    // 가로 영상은 높이, 세로 영상은 너비를 맞추고 다른 변은 비율 유지 (짝수)
    final portrait = source?.width != null &&
        source?.height != null &&
        source!.height! > source.width!;
    args.addAll(['-vf',
      portrait ? 'scale=$side:-2:flags=lanczos' : 'scale=-2:$side:flags=lanczos']);
  }
  return args;
}

/// 원본보다 큰 크기를 골랐는지 (화질 향상 없음 경고용)
bool isUpscale(ResolutionChoice r, StreamInfo? source) {
  final side = r.shortSide;
  if (side == null || source?.width == null || source?.height == null) return false;
  final srcShort = source!.width! < source.height! ? source.width! : source.height!;
  return side > srcShort;
}
