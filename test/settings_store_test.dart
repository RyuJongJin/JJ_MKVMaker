import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jj_mkvmaker/app/settings.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory dir;
  late String file;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('jj_settings_');
    file = p.join(dir.path, 'settings.json');
  });
  tearDown(() => dir.deleteSync(recursive: true));

  test('저장: 임시 파일에 쓴 뒤 바꿔치기 · 직전 정상본은 .bak · 남는 임시 파일 없음', () async {
    final store = SettingsStore(file);
    await store.save(AppSettings()..homeUrl = 'https://a.example');
    await store.save(AppSettings()..homeUrl = 'https://b.example');
    expect((await SettingsStore(file).load()).homeUrl, 'https://b.example');
    expect(File('$file.bak').readAsStringSync(), contains('https://a.example'));
    expect(File('$file.tmp').existsSync(), isFalse);
    // 여러 번 빠르게 저장해도 마지막 것이 남는다 (순서대로)
    await Future.wait([for (var i = 0; i < 5; i++) store.save(AppSettings()..homeUrl = 'https://$i.example')]);
    expect((await SettingsStore(file).load()).homeUrl, 'https://4.example');
  });

  test('깨진 설정 파일: 백업으로 되살리고, 깨진 파일은 보관 · 알림 정보', () async {
    final store = SettingsStore(file);
    await store.save(AppSettings()..homeUrl = 'https://good.example');
    await store.save(AppSettings()..homeUrl = 'https://good2.example'); // .bak = good
    File(file).writeAsStringSync('{"homeUrl": "https://half'); // 반쯤 쓰다 끊긴 파일
    final s = await store.load();
    expect(s.homeUrl, 'https://good.example');
    expect(store.problem!.restoredFromBackup, isTrue);
    final kept = store.problem!.brokenCopy!;
    expect(File(kept).readAsStringSync(), '{"homeUrl": "https://half');
    // 다음 저장이 좋은 백업을 깨진 파일로 덮지 않는다
    await store.save(s);
    expect(File('$file.bak').readAsStringSync(), contains('good'));
  });

  test('깨졌고 백업도 없음: 처음 설정 + 알림, 깨진 파일 보관 / settings.json 만 없으면 백업으로', () async {
    File(file).writeAsStringSync('not json');
    final store = SettingsStore(file);
    final s = await store.load();
    expect(s.homeUrl, AppSettings().homeUrl);
    expect(store.problem!.restoredFromBackup, isFalse);
    expect(File(store.problem!.brokenCopy!).readAsStringSync(), 'not json');

    // 바꿔치기 도중 끝나 settings.json 이 없고 .bak 만 있는 경우
    File(file).deleteSync();
    File('$file.bak').writeAsStringSync('{"homeUrl": "https://bak.example"}');
    final again = SettingsStore(file);
    expect((await again.load()).homeUrl, 'https://bak.example');
    expect(again.problem!.restoredFromBackup, isTrue);
    // 정상이면 알림 없음
    await again.save(AppSettings());
    await again.load();
    expect(again.problem, isNull);
  });
}
