import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jj_mkvmaker/app/app_controller.dart';
import 'package:jj_mkvmaker/app/live_sync.dart';
import 'package:jj_mkvmaker/app/settings.dart';
import 'package:jj_mkvmaker/app/transfer_job.dart';
import 'package:jj_mkvmaker/core/file_ops.dart';
import 'package:jj_mkvmaker/core/sync_tools.dart';
import 'package:jj_mkvmaker/platform/windows/desktop_storage_service.dart';
import 'package:jj_mkvmaker/platform/windows/process_media_tool.dart';
import 'package:jj_mkvmaker/platform/windows/rsync_installer.dart';
import 'package:jj_mkvmaker/services/platform_services.dart';
import 'package:path/path.dart' as p;

void main() {
  group('명령 만들기', () {
    test('옵션 나누기 (따옴표 묶음)', () {
      expect(splitOptions('-avPog --exclude "a b" \'c d\''), ['-avPog', '--exclude', 'a b', 'c d']);
      expect(splitOptions('  '), isEmpty);
    });

    test('Windows 경로 → MSYS2 rsync 경로', () {
      expect(toCygwinPath(r'C:\Users\x\한글'), '/cygdrive/c/Users/x/한글');
      expect(toCygwinPath(r'D:\'), '/cygdrive/d/');
      expect(toCygwinPath(r'\\server\share\a'), '//server/share/a');
      expect(toCygwinPath('/storage/emulated/0', windows: false), '/storage/emulated/0');
    });

    test('rsync 인수: 옵션 · 속도 제한 · 이동 · 원본 (끝 / 없음) · 대상/', () {
      expect(
          rsyncArgs(options: '-avPog', sources: [r'C:\a\src\', r'C:\a\f.mkv'], dest: r'E:\dst', bandwidthKBps: 500, move: true),
          ['-avPog', '--bwlimit=500', '--remove-source-files', '/cygdrive/c/a/src', '/cygdrive/c/a/f.mkv', '/cygdrive/e/dst/']);
      // 옵션 칸에 직접 넣은 속도 제한이 우선
      expect(rsyncArgs(options: '-a --bwlimit=10', sources: ['/x'], dest: '/y', bandwidthKBps: 500, windows: false),
          ['-a', '--bwlimit=10', '/x', '/y/']);
    });

    test('robocopy: 폴더마다 · 같은 폴더 파일은 한 번에 · /IPG · 이동', () {
      final runs = robocopyRuns(
        options: '/E /R:2',
        folders: [r'C:\a\movies'],
        files: [r'C:\b\1.mkv', r'C:\b\2.mkv', r'C:\c\3.mkv'],
        dest: r'E:\dst',
        bandwidthKBps: 640,
        move: true,
      );
      expect(runs[0], [r'C:\a\movies', p.join(r'E:\dst', 'movies'), '/E', '/R:2', '/IPG:100', '/MOVE']);
      expect(runs[1], [r'C:\b', r'E:\dst', '1.mkv', '2.mkv', '/R:2', '/IPG:100', '/MOV']); // 파일만: /E 빼고 /MOV
      expect(runs[2].sublist(0, 3), [r'C:\c', r'E:\dst', '3.mkv']);
      expect(robocopyIpg(0), 0);
    });

    test('rsync 출력 읽기: 파일 줄만 (폴더 · 진행 · 요약 줄 뺌)', () {
      final o = RsyncOutput();
      // 실제 rsync 3.5.1 -avPog 출력 (\r 진행 줄 포함)
      expect(o.feed('sending incremental file list\nsrc/\nsrc/a.txt\n'), ['src/a.txt']);
      expect(o.feed('              3 100%    0.00kB/s    0:00:00\r              3 100%  (xfr#1, to-chk=2/4)\nsrc/sub/\nsrc/sub/b'),
          isEmpty);
      expect(o.currentPercent, 1.0);
      expect(o.feed('.txt\n\nsent 244 bytes  received 66 bytes  620.00 bytes/sec\ntotal size is 5  speedup is 0.02\n'),
          ['src/sub/b.txt']);
    });

    test('robocopy 출력 읽기: New File 줄 · % 줄', () {
      final o = RobocopyOutput();
      expect(o.feed('\n\t    New File  \t\t       3\tC:\\t\\src\\a.txt\r\n45%  \r\n'), [r'C:\t\src\a.txt']);
      expect(o.currentPercent, 0.45);
      expect(o.feed('100%  \n\t    Newer     \t\t     200\tC:\\t\\src\\b.txt\n\t*EXTRA File \t\t 1\tC:\\x\n'), [r'C:\t\src\b.txt']);
    });
  });

  group('실제 복사', () {
    late Directory tmp;
    late String src, dst;
    setUp(() {
      tmp = Directory.systemTemp.createTempSync('jj_sync_');
      src = p.join(tmp.path, 'src');
      dst = p.join(tmp.path, 'dst');
      for (final (rel, text) in [('a.txt', 'aa'), ('sub/b.txt', 'bbb'), ('한글 폴더/동영상 1.txt', 'ccc')]) {
        File(p.join(src, rel))
          ..createSync(recursive: true)
          ..writeAsStringSync(text);
      }
      File(p.join(tmp.path, 'single.txt')).writeAsStringSync('s');
      Directory(dst).createSync();
    });
    tearDown(() => tmp.deleteSync(recursive: true));

    void expectCopied() {
      expect(File(p.join(dst, 'src', 'a.txt')).readAsStringSync(), 'aa');
      expect(File(p.join(dst, 'src', 'sub', 'b.txt')).readAsStringSync(), 'bbb');
      expect(File(p.join(dst, 'src', '한글 폴더', '동영상 1.txt')).readAsStringSync(), 'ccc');
      expect(File(p.join(dst, 'single.txt')).readAsStringSync(), 's');
    }

    test('현재 방식: 진행 (항목 2개 · 폴더 안 파일 3개) · 이동', () async {
      final job = TransferJob(sources: [src, p.join(tmp.path, 'single.txt')], dest: dst, move: false);
      final seen = <(int, int, int)>[];
      job.addListener(() => seen.add((job.index, job.filesDone[0], job.filesTotal[0])));
      await job.run();
      expect(job.error, isNull);
      expectCopied();
      expect(job.filesTotal, [3, 1]);
      expect(job.overall, 1);
      expect(seen.where((x) => x.$1 == 0).map((x) => x.$2).toSet(), containsAll([1, 2, 3])); // 파일마다 알림
      final mv = TransferJob(sources: [p.join(dst, 'single.txt')], dest: src, move: true);
      await mv.run();
      expect(File(p.join(src, 'single.txt')).existsSync(), isTrue);
      expect(File(p.join(dst, 'single.txt')).existsSync(), isFalse);
    });

    test('현재 방식 속도 제한: 64KB 를 32KB/s 로 → 1.5초 넘게', () async {
      File(p.join(src, 'big.bin')).writeAsBytesSync(List.filled(64 * 1024, 7));
      final sw = Stopwatch()..start();
      await FileOps(bandwidthKBps: 32).copy([p.join(src, 'big.bin')], dst);
      expect(sw.elapsedMilliseconds, greaterThan(1500));
    });

    test('동기화 (mirror): 바뀐 것만 · 지우기', () async {
      final ops = FileOps();
      expect(await ops.mirror(src, dst), 3);
      expect(await ops.mirror(src, dst), 0); // 바뀐 것 없음
      File(p.join(src, 'a.txt')).writeAsStringSync('changed!');
      File(p.join(dst, 'extra.txt')).writeAsStringSync('x');
      expect(await ops.mirror(src, dst), 1);
      expect(File(p.join(dst, 'extra.txt')).existsSync(), isTrue);
      await ops.mirror(src, dst, delete: true);
      expect(File(p.join(dst, 'extra.txt')).existsSync(), isFalse);
      expect(File(p.join(dst, 'a.txt')).readAsStringSync(), 'changed!');
    });

    test('robocopy (Windows): 폴더 · 파일 · 한글 이름 · 진행', () async {
      if (!Platform.isWindows) return markTestSkipped('Windows 만');
      final job = TransferJob(
          sources: [src, p.join(tmp.path, 'single.txt')],
          dest: dst,
          move: false,
          method: CopyMethod.robocopy,
          options: defaultRobocopyOptions,
          bandwidthKBps: 1000);
      await job.run();
      expect(job.error, isNull);
      expectCopied();
      expect(job.filesDone, [3, 1]);
    });

    test('rsync (Windows, 실제 내려받기 · JJ_NET_TESTS=1): -avPog · 따로 / 한 번에 · 이동', () async {
      if (!Platform.isWindows || Platform.environment['JJ_NET_TESTS'] != '1') {
        return markTestSkipped('인터넷 테스트 꺼짐');
      }
      RsyncInstaller.dirOverride = p.join(tmp.path, 'rsync');
      addTearDown(() => RsyncInstaller.dirOverride = null);
      final exe = await RsyncInstaller.install();
      for (final once in [false, true]) {
        Directory(dst).deleteSync(recursive: true);
        Directory(dst).createSync();
        final job = TransferJob(
            sources: [src, p.join(tmp.path, 'single.txt')],
            dest: dst,
            move: false,
            method: CopyMethod.rsync,
            options: defaultRsyncOptions,
            once: once,
            bandwidthKBps: 1000,
            rsyncExe: exe);
        await job.run();
        expect(job.error, isNull, reason: job.log.join('\n'));
        expectCopied();
        expect(job.filesDone, [3, 1], reason: 'once=$once');
      }
      // 이동: 원본 파일 · 빈 폴더가 사라진다
      final mv = TransferJob(
          sources: [src], dest: p.join(tmp.path, 'moved'), move: true, method: CopyMethod.rsync, options: '-a', rsyncExe: exe);
      Directory(p.join(tmp.path, 'moved')).createSync();
      await mv.run();
      expect(mv.error, isNull, reason: mv.log.join('\n'));
      expect(Directory(src).existsSync(), isFalse);
      expect(File(p.join(tmp.path, 'moved', 'src', 'sub', 'b.txt')).existsSync(), isTrue);
    });

    test('실시간 동기화: 지금 맞추기 (현재 방식) · 상태', () async {
      final c = AppController(PlatformServices(mediaTool: ProcessMediaTool('x', 'y'), storage: DesktopStorageService()));
      final pair = LiveSyncPair(src, p.join(tmp.path, 'mirror'));
      c.settings.liveSyncPairs = [pair];
      final live = LiveSync(c);
      await live.syncNow(pair);
      expect(File(p.join(tmp.path, 'mirror', 'sub', 'b.txt')).readAsStringSync(), 'bbb');
      expect(live.status[LiveSync.keyOf(pair)]!.$2, contains('3'));
      // 대상이 원본 안이면 거부
      c.settings.liveSyncPairs = [LiveSyncPair(src, p.join(src, 'in'))];
      live.start();
      expect(live.status[LiveSync.keyOf(c.settings.liveSyncPairs.first)]!.$2, contains('안에'));
      live.dispose();
      // 설정 저장 · 읽기
      final back = AppSettings.fromJson(c.settings.toJson());
      expect(back.liveSyncPairs.single.target, p.join(src, 'in'));
      expect([back.copyMethodFolder, back.rsyncOptions, back.copyRunMode, back.rsyncSource],
          ['builtin', '-avPog', 'each', 'download']);
    });
  });
}
