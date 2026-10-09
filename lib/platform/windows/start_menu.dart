import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;

/// 99 (사용자 결정): 지금 사용자의 시작 메뉴에 JJ_MKVMaker 바로 가기를 앱 ID (AUMID) 와 함께 만들고,
/// jjmkvmaker:// 주소를 이 앱으로 연결한다 (관리자 권한 없이 - 사용자 영역만).
/// 그래야 Windows 알림의 출처가 "JJ_MKVMaker" 로 보이고, 알림을 누르면 앱이 열린다 (jjmkvmaker://lsync).
class StartMenu {
  static const aumid = 'JJ.MKVMaker';
  static const protocol = 'jjmkvmaker';

  /// 바로 가기 파일 (사용자의 시작 메뉴)
  static String get shortcutPath => p.join(Platform.environment['APPDATA'] ?? '', 'Microsoft', 'Windows', 'Start Menu',
      'Programs', 'JJ_MKVMaker.lnk');

  /// 이 프로세스의 앱 ID (작업 표시줄 · 알림이 바로 가기와 같은 앱으로 묶이게)
  static void setProcessAppId() {
    if (!Platform.isWindows) return;
    final id = aumid.toNativeUtf16();
    try {
      final shell32 = DynamicLibrary.open('shell32.dll');
      final f = shell32.lookupFunction<Int32 Function(Pointer<Utf16>), int Function(Pointer<Utf16>)>(
          'SetCurrentProcessExplicitAppUserModelID');
      f(id);
    } catch (_) {
    } finally {
      calloc.free(id);
    }
  }

  /// 바로 가기 · 주소 연결을 만든다 (있고 이 실행 파일을 가리키면 그대로, 앱 폴더를 옮겼으면 고친다). 됐으면 true
  /// [lnk] · [registerProtocol]: 시험용 (사용자의 시작 메뉴 · 레지스트리를 건드리지 않고)
  static Future<bool> ensure({String? exe, String? lnk, bool registerProtocol = true}) async {
    if (!Platform.isWindows) return false;
    final target = exe ?? appLauncher();
    final script = _script(lnk ?? shortcutPath, target, registerProtocol: registerProtocol);
    try {
      final r = await Process.run(
        'powershell.exe',
        ['-NoProfile', '-NonInteractive', '-WindowStyle', 'Hidden', '-EncodedCommand', _encode(script)],
      ).timeout(const Duration(seconds: 60));
      return r.exitCode == 0 && '${r.stdout}'.contains('JJ_OK');
    } catch (_) {
      return false;
    }
  }

  /// 사용자가 켜는 실행 파일: 배포판은 폴더 맨 위의 jj_mkvmaker.exe (Lib\jj_mkvmaker.exe 를 띄우는 실행기), 아니면 지금 실행 파일
  static String appLauncher([String? running]) {
    final exe = running ?? Platform.resolvedExecutable;
    final dir = p.dirname(exe);
    if (p.basename(dir).toLowerCase() == 'lib') {
      final launcher = p.join(p.dirname(dir), p.basename(exe));
      if (File(launcher).existsSync()) return launcher;
    }
    return exe;
  }

