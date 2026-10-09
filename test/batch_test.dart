import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jj_mkvmaker/app/app_controller.dart';
import 'package:jj_mkvmaker/app/bookmarks_controller.dart';
import 'package:jj_mkvmaker/app/download_manager.dart';
import 'package:jj_mkvmaker/app/settings.dart';
import 'package:jj_mkvmaker/core/download_detect.dart';
import 'package:jj_mkvmaker/core/models.dart';
import 'package:jj_mkvmaker/core/output_paths.dart';
import 'package:jj_mkvmaker/core/srt.dart';
import 'package:jj_mkvmaker/platform/windows/desktop_storage_service.dart';
import 'package:jj_mkvmaker/platform/windows/process_media_tool.dart';
import 'package:jj_mkvmaker/services/ai_services.dart';
import 'package:jj_mkvmaker/services/downloader.dart';
import 'package:jj_mkvmaker/services/model_store.dart';
import 'package:jj_mkvmaker/services/platform_services.dart';
import 'package:jj_mkvmaker/ui/app_actions.dart';
import 'package:jj_mkvmaker/ui/browser_page.dart';
import 'package:jj_mkvmaker/ui/downloads_page.dart';
import 'package:jj_mkvmaker/ui/home_page.dart';
import 'package:jj_mkvmaker/ui/settings_page.dart';
import 'package:path/path.dart' as p;

class _Recognizer implements SpeechRecognizer {
  @override
  void cancel() {}
  final heard = <String>[];
  @override
  Future<List<Cue>> transcribe(String wavPath,
      {required String modelPath, String language = 'auto', AiProgress? onProgress}) async {
    heard.add(p.basename(wavPath));
    return [Cue(const Duration(seconds: 1), const Duration(seconds: 2), 'Hello everyone, this is a test.')];
  }
}

class _Translator implements Translator {
  @override
  Future<void> load(String modelDir) async {}
  @override
  Future<List<String>> translate(List<String> lines,
          {required String source, required String target, AiProgress? onProgress}) async =>
      [for (final l in lines) '[$target] $l'];
  @override
  void cancel() {}
  @override
  Future<void> dispose() async {}
}

class _Backend implements DownloadBackend {
  @override
  DownloadKind get kind => DownloadKind.video;
  @override
  Future<(String, List<PlaylistEntry>)?> expandPlaylist(String url) async => null;
  @override
  Future<void> start(DownloadTask t, void Function() changed) async => t.state = DownloadState.downloading;
  @override
  Future<void> pause(DownloadTask t) async {}
  @override
  Future<void> cancel(DownloadTask t) async {}
  @override
  Future<void> shutdown() async {}
}

AppController _plain() =>
    AppController(PlatformServices(mediaTool: ProcessMediaTool('x', 'y'), storage: DesktopStorageService()));

