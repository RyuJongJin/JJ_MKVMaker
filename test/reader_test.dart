import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:jj_mkvmaker/app/app_controller.dart';
import 'package:jj_mkvmaker/app/settings.dart';
import 'package:jj_mkvmaker/core/reader_sources.dart';
import 'package:jj_mkvmaker/platform/windows/desktop_storage_service.dart';
import 'package:jj_mkvmaker/platform/windows/process_media_tool.dart';
import 'package:jj_mkvmaker/services/platform_services.dart';
import 'package:jj_mkvmaker/ui/reader_page.dart';
import 'package:path/path.dart' as p;

Uint8List _png(int r, int g, int b, {int w = 40, int h = 60}) {
  final im = img.Image(width: w, height: h);
  img.fill(im, color: img.ColorRgb8(r, g, b));
  return Uint8List.fromList(img.encodePng(im));
}

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('jj_reader_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('ZIP: 목록 · 그림만 자연 순서 · 골라서 / 모두 풀기 (바깥 경로 막기)', () async {
    final zip = p.join(tmp.path, 'comic.zip');
    final a = Archive()
      ..add(ArchiveFile.bytes('ch1/10.png', _png(1, 2, 3)))
      ..add(ArchiveFile.bytes('ch1/2.png', _png(4, 5, 6)))
      ..add(ArchiveFile.bytes('ch1/1.jpg', img.encodeJpg(img.Image(width: 8, height: 8))))
      ..add(ArchiveFile.bytes('readme.txt', 'hi'.codeUnits))
      ..add(ArchiveFile.bytes('../evil.txt', 'x'.codeUnits));
    File(zip).writeAsBytesSync(ZipEncoder().encode(a));

    final entries = await zipEntries(zip, tempDir: tmp.path);
    expect(entries.where((f) => f.isFile).length, 5);
    final src = await ZipImagesSource.open(zip, tempDir: tmp.path, imageExts: defaultImageExtensions);
    expect([for (var i = 0; i < src.length; i++) src.pageName(i)], ['1.jpg', '2.png', '10.png']);
    final page = await src.load(1, maxWidth: 800);
    expect(page.provider, isNotNull);
    await src.dispose();

    final out1 = p.join(tmp.path, 'out1');
    expect(await extractZip(zip, out1, tempDir: tmp.path, names: ['readme.txt']), 1);
    expect(File(p.join(out1, 'readme.txt')).readAsStringSync(), 'hi');
    final out2 = p.join(tmp.path, 'out2');
    expect(await extractZip(zip, out2, tempDir: tmp.path, names: ['ch1']), 3); // 폴더째
    expect(File(p.join(out2, 'ch1', '10.png')).existsSync(), isTrue);
    final out3 = p.join(tmp.path, 'out3');
    await extractZip(zip, out3, tempDir: tmp.path);
    expect(File(p.join(out3, 'evil.txt')).existsSync(), isTrue); // ../ 는 떼고 안에
    expect(File(p.join(tmp.path, 'evil.txt')).existsSync(), isFalse);
  });

  test('보기 설정 저장 · 읽기', () {
    final s = AppSettings()
      ..imageExts = ['png', 'webp']
      ..readerFit = 'width'
      ..readerRtl = true
      ..readerBrightness = 0.3
      ..zipComic = false;
    final b = AppSettings.fromJson(s.toJson());
    expect([b.imageExts, b.readerFit, b.readerRtl, b.readerBrightness, b.zipComic], [
      ['png', 'webp'], 'width', true, 0.3, false,
    ]);
    expect(AppSettings.fromJson({}).imageExts, defaultImageExtensions);
  });

  testWidgets('그림 보기: 오른쪽을 누르면 다음, 왼쪽을 누르면 이전, 가운데는 막대 숨기기 · 오른쪽→왼쪽 넘기기', (tester) async {
    tester.view.physicalSize = const Size(900, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final files = [
      for (final (i, n) in ['a.png', 'b.png', 'c.png'].indexed)
        (File(p.join(tmp.path, n))..writeAsBytesSync(_png(i * 80, 0, 0))).path,
    ];
    final c = AppController(PlatformServices(mediaTool: ProcessMediaTool('x', 'y'), storage: DesktopStorageService()));
    final src = ImageFilesSource(files, tempDir: tmp.path, title: 'imgs');
    await tester.pumpWidget(MaterialApp(home: ReaderPage(c: c, source: src)));
    await tester.pump();
    expect(find.text('1 / 3'), findsOneWidget);
    expect(find.text('a.png'), findsOneWidget);
    Future<void> tapAt(double x) async {
      await tester.tapAt(Offset(x, 600));
      await tester.pumpAndSettle();
    }

    await tapAt(850); // 오른쪽 → 다음
    expect(find.text('2 / 3'), findsOneWidget);
    await tapAt(850);
    expect(find.text('3 / 3'), findsOneWidget);
    await tapAt(50); // 왼쪽 → 이전
    expect(find.text('2 / 3'), findsOneWidget);
    await tapAt(450); // 가운데 → 막대 숨김
    expect(find.text('2 / 3'), findsNothing);
    await tapAt(450);
    expect(find.text('2 / 3'), findsOneWidget);
    // 만화 (오른쪽 → 왼쪽): 왼쪽을 누르면 다음
    await tester.tap(find.byTooltip('넘기는 방향: 왼쪽 → 오른쪽'));
    await tester.pumpAndSettle();
    expect(c.settings.readerRtl, isTrue);
    await tapAt(50);
    expect(find.text('3 / 3'), findsOneWidget);
    // 맞추기 · 밝기
    await tester.tap(find.byTooltip('좌우 맞추기 (세로로 밀어 봄)'));
    await tester.tap(find.byTooltip('밝게'));
    await tester.pump();
    expect(c.settings.readerFit, 'width');
    expect(c.settings.readerBrightness, closeTo(0.1, 1e-9));
  });
}
