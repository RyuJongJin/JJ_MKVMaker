import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jj_mkvmaker/app/app_controller.dart';
import 'package:jj_mkvmaker/app/live_sync.dart';
import 'package:jj_mkvmaker/app/settings.dart';
import 'package:jj_mkvmaker/core/file_ops.dart';
import 'package:jj_mkvmaker/core/vfs.dart';
import 'package:jj_mkvmaker/core/webdav.dart';
import 'package:jj_mkvmaker/platform/windows/desktop_storage_service.dart';
import 'package:jj_mkvmaker/platform/windows/process_media_tool.dart';
import 'package:jj_mkvmaker/services/platform_services.dart';
import 'package:path/path.dart' as p;

import 'support/dav_server.dart';

void main() {
  late Directory tmp, remote, local;
  late TestDavServer server;
  const id = 'nas';

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('jj_dav_');
    remote = Directory(p.join(tmp.path, 'remote'))..createSync();
    local = Directory(p.join(tmp.path, 'local'))..createSync();
    server = TestDavServer(remote);
    await server.start();
    DavRegistry.configure([DavServer(id: id, name: '집 NAS', url: server.url, user: 'user', password: 'pass')]);
  });
  tearDown(() async {
    DavRegistry.configure([]);
    await server.stop();
    tmp.deleteSync(recursive: true);
  });

  File lf(String rel, [String text = 'x']) => File(p.join(local.path, rel))
    ..parent.createSync(recursive: true)
    ..writeAsStringSync(text);
  File rf(String rel, [String text = 'x']) => File(p.join(remote.path, rel))
    ..parent.createSync(recursive: true)
    ..writeAsStringSync(text);

  test('경로: dav://서버/경로 정리 · 이어 붙이기 · 같은지 · 안에 있는지', () {
    expect(DavPath.parse(r'dav://nas/a\b/').full, 'dav://nas/a/b');
    expect(DavPath.parse('dav://nas').full, 'dav://nas/');
    expect(vJoin('dav://nas/', '한글 폴더'), 'dav://nas/한글 폴더');
    expect(vDirname('dav://nas/a/b'), 'dav://nas/a');
    expect(vDirname('dav://nas/a'), 'dav://nas/');
    expect(vBasename('dav://nas/a/b.mkv'), 'b.mkv');
    expect(samePath('dav://nas/a/', r'dav://nas/a'), isTrue);
    expect(isSameOrInside('dav://nas/a/b', 'dav://nas/a'), isTrue);
    expect(isSameOrInside('dav://nas/ab', 'dav://nas/a'), isFalse);
    expect(isSameOrInside('dav://nas/a', 'dav://other/a'), isFalse);
    expect(samePath('dav://nas/a', r'C:\a'), isFalse);
  });

  test('목록 · 폴더 만들기 · 이름 바꾸기 · 지우기 (한글 이름 · 인증)', () async {
    rf('영상/a.mkv', 'aaaa');
    rf('영상/sub/b.txt', 'b');
    final top = await listEntries('dav://$id/');
    expect(top.map((e) => (e.name, e.isDir)), [('영상', true)]);
    final inside = sortEntries(await listEntries('dav://$id/영상'), SortBy.name);
    expect(inside.map((e) => (e.name, e.isDir, e.size)), [('sub', true, 0), ('a.mkv', false, 4)]);
    final made = await FileOps.makeFolder('dav://$id/영상', '새 폴더');
    expect(made, 'dav://$id/영상/새 폴더');
    expect(Directory(p.join(remote.path, '영상', '새 폴더')).existsSync(), isTrue);
    final renamed = await FileOps.rename('dav://$id/영상/a.mkv', 'c.mkv');
    expect(renamed, 'dav://$id/영상/c.mkv');
    expect(File(p.join(remote.path, '영상', 'c.mkv')).readAsStringSync(), 'aaaa');
    await FileOps().delete(['dav://$id/영상/sub']);
    expect(Directory(p.join(remote.path, '영상', 'sub')).existsSync(), isFalse);
    // 잘못된 비밀번호
    DavRegistry.configure([DavServer(id: id, name: 'x', url: server.url, user: 'user', password: 'wrong')]);
    expect(() => listEntries('dav://$id/'), throwsA(isA<DavException>().having((e) => e.status, 'status', 401)));
  });

  test('복사 · 이동: 로컬 → WebDAV · WebDAV → 로컬 · 같은 서버 안 이동 (속도 알림)', () async {
    lf('up/x.txt', 'xx');
    lf('up/deep/y.bin', 'yyy');
    var bytes = 0;
    final ops = FileOps(onBytes: (n) => bytes += n);
    expect(await ops.copy([p.join(local.path, 'up')], 'dav://$id/'), ['dav://$id/up']);
    expect(File(p.join(remote.path, 'up', 'deep', 'y.bin')).readAsStringSync(), 'yyy');
    expect(bytes, 5);
    // 같은 이름이면 "이름 (2)"
    expect(await ops.copy([p.join(local.path, 'up')], 'dav://$id/'), ['dav://$id/up (2)']);
    // WebDAV → 로컬
    final down = Directory(p.join(local.path, 'down'))..createSync();
    await ops.copy(['dav://$id/up'], down.path);
    expect(File(p.join(down.path, 'up', 'x.txt')).readAsStringSync(), 'xx');
    // 같은 서버 안 이동 (서버가 MOVE)
    await FileOps.makeFolder('dav://$id/', 'box');
    await ops.move(['dav://$id/up (2)'], 'dav://$id/box');
    expect(Directory(p.join(remote.path, 'box', 'up (2)')).existsSync(), isTrue);
    expect(Directory(p.join(remote.path, 'up (2)')).existsSync(), isFalse);
    expect(server.requests.where((r) => r.startsWith('MOVE')), isNotEmpty);
    // 로컬 → WebDAV 이동 (복사 후 원본 지움)
    lf('mv/m.txt', 'm');
    await ops.move([p.join(local.path, 'mv')], 'dav://$id/box');
    expect(File(p.join(remote.path, 'box', 'mv', 'm.txt')).readAsStringSync(), 'm');
    expect(Directory(p.join(local.path, 'mv')).existsSync(), isFalse);
  });

  test('동기화 (mirror): 바뀐 것만 · 지우기 · -u · 원격 → 로컬도', () async {
    lf('src/a.txt', 'a');
    lf('src/sub/b.txt', 'b');
    final ops = FileOps();
    expect(await ops.mirror(p.join(local.path, 'src'), 'dav://$id/dst'), 2);
    expect(File(p.join(remote.path, 'dst', 'sub', 'b.txt')).readAsStringSync(), 'b');
    // 다시: 바뀐 것 없음 (올린 파일은 서버 시각이 원본보다 새것)
    expect(await ops.mirror(p.join(local.path, 'src'), 'dav://$id/dst'), 0);
    // 원본에서 내용 (크기) 이 바뀐 것만
    lf('src/a.txt', 'aaa');
    expect(await ops.mirror(p.join(local.path, 'src'), 'dav://$id/dst'), 1);
    expect(File(p.join(remote.path, 'dst', 'a.txt')).readAsStringSync(), 'aaa');
    // 지우기 포함: 대상에만 있는 것
    rf('dst/extra.txt', 'e');
    await ops.mirror(p.join(local.path, 'src'), 'dav://$id/dst', delete: true);
    expect(File(p.join(remote.path, 'dst', 'extra.txt')).existsSync(), isFalse);
    // -u: 대상이 더 새것이면 덮어쓰지 않음
    rf('dst/a.txt', 'remote newer!!');
    final old = DateTime.now().subtract(const Duration(days: 1));
    File(p.join(local.path, 'src', 'a.txt')).setLastModifiedSync(old);
    await ops.mirror(p.join(local.path, 'src'), 'dav://$id/dst', update: true);
    expect(File(p.join(remote.path, 'dst', 'a.txt')).readAsStringSync(), 'remote newer!!');
    // 원격 → 로컬 (받은 파일은 원격의 바뀐 때로 맞춰져 다시 받지 않음)
    final back = p.join(local.path, 'back');
    expect(await ops.mirror('dav://$id/dst', back), 2);
    expect(File(p.join(back, 'sub', 'b.txt')).readAsStringSync(), 'b');
    expect(await ops.mirror('dav://$id/dst', back), 0);
  });

  test('빈 폴더 지우기 · 파일 수 · 용량 · 임시로 받기', () async {
    rf('p/e1/e2/.keep', '');
    File(p.join(remote.path, 'p', 'e1', 'e2', '.keep')).deleteSync();
    rf('p/f/z.txt', 'z');
    expect(await vCountFiles('dav://$id/p'), 1);
    expect(await removeEmptyDirs('dav://$id/p'), 2); // e1/e2, e1
    expect(Directory(p.join(remote.path, 'p', 'f')).existsSync(), isTrue);
    expect(await DavRegistry.client(id).quota(), (1000000, 500));
    final got = await vLocalCopy('dav://$id/p/f/z.txt', p.join(local.path, 'cache'));
    expect(File(got).readAsStringSync(), 'z');
    expect(transferProblem(['dav://$id/p'], 'dav://$id/p/f', move: false), contains('자기 자신 안으로'));
  });

  test('실시간 동기화 (lsync): 로컬 → WebDAV 쌍은 rsync 로 정해 두어도 앱이 맞추고 남은 것 · 지우기', () async {
    lf('live/a.txt', 'a');
    lf('live/sub/b.txt', 'bb');
    rf('mirror/old.txt', 'o');
    final c = AppController(PlatformServices(mediaTool: ProcessMediaTool('x', 'y'), storage: DesktopStorageService()));
    final pair = LiveSyncPair(p.join(local.path, 'live'), 'dav://$id/mirror', method: 'rsync', delete: true);
    c.settings.liveSyncPairs = [pair];
    final live = LiveSync(c);
    expect(await LiveSync.diff(pair), unorderedEquals(['a.txt', 'sub/b.txt', '− old.txt']));
    await live.syncNow(pair);
    expect(live.status[LiveSync.keyOf(pair)]!.$2, isNot(contains('실패')));
    expect(File(p.join(remote.path, 'mirror', 'sub', 'b.txt')).readAsStringSync(), 'bb');
    expect(File(p.join(remote.path, 'mirror', 'old.txt')).existsSync(), isFalse);
    expect(live.pending[LiveSync.keyOf(pair)], isEmpty);
    live.dispose();
  });
}
