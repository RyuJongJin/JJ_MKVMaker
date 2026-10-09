import 'dart:io';

import 'package:path/path.dart' as p;

/// 115: Android 자동 백업 (allowBackup) 은 앱을 지웠다 다시 깔면 설정 · 동영상 목록을 말없이 되살린다.
/// 이 표시 파일은 백업에서 빼 두었으므로 (res/xml/backup_rules · data_extraction_rules),
/// "설치 직후 처음 켰는데 설정 파일은 있고 표시 파일은 없다" 면 자동 백업에서 되살아난 것이다.
class InstallMarker {
  InstallMarker(this.dataDir);

  final String dataDir;
  static const fileName = 'install_marker';

  File get _file => File(p.join(dataDir, fileName));

  bool get exists => _file.existsSync();

  void write() {
    try {
      _file.writeAsStringSync(DateTime.now().toIso8601String());
    } catch (_) {}
  }
}

/// 자동 백업에서 되살아났는지: 설정 파일이 켜기 전부터 있었고, 표시 파일이 없고,
/// 새로 설치한 뒤 업데이트한 적이 없다 (업데이트로 처음 이 판을 켠 경우와 구분 - 업데이트는 설치 시각과 업데이트 시각이 다르다)
bool restoredByAutoBackup({
  required bool settingsExisted,
  required bool markerExists,
  required DateTime? installTime,
  required DateTime? updateTime,
}) {
  if (!settingsExisted || markerExists || installTime == null || updateTime == null) return false;
  return updateTime.difference(installTime).inSeconds.abs() < 5;
}
