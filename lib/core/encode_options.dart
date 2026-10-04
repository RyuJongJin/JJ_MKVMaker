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

/// 출력 화면 비율 (파이널 컷의 프로젝트 화면 비율). 원본이 아니면 [FitChoice] 로 맞춘다.
enum FrameChoice {
  original('원본 비율', null),
  landscape('가로 16:9', 16 / 9),
  portrait('세로 9:16', 9 / 16),
  square('정사각 1:1', 1.0),
  portrait45('세로 4:5', 4 / 5);

  /// 한국어 원문 (번역 사전의 열쇠)
  final String koLabel;

  /// 화면에 보일 이름 (화면 언어로)
  String get label => tr(koLabel);

  /// 너비 / 높이 (원본이면 null)
  final double? aspect;
  const FrameChoice(this.koLabel, this.aspect);
}

/// 비율이 다를 때 맞추는 방법 (파이널 컷의 공간 맞추기: 채우기 · 맞추기)
enum FitChoice {
  fill('채우기 (가운데 잘라냄)'),
  fit('맞추기 (검은 여백)'),
  blur('맞추기 (흐린 배경)');

  /// 한국어 원문 (번역 사전의 열쇠)
  final String koLabel;

  /// 화면에 보일 이름 (화면 언어로)
  String get label => tr(koLabel);
  const FitChoice(this.koLabel);
}

/// 회전 (시계 방향)
enum RotateChoice {
  none('회전 없음', 0),
  cw90('오른쪽 90°', 90),
  r180('180°', 180),
  ccw90('왼쪽 90°', 270);

  /// 한국어 원문 (번역 사전의 열쇠)
  final String koLabel;

  /// 화면에 보일 이름 (화면 언어로)
  String get label => tr(koLabel);
  final int degrees;
  const RotateChoice(this.koLabel, this.degrees);

  /// 가로 · 세로가 바뀌는지
  bool get swaps => degrees == 90 || degrees == 270;
}

class EncodeSettings {
  final VideoCodecChoice codec;
  final ResolutionChoice resolution;
  final QualityChoice quality;

  /// 화면 비율 · 맞추는 방법 · 회전
  final FrameChoice frame;
  final FitChoice fit;
  final RotateChoice rotate;

  /// 색 보정 (-100 ~ 100, 0 = 그대로): 밝기 · 대비 · 채도 · 색온도 (+ 따뜻하게 / − 차갑게)
  final int brightness, contrast, saturation, temperature;

  const EncodeSettings({
    this.codec = VideoCodecChoice.copy,
    this.resolution = ResolutionChoice.original,
    this.quality = QualityChoice.normal,
    this.frame = FrameChoice.original,
    this.fit = FitChoice.fill,
    this.rotate = RotateChoice.none,
    this.brightness = 0,
    this.contrast = 0,
    this.saturation = 0,
    this.temperature = 0,
  });

  bool get reencode => codec != VideoCodecChoice.copy;

  /// 색 보정을 하는지
  bool get hasColor => brightness != 0 || contrast != 0 || saturation != 0 || temperature != 0;

  /// 화면 비율 · 회전 · 색 보정 중 하나라도 바꿨는지 (재인코딩이 필요함)
  bool get adjusts => frame != FrameChoice.original || rotate != RotateChoice.none || hasColor;

  /// 화면 비율 · 회전 · 색 보정을 처음으로
  EncodeSettings resetAdjust() => EncodeSettings(codec: codec, resolution: resolution, quality: quality);

  EncodeSettings copyWith({
    VideoCodecChoice? codec,
    ResolutionChoice? resolution,
    QualityChoice? quality,
    FrameChoice? frame,
    FitChoice? fit,
    RotateChoice? rotate,
    int? brightness,
    int? contrast,
    int? saturation,
    int? temperature,
  }) =>
      EncodeSettings(
        codec: codec ?? this.codec,
        resolution: resolution ?? this.resolution,
        quality: quality ?? this.quality,
        frame: frame ?? this.frame,
        fit: fit ?? this.fit,
        rotate: rotate ?? this.rotate,
        brightness: brightness ?? this.brightness,
        contrast: contrast ?? this.contrast,
        saturation: saturation ?? this.saturation,
        temperature: temperature ?? this.temperature,
      );

  /// 짧은 설명 ("세로 9:16 · 채우기 · 채도 +20"). 바꾼 것이 없으면 빈 글.
  String get adjustSummary => [
        if (frame != FrameChoice.original) '${frame.label} · ${fit.label}',
        if (rotate != RotateChoice.none) rotate.label,
        if (brightness != 0) '${tr('밝기')} ${_signed(brightness)}',
        if (contrast != 0) '${tr('대비')} ${_signed(contrast)}',
        if (saturation != 0) '${tr('채도')} ${_signed(saturation)}',
        if (temperature != 0) '${tr('색온도')} ${_signed(temperature)}',
      ].join(' · ');

