import 'dart:async';
import 'dart:io';

import 'package:flutter/gestures.dart' show kSecondaryButton;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jj_mkvmaker/app/app_controller.dart';
import 'package:jj_mkvmaker/app/settings.dart';
import 'package:jj_mkvmaker/core/playlist.dart';
import 'package:jj_mkvmaker/main.dart' show lastWorkText, wantsNewPlayerWindow;
import 'package:jj_mkvmaker/platform/windows/desktop_storage_service.dart';
import 'package:jj_mkvmaker/platform/windows/process_media_tool.dart';
import 'package:jj_mkvmaker/platform/windows/shell_integration.dart';
import 'package:jj_mkvmaker/platform/windows/single_instance.dart';
import 'package:jj_mkvmaker/services/media_player.dart';
import 'package:jj_mkvmaker/services/platform_services.dart';
import 'package:jj_mkvmaker/ui/exit_dialog.dart';
import 'package:jj_mkvmaker/ui/player_page.dart';
import 'package:path/path.dart' as p;

class _FakePlayer implements MediaPlayer {
  @override
  final ValueNotifier<PlayerState> state = ValueNotifier(const PlayerState(
    duration: Duration(minutes: 2),
    audioTracks: [TrackInfo('1', 'kor'), TrackInfo('2', 'eng')],
    subtitleTracks: [TrackInfo('3', '한국어')],
    width: 1920,
    height: 1080,
  ));
  final calls = <String>[];
  List<String> _files = [];

  void _set({bool? playing, int? index, String? sub, bool clearSub = false, double? volume}) {
    final s = state.value;
    state.value = PlayerState(
      position: s.position,
      duration: s.duration,
      playing: playing ?? s.playing,
      index: index ?? s.index,
      volume: volume ?? s.volume,
      width: s.width,
      height: s.height,
      audioTracks: s.audioTracks,
      subtitleTracks: s.subtitleTracks,
      subtitleId: clearSub ? null : (sub ?? s.subtitleId),
    );
  }

  @override
  Stream<String> get errors => const Stream.empty();
  @override
  List<String> get playlist => _files;
  @override
  Future<void> open(List<String> files, {int start = 0}) async {
    _files = List.of(files);
    calls.add('open ${files.length} $start');
    _set(index: start, playing: true);
  }

  @override
  Future<void> add(List<String> files) async => _files.addAll(files);
  @override
  Future<void> jump(int index) async => _set(index: index);
  @override
  Future<void> next() async => _set(index: (state.value.index + 1).clamp(0, _files.length - 1));
  @override
  Future<void> previous() async => _set(index: (state.value.index - 1).clamp(0, _files.length - 1));
  @override
  Future<void> playOrPause() async => _set(playing: !state.value.playing);
  @override
  Future<void> play() async => _set(playing: true);
  @override
  Future<void> stop() async => calls.add('stop');
  @override
  Future<void> seek(Duration position) async => calls.add('seek ${position.inSeconds}');
  @override
  Future<void> setVolume(double volume) async => _set(volume: volume);
  @override
  Future<void> setRate(double rate) async => calls.add('rate $rate');
  @override
  Future<void> setAudioTrack(TrackInfo t) async => calls.add('audio ${t.id}');
  @override
  Future<void> setSubtitleTrack(TrackInfo? t) async =>
      t == null ? _set(clearSub: true) : _set(sub: t.id);
  @override
  Widget buildView() => const ColoredBox(color: Colors.black);
  @override
  Future<void> dispose() async => calls.add('dispose');
}

