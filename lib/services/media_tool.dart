import '../core/models.dart';

/// 진행률 콜백 (0.0 ~ 1.0)
typedef ProgressCallback = void Function(double progress);

class MediaToolException implements Exception {
  final String message;
  const MediaToolException(this.message);
  @override
  String toString() => message;
}

/// FFmpeg / FFprobe 실행 경계.
///
/// Windows: 동봉한 ffmpeg.exe 를 프로세스로 실행
/// Android: (이식 시) 앱에 포함한 FFmpeg 라이브러리로 구현
abstract class MediaTool {
  /// 사용 가능 여부와 버전 문자열
  Future<String?> version();

  Future<MediaInfo> probe(String path);

  /// 사용 가능한 인코더 이름 목록 (libx264, libx265 ...)
  Future<Set<String>> encoders();

  /// FFmpeg 실행. [duration] 이 있으면 진행률을 계산해 [onProgress] 로 알린다.
  Future<void> runFfmpeg(
    List<String> args, {
    Duration? duration,
    ProgressCallback? onProgress,
  });

  /// 실행 중인 작업 취소
  void cancel();
}
