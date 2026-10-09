import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jj_mkvmaker/app/download_manager.dart';
import 'package:jj_mkvmaker/app/i18n_controller.dart';
import 'package:jj_mkvmaker/app/settings.dart';
import 'package:jj_mkvmaker/core/download_detect.dart';
import 'package:jj_mkvmaker/services/downloader.dart';
import 'package:jj_mkvmaker/ui/downloads_page.dart';

class _Backend implements DownloadBackend {
  var starts = 0;
  @override
  DownloadKind get kind => DownloadKind.video;
  @override
  Future<(String, List<PlaylistEntry>)?> expandPlaylist(String url) async => null;
  @override
  Future<void> start(DownloadTask t, void Function() changed) async {
    starts++;
    t
      ..state = DownloadState.failed
      ..error = 'ERROR: [generic] Unable to download webpage: HTTP Error 404: Not Found '
          '(https://cdn.example.com/v.mp4?sig=SECRET123&expire=1)';
    changed();
  }

  @override
  Future<void> pause(DownloadTask t) async {}
  @override
  Future<void> cancel(DownloadTask t) async {}
  @override
  Future<void> shutdown() async {}
}

/// 136: 실패한 다운로드 줄 - 진행 막대 대신 실패 · 사람 말 이유 · [자세히] (원문) · [다시 시도]
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('yt-dlp · aria2 원문 → 사람 말 이유', () {
    expect(friendlyDownloadError('ERROR: [generic] x: HTTP Error 404: Not Found'), '주소에 영상이 없습니다 (404)');
    expect(friendlyDownloadError('ERROR: [vimeo] 1: HTTP Error 403: Forbidden'), '로그인이 필요합니다 (403)');
    expect(friendlyDownloadError('ERROR: Unsupported URL: https://example.com/'), '지원하지 않는 사이트입니다');
    expect(friendlyDownloadError('ERROR: [generic] Unable to download webpage: <urlopen error [Errno 11001] getaddrinfo failed>'),
        '연결할 수 없습니다');
    expect(friendlyDownloadError('Network problem has occurred. cause:Connection refused (errorCode=6)'), '연결할 수 없습니다');
    expect(friendlyDownloadError('Resource not found (errorCode=3)'), '주소에 영상이 없습니다 (404)');
    expect(friendlyDownloadError('There is not enough disk space available (errorCode=9)'), '저장 공간이 모자랍니다');
    expect(friendlyDownloadError('ERROR: [youtube] x: Sign in to confirm you’re not a bot'), contains('로봇 확인'));
    expect(friendlyDownloadError('무언가 이상함'), '받지 못했습니다');
  });

  test('화면 언어를 따른다 (59 와 같은 방식)', () async {
    await i18n.apply('ja', save: false);
    addTearDown(() => i18n.apply('ko', save: false));
    expect(friendlyDownloadError('HTTP Error 404: Not Found'), 'このアドレスに動画がありません (404)');
  });

  test('서명 · 키가 든 주소 부분은 가린다', () {
    expect(redactUrlSecrets('x https://cdn.example.com/v.mp4?sig=AAA&expire=1 y'), 'x https://cdn.example.com/v.mp4?… y');
    expect(redactUrlSecrets('(https://user:pw@nas.local/dav/a.mkv#t=1)'), '(https://nas.local/dav/a.mkv?…)');
    expect(redactUrlSecrets('https://www.youtube.com/watch'), 'https://www.youtube.com/watch');
  });

  testWidgets('실패한 줄: 진행 막대 ("준비 중…") 없이 이유 · [자세히] 는 원문 (주소의 서명은 가림) · [다시 시도]', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final b = _Backend();
    final d = DownloadManager(backends: [b], settings: () => AppSettings(), readClipboard: () async => null);
    final t = d.addPage('https://cdn.example.com/page')!..title = '영상';
    await tester.pumpWidget(MaterialApp(home: DownloadsPage(d: d)));
    for (var i = 0; i < 20 && t.state != DownloadState.failed; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(t.state, DownloadState.failed);
    await tester.pump();
    expect(find.text('준비 중…'), findsNothing);
    expect(find.byType(DownloadProgressBar), findsNothing);
    expect(find.textContaining('주소에 영상이 없습니다 (404)'), findsOneWidget);
    expect(find.textContaining('HTTP Error'), findsNothing, reason: '원문은 [자세히] 에서만');

    await tester.tap(find.text('자세히'));
    await tester.pumpAndSettle();
    expect(find.textContaining('HTTP Error 404'), findsOneWidget);
    expect(find.textContaining('SECRET123'), findsNothing, reason: '서명된 주소를 보이지 않음');
    await tester.tap(find.text('닫기'));
    await tester.pumpAndSettle();

    expect(b.starts, 1);
    await tester.tap(find.text('다시 시도'));
    for (var i = 0; i < 20 && b.starts < 2; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(b.starts, 2, reason: '[다시 시도] 로 다시 받기 시작 (이 가짜 백엔드는 또 실패)');
    d.dispose();
  });
}
