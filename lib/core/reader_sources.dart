import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:archive/archive_io.dart';
import 'package:flutter/painting.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:pdfrx/pdfrx.dart';

import 'playlist.dart' show naturalCompare;
import 'vfs.dart';

/// 그림 보기 (만화 보기) 의 기본 대상 확장자 (환경 설정에서 바꿈)
const defaultImageExtensions = ['jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp'];

/// 만화 압축 파일 (ZIP · CBZ)
const zipExtensions = ['zip', 'cbz'];

String extOf(String path) {
  final name = vBasename(path);
  final i = name.lastIndexOf('.');
  return i < 0 ? '' : name.substring(i + 1).toLowerCase();
}

/// 보기 화면의 한 장: 그림 파일 · 압축 안 그림은 [provider], PDF 페이지는 그린 [image]
class ReaderImage {
  final ImageProvider? provider;
  final ui.Image? image;
  const ReaderImage({this.provider, this.image});
  void dispose() => image?.dispose();
}

/// 넘겨 보는 페이지들 (그림 파일들 · 압축 파일 안 그림 · PDF)
abstract class ReaderSource {
  String get title;
  int get length;
  String pageName(int i);

  /// [i] 번째 장을 너비 [maxWidth] 픽셀 정도로 (메모리를 아끼려고 화면 크기에 맞춰 줄임)
  Future<ReaderImage> load(int i, {required int maxWidth});
  Future<void> dispose() async {}
}

/// 폴더의 그림 파일들 (로컬 · WebDAV). WebDAV 는 볼 때 임시 폴더로 받는다.
class ImageFilesSource extends ReaderSource {
  final List<String> paths;
  final String tempDir;
  @override
  final String title;
  ImageFilesSource(this.paths, {required this.tempDir, required this.title});

  @override
  int get length => paths.length;
  @override
  String pageName(int i) => vBasename(paths[i]);

  @override
  Future<ReaderImage> load(int i, {required int maxWidth}) async {
    final local = await vLocalCopy(paths[i], tempDir);
    return ReaderImage(provider: ResizeImage.resizeIfNeeded(maxWidth, null, FileImage(File(local))));
  }
}

/// ZIP · CBZ 안의 그림들 (이름의 자연 순서). 큰 파일도 목록만 읽고 그림은 볼 때 푼다.
class ZipImagesSource extends ReaderSource {
  final Archive archive;
  final InputFileStream _input;
  final List<ArchiveFile> entries;
  @override
  final String title;
  ZipImagesSource._(this.archive, this._input, this.entries, this.title);

  /// [imageExts] 그림으로 볼 확장자
  static Future<ZipImagesSource> open(String path, {required String tempDir, required List<String> imageExts}) async {
    final local = await vLocalCopy(path, tempDir);
    final input = InputFileStream(local);
    final archive = ZipDecoder().decodeStream(input);
    final images = [
      for (final f in archive.files)
        if (f.isFile && imageExts.contains(extOf(f.name)) && !f.name.startsWith('__MACOSX/')) f,
    ]..sort((a, b) => naturalCompare(a.name, b.name));
    return ZipImagesSource._(archive, input, images, vBasename(path));
  }

  @override
  int get length => entries.length;
  @override
  String pageName(int i) => p.posix.basename(entries[i].name);

  @override
  Future<ReaderImage> load(int i, {required int maxWidth}) async {
    final bytes = entries[i].readBytes() ?? Uint8List(0);
    return ReaderImage(provider: ResizeImage.resizeIfNeeded(maxWidth, null, MemoryImage(bytes)));
  }

  @override
  Future<void> dispose() async {
    await _input.close();
  }
}

/// PDF: 보기 + 페이지 지우기 · 그림을 페이지로 넣기 · 저장
class PdfSource extends ReaderSource {
  final String path;
  final String localPath;
  final PdfDocument doc;
  @override
  final String title;

  /// 넣은 그림으로 만든 1쪽 문서들 (저장할 때까지 살아 있어야 함)
  final _added = <PdfDocument>[];
  bool dirty = false;

  /// 보이는 페이지 (원본 문서 · 넣은 그림 문서의 페이지). 문서 자체는 고치지 않고 저장할 때 한 번에 조립한다
  /// (같은 문서의 페이지 목록을 여러 번 바꾸면 pdfrx 가 저장할 때 엉뚱한 페이지를 남겼다).
  late final List<PdfPage> _view = [...doc.pages];

  /// 보이는 페이지들 (시험용)
  List<PdfPage> get pages => List.unmodifiable(_view);

  PdfSource._(this.path, this.localPath, this.doc, this.title);

  static Future<PdfSource> open(String path, {required String tempDir}) async {
    await pdfrxFlutterInitialize();
    final local = await vLocalCopy(path, tempDir);
    // 사본을 연다: pdfium 이 연 파일을 잡고 있어 (Windows) 저장할 때 원본을 덮어쓸 수 없으므로
    final work = p.join(tempDir, 'jj_pdf_${DateTime.now().microsecondsSinceEpoch}.pdf');
    await File(local).copy(work);
    final doc = await PdfDocument.openFile(work);
    return PdfSource._(path, work, doc, vBasename(path));
  }

  @override
  int get length => _view.length;
  @override
  String pageName(int i) => '${i + 1} / ${_view.length}';

  @override
  Future<ReaderImage> load(int i, {required int maxWidth}) async {
    final page = _view[i];
    final w = maxWidth.toDouble();
    final h = w * page.height / page.width;
    final pdfImage = await page.render(fullWidth: w, fullHeight: h, backgroundColor: 0xffffffff);
    if (pdfImage == null) return const ReaderImage();
    try {
      return ReaderImage(image: await pdfImage.createImage());
    } finally {
      pdfImage.dispose();
    }
  }