  static String _signed(int v) => v > 0 ? '+$v' : '$v';
}

/// 영상 필터 (회전 → 색 보정 → 화면 비율 맞추기 → 크기). 바꿀 것이 없으면 null.
///
/// [source] 는 원본 영상 정보 (가로 · 세로 크기). [preview] 면 크기 바꾸기 ([ResolutionChoice]) 는 빼고
/// 미리보기용으로 작게 만든다.
String? buildVideoFilter(EncodeSettings s, StreamInfo? source, {bool preview = false}) {
  final f = <String>[];
  // 1. 회전
  switch (s.rotate) {
    case RotateChoice.cw90:
      f.add('transpose=1');
    case RotateChoice.ccw90:
      f.add('transpose=2');
    case RotateChoice.r180:
      f.add('hflip,vflip');
    case RotateChoice.none:
      break;
  }
  // 2. 색 보정: 밝기 · 대비 · 채도 (eq), 색온도 (colorbalance: 붉은색 ↔ 푸른색)
  if (s.brightness != 0 || s.contrast != 0 || s.saturation != 0) {
    String n(double v) => v.toStringAsFixed(3);
    f.add('eq=brightness=${n(s.brightness / 100 * 0.25)}'
        ':contrast=${n(1 + s.contrast / 100 * 0.5)}'
        ':saturation=${n(1 + s.saturation / 100)}');
  }
  if (s.temperature != 0) {
    final k = (s.temperature / 100 * 0.25).toStringAsFixed(3);
    final m = (-s.temperature / 100 * 0.25).toStringAsFixed(3);
    f.add('colorbalance=rs=$k:rm=$k:rh=$k:bs=$m:bm=$m:bh=$m');
  }
  // 회전 뒤의 원본 크기
  var w = source?.width, h = source?.height;
  if (s.rotate.swaps && w != null && h != null) (w, h) = (h, w);
  final side = preview ? null : s.resolution.shortSide;
  final aspect = s.frame.aspect;
  String? last;
  if (aspect != null) {
    // 3. 화면 비율: 짧은 변은 고른 크기 (없으면 원본의 짧은 변) 로, 긴 변은 비율대로 (짝수)
    final srcShort = (w != null && h != null) ? (w < h ? w : h) : 1080;
    final short = preview ? 360 : (side ?? srcShort);
    int even(double v) => (v / 2).round() * 2;
    final ow = aspect >= 1 ? even(short * aspect) : even(short.toDouble());
    final oh = aspect >= 1 ? even(short.toDouble()) : even(short / aspect);
    final cover = 'scale=$ow:$oh:force_original_aspect_ratio=increase:flags=lanczos,crop=$ow:$oh';
    final contain = 'scale=$ow:$oh:force_original_aspect_ratio=decrease:flags=lanczos';
    switch (s.fit) {
      case FitChoice.fill:
        f.add(cover);
      case FitChoice.fit:
        f.add('$contain,pad=$ow:$oh:(ow-iw)/2:(oh-ih)/2:black');
      case FitChoice.blur:
        // 같은 영상을 크게 채워 흐리게 깔고, 그 위에 전체가 보이게 얹는다
        last = 'split[jjbg][jjfg];[jjbg]$cover,boxblur=20:2[jjb];[jjfg]$contain[jjf];'
            '[jjb][jjf]overlay=(W-w)/2:(H-h)/2';
    }
  } else if (preview) {
    f.add('scale=480:480:force_original_aspect_ratio=decrease');
  } else if (side != null) {
    // 4. 크기만: 가로 영상은 높이, 세로 영상은 너비를 맞추고 다른 변은 비율 유지 (짝수)
    final portrait = w != null && h != null && h > w;
    f.add(portrait ? 'scale=$side:-2:flags=lanczos' : 'scale=-2:$side:flags=lanczos');
  }
  if (last != null) {
    // 흐린 배경은 여러 갈래라 앞의 필터를 이어 붙인 뒤 마지막에
    final head = f.isEmpty ? '' : '${f.join(',')},';
    return '$head$last,setsar=1';
  }
  if (f.isEmpty) return null;
  if (aspect != null) f.add('setsar=1');
  return f.join(',');
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
  final vf = buildVideoFilter(s, source);
  if (vf != null) args.addAll(['-vf', vf]);
  // 회전은 필터로 했으므로 원본의 회전 표시는 지운다
  if (s.rotate != RotateChoice.none) args.addAll(['-metadata:s:v:0', 'rotate=0']);
  return args;
}

/// 원본보다 큰 크기를 골랐는지 (화질 향상 없음 경고용)
bool isUpscale(ResolutionChoice r, StreamInfo? source) {
  final side = r.shortSide;
  if (side == null || source?.width == null || source?.height == null) return false;
  final srcShort = source!.width! < source.height! ? source.width! : source.height!;
  return side > srcShort;
}
