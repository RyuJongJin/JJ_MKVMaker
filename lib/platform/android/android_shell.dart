import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../../services/app_shell.dart';

/// Android: 창 · 트레이 · 단축키 · 탐색기 연결은 없음. 종료 · 전체 화면 · 웹 주소 열기 · 폴더 열기 (파일 앱).
class AndroidShell extends NoopShell {
  static const _ch = MethodChannel('jj_mkvmaker/android');
  bool _full = false;

  @override
  Future<void> quit() => SystemNavigator.pop();

  @override
  Future<void> setFullScreen(bool on) async {
    _full = on;
    await SystemChrome.setEnabledSystemUIMode(on ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge);
  }

  @override
  Future<bool> isFullScreen() async => _full;

  /// 기기의 기본 브라우저로 (고른 브라우저는 PC 에서만)
  @override
  Future<void> openUrl(String url, {String browser = 'system'}) async {
    try {
      await _ch.invokeMethod<bool>('openUrl', {'url': url});
    } catch (_) {}
  }

  /// 파일이 있는 폴더 (폴더면 그 폴더) 를 파일 앱으로
  @override
  Future<void> revealFile(String path) async {
    final dir = await FileSystemEntity.isDirectory(path) ? path : p.dirname(path);
    try {
      await _ch.invokeMethod<bool>('openFolder', {'path': dir});
    } catch (_) {}
  }
}
