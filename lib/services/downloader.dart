import '../core/download_detect.dart';

enum DownloadState { queued, downloading, paused, done, failed, cancelled }

/// 다운로드 한 건
class DownloadTask {
  final String id;
  final DownloadKind kind;
  final String source;
  final String dir;
  final DateTime added = DateTime.now();

  String title;
  DownloadState state = DownloadState.queued;

  /// 0.0~1.0, 알 수 없으면 null
  double? progress;
  /// 받은 크기 · 전체 크기 (바이트, 모르면 null)
  int? receivedBytes;
  int? totalBytes;
  String speed = '';
  String eta = '';
  String? error;

  /// 만들어진(또는 만들고 있는) 파일
  final Set<String> files = {};

  /// 백엔드가 쓰는 값 (aria2 gid 등)
  final Map<String, Object?> extra = {};

  DownloadTask({required this.id, required this.kind, required this.source, required this.dir})
      : title = source;

  bool get unfinished =>
      state == DownloadState.queued || state == DownloadState.downloading || state == DownloadState.paused;

  /// 재생목록을 불러오는 중인 임시 항목 (다 불러오면 영상별 항목으로 바뀜)
  bool expanding = false;
}

/// 다운로드 엔진 경계.
/// Windows: yt-dlp.exe 프로세스 / aria2c.exe RPC  (platform/windows)
/// Android: (이식 시) youtubedl-android · aria2 안드로이드 빌드
/// 재생목록 안의 항목
class PlaylistEntry {
  final String url;
  final String title;
  const PlaylistEntry(this.url, this.title);
}

abstract class DownloadBackend {
  DownloadKind get kind;

  /// 재생목록이면 (목록 이름, 항목들). 재생목록이 아니거나 지원하지 않으면 null.
  Future<(String, List<PlaylistEntry>)?> expandPlaylist(String url);

  /// 시작 (또는 일시정지 후 다시 시작). 상태가 바뀔 때마다 [changed] 호출.
  Future<void> start(DownloadTask t, void Function() changed);

  Future<void> pause(DownloadTask t);

  /// 중지하고 받던 파일 삭제
  Future<void> cancel(DownloadTask t);

  /// 앱 종료 시 모두 중지
  Future<void> shutdown();
}
