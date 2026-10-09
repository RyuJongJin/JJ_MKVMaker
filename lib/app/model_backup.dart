import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'component_store.dart' show AccumulatorSink;
import 'folder_readme.dart';

/// P0 (되돌리기): Android 에서 예전 버전으로 되돌리면 앱을 지워야 해서 앱 안에 받은 AI 모델이 사라진다.
/// 공용 폴더 (Download/JJ_MKVMaker/AI 모델 보관) 에 옮겨 두었다가, 다시 설치한 앱 (이 기능이 있는 판) 이 켜질 때
/// SHA-256 을 확인하며 되살리고 공용 폴더의 사본은 지운다.
///
/// [roots]: 보관할 폴더들 (이름 → 경로, 예: 'ai' → 앱 데이터/ai, 'models' → 자막 모델 폴더)
class ModelBackup {
  ModelBackup(this.dir);

  /// 보관 폴더 (Download/JJ_MKVMaker/AI 모델 보관)
  final String dir;

  /// 공용 폴더 Download/JJ_MKVMaker (Android, main 에서 정함)
  static String? sharedRoot;

  // l10n-skip: 실제 폴더 이름 (예전 보관을 찾아야 하므로 바꾸지 않음)
  static ModelBackup? get shared => sharedRoot == null ? null : ModelBackup(p.join(sharedRoot!, 'AI 모델 보관'));

  File get _manifest => File(p.join(dir, 'manifest.json'));

  /// 되살릴 보관본이 있는지
  bool get exists => _manifest.existsSync();

  /// 받다 만 조각 · 임시 파일은 보관하지 않는다
  static bool _skip(String path) {
    final n = p.basename(path).toLowerCase();
    return n.endsWith('.part') || n.endsWith('.jjpart') || n.endsWith('.tmp');
  }

  static Iterable<(String root, String rel, File f)> _files(Map<String, String> roots) sync* {
    for (final e in roots.entries) {
      final d = Directory(e.value);
      if (!d.existsSync()) continue;
      for (final f in d.listSync(recursive: true, followLinks: false).whereType<File>()) {
        if (_skip(f.path)) continue;
        yield (e.key, p.relative(f.path, from: e.value), f);
      }
    }
  }

  /// 보관할 크기 (바이트)
  static int sizeOf(Map<String, String> roots) {
    var n = 0;
    for (final (_, _, f) in _files(roots)) {
      try {
        n += f.lengthSync();
      } catch (_) {}
    }
    return n;
  }

  /// 파일을 복사하며 SHA-256 을 잰다
  static Future<String> _copyHashed(File from, File to, void Function(int n)? onBytes) async {
    await to.parent.create(recursive: true);
    final out = to.openWrite();
    final sink = AccumulatorSink<Digest>();
    final hash = sha256.startChunkedConversion(sink);
    try {
      await for (final chunk in from.openRead()) {
        out.add(chunk);
        hash.add(chunk);
        onBytes?.call(chunk.length);
      }
    } finally {
      await out.close();
    }
    hash.close();
    return sink.events.single.toString();
  }

  /// [roots] 의 파일을 보관 폴더로 복사하고 목록 (경로 · 크기 · SHA-256) 을 남긴다. 실패하면 만든 것을 지우고 다시 던진다.
  Future<int> save(Map<String, String> roots, {void Function(int done, int total)? onProgress}) async {
    final d = Directory(dir);
    if (d.existsSync()) await d.delete(recursive: true);
    final total = sizeOf(roots);
    var done = 0;
    final list = <Map<String, Object>>[];
    try {
      for (final (root, rel, f) in _files(roots).toList()) {
        final sha = await _copyHashed(f, File(p.join(dir, root, rel)), (n) {
          done += n;
          onProgress?.call(done, total);
        });
        list.add({'root': root, 'rel': p.posix.joinAll(p.split(rel)), 'size': f.lengthSync(), 'sha256': sha});
      }
      writeFolderReadme(dir, modelBackupReadme); // "AI 모델 보관" 은 한국어 이름이라 (영어 · 한국어)
      // 목록은 마지막에 (목록이 있으면 다 복사된 것)
      await _manifest.writeAsString(jsonEncode({'saved': DateTime.now().toIso8601String(), 'files': list}));
    } catch (_) {
      try {
        await d.delete(recursive: true);
      } catch (_) {}
      rethrow;
    }
    return total;
  }

  /// 보관한 크기 (목록 기준)
  int get savedSize {
    try {
      final j = jsonDecode(_manifest.readAsStringSync()) as Map;
      return (j['files'] as List).fold<int>(0, (a, e) => a + ((e as Map)['size'] as num).toInt());
    } catch (_) {
      return 0;
    }
  }

  /// 되살린다: 이미 같은 크기로 있으면 건너뛰고, 복사한 것은 SHA-256 을 목록과 맞춰 본다.
  /// 모두 되살렸으면 보관 폴더를 지운다. 맞지 않거나 실패한 파일은 [RestoreResult.failed] (보관본은 남김).
  Future<RestoreResult> restore(Map<String, String> roots, {void Function(int done, int total)? onProgress}) async {
    final j = jsonDecode(await _manifest.readAsString()) as Map;
    final files = [for (final e in j['files'] as List) Map<String, Object?>.from(e as Map)];
    final total = files.fold<int>(0, (a, e) => a + (e['size'] as num).toInt());
    var done = 0, restored = 0, skipped = 0;
    final failed = <String>[];
    for (final e in files) {
      final base = roots['${e['root']}'];
      final rel = '${e['rel']}';
      final size = (e['size'] as num).toInt();
      if (base == null) {
        failed.add(rel);
        continue;
      }
      final target = File(p.join(base, p.joinAll(p.posix.split(rel))));
      if (target.existsSync() && target.lengthSync() == size) {
        skipped++;
        done += size;
        onProgress?.call(done, total);
        continue;
      }
      final tmp = File('${target.path}.jjpart');
      try {
        final sha = await _copyHashed(File(p.join(dir, '${e['root']}', p.joinAll(p.posix.split(rel)))), tmp, (n) {
          done += n;
          onProgress?.call(done, total);
        });
        if (sha != e['sha256']) {
          await tmp.delete();
          failed.add(rel);
          continue;
        }
        if (target.existsSync()) await target.delete();
        await tmp.rename(target.path);
        restored++;
      } catch (_) {
        try {
          if (tmp.existsSync()) await tmp.delete();
        } catch (_) {}
        failed.add(rel);
      }
    }
    if (failed.isEmpty) {
      try {
        await Directory(dir).delete(recursive: true);
      } catch (_) {}
    }
    return RestoreResult(restored, skipped, failed);
  }
}

class RestoreResult {
  const RestoreResult(this.restored, this.skipped, this.failed);
  final int restored;
  final int skipped;
  final List<String> failed;
}
