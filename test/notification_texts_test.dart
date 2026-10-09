import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jj_mkvmaker/app/i18n_controller.dart';
import 'package:jj_mkvmaker/platform/android/android_keep_alive.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('57: Android 알림 글 · 채널 이름이 화면 언어로 (Kotlin 이 아는 열쇠와 같게)', () async {
    final ko = AndroidKeepAlive.notificationTexts();
    // Kotlin (KeepAliveService.defaults) 의 열쇠와 한국어 기본 글이 Dart 와 같다 - 한쪽만 고치면 어긋난다
    final kt = File('android/app/src/main/kotlin/com/jj/jj_mkvmaker/KeepAliveService.kt').readAsStringSync();
    final defaults = {
      for (final m in RegExp(r'"(\w+)" to "((?:[^"\\]|\\.)*)"').allMatches(kt)) m.group(1)!: m.group(2)!,
    };
    expect(defaults, ko);

    await i18n.apply('ja', save: false);
    try {
      final ja = AndroidKeepAlive.notificationTexts();
      expect(ja['working'], 'JJ_MKVMaker 作業中');
      expect(ja['jobsChannel'], '作業の進行');
      expect(ja['doneChannel'], '完了した作業');
      for (final k in ko.keys) {
        expect(ja[k], isNot(ko[k]), reason: '$k 가 번역되지 않음');
      }
    } finally {
      await i18n.apply('ko', save: false);
    }
  });
}
