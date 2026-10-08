import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:integration_test/integration_test.dart';
import 'package:jj_mkvmaker/core/reader_sources.dart';
import 'package:path/path.dart' as p;

/// 실제 pdfium: 그림 → PDF, 열기 · 그리기, 페이지 지우기 · 그림 넣기 · 저장
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('PDF: 만들기 · 열기 · 지우기 · 넣기 · 저장', (tester) async {
    final dir = Directory.systemTemp.createTempSync('jj_pdf_');
    addTearDown(() => dir.deleteSync(recursive: true));
    String image(String name, int w, int h, {bool jpg = false}) {
      final im = img.Image(width: w, height: h);
      img.fill(im, color: img.ColorRgb8(200, 50, 50));
      final f = File(p.join(dir.path, name));
      f.writeAsBytesSync(Uint8List.fromList(jpg ? img.encodeJpg(im) : img.encodePng(im)));
      return f.path;
    }

    final imgs = [image('1.png', 400, 600), image('2.jpg', 800, 600, jpg: true), image('3.webp.png', 300, 300)];
    final out = p.join(dir.path, 'book.pdf');
    await tester.runAsync(() => imagesToPdf(imgs, out, tempDir: dir.path));
    expect(File(out).lengthSync(), greaterThan(1000));

    final src = (await tester.runAsync(() => PdfSource.open(out, tempDir: dir.path)))!;
    expect(src.length, 3);
    expect(src.pages[1].width, closeTo(800 * 0.75, 1)); // 그림 크기대로
    final page = (await tester.runAsync(() => src.load(0, maxWidth: 400)))!;
    expect(page.image, isNotNull);
    expect(page.image!.width, 400);
    page.dispose();

    await tester.runAsync(() => src.deletePage(1)); // 가로 그림 지우기
    expect(src.length, 2);
    await tester.runAsync(() => src.insertImages([image('new.png', 100, 200)], after: -1, tempDir: dir.path)); // 맨 앞에
    expect(src.length, 3);
    expect(src.dirty, isTrue);
    await tester.runAsync(() => src.save());
    expect(src.dirty, isFalse);
    await tester.runAsync(src.dispose);

    final again = (await tester.runAsync(() => PdfSource.open(out, tempDir: dir.path)))!;
    expect(again.length, 3);
    expect([for (final pg in again.pages) pg.width.round()], [75, 300, 225]);
    await tester.runAsync(again.dispose);
  });
}
