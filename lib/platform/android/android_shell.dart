import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../../services/app_shell.dart';

/// Android 화면 방향 적용: 'landscape' 가로 고정 / 'portrait' 세로 고정 / 그 밖 (자동 · 모르는 값) 은 기기 방향 따라 (환경 설정 > 화면)
Future<void> applyScreenOrientation(String mode) => SystemChrome.setPreferredOrientations(switch (mode) {
      'portrait' => [DeviceOrientation.portraitUp, DeviceOrientation.portraitDown],
      'landscape' => [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight],
      _ => const <DeviceOrientation>[], // 빈 목록 = 기기 · 시스템 설정을 따름
    });

/// Android: 창 · 트레이 · 단축키 · 탐색기 연결은 없음. 종료 · 전체 화면 · 웹 주소 열기 · 폴더 열기 (파일 앱).
class AndroidShell extends NoopShell {
  static const _ch = MethodChannel('jj_mkvmaker/android');
  bool _full = false;

  /// [종료]: 백그라운드로 살려 둔 엔진 · 작업 알림까지 끝낸다 (화면만 닫는 ← 와 다름)
  @override
  Future<void> quit() async {
    try {
      await _ch.invokeMethod<void>('exitApp');
    } catch (_) {
      await SystemNavigator.pop();
    }
  }

  @override
  Future<void> setFullScreen(bool on) async {
    _full = on;
    await SystemChrome.setEnabledSystemUIMode(on ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge);
  }

  @override
  Future<bool> isFullScreen() async => _full;

  /// 앱 목록 · 홈 화면 아이콘: 고른 아이콘의 activity-alias 만 켠다 (런처가 다시 그리는 데 몇 초 걸릴 수 있음)
  @override
  Future<void> setAppIcon(String id) async {
    try {
      await _ch.invokeMethod<bool>('setAppIcon', {'id': appIconOf(id)});
    } catch (_) {}
  }

  /// 기기의 기본 브라우저로 (고른 브라우저는 PC 에서만)
  @override
  Future<void> openUrl(String url, {String browser = 'system'}) async {
    try {
      await _ch.invokeMethod<bool>('openUrl', {'url': url});
    } catch (_) {}
  }

  /// 다른 앱으로 열기 (MainActivity "openWith"): [choose] 면 늘 앱 고르기 창, 아니면 기본 앱 (없으면 고르기 창)
  @override
  Future<bool> openWith(String path, {bool choose = false}) async {
    try {
      return await _ch.invokeMethod<bool>('openWith', {'path': path, 'choose': choose}) ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 환경 설정의 확장자별 재생 프로그램: Android 는 'system' (기본 앱) 만 있다
  @override
  Future<void> openExternal(String program, List<String> files) async {
    if (files.isNotEmpty) await openWith(files.first);
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
