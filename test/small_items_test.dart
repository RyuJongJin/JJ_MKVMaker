import 'package:flutter_test/flutter_test.dart';
import 'package:jj_mkvmaker/app/app_controller.dart';
import 'package:jj_mkvmaker/app/copy_center.dart';
import 'package:jj_mkvmaker/app/settings.dart';
import 'package:jj_mkvmaker/core/download_detect.dart';
import 'package:jj_mkvmaker/core/encode_options.dart';
import 'package:jj_mkvmaker/core/sync_tools.dart';
import 'package:jj_mkvmaker/platform/windows/desktop_storage_service.dart';
import 'package:jj_mkvmaker/platform/windows/process_media_tool.dart';
import 'package:jj_mkvmaker/services/media_player.dart';
import 'package:jj_mkvmaker/services/platform_services.dart';

/// 작은 항목: 자막 글자 크기 · WebDAV 복사 창의 방법 표시
void main() {
  late AppController c;
  setUp(() => c = AppController(PlatformServices(mediaTool: ProcessMediaTool('x', 'y'), storage: DesktopStorageService())));

  test('자막 글자 크기: 설정에 남고 플레이어에 바로 반영', () async {
    await c.updateSettings((s) => s.subtitleScale = 1.5);
    expect(playerSubtitleScale.value, 1.5);
    expect(AppSettings.fromJson(c.settings.toJson()).subtitleScale, 1.5);
    expect(AppSettings.fromJson({'subtitleScale': 9}).subtitleScale, 2.5);
    expect(AppSettings.fromJson({}).subtitleScale, 1.0);
    await c.updateSettings((s) => s.subtitleScale = 1.0);
  });

  test('WebDAV 가 끼면 탐색기 복사 확인 창에 robocopy 가 아니라 실제 방법 (현재 방식)', () {
    c.settings.copyMethodFolder = 'robocopy';
    final t = CopyCenter.of(c).fresh(['dav://nas/a'], r'C:\dst');
    expect(CopyMethod.of(t.method), CopyMethod.builtin);
    // Rsync 화면 (방법을 정해서) 은 그대로
    expect(CopyCenter.of(c).fresh(['dav://nas/a'], r'C:\dst', method: 'rsync').method, 'rsync');
  });

  test('36: 같은 화질이면 H.264 먼저 - 설정 (PC 기본 꺼짐) · yt-dlp 인수', () {
    expect(AppSettings.fromJson({}).ytPreferH264, isFalse); // 시험은 PC (Android 는 기본 켜짐)
    expect(AppSettings.fromJson({'ytPreferH264': true}).ytPreferH264, isTrue);
    expect(AppSettings.fromJson((AppSettings()..ytPreferH264 = true).toJson()).ytPreferH264, isTrue);
    expect(ytDlpFormatArgs(YtContainer.mp4, YtQuality.best, preferH264: true).join(' '), contains('vcodec:h264'));
    expect(ytDlpFormatArgs(YtContainer.mp4, YtQuality.best).join(' '), isNot(contains('vcodec:h264')));
  });

  test('39: "모든 파일 접근" 시작 안내는 한 번만 (보였다는 표시가 설정에 남음)', () {
    expect(AppSettings.fromJson({}).allFilesHintShown, isFalse);
    expect(AppSettings.fromJson((AppSettings()..allFilesHintShown = true).toJson()).allFilesHintShown, isTrue);
  });

  test('103: 크기 때문에 저절로 H.264 로 바꾼 코덱은 원본 크기로 되돌리면 "원본 유지" 로 돌아온다 (직접 고른 코덱은 그대로)', () {
    c.setCodec(VideoCodecChoice.copy);
    c.setResolution(ResolutionChoice.k4);
    expect(c.encode.codec, VideoCodecChoice.h264);
    expect(c.encodeNotice, contains('H.264'));
    c.encodeNotice = null;
    c.setResolution(ResolutionChoice.original);
    expect(c.encode.codec, VideoCodecChoice.copy);
    expect(c.encodeNotice, contains('원본 유지'));
    // 직접 H.264 를 고른 경우는 되돌리지 않는다
    c.setCodec(VideoCodecChoice.h264);
    c.setResolution(ResolutionChoice.p1080);
    c.setResolution(ResolutionChoice.original);
    expect(c.encode.codec, VideoCodecChoice.h264);
  });
}
