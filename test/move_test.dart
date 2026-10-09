import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jj_mkvmaker/app/app_controller.dart';
import 'package:jj_mkvmaker/app/settings.dart';
import 'package:jj_mkvmaker/core/languages.dart';
import 'package:jj_mkvmaker/core/models.dart';
import 'package:jj_mkvmaker/platform/windows/desktop_storage_service.dart';
import 'package:jj_mkvmaker/platform/windows/process_media_tool.dart';
import 'package:jj_mkvmaker/services/platform_services.dart';
import 'package:jj_mkvmaker/ui/home_page.dart';
import 'package:path/path.dart' as p;

AppController _controller() =>
    AppController(PlatformServices(mediaTool: ProcessMediaTool('x', 'y'), storage: DesktopStorageService()));

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('jj_move_'));
  tearDown(() => dir.deleteSync(recursive: true));

  File make(String name) => File(p.join(dir.path, name))
    ..parent.createSync(recursive: true)
    ..writeAsStringSync(name);

  test('이동: 동영상 + 옆의 같은 이름 자막을 옮기고 목록에서 뺀다. 같은 이름이 있으면 (2)', () async {
    final c = _controller();
    final dest = p.join(dir.path, 'done');
    final a = VideoItem(make('a.mp4').path)
      ..subtitles.add(SubtitleEntry.external(path: make('a.ko.srt').path, language: undetermined))
      ..subtitles.add(SubtitleEntry.external(path: make('other.srt').path, language: undetermined));
    final b = VideoItem(make('b.mkv').path);
    final busy = VideoItem(make('c.mp4').path)..status = JobStatus.running;
    make(p.join('done', 'b.mkv')); // 이미 있는 이름
    // 만든 결과물 (jj_mkv): a 의 것만 함께 옮긴다
    make(p.join('jj_mkv', 'a.mkv'));
    make(p.join('jj_mkv', 'a_AI.srt'));
    make(p.join('jj_mkv', 'a_zh-Hans.srt'));
    make(p.join('jj_mkv', 'ab.mkv'));
    make(p.join('jj_mkv', 'a_1_ko.srt'));
    c.videos.addAll([a, b, busy]);
    c.selected = a;

    final (moved, errors) = await c.moveVideos([a, b, busy], dest);
    expect(moved, 2);
    expect(errors.single, contains('작업 중'));
    expect(File(p.join(dest, 'a.mp4')).existsSync(), isTrue);
    expect(File(p.join(dest, 'a.ko.srt')).existsSync(), isTrue);
    expect(File(p.join(dir.path, 'other.srt')).existsSync(), isTrue, reason: '이름이 다른 자막은 그대로');
    expect(File(p.join(dest, 'b (2).mkv')).readAsStringSync(), 'b.mkv');
    expect(File(p.join(dir.path, 'a.mp4')).existsSync(), isFalse);
    for (final f in ['a.mkv', 'a_AI.srt', 'a_zh-Hans.srt']) {
      expect(File(p.join(dest, 'jj_mkv', f)).existsSync(), isTrue, reason: f);
      expect(File(p.join(dir.path, 'jj_mkv', f)).existsSync(), isFalse, reason: f);
    }
    for (final f in ['ab.mkv', 'a_1_ko.srt']) {
      expect(File(p.join(dir.path, 'jj_mkv', f)).existsSync(), isTrue, reason: '다른 동영상의 결과물 $f 는 그대로');
    }
    expect(c.videos, [busy]);
    expect(c.selected, busy);
  });

  test('목록에 다시 넣으면 (앱을 다시 켜도) 전에 만든 자막 (jj_mkv 의 파일명_ko.srt 등) 이 다시 붙는다', () async {
    final c = _controller();
    final video = make('강의.mp4').path;
    make(p.join('jj_mkv', '강의_AI.srt'));
    make(p.join('jj_mkv', '강의_ko.srt'));
    make(p.join('jj_mkv', '강의_en.srt'));
    make(p.join('jj_mkv', '다른영상_ko.srt'));
    make('강의.ja.srt'); // 같은 폴더 자막
    await c.addVideos([video]);
    final v = c.videos.single;
    expect([for (final s in v.subtitles) p.basename(s.path!)]..sort(), ['강의.ja.srt', '강의_en.srt', '강의_ko.srt']);
    expect(v.subtitles.firstWhere((s) => s.path!.endsWith('_ko.srt')).language.code, 'ko');
  });

  test('이동 폴더를 안 정했으면 옮기지 않는다', () async {
    final c = _controller();
    final a = VideoItem(make('a.mp4').path);
    c.videos.add(a);
    final (moved, errors) = await c.moveVideos([a], '');
    expect(moved, 0);
    expect(errors.single, contains('이동할 폴더'));
    expect(File(a.path).existsSync(), isTrue);
  });

  test('이동 버튼 설정 저장 (표시 이름 · 폴더 · 순서), 예전 이동 폴더 하나는 "이동" 버튼으로', () {
    final s = AppSettings()
      ..moveTargets = const [MoveTarget('완료', r'D:\done'), MoveTarget('보관', r'E:\archive')];
    expect(AppSettings.fromJson(s.toJson()).moveTargets, s.moveTargets);
    expect(AppSettings().moveTargets, isEmpty);
    expect(AppSettings.fromJson({'moveTargetDir': r'D:\old'}).moveTargets, const [MoveTarget('이동', r'D:\old')]);
  });

  testWidgets('MKV 목록: 세 번 누르면 첫 번째 이동 버튼으로 · 세부 정보의 이동 버튼 (표시 이름) 은 그 폴더로', (tester) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final c = _controller();
    final dest = p.join(dir.path, 'done');
    final archive = p.join(dir.path, 'archive');
    c.settings.moveTargets = [MoveTarget('완료함', dest), MoveTarget('보관함', archive)];
    final a = VideoItem(make('a.mp4').path);
    final b = VideoItem(make('b.mp4').path);
    final d = VideoItem(make('d.mp4').path);
    c.videos.addAll([a, b, d]);
    c.selected = a;
    await tester.pumpWidget(MaterialApp(home: HomePage(c: c, onExit: () {})));
    // 파일 옮기기 (실제 입출력) 가 끝나도록 실제 시간을 조금씩 흘려 보낸다
    Future<void> settleIo() async {
      for (var i = 0; i < 10; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    // b 줄을 세 번 → b 만 이동
    final tile = find.text('b.mp4').first;
    for (var i = 0; i < 3; i++) {
      await tester.tap(tile);
      await tester.pump(const Duration(milliseconds: 80));
    }
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    // 47: 옮기기 전에 묻는다 - [취소] 면 그대로, [옮기기] 면 이동
    expect(find.text('파일 옮기기'), findsOneWidget);
    expect(find.textContaining('"b.mp4" 을(를) "완료함" 폴더로 옮길까요?'), findsOneWidget);
    await tester.tap(find.text('취소'));
    await tester.pumpAndSettle();
    await settleIo();
    expect(File(p.join(dest, 'b.mp4')).existsSync(), isFalse);
    for (var i = 0; i < 3; i++) {
      await tester.tap(tile);
      await tester.pump(const Duration(milliseconds: 80));
    }
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '옮기기'));
    await tester.pump();
    await settleIo();
    // 옮긴 뒤 목록에서 빠지는 것은 조금 늦다 (전체 시험 중 바쁠 때) - 빠질 때까지 기다린다
    for (var i = 0; i < 30 && c.videos.any((v) => v.fileName == 'b.mp4'); i++) {
      await settleIo();
    }
    expect(File(p.join(dest, 'b.mp4')).existsSync(), isTrue);
    // 102: 세 번 누르기를 "아무것도 안 함" 으로 하면 묻지도 옮기지도 않는다
    c.settings.tripleTapAction = 'none';
    final dTile = find.text('d.mp4').first;
    for (var i = 0; i < 3; i++) {
      await tester.tap(dTile);
      await tester.pump(const Duration(milliseconds: 80));
    }
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(find.text('파일 옮기기'), findsNothing);
    expect(File(p.join(dest, 'd.mp4')).existsSync(), isFalse);
    c.settings.tripleTapAction = 'move';
    expect(c.videos.map((v) => v.fileName), ['a.mp4', 'd.mp4']);

    // 세부 정보 오른쪽 아래: 표시 이름 버튼 두 개 (첫 번째가 아래, 두 번째가 그 위)
    c.select(a);
    await tester.pump();
    expect(find.text('완료함'), findsOneWidget);
    expect(find.text('보관함'), findsOneWidget);
    expect(find.text('이동'), findsNothing);
    expect(tester.getCenter(find.text('보관함')).dy, lessThan(tester.getCenter(find.text('완료함')).dy));
    // 체크 없음: [보관함] → 보고 있는 동영상 (a) 를 보관 폴더로
    await tester.tap(find.text('보관함'));
    await settleIo();
    expect(File(p.join(archive, 'a.mp4')).existsSync(), isTrue);
    expect(c.videos.map((v) => v.fileName), ['d.mp4']);
    // 체크하면 버튼에 개수
    c.toggleChecked(d);
    await tester.pump();
    expect(find.text('완료함 (1)'), findsOneWidget);
  });
}
