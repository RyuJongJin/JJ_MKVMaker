import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jj_mkvmaker/app/settings.dart';
import 'package:jj_mkvmaker/app/version_snapshot.dart';
import 'package:jj_mkvmaker/core/webdav.dart';
import 'package:jj_mkvmaker/services/secret_store.dart';
import 'package:path/path.dart' as p;

/// 40 · 54: 비밀번호는 설정 파일에 평문으로 쓰지 않고 안전 저장소에. 한 번 넣으면 업데이트 · 예전 판 · 되살리기 뒤에도 남는다
void main() {
  late Directory dir;
  late String file;
  late MemorySecretStore secrets;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('jj_secret_');
    file = p.join(dir.path, 'settings.json');
    secrets = MemorySecretStore();
  });
  tearDown(() => dir.deleteSync(recursive: true));

  SettingsStore store() => SettingsStore(file, secrets);
  String text(String f) => File(f).readAsStringSync();

  test('예전 평문 비밀번호: 처음 켤 때 안전 저장소로 옮기고 settings.json · .bak 에서 지운다 · 모르는 항목은 그대로', () async {
    File(file).writeAsStringSync(jsonEncode({
      'homeUrl': 'https://a.example',
      'openSubtitlesKey': 'KEY-1',
      'openSubtitlesUser': 'me',
      'openSubtitlesPassword': 'os-pw',
      'webdavServers': [
        {'id': 'd1', 'name': 'nas', 'url': 'https://nas', 'user': 'u', 'password': 'dav-pw'},
      ],
      'futureFeature': {'x': 1},
    }));
    final s = await store().load();
    expect(s.openSubtitlesKey, 'KEY-1');
    expect(s.openSubtitlesPassword, 'os-pw');
    expect(s.webdavServers.single.password, 'dav-pw');
    expect(secrets.values.values, containsAll(['KEY-1', 'me', 'os-pw', 'dav-pw']));
    for (final f in [file, '$file.bak']) {
      expect(text(f), isNot(contains('dav-pw')), reason: f);
      expect(text(f), isNot(contains('os-pw')), reason: f);
      expect(text(f), isNot(contains('KEY-1')), reason: f);
    }
    final j = jsonDecode(text(file)) as Map;
    expect(j['futureFeature'], {'x': 1});
    expect((j['webdavServers'] as List).single['hasPassword'], isTrue);
    expect(j['openSubtitlesSaved'], {'key': true, 'user': true, 'password': true});
    // 다시 켜도 그대로
    final again = await store().load();
    expect(again.webdavServers.single.password, 'dav-pw');
    expect(again.openSubtitlesKey, 'KEY-1');
  });

  test('예전 판이 서버 목록 · 비밀 값을 지운 설정 파일을 써도 되살아난다', () async {
    final st = store();
    await st.load();
    await st.save(AppSettings()
      ..openSubtitlesKey = 'KEY-2'
      ..webdavServers = [const DavServer(id: 'd1', name: 'nas', url: 'https://nas', user: 'u', password: 'pw')]);
    // 예전 판: 모르는 항목을 지우고 저장
    File(file).writeAsStringSync(jsonEncode({'homeUrl': 'https://old.example'}));
    final s = await store().load();
    expect(s.homeUrl, 'https://old.example');
    expect(s.webdavServers.single.url, 'https://nas');
    expect(s.webdavServers.single.password, 'pw');
    expect(s.openSubtitlesKey, 'KEY-2');
    // 사용자가 일부러 서버를 모두 지웠으면 (목록 항목은 있음) 되살리지 않는다
    final st2 = store();
    final s2 = await st2.load();
    await st2.save(s2..webdavServers = []);
    expect((await store().load()).webdavServers, isEmpty);
  });

  test('비밀번호를 지우거나 서버를 지우면 안전 저장소에서도 지운다', () async {
    final st = store();
    final s = await st.load();
    s.webdavServers = [
      const DavServer(id: 'a', name: 'a', url: 'https://a', password: 'pa'),
      const DavServer(id: 'b', name: 'b', url: 'https://b', password: 'pb'),
    ];
    s.openSubtitlesPassword = 'x';
    await st.save(s);
    expect(secrets.values.values, containsAll(['pa', 'pb', 'x']));
    s.webdavServers = [s.webdavServers.first];
    s.openSubtitlesPassword = '';
    await st.save(s);
    expect(secrets.values.values, isNot(contains('pb')));
    expect(secrets.values.values, isNot(contains('x')));
    expect(secrets.values.values, contains('pa'));
  });

  test('안전 저장소를 읽지 못하면: 저장소를 건드리지 않고 파일의 예전 값도 잃지 않는다', () async {
    secrets.values['dav.pw.d1'] = 'kept';
    secrets.failRead = true;
    File(file).writeAsStringSync(jsonEncode({
      'openSubtitlesKey': 'KEY-3',
      'webdavServers': [
        {'id': 'd1', 'name': 'nas', 'url': 'https://nas', 'password': 'plain'},
      ],
    }));
    final st = store();
    final s = await st.load();
    expect(s.openSubtitlesKey, 'KEY-3');
    await st.save(s..homeUrl = 'https://x.example');
    expect(text(file), contains('KEY-3'));
    expect(text(file), contains('plain'));
    expect(secrets.values, {'dav.pw.d1': 'kept'});
  });

  test('버전 보관본으로 되살려도 비밀번호는 안전 저장소의 것이 그대로', () async {
    final st = store();
    final s = await st.load();
    s.webdavServers = [const DavServer(id: 'd1', name: 'nas', url: 'https://nas', user: 'u', password: 'pw')];
    await st.save(s);
    final snap = VersionSnapshot(dir.path);
    await snap.save('1.0');
    expect(text(p.join(snap.dirOf('1.0'), 'settings.json')), isNot(contains('"pw"')));
    await snap.restoreFrom(snap.dirOf('1.0'));
    expect((await store().load()).webdavServers.single.password, 'pw');
  });

  test('40-1: 안전 저장소에 쓰지 못하면 예전 평문은 파일에 그대로 · 새 값은 평문으로 쓰지 않음 · 알림 · [다시 시도]', () async {
    File(file).writeAsStringSync(jsonEncode({
      'webdavServers': [
        {'id': 'd1', 'name': 'nas', 'url': 'https://nas', 'user': 'u', 'password': 'old-pw'},
      ],
    }));
    secrets.failWrite = true;
    final st = store();
    final s = await st.load();
    expect(st.secretIssue.value?.kind, SecretIssueKind.writeFailed);
    for (final f in [file, '$file.bak']) {
      if (File(f).existsSync()) expect(text(f), contains('old-pw'), reason: f);
    }
    // 다시 켜도 비밀번호가 남아 있다
    expect((await SettingsStore(file, secrets).load()).webdavServers.single.password, 'old-pw');
    // 새 비밀번호: 저장소에 못 쓰면 파일에 평문으로 쓰지 않는다 (예전 값은 그대로)
    s.webdavServers = [s.webdavServers.single.copyWith(password: 'new-pw')];
    await st.save(s);
    expect(text(file), isNot(contains('new-pw')));
    expect(text(file), contains('old-pw'));
    expect(st.secretIssue.value?.kind, SecretIssueKind.writeFailed);
    // 다시 시도: 저장소에 들어가면 파일 · .bak 에서 평문을 지우고 알림도 사라진다
    secrets.failWrite = false;
    expect(await st.retrySecrets(s), isTrue);
    expect(secrets.values['dav.pw.d1'], 'new-pw');
    expect(st.secretIssue.value, isNull);
    await st.save(s); // .bak 도 새로
    for (final f in [file, '$file.bak']) {
      expect(text(f), isNot(contains('old-pw')), reason: f);
      expect(text(f), isNot(contains('new-pw')), reason: f);
    }
  });

  test('40-3: 안전 저장소를 읽지 못한 실행에서 넣은 비밀번호 - 평문으로 쓰지 않고 알림 · [다시 시도] 로 저장', () async {
    secrets.failRead = true;
    final st = store();
    final s = await st.load();
    expect(st.secretIssue.value?.kind, SecretIssueKind.readFailed);
    s.webdavServers = [const DavServer(id: 'd1', name: 'nas', url: 'https://nas', user: 'u', password: 'typed')];
    await st.save(s);
    expect(text(file), isNot(contains('typed')));
    expect(secrets.values, isEmpty);
    expect(st.secretIssue.value?.kind, SecretIssueKind.readFailed);
    secrets.failRead = false;
    expect(await st.retrySecrets(s), isTrue);
    expect(secrets.values['dav.pw.d1'], 'typed');
    expect(st.secretIssue.value, isNull);
  });

  test('40-2: 서버 비밀번호를 바꾸면 다시 켜지 않아도 바로 새 비밀번호로 접속', () {
    DavRegistry.configure([const DavServer(id: 'd1', name: 'nas', url: 'https://nas', user: 'u', password: 'a')]);
    expect(DavRegistry.client('d1').server.password, 'a');
    DavRegistry.configure([const DavServer(id: 'd1', name: 'nas', url: 'https://nas', user: 'u', password: 'b')]);
    expect(DavRegistry.client('d1').server.password, 'b');
    DavRegistry.configure([]);
  });

  test('40-4: 깨진 설정 파일의 보관본 · 오류 글에 비밀 값이 없고, .bak 으로 되살리면 .bak 의 평문도 지운다', () async {
    File('$file.bak').writeAsStringSync(jsonEncode({
      'openSubtitlesPassword': 'bak-secret',
      'webdavServers': [
        {'id': 'd1', 'name': 'nas', 'url': 'https://nas', 'password': 'bak-pw'},
      ],
    }));
    File(file).writeAsStringSync('{"openSubtitlesKey": "broken-secret", "webdavServers": [{"id": "d1", "password": "x\\"y"}');
    final st = store();
    final s = await st.load();
    expect(st.problem!.restoredFromBackup, isTrue);
    expect(st.problem!.error, isNot(contains('broken-secret')));
    final kept = File(st.problem!.brokenCopy!).readAsStringSync();
    expect(kept, isNot(contains('broken-secret')));
    expect(kept, isNot(contains(r'x\"y')));
    expect(kept, contains('"openSubtitlesKey": ""'));
    // .bak 의 값은 저장소로 옮기고 .bak 에서 지운다
    expect(s.webdavServers.single.password, 'bak-pw');
    expect(secrets.values['os.password'], 'bak-secret');
    expect(text('$file.bak'), isNot(contains('bak-pw')));
    expect(text('$file.bak'), isNot(contains('bak-secret')));
  });

  test('40-5: 안전 저장소를 풀 수 없어 새로 시작했으면 켤 때 알림 (보관한 곳 포함)', () async {
    secrets.lostCopy = r'C:\x\secrets.broken-1.dat';
    final st = store();
    await st.load();
    expect(st.secretIssue.value?.kind, SecretIssueKind.lost);
    expect(st.secretIssue.value?.kept, r'C:\x\secrets.broken-1.dat');
  });
}
