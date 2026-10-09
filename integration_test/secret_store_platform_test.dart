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

  testWidgets('130: 두 창 (저장소 두 개) 이 번갈아 써도 서로의 값을 지우지 않는다', (t) async {
    const a = 'jj.selftest.a', b = 'jj.selftest.b';
    final first = SecretStore.platform(), second = SecretStore.platform();
    try {
      await first.readAll(); // 첫 창이 읽어 둠
      await second.write(b, '두 번째 창'); // 두 번째 창이 씀
      await first.write(a, '첫 창'); // 첫 창이 쓸 때 두 번째 창의 값을 지우면 안 된다
      final now = await SecretStore.platform().readAll();
      expect(now[a], '첫 창');
      expect(now[b], '두 번째 창');
      await second.delete(b); // 두 번째 창이 지울 때 첫 창의 값을 되살리거나 지우면 안 된다
      final after = await first.readAll();
      expect(after[a], '첫 창');
      expect(after.containsKey(b), isFalse);
    } finally {
      await SecretStore.platform().delete(a);
      await SecretStore.platform().delete(b);
    }
    final end = await SecretStore.platform().readAll();
    expect(end.containsKey(a) || end.containsKey(b), isFalse);
  });
}
