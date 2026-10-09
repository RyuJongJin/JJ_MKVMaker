import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jj_mkvmaker/app/version_snapshot.dart';
import 'package:jj_mkvmaker/core/app_update.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory data;
  setUp(() => data = Directory.systemTemp.createTempSync('jj_snap_'));
  tearDown(() => data.deleteSync(recursive: true));

  void writeSettings(Map<String, dynamic> j) => File(p.join(data.path, 'settings.json')).writeAsStringSync(jsonEncode(j));
  Map<String, dynamic> readSettings() =>
      jsonDecode(File(p.join(data.path, 'settings.json')).readAsStringSync()) as Map<String, dynamic>;

  test('보관 (비밀 값 빼고) → 다른 버전이 설정을 쓴 뒤 → 되살리기 (지금 비밀 값은 그대로)', () async {
    final snap = VersionSnapshot(data.path);
    writeSettings({'uiLanguage': 'ja', 'newOption': 7, 'lastRunVersion': '2.0.0', 'openSubtitlesKey': 'OLD-KEY'});
    File(p.join(data.path, 'videos.json')).writeAsStringSync('["a.mkv"]');
    expect(snap.has('2.0.0'), isFalse);
    await snap.save('2.0.0');
    expect(snap.has('2.0.0'), isTrue);
    expect(File(p.join(snap.dirOf('2.0.0'), 'settings.json')).readAsStringSync(), isNot(contains('OLD-KEY')));
    // 예전 버전이 실행되며 설정을 저장: 모르는 항목 (newOption · lastRunVersion) 이 사라짐, 키는 새로 넣음
    writeSettings({'uiLanguage': 'en', 'openSubtitlesKey': 'NEW-KEY'});
    File(p.join(data.path, 'videos.json')).writeAsStringSync('[]');
    expect(snap.shouldOffer('2.0.0', ''), isTrue); // 2.0.0 으로 돌아옴 · 마지막 실행 버전이 비어 있음
    expect(snap.shouldOffer('2.0.0', '2.0.0'), isFalse);
    expect(snap.shouldOffer('1.0.0', ''), isFalse); // 보관본 없는 버전
    await snap.restoreFrom(snap.dirOf('2.0.0'));
    final j = readSettings();
    expect([j['uiLanguage'], j['newOption'], j['lastRunVersion'], j['openSubtitlesKey']], ['ja', 7, '2.0.0', 'NEW-KEY']);
    expect(File(p.join(data.path, 'videos.json')).readAsStringSync(), '["a.mkv"]');
  });

  test('공용 폴더 (Android, 앱을 다시 설치해도 남음): 같은 버전, 없으면 가장 최근', () async {
    final shared = p.join(data.path, 'shared');
    final snap = VersionSnapshot(data.path, sharedDir: shared);
    writeSettings({'a': 1});
    await snap.save('2026.10.05_003');
    await snap.save('2026.10.07_001');
    expect(File(p.join(shared, '2026.10.05_003', 'settings.json')).existsSync(), isTrue);
    // 한국어 이름 폴더 ("설정 보관") 를 알아보게 README.txt (영어 · 한국어) - 보관본 고르기에는 끼지 않는다
    expect(File(p.join(shared, 'README.txt')).readAsStringSync(), startsWith('JJ_MKVMaker settings backup / 설정 보관'));
    expect(p.basename(snap.sharedFor('2026.10.05_003')!), '2026.10.05_003');
    expect(p.basename(snap.sharedFor('2026.10.01_001')!), '2026.10.07_001');
    expect(VersionSnapshot(data.path).sharedFor('x'), isNull);
  });

  test('릴리스 목록: 초안 빼고 · 시험판 표시 · 새 버전이 앞 · 올린 때', () {
    Map<String, dynamic> rel(String tag, {bool draft = false, bool pre = false}) => {
          'tag_name': tag,
          'draft': draft,
          'prerelease': pre,
          'published_at': '2026-10-04T18:22:00Z',
          'assets': [
            {'name': 'JJ_MKVMaker_${tag}_win64.zip', 'browser_download_url': 'https://x/$tag.zip', 'size': 1},
          ],
        };
    final list = parseReleaseList([
      rel('v2026.10.04_012'),
      rel('v2026.10.05_003'),
      rel('v2026.10.06_001', draft: true),
      rel('v2026.10.05_004', pre: true),
    ]);
    expect(list.map((r) => r.version), ['2026.10.05_004', '2026.10.05_003', '2026.10.04_012']);
    expect(list.first.prerelease, isTrue);
    expect(list.first.published, DateTime.utc(2026, 10, 4, 18, 22));
    expect(parseLatestRelease(rel('v2026.10.05_004', pre: true)), isNull); // 자동 확인은 시험판 제외 그대로
  });
}
