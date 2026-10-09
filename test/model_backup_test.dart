import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jj_mkvmaker/app/model_backup.dart';
import 'package:jj_mkvmaker/app/settings.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory tmp;
  late Map<String, String> roots;
  late ModelBackup backup;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('jj_mb_');
    roots = {'ai': p.join(tmp.path, 'data', 'ai'), 'models': p.join(tmp.path, 'data', 'models')};
    File(p.join(roots['ai']!, 'models', 'sd15.safetensors'))
      ..createSync(recursive: true)
      ..writeAsBytesSync(List.generate(300000, (i) => i % 251));
    File(p.join(roots['ai']!, 'models', 'sd15.json'))
      ..createSync(recursive: true)
      ..writeAsStringSync('{"sha256":"x"}');
    File(p.join(roots['ai']!, 'models', 'half.safetensors.part'))
      ..createSync(recursive: true)
      ..writeAsStringSync('partial');
    File(p.join(roots['models']!, 'whisper', 'ggml-base.bin'))
      ..createSync(recursive: true)
      ..writeAsBytesSync(List.filled(1000, 7));
    backup = ModelBackup(p.join(tmp.path, 'Download', 'JJ_MKVMaker', 'AI 모델 보관'));
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  void wipeAppData() => Directory(p.join(tmp.path, 'data')).deleteSync(recursive: true);

  test('P0: 받은 모델을 복사해 두고 (조각은 빼고) 앱을 지운 뒤 되살리면 같은 파일 · 사본은 지운다', () async {
    final size = ModelBackup.sizeOf(roots);
    expect(size, 300000 + 14 + 1000, reason: '.part 는 빼고');
    final progress = <int>[];
    await backup.save(roots, onProgress: (d, t) => progress.add(d));
    expect(progress.last, size);
    expect(backup.exists, true);
    expect(backup.savedSize, size);
    final before = File(p.join(roots['ai']!, 'models', 'sd15.safetensors')).readAsBytesSync();
    wipeAppData(); // 앱을 지움
    final r = await backup.restore(roots);
    expect((r.restored, r.skipped), (3, 0));
    expect(r.failed, isEmpty);
    expect(File(p.join(roots['ai']!, 'models', 'sd15.safetensors')).readAsBytesSync(), before);
    expect(File(p.join(roots['models']!, 'whisper', 'ggml-base.bin')).lengthSync(), 1000);
    expect(File(p.join(roots['ai']!, 'models', 'half.safetensors.part')).existsSync(), false);
    expect(Directory(backup.dir).existsSync(), false, reason: '다 되살리면 공용 폴더의 사본을 지운다');
  });

  test('SHA-256 이 맞지 않는 사본은 되살리지 않고 보관본을 남긴다', () async {
    await backup.save(roots);
    wipeAppData();
    // 공용 폴더의 사본이 (다른 앱 · 사용자에 의해) 바뀜
    File(p.join(backup.dir, 'models', 'whisper', 'ggml-base.bin')).writeAsBytesSync(List.filled(1000, 8));
    final r = await backup.restore(roots);
    expect(r.failed, ['whisper/ggml-base.bin']);
    expect(File(p.join(roots['models']!, 'whisper', 'ggml-base.bin')).existsSync(), false);
    expect(File(p.join(roots['models']!, 'whisper', 'ggml-base.bin.jjpart')).existsSync(), false);
    expect(backup.exists, true, reason: '실패하면 사본을 남김');
  });

  test('이미 같은 크기로 있는 파일은 건너뛴다 (예전 판이 다시 받은 경우)', () async {
    await backup.save(roots);
    final r = await backup.restore(roots); // 지우지 않고 바로
    expect((r.restored, r.skipped, r.failed.length), (0, 3, 0));
  });

  test('목록이 없으면 (복사 도중 끊김) 되살릴 것이 없다', () async {
    await backup.save(roots);
    File(p.join(backup.dir, 'manifest.json')).deleteSync();
    expect(backup.exists, false);
  });

  test('설정: 기본은 자동 (남은 공간으로), 고른 값은 남는다', () {
    expect(AppSettings().rollbackKeepModels, '');
    final b = AppSettings.fromJson((AppSettings()..rollbackKeepModels = 'off').toJson());
    expect(b.rollbackKeepModels, 'off');
    expect(AppSettings.fromJson({'rollbackKeepModels': 'weird'}).rollbackKeepModels, '');
  });
}
