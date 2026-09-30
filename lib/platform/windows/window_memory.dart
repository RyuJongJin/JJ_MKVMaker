import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/painting.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:window_manager/window_manager.dart';

/// 창 위치 · 크기 · 최대화 여부를 기억했다가 다음에 같은 자리에서 연다.
///
/// [key] 별로 따로 기억한다 ('main' = 원래 창, 'second' = 탐색기에서 연 새 창).
/// 전체 화면 · 팝업 보기 · 최소화 상태에서는 저장하지 않는다 (그 전의 보통 크기를 유지).
class WindowMemory with WindowListener {
  final String file;
  final String key;
  Timer? _debounce;

  /// 팝업 보기처럼 창 크기를 잠깐 바꾸는 동안 true 로 두면 저장하지 않는다
  bool Function()? paused;

  WindowMemory(this.file, this.key);

  Map<String, dynamic> _readAll() {
    try {
      return jsonDecode(File(file).readAsStringSync()) as Map<String, dynamic>;
    } catch (_) {
      return {};
    }
  }

  /// 저장된 자리로 옮기고, 이후 움직이거나 크기를 바꾸면 자동 저장
  Future<void> restoreAndWatch() async {
    try {
      final m = _readAll()[key];
      if (m is Map) {
        final r = Rect.fromLTWH((m['x'] as num).toDouble(), (m['y'] as num).toDouble(),
            (m['w'] as num).toDouble(), (m['h'] as num).toDouble());
        // 모니터를 뺐거나 해상도가 바뀌어 화면 밖이면 옮기지 않는다
        if (r.width >= 400 && r.height >= 300 && await _visible(r)) {
          await windowManager.setBounds(r);
          if (m['max'] == true) await windowManager.maximize();
        }
      }
    } catch (_) {}
    windowManager.addListener(this);
  }

  static Future<bool> _visible(Rect r) async {
    for (final d in await screenRetriever.getAllDisplays()) {
      final area = (d.visiblePosition ?? Offset.zero) & (d.visibleSize ?? d.size);
      final hit = area.intersect(r);
      if (hit.width >= 200 && hit.height >= 100) return true;
    }
    return false;
  }

  Future<void> save() async {
    try {
      if (paused?.call() ?? false) return;
      if (await windowManager.isFullScreen() || await windowManager.isMinimized()) return;
      if (!await windowManager.isVisible()) return;
      final max = await windowManager.isMaximized();
      final all = _readAll();
      final old = all[key];
      if (max && old is Map) {
        // 최대화: 보통 크기는 그대로 두고 표시만
        all[key] = {...old, 'max': true};
      } else {
        final b = await windowManager.getBounds();
        all[key] = {'x': b.left, 'y': b.top, 'w': b.width, 'h': b.height, 'max': max};
      }
      final tmp = File('$file.$pid.tmp')..writeAsStringSync(jsonEncode(all), flush: true);
      tmp.renameSync(file);
    } catch (_) {}
  }

  void _later() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 500), save);
  }

  @override
  void onWindowMoved() => _later();
  @override
  void onWindowResized() => _later();
  @override
  void onWindowMaximize() => _later();
  @override
  void onWindowUnmaximize() => _later();
}
