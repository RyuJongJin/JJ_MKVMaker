import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jj_mkvmaker/app/app_controller.dart';
import 'package:jj_mkvmaker/app/live_sync.dart';
import 'package:jj_mkvmaker/app/settings.dart';
import 'package:jj_mkvmaker/core/file_ops.dart';
import 'package:jj_mkvmaker/platform/windows/desktop_storage_service.dart';
import 'package:jj_mkvmaker/platform/windows/process_media_tool.dart';
import 'package:jj_mkvmaker/services/platform_services.dart';
import 'package:path/path.dart' as p;

/// 41: 원본을 읽지 못하면 (권한 · SD 카드 빠짐 · 네트워크) "지우기 포함" 이 대상 파일을 지우지 않는다
void main() {
  late Directory tmp;
  late String src, dst;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('jj_mirror_safe_');
    src = p.join(tmp.path, 'src');
    dst = p.join(tmp.path, 'backup');
    File(p.join(dst, 'keep1.txt'))
      ..createSync(recursive: true)
      ..writeAsStringSync('1');
    File(p.join(dst, 'sub', 'keep2.txt'))
      ..createSync(recursive: true)
      ..writeAsStringSync('2');
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  int count() => Directory(dst).listSync(recursive: true).whereType<File>().length;

  test('원본 폴더가 없으면 (SD 카드 빠짐 등) 멈추고 대상은 그대로', () async {
    await expectLater(FileOps().mirror(src, dst, delete: true), throwsA(isA<SourceUnreadableException>()));
    expect(count(), 2);
  });

  test('원본이 통째로 비었는데 대상에 파일이 있으면 지우지 않고 멈춤 / 원본에 파일이 있으면 평소대로 지움', () async {
    Directory(src).createSync();
    final e = await FileOps().mirror(src, dst, delete: true).then<Object?>((_) => null, onError: (Object e) => e);
    expect(e, isA<SourceUnreadableException>().having((x) => x.empty, 'empty', isTrue));
    expect(count(), 2);
    // 원본에 파일이 있으면 원본에 없는 것을 지운다 (평소 동작)
    File(p.join(src, 'new.txt')).writeAsStringSync('n');
    await FileOps().mirror(src, dst, delete: true);
    expect(File(p.join(dst, 'new.txt')).existsSync(), isTrue);
    expect(File(p.join(dst, 'keep1.txt')).existsSync(), isFalse);
  });

  test('실시간 동기화 (지우기 포함, rsync 로 정해 둠): 원본이 없으면 실패로 알리고 대상은 그대로, 미리 보기에 "지울 것" 없음',
      () async {
    final c = AppController(PlatformServices(mediaTool: ProcessMediaTool('x', 'y'), storage: DesktopStorageService()));
    final pair = LiveSyncPair(src, dst, method: 'rsync', delete: true);
    c.settings.liveSyncPairs = [pair];
    final live = LiveSync(c);
    await live.syncNow(pair);
    expect(live.status[LiveSync.keyOf(pair)]!.$2, '원본을 읽을 수 없어 멈춤');
    expect(count(), 2);
    expect(await LiveSync.diff(pair), isEmpty);
    live.dispose();
  });

  test('42: 지우기 포함으로 새로 추가한 쌍은 확인 전에는 지우지 않고 맞춘다 · 확인하면 지운다 · 예전 쌍은 확인한 것으로', () async {
    File(p.join(src, 'a.txt'))
      ..createSync(recursive: true)
      ..writeAsStringSync('a');
    final c = AppController(PlatformServices(mediaTool: ProcessMediaTool('x', 'y'), storage: DesktopStorageService()));
    final pair = LiveSyncPair(src, dst, delete: true); // 새 쌍: deleteConfirmed false
    c.settings.liveSyncPairs = [pair];
    final live = LiveSync(c);
    await live.syncNow(pair);
    final k = LiveSync.keyOf(pair);
    expect(File(p.join(dst, 'a.txt')).existsSync(), isTrue); // 복사는 함
    expect(count(), 3); // 대상에만 있던 2개는 그대로
    expect(live.toDelete[k], unorderedEquals(['keep1.txt', 'sub']));
    expect(live.status[k]!.$2, contains('확인 필요'));
    // 지우기 포함으로 맞추기 (확인)
    await live.decideDelete(c.settings.liveSyncPairs.single, delete: true);
    expect(c.settings.liveSyncPairs.single.deleteConfirmed, isTrue);
    expect(File(p.join(dst, 'keep1.txt')).existsSync(), isFalse);
    expect(live.toDelete[k], isNull);
    live.dispose();
    // 예전 설정 파일의 쌍 (deleteConfirmed 없음) 은 확인한 것으로, 지우기를 새로 켜면 다시 확인
    final old = LiveSyncPair.fromJson({'source': src, 'target': dst, 'delete': true});
    expect(old.deleteConfirmed, isTrue);
    final off = LiveSyncPair.fromJson({'source': src, 'target': dst, 'delete': false});
    expect(off.copyWith(delete: true).deleteConfirmed, isFalse);
  });

  test('43: 복사는 임시 이름 (.jjpart) 에 쓴 뒤 바꾼다 · 취소하면 완성된 이름의 반쪽 파일이 남지 않는다', () async {
    final big = File(p.join(tmp.path, 'big.bin'))..writeAsBytesSync(List.filled(8 << 20, 1));
    final out = Directory(p.join(tmp.path, 'out'))..createSync();
    await FileOps().copy([big.path], out.path);
    expect(File(p.join(out.path, 'big.bin')).lengthSync(), 8 << 20);
    expect(out.listSync().where((e) => e.path.endsWith('.jjpart')), isEmpty);
    // 취소: 첫 조각 뒤에 멈춤
    final out2 = Directory(p.join(tmp.path, 'out2'))..createSync();
    late FileOps ops;
    ops = FileOps(onBytes: (_) => ops.cancel(), bandwidthKBps: 1024);
    await expectLater(ops.copy([big.path], out2.path), throwsA(isA<FileOpCancelled>()));
    expect(out2.listSync(), isEmpty);
  });
}
