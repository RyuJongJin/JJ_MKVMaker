import 'dart:io';

import 'package:flutter/material.dart';

import '../l10n/tr.dart';
import '../platform/windows/start_menu.dart';

/// Windows 알림이 꺼져 있는 까닭 (켜져 있으면 null)
enum ToastBlock { all, app }

/// reg query 출력에서 DWORD 값 (없으면 null)
int? regDword(String out, String name) {
  final m = RegExp('^\\s*${RegExp.escape(name)}\\s+REG_DWORD\\s+0x([0-9a-fA-F]+)', multiLine: true).firstMatch(out);
  return m == null ? null : int.tryParse(m.group(1)!, radix: 16);
}

/// 전체 알림 (ToastEnabled) · 이 앱 알림 (Notifications\Settings\JJ.MKVMaker Enabled) 이 0 이면 꺼짐.
/// 값이 없으면 켜짐 (Windows 기본). 읽기만 하고 바꾸지 않는다.
ToastBlock? toastBlockFrom({required String global, required String app}) {
  if (regDword(global, 'ToastEnabled') == 0) return ToastBlock.all;
  if (regDword(app, 'Enabled') == 0) return ToastBlock.app;
  return null;
}

Future<ToastBlock?> readToastBlock() async {
  // 위젯 시험에서는 실제 레지스트리를 읽지 않는다 (가짜 시간 안에서 프로세스가 끝나지 않음)
  if (!Platform.isWindows || Platform.environment.containsKey('FLUTTER_TEST')) return null;
  Future<String> q(String key) async {
    try {
      final r = await Process.run('reg.exe', ['query', key]);
      return r.exitCode == 0 ? '${r.stdout}' : '';
    } catch (_) {
      return '';
    }
  }

  return toastBlockFrom(
    global: await q(r'HKCU\Software\Microsoft\Windows\CurrentVersion\PushNotifications'),
    app: await q('HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Notifications\\Settings\\${StartMenu.aumid}'),
  );
}

/// "동기화가 멈추면 Windows 알림" 아래: 알림이 꺼져 있으면 알리고 Windows 설정을 열어 준다 (앱이 설정을 바꾸지는 않는다)
class ToastStatusHint extends StatefulWidget {
  const ToastStatusHint({super.key, this.check = readToastBlock, this.openSettings = openNotificationSettings});

  final Future<ToastBlock?> Function() check;
  final Future<void> Function() openSettings;

  @override
  State<ToastStatusHint> createState() => _ToastStatusHintState();
}

Future<void> openNotificationSettings() async {
  try {
    await Process.start('explorer.exe', ['ms-settings:notifications']);
  } catch (_) {}
}

class _ToastStatusHintState extends State<ToastStatusHint> {
  ToastBlock? _block;
  late final AppLifecycleListener _life;

  @override
  void initState() {
    super.initState();
    // Windows 설정에서 켜고 돌아오면 다시 확인
    _life = AppLifecycleListener(onResume: _refresh);
    _refresh();
  }

  @override
  void dispose() {
    _life.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    final b = await widget.check();
    if (mounted && b != _block) setState(() => _block = b);
  }

  @override
  Widget build(BuildContext context) {
    final b = _block;
    if (b == null) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 8,
        runSpacing: 4,
        children: [
          Icon(Icons.notifications_off_outlined, size: 18, color: scheme.error),
          Text(
            b == ToastBlock.all
                ? tr('Windows 알림이 꺼져 있어 보이지 않습니다')
                : tr('Windows 에서 이 앱의 알림이 꺼져 있어 보이지 않습니다'),
            style: TextStyle(color: scheme.error),
          ),
          OutlinedButton(
            onPressed: () async {
              await widget.openSettings();
            },
            child: Text(tr('Windows 알림 설정 열기')),
          ),
          IconButton(
            tooltip: tr('다시 확인'),
            icon: const Icon(Icons.refresh, size: 18),
            onPressed: _refresh,
          ),
        ],
      ),
    );
  }
}