void main() {
  test('여러 개 선택: 체크 · 전체 선택 · 일괄 대상 · 선택 제거', () async {
    final dir = Directory.systemTemp.createTempSync('jj_batch_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final files = [for (final n in ['a', 'b', 'c']) p.join(dir.path, '$n.mp4')];
    for (final f in files) {
      File(f).writeAsStringSync('x');
    }
    final c = _plain();
    await c.addVideos(files);
    final [a, b, cc] = c.videos;

    // 체크한 것이 없으면 지금 보고 있는 한 개
    expect(c.batchTargets, [a]);
    c.toggleChecked(cc);
    c.toggleChecked(a);
    expect(c.batchTargets, [a, cc]); // 목록 순서대로
    c.toggleAllChecked();
    expect(c.checked, hasLength(3));
    c.toggleAllChecked();
    expect(c.checked, isEmpty);

    c
      ..toggleChecked(a)
      ..toggleChecked(b);
    b.status = JobStatus.running; // 작업 중인 것은 남긴다
    c.removeChecked();
    expect(c.videos, [b, cc]);
    expect(c.selected, b);
    b.status = JobStatus.ready;
    c.removeVideo(b);
    expect(c.checked, isEmpty);
    expect(c.batchTargets, [cc]);
  });

  test('목록 정렬 (파일 이름 · 날짜, 다시 누르면 반대) · 선택한 파일을 목록 순서대로 재생', () async {
    final dir = Directory.systemTemp.createTempSync('jj_sort_');
    addTearDown(() => dir.deleteSync(recursive: true));
    // 이름순: ep2 < ep10 < intro   날짜순: intro(가장 오래됨) < ep10 < ep2
    final when = {'ep10.mp4': 2, 'intro.mp4': 1, 'ep2.mp4': 3};
    for (final e in when.entries) {
      File(p.join(dir.path, e.key))
        ..writeAsStringSync('x')
        ..setLastModifiedSync(DateTime(2026, 1, e.value));
    }
    final c = _plain();
    await c.addVideos([for (final n in when.keys) p.join(dir.path, n)]);
    List<String> names() => [for (final v in c.videos) v.fileName];
    expect(names(), ['ep10.mp4', 'intro.mp4', 'ep2.mp4']);

    c.sortVideos('name');
    expect(names(), ['ep2.mp4', 'ep10.mp4', 'intro.mp4']); // 숫자는 숫자로 비교
    c.sortVideos('name');
    expect(names(), ['intro.mp4', 'ep10.mp4', 'ep2.mp4']);
    c.sortVideos('date');
    expect([c.sortedBy, c.sortAscending], ['date', true]);
    expect(names(), ['intro.mp4', 'ep10.mp4', 'ep2.mp4']);
    c.sortVideos('date');
    expect(names(), ['ep2.mp4', 'ep10.mp4', 'intro.mp4']);

    // 재생 순서: 지금 목록에 보이는 순서 그대로 (이름순으로 다시 정렬하지 않음)
    c.sortVideos('date'); // intro, ep10, ep2
    for (final v in c.videos) {
      c.toggleChecked(v);
    }
    final files = [for (final v in c.batchTargets) v.path];
    final (kept, start) = (await c.preparePlayback(files, keepOrder: true))!;
    expect([for (final f in kept) p.basename(f)], ['intro.mp4', 'ep10.mp4', 'ep2.mp4']);
    expect(start, 0);
    final (sorted, _) = (await c.preparePlayback(files))!;
    expect([for (final f in sorted) p.basename(f)], ['ep2.mp4', 'ep10.mp4', 'intro.mp4']);
  });

  test('자막 만들기 & MKV 만들기: 체크한 동영상만 자막 → MKV 까지 일괄', () async {
    final tool = ProcessMediaTool('ffmpeg', 'ffprobe');
    if (await tool.version() == null) return markTestSkipped('FFmpeg 없음');
    final dir = Directory.systemTemp.createTempSync('jj_batch2_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final files = [for (final n in ['one', 'two', 'three']) p.join(dir.path, '$n.mp4')];
    for (final f in files) {
      await tool.runFfmpeg(['-y', '-f', 'lavfi', '-i', 'testsrc=size=160x120:rate=10',
        '-f', 'lavfi', '-i', 'sine', '-t', '2', '-c:v', 'libx264', '-pix_fmt', 'yuv420p', '-c:a', 'aac', f]);
    }
    final models = ModelStore(p.join(dir.path, 'models'));
    for (final m in [whisperModels.first, nllbModel]) {
      for (var i = 0; i < m.files.length; i++) {
        File(await models.pathOf(m, i))
          ..createSync(recursive: true)
          ..writeAsStringSync('x');
      }
    }
    final rec = _Recognizer();
    final c = AppController(PlatformServices(
      mediaTool: tool,
      storage: DesktopStorageService(),
      createRecognizer: () => rec,
      createTranslator: _Translator.new,
      models: models,
    ));
    await c.init();
    await c.addVideos(files);
    final [one, two, three] = c.videos;
    c
      ..toggleChecked(one)
      ..toggleChecked(three);

    await c.aiThenBuild(c.batchTargets, AiOptions.defaults());

    expect(rec.heard, hasLength(2));
    expect([one.status, two.status, three.status], [JobStatus.done, JobStatus.ready, JobStatus.done],
        reason: '${one.message} ${three.message}');
    expect(File(outputMkvPath(one.path)).existsSync(), isTrue);
    expect(File(outputMkvPath(two.path)).existsSync(), isFalse);
    final info = await tool.probe(outputMkvPath(three.path));
    expect(info.ofType('subtitle').map((s) => s.language), containsAll(['kor', 'eng', 'jpn']));
    expect(c.busy, isFalse);

    // 고른 것만 다시 만들기 (이미 만든 것도)
    await c.buildVideos([one]);
    expect(one.status, JobStatus.done);
  });

  testWidgets('MKV 화면: 체크 → "자막 만들기 (2)" · "MKV 만들기 (2)" 글, 전체 선택', (tester) async {
    tester.view.physicalSize = const Size(1600, 900); // 위쪽 버튼 글이 다 보이는 너비
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final c = AppController(PlatformServices(
      mediaTool: ProcessMediaTool('x', 'y'),
      storage: DesktopStorageService(),
      createRecognizer: _Recognizer.new,
      createTranslator: _Translator.new,
    ));
    for (final n in ['a', 'b', 'c']) {
      c.videos.add(VideoItem('D:\\v\\$n.mp4'));
    }
    c.selected = c.videos.first;
    await tester.pumpWidget(MaterialApp(home: HomePage(c: c)));
    expect(find.text('자막 만들기'), findsOneWidget);
    expect(find.text('자막 만들기 & MKV 만들기'), findsOneWidget);
    expect(find.text('동영상 3개 · 전체 선택'), findsOneWidget);

    // 줄의 체크 상자 (0 번째는 전체 선택)
    // (줄에 더블클릭 = 재생이 있어 탭은 더블클릭 대기 시간 뒤에 확정된다)
    await tester.tap(find.byType(Checkbox).at(1));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.byType(Checkbox).at(3));
    await tester.pump(const Duration(milliseconds: 400));
    expect(c.checked, {c.videos[0], c.videos[2]});
    expect(find.text('선택 2 / 3개'), findsOneWidget);
    expect(find.text('자막 만들기 (2)'), findsOneWidget);
    expect(find.text('자막 만들기 & MKV 만들기 (2)'), findsOneWidget);
    expect(find.text('MKV 만들기 (2)'), findsOneWidget);
    expect(find.byTooltip(RegExp('^파일 이름 순으로 정렬')), findsOneWidget);
    expect(find.byTooltip(RegExp('^날짜 순으로 정렬')), findsOneWidget);

    await tester.tap(find.text('선택 2 / 3개'));
    await tester.pump();
    expect(c.checked, hasLength(3));
    await tester.tap(find.byTooltip('선택한 동영상을 목록에서 제거'));
    await tester.pump();
    expect(c.videos, isEmpty);
  });

  testWidgets('다운로드 화면: 다 받은 것을 골라 [동영상 추가] → MKV 목록', (tester) async {
    tester.view.physicalSize = const Size(1500, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final dir = Directory.systemTemp.createTempSync('jj_dladd_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = p.join(dir.path, 'movie.mp4');
    File(file).writeAsStringSync('x');

    final d = DownloadManager(
        backends: [_Backend()], settings: () => AppSettings()..downloadRoot = dir.path, readClipboard: () async => null);
    final added = <String>[];
    d.addToEditList = (files) async {
      added.addAll(files);
      return files.length;
    };
    final done = d.addPage('https://vimeo.com/1')!
      ..title = '다 받은 영상'
      ..files.add(file)
      ..state = DownloadState.done;
    d.addPage('https://vimeo.com/2')!.title = '받는 중인 영상';

    await tester.pumpWidget(MaterialApp(home: DownloadsPage(d: d)));
    OutlinedButton btn() => tester.widget<OutlinedButton>(
        find.ancestor(of: find.text('동영상 추가'), matching: find.byWidgetPredicate((w) => w is OutlinedButton)));
    expect(btn().onPressed, isNull); // 고른 것이 없음

    await tester.tap(find.text('받는 중인 영상'));
    await tester.pump();
    expect(btn().onPressed, isNull); // 아직 다 받지 않음

    await tester.tap(find.text('다 받은 영상'));
    await tester.pump();
    expect(d.selectedVideoFiles, [file]);
    await tester.tap(find.text('동영상 추가'));
    await tester.pump();
    expect(added, [file]);
    expect(find.textContaining('동영상 1개를 추가했습니다'), findsOneWidget);
    expect(done.state, DownloadState.done);
    d.dispose();
  });

  testWidgets('다운로드 화면: "완료시 자동 동영상추가" 체크 → 설정 변경, 목록에서 빼기', (tester) async {
    tester.view.physicalSize = const Size(1500, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final s = AppSettings()..addFinishedDownloads = false;
    final d = DownloadManager(backends: [_Backend()], settings: () => s, readClipboard: () async => null);
    d.addToEditList = (files) async => files.length;
    d.setAutoAdd = (on) async {
      s.addFinishedDownloads = on;
      d.refresh();
    };
    final t = d.addPage('https://vimeo.com/1')!..title = '영상';

    await tester.pumpWidget(MaterialApp(home: DownloadsPage(d: d)));
    Checkbox box() => tester.widget<Checkbox>(
        find.descendant(of: find.byTooltip(RegExp('MKV 만들기의 동영상 목록에 자동으로')), matching: find.byType(Checkbox)));
    expect(box().value, isFalse);
    await tester.tap(find.text('완료시 자동 동영상추가'));
    await tester.pump();
    expect(s.addFinishedDownloads, isTrue);
    expect(box().value, isTrue);

    // 다 받으면 목록에서 뺀다 (앱이 onFinished 에서 부름)
    d.dropFromList(t);
    await tester.pump();
    expect(d.tasks, isEmpty);
    expect(find.text('영상'), findsNothing);
    d.dispose();
  });

  testWidgets('환경 설정 · 종료 버튼: 모든 화면에서 같은 자리', (tester) async {
    tester.view.physicalSize = const Size(1500, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final dir = Directory.systemTemp.createTempSync('jj_pos_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final c = _plain();
    final d = DownloadManager(backends: [_Backend()], settings: () => c.settings, readClipboard: () async => null);
    final bm = BookmarksController(p.join(dir.path, 'bm.json'));
    var exits = 0;

    Future<(Offset, Offset, Offset, Offset)> at(Widget page) async {
      await tester.pumpWidget(MaterialApp(
        key: UniqueKey(),
        builder: (context, child) =>
            AppScope(controller: c, onExit: () => exits++, downloads: d, bookmarks: bm, child: child!),
        home: page,
      ));
      await tester.pump();
      return (
        tester.getCenter(find.byTooltip('환경 설정')),
        tester.getCenter(find.byTooltip('종료')),
        // 왼쪽 공통 버튼: JJ (홈) · 다운로드 목록
        tester.getCenter(find.byTooltip(RegExp('^홈 화면'))),
        tester.getCenter(find.byTooltip(RegExp('^다운로드 목록'))),
      );
    }

    final home = await at(HomePage(c: c, downloads: d, bookmarks: bm, onExit: () => exits++));
    final pages = {
      '다운로드': await at(DownloadsPage(d: d)),
      '환경 설정': await at(SettingsPage(c: c)),
      '브라우저': await at(BrowserPage(
          c: c, bookmarks: bm, downloads: d, viewBuilder: (h, url) => const ColoredBox(color: Colors.white))),
    };
    for (final e in pages.entries) {
      expect(e.value, home, reason: '${e.key} 화면의 버튼 자리가 MKV 화면과 다릅니다');
    }
    // 오른쪽 위 구석
    expect(home.$2.dx, greaterThan(1500 - 60));
    expect(home.$2.dy, 28);
    // 왼쪽 위 구석: JJ 아이콘 (홈)
    expect(home.$3.dx, lessThan(40));
    expect(home.$3.dy, 28);

    // 브라우저에서 종료 버튼 → 앱의 종료 동작
    await tester.tap(find.byTooltip('종료'));
    expect(exits, 1);
    d.dispose();
  });

  testWidgets('MKV 만들기: 체크가 없으면 보고 있는 동영상만, 보고 있는 것도 없으면 "전체 만들기 / 취소" 를 묻는다', (tester) async {
    tester.view.physicalSize = const Size(1500, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final c = _plain()..ffmpegVersion = 'test';
    c.videos.addAll([VideoItem(r'D:\v\a.mp4'), VideoItem(r'D:\v\b.mp4')]);
    c.selected = null;
    await tester.pumpWidget(MaterialApp(home: HomePage(c: c)));

    await tester.tap(find.text('MKV 만들기'));
    await tester.pumpAndSettle();
    expect(find.textContaining('선택한 동영상이 없습니다'), findsOneWidget);
    expect(find.textContaining('목록 전체 2개'), findsOneWidget);
    await tester.tap(find.text('취소'));
    await tester.pumpAndSettle();
    expect(c.busy, isFalse); // 취소하면 아무것도 하지 않음

    // 하나라도 고르면 묻지 않는다 (버튼 글에 개수)
    c.toggleChecked(c.videos.last);
    await tester.pump();
    expect(find.text('MKV 만들기 (1)'), findsOneWidget);
  });

  testWidgets('왼쪽 공통 버튼: JJ (홈) · MKV 화면으로 · 뒤로 · 다운로드 목록', (tester) async {
    tester.view.physicalSize = const Size(1500, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final dir = Directory.systemTemp.createTempSync('jj_nav_');
    final c = _plain();
    final d = DownloadManager(backends: [_Backend()], settings: () => c.settings, readClipboard: () async => null);
    final bm = BookmarksController(p.join(dir.path, 'bm.json'));
    await tester.pumpWidget(MaterialApp(
      builder: (context, child) => AppScope(controller: c, downloads: d, bookmarks: bm, child: child!),
      home: HomePage(c: c, downloads: d, bookmarks: bm),
    ));
    IconButton btn(String tip) =>
        tester.widget<IconButton>(find.ancestor(of: find.byTooltip(RegExp('^$tip')), matching: find.byType(IconButton)).first);

    // MKV 화면: 뒤로 · MKV 는 "지금 여기" 라 꺼짐, 다운로드 목록 열기
    expect(btn('뒤로').onPressed, isNull);
    expect(find.byTooltip('MKV 화면 (지금 여기)'), findsOneWidget);
    // 지금 화면 버튼 아래 밑줄 하나 (그 버튼 아래에)
    final line = find.byKey(const ValueKey('nav-here-underline'));
    expect(line, findsOneWidget);
    final mkv = tester.getRect(find.byTooltip('MKV 화면 (지금 여기)'));
    expect(tester.getCenter(line).dx, closeTo(mkv.center.dx, 2));
    await tester.tap(find.byTooltip('다운로드 목록'));
    await tester.pumpAndSettle();
    expect(find.textContaining('다운로드 ('), findsOneWidget);
    expect(find.byTooltip('다운로드 목록 (지금 여기)'), findsOneWidget);

    // 다운로드 → 환경 설정 → MKV 화면으로 (한 번에 처음까지)
    await tester.tap(find.byTooltip('환경 설정').first);
    await tester.pumpAndSettle();
    expect(find.text('환경 설정'), findsWidgets);
    await tester.tap(find.byTooltip('MKV 화면으로'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('MKV 화면 (지금 여기)'), findsOneWidget);

    // 뒤로: 한 단계만
    await tester.tap(find.byTooltip('다운로드 목록'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('뒤로'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('MKV 화면 (지금 여기)'), findsOneWidget);

    // 홈 화면을 웹 브라우저로 정하면 JJ 아이콘이 브라우저를 연다 (MKV 버튼은 그대로 있음)
    c.settings.startScreen = 'browser';
    await tester.tap(find.byTooltip('다운로드 목록'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip(RegExp('^홈 화면 \\(웹 브라우저\\)')));
    // 화면 전환 (닫히는 화면 · 새 화면) 이 끝날 때까지. 브라우저는 계속 움직여서 pumpAndSettle 은 쓰지 않는다.
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    expect(find.byType(BrowserPage), findsOneWidget);
    expect(find.byTooltip('MKV 화면으로'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    d.dispose();
  });
}
