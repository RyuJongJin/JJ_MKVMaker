import 'dart:typed_data';

/// 파일 선택·폴더 접근 경계.
///
/// Windows: 일반 파일 경로 (dart:io)
/// Android: (이식 시) 저장소 접근 프레임워크(SAF) 권한 처리
abstract class StorageService {
  Future<List<String>> pickVideos();

  Future<List<String>> pickSubtitles({String? initialDirectory});

  /// 폴더 안의 파일 경로 목록 (하위 폴더 제외)
  Future<List<String>> listFiles(String directory);

  Future<void> ensureDirectory(String directory);

  Future<bool> exists(String path);

  /// 문자셋 판별용으로 파일 앞부분 읽기
  Future<List<int>> readHead(String path, int maxBytes);

  Future<Uint8List> readBytes(String path);

  Future<int> fileSize(String path);

  /// 파일의 [start] 위치부터 최대 [length] 바이트 (영상 해시 계산용)
  Future<Uint8List> readRange(String path, int start, int length);

  Future<void> writeBytes(String path, Uint8List bytes);

  Future<void> delete(String path);

  /// 앱 전용 임시 폴더
  Future<String> tempDirectory();

  /// "다른 이름으로 저장" 대화상자. 저장한 위치를 돌려주고, 취소하면 null.
  Future<String?> saveAs({
    required String fileName,
    required Uint8List bytes,
    String? initialDirectory,
  });
}
