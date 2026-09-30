import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:jj_mkvmaker/services/preview_player.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jj_mkvmaker/app/app_controller.dart';
import 'package:jj_mkvmaker/app/subtitle_editor_controller.dart';
import 'package:jj_mkvmaker/core/languages.dart';
import 'package:jj_mkvmaker/core/models.dart';
import 'package:jj_mkvmaker/core/srt.dart';
import 'package:jj_mkvmaker/ui/subtitle_editor_page.dart';
import 'package:jj_mkvmaker/main.dart';
import 'package:jj_mkvmaker/services/media_tool.dart';
import 'package:jj_mkvmaker/services/platform_services.dart';
import 'package:jj_mkvmaker/services/storage_service.dart';

class _FakeTool implements MediaTool {
  @override
  Future<String?> version() async => 'ffmpeg version test';
  @override
  Future<Set<String>> encoders() async => {'libx264', 'libx265', 'libvpx-vp9', 'libxvid'};
  @override
  Future<MediaInfo> probe(String path) async => const MediaInfo(
        duration: Duration(minutes: 90),
        streams: [
          StreamInfo(index: 0, type: 'video', codec: 'h264', width: 1920, height: 1080),
          StreamInfo(index: 1, type: 'audio', codec: 'aac'),
          StreamInfo(index: 2, type: 'subtitle', codec: 'subrip', language: 'eng'),
        ],
      );
  @override
  Future<void> runFfmpeg(List<String> args,
      {Duration? duration, ProgressCallback? onProgress}) async {}
  @override
  void cancel() {}
}

class _FakeStorage implements StorageService {
  @override
  Future<List<String>> pickVideos() async => [];
  @override
  Future<List<String>> pickSubtitles({String? initialDirectory}) async => [];
  @override
  Future<List<String>> listFiles(String directory) async =>
      [r'D:\m\영화.mkv', r'D:\m\영화.ko.srt'];
  @override
  Future<void> ensureDirectory(String directory) async {}
  @override
  Future<bool> exists(String path) async => true;
  @override
  Future<List<int>> readHead(String path, int maxBytes) async => [0x31];
  @override
  Future<Uint8List> readBytes(String path) async => Uint8List(0);
  @override
  Future<int> fileSize(String path) async => 0;
  @override
  Future<Uint8List> readRange(String path, int start, int length) async => Uint8List(0);
  @override
  Future<void> writeBytes(String path, Uint8List bytes) async {}
  @override
  Future<void> delete(String path) async {}
  @override
  Future<String> tempDirectory() async => r'C:\tmp';
  @override
  Future<String?> saveAs(
          {required String fileName, required Uint8List bytes, String? initialDirectory}) async =>
      null;
}

class _FakePlayer implements PreviewPlayer {
  final pos = StreamController<Duration>.broadcast(sync: true);
  Duration _pos = Duration.zero;
  bool disposed = false;
  String? opened;

  @override
  Stream<Duration> get positionStream => pos.stream;
  @override
  Stream<Duration> get durationStream => Stream.value(const Duration(seconds: 60));
  @override
  Stream<bool> get playingStream => const Stream.empty();
  @override
  Stream<String> get errorStream => const Stream.empty();
  @override
  Duration get position => _pos;
  @override
  Duration get duration => const Duration(seconds: 60);
  @override
  bool get isPlaying => false;
  @override
  Future<void> open(String path) async => opened = path;
  @override
  Future<void> playOrPause() async {}
  @override
  Future<void> pause() async {}
  @override
  Future<void> seek(Duration position) async => _pos = position;
  @override
  Future<void> setRate(double rate) async {}
  @override
  Widget buildView() => const ColoredBox(color: Colors.black);
  @override
  Future<void> dispose() async => disposed = true;
}

