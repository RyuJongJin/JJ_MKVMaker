import 'package:flutter_test/flutter_test.dart';
import 'package:jj_mkvmaker/app/live_sync.dart';
import 'package:jj_mkvmaker/app/settings.dart';

/// 97: 실시간 동기화의 지우기는 쌍의 "지우기 포함" 으로만 (설정 옵션의 --delete · --del · /MIR · /PURGE 는 빼고)
void main() {
  test('rsync: 설정 옵션의 지우기는 빼고, 쌍이 지우기 포함일 때만 --delete 하나', () {
    final s = AppSettings()..rsyncOptions = '-avPog --delete --del --delete-after';
    final off = LiveSync.rsyncArgsFor(LiveSyncPair('/a', '/b'), s, windows: false);
    expect(off.where((o) => o.startsWith('--del')), isEmpty);
    final on = LiveSync.rsyncArgsFor(LiveSyncPair('/a', '/b', delete: true), s, windows: false);
    expect(on.where((o) => o.startsWith('--del')), ['--delete']);
  });

  test('robocopy: /MIR 는 /E 로, /PURGE 는 쌍이 지우기 포함일 때만', () {
    final s = AppSettings()..robocopyOptions = '/MIR /PURGE /R:2';
    final off = LiveSync.robocopyArgsFor(LiveSyncPair(r'C:\a', r'D:\b'), s).map((o) => o.toUpperCase()).toList();
    expect(off, isNot(contains('/MIR')));
    expect(off, isNot(contains('/PURGE')));
    expect(off, contains('/E'));
    final on = LiveSync.robocopyArgsFor(LiveSyncPair(r'C:\a', r'D:\b', delete: true), s).map((o) => o.toUpperCase()).toList();
    expect(on.where((o) => o == '/PURGE'), hasLength(1));
  });

  test('107: 원본을 지우는 옵션 (--remove-source-files · /MOV · /MOVE) 도 실시간 동기화에서는 쓰지 않는다', () {
    final s = AppSettings()
      ..rsyncOptions = '-avPog --remove-source-files --remove-sent-files'
      ..robocopyOptions = '/E /MOV /MOVE';
    final r = LiveSync.rsyncArgsFor(LiveSyncPair('/a', '/b', delete: true), s, windows: false);
    expect(r.where((o) => o.startsWith('--remove')), isEmpty);
    final w = LiveSync.robocopyArgsFor(LiveSyncPair(r'C:', r'D:', delete: true), s).map((o) => o.toUpperCase()).toList();
    expect(w, isNot(contains('/MOV')));
    expect(w, isNot(contains('/MOVE')));
  });
}