void main() {
  group('재생 목록 규칙', () {
    const dir = r'D:\v';
    final files = [
      for (final n in [
        'file_010.mp4', 'file_002.mp4', 'file_1.mp4', 'Show.S01E02.mkv', 'Show.S01E10.mkv',
        'Show.S02E01.mkv', 'other.avi', 'notes.txt', 'Show.S01E01.srt',
      ])
        p.join(dir, n),
    ];

    test('시리즈 키 · 자연 정렬', () {
      expect(seriesKey('file_001.mp4'), seriesKey('file_0002.mp4'));
      expect(seriesKey('Show.S01E02.mkv'), seriesKey('Show.S02E10.mkv'));
      expect(seriesKey('other.avi') == seriesKey('file_1.mp4'), isFalse);
      final names = ['a10', 'a2', 'a1', 'b1'];
      names.sort(naturalCompare);
      expect(names, ['a1', 'a2', 'a10', 'b1']);
    });

    test('하나 · 시리즈 · 폴더', () {
      final f = p.join(dir, 'file_002.mp4');
      final (one, k) = buildPlaylist(f, files, PlaylistMode.single);
      expect([one, k], [[f], 0]);
      final (series, i) = buildPlaylist(f, files, PlaylistMode.series);
      expect(series.map(p.basename), ['file_1.mp4', 'file_002.mp4', 'file_010.mp4']);
      expect(i, 1);
      final (show, j) = buildPlaylist(p.join(dir, 'Show.S01E10.mkv'), files, PlaylistMode.series);
      expect(show.map(p.basename), ['Show.S01E02.mkv', 'Show.S01E10.mkv', 'Show.S02E01.mkv']);
      expect(j, 1);
      final (all, _) = buildPlaylist(f, files, PlaylistMode.folder);
      expect(all, hasLength(7)); // 자막·텍스트 제외
    });

    test('끌어다 놓기: 동영상만, 폴더 안쪽, jj_ 출력 폴더 제외', () async {
      final tree = {
        r'D:\drop': [r'D:\drop\a.mp4', r'D:\drop\b.txt', r'D:\drop\sub', r'D:\drop\jj_mkv'],
        r'D:\drop\sub': [r'D:\drop\sub\c.mkv'],
        r'D:\drop\jj_mkv': [r'D:\drop\jj_mkv\a.mkv'],
      };
      final v = await collectVideos([r'D:\drop', r'D:\x.avi', r'D:\y.jpg'],
          isDirectory: (x) async => tree.containsKey(x), listDir: (x) async => List.of(tree[x]!));
      expect(v, [r'D:\drop\a.mp4', r'D:\drop\sub\c.mkv', r'D:\x.avi']);
    });

    test('실행 인수', () {
      final r = LaunchRequest.parse(['--play', r'D:\a.mp4', r'D:\b.mp4']);
      expect([r.action, r.files], [LaunchAction.play, [r'D:\a.mp4', r'D:\b.mp4']]);
      expect(LaunchRequest.parse([r'D:\a.mp4']).action, LaunchAction.add);
      expect(LaunchRequest.parse(['--subtitle', 'x']).toArgs(), ['--subtitle', 'x']);
    });

    test('탐색기에서 연 동영상: 새 재생 창 여부', () {
      final open = LaunchRequest.parse([r'D:.mkv']);
      final play = LaunchRequest.parse(['--play', r'D:.mkv']);
      final sub = LaunchRequest.parse(['--subtitle', r'D:.mkv']);
      final s = AppSettings();
      expect([s.openFileAction, s.openFileWindow], ['play', 'same']);
      expect(wantsNewPlayerWindow(open, s), isFalse); // 기본: 켜져 있는 창에서
      s.openFileWindow = 'new';
      expect(wantsNewPlayerWindow(open, s), isTrue);
      expect(wantsNewPlayerWindow(play, s), isTrue);
      expect(wantsNewPlayerWindow(sub, s), isFalse); // 자막 만들기는 원래 창
      expect(wantsNewPlayerWindow(LaunchRequest.parse(const []), s), isFalse);
      s.openFileAction = 'add';
      expect(wantsNewPlayerWindow(open, s), isFalse); // 목록에 추가는 원래 창
      expect(wantsNewPlayerWindow(play, s), isTrue);
      final back = AppSettings.fromJson(s.toJson());
      expect([back.openFileAction, back.openFileWindow], ['add', 'new']);
    });

    test('Android 화면 방향: 기본 가로 고정, 세로 · 자동 저장, 모르는 값은 가로', () {
      final s = AppSettings();
      expect(s.screenOrientation, 'landscape');
      for (final m in ['portrait', 'auto', 'landscape']) {
        s.screenOrientation = m;
        expect(AppSettings.fromJson(s.toJson()).screenOrientation, m);
      }
      expect(AppSettings.fromJson({'screenOrientation': 'sideways'}).screenOrientation, 'landscape');
    });
  });

  test('중복 실행 방지: 나중 실행은 넘기고, 짧은 시간의 요청은 하나로', () async {
    final first = SingleInstance(port: 47999, gather: const Duration(milliseconds: 300));
    expect(await first.claim(const LaunchRequest(LaunchAction.play, ['a.mp4'])), isTrue);
    final got = <LaunchRequest>[];
    first.listen(got.add);

    // 탐색기가 파일마다 프로그램을 실행한 상황
    for (final f in ['b.mp4', 'c.mp4']) {
      expect(await SingleInstance(port: 47999).claim(LaunchRequest(LaunchAction.play, [f])), isFalse);
    }
    expect(await SingleInstance(port: 47999).claim(const LaunchRequest(LaunchAction.subtitle, ['d.mp4'])), isFalse);
    await Future<void>.delayed(const Duration(milliseconds: 600));
    await first.close();

    expect(got, hasLength(2));
    final play = got.firstWhere((r) => r.action == LaunchAction.play);
    expect(play.files, ['a.mp4', 'b.mp4', 'c.mp4']);
    expect(got.firstWhere((r) => r.action == LaunchAction.subtitle).files, ['d.mp4']);
  });

  test('탐색기 메뉴 등록 · 해제 (테스트 전용 확장자)', () async {
    if (!Platform.isWindows) return markTestSkipped('Windows 전용');
    final s = ShellIntegration(exePath: r'C:\JJ Test\jj_mkvmaker.exe', extensions: ['jjtestvid']);
    await s.unregister();
    expect(await s.isRegistered(), isFalse);
    expect(await s.register(), isTrue);
    expect(await s.isRegistered(), isTrue);
    final q = await Process.run('reg', [
      'query', r'HKCU\Software\Classes\SystemFileAssociations\.jjtestvid\shell\JJMKVMaker.Play\command', '/ve'
    ]);
    expect('${q.stdout}', contains(r'"C:\JJ Test\jj_mkvmaker.exe" --play "%1"'));
    final q2 = await Process.run('reg', [
      'query', r'HKCU\Software\Classes\SystemFileAssociations\.jjtestvid\shell\JJMKVMaker.Subtitle\command', '/ve'
    ]);
    expect('${q2.stdout}', contains('--subtitle "%1"'));
    await s.unregister();
    expect(await s.isRegistered(), isFalse);
  });

  testWidgets('플레이어 화면: 조작 · 단축키 · 오른쪽 메뉴 · 재생 목록', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final c = AppController(PlatformServices(mediaTool: ProcessMediaTool('x', 'y'), storage: DesktopStorageService()));
    final pl = _FakePlayer();
    await tester.pumpWidget(MaterialApp(
      home: PlayerPage(c: c, player: pl, files: const [r'D:\v\ep1.mp4', r'D:\v\ep2.mp4'], start: 1),
    ));
    await tester.pump();
    expect(pl.calls.first, 'open 2 1');
    expect(find.text('ep2.mp4   (2/2)'), findsOneWidget);

    // Space: 일시정지
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(pl.state.value.playing, isFalse);
    // → 10초 앞으로, P 이전 파일
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyP);
    await tester.pump();
    expect(pl.calls, contains('seek 10'));
    expect(find.text('ep1.mp4   (1/2)'), findsOneWidget);
    // S: 자막 켜기 → 첫 트랙
    await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
    await tester.pump();
    expect(pl.state.value.subtitleId, '3');

    // 재생 목록 (L) → 항목 누르면 이동
    await tester.sendKeyEvent(LogicalKeyboardKey.keyL);
    await tester.pumpAndSettle();
    expect(find.text('재생 목록 2개'), findsOneWidget);
    await tester.tap(find.text('ep2.mp4'));
    await tester.pump();
    expect(pl.state.value.index, 1);

    // 오른쪽 클릭 메뉴
    await tester.tap(find.byType(ColoredBox).first, buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    expect(find.text('전체 화면'), findsOneWidget);
    expect(find.text('팝업 보기'), findsOneWidget);
    expect(find.text('자막 보기'), findsOneWidget);
    expect(find.text('화면 크기'), findsOneWidget);
    expect(find.text('음성 선택'), findsOneWidget); // 음성 트랙 2개
    await tester.tap(find.text('자막 보기'));
    await tester.pumpAndSettle();
    expect(pl.state.value.subtitleId, isNull);

    await tester.pumpWidget(const SizedBox());
    expect(pl.calls.last, 'dispose');
  });

  test('동영상 목록: 저장 → 다시 켜면 그대로, 창 두 개가 서로 맞춤 (추가 · 삭제)', () async {
    final dir = Directory.systemTemp.createTempSync('jj_list_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final list = p.join(dir.path, 'videos.json');
    Directory(p.join(dir.path, 'jj_mkv')).createSync();
    final a = p.join(dir.path, 'a.mp4'), b = p.join(dir.path, 'jj_mkv', 'b.mkv');
    for (final f in [a, b]) {
      File(f).writeAsStringSync('x');
    }
    AppController make() =>
        AppController(PlatformServices(mediaTool: ProcessMediaTool('x', 'y'), storage: DesktopStorageService()));

    final w1 = make();
    await w1.shareVideoList(list);
    await w1.addVideos([a]);
    // 탐색기에서 직접 연 파일은 jj_mkv 안이어도 들어간다 (폴더째 넣을 때는 제외)
    await w1.addVideos([b]);
    expect(w1.videos, hasLength(1));
    await w1.addVideos([b], allowOutputFolder: true);
    expect(w1.videos.map((v) => v.fileName), ['a.mp4', 'b.mkv']);

    // 새 창: 같은 목록으로 시작
    final w2 = make();
    await w2.shareVideoList(list);
    expect(w2.videos.map((v) => v.fileName), ['a.mp4', 'b.mkv']);

    // 새 창에서 삭제 → 원래 창에서도 삭제
    w2.removeVideo(w2.videos.first);
    await w1.syncVideoList();
    expect(w1.videos.map((v) => v.fileName), ['b.mkv']);
    // 원래 창에서 추가 → 새 창에도
    await w1.addVideos([a]);
    await w2.syncVideoList();
    expect(w2.videos.map((v) => v.fileName), ['b.mkv', 'a.mp4']);

    // 없어진 파일은 다시 켤 때 빠진다
    File(a).deleteSync();
    final w3 = make();
    await w3.shareVideoList(list);
    expect(w3.videos.map((v) => v.fileName), ['b.mkv']);
    for (final w in [w1, w2, w3]) {
      w.stopVideoListShare();
    }
  });

  testWidgets('종료 진행 창: 종료 중입니다 → 단계 → Have You Good Time', (tester) async {
    final c = AppController(PlatformServices(mediaTool: ProcessMediaTool('x', 'y'), storage: DesktopStorageService()));
    expect(lastWorkText(c), '없음');
    final ran = <String>[];
    final gate = Completer<void>();
    late BuildContext ctx;
    await tester.pumpWidget(MaterialApp(home: Builder(builder: (x) {
      ctx = x;
      return const SizedBox();
    })));
    var closed = false;
    unawaited(showExitProgress(ctx, lastWork: 'MKV 만들기', steps: [
      ExitStep('다운로드 정리', () async => ran.add('dl')),
      ExitStep('쓰레드 확인', () async {
        await gate.future;
        ran.add('thread');
      }),
      ExitStep('실패해도 계속', () async => throw StateError('x')),
      ExitStep('창 종료', () async => ran.add('close')),
    ]).then((_) => closed = true));
    await tester.pump();
    expect(find.text('종료 중입니다.'), findsOneWidget);
    expect(find.text('바로 전 작업: MKV 만들기'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump(const Duration(milliseconds: 200));
    expect(ran, ['dl']); // 쓰레드 확인에서 기다리는 중
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    gate.complete();
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(ran, ['dl', 'thread', 'close']);
    expect(find.text('Have You Good Time'), findsOneWidget);
    expect(closed, isFalse);
    await tester.pump(const Duration(milliseconds: 800));
    await tester.pump();
    expect(closed, isTrue);
  });

  testWidgets('종료를 누르면: 설정 기본값 · 고르기 창 (백그라운드로 / 모두 종료 / 묻지 않기)', (tester) async {
    expect(AppSettings().closeAction, 'background');
    expect(AppSettings.fromJson((AppSettings()..closeAction = 'quit').toJson()).closeAction, 'quit');
    expect(AppSettings.fromJson({'closeAction': 'x'}).closeAction, 'background');

    late BuildContext ctx;
    await tester.pumpWidget(MaterialApp(home: Builder(builder: (x) {
      ctx = x;
      return const SizedBox();
    })));
    Future<(String, bool)?> open() => showCloseChoice(ctx, running: '다운로드 2개', hotkey: 'Ctrl+Shift+X');

    var r = open();
    await tester.pumpAndSettle();
    expect(find.text('지금: 다운로드 2개'), findsOneWidget);
    expect(find.textContaining('Ctrl+Shift+X'), findsOneWidget);
    await tester.tap(find.text('백그라운드로'));
    await tester.pumpAndSettle();
    expect(await r, ('background', false));

    r = open();
    await tester.pumpAndSettle();
    await tester.tap(find.byType(Checkbox));
    await tester.pump();
    await tester.tap(find.text('모두 종료'));
    await tester.pumpAndSettle();
    expect(await r, ('quit', true));

    r = open();
    await tester.pumpAndSettle();
    await tester.tap(find.text('취소'));
    await tester.pumpAndSettle();
    expect(await r, isNull);
  });
}
