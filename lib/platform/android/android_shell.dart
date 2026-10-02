import 'package:flutter/services.dart';

import '../../services/app_shell.dart';

/// Android: 창 · 트레이 · 단축키 · 탐색기 연결은 없음. 종료와 전체 화면만.
class AndroidShell extends NoopShell {
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
}
