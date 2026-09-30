import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jj_mkvmaker/app/app_controller.dart';
import 'package:jj_mkvmaker/platform/windows/desktop_storage_service.dart';
import 'package:jj_mkvmaker/platform/windows/process_media_tool.dart';
import 'package:jj_mkvmaker/platform/windows/windows_usage.dart';
import 'package:jj_mkvmaker/services/platform_services.dart';
import 'package:jj_mkvmaker/services/system_usage.dart';
import 'package:jj_mkvmaker/ui/app_actions.dart';

class _Fake implements SystemUsage {
  UsageSample? next;
  (int, int)? space;
  @override
  UsageSample? read() => next;
  @override
  (int, int)? disk(String path) => space;
}

void main() {
  test('Windows: 실제 CPU · 메모리 값 읽기', () async {
    if (!Platform.isWindows) return markTestSkipped('Windows 전용');
    final u = WindowsUsage();
    expect(u.read(), isNull); // 첫 호출은 기준점만
    // 조금 일하게 한 뒤 다시
    final end = DateTime.now().add(const Duration(milliseconds: 300));
    var x = 0;
    while (DateTime.now().isBefore(end)) {
      x += 1;
    }
    expect(x, greaterThan(0));
    final s = u.read()!;
    // ignore: avoid_print
    print('RESULT CPU ${(s.cpu * 100).toStringAsFixed(1)}%  MEM ${(s.mem * 100).toStringAsFixed(1)}% '
        '(${s.memUsed ~/ (1 << 20)}MB / ${s.memTotal ~/ (1 << 20)}MB)');
    expect(s.cpu, inInclusiveRange(0.0, 1.0));
    expect(s.cpu, greaterThan(0)); // 방금 이 테스트가 CPU 를 썼다
    expect(s.memTotal, greaterThan(1 << 30)); // 1GB 이상
    expect(s.memUsed, inExclusiveRange(0, s.memTotal));

    // 디스크: 이 테스트가 도는 드라이브
    final root = Directory.current.path.substring(0, 3);
    final (free, total) = u.disk(root)!;
    // ignore: avoid_print
    print('RESULT DISK $root 남은 ${free ~/ (1 << 30)}GB / 전체 ${total ~/ (1 << 30)}GB');
    expect(total, greaterThan(1 << 30));
    expect(free, inInclusiveRange(0, total));
    expect(u.disk(r'?:\없는 드라이브'), isNull);
  });

  testWidgets('위쪽 막대: 환경 설정 앞에 CPU · MEM 표시, 값이 바뀌면 갱신', (tester) async {
    final fake = _Fake();
    final c = AppController(PlatformServices(
        mediaTool: ProcessMediaTool('x', 'y'), storage: DesktopStorageService(), usage: fake));
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: Row(children: [const Spacer(), AppActions(c: c, onExit: () {})]))));
    expect(find.textContaining('--%', findRichText: true), findsNWidgets(2)); // 아직 값이 없음

    fake.next = const UsageSample(cpu: 0.234, memUsed: 6 << 30, memTotal: 16 << 30);
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    expect(find.textContaining('CPU 23%', findRichText: true), findsOneWidget);
    expect(find.textContaining('MEM 38%', findRichText: true), findsOneWidget);
    expect(find.textContaining('DISK', findRichText: true), findsNothing); // 디스크 값을 모르면 숨김

    // DISK: MEM 뒤, 환경 설정 앞. 남은 용량이 적으면 diskLow.
    fake.space = (128 << 30, 931 << 30);
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    final disk = find.textContaining('DISK 128GB', findRichText: true);
    expect(disk, findsOneWidget);
    expect(tester.getCenter(disk).dx,
        greaterThan(tester.getCenter(find.textContaining('MEM 38%', findRichText: true)).dx));
    expect(tester.getCenter(disk).dx, lessThan(tester.getCenter(find.byTooltip('환경 설정')).dx));
    expect(c.usage!.value!.diskLow, isFalse);
    expect(const UsageSample(cpu: 0, memUsed: 1, memTotal: 2, diskFree: 5 << 30, diskTotal: 100 << 30).diskLow, isTrue);
    expect(const UsageSample(cpu: 0, memUsed: 1, memTotal: 2, diskFree: 30 << 30, diskTotal: 2000 << 30).diskLow, isTrue);
    // 환경 설정 버튼의 왼쪽
    expect(tester.getCenter(find.textContaining('MEM 38%', findRichText: true)).dx,
        lessThan(tester.getCenter(find.byTooltip('환경 설정')).dx));

    // 화면이 사라지면 재는 것도 멈춘다
    await tester.pumpWidget(const SizedBox());
    // ignore: invalid_use_of_protected_member
    expect(c.usage!.hasListeners, isFalse);
  });

  test('사용량을 지원하지 않으면 표시 없음', () {
    final c = AppController(PlatformServices(mediaTool: ProcessMediaTool('x', 'y'), storage: DesktopStorageService()));
    expect(c.usage, isNull);
  });
}
