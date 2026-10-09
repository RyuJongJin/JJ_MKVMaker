import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jj_mkvmaker/app/download_manager.dart';
import 'package:jj_mkvmaker/app/settings.dart';
import 'package:jj_mkvmaker/core/download_detect.dart';
import 'package:jj_mkvmaker/services/downloader.dart';
import 'package:jj_mkvmaker/ui/downloads_page.dart';

class _Backend implements DownloadBackend {
  @override
  final DownloadKind kind;
  _Backend(this.kind);
  @override
  Future<(String, List<PlaylistEntry>)?> expandPlaylist(String url) async => null;
  @override
  Future<void> start(DownloadTask t, void Function() changed) async {
    t
      ..state = DownloadState.downloading
      ..progress = 0.4
      ..speed = '1.2MB/s'
      ..title = t.kind == DownloadKind.video ? '테스트 영상' : '리눅스 ISO';
    changed();
  }

  @override
  Future<void> pause(DownloadTask t) async => t.state = DownloadState.paused;
  @override
  Future<void> cancel(DownloadTask t) async => t.state = DownloadState.cancelled;
  @override
  Future<void> shutdown() async {}
}

void main() {
  DownloadManager make() => DownloadManager(
        backends: [_Backend(DownloadKind.video), _Backend(DownloadKind.torrent)],
        settings: () => AppSettings()..downloadRoot = r'D:\dl',
        readClipboard: () async => null,
      );

  testWidgets('다운로드 목록: 추가 · 전체 선택 · 일시정지 · 완료 정리', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final d = make();

    await tester.pumpWidget(MaterialApp(home: DownloadsPage(d: d)));
    expect(find.textContaining('다운로드가 없습니다'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'https://youtu.be/AAA111');
    await tester.tap(find.text('추가'));
    await tester.pump();
    d.add('magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567');
    await tester.pump();
    expect(find.text('테스트 영상'), findsOneWidget);
    expect(find.text('리눅스 ISO'), findsOneWidget);
    // 진행 막대 안에 퍼센트, 아래에 상태 · 속도
    expect(find.byType(DownloadProgressBar), findsNWidgets(2));
    expect(find.text('40.0%'), findsNWidgets(2));
    expect(find.textContaining('받는 중  ·  1.2MB/s'), findsNWidgets(2));

    await tester.tap(find.text('전체 선택'));
    await tester.pump();
    expect(find.text('2개 선택'), findsOneWidget);
    await tester.tap(find.text('일시정지'));
    await tester.pump();
    expect(d.tasks.every((t) => t.state == DownloadState.paused), isTrue);

    d.tasks.first.state = DownloadState.done;
    d.tasks.last.progress = null; // 진행률을 모르는 상태 (마그넷 정보 받는 중 등)
    d.tasks.last.state = DownloadState.downloading;
    d.selectNone(); // 화면 갱신
    await tester.pump();
    expect(find.text('100.0%'), findsOneWidget); // 완료는 가득 찬 막대
    expect(find.text('준비 중…'), findsOneWidget);
    await tester.tap(find.text('완료 정리'));
    await tester.pump();
    expect(d.tasks, hasLength(1));

    // 44: [다운로드 취소] 는 일시정지 · 재개와 떨어져 있고, 누르면 묻는다 ([취소] 면 그대로)
    await tester.tap(find.text('전체 선택'));
    await tester.pump();
    expect(tester.getTopLeft(find.text('다운로드 취소')).dx - tester.getTopRight(find.text('재개')).dx, greaterThan(16));
    await tester.tap(find.text('다운로드 취소'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('선택한 다운로드 1개를 취소할까요? 잠깐 멈추려면 [일시정지] 를 쓰세요.'), findsOneWidget);
    await tester.tap(find.text('취소'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(d.tasks.single.state, DownloadState.downloading);
    await tester.tap(find.text('다운로드 취소'));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.widgetWithText(FilledButton, '다운로드 취소'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(d.tasks.single.state, DownloadState.cancelled);
  });

  testWidgets('종료: 다운로드 중이면 목록 → 종료 → 확인 메시지', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final d = make();
    bool? result;

    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (ctx) => TextButton(
          onPressed: () async => result = await confirmExit(ctx, d),
          child: const Text('X'),
        ),
      ),
    ));

    // 다운로드 없으면 바로 종료
    await tester.tap(find.text('X'));
    await tester.pumpAndSettle();
    expect(result, isTrue);

    d.add('https://youtu.be/AAA111');
    d.add('https://youtu.be/BBB222');
    await tester.pump();
    result = null;
    await tester.tap(find.text('X'));
    await tester.pumpAndSettle();
    expect(find.text('받는 중인 다운로드 2개'), findsOneWidget);

    // 목록에서 하나 삭제
    await tester.tap(find.byTooltip('삭제 (중지하고 받던 파일 삭제)').first);
    await tester.pumpAndSettle();
    expect(find.text('받는 중인 다운로드 1개'), findsOneWidget);

    // 종료 → 확인 메시지 → 취소 (다운로드 목록 유지)
    await tester.tap(find.widgetWithText(FilledButton, '종료'));
    await tester.pumpAndSettle();
    expect(find.text('다운로드를 종료하시겠습니까?'), findsOneWidget);
    await tester.tap(find.text('취소'));
    await tester.pumpAndSettle();
    expect(find.text('받는 중인 다운로드 1개'), findsOneWidget);
    expect(result, isNull);

    // X 버튼 → 확인 메시지 → 종료
    await tester.tap(find.byTooltip('종료'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '종료').last);
    await tester.pumpAndSettle();
    expect(result, isTrue);
  });

  testWidgets('26: 직접 넣은 일반 동영상 사이트 주소도 받는다 (yt-dlp) · 주소가 없으면 알림', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final d = make();
    await tester.pumpWidget(MaterialApp(home: DownloadsPage(d: d)));
    await tester.enterText(find.byType(TextField), '이것 보세요 https://vimeo.com/123456 재밌어요');
    await tester.tap(find.text('추가'));
    await tester.pump();
    expect(d.tasks.single.source, 'https://vimeo.com/123456');
    expect(d.tasks.single.kind, DownloadKind.video);
    await tester.enterText(find.byType(TextField), '주소 아님');
    await tester.tap(find.text('추가'));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('주소 (http · https · 마그넷) 를 찾지 못했거나 이미 받는 중입니다.'), findsOneWidget);
    expect(d.tasks, hasLength(1));
  });

  testWidgets('35: aria2 가 순서를 기다리게 한 토렌트는 "대기 중"', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final d = make();
    await tester.pumpWidget(MaterialApp(home: DownloadsPage(d: d)));
    d.add('magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567');
    await tester.pump();
    d.tasks.single
      ..extra['waiting'] = true
      ..progress = null;
    d.selectNone();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.textContaining('대기 중'), findsWidgets);
    expect(find.textContaining('받는 중'), findsNothing);
  });
}
