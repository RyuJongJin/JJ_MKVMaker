import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jj_mkvmaker/app/settings.dart';
import 'package:jj_mkvmaker/services/app_shell.dart';

void main() {
  test('앱 아이콘 설정: 기본은 노랑, 저장 · 불러오기, 모르는 값은 기본으로', () {
    expect(AppSettings().appIcon, 'yellow');
    final s = AppSettings()..appIcon = 'black';
    expect(AppSettings.fromJson(s.toJson()).appIcon, 'black');
    expect(AppSettings.fromJson({'appIcon': 'nope'}).appIcon, 'yellow');
    expect(AppSettings.fromJson({}).appIcon, 'yellow');
  });

  test('아이콘마다 그림 파일 (설정 미리보기 · 앱 안 버튼 · Windows ico · Android 런처) 이 있다', () {
    for (final id in appIconIds) {
      expect(File(appIconPreviewAsset(id)).existsSync(), isTrue, reason: id);
      expect(File(appIconButtonAsset(id)).existsSync(), isTrue, reason: id);
      expect(File('assets/icon/variants/$id.ico').existsSync(), isTrue, reason: id);
      expect(File('android/app/src/main/res/mipmap-anydpi-v26/ic_launcher_$id.xml').existsSync(), isTrue, reason: id);
      expect(File('android/app/src/main/res/mipmap-xxxhdpi/ic_launcher_$id.png').existsSync(), isTrue, reason: id);
    }
    // Android: 아이콘마다 activity-alias 하나 (처음에는 기본만 켜짐)
    final manifest = File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
    for (final id in appIconIds) {
      expect(manifest, contains('@mipmap/ic_launcher_$id"'), reason: id);
    }
    expect('android:enabled="true"'.allMatches(manifest).length, 1);
  });
}
