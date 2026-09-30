import 'languages.dart';
import 'srt.dart';

/// 음성인식에 쓰는 Whisper 언어 코드 (zh-Hans → zh)
String whisperCode(Language l) => l.code.split('-').first;

/// 영상 → 16kHz 모노 WAV (음성인식 입력)
List<String> buildExtractAudioArgs(String video, String wav) => [
      '-hide_banner', '-nostdin', '-y', '-i', video,
      '-map', '0:a:0', '-vn', '-ac', '1', '-ar', '16000', '-c:a', 'pcm_s16le',
      '-progress', 'pipe:1', '-nostats', wav,
    ];

/// 인식한 글자의 문자 체계로 원어 추정.
///
/// 한글 → 한국어, 가나 → 일본어, 한자만 → 중국어, 키릴 → 러시아어, 태국·아랍·힌디 문자,
/// 라틴 문자는 자주 쓰는 단어로 영어·스페인어·프랑스어·독일어·포르투갈어·이탈리아어·베트남어 구분.
Language detectLanguage(String text) {
  var hangul = 0, kana = 0, han = 0, cyr = 0, thai = 0, arab = 0, deva = 0, latin = 0;
  for (final r in text.runes) {
    if (r >= 0xAC00 && r <= 0xD7A3 || r >= 0x1100 && r <= 0x11FF || r >= 0x3130 && r <= 0x318F) {
      hangul++;
    } else if (r >= 0x3040 && r <= 0x30FF) {
      kana++;
    } else if (r >= 0x4E00 && r <= 0x9FFF) {
      han++;
    } else if (r >= 0x0400 && r <= 0x04FF) {
      cyr++;
    } else if (r >= 0x0E00 && r <= 0x0E7F) {
      thai++;
    } else if (r >= 0x0600 && r <= 0x06FF) {
      arab++;
    } else if (r >= 0x0900 && r <= 0x097F) {
      deva++;
    } else if (r >= 0x41 && r <= 0x5A || r >= 0x61 && r <= 0x7A || r >= 0xC0 && r <= 0x24F || r >= 0x1E00 && r <= 0x1EFF) {
      latin++;
    }
  }
  final total = hangul + kana + han + cyr + thai + arab + deva + latin;
  if (total == 0) return undetermined;
  if (hangul >= total * 0.3) return languageOf('ko');
  if (kana > 0 && kana + han >= total * 0.3) return languageOf('ja');
  if (han >= total * 0.3) return languageOf('zh-Hans');
  if (cyr >= total * 0.3) return languageOf('ru');
  if (thai >= total * 0.3) return languageOf('th');
  if (arab >= total * 0.3) return languageOf('ar');
  if (deva >= total * 0.3) return languageOf('hi');

  // 라틴 문자: 자주 쓰는 단어 점수
  const words = {
    'en': ['the', 'and', 'is', 'you', 'to', 'of', 'it', 'that', 'this', 'we', 'what', 'are'],
    'es': ['el', 'la', 'que', 'de', 'y', 'es', 'los', 'por', 'una', 'pero', 'qué', 'está'],
    'fr': ['le', 'la', 'les', 'et', 'est', 'je', 'vous', 'pas', 'une', 'que', 'c\'est', 'nous'],
    'de': ['der', 'die', 'das', 'und', 'ist', 'ich', 'nicht', 'sie', 'ein', 'zu', 'wir', 'es'],
    'pt': ['o', 'a', 'que', 'de', 'e', 'não', 'um', 'uma', 'você', 'é', 'para', 'isso'],
    'it': ['il', 'di', 'che', 'e', 'la', 'non', 'è', 'un', 'per', 'sono', 'io', 'questo'],
    'vi': ['và', 'là', 'của', 'không', 'có', 'tôi', 'một', 'được', 'này', 'những', 'người', 'với'],
  };
  final tokens = text.toLowerCase().split(RegExp(r"[^\p{L}']+", unicode: true));
  var best = 'en';
  var bestScore = 0;
  for (final e in words.entries) {
    final set = e.value.toSet();
    final score = tokens.where(set.contains).length;
    if (score > bestScore) {
      bestScore = score;
      best = e.key;
    }
  }
  return languageOf(best);
}

final _nonSpeech = RegExp(r'^\s*[\[\(（【♪*].*[\]\)）】♪*]\s*$');

/// 음성인식 구간 → 자막 줄 정리
/// - 빈 줄, "[BLANK_AUDIO]" · "(음악)" 같은 비음성 표시 제거
/// - 긴 줄은 두 줄로 나눔 (한 줄 약 [maxLine] 글자)
List<Cue> cleanRecognized(List<Cue> raw, {int maxLine = 42}) {
  final out = <Cue>[];
  for (final c in raw) {
    final t = c.text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (t.isEmpty || _nonSpeech.hasMatch(t)) continue;
    if (c.end <= c.start) continue;
    out.add(Cue(c.start, c.end, _wrap(t, maxLine)));
  }
  return out;
}

String _wrap(String t, int maxLine) {
  if (t.length <= maxLine) return t;
  // 가운데에 가장 가까운 공백에서 나눔 (공백이 없는 언어는 가운데)
  final mid = t.length ~/ 2;
  var cut = -1;
  for (var d = 0; d < mid; d++) {
    if (mid + d < t.length && t[mid + d] == ' ') {
      cut = mid + d;
      break;
    }
    if (mid - d > 0 && t[mid - d] == ' ') {
      cut = mid - d;
      break;
    }
  }
  if (cut < 0) return '${t.substring(0, mid)}\n${t.substring(mid)}';
  return '${t.substring(0, cut)}\n${t.substring(cut + 1)}';
}
