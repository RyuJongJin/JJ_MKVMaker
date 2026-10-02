import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../core/subtitle_detector.dart';
import '../../ui/android_file_browser.dart';
import '../windows/desktop_storage_service.dart';

/// Android 저장소 전체 접근 (MainActivity.kt 의 "jj_mkvmaker/android")
class AndroidAccess {
  static const _ch = MethodChannel('jj_mkvmaker/android');

  static Future<bool> hasAllFiles() async {
    try {
      return await _ch.invokeMethod<bool>('hasAllFilesAccess') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 설정 화면 (모든 파일 접근 허용) 을 연다
  static Future<void> request() async {
    try {
      await _ch.invokeMethod<void>('requestAllFilesAccess');
    } catch (_) {}
  }

  /// 내장 저장소 맨 위 (예: /storage/emulated/0)
  static Future<String> storageRoot() async {
    try {
      return await _ch.invokeMethod<String>('storageRoot') ?? '/storage/emulated/0';
    } catch (_) {
      return '/storage/emulated/0';
    }
  }
}

/// Android: 실제 파일 경로가 필요하다 (MKV 를 동영상 옆 jj_mkv 폴더에 만든다).
/// 시스템 파일 선택기는 사본을 앱 캐시에 만들어 큰 동영상에 맞지 않으므로 앱 안 파일 고르기 화면을 쓴다.
class AndroidStorageService extends DesktopStorageService {
  /// 파일 고르기 화면을 띄울 곳 (main 에서 정함)
  static GlobalKey<NavigatorState>? navigatorKey;

  Future<List<String>> _pick(String title, List<String> extensions, {String? initialDirectory}) async {
    final ctx = navigatorKey?.currentContext;
    if (ctx == null) return [];
    return await showAndroidFileBrowser(ctx, title: title, extensions: extensions, initialDirectory: initialDirectory) ??
        const [];
  }

  @override
  Future<List<String>> pickVideos() => _pick('동영상 선택', videoExtensions);

  @override
  Future<List<String>> pickSubtitles({String? initialDirectory}) =>
      _pick('자막 파일 선택', subtitleExtensions, initialDirectory: initialDirectory);

  /// 임시 폴더: 캐시 폴더가 아니라 앱 데이터 폴더 아래 tmp.
  /// 저장 공간이 모자라면 Android 가 캐시 폴더를 마음대로 비워, 쓰는 중인 임시 파일 (AI 음성 · 자막 사본) 이
  /// 사라질 수 있다. 대신 앱을 켤 때 (처음 쓸 때) 지난 실행의 임시 파일을 지운다.
  static Future<String>? _tmp;

  @override
  Future<String> tempDirectory() => _tmp ??= () async {
        final dir = Directory(p.join((await getApplicationSupportDirectory()).path, 'tmp'));
        if (await dir.exists()) {
          try {
            await dir.delete(recursive: true);
          } catch (_) {}
        }
        await dir.create(recursive: true);
        return dir.path;
      }();
}
