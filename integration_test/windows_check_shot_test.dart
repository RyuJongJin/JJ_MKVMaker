import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:jj_mkvmaker/app/app_controller.dart';
import 'package:jj_mkvmaker/app/master_lock.dart';
import 'package:jj_mkvmaker/platform/windows/recycle_bin.dart';
import 'package:jj_mkvmaker/services/image_ai.dart';
import 'package:jj_mkvmaker/services/platform_services.dart';
import 'package:jj_mkvmaker/services/secret_store.dart';
import 'package:jj_mkvmaker/ui/ai_image_page.dart';
import 'package:jj_mkvmaker/ui/explorer_page.dart';
import 'package:jj_mkvmaker/ui/master_prompt.dart';
import 'package:jj_mkvmaker/ui/security_settings.dart';
import 'package:jj_mkvmaker/ui/theme.dart';
import 'package:path/path.dart' as p;

import '../test/support/fake_recycle_bin.dart';

/// 기기 감독 (Windows) 확인용: 실제 앱 화면을 띄워 누르고 단계마다 PNG (JJ_SHOT_DIR) 로 남긴다.
/// 65 · 94 · 98 (휴지통 · 휴지통 없는 위치 · 오류 문구), 37 (경로 입력), 124 · 130 (마스터 · 최상), 123 (AI 그림).
/// 시험 폴더 · 메모리 저장소만 쓴다 (사용자 설정 · 비밀번호는 건드리지 않음). 휴지통에 넣은 시험 항목은 끝에 $I 로 골라 지운다.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final out = Platform.environment['JJ_SHOT_DIR'] ?? p.join(Directory.systemTemp.path, 'jj_shots');
  // 시험 폴더: 항목이 아주 많은 시스템 임시 폴더 대신 (JJ_SHOT_TMP, 없으면 시스템 임시 폴더)
  Directory tempDir(String prefix) {
    final base = Platform.environment['JJ_SHOT_TMP'];
    if (base == null || base.isEmpty) return Directory.systemTemp.createTempSync(prefix);
    Directory(base).createSync(recursive: true);
    return Directory(base).createTempSync(prefix);
  }
  final key = GlobalKey();
  const sizes = [('narrow', Size(700, 900)), ('wide', Size(1280, 800))];

  Future<void> settle(WidgetTester t, [int rounds = 12]) async {
    for (var i = 0; i < rounds; i++) {
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 120)));
      await t.pump();
    }
  }

  Future<void> shot(WidgetTester t, String name) async {
    await settle(t, 6);
    final b = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final img = await t.runAsync(() => b.toImage());
    final bytes = await t.runAsync(() => img!.toByteData(format: ui.ImageByteFormat.png));
    Directory(out).createSync(recursive: true);
    File(p.join(out, '$name.png')).writeAsBytesSync(bytes!.buffer.asUint8List());
  }

  Future<void> show(WidgetTester t, Size size, Widget home) async {
    t.view.physicalSize = size;
    t.view.devicePixelRatio = 1;
    await t.runAsync(() => t.pumpWidget(MaterialApp(
          theme: buildTheme(),
          // 창 · 안내 (Navigator 위) 까지 찍히게
          builder: (_, child) => RepaintBoundary(key: key, child: child),
          // 크기마다 새 화면 (같은 자리의 앞 화면 상태를 이어 쓰지 않게)
          home: KeyedSubtree(key: UniqueKey(), child: home),
        )));
    await settle(t);
  }

  AppController controller() => AppController(PlatformServices.create());

  /// 그 글이 화면에 나올 때까지 (목록을 다시 읽는 중일 수 있어) 기다렸다가 누른다
  Future<void> tapText(WidgetTester t, String text) async {
    for (var i = 0; i < 60 && find.text(text).evaluate().isEmpty; i++) {
      await settle(t, 1);
    }
    await t.tap(find.text(text).first);
    await settle(t, 4);
  }

  testWidgets('65 · 94 · 98: 지우기 - 휴지통 · 영구 삭제 · 휴지통 없는 위치 · 오류 문구', (t) async {
    final tmp = tempDir('jj_shot_del_');
    final started = DateTime.now();
    // 휴지통: 기본은 가짜 (화면 흐름만), JJ_TEST_REAL_RECYCLE=1 이면 실제 휴지통 (끝에 시험 항목만 지움)
    useTestRecycleBin();
    try {
      for (final (tag, size) in sizes) {
        final dir = Directory(p.join(tmp.path, tag))..createSync();
        File(p.join(dir.path, 'recycle_me_$tag.txt')).writeAsStringSync('x');
        File(p.join(dir.path, 'keep_$tag.txt')).writeAsStringSync('x');
        final c = controller();
        c.settings
          ..explorerLayout = 'single'
          ..explorerClick = 'select'
          ..explorerPaths = [dir.path, dir.path];
        await show(t, size, ExplorerPage(c: c));
        await tapText(t, 'recycle_me_$tag.txt');
        await t.sendKeyEvent(LogicalKeyboardKey.delete);
        await settle(t);
        await shot(t, '65_recycle_confirm_$tag');
        await t.tap(find.text('휴지통으로').last);
        await settle(t, 20);
        await shot(t, '65_recycle_done_$tag');
        // Shift+Delete: 영구 삭제로 묻는다 (취소)
        await tapText(t, 'keep_$tag.txt');
        await t.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
        await t.sendKeyEvent(LogicalKeyboardKey.delete);
        await t.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
        await settle(t);
        await shot(t, '65_shift_delete_confirm_$tag');
        await t.tap(find.text('취소').last);
        await settle(t);
      }

      // 94: 휴지통이 없는 위치 (네트워크 공유 \\localhost\M$\…) - 처음부터 영구 삭제로 묻는다 (취소)
      final unc = '\\\\localhost\\${tmp.path[0]}\$${tmp.path.substring(2)}';
      final share = Directory(p.join(unc, 'share'))..createSync();
      File(p.join(share.path, 'on_share.txt')).writeAsStringSync('x');
      for (final (tag, size) in sizes) {
        final c = controller();
        c.settings
          ..explorerLayout = 'single'
          ..explorerClick = 'select'
          ..explorerPaths = [share.path, share.path];
        await show(t, size, ExplorerPage(c: c));
        await settle(t, 20);
        await tapText(t, 'on_share.txt');
        await t.sendKeyEvent(LogicalKeyboardKey.delete);
        await settle(t);
        await shot(t, '94_no_recycle_bin_$tag');
        await t.tap(find.text('취소').last);
        await settle(t);
      }

      // 98: 휴지통이 받지 않는 긴 경로 - 이유를 읽을 수 있는 말로
      var deep = p.join(tmp.path, 'long');
      while (deep.length < 250) {
        deep = p.join(deep, 'd' * 30);
      }
      Directory('\\\\?\\$deep').createSync(recursive: true);
      File('\\\\?\\${p.join(deep, 'long_name_file_that_is_too_long_for_the_recycle_bin.txt')}').writeAsStringSync('x');
      for (final (tag, size) in sizes) {
        final c = controller();
        c.settings
          ..explorerLayout = 'single'
          ..explorerClick = 'select'
          ..explorerPaths = [deep, deep];
        await show(t, size, ExplorerPage(c: c));
        await settle(t, 20);
        final f = find.textContaining('long_name_file');
        if (f.evaluate().isEmpty) break;
        await t.tap(f.first);
        await settle(t, 4);
        await t.sendKeyEvent(LogicalKeyboardKey.delete);
        await settle(t);
        await t.tap(find.text('휴지통으로').last);
        await settle(t, 20);
        await shot(t, '98_error_text_$tag');
        // 144 뒤로는 이유 한 줄과 [그대로 두기] / [영구 삭제] 창이 뜬다 - 지우지 않고 닫아 다음 크기로
        for (final b in ['그대로 두기', '확인']) {
          if (find.text(b).evaluate().isNotEmpty) {
            await t.tap(find.text(b).last);
            await settle(t);
          }
        }
      }
    } finally {
      await t.pumpWidget(const SizedBox());
      // 시험이 휴지통에 넣은 것만 ($I 의 원래 경로가 이 시험 폴더인 것) 휴지통에서 지운다
      final removed = await _purgeRecycled(tmp.path, since: started);
      File(p.join(out, 'recycle_bin_cleanup.txt'))
        ..createSync(recursive: true)
        ..writeAsStringSync('시험 폴더: ${tmp.path}\n휴지통에서 지운 시험 항목: $removed\n남은 시험 항목: ${await _countRecycled(tmp.path, since: started)}\n');
      try {
        Directory('\\\\?\\${tmp.path}').deleteSync(recursive: true);
      } catch (_) {}
    }
  });

  testWidgets('37: 경로 입력 - 폴더로 가기 · \\\\NAS 만 · 없는 경로', (t) async {
    final tmp = tempDir('jj_shot_path_');
    try {
      final target = Directory(p.join(tmp.path, '가고 싶은 폴더'))..createSync();
      File(p.join(target.path, 'inside.txt')).writeAsStringSync('x');
      for (final (tag, size) in sizes) {
        final c = controller();
        c.settings
          ..explorerLayout = 'single'
          ..explorerPaths = [tmp.path, tmp.path];
        await show(t, size, ExplorerPage(c: c));
        Future<void> enter(String text) async {
          await t.tap(find.byTooltip('경로 입력').first);
          await settle(t);
          await t.enterText(find.byType(TextField).last, text);
          await settle(t, 3);
        }

        await enter(target.path);
        await shot(t, '37_path_dialog_$tag');
        await t.tap(find.widgetWithText(FilledButton, '확인'));
        await settle(t, 20);
        await shot(t, '37_path_went_$tag');
        await enter('\\\\NAS');
        await t.tap(find.widgetWithText(FilledButton, '확인'));
        await settle(t, 6);
        await shot(t, '37_unc_server_only_$tag');
        await enter(p.join(tmp.path, '없는 폴더'));
        await t.tap(find.widgetWithText(FilledButton, '확인'));
        await settle(t, 6);
        await shot(t, '37_missing_path_$tag');
      }
    } finally {
      await t.pumpWidget(const SizedBox());
      tmp.deleteSync(recursive: true);
    }
  });

  testWidgets('124 · 130: 마스터 · 최상 비밀번호 창 · 초기화 창 · 보안 설정', (t) async {
    for (final (tag, size) in sizes) {
      final c = controller();
      final lock = MasterLock(MemorySecretStore()); // 메모리에만 - 사용자 secrets.dat 는 건드리지 않음
      await t.runAsync(() async {
        await lock.setMaster('m');
        await lock.setSuper('s');
      });
      lock.unlocked = false;
      MasterLock.instance = lock;
      await show(t, size, Scaffold(body: ListView(children: [SecuritySettings(c: c)])));
      await shot(t, '124_security_settings_$tag');
      final ctx = t.element(find.byType(SecuritySettings));
      askMaster(ctx, c, lock);
      await settle(t);
      await shot(t, '124_master_prompt_$tag');
      await t.enterText(find.byType(TextField).last, 'wrong');
      await t.tap(find.text('확인').last);
      await settle(t, 20);
      await shot(t, '124_master_wrong_$tag');
      await t.enterText(find.byType(TextField).last, 's');
      await t.tap(find.text('확인').last);
      await settle(t, 20);
      await shot(t, '124_super_reset_$tag');
      await t.tap(find.text('취소').last);
      await settle(t);
      MasterLock.instance = null;
    }
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('123: AI 그림 화면 - 모델 없음 안내 · 서비스 (기기 밖) 경고', (t) async {
    for (final (tag, size) in sizes) {
      final c = controller();
      await show(t, size, AiImagePage(c: c));
      await shot(t, '123_ai_local_$tag');
      c.settings
        ..aiServices = [const AiService(id: 's', name: 'GPU PC (Tailscale)', url: 'http://100.1.2.3:7860', kind: 'a1111')]
        ..aiEngine = 's';
      await show(t, size, AiImagePage(c: c));
      await shot(t, '123_ai_service_$tag');
    }
    await t.pumpWidget(const SizedBox());
  });
}

/// 휴지통의 $I 정보 중 원래 경로가 [dir] 아래이고 [since] 뒤에 생긴 것 (시험이 넣은 것)
Future<List<File>> _recycledInfos(String dir, {required DateTime since}) async {
  final drive = dir.substring(0, 2);
  final out = <File>[];
  for (final user in Directory('$drive\\\$Recycle.Bin').listSync().whereType<Directory>()) {
    List<FileSystemEntity> items;
    try {
      items = user.listSync();
    } catch (_) {
      continue;
    }
    for (final f in items.whereType<File>()) {
      if (!p.basename(f.path).startsWith(r'$I') || f.lastModifiedSync().isBefore(since.subtract(const Duration(seconds: 5)))) continue;
      final orig = recycledInfoPath(f.readAsBytesSync());
      if (orig != null && orig.toLowerCase().startsWith(dir.toLowerCase())) out.add(f);
    }
  }
  return out;
}

Future<int> _countRecycled(String dir, {required DateTime since}) async => (await _recycledInfos(dir, since: since)).length;

Future<int> _purgeRecycled(String dir, {required DateTime since}) async {
  var n = 0;
  for (final info in await _recycledInfos(dir, since: since)) {
    final data = p.join(p.dirname(info.path), '\$R${p.basename(info.path).substring(2)}');
    try {
      final t = FileSystemEntity.typeSync(data);
      if (t == FileSystemEntityType.directory) Directory(data).deleteSync(recursive: true);
      if (t == FileSystemEntityType.file) File(data).deleteSync();
      info.deleteSync();
      n++;
    } catch (_) {}
  }
  return n;
}
