import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jj_mkvmaker/core/download_detect.dart';
import 'package:jj_mkvmaker/platform/windows/ytdlp_backend.dart';
import 'package:jj_mkvmaker/services/downloader.dart';
import 'package:path/path.dart' as p;

/// 실제 yt-dlp 로 짧은 YouTube 영상을 받아 진행률 · 크기가 중간에도 나오는지 확인
/// 실행: JJ_NET_TESTS=1 flutter test test/ytdlp_net_test.dart  (인터넷 · third_party 도구 필요)
void main() {
  test('실제 다운로드: 진행률이 중간값을 거치고, 받은 크기 / 전체 크기가 나온다', () async {
    if (Platform.environment['JJ_NET_TESTS'] != '1') return markTestSkipped('JJ_NET_TESTS=1 일 때만');
    final tools = p.join(Directory.current.path, 'third_party', 'tools', 'windows');
    final ffmpeg = p.join(Directory.current.path, 'third_party', 'ffmpeg', 'windows');
    final dir = Directory.systemTemp.createTempSync('jj_ytnet_');
    addTearDown(() => dir.deleteSync(recursive: true));

    final backend = YtDlpBackend(
      ytdlp: p.join(tools, 'yt-dlp.exe'),
      deno: p.join(tools, 'deno.exe'),
      ffmpegDir: ffmpeg,
      formatArgs: () => ytDlpFormatArgs(YtContainer.mp4, YtQuality.p360),
    );
    final t = DownloadTask(
        id: '1', kind: DownloadKind.video, source: 'https://www.youtube.com/watch?v=jNQXAC9IVRw', dir: dir.path);
    final seen = <(double, int?, int?)>[];
    await backend.start(t, () {
      if (t.state == DownloadState.downloading && t.progress != null) {
        seen.add((t.progress!, t.receivedBytes, t.totalBytes));
      }
    });
    // ignore: avoid_print
    print('RESULT ${t.state} ${t.error ?? ''} 단계 ${seen.length}개: '
        '${seen.where((s) => seen.indexOf(s) % 4 == 0).map((s) => '${(s.$1 * 100).round()}% ${s.$2}/${s.$3}').join(', ')}');
    expect(t.state, DownloadState.done, reason: t.error);
    // 진행률이 줄어들지 않고 (영상 → 음성으로 넘어갈 때 0 으로 돌아가지 않음), 중간값이 있다
    for (var i = 1; i < seen.length; i++) {
      expect(seen[i].$1, greaterThanOrEqualTo(seen[i - 1].$1 - 1e-9));
    }
    expect(seen.where((s) => s.$1 > 0.05 && s.$1 < 0.95), isNotEmpty);
    expect(seen.last.$3, isNotNull);
    expect(t.totalBytes, greaterThan(100000));
    expect(t.receivedBytes, t.totalBytes);
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('실제 다운로드: 고른 브라우저의 쿠키를 못 읽으면 쿠키 없이 다시 받는다', () async {
    if (Platform.environment['JJ_NET_TESTS'] != '1') return markTestSkipped('JJ_NET_TESTS=1 일 때만');
    final tools = p.join(Directory.current.path, 'third_party', 'tools', 'windows');
    final dir = Directory.systemTemp.createTempSync('jj_ytnet2_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final backend = YtDlpBackend(
      ytdlp: p.join(tools, 'yt-dlp.exe'),
      deno: p.join(tools, 'deno.exe'),
      ffmpegDir: p.join(Directory.current.path, 'third_party', 'ffmpeg', 'windows'),
      formatArgs: () => ytDlpFormatArgs(YtContainer.mp4, YtQuality.p360),
      // 없는 프로필 → "could not find ... cookies database"
      cookieArgs: () => ['--cookies-from-browser', 'firefox:${p.join(dir.path, 'no_such_profile')}'],
    );
    final t = DownloadTask(
        id: '1', kind: DownloadKind.video, source: 'https://www.youtube.com/watch?v=jNQXAC9IVRw', dir: dir.path);
    await backend.start(t, () {});
    // ignore: avoid_print
    print('RESULT ${t.state} stage=${t.extra['cookieStage']} ${t.error ?? ''}');
    expect(t.state, DownloadState.done, reason: t.error);
    expect(t.extra['cookieStage'], 2);
  }, timeout: const Timeout(Duration(minutes: 3)));
}
