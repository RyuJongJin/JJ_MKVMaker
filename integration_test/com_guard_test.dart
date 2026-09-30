import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:jj_mkvmaker/platform/windows/com_guard.dart';
import 'package:jj_mkvmaker/ui/browser_page.dart';

/// 실제 Edge(WebView2): 다른 구성 요소가 COM 준비 상태를 풀어 버린 상황을 만들고
/// (브라우저가 "CoInitialize 가 호출되지 않았습니다" 로 안 뜨던 문제) 그래도 브라우저 환경이 만들어지는지
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('COM 이 풀려 있어도 브라우저 환경을 만든다', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));

    // 1. 화면을 그리는 스레드 = 실행 파일이 COM 을 준비한 스레드인지 (그래야 여기서 다시 준비한 것이 통한다)
    final first = ComGuard.ensure();
    // ignore: avoid_print
    print('RESULT 처음 확인: $first (1 = 이미 준비되어 있음 → 같은 스레드)');
    expect(first, 1);
    ComGuard.releaseForTest(); // 방금 올린 만큼 내림

    // 2. 준비 상태를 끝까지 푼다 (문제 상황). 여러 구성 요소가 겹쳐 준비해 두므로 넉넉히 여러 번.
    for (var i = 0; i < 8; i++) {
      ComGuard.releaseForTest();
    }
    final dir = Directory.systemTemp.createTempSync('jj_com_').path;
    final raw = await tester.runAsync<Object?>(() async {
      try {
        await WebViewEnvironment.create(settings: WebViewEnvironmentSettings(userDataFolder: '${dir}_raw'));
        return null;
      } catch (e) {
        return e;
      }
    });
    // ignore: avoid_print
    print('RESULT 풀린 상태에서 그냥 만들기: ${raw ?? '성공'}');
    expect('$raw', contains('Cannot create WebViewEnvironment'));

    // 3. 앱의 방식 (만들기 전에 다시 준비) 으로는 만들어진다
    for (var i = 0; i < 8; i++) {
      ComGuard.releaseForTest();
    }
    final env = await tester.runAsync(() => browserEnvironment(dir));
    // ignore: avoid_print
    print('RESULT 앱 방식으로 만들기: ${env == null ? '실패' : '성공'}');
    expect(env, isNotNull);
  }, timeout: const Timeout(Duration(minutes: 2)));
}