void main() {
  testWidgets('영상 보며 싱크 편집: 재생 위치 표시, 시작=현재, 맞추기, 타임라인 드래그', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final c = AppController(
        PlatformServices(mediaTool: _FakeTool(), storage: _FakeStorage()));
    final v = VideoItem(r'D:\m\영화.mkv');
    final s = SubtitleEntry.external(path: r'D:\m\영화.ko.srt', language: languageOf('ko'));
    v.subtitles.add(s);
    final editor = SubtitleEditorController(
        parseSrt('1\n00:00:01,000 --> 00:00:03,000\n첫째\n\n'
            '2\n00:00:05,000 --> 00:00:07,000\n둘째\n\n'
            '3\n00:00:09,000 --> 00:00:11,000\n셋째\n'),
        saveCharset: 'UTF-8');
    final player = _FakePlayer();

    await tester.pumpWidget(MaterialApp(
        home: SubtitleEditorPage(
            app: c, video: v, entry: s, editor: editor, player: player)));
    await tester.pump();
    expect(player.opened, v.path);
    expect(find.text('00:00:00,000 / 00:01:00,000'), findsOneWidget);

    // 재생 위치 2초 → 영상 위에 "첫째" 겹쳐 표시 (표 + 타임라인 + 겹쳐 보기)
    player.pos.add(const Duration(seconds: 2));
    await tester.pump();
    expect(find.text('00:00:02,000 / 00:01:00,000'), findsOneWidget);
    expect(find.text('첫째'), findsNWidgets(3));

    // 2번 줄 선택(번호 클릭) → 그 줄 시작(5초)으로 이동
    await tester.tap(find.text('2').first);
    await tester.pump();
    expect(editor.selected, editor.cues[1]);
    expect(player.position, const Duration(seconds: 5));

    // 4.5초에서 "선택 줄부터 여기로 맞추기" → 2, 3번이 0.5초 앞당겨짐, 1번은 그대로
    player.pos.add(const Duration(milliseconds: 4500));
    await tester.pump();
    await tester.tap(find.text('선택 줄부터 여기로 맞추기'));
    await tester.pump();
    expect(editor.cues.map((c) => c.start.inMilliseconds), [1000, 4500, 8500]);

    // F10: 끝 = 현재 → 최소 길이 보장 (4.5초 → 4.6초)
    await tester.sendKeyEvent(LogicalKeyboardKey.f10);
    await tester.pump();
    expect(editor.cues[1].end, const Duration(milliseconds: 4600));

    // 타임라인에서 3번 블록을 오른쪽으로 끌면 뒤로 이동
    final before = editor.cues[2].start;
    await tester.drag(find.text('셋째').last, const Offset(60, 0));
    await tester.pump();
    expect(editor.cues[2].start, greaterThan(before));
    expect(editor.cues[2].end - editor.cues[2].start, const Duration(seconds: 2));
    expect(editor.dirty, isTrue);

    await tester.pumpWidget(const SizedBox());
    expect(player.disposed, isTrue);
  });

  testWidgets('동영상 추가 후 화면 표시', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final c = AppController(
        PlatformServices(mediaTool: _FakeTool(), storage: _FakeStorage()));
    await c.init();
    await tester.pumpWidget(JjCapCutApp(controller: c));
    expect(find.text('"동영상 추가" 로 파일을 선택하세요'), findsOneWidget);

    await c.addVideos([r'D:\m\영화.mkv']);
    await tester.pump();

    expect(find.text('영화.mkv'), findsNWidgets(2)); // 목록 + 상세 제목
    expect(find.text('자막 2개'), findsOneWidget); // 내장 1 + 같은 폴더 1
    expect(find.text('1920×1080'), findsOneWidget);
    expect(find.text('영화.ko.srt'), findsOneWidget);
    expect(find.text('한국어 (ko)'), findsOneWidget);
    expect(find.text('영어 (en)'), findsOneWidget);

    await tester.tap(find.text('MKV 만들기'));
    await tester.pump();
    expect(c.videos.single.status, JobStatus.done);
  });

  testWidgets('자막 편집 화면: 싱크 이동과 형식 오류 표시', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final c = AppController(
        PlatformServices(mediaTool: _FakeTool(), storage: _FakeStorage()));
    final v = VideoItem(r'D:\m\영화.mkv');
    final s = SubtitleEntry.external(path: r'D:\m\영화.ko.srt', language: languageOf('ko'));
    v.subtitles.add(s);
    final editor = SubtitleEditorController(
        parseSrt('1\n00:00:01,000 --> 00:00:02,000\n안녕\n\n2\n00:00:03,000 --> 00:00:04,000\n반가워\n'),
        saveCharset: 'CP949');

    await tester.pumpWidget(MaterialApp(
        home: SubtitleEditorPage(app: c, video: v, entry: s, editor: editor)));
    expect(find.text('안녕'), findsOneWidget);
    expect(find.text('2줄'), findsOneWidget);
    expect(find.text('CP949 (EUC-KR)'), findsOneWidget);

    // 전체 +500ms 이동 → 입력칸에 반영
    await tester.enterText(find.widgetWithText(TextField, '0'), '500');
    await tester.tap(find.text('전체 이동'));
    await tester.pump();
    expect(find.text('00:00:01,500'), findsOneWidget);

    // 잘못된 시간 입력 → 오류 표시, 저장 버튼 비활성
    await tester.enterText(find.text('00:00:01,500'), '1:2x');
    await tester.pump();
    expect(find.text('형식 오류'), findsOneWidget);
    expect(find.textContaining('시간 형식 오류 1곳'), findsOneWidget);
    final save = tester.widget<FilledButton>(
        find.ancestor(of: find.textContaining('저장 (MKV 반영)'), matching: find.byWidgetPredicate((w) => w is FilledButton)));
    expect(save.onPressed, isNull);
  });
}
