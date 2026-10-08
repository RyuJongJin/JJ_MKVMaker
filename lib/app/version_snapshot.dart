import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../core/app_update.dart';

/// 버전을 바꿀 때 (업데이트 · 예전 버전으로 되돌리기) 그 버전의 설정을 보관하고, 그 버전으로 돌아오면 되살린다.
///
/// 예전 버전은 새 버전에만 있는 설정 항목을 몰라 저장하면서 지워 버릴 수 있다. 그래서 다른 버전을 설치하기 전에
/// 지금 버전의 설정 파일들을 `version_snapshots/<버전>/` 에 두고, 다시 그 버전이 켜졌을 때
/// (설정의 [lastRunVersion] 이 자기 버전이 아니면 = 그사이 다른 버전이 설정을 썼으면) 되살릴지 묻는다.
/// 예전 버전의 업데이트 코드는 이 기능을 모르므로 되살리기는 돌아온 버전이 시작할 때 스스로 한다.
///
/// 비밀 값 (API 키 · 비밀번호) 은 보관본에 넣지 않는다. 되살릴 때는 지금 설정의 비밀 값을 그대로 둔다.
class VersionSnapshot {
  /// 앱 데이터 폴더 (settings.json 등이 있는 곳)
  final String dataDir;

  /// Android: 앱을 지웠다 다시 설치해도 남는 공용 폴더 (Download/JJ_MKVMaker/설정 보관). 없으면 null.
  final String? sharedDir;

  VersionSnapshot(this.dataDir, {this.sharedDir});

  /// 앱에서 쓰는 것 (시작할 때 main 이 정한다)
  static VersionSnapshot? instance;

  /// 보관하는 파일 (설정 · 동영상 목록 · 즐겨찾기 · 창 위치)
  static const files = ['settings.json', 'videos.json', 'bookmarks.json', 'window.json'];

  /// 보관본에 넣지 않는 설정 항목 (사용자가 다른 곳에 두지 말라고 한 비밀 값)
  static const secretKeys = ['openSubtitlesKey', 'openSubtitlesUser', 'openSubtitlesPassword'];

  String get root => p.join(dataDir, 'version_snapshots');
  String dirOf(String version) => p.join(root, version);

  /// 이 버전의 보관본이 있는지
  bool has(String version) => File(p.join(dirOf(version), 'settings.json')).existsSync();

  /// 지금 버전 ([version]) 의 설정을 보관한다 (같은 버전의 보관본은 새것으로). 공용 폴더에도 (있으면).
  Future<void> save(String version) async {
    for (final dir in [dirOf(version), if (sharedDir != null) p.join(sharedDir!, version)]) {
      final d = Directory(dir);
      if (await d.exists()) await d.delete(recursive: true);
      await d.create(recursive: true);
      for (final f in files) {
        final src = File(p.join(dataDir, f));
        if (!await src.exists()) continue;
        final dst = File(p.join(dir, f));
        if (f == 'settings.json') {
          await dst.writeAsString(_withoutSecrets(await src.readAsString()));
        } else {
          await src.copy(dst.path);
        }
      }
      await File(p.join(dir, 'snapshot.json'))
          .writeAsString(jsonEncode({'version': version, 'saved': DateTime.now().toIso8601String()}));
    }
  }

  /// 보관본 [from] (폴더) 을 데이터 폴더로 되살린다. 비밀 값은 지금 설정의 것을 그대로 둔다.
  Future<void> restoreFrom(String from) async {
    final current = File(p.join(dataDir, 'settings.json'));
    Map<String, dynamic> secrets = {};
    Map<String, Object?> davPasswords = {};
    if (await current.exists()) {
      try {
        final j = jsonDecode(await current.readAsString()) as Map<String, dynamic>;
        secrets = {for (final k in secretKeys) if (j[k] != null) k: j[k]};
        final servers = j['webdavServers'];
        if (servers is List) {
          davPasswords = {
            for (final s in servers)
              if (s is Map && s['id'] != null && s['password'] != null) '${s['id']}': s['password'],
          };
        }
      } catch (_) {}
    }
    for (final f in files) {
      final src = File(p.join(from, f));
      if (!await src.exists()) continue;
      final dst = File(p.join(dataDir, f));
      if (f == 'settings.json') {
        final j = jsonDecode(await src.readAsString()) as Map<String, dynamic>;
        j.addAll(secrets);
        final servers = j['webdavServers'];
        if (servers is List) {
          for (final s in servers) {
            if (s is Map && davPasswords.containsKey('${s['id']}')) s['password'] = davPasswords['${s['id']}'];
          }
        }
        await dst.writeAsString(const JsonEncoder.withIndent('  ').convert(j));
      } else {
        await src.copy(dst.path);
      }
    }
  }

  /// 앱을 다시 설치해 설정이 없을 때 (Android 에서 예전 버전으로 되돌리면 앱을 지워야 함):
  /// 공용 폴더에 남겨 둔 보관본 중 가장 가까운 것 (같은 버전, 없으면 가장 최근) 의 폴더. 없으면 null.
  String? sharedFor(String version) {
    final s = sharedDir;
    if (s == null || !Directory(s).existsSync()) return null;
    final same = p.join(s, version);
    if (File(p.join(same, 'settings.json')).existsSync()) return same;
    final all = Directory(s)
        .listSync()
        .whereType<Directory>()
        .where((d) => File(p.join(d.path, 'settings.json')).existsSync())
        .toList()
      ..sort((a, b) => compareVersions(p.basename(b.path), p.basename(a.path)));
    return all.isEmpty ? null : all.first.path;
  }

  static String _withoutSecrets(String settingsJson) {
    try {
      final j = jsonDecode(settingsJson) as Map<String, dynamic>;
      for (final k in secretKeys) {
        j.remove(k);
      }
      // WebDAV 서버의 비밀번호
      final servers = j['webdavServers'];
      if (servers is List) {
        for (final s in servers) {
          if (s is Map) s.remove('password');
        }
      }
      return const JsonEncoder.withIndent('  ').convert(j);
    } catch (_) {
      return '{}';
    }
  }

  /// 시작할 때 되살릴지: 이 버전의 보관본이 있고, 마지막으로 설정을 쓴 버전이 이 버전이 아니면
  /// (예전 버전이 그사이 설정을 썼으면 [lastRunVersion] 이 다르거나 비어 있다).
  bool shouldOffer(String current, String lastRunVersion) => has(current) && lastRunVersion != current;
}
