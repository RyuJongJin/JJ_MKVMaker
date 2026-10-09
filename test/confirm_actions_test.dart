import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jj_mkvmaker/app/app_controller.dart';
import 'package:jj_mkvmaker/app/live_sync.dart';
import 'package:jj_mkvmaker/app/settings.dart';
import 'package:jj_mkvmaker/core/models.dart';
import 'package:jj_mkvmaker/core/webdav.dart';
import 'package:jj_mkvmaker/platform/windows/desktop_storage_service.dart';
import 'package:jj_mkvmaker/platform/windows/process_media_tool.dart';
import 'package:jj_mkvmaker/services/platform_services.dart';
import 'package:jj_mkvmaker/ui/home_page.dart';
import 'package:jj_mkvmaker/ui/monitor_page.dart';
import 'package:jj_mkvmaker/ui/path_label.dart';
import 'package:jj_mkvmaker/ui/webdav_settings.dart';
import 'package:path/path.dart' as p;

/// 46 · 67 · 69: 지우기 전에 묻기, 동기화 쌍을 짧은 경로로 · 카드에서 고치기 · 지우기
void main() {
  late AppController c;
  setUp(() => c = AppController(PlatformServices(mediaTool: ProcessMediaTool('x', 'y'), storage: DesktopStorageService())));
  tearDown(() => DavRegistry.configure([]));

  test('67: 짧은 경로 - 끝 폴더가 보이게', () {
    expect(friendlyPath('/storage/emulated/0/Download/jj_감독시험/src'), '내장 저장소 › Download › jj_감독시험 › src');
    expect(friendlyPath('/storage/1234-ABCD/JJ_sdtest/jj_mkv'), 'SD 카드 › JJ_sdtest › jj_mkv');
    expect(shortPath('/storage/emulated/0/Download/jj_감독시험/src'), '… › Download › jj_감독시험 › src');
    expect(shortPath(r'D:\backup\movies'), 'D: › backup › movies');
    DavRegistry.configure([const DavServer(id: 'n', name: '집 NAS', url: 'https://nas')]);
    expect(shortPath('dav://n/영상/드라마/2024'), '… › 영상 › 드라마 › 2024');
    expect(friendlyPath('dav://n/영상'), '☁ 집 NAS › 영상');
  });

  testWidgets('69 · 46: lsync 카드 - 짧은 경로 · 길게 누르면 고치기 · 지우기 메뉴 · 지우기는 확인 뒤', (tester) async {
    final tmp = Directory.systemTemp.createTempSync('jj_card_');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final src = p.join(tmp.path, 'movies', 'src'), dst = p.join(tmp.path, 'backup', 'dst');
    c.settings.liveSyncPairs = [LiveSyncPair(src, dst)];
    final live = LiveSync(c);
    LiveSync.instance = live;
    addTearDown(() {
      LiveSync.instance = null;
      live.dispose();
    });
    tester.view.physicalSize = const Size(1500, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: MonitorPage(c: c, initialTab: 1)));
    await tester.pump();
    expect(find.text(shortPath(src)), findsOneWidget);
    expect(find.text('→  ${shortPath(dst)}'), findsOneWidget);
    expect(find.byTooltip('고치기'), findsOneWidget);
    // 길게 누르기 메뉴
    await tester.longPress(find.text(shortPath(src)));
    await tester.pumpAndSettle();
    expect(find.text('고치기'), findsOneWidget);
    await tester.tap(find.text('지우기').last);
    await tester.pumpAndSettle();
    // 확인 창: [취소] 면 그대로
    expect(find.text('실시간 동기화를 지울까요?'), findsOneWidget);
    await tester.tap(find.text('취소'));
    await tester.pumpAndSettle();
    expect(c.settings.liveSyncPairs, hasLength(1));
    // 카드의 지우기 버튼 → 확인 → 지움
    await tester.tap(find.byTooltip('지우기'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '지우기'));
    await tester.pumpAndSettle();
    expect(c.settings.liveSyncPairs, isEmpty);
  });

  testWidgets('46: MKV 목록 "모두 지우기" 는 확인 뒤 · 45: 대기 작업이 있으면 지금 작업만 / 모두 고르기', (tester) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    c.videos.addAll([VideoItem(r'C:\v\a.mp4'), VideoItem(r'C:\v\b.mp4')]);
    await tester.pumpWidget(MaterialApp(home: HomePage(c: c, onExit: () {})));
    await tester.pump();
    await tester.tap(find.byTooltip('모두 지우기'));
    await tester.pumpAndSettle();
    expect(find.text('동영상 2개를 MKV 목록에서 뺍니다. 파일은 지우지 않습니다.'), findsOneWidget);
    await tester.tap(find.text('취소'));
    await tester.pumpAndSettle();
    expect(c.videos, hasLength(2));

    // 45: 작업 중 + 대기 1개 → [취소] 를 누르면 고르기
    c
      ..busy = true
      ..currentJob = 'MKV 만들기 2개'
      ..pendingJobs.add('AI 자막: a.mp4');
    c.notifyListeners();
    await tester.pump();
    await tester.tap(find.byTooltip('작업 취소').first);
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('지금: MKV 만들기 2개'), findsOneWidget);
    await tester.tap(find.text('지금 작업만 (대기 1개는 계속)'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(c.pendingJobs, ['AI 자막: a.mp4']); // 대기는 남는다
    await tester.tap(find.byTooltip('작업 취소').first);
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.text('모두 취소 (대기 1개 포함)'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(c.pendingJobs, isEmpty);
    c.busy = false;
  });

  testWidgets('32: AI 자막 · 번역만 돌 때는 MKV 설정을 바꿀 수 있고, MKV 를 만드는 동안만 막는다', (tester) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    c.videos.add(VideoItem(r'C:\v\a.mp4'));
    await tester.pumpWidget(MaterialApp(home: HomePage(c: c, onExit: () {})));
    bool anyLocked() => tester.widgetList(find.byWidgetPredicate((w) => w is DropdownButton)).any((d) => (d as dynamic).onChanged == null);
    c
      ..busy = true
      ..currentJob = 'AI 자막: a.mp4';
    c.notifyListeners();
    await tester.pump(const Duration(milliseconds: 300));
    expect(anyLocked(), isFalse);
    c.buildingMkv = true;
    c.notifyListeners();
    await tester.pump(const Duration(milliseconds: 300));
    expect(anyLocked(), isTrue);
    c
      ..buildingMkv = false
      ..busy = false;
  });

  testWidgets('46: WebDAV 서버 지우기는 확인 뒤', (tester) async {
    c.settings.webdavServers = [const DavServer(id: 'n', name: '집 NAS', url: 'https://nas')];
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: SingleChildScrollView(child: WebDavSettings(c: c)))));
    await tester.tap(find.byTooltip('지우기'));
    await tester.pumpAndSettle();
    expect(find.text('WebDAV 서버 "집 NAS" 을(를) 지울까요?'), findsOneWidget);
    await tester.tap(find.text('취소'));
    await tester.pumpAndSettle();
    expect(c.settings.webdavServers, hasLength(1));
    await tester.tap(find.byTooltip('지우기'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '지우기'));
    await tester.pumpAndSettle();
    expect(c.settings.webdavServers, isEmpty);
  });
}
