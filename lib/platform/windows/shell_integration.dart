import 'dart:io';

import '../../core/subtitle_detector.dart';
import '../../l10n/tr.dart';

/// 탐색기 오른쪽 클릭 메뉴 등록 (현재 사용자만, 관리자 권한 불필요)
///
///   JJ_MKVMaker 로 재생         → jj_mkvmaker.exe --play "파일"
///   JJ_MKVMaker 로 자막 만들기  → jj_mkvmaker.exe --subtitle "파일"
///
/// Windows 11 에서는 "더 많은 옵션 표시" 안에 나타난다.
class ShellIntegration {
  static const _root = r'HKCU\Software\Classes\SystemFileAssociations';
  static final _verbs = {
    'JJMKVMaker.Play': (tr('JJ_MKVMaker 로 재생'), '--play'),
    'JJMKVMaker.Subtitle': (tr('JJ_MKVMaker 로 자막 만들기'), '--subtitle'),
  };

  final String exePath;
  final List<String> extensions;

  ShellIntegration({String? exePath, List<String>? extensions})
      : exePath = exePath ?? Platform.resolvedExecutable,
        extensions = extensions ?? videoExtensions;

  static Future<bool> _reg(List<String> args) async =>
      (await Process.run('reg', args)).exitCode == 0;

  Future<bool> isRegistered() => _reg(['query', '$_root\\.${extensions.first}\\shell\\JJMKVMaker.Play']);

  /// 이전 이름(JJ CapCut)으로 등록된 메뉴
  static const _legacyVerbs = ['JJCapCut.Play', 'JJCapCut.Subtitle'];

  Future<bool> register() async {
    await _removeLegacy();
    var ok = true;
    for (final ext in extensions) {
      for (final e in _verbs.entries) {
        final key = '$_root\\.$ext\\shell\\${e.key}';
        final (label, flag) = e.value;
        ok &= await _reg(['add', key, '/ve', '/d', label, '/f']);
        ok &= await _reg(['add', key, '/v', 'Icon', '/d', '"$exePath",0', '/f']);
        // 파일을 많이 골라도 메뉴가 보이도록
        ok &= await _reg(['add', key, '/v', 'MultiSelectModel', '/d', 'Player', '/f']);
        ok &= await _reg(['add', '$key\\command', '/ve', '/d', '"$exePath" $flag "%1"', '/f']);
      }
    }
    return ok;
  }

  Future<void> unregister() async {
    await _removeLegacy();
    for (final ext in extensions) {
      for (final verb in _verbs.keys) {
        await _reg(['delete', '$_root\\.$ext\\shell\\$verb', '/f']);
      }
    }
  }

  Future<void> _removeLegacy() async {
    for (final ext in extensions) {
      for (final verb in _legacyVerbs) {
        await _reg(['delete', '$_root\\.$ext\\shell\\$verb', '/f']);
      }
    }
  }
}

/// 외부 브라우저 실행 파일 이름
const browserExecutables = {
  'chrome': 'chrome.exe',
  'firefox': 'firefox.exe',
  'edge': 'msedge.exe',
  'whale': 'whale.exe',
};

/// 설치된 브라우저 경로 (Windows "App Paths" 등록 정보). 없으면 null.
String? findBrowser(String browser) {
  final exe = browserExecutables[browser];
  if (exe == null) return null;
  for (final hive in ['HKCU', 'HKLM']) {
    final r = Process.runSync('reg', ['query', '$hive\\Software\\Microsoft\\Windows\\CurrentVersion\\App Paths\\$exe', '/ve']);
    if (r.exitCode != 0) continue;
    final m = RegExp(r'REG_SZ\s+(.+)$', multiLine: true).firstMatch('${r.stdout}');
    final path = m?.group(1)?.trim().replaceAll('"', '');
    if (path != null && File(path).existsSync()) return path;
  }
  return null;
}

/// 웹 주소를 브라우저로 열기 ('system' 이거나 찾지 못하면 Windows 기본 브라우저)
Future<void> openInBrowser(String url, String browser) async {
  final exe = browser == 'system' ? null : findBrowser(browser);
  if (exe != null) {
    await Process.start(exe, [url], mode: ProcessStartMode.detached);
  } else {
    await Process.start('explorer.exe', [url], mode: ProcessStartMode.detached);
  }
}

/// 외부 플레이어 찾기
String? findVlc() {
  for (final base in [
    Platform.environment['ProgramFiles'],
    Platform.environment['ProgramFiles(x86)'],
    Platform.environment['ProgramW6432'],
  ]) {
    if (base == null) continue;
    final f = '$base\\VideoLAN\\VLC\\vlc.exe';
    if (File(f).existsSync()) return f;
  }
  return null;
}

/// 외부 프로그램으로 열기. [program] 이 'system' 이면 Windows 기본 연결 프로그램 (첫 파일만).
Future<void> openExternally(String program, List<String> files) async {
  if (files.isEmpty) return;
  if (program == 'system') {
    await Process.start('explorer.exe', [files.first], mode: ProcessStartMode.detached);
  } else {
    await Process.start(program, files, mode: ProcessStartMode.detached);
  }
}
