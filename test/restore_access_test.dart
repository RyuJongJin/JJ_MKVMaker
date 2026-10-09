import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jj_mkvmaker/app/app_controller.dart';
import 'package:jj_mkvmaker/app/install_marker.dart';
import 'package:jj_mkvmaker/app/version_snapshot.dart';
import 'package:jj_mkvmaker/core/models.dart';
import 'package:jj_mkvmaker/platform/windows/desktop_storage_service.dart';
import 'package:jj_mkvmaker/services/media_tool.dart';
import 'package:jj_mkvmaker/services/platform_services.dart';
import 'package:jj_mkvmaker/ui/all_files_guide.dart';
import 'package:jj_mkvmaker/ui/version_restore.dart';
import 'package:path/path.dart' as p;

/// 권한이 생기기 전에는 Permission denied 로 실패하는 가짜 FFprobe
class _Tool implements MediaTool {
  bool allowed = false;
  var probes = 0;
  @override
  Future<String?> version() async => 'ffmpeg test';
  @override
  Future<Set<String>> encoders() async => {'libx264'};
  @override
  Future<MediaInfo> probe(String path) async {
    probes++;
    if (!allowed) throw MediaToolException('파일을 분석할 수 없습니다: $path: Permission denied');
    return const MediaInfo(duration: Duration(seconds: 1), streams: [
      StreamInfo(index: 0, type: 'video', codec: 'h264', width: 640, height: 360),
      StreamInfo(index: 1, type: 'subtitle', codec: 'subrip', language: 'eng'),
    ]);
  }

  @override
  Future<void> runFfmpeg(List<String> args, {Duration? duration, ProgressCallback? onProgress}) async {}
  @override
  void cancel() {}
}

