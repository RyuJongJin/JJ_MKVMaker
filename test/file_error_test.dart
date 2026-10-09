import 'package:flutter_test/flutter_test.dart';
import 'package:jj_mkvmaker/ui/file_error.dart';

void main() {
  test('50: Android 가 막은 폴더 (Android/data · obb) 알아보기', () {
    for (final p in [
      '/storage/emulated/0/Android/data',
      '/storage/emulated/0/Android/data/com.example.app',
      '/storage/emulated/0/Android/obb/',
      '/storage/1234-ABCD/Android/data/x',
    ]) {
      expect(isAndroidRestricted(p, android: true), isTrue, reason: p);
    }
    for (final p in [
      '/storage/emulated/0/Android',
      '/storage/emulated/0/Android/media',
      '/storage/emulated/0/Download/Android/datas',
      '/storage/emulated/0/Movies',
    ]) {
      expect(isAndroidRestricted(p, android: true), isFalse, reason: p);
    }
    // Windows 등은 해당 없음
    expect(isAndroidRestricted('/storage/emulated/0/Android/data', android: false), isFalse);
  });

  test('50: 막힌 폴더는 "이 폴더는 Android 가 막아 볼 수 없습니다" 와 할 일', () {
    final (title, body) = explainFileError(androidRestrictedError, dav: false);
    expect(title, '이 폴더는 Android 가 막아 볼 수 없습니다');
    expect(body, contains('내보내기'));
  });
}
