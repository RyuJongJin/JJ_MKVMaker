import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jj_mkvmaker/app/app_controller.dart';
import 'package:jj_mkvmaker/app/copy_center.dart';
import 'package:jj_mkvmaker/app/live_sync.dart';
import 'package:jj_mkvmaker/app/settings.dart';
import 'package:jj_mkvmaker/core/cron_window.dart';
import 'package:jj_mkvmaker/platform/windows/desktop_storage_service.dart';
import 'package:jj_mkvmaker/platform/windows/process_media_tool.dart';
import 'package:jj_mkvmaker/services/platform_services.dart';
import 'package:jj_mkvmaker/ui/monitor_page.dart';
import 'package:path/path.dart' as p;

void main() {
  group('cron 일정', () {
    // 2026-10-05 은 월요일
    final mon10 = DateTime(2026, 10, 5, 10, 30), mon20 = DateTime(2026, 10, 5, 20), sat10 = DateTime(2026, 10, 10, 10);

    test('읽기 · 시간 창 (시 · 요일 · 범위 · 간격 · 이름)', () {
      final e = CronExpr.parse('0 9-17 * * 1-5');
      expect([e.activeAt(mon10), e.activeAt(mon20), e.activeAt(sat10)], [true, false, false]);
      expect(CronExpr.parse('0 */2 * * SAT,SUN').activeAt(sat10), isTrue);
      expect(CronExpr.parse('0 * * * 7').activeAt(DateTime(2026, 10, 11, 3)), isTrue); // 7 = 일요일
      expect(CronExpr.parse('0 10 5 10 *').activeAt(mon10), isTrue); // 10월 5일 10시
      expect(() => CronExpr.parse('0 25 * * *'), throwsFormatException);
      expect(() => CronExpr.parse('0 9 * *'), throwsFormatException);
      expect(CronExpr.tryParse('x'), isNull);
    });

    test('계속 · 다음 시작 · 끝나는 때', () {
      expect(scheduleActive(const [], sat10), isTrue);
      const work = ['0 9-17 * * 1-5'];
      expect(scheduleNextStart(work, mon20), DateTime(2026, 10, 6, 9));
      expect(scheduleNextStart(work, mon10), isNull);
      expect(scheduleEnd(work, mon10), DateTime(2026, 10, 5, 18));
      expect(scheduleNextStart(work, sat10), DateTime(2026, 10, 12, 9)); // 다음 월요일
    });

    test('격자 ↔ cron (같은 시간대 요일끼리 한 줄)', () {
      final cells = {for (var d = 1; d <= 5; d++) for (var h = 9; h < 18; h++) d * 24 + h, 6 * 24 + 22, 6 * 24 + 23};
      final lines = cronFromGrid(cells);
      expect(lines, ['0 9-17 * * 1-5', '0 22-23 * * 6']);
      expect(gridFromCron(lines), cells);
      expect(cronFromGrid({for (var i = 0; i < 168; i++) i}), ['0 * * * *']);
      expect(gridFromCron(['0 10 5 10 *']), isEmpty); // 일 · 월을 정한 줄은 격자로 못 그림
    });
  });

  group('복사 기억 · lsync', () {
    late Directory tmp;
    late AppController c;
    late String src, dst;
    setUp(() {
      tmp = Directory.systemTemp.createTempSync('jj_mon_');
      src = p.join(tmp.path, 'src');
      dst = p.join(tmp.path, 'dst');
      File(p.join(src, 'a.txt'))
        ..createSync(recursive: true)
        ..writeAsStringSync('a');
      File(p.join(src, 'sub', 'b.txt'))
        ..createSync(recursive: true)
        ..writeAsStringSync('b');
      Directory(dst).createSync();
      c = AppController(PlatformServices(mediaTool: ProcessMediaTool('x', 'y'), storage: DesktopStorageService()));
    });
    tearDown(() => tmp.deleteSync(recursive: true));

    test('같은 복사는 기억한 옵션 · 실행 결과 기록 · lsync 로 이동 · 다시 복사 목록으로', () async {
      c.settings.copyMethodFolder = 'builtin'; // rsync 실행은 sync_tools_test (시험 환경에서는 path_provider 없음)
      final center = CopyCenter(c);
      final t = await center.remember([src], dst);
      await center.update(t.copyWith(options: '-a --custom', bandwidthKBps: 77));
      final again = await center.remember([src], dst);
      expect([again.id, again.options, again.bandwidthKBps], [t.id, '-a --custom', 77]);
      expect(center.tasks, hasLength(1));

      final job = await center.start(center.tasks.single);
      await job!.done;
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(File(p.join(dst, 'src', 'sub', 'b.txt')).readAsStringSync(), 'b');
      expect(center.tasks.single.lastResult, 'done');
      expect(center.tasks.single.lastFiles, 2);

      // lsync 로: 원본 → 대상\이름
      expect(await center.toLiveSync(center.tasks.single), 1);
      expect(center.tasks, isEmpty);
      final pair = c.settings.liveSyncPairs.single;
      expect([pair.source, pair.target], [src, p.join(dst, 'src')]);

      // 다시 복사 목록으로 (안의 것 → 대상)
      final back = await center.fromLiveSync(pair);
      expect(c.settings.liveSyncPairs, isEmpty);
      expect([back.contents, back.dest], [true, p.join(dst, 'src')]);
      expect(back.method, Platform.isWindows ? 'rsync' : 'builtin'); // rsync 로 옮겨 온다 (쓸 수 있으면)
      File(p.join(src, 'new.txt')).writeAsStringSync('n');
      // (시험 환경에는 rsync 가 없어 현재 방식으로 실행 - rsync 실행은 sync_tools_test)
      final j2 = await center.start(back.copyWith(method: 'builtin'));
      await j2!.done;
      expect(File(p.join(dst, 'src', 'new.txt')).readAsStringSync(), 'n'); // 안의 것 모드: 이름 폴더가 또 생기지 않음
      expect(Directory(p.join(dst, 'src', 'src')).existsSync(), isFalse);
    });

    test('이동 뒤 원본 정리 (prune) 저장 · 읽기', () {
      final t = CopyTask(id: '1', sources: const ['/a'], dest: '/b', move: true, contents: true, method: 'rsync', prune: 'all');
      final back = CopyTask.fromJson(t.toJson());
      expect([back.move, back.prune], [true, 'all']);
      expect(CopyTask.fromJson({'id': '2', 'dest': '/b', 'prune': 'x'}).prune, '');
      expect(t.copyWith(prune: 'keep').prune, 'keep');
    });

    test('기억한 복사의 원본이 없어졌거나 자기 안으로면 시작하지 않고 실패로 남긴다', () async {
      c.settings.copyMethodFolder = 'rsync';
      final center = CopyCenter(c);
      final t = await center.remember([src], src); // 자기 안으로
      expect(await center.start(t), isNull);
      expect([center.tasks.single.lastResult, center.tasks.single.lastMessage], ['failed', contains('자기 자신 안으로')]);
      final t2 = await center.remember([p.join(tmp.path, 'gone')], dst);
      expect(await center.start(t2), isNull);
      expect(center.tasks.firstWhere((x) => x.id == t2.id).lastMessage, contains('원본이 없습니다'));
      expect(center.jobs, isEmpty);
    });

    test('lsync: 맞출 것 자동으로 세기 · 일정 밖이면 맞추지 않음', () async {
      final target = p.join(dst, 'mirror');
      // 일정: 지금이 아닌 시간 (지금 시 + 2)
      final off = (DateTime.now().hour + 2) % 24;
      final pair = LiveSyncPair(src, target, schedule: ['0 $off * * *'], delete: true);
      expect(await LiveSync.diff(pair), unorderedEquals(['a.txt', 'sub/b.txt']));
      expect(LiveSync.activeNow(pair), isFalse);
      c.settings.liveSyncPairs = [pair];
      final live = LiveSync(c)..start();
      await Future<void>.delayed(const Duration(seconds: 4)); // 모아서 3초 뒤
      expect(live.pending[LiveSync.keyOf(pair)], hasLength(2));
      expect(Directory(target).existsSync(), isFalse); // 일정 밖: 맞추지 않음
      // 지금 맞추기는 늘 된다
      await live.syncNow(pair);
      expect(live.pending[LiveSync.keyOf(pair)], isEmpty);
      File(p.join(target, 'extra.txt')).writeAsStringSync('x');
      expect(await LiveSync.diff(pair), ['− extra.txt']);
      live.dispose();
    });
  });

  group('백그라운드 · 다시 켤 때 동기화', () {
    test('설정 저장 · 읽기, Windows 는 종료 동작과 같은 값', () {
      final s = AppSettings()
        ..runInBackground = true
        ..liveSyncOnStart = 'ask';
      final r = AppSettings.fromJson(s.toJson());
      expect([r.runInBackground, r.liveSyncOnStart], [true, 'ask']);
      expect(AppSettings.fromJson({'liveSyncOnStart': 'x'}).liveSyncOnStart, 'auto');
      expect(AppSettings.fromJson({}).runInBackground, isFalse);
      final w = AppSettings()..backgroundRun = false;
      if (Platform.isWindows) {
        expect(w.closeAction, 'quit');
        w.backgroundRun = true;
        expect([w.closeAction, w.backgroundRun], ['background', true]);
      } else {
        expect(w.runInBackground, isFalse);
      }
    });

    test('멈춘 채로 시작 · 고른 것만 시작 · 모두 시작', () async {
      final tmp = Directory.systemTemp.createTempSync('jj_hold_');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final a = Directory(p.join(tmp.path, 'a'))..createSync();
      final b = Directory(p.join(tmp.path, 'b'))..createSync();
      File(p.join(a.path, '1.txt')).writeAsStringSync('1');
      File(p.join(b.path, '2.txt')).writeAsStringSync('2');
      final c = AppController(PlatformServices(mediaTool: ProcessMediaTool('x', 'y'), storage: DesktopStorageService()));
      final pa = LiveSyncPair(a.path, p.join(tmp.path, 'ta')), pb = LiveSyncPair(b.path, p.join(tmp.path, 'tb'));
      c.settings
        ..liveSyncPairs = [pa, pb]
        ..liveSyncOnStart = 'off';
      final live = LiveSync(c)..start(hold: c.settings.liveSyncOnStart != 'auto');
      addTearDown(live.dispose);
      expect(live.watching, isEmpty);
      await Future<void>.delayed(const Duration(seconds: 4));
      expect(Directory(pa.target).existsSync(), isFalse); // 시작 안 함
      live.runOnly([pa]);
      expect(live.watching.map((x) => x.source), [a.path]);
      expect(live.isPaused(pb), isTrue);
      await Future<void>.delayed(const Duration(seconds: 4));
      expect(File(p.join(pa.target, '1.txt')).existsSync(), isTrue);
      expect(Directory(pb.target).existsSync(), isFalse);
      live.resumeAll();
      await Future<void>.delayed(const Duration(seconds: 4));
      expect(File(p.join(pb.target, '2.txt')).existsSync(), isTrue);
      live.pause(pa);
      expect(live.watching.map((x) => x.source), [b.path]);
    });
  });

  testWidgets('모니터링 화면: 복사 목록 · 옵션 고치기 → 현재 유지 / 반영 후 실행, lsync 탭 · 일정', (tester) async {
    final tmp = Directory.systemTemp.createTempSync('jj_monui_');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final c = AppController(PlatformServices(mediaTool: ProcessMediaTool('x', 'y'), storage: DesktopStorageService()));
    c.settings
      ..copyTasks = [CopyTask(id: '1', sources: [tmp.path], dest: p.join(tmp.path, '..'), method: 'builtin')]
      ..liveSyncPairs = [LiveSyncPair(tmp.path, p.join(tmp.path, 'x'), schedule: const ['0 9-17 * * 1-5'])];
    tester.view.physicalSize = const Size(1500, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: MonitorPage(c: c)));
    await tester.pump();
    expect(find.text('아직 실행 안 함'), findsOneWidget);
    expect(find.text('실행'), findsOneWidget);
    expect(find.text('lsync 로 이동'), findsOneWidget);

    // 속도 제한을 고치면 [저장] → 묻기 → 현재 유지 (실행 안 함)
    await tester.enterText(find.widgetWithText(TextField, '속도 제한'), '500');
    await tester.pump();
    await tester.tap(find.text('저장'));
    await tester.pumpAndSettle();
    expect(find.text('옵션을 저장했습니다'), findsOneWidget);
    expect(find.text('설정 반영 후 실행'), findsOneWidget);
    await tester.tap(find.text('현재 유지'));
    await tester.pumpAndSettle();
    expect(c.settings.copyTasks.single.bandwidthKBps, 500);
    expect(CopyCenter.of(c).jobs, isEmpty);

    // lsync 탭: 일정 요약 · 맞추기 버튼
    await tester.tap(find.text('lsync (실시간 동기화)'));
    await tester.pumpAndSettle();
    expect(find.textContaining('0 9-17 * * 1-5'), findsOneWidget);
    expect(find.text('지금 맞추기'), findsOneWidget);
    expect(find.text('복사 · rsync 로 이동'), findsOneWidget);
  });
}
