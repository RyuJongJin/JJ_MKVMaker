import 'package:flutter/material.dart';

import '../app/app_controller.dart';
import '../platform/windows/cef_runtime.dart';
import 'theme.dart';

/// 환경 설정에서 "Chrome (내장)" 을 골랐을 때: 엔진이 없으면 내려받고, 설정을 바꾼 뒤 다시 시작을 권한다.
/// 끝까지 진행했으면 true (설정이 'chrome' 으로 바뀜).
Future<bool> chooseChromeEngine(BuildContext context, AppController c) async {
  if (!CefRuntime.installed) {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('내장 Chrome 엔진 내려받기'),
        content: const SizedBox(
          width: 460,
          child: Text(
            'Chrome 엔진 (CEF ${CefRuntime.version}) 을 공식 배포처에서 내려받습니다.\n'
            '· 받을 크기: 약 ${CefRuntime.approxDownloadMb}MB (설치 후 약 390MB)\n'
            '· 설치 위치: 프로그램 폴더의 Lib\\cef\n'
            '· 설치한 뒤 프로그램을 다시 시작하면 앱 안 브라우저가 Chrome 엔진으로 바뀝니다.\n\n'
            '참고: Google 은 이런 내장 브라우저의 로그인을 막을 수 있습니다. '
            'YouTube 로그인이 필요하면 Edge 엔진을 쓰세요 (언제든 다시 바꿀 수 있습니다).',
            style: TextStyle(fontSize: 13),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('취소')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('내려받기')),
        ],
      ),
    );
    if (ok != true || !context.mounted) return false;
    final installed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _InstallProgress(c: c),
    );
    if (installed != true || !context.mounted) return false;
  }
  await c.updateSettings((s) => s.browserEngine = 'chrome');
  if (!context.mounted) return true;
  if (!CefRuntime.readyThisRun) {
    final restart = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('다시 시작'),
        content: const Text('Chrome 엔진은 프로그램을 다시 시작하면 쓸 수 있습니다. 지금 다시 시작할까요?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('나중에')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('다시 시작')),
        ],
      ),
    );
    if (restart == true) await c.services.shell.restart();
  }
  return true;
}

class _InstallProgress extends StatefulWidget {
  final AppController c;
  const _InstallProgress({required this.c});

  @override
  State<_InstallProgress> createState() => _InstallProgressState();
}

class _InstallProgressState extends State<_InstallProgress> {
  double _p = 0;
  String _stage = '준비 중';
  String? _error;
  bool _cancel = false;

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    widget.c.note('내장 Chrome 엔진 내려받기 시작: ${CefRuntime.downloadUri}');
    try {
      await CefRuntime.install(
        onProgress: (p, stage) {
          if (mounted) {
            setState(() {
              _p = p;
              _stage = stage;
            });
          }
        },
        isCancelled: () => _cancel,
      );
      widget.c.note('내장 Chrome 엔진 설치 완료 (${CefRuntime.installedMb()}MB): ${CefRuntime.dir}');
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      widget.c.note('내장 Chrome 엔진 설치 실패: $e');
      if (mounted) setState(() => _error = '$e');
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('내장 Chrome 엔진'),
        content: SizedBox(
          width: 420,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (_error == null) ...[
              Text('$_stage  ${(_p * 100).round()}%'),
              const SizedBox(height: 8),
              LinearProgressIndicator(value: _p <= 0 ? null : _p),
            ] else
              Text('설치하지 못했습니다.\n$_error', style: const TextStyle(color: JjColors.danger)),
          ]),
        ),
        actions: [
          if (_error == null)
            TextButton(onPressed: () => setState(() => _cancel = true), child: const Text('취소'))
          else
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('닫기')),
        ],
      );
}
