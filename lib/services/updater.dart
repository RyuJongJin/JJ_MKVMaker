import '../core/app_update.dart';

class UpdateException implements Exception {
  final String message;
  const UpdateException(this.message);
  @override
  String toString() => message;
}

/// Android: "이 출처의 앱 설치 허용" 이 꺼져 있어 설정 화면을 열었다. 켜고 돌아오면 받은 파일로 다시 설치하면 된다.
class InstallPermissionNeeded extends UpdateException {
  const InstallPermissionNeeded(super.message);
}

/// 새 버전 확인 · 설치 경계
/// Windows: platform/windows/github_updater.dart (zip 받아 파일 교체 후 다시 시작)
/// Android: (이식 시) 스토어 / APK 안내
abstract class Updater {
  /// 지금 실행 중인 버전 (예: 1.0.1)
  Future<String> currentVersion();

  /// GitHub 최신 Release (없거나 읽을 수 없으면 null)
  Future<ReleaseInfo?> latest();

  /// GitHub 에 올려 둔 모든 버전 (새 버전이 앞) - 예전 버전으로 되돌리기
  Future<List<ReleaseInfo>> releases();

  /// 프로그램 폴더에 쓸 수 있어 자동 설치가 가능한지 (아니면 페이지 안내)
  Future<bool> canInstall();

  /// zip 을 받아 SHA256 확인 후 압축을 푼 폴더 경로
  Future<String> download(ReleaseInfo r, void Function(double progress) onProgress);

  /// 앱이 끝나면 파일을 교체하고 새 버전을 실행하도록 예약 (호출 뒤 앱을 종료해야 함)
  Future<void> scheduleInstall(String extractedDir);

  /// 브라우저로 Release 페이지 열기
  Future<void> openPage(ReleaseInfo r);

  /// 이 앱을 지우는 확인 창 (Android: 예전 버전으로 되돌릴 때. Windows 는 하지 않음)
  Future<void> uninstallSelf();

  /// true 면 [scheduleInstall] 이 설치 화면을 열 뿐 앱을 끝낼 필요가 없다 (Android)
  bool get installsInPlace => false;
}
