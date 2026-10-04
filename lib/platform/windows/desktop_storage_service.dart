import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;

import '../../core/subtitle_detector.dart';
import '../../services/storage_service.dart';
import '../../l10n/tr.dart';

class DesktopStorageService implements StorageService {
  @override
  Future<List<String>> pickVideos() async {
    final files = await FilePicker.pickFiles(
      dialogTitle: tr('동영상 선택'),
      type: FileType.custom,
      allowedExtensions: videoExtensions,
    );
    return files.map((f) => f.path).whereType<String>().toList();
  }

  @override
  Future<List<String>> pickSubtitles({String? initialDirectory}) async {
    final files = await FilePicker.pickFiles(
      dialogTitle: tr('자막 파일 선택'),
      initialDirectory: initialDirectory,
      type: FileType.custom,
      allowedExtensions: subtitleExtensions,
    );
    return files.map((f) => f.path).whereType<String>().toList();
  }

  @override
  Future<List<String>> listFiles(String directory) async {
    final dir = Directory(directory);
    if (!await dir.exists()) return [];
    return dir
        .list(followLinks: false)
        .where((e) => e is File)
        .map((e) => e.path)
        .toList();
  }

  @override
  Future<void> ensureDirectory(String directory) =>
      Directory(directory).create(recursive: true);

  @override
  Future<bool> exists(String path) => File(path).exists();

  @override
  Future<List<int>> readHead(String path, int maxBytes) async {
    final raf = await File(path).open();
    try {
      return await raf.read(maxBytes);
    } finally {
      await raf.close();
    }
  }

  @override
  Future<Uint8List> readBytes(String path) => File(path).readAsBytes();

  @override
  Future<int> fileSize(String path) => File(path).length();

  @override
  Future<Uint8List> readRange(String path, int start, int length) async {
    final raf = await File(path).open();
    try {
      await raf.setPosition(start);
      return await raf.read(length);
    } finally {
      await raf.close();
    }
  }

  @override
  Future<void> writeBytes(String path, Uint8List bytes) async {
    await File(path).parent.create(recursive: true);
    await File(path).writeAsBytes(bytes, flush: true);
  }

  @override
  Future<void> delete(String path) async {
    final f = File(path);
    if (await f.exists()) await f.delete();
  }

  @override
  Future<String> tempDirectory() async {
    final dir = Directory(p.join(Directory.systemTemp.path, 'jj_mkvmaker'));
    await dir.create(recursive: true);
    return dir.path;
  }

  @override
  Future<String?> saveAs({
    required String fileName,
    required Uint8List bytes,
    String? initialDirectory,
  }) async {
    final uri = await FilePicker.saveFile(
      dialogTitle: tr('다른 이름으로 저장'),
      fileName: fileName,
      bytes: bytes,
      initialDirectory: initialDirectory,
      type: FileType.custom,
      allowedExtensions: const ['srt'],
    );
    if (uri == null) return null;
    final path = uri.scheme == 'file' ? uri.toFilePath() : uri.toString();
    // 데스크톱 구현이 내용을 쓰지 않는 경우를 대비해 한 번 더 기록
    if (uri.scheme == 'file') await writeBytes(path, bytes);
    return path;
  }
}