  /// 설정에서 끄면: 바로 가기 · 주소 연결을 지운다 (이 앱이 만든 것만)
  static Future<void> remove() async {
    if (!Platform.isWindows) return;
    try {
      final f = File(shortcutPath);
      if (await f.exists()) await f.delete();
      await Process.run('reg.exe', ['delete', r'HKCU\Software\Classes\' + protocol, '/f']);
    } catch (_) {}
  }

  static String _encode(String script) {
    final bytes = <int>[for (final u in script.codeUnits) ...[u & 0xff, u >> 8]];
    return base64Encode(bytes);
  }

  static String _q(String s) => s.replaceAll("'", "''");

  static String _script(String lnk, String exe, {bool registerProtocol = true}) => '''
\$ErrorActionPreference = 'Stop'
\$lnk = '${_q(lnk)}'
\$exe = '${_q(exe)}'
if (\$${registerProtocol ? 'true' : 'false'}) {
  # 주소 연결 (사용자 영역): jjmkvmaker://... → 이 실행 파일
  \$k = 'HKCU:\\Software\\Classes\\$protocol'
  New-Item -Path \$k -Force | Out-Null
  Set-ItemProperty -Path \$k -Name '(default)' -Value 'URL:JJ_MKVMaker'
  Set-ItemProperty -Path \$k -Name 'URL Protocol' -Value ''
  New-Item -Path "\$k\\shell\\open\\command" -Force | Out-Null
  Set-ItemProperty -Path "\$k\\shell\\open\\command" -Name '(default)' -Value ('"' + \$exe + '" "%1"')
}
# 바로 가기가 이미 이 실행 파일을 가리키면 그대로
if (Test-Path -LiteralPath \$lnk) {
  \$cur = (New-Object -ComObject WScript.Shell).CreateShortcut(\$lnk).TargetPath
  if (\$cur -eq \$exe) { 'JJ_OK'; exit 0 }
}
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
[ComImport, Guid("00021401-0000-0000-C000-000000000046")] class CShellLink {}
[ComImport, InterfaceType(ComInterfaceType.InterfaceIsIUnknown), Guid("000214F9-0000-0000-C000-000000000046")]
interface IShellLinkW {
  void GetPath([Out, MarshalAs(UnmanagedType.LPWStr)] System.Text.StringBuilder f, int c, IntPtr d, uint fl);
  void GetIDList(out IntPtr p); void SetIDList(IntPtr p);
  void GetDescription([Out, MarshalAs(UnmanagedType.LPWStr)] System.Text.StringBuilder n, int c);
  void SetDescription([MarshalAs(UnmanagedType.LPWStr)] string n);
  void GetWorkingDirectory([Out, MarshalAs(UnmanagedType.LPWStr)] System.Text.StringBuilder d, int c);
  void SetWorkingDirectory([MarshalAs(UnmanagedType.LPWStr)] string d);
  void GetArguments([Out, MarshalAs(UnmanagedType.LPWStr)] System.Text.StringBuilder a, int c);
  void SetArguments([MarshalAs(UnmanagedType.LPWStr)] string a);
  void GetHotkey(out short h); void SetHotkey(short h);
  void GetShowCmd(out int s); void SetShowCmd(int s);
  void GetIconLocation([Out, MarshalAs(UnmanagedType.LPWStr)] System.Text.StringBuilder p, int c, out int i);
  void SetIconLocation([MarshalAs(UnmanagedType.LPWStr)] string p, int i);
  void SetRelativePath([MarshalAs(UnmanagedType.LPWStr)] string p, uint r);
  void Resolve(IntPtr h, uint f);
  void SetPath([MarshalAs(UnmanagedType.LPWStr)] string f);
}
[StructLayout(LayoutKind.Sequential, Pack = 4)] public struct JJPropKey { public Guid fmtid; public uint pid; }
[StructLayout(LayoutKind.Explicit)] public struct JJPropVariant { [FieldOffset(0)] public ushort vt; [FieldOffset(8)] public IntPtr p; [FieldOffset(8)] public long pad; }
[ComImport, InterfaceType(ComInterfaceType.InterfaceIsIUnknown), Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99")]
interface IPropertyStore {
  void GetCount(out uint c); void GetAt(uint i, out JJPropKey k);
  void GetValue(ref JJPropKey k, out JJPropVariant v); void SetValue(ref JJPropKey k, ref JJPropVariant v); void Commit();
}
public static class JJLink {
  public static void Make(string lnk, string exe, string aumid) {
    var link = (IShellLinkW)new CShellLink();
    link.SetPath(exe);
    link.SetWorkingDirectory(System.IO.Path.GetDirectoryName(exe));
    link.SetIconLocation(exe, 0);
    link.SetDescription("JJ_MKVMaker");
    var store = (IPropertyStore)link;
    var key = new JJPropKey { fmtid = new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3"), pid = 5 };
    var pv = new JJPropVariant { vt = 31, p = Marshal.StringToCoTaskMemUni(aumid) };
    store.SetValue(ref key, ref pv);
    store.Commit();
    Marshal.FreeCoTaskMem(pv.p);
    ((IPersistFile)link).Save(lnk, true);
  }
}
"@
New-Item -ItemType Directory -Force -Path (Split-Path -LiteralPath \$lnk) | Out-Null
[JJLink]::Make(\$lnk, \$exe, '$aumid')
'JJ_OK'
''';

  /// 이 앱 이름으로 알림 (바로 가기가 있어야 한다). 누르면 jjmkvmaker://[launch] 로 앱이 열린다. 띄웠으면 true
  static Future<bool> toast(String title, String body, {String launch = 'lsync'}) async {
    String esc(String s) =>
        s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('"', '&quot;');
    final lines = body.split('\n');
    final xml = '<toast activationType="protocol" launch="$protocol://$launch">'
        '<visual><binding template="ToastGeneric"><text>${esc(title)}</text>'
        '<text>${esc(lines.first)}</text><text>${esc(lines.skip(1).join(' · '))}</text></binding></visual></toast>';
    final script = '''
[Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] > \$null
[Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime] > \$null
\$x = New-Object Windows.Data.Xml.Dom.XmlDocument
\$x.LoadXml('${_q(xml)}')
\$t = New-Object Windows.UI.Notifications.ToastNotification \$x
[Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier('$aumid').Show(\$t)
''';
    try {
      final r = await Process.run(
        'powershell.exe',
        ['-NoProfile', '-NonInteractive', '-WindowStyle', 'Hidden', '-EncodedCommand', _encode(script)],
      ).timeout(const Duration(seconds: 20));
      return r.exitCode == 0 && !'${r.stderr}'.contains('Exception') && !'${r.stderr}'.contains('<S S="Error">');
    } catch (_) {
      return false;
    }
  }
}
