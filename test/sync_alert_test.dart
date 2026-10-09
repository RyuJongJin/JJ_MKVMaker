import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jj_mkvmaker/app/app_controller.dart';
import 'package:jj_mkvmaker/app/live_sync.dart';
import 'package:jj_mkvmaker/app/settings.dart';
import 'package:jj_mkvmaker/platform/windows/desktop_storage_service.dart';
import 'package:jj_mkvmaker/platform/windows/process_media_tool.dart';
import 'package:jj_mkvmaker/services/app_shell.dart';
import 'package:jj_mkvmaker/services/platform_services.dart';
import 'package:jj_mkvmaker/ui/sync_alert.dart';
import 'package:path/path.dart' as p;

class _Shell extends NoopShell {
  bool front = false;
  final notes = <(String, String)>[];
  void Function()? click;
  void Function()? trayShown;
  String tip = '';
  @override
  Future<bool> notify(String title, String body, {void Function()? onClick}) async {
    notes.add((title, body));
    click = onClick;
    return true;
  }

  @override
  set onTrayShown(void Function()? f) => trayShown = f;
  @override
  Future<bool> isInFront() async => front;
  @override
  Future<void> setTooltip(String text) async => tip = text;
}

/// 92: 트레이에 둔 채 동기화가 멈추면 Windows 알림 · 트레이 툴팁 · 누르면 lsync 카드로
void main() {
  test('창이 앞에 없을 때 새로 멈춘 쌍만 한 번 알림 · 툴팁 경고 · 알림 · 트레이를 누르면 lsync 로', () async {
    final tmp = Directory.systemTemp.createTempSync('jj_alert_');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final c = AppController(PlatformServices(mediaTool: ProcessMediaTool('x', 'y'), storage: DesktopStorageService()));
    final pair = LiveSyncPair(p.join(tmp.path, 'gone'), p.join(tmp.path, 'dst'));
    c.settings.liveSyncPairs = [pair];
    final live = LiveSync(c);
    final shell = _Shell();
    var opened = 0;
    final alert = SyncAlert(live, shell, openLsync: () => opened++, baseTooltip: () => 'JJ_MKVMaker');

    await live.syncNow(pair);
    await Future<void>.delayed(Duration.zero);
    expect(shell.notes, hasLength(1));
    expect(shell.notes.single.$1, '실시간 동기화가 멈췄습니다');
    expect(shell.notes.single.$2, contains('원본을 읽을 수 없어 멈췄습니다'));
    expect(shell.tip, 'JJ_MKVMaker · ⚠ 동기화 멈춤 1개');
    // 같은 쌍이 계속 멈춰 있으면 다시 알리지 않는다
    await live.syncNow(pair);
    await Future<void>.delayed(Duration.zero);
    expect(shell.notes, hasLength(1));
    // 알림 · 트레이를 누르면 lsync 카드로
    shell.click!();
    shell.trayShown!();
    expect(opened, 2);
    // 다시 정상이 되면 툴팁에서 빠지고, 또 멈추면 다시 알린다 (창이 앞에 있으면 알림 없이 툴팁만)
    Directory(pair.source).createSync();
    File(p.join(pair.source, 'a.txt')).writeAsStringSync('a');
    await live.syncNow(pair);
    await Future<void>.delayed(Duration.zero);
    expect(shell.tip, 'JJ_MKVMaker');
    Directory(pair.source).deleteSync(recursive: true);
    shell.front = true;
    await live.syncNow(pair);
    await Future<void>.delayed(Duration.zero);
    expect(shell.notes, hasLength(1));
    expect(shell.tip, contains('⚠'));
    alert.dispose();
    live.dispose();
  });
}
