import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;

import '../../core/app_update.dart';
import '../../services/storage_service.dart';
import '../../services/updater.dart';
import '../../l10n/tr.dart';

/// GitHub Release 로 업데이트 (Android)
///
/// 1. releases/latest 조회 (APK 파일) → 2. APK 받기 · SHA256 확인
/// 3. Android 설치 화면을 연다 (MainActivity.kt "installApk"). 설치는 사용자가 [설치] 를 눌러야 한다.
///    같은 서명 키로 만든 APK 라 설정 · 받은 파일 · AI 모델은 그대로 남는다.
class AndroidUpdater implements Updater {
  static const _ch = MethodChannel('jj_mkvmaker/android');

  final String apiBase;
  final StorageService storage;
  final HttpClient _http = HttpClient()
    ..userAgent = 'JJ_MKVMaker-updater'
    ..connectionTimeout = const Duration(seconds: 20);

  AndroidUpdater(this.storage, {this.apiBase = 'https://api.github.com'});

  /// 앱을 끝내지 않고 Android 설치 화면이 이어서 설치한다
  @override
  bool get installsInPlace => true;

  /// 시험용: --dart-define=JJ_VERSION_OVERRIDE=2026.10.02_001 로 빌드하면 그 버전인 척한다 (업데이트 과정 점검)
  static const _override = String.fromEnvironment('JJ_VERSION_OVERRIDE');

  @override
  Future<String> currentVersion() async {
    if (_override.isNotEmpty) return _override;
    final info = await PackageInfo.fromPlatform();
    return formatVersion('${info.version}+${info.buildNumber}');
  }

  @override
  Future<ReleaseInfo?> latest() async {
    final req = await _http.getUrl(Uri.parse('$apiBase/repos/$updateRepo/releases/latest'));
    req.headers.set('Accept', 'application/vnd.github+json');
    final res = await req.close();
    final body = await res.transform(utf8.decoder).join();
    if (res.statusCode == 404) return null;
    if (res.statusCode != 200) {
      throw UpdateException(trf('최신 버전을 확인할 수 없습니다 ({0})', [res.statusCode]));
    }
    return parseLatestRelease(jsonDecode(body) as Map<String, dynamic>, assetPattern: androidAssetPattern);
  }

  @override
  Future<List<ReleaseInfo>> releases() async {
    final req = await _http.getUrl(Uri.parse('$apiBase/repos/$updateRepo/releases?per_page=100'));
    req.headers.set('Accept', 'application/vnd.github+json');
    final res = await req.close();
    final body = await res.transform(utf8.decoder).join();
    if (res.statusCode != 200) {
      throw UpdateException(trf('버전 목록을 읽을 수 없습니다 ({0})', [res.statusCode]));
    }
    return parseReleaseList(jsonDecode(body) as List<dynamic>, assetPattern: androidAssetPattern);
  }

  @override
  Future<bool> canInstall() async => true;

  @override
  Future<String> download(ReleaseInfo r, void Function(double progress) onProgress) async {
    final url = r.zipUrl;
    if (url == null) throw UpdateException(tr('이 버전에는 Android 용 APK 가 없습니다.'));
    final apk = File(p.join(await storage.tempDirectory(), r.zipName ?? 'update.apk'));
    final req = await _http.getUrl(Uri.parse(url));
    final res = await req.close();
    if (res.statusCode != 200) throw UpdateException(trf('내려받기 실패 ({0})', [res.statusCode]));
    final total = res.contentLength > 0 ? res.contentLength : r.zipSize;
    final sink = apk.openWrite();
    var got = 0;
    try {
      await for (final chunk in res) {
        sink.add(chunk);
        got += chunk.length;
        if (total > 0) onProgress((got / total).clamp(0.0, 0.99));
      }
    } finally {
      await sink.close();
    }
    // 검증: GitHub 가 알려 준 SHA256 과 비교
    if (r.sha256 != null) {
      final hash = (await sha256.bind(apk.openRead()).first).toString();
      if (hash != r.sha256) {
        await apk.delete();
        throw UpdateException(tr('받은 파일이 손상되었거나 다른 파일입니다 (SHA256 불일치). 설치를 중단했습니다.'));
      }
    }
    onProgress(1);
    return apk.path;
  }

  /// Android 설치 화면 열기 ([downloaded] 는 APK 파일 경로)
  @override
  Future<void> scheduleInstall(String downloaded) async {
    try {
      await _ch.invokeMethod<void>('installApk', {'path': downloaded});
    } on PlatformException catch (e) {
      if (e.code == 'PERMISSION') throw InstallPermissionNeeded(e.message ?? '$e');
      throw UpdateException(e.message ?? '$e');
    }
  }

  @override
  Future<void> uninstallSelf() => _ch.invokeMethod<void>('uninstallSelf');

  @override
  Future<void> openPage(ReleaseInfo r) async {
    try {
      await _ch.invokeMethod<bool>('openUrl', {'url': r.pageUrl});
    } catch (_) {}
  }
}
