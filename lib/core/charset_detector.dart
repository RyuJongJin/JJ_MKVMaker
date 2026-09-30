import 'dart:convert';
import 'dart:typed_data';

/// 지원 문자셋 (확정 사항 4). 값은 FFmpeg/iconv 이름.
const supportedCharsets = <String, String>{
  'UTF-8': 'UTF-8',
  'UTF-16LE': 'UTF-16 LE',
  'UTF-16BE': 'UTF-16 BE',
  'CP949': 'CP949 (EUC-KR)',
  'SHIFT_JIS': 'Shift-JIS',
  'GBK': 'GB2312 (GBK)',
};

/// 텍스트 자막 바이트의 문자셋 추정.
///
/// BOM → UTF-8 유효성 → 동아시아 2바이트 인코딩 순으로 판단한다.
/// 정확하지 않을 수 있으므로 화면에서 사용자가 바꿀 수 있다.
String detectCharset(Uint8List bytes) {
  if (bytes.length >= 3 &&
      bytes[0] == 0xEF &&
      bytes[1] == 0xBB &&
      bytes[2] == 0xBF) {
    return 'UTF-8';
  }
  if (bytes.length >= 2) {
    if (bytes[0] == 0xFF && bytes[1] == 0xFE) return 'UTF-16LE';
    if (bytes[0] == 0xFE && bytes[1] == 0xFF) return 'UTF-16BE';
  }
  if (_isUtf8(bytes)) return 'UTF-8';

  // 2바이트 인코딩 점수 비교
  var hangul = 0; // CP949 완성형 한글: B0-C8 / A1-FE
  var kana = 0; // Shift-JIS 히라가나·가타카나: 82 9F-F1, 83 40-96
  var hanzi = 0; // GBK 한자 영역: B0-F7 / A1-FE 중 한글 영역 밖
  for (var i = 0; i + 1 < bytes.length; i++) {
    final a = bytes[i], b = bytes[i + 1];
    if (a < 0x80) continue;
    if (a >= 0xB0 && a <= 0xC8 && b >= 0xA1 && b <= 0xFE) hangul++;
    if ((a == 0x82 && b >= 0x9F && b <= 0xF1) ||
        (a == 0x83 && b >= 0x40 && b <= 0x96)) {
      kana++;
    }
    if (a >= 0xC9 && a <= 0xF7 && b >= 0xA1 && b <= 0xFE) hanzi++;
    i++; // 2바이트 문자 건너뛰기
  }
  if (kana > hangul && kana > hanzi) return 'SHIFT_JIS';
  if (hanzi > hangul) return 'GBK';
  return 'CP949';
}

bool _isUtf8(Uint8List bytes) {
  // 파일 앞부분만 읽었으므로 끝에서 잘린 멀티바이트 문자 1개는 제외하고 검사
  var end = bytes.length;
  for (var i = bytes.length - 1; i >= 0 && i >= bytes.length - 3; i--) {
    final b = bytes[i];
    if (b & 0xC0 == 0x80) continue; // 이어지는 바이트
    final need = b >= 0xF0 ? 4 : b >= 0xE0 ? 3 : b >= 0xC0 ? 2 : 1;
    if (i + need > bytes.length) end = i;
    break;
  }
  try {
    utf8.decode(bytes.sublist(0, end));
    return true;
  } on FormatException {
    return false;
  }
}
