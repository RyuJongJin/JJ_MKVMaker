import 'package:flutter_test/flutter_test.dart';
import 'package:jj_mkvmaker/app/app_controller.dart';
import 'package:jj_mkvmaker/core/playlist.dart';
import 'package:jj_mkvmaker/platform/windows/desktop_storage_service.dart';
import 'package:jj_mkvmaker/platform/windows/process_media_tool.dart';
import 'package:jj_mkvmaker/services/platform_services.dart';

/// 29: 예전 동영상 형식 (mpg · vob · 3gp ...) 은 동영상으로, 음악은 내장 플레이어로도
void main() {
  test('형식 알아보기', () {
    for (final f in ['a.mpg', 'b.MPEG', 'c.vob', 'd.3gp', 'e.mts', 'f.ogv']) {
      expect(isVideoFile(f), isTrue, reason: f);
    }
    for (final f in ['a.mp3', 'b.FLAC', 'c.m4a', 'd.opus']) {
      expect(isAudioFile(f), isTrue, reason: f);
      expect(isVideoFile(f), isFalse, reason: f);
    }
  });

  test('음악도 내장 플레이어 재생 목록에 들어간다', () async {
    final c = AppController(PlatformServices(mediaTool: ProcessMediaTool('x', 'y'), storage: DesktopStorageService()));
    final plan = await c.preparePlayback([r'C:\m\song.mp3'], internal: true);
    expect(plan?.$1, [r'C:\m\song.mp3']);
  });

  outputFolderPickTests();
}

class _PickStorage extends DesktopStorageService {
  final List<String> picked;
  _PickStorage(this.picked);
  @override
  Future<List<String>> pickVideos() async => picked;
}

/// 33: 직접 고른 파일은 jj_mkv (결과) 폴더 안에 있어도 MKV 목록에 넣는다
void outputFolderPickTests() {
  test('파일 고르기로 고른 jj_mkv 안의 파일도 들어간다', () async {
    final out = r'C:\v\jj_mkv\a.mkv';
    final c = AppController(PlatformServices(mediaTool: ProcessMediaTool('x', 'y'), storage: _PickStorage([out])));
    await c.pickVideos();
    expect(c.videos.map((v) => v.path), [out]);
    // 폴더째 넣는 경우 (allowOutputFolder 없음) 는 예전처럼 건너뜀
    final c2 = AppController(PlatformServices(mediaTool: ProcessMediaTool('x', 'y'), storage: DesktopStorageService()));
    await c2.addVideos([out]);
    expect(c2.videos, isEmpty);
  });
}
