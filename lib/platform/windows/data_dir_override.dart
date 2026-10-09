import 'dart:io';

import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

/// 시험판 (Windows): 환경 변수 JJ_MKVMAKER_DATA 가 있으면 설정 · 비밀번호 (secrets.dat) · 즐겨찾기 등을
/// 사용자의 실제 앱 폴더 대신 그 폴더에 둔다. 사용자 PC 에서 시험해도 사용자 데이터를 건드리지 않게.
/// 설정이 없으면 (보통의 실행) 아무것도 바꾸지 않는다.
String? get dataDirOverride {
  if (!Platform.isWindows) return null;
  final v = Platform.environment['JJ_MKVMAKER_DATA']?.trim() ?? '';
  return v.isEmpty ? null : v;
}

/// [dataDirOverride] 가 있으면 앱 데이터 폴더만 그것으로 (나머지는 원래 것)
void applyDataDirOverride() {
  final dir = dataDirOverride;
  if (dir == null) return;
  Directory(dir).createSync(recursive: true);
  PathProviderPlatform.instance = _OverridePaths(PathProviderPlatform.instance, dir);
}

class _OverridePaths extends PathProviderPlatform {
  _OverridePaths(this._base, this._dir);
  final PathProviderPlatform _base;
  final String _dir;

  @override
  Future<String?> getApplicationSupportPath() async => _dir;
  @override
  Future<String?> getTemporaryPath() => _base.getTemporaryPath();
  @override
  Future<String?> getLibraryPath() => _base.getLibraryPath();
  @override
  Future<String?> getApplicationDocumentsPath() => _base.getApplicationDocumentsPath();
  @override
  Future<String?> getApplicationCachePath() => _base.getApplicationCachePath();
  @override
  Future<String?> getExternalStoragePath() => _base.getExternalStoragePath();
  @override
  Future<List<String>?> getExternalCachePaths() => _base.getExternalCachePaths();
  @override
  Future<List<String>?> getExternalStoragePaths({StorageDirectory? type}) => _base.getExternalStoragePaths(type: type);
  @override
  Future<String?> getDownloadsPath() => _base.getDownloadsPath();
}