void main() {
  group('115: Android 자동 백업에서 되살아났는지', () {
    final t0 = DateTime(2026, 10, 9, 10);
    test('새로 설치 · 설정 있음 · 표시 파일 없음 = 자동 백업', () {
      expect(restoredByAutoBackup(settingsExisted: true, markerExists: false, installTime: t0, updateTime: t0), isTrue);
    });
    test('업데이트로 처음 이 판을 켬 (설치 ≠ 업데이트 시각) · 표시 파일 있음 · 설정 없음 = 아님', () {
      expect(
          restoredByAutoBackup(
              settingsExisted: true, markerExists: false, installTime: t0, updateTime: t0.add(const Duration(days: 3))),
          isFalse);
      expect(restoredByAutoBackup(settingsExisted: true, markerExists: true, installTime: t0, updateTime: t0), isFalse);
      expect(restoredByAutoBackup(settingsExisted: false, markerExists: false, installTime: t0, updateTime: t0), isFalse);
      expect(restoredByAutoBackup(settingsExisted: true, markerExists: false, installTime: null, updateTime: t0), isFalse);
    });
    test('표시 파일 쓰기 · 백업 규칙에서 빠져 있음', () {
      final dir = Directory.systemTemp.createTempSync('jj_marker_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final m = InstallMarker(dir.path);
      expect(m.exists, isFalse);
      m.write();
      expect(m.exists, isTrue);
      for (final f in ['backup_rules.xml', 'data_extraction_rules.xml']) {
        final xml = File('android/app/src/main/res/xml/$f').readAsStringSync();
        expect(xml, contains('<exclude domain="file" path="${InstallMarker.fileName}" />'), reason: f);
      }
    });
    test('보관본 요약: 동영상 수 · 서버 이름 · 보관한 때', () {
      final dir = Directory.systemTemp.createTempSync('jj_sum_');
      addTearDown(() => dir.deleteSync(recursive: true));
      File(p.join(dir.path, 'videos.json')).writeAsStringSync(jsonEncode(['/a.mp4', '/b.mp4', '/c.mp4']));
      File(p.join(dir.path, 'settings.json')).writeAsStringSync(jsonEncode({
        'webdavServers': [
          {'id': '1', 'name': 'NAS', 'url': 'https://nas', 'hasPassword': true},
        ],
      }));
      File(p.join(dir.path, 'snapshot.json')).writeAsStringSync(jsonEncode({'saved': '2026-10-08T21:30:00'}));
      final s = VersionSnapshot.summaryOf(dir.path);
      expect(s.videos, 3);
      expect(s.servers, ['NAS']);
      expect(s.saved, DateTime(2026, 10, 8, 21, 30));
      final empty = VersionSnapshot.summaryOf(p.join(dir.path, 'none'));
      expect(empty.videos, 0);
      expect(empty.servers, isEmpty);
      expect(empty.saved, isNull);
    });

    Future<bool?> show(WidgetTester t, {SettingsSummary? kept}) async {
      bool? result;
      await t.pumpWidget(MaterialApp(
        home: Builder(
          builder: (ctx) => TextButton(
            onPressed: () async => result = await showAutoBackupNotice(ctx,
                restored: (videos: 5, servers: <String>[], saved: null), kept: kept, keptName: '1.2.3'),
            child: const Text('go'),
          ),
        ),
      ));
      await t.tap(find.text('go'));
      await t.pumpAndSettle();
      expect(find.textContaining('Android 자동 백업'), findsOneWidget);
      expect(find.textContaining('동영상 목록 5개'), findsOneWidget);
      expect(find.textContaining('비밀번호'), findsOneWidget);
      return result;
    }

    testWidgets('알림: 보관본이 없으면 [확인] 만', (t) async {
      await show(t);
      expect(find.textContaining('WebDAV 서버: 없음'), findsOneWidget);
      expect(find.text('보관한 설정으로 되살리고 다시 시작'), findsNothing);
      await t.tap(find.text('확인'));
      await t.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
    });

    testWidgets('알림: 공용 폴더 보관본이 있으면 서버 목록까지 보여 주고 그것으로 되살릴지', (t) async {
      await show(t, kept: (videos: 7, servers: ['NAS', 'ds'], saved: DateTime(2026, 10, 8, 21, 30)));
      expect(find.textContaining('v1.2.3 · 2026-10-08 21:30'), findsOneWidget);
      expect(find.textContaining('WebDAV 서버: NAS, ds'), findsOneWidget);
      expect(find.text('자동 백업 그대로'), findsOneWidget);
      await t.tap(find.text('보관한 설정으로 되살리고 다시 시작'));
      await t.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
    });
  });

  group('116: 권한 안내 · 허용하면 다시 분석', () {
    test('권한이 없어 실패 → 알아볼 수 있는 안내, 허용 뒤 reanalyzeFailed 로 다시 분석 (자막 중복 없이)', () async {
      final dir = Directory.systemTemp.createTempSync('jj_116_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final video = File(p.join(dir.path, '삼체.mkv'))..writeAsStringSync('');
      File(p.join(dir.path, '삼체.ko.srt')).writeAsStringSync('1\n00:00:01,000 --> 00:00:02,000\n안녕\n');
      final tool = _Tool();
      final c = AppController(PlatformServices(mediaTool: tool, storage: DesktopStorageService()));
      var access = false;
      c.fileAccess = () async => access;

      await c.addVideos([video.path], allowOutputFolder: true);
      final v = c.videos.single;
      expect(v.info, isNull);
      expect(v.message, AppController.accessNeededMessage);
      expect(v.message, isNot(contains('Permission denied')));
      final external = v.subtitles.where((s) => s.kind != SubtitleKind.embedded).length;

      // 허용하고 돌아옴
      access = true;
      tool.allowed = true;
      expect(await c.reanalyzeFailed(), 1);
      expect(v.info, isNotNull);
      expect(v.message, isNull);
      expect(v.subtitles.where((s) => s.kind == SubtitleKind.embedded).length, 1);
      expect(v.subtitles.where((s) => s.kind != SubtitleKind.embedded).length, external, reason: '같은 폴더 자막이 두 번 들어가지 않게');
      // 이미 분석된 것은 다시 하지 않는다
      final before = tool.probes;
      expect(await c.reanalyzeFailed(), 0);
      expect(tool.probes, before);
    });

    test('권한이 있는데 실패한 것 (다른 까닭) 은 원래 오류 그대로', () async {
      final dir = Directory.systemTemp.createTempSync('jj_116b_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final video = File(p.join(dir.path, 'a.mkv'))..writeAsStringSync('');
      final c = AppController(PlatformServices(mediaTool: _Tool(), storage: DesktopStorageService()));
      c.fileAccess = () async => true;
      await c.addVideos([video.path], allowOutputFolder: true);
      expect(c.videos.single.message, contains('Permission denied'));
    });

    test('안내는 겹쳐 띄우지 않되, 권한이 있다가 없어지면 다음에 켤 때 한 번 더', () async {
      final c = AppController(PlatformServices(mediaTool: _Tool(), storage: DesktopStorageService()));
      expect(c.settings.allFilesHintShown, isFalse);
      expect(await allFilesGuideDue(c, hasAccess: false), isTrue, reason: '처음 켬, 권한 없음');
      expect(await allFilesGuideDue(c, hasAccess: false), isFalse, reason: '다시 켜도 권한이 계속 없으면 띄우지 않음');
      expect(await allFilesGuideDue(c, hasAccess: true), isFalse, reason: '허용함');
      expect(c.settings.allFilesHintShown, isFalse);
      expect(await allFilesGuideDue(c, hasAccess: true), isFalse);
      expect(await allFilesGuideDue(c, hasAccess: false), isTrue, reason: '사용자가 권한을 끈 뒤 켬 → 한 번 더');
      expect(await allFilesGuideDue(c, hasAccess: false), isFalse);
    });

    testWidgets('처음 켤 때 안내: [허용] 은 설정 열기, [나중에] 는 그냥 닫기', (t) async {
      var requested = 0;
      await t.pumpWidget(MaterialApp(
        home: Builder(
          builder: (ctx) => TextButton(
            onPressed: () => showAllFilesGuide(ctx, () async => requested++),
            child: const Text('go'),
          ),
        ),
      ));
      await t.tap(find.text('go'));
      await t.pumpAndSettle();
      expect(find.textContaining('저절로 다시 분석'), findsOneWidget);
      await t.tap(find.text('나중에'));
      await t.pumpAndSettle();
      expect(requested, 0);
      await t.tap(find.text('go'));
      await t.pumpAndSettle();
      await t.tap(find.text('허용'));
      await t.pumpAndSettle();
      expect(requested, 1);
    });
  });
}
