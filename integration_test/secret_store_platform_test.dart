import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:jj_mkvmaker/services/secret_store.dart';

/// 54: 이 기기의 안전 저장소 (Windows DPAPI · Android Keystore) 에 실제로 쓰고 읽고 지운다.
/// 시험용 열쇠 하나만 쓰고 끝에 지운다 (사용자가 저장한 값은 건드리지 않음).
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('안전 저장소: 쓰기 · 읽기 · 지우기', (t) async {
    final s = SecretStore.platform();
    const key = 'jj.selftest';
    await s.write(key, '비밀-1');
    expect((await s.readAll())[key], '비밀-1');
    await s.write(key, '비밀-2');
    expect((await s.readAll())[key], '비밀-2');
    await s.delete(key);
    expect((await s.readAll()).containsKey(key), isFalse);
  });
}
