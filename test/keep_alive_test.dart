import 'package:flutter_test/flutter_test.dart';
import 'package:jj_mkvmaker/platform/android/android_keep_alive.dart';

void main() {
  test('Android 진행 알림 글 · 진행률', () {
    // 진행 중인 일이 없으면 알림을 내린다
    expect(AndroidKeepAlive.status(null, false, 0, null), (null, -1));
    // 다운로드만: 진행률 막대
    expect(AndroidKeepAlive.status(null, false, 2, 0.456), ('다운로드 2개 · 46%', 46));
    expect(AndroidKeepAlive.status(null, false, 1, null), ('다운로드 1개', -1));
    // 작업 (MKV · AI) 이 있으면 글만
    expect(AndroidKeepAlive.status('MKV 만들기', true, 0, null), ('MKV 만들기', -1));
    expect(AndroidKeepAlive.status('AI 자막', true, 1, 0.5), ('AI 자막 · 다운로드 1개 · 50%', -1));
  });
}
