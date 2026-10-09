import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:jj_mkvmaker/platform/windows/desktop_shell.dart';
import 'package:nativeapi/nativeapi.dart' as native;

/// 92: Windows 알림 (토스트) 이 실제로 뜨는지 (화면 오른쪽 아래에 시험 알림)
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Windows 토스트 띄우기', (t) async {
    // ignore: avoid_print
    print('NOTIFY_NATIVE supported=${native.NotificationManager.instance.isSupported()}');
    final ok = await DesktopShell().notify('JJ_MKVMaker 알림 시험', '실시간 동기화 멈춤 알림 시험입니다 (92).\n무시해도 됩니다.');
    // ignore: avoid_print
    print('NOTIFY_RESULT $ok');
    expect(ok, isTrue);
  });
}