  /// [i] 번째 페이지 지우기 (저장해야 파일에 반영)
  Future<void> deletePage(int i) async {
    _view.removeAt(i);
    dirty = true;
  }

  /// 그림들을 한 장씩 [after] 번째 페이지 뒤에 넣는다 (-1 이면 맨 앞)
  Future<void> insertImages(List<String> images, {required int after, required String tempDir}) async {
    final newPages = <PdfPage>[];
    for (final (k, path) in images.indexed) {
      final one = await imagePageDocument(path, tempDir: tempDir, sourceName: 'jj_add_${DateTime.now().microsecondsSinceEpoch}_$k');
      _added.add(one);
      newPages.add(one.pages.first);
    }
    _view.insertAll(after + 1, newPages);
    dirty = true;
  }

  /// 저장 ([to] 가 없으면 원래 파일에 덮어쓰기, WebDAV 도): 빈 새 문서에 보이는 순서대로 한 번에 조립.
  /// (원본 문서의 페이지 목록에 다른 문서의 페이지를 섞어 넣으면 pdfrx 가 엉뚱한 페이지를 남겨, 모두 바깥 페이지로)
  Future<String> save({String? to}) async {
    final out = await PdfDocument.createNew(sourceName: 'jj_save_${DateTime.now().microsecondsSinceEpoch}');
    Uint8List bytes;
    try {
      out.pages = [..._view];
      bytes = await out.encodePdf();
    } finally {
      await out.dispose();
    }
    final target = to ?? path;
    await vWrite(target, Stream.value(bytes), length: bytes.length);
    dirty = false;
    return target;
  }

  @override
  Future<void> dispose() async {
    await doc.dispose();
    for (final d in _added) {
      await d.dispose();
    }
    try {
      await File(localPath).delete();
    } catch (_) {}
  }
}

/// 그림 한 장으로 1쪽 PDF (JPEG 가 아니면 JPEG 로 바꿈). 페이지 크기는 그림 픽셀 × 0.75 pt (96dpi 기준).
Future<PdfDocument> imagePageDocument(String path, {required String tempDir, required String sourceName}) async {
  await pdfrxFlutterInitialize();
  final local = await vLocalCopy(path, tempDir);
  final bytes = await File(local).readAsBytes();
  final decoded = img.decodeImage(bytes);
  if (decoded == null) throw FormatException('그림을 읽을 수 없습니다', vBasename(path));
  final jpeg = extOf(path) == 'jpg' || extOf(path) == 'jpeg' ? bytes : Uint8List.fromList(img.encodeJpg(decoded, quality: 92));
  return PdfDocument.createFromJpegData(jpeg,
      width: decoded.width * 0.75, height: decoded.height * 0.75, sourceName: sourceName);
}

/// 그림들을 한 장씩 PDF 로 ([out] 에 저장, 로컬 · WebDAV)
Future<void> imagesToPdf(List<String> images, String out, {required String tempDir, void Function(int done)? onProgress}) async {
  await pdfrxFlutterInitialize();
  final doc = await PdfDocument.createNew(sourceName: 'jj_new_${DateTime.now().microsecondsSinceEpoch}');
  final parts = <PdfDocument>[];
  try {
    final pages = <PdfPage>[];
    for (final (k, path) in images.indexed) {
      final one = await imagePageDocument(path, tempDir: tempDir, sourceName: 'jj_img_${DateTime.now().microsecondsSinceEpoch}_$k');
      parts.add(one);
      pages.add(one.pages.first);
      onProgress?.call(k + 1);
    }
    doc.pages = pages;
    final bytes = await doc.encodePdf();
    await vWrite(out, Stream.value(bytes), length: bytes.length);
  } finally {
    await doc.dispose();
    for (final d in parts) {
      await d.dispose();
    }
  }
}

/// ZIP 목록 (폴더 · 파일 크기)
Future<List<ArchiveFile>> zipEntries(String path, {required String tempDir}) async {
  final local = await vLocalCopy(path, tempDir);
  final input = InputFileStream(local);
  try {
    final archive = ZipDecoder().decodeStream(input);
    return [for (final f in archive.files) f];
  } finally {
    await input.close();
  }
}

/// ZIP 에서 [names] (빈 목록이면 모두) 를 [dest] 폴더로 풀기 (로컬 · WebDAV). 푼 파일 수.
Future<int> extractZip(String path, String dest, {required String tempDir, List<String> names = const [],
    void Function(int done, int total)? onProgress}) async {
  final local = await vLocalCopy(path, tempDir);
  final input = InputFileStream(local);
  var n = 0;
  try {
    final archive = ZipDecoder().decodeStream(input);
    final todo = [
      for (final f in archive.files)
        if (f.isFile && (names.isEmpty || names.any((x) => f.name == x || f.name.startsWith(x.endsWith('/') ? x : '$x/')))) f,
    ];
    for (final f in todo) {
      // 압축 안 경로를 그대로 (../ 같은 바깥 경로는 막는다)
      final parts = [for (final s in f.name.split('/')) if (s.isNotEmpty && s != '.' && s != '..') s];
      if (parts.isEmpty) continue;
      var target = dest;
      for (final s in parts.take(parts.length - 1)) {
        target = vJoin(target, s);
      }
      await vMkdirs(target);
      final bytes = f.readBytes() ?? Uint8List(0);
      await vWrite(vJoin(target, parts.last), Stream.value(bytes), length: bytes.length);
      n++;
      onProgress?.call(n, todo.length);
    }
  } finally {
    await input.close();
  }
  return n;
}
