import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jj_mkvmaker/app/app_controller.dart';
import 'package:jj_mkvmaker/app/download_manager.dart';
import 'package:jj_mkvmaker/platform/windows/desktop_storage_service.dart';
import 'package:jj_mkvmaker/platform/windows/process_media_tool.dart';
import 'package:jj_mkvmaker/services/platform_services.dart';
import 'package:jj_mkvmaker/ui/app_drop.dart';
import 'package:jj_mkvmaker/ui/downloads_page.dart';
import 'package:path/path.dart' as p;

AppController _plain() =>
    AppController(PlatformServices(mediaTool: ProcessMediaTool('x', 'y'), storage: DesktopStorageService()));

/// 탐색기에서 끌어다 놓을 때 Windows 쪽 플러그인이 보내는 것과 같은 메시지
Future<void> _native(WidgetTester tester, String method, Object? args) async {
  const codec = StandardMethodCodec();
  await tester.binding.defaultBinaryMessenger
      .handlePlatformMessage('desktop_drop', codec.encodeMethodCall(MethodCall(method, args)), (_) {});
}

void main() {
  test('끌어다 놓은 것에서 동영상 고르기: 파일 · 폴더 · jj_mkv 안의 파일 · 이미 있는 것', () async {
    final dir = Directory.systemTemp.createTempSync('jj_drop_');
    addTearDown(() => dir.deleteSync(recursive: true));
    String make(String rel) {
      final f = File(p.join(dir.path, rel))..createSync(recursive: true);
      f.writeAsStringSync('x');
      return f.path;
    }

    final a = make('a.mp4');
    final made = make(p.join('jj_mkv', '만든 것.mkv'));
    make(p.join('시리즈', '1화.mkv'));
    make(p.join('시리즈', '2화.mkv'));
    make(p.join('시리즈', 'jj_mkv', '1화.mkv')); // 폴더째 놓을 때는 출력 폴더를 건너뜀
    final note = make('메모.txt');

    final c = _plain();
    // 파일 하나
    expect(await addDroppedVideos(c, [a]), (1, 1));
    // 직접 놓은 파일은 jj_mkv 안이어도 추가, 동영상이 아닌 것은 무시, 폴더는 안쪽까지
    expect(await addDroppedVideos(c, [made, note, p.join(dir.path, '시리즈')]), (3, 3));
    expect([for (final v in c.videos) v.fileName], ['a.mp4', '만든 것.mkv', '1화.mkv', '2화.mkv']);
    // 이미 있는 것
    expect(await addDroppedVideos(c, [a, made]), (0, 2));
    // 동영상이 없음
    expect(await addDroppedVideos(c, [note]), (0, 0));
    expect(c.videos, hasLength(4));
  });

  testWidgets('다른 화면 (다운로드) 에서 끌어다 놓아도 MKV 만들기의 동영상 목록에 추가 + 안내', (tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final dir = Directory.systemTemp.createTempSync('jj_drop2_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = p.join(dir.path, '끌어온 영상.mp4');
    File(file).writeAsStringSync('x');

    final c = _plain();
    final d = DownloadManager(backends: const [], settings: () => c.settings, readClipboard: () async => null);
    await tester.pumpWidget(MaterialApp(
      builder: (context, child) => AppDropArea(c: c, child: child!),
      home: DownloadsPage(d: d), // MKV 화면이 아닌 화면
    ));
    await tester.pump();

    // 끌고 들어오면 안내
    await _native(tester, 'entered', [400.0, 300.0]);
    await tester.pump();
    expect(find.textContaining('여기에 놓으면'), findsOneWidget);

    // 놓기
    await tester.runAsync(() async {
      await _native(tester, 'performOperation', [file]);
      for (var i = 0; i < 50 && c.videos.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pump();
    expect([for (final v in c.videos) v.fileName], ['끌어온 영상.mp4']);
    expect(c.selected, c.videos.single);
    expect(find.textContaining('여기에 놓으면'), findsNothing);
    expect(find.textContaining('동영상 목록에 1개를 추가했습니다'), findsOneWidget);

    // 같은 것을 다시 놓으면 "이미 있음"
    await _native(tester, 'entered', [400.0, 300.0]);
    await tester.pump();
    await tester.runAsync(() async {
      await _native(tester, 'performOperation', [file]);
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    // 앞의 안내가 사라지고 새 안내가 나올 때까지
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    expect(c.videos, hasLength(1));
    expect(find.textContaining('이미 동영상 목록에 있습니다'), findsOneWidget);
    d.dispose();
  });
}
