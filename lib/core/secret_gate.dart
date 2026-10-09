/// 124: 저장된 비밀번호 (WebDAV · OpenSubtitles · API 키) 를 쓰기 전에 지나는 문.
/// 마스터 비밀번호를 정해 두었으면 앱이 [check] 에 "필요하면 묻기" 를 넣는다 (main). 없으면 늘 통과.
class SecretGate {
  /// [force]: 사용자가 직접 연 것 (마스터 창을 한 번 취소했어도 다시 묻는다). 아니면 자동 · 배경 작업
  static Future<bool> Function(bool force)? check;

  /// 써도 되면 true
  static Future<bool> pass({bool force = false}) => check?.call(force) ?? Future.value(true);
}

/// 마스터 비밀번호를 넣지 않아 막혔을 때의 안내
const secretGateMessage = '마스터 비밀번호를 넣어야 저장된 비밀번호를 쓸 수 있습니다';
