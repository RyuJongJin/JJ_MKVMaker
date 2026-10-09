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
          ['-a', '--bwlimit=10', '-8', '/x', '/y/']); // Android: 한글 이름을 그대로 출력 (-8)
    });

    test('파일 탐색기 복사 방법: 현재 방식 (기본) · robocopy, 예전 값 rsync 는 현재 방식으로 (rsync 는 Rsync 화면)', () {
      expect([AppSettings().copyMethodFile, AppSettings().copyMethodFolder], ['builtin', 'builtin']);
      expect(AppSettings.fromJson({'copyMethodFolder': 'rsync', 'copyMethodFile': 'rsync'}).copyMethodFolder, 'builtin');
      expect(AppSettings.fromJson({'copyMethodFolder': 'robocopy'}).copyMethodFolder, 'robocopy');
      final s = AppSettings()..rsyncPaths = ['/a', '/b'];
      expect(AppSettings.fromJson(s.toJson()).rsyncPaths, ['/a', '/b']);
    });

    test('양쪽 (⇄) rsync 는 -u 를 더한다 (이미 있으면 그대로)', () {
      expect(withUpdateOption('-avPog'), '-avPog -u');
      expect(withUpdateOption('-avuP'), '-avuP');
      expect(withUpdateOption('-a --update'), '-a --update');
      expect(withUpdateOption('-a --bwlimit=10'), '-a --bwlimit=10 -u');
      expect(withUpdateOption(''), '-u');
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

    test('rsync 진행 줄의 전송 속도 (바이트/초)', () {
      final o = RsyncOutput();
      o.feed('     52,428,800  45%   12.50MB/s    0:00:05\r');
      expect(o.currentPercent, 0.45);
      expect(o.currentSpeed, 12.5 * 1024 * 1024);
      o.feed('        512,000 100%  500.00kB/s    0:00:01 (xfr#2, to-chk=0/3)\n');
      expect(o.currentSpeed, 500 * 1024);
      // 폴더 전체: to-chk=남은/전체 → 확인한 수
      expect([o.checked, o.checkTotal], [3, 3]);
      o.feed('        100 100%  1.00kB/s    0:00:00 (xfr#3, ir-chk=1000/1250)\n');
      expect([o.checked, o.checkTotal], [250, 1250]);
    });

    test('robocopy 출력 읽기: New File 줄 · % 줄', () {
      final o = RobocopyOutput();
      expect(o.feed('\n\t    New File  \t\t       3\tC:\\t\\src\\a.txt\r\n45%  \r\n'), [r'C:\t\src\a.txt']);
      expect(o.currentPercent, 0.45);
      expect(o.feed('100%  \n\t    Newer     \t\t     200\tC:\\t\\src\\b.txt\n\t*EXTRA File \t\t 1\tC:\\x\n'), [r'C:\t\src\b.txt']);
    });

    test('61: robocopy 파일 줄은 Windows 언어와 상관없이 (일본어 · 중국어 · 한국어 종류 글)', () {
      final o = RobocopyOutput();
      expect(o.feed('\t    新しいファイル  \t\t 3000000\tC:\\t\\a b.txt\r\n 34%  \r\n'), [r'C:\t\a b.txt']);
      expect(o.currentPercent, 0.34);
      expect(o.feed('\t    新文件  \t\t       1\tC:\\t\\c.txt\n\t    새 파일  \t\t  12.5 m\tC:\\t\\d.mkv\n'), [r'C:\t\c.txt', r'C:\t\d.mkv']);
      // 대상에만 있는 것 (* 로 시작) · 폴더 줄 (종류 없이 수 · 경로) · 오류 줄은 세지 않는다
      expect(
          o.feed('\t*追加ファイル  \t\t 1\tC:\\x\n\t\t\t\t    2\tC:\\t\\sub\\\n'
              '2026/10/10 01:00:00 ERROR 5 (0x00000005) Copying File C:\\t\\e.txt\n'),
          isEmpty);
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

    test('현재 방식 복사: 전송 속도를 계산하고 끝나면 비움', () async {
      final src = Directory(p.join(tmp.path, 'speed_src'))..createSync();
      for (var i = 0; i < 4; i++) {
        File(p.join(src.path, 'f$i.bin')).writeAsBytesSync(List.filled(256 * 1024, i));
      }
      final job = TransferJob(sources: [src.path], dest: Directory(p.join(tmp.path, 'speed_dst')).path, move: false, bandwidthKBps: 2048);
      Directory(job.dest).createSync();
      double? seen;
      job.addListener(() => seen = job.speed ?? seen);
      await job.run();
      expect(job.error, isNull);
      expect(seen, isNotNull);
      expect(seen!, greaterThan(0));
      expect(job.speed, isNull); // 끝나면 표시하지 않음
    });

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

    test('진행 표시: 큰 파일 하나도 보낸 바이트로 0% 에서 오른다 · 끝난 뒤에도 항목 이름 (171)', () async {
      File(p.join(src, 'one.bin')).writeAsBytesSync(List.filled(256 * 1024, 7));
      final job = TransferJob(sources: [p.join(src, 'one.bin')], dest: dst, move: false, bandwidthKBps: 256);
      final mid = <double>[];
      job.addListener(() {
        if (!job.finished && !job.counting) mid.add(job.overall);
      });
      await job.run();
      expect(job.error, isNull);
      // 예전에는 파일 수 (0/1) 로 세어 끝날 때까지 0% 였다
      expect(mid.any((v) => v > 0.2 && v < 1), isTrue, reason: '중간 진행: $mid');
      expect(job.current, 1);
      expect(job.currentName, 'one.bin', reason: '끝난 진행 창에 " 안의 파일" 대신 이름');
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
