import 'dart:io';

import '../core/secret_gate.dart';
import '../l10n/tr.dart';

/// 파일 · WebDAV 오류를 사람이 읽을 말로 (제목, 할 일). 원문 예외는 알아볼 수 없을 때만 그대로.
/// 파일 탐색기 · 폴더 고르기 · 그 밖에 WebDAV 를 읽는 화면이 함께 쓴다 (12 · 134).
/// 50: Android 가 막은 폴더 (Android/data · obb) 표시 (파일 탐색기가 오류 자리에 넣는다)
const androidRestrictedError = 'ANDROID_RESTRICTED_FOLDER';

/// 50: Android 11 부터 어떤 파일 앱도 다른 앱의 데이터 폴더 (Android/data · Android/obb) 를 볼 수 없다
bool isAndroidRestricted(String path, {bool? android}) =>
    (android ?? Platform.isAndroid) && RegExp(r'/Android/(data|obb)(/|$)', caseSensitive: false).hasMatch(path);

(String, String) explainFileError(String e, {required bool dav, bool noPassword = false}) {
if (e == androidRestrictedError) {
  return (
    tr('이 폴더는 Android 가 막아 볼 수 없습니다'),
    tr('Android 11 부터 다른 앱의 데이터 폴더 (Android/data · Android/obb) 는 어떤 파일 앱도 열 수 없습니다. '
        '그 앱 안의 내보내기 · 공유로 파일을 꺼내세요.'),
  );
}
// 128 · 133: 마스터 비밀번호를 기다리는 중 (고장이 아님)
if (isLockedError(e)) {
  return (tr('마스터 비밀번호가 필요합니다'), tr('이 서버의 저장된 비밀번호를 쓰려면 마스터 비밀번호를 넣으세요.'));
}
  final s = e.toLowerCase();
  if (dav && (s.contains('socketexception') || s.contains('connection refused') || s.contains('failed host lookup') ||
      s.contains('network is unreachable') || s.contains('no route') || s.contains('timed out') ||
      s.contains('timeoutexception') || s.contains('connection reset') || s.contains('connection closed'))) {
    return (
      tr('서버에 닿지 않습니다'),
      tr('서버와 같은 네트워크에 있거나 VPN (예: Tailscale) 이 켜져 있어야 합니다. 켠 뒤 [다시 시도] 를 누르세요.'),
    );
  }
  if (s.contains(' 401') || s.contains('status: 401') || s.contains('아이디 · 비밀번호')) {
    // 54: 비밀번호가 틀린 것이 아니라 저장된 것이 없다 (예전 판 설치 · 앱 다시 설치 등)
    if (noPassword) {
      return (
        tr('저장된 비밀번호가 없습니다. 한 번만 다시 넣어 주세요'),
        tr('[서버 설정 고치기] 에서 비밀번호를 넣으면 이 기기의 안전 저장소에 남아 다음부터는 다시 넣지 않아도 됩니다.'),
      );
    }
    return (tr('아이디 또는 비밀번호가 맞지 않습니다'), tr('[서버 설정 고치기] 에서 아이디 · 비밀번호를 확인하세요.'));
  }
  if (s.contains('handshake') || s.contains('certificate')) {
    return (
      tr('서버 인증서를 확인할 수 없습니다'),
      tr('집 NAS 처럼 자체 서명 인증서면 [서버 설정 고치기] 에서 "인증서 확인 안 함" 을 켜세요.'),
    );
  }
  if (s.contains(' 403') || s.contains('권한 없음')) return (tr('이 폴더를 볼 권한이 없습니다'), tr('서버에서 이 계정의 권한을 확인하세요.'));
  if (s.contains(' 404') || s.contains('없는 경로')) return (tr('폴더가 없습니다'), tr('다른 곳에서 지웠거나 옮겼을 수 있습니다. 위 폴더로 가 보세요.'));
  if (s.contains('permission denied') || s.contains('pathaccessexception') || s.contains('errno = 13')) {
    return (
      tr('이 폴더를 읽을 권한이 없습니다'),
      Platform.isAndroid ? tr('Android 가 막은 폴더 (Android/data 등) 이거나 "모든 파일에 대한 접근" 권한이 없습니다.') : '',
    );
  }
  return (tr('읽을 수 없습니다'), e);
}

/// 마스터 비밀번호를 넣지 않아 막힌 오류인지 (128 · 133)
bool isLockedError(Object e) {
  final s = '$e';
  return s.contains(secretGateMessage) || s.contains(tr(secretGateMessage));
}
