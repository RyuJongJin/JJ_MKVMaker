import 'dart:convert';
import 'dart:typed_data';
import '../l10n/tr.dart';

import 'package:charset/charset.dart' show ShiftJISCodec, gbk, shiftJis;
import 'package:cp949_codec/cp949_codec.dart' show cp949;

/// 저장할 때 고를 수 있는 문자셋 (읽기용 [supportedCharsets] + BOM 포함 UTF-8)
const saveCharsets = <String, String>{
  'UTF-8': 'UTF-8',
  'UTF-8-BOM': 'UTF-8 (BOM)',
  'UTF-16LE': 'UTF-16 LE',
  'UTF-16BE': 'UTF-16 BE',
  'CP949': 'CP949 (EUC-KR)',
  'SHIFT_JIS': 'Shift-JIS',
  'GBK': 'GB2312 (GBK)',
};

/// 바이트 → 문자열 (BOM 제거, 잘못된 바이트는 � 로)
String decodeText(List<int> bytes, String charset) {
  var b = bytes;
  if (b.length >= 3 && b[0] == 0xEF && b[1] == 0xBB && b[2] == 0xBF) {
    return utf8.decode(b.sublist(3), allowMalformed: true);
  }
  if (b.length >= 2 && b[0] == 0xFF && b[1] == 0xFE) return _utf16(b.sublist(2), little: true);
  if (b.length >= 2 && b[0] == 0xFE && b[1] == 0xFF) return _utf16(b.sublist(2), little: false);
  return switch (charset) {
    'UTF-16LE' => _utf16(b, little: true),
    'UTF-16BE' => _utf16(b, little: false),
    'CP949' => cp949.decode(b, allowInvalid: true),
    'SHIFT_JIS' => const ShiftJISCodec(allowMalformed: true).decode(b),
    'GBK' => gbk.decode(b, allowMalformed: true),
    _ => utf8.decode(b, allowMalformed: true),
  };
}

class EncodeResult {
  final Uint8List bytes;

  /// 이 문자셋으로 표현할 수 없어 깨진 글자 수
  final int lostChars;

  const EncodeResult(this.bytes, this.lostChars);
}

/// 문자열 → 바이트. 표현할 수 없는 글자는 '?' 로 바꾸고 개수를 알려 준다.
EncodeResult encodeText(String text, String charset) {
  switch (charset) {
    case 'UTF-8':
      return EncodeResult(Uint8List.fromList(utf8.encode(text)), 0);
    case 'UTF-8-BOM':
      return EncodeResult(Uint8List.fromList([0xEF, 0xBB, 0xBF, ...utf8.encode(text)]), 0);
    case 'UTF-16LE':
    case 'UTF-16BE':
      final little = charset == 'UTF-16LE';
      final out = BytesBuilder()..add(little ? [0xFF, 0xFE] : [0xFE, 0xFF]);
      for (final u in text.codeUnits) {
        out.add(little ? [u & 0xFF, u >> 8] : [u >> 8, u & 0xFF]);
      }
      return EncodeResult(out.toBytes(), 0);
  }

  final Encoding enc = switch (charset) {
    'CP949' => cp949,
    'SHIFT_JIS' => shiftJis,
    'GBK' => gbk,
    _ => throw ArgumentError(trf('지원하지 않는 문자셋: {0}', [charset])),
  };
  // 글자 단위로 인코딩해 표현 불가 글자를 찾는다 (자막은 크지 않으므로 충분히 빠름)
  final out = BytesBuilder();
  var lost = 0;
  for (final r in text.runes) {
    final ch = String.fromCharCode(r);
    if (r < 0x80) {
      out.addByte(r);
      continue;
    }
    List<int>? b;
    try {
      b = enc.encode(ch);
      if (b.isEmpty || enc.decode(b) != ch) b = null;
    } catch (_) {
      b = null;
    }
    if (b == null) {
      out.addByte(0x3F); // ?
      lost++;
    } else {
      out.add(b);
    }
  }
  return EncodeResult(out.toBytes(), lost);
}

String _utf16(List<int> b, {required bool little}) {
  final units = <int>[];
  for (var i = 0; i + 1 < b.length; i += 2) {
    units.add(little ? b[i] | (b[i + 1] << 8) : (b[i] << 8) | b[i + 1]);
  }
  return String.fromCharCodes(units);
}
