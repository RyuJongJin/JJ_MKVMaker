// l10n-skip-file: 음성인식 결과를 고르는 자료 (말버릇 · 맞장구 목록) 라 번역하지 않는다
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

/// 자주 나오는 짧은 말 (맞장구 · 감탄) 의 번역: 원어 → (정리한 말 → 대상 언어 → 번역).
/// 번역 모델은 짧은 말을 엉뚱하게 옮기는 일이 많아서 (はい → "I know.", はーい → "What?") 이 표를 먼저 쓴다.
const _fillers = <String, Map<String, Map<String, String>>>{
  'ja': {
    'はい': {'en': 'Yes.', 'ko': '네.'},
    'はーい': {'en': 'Okay!', 'ko': '네~'},
    'はいはい': {'en': 'Yes, yes.', 'ko': '네, 네.'},
    'うん': {'en': 'Yeah.', 'ko': '응.'},
    'うんうん': {'en': 'Yeah, yeah.', 'ko': '응응.'},
    'ええ': {'en': 'Yes.', 'ko': '네.'},
    'えー': {'en': 'Um...', 'ko': '음...'},
    'えっと': {'en': 'Um...', 'ko': '음...'},
    'えーと': {'en': 'Um...', 'ko': '음...'},
    'あー': {'en': 'Ah...', 'ko': '아...'},
    'あ': {'en': 'Oh.', 'ko': '아.'},
    'あっ': {'en': 'Oh!', 'ko': '앗.'},
    'うーん': {'en': 'Hmm...', 'ko': '음...'},
    'そう': {'en': 'Right.', 'ko': '맞아.'},
    'そうそう': {'en': 'Right, right.', 'ko': '맞아 맞아.'},
    'そうそうそう': {'en': 'Right, right.', 'ko': '맞아 맞아.'},
    'そうですね': {'en': "That's right.", 'ko': '그렇네요.'},
    'そうなんです': {'en': "That's right.", 'ko': '그렇거든요.'},
    'そうなんだ': {'en': 'I see.', 'ko': '그렇구나.'},
    'なるほど': {'en': 'I see.', 'ko': '그렇구나.'},
    'ね': {'en': 'Right?', 'ko': '그치?'},
    'ねえ': {'en': 'Hey.', 'ko': '있잖아.'},
    'へえ': {'en': 'Huh.', 'ko': '오~'},
    'へー': {'en': 'Huh.', 'ko': '오~'},
    'ほんとに': {'en': 'Really?', 'ko': '정말?'},
    'ありがとうございます': {'en': 'Thank you.', 'ko': '감사합니다.'},
    'ありがとう': {'en': 'Thanks.', 'ko': '고마워.'},
    'さようなら': {'en': 'Goodbye.', 'ko': '안녕히 계세요.'},
    'バイバイ': {'en': 'Bye-bye.', 'ko': '바이바이.'},
    'おはようございます': {'en': 'Good morning.', 'ko': '안녕하세요.'},
    'こんにちは': {'en': 'Hello.', 'ko': '안녕하세요.'},
  },
  'ko': {
    '네': {'en': 'Yes.', 'ja': 'はい。'},
    '예': {'en': 'Yes.', 'ja': 'はい。'},
    '응': {'en': 'Yeah.', 'ja': 'うん。'},
    '음': {'en': 'Hmm.', 'ja': 'うーん。'},
    '어': {'en': 'Uh.', 'ja': 'あ。'},
    '아': {'en': 'Oh.', 'ja': 'あ。'},
    '그래': {'en': 'Okay.', 'ja': 'そう。'},
    '맞아': {'en': 'Right.', 'ja': 'そうそう。'},
    '감사합니다': {'en': 'Thank you.', 'ja': 'ありがとうございます。'},
    '안녕하세요': {'en': 'Hello.', 'ja': 'こんにちは。'},
  },
  'en': {
    'yes': {'ko': '네.', 'ja': 'はい。'},
    'yeah': {'ko': '응.', 'ja': 'うん。'},
    'okay': {'ko': '좋아.', 'ja': 'オーケー。'},
    'ok': {'ko': '좋아.', 'ja': 'オーケー。'},
    'um': {'ko': '음...', 'ja': 'えーと。'},
    'uh': {'ko': '어...', 'ja': 'えー。'},
    'oh': {'ko': '아.', 'ja': 'あ。'},
    'right': {'ko': '맞아.', 'ja': 'そうそう。'},
    'thank you': {'ko': '감사합니다.', 'ja': 'ありがとうございます。'},
  },
};

/// 짧은 말 표에 있으면 그 번역 ([src] · [tgt] 는 언어 코드 ja · ko · en). 없으면 null.
String? fillerTranslation(String text, String src, String tgt) {
  final table = _fillers[src];
  if (table == null) return null;
  var key = text
      .toLowerCase()
      .replaceAll(RegExp(r'[\s\p{P}~〜!！?？]', unicode: true), ' ')
      .trim()
      .replaceAll(RegExp(r' +'), src == 'en' ? ' ' : '')
      .replaceAll(RegExp(r'ー+'), 'ー');
  return table[key]?[tgt];
}

/// 여러 줄 번역: 짧은 말 표에 있는 줄은 표의 번역을 쓰고, 나머지만 [translate] (번역 모델) 에 넘긴다.
Future<List<String>> translateKeepingFillers(
  List<String> lines,
  Future<List<String>> Function(List<String> rest) translate, {
  required String src,
  required String tgt,
}) async {
  final out = List<String?>.filled(lines.length, null);
  final rest = <int>[];
  for (var i = 0; i < lines.length; i++) {
    final f = fillerTranslation(lines[i], src, tgt);
    if (f != null) {
      out[i] = f;
    } else {
      rest.add(i);
    }
  }
  if (rest.isNotEmpty) {
    final got = await translate([for (final i in rest) lines[i]]);
    for (var k = 0; k < rest.length && k < got.length; k++) {
      out[rest[k]] = got[k];
    }
  }
  return [for (var i = 0; i < lines.length; i++) out[i] ?? lines[i]];
}

/// 음성인식 구간 → 자막 줄 정리
/// - 빈 줄, "[BLANK_AUDIO]" · "(음악)" 같은 비음성 표시 제거
/// - 말이 없는 곳 (끝 음악 등) 에서 음성인식이 지어낸 같은 말 되풀이 정리:
///   같은 줄이 [repeatRun] 번 넘게 이어지면 첫 줄만 남기고, 아주 짧은 말 ("ん" · "う" 등) 이면 모두 뺀다
/// - 긴 줄은 두 줄로 나눔 (한 줄 약 [maxLine] 글자)
List<Cue> cleanRecognized(List<Cue> raw, {int maxLine = 42, int repeatRun = 3}) {
  final kept = <Cue>[];
  for (final c in raw) {
    final t = c.text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (t.isEmpty || _nonSpeech.hasMatch(t)) continue;
    if (c.end <= c.start) continue;
    kept.add(Cue(c.start, c.end, t));
  }
  final out = <Cue>[];
  for (var i = 0; i < kept.length;) {
    var j = i + 1;
    while (j < kept.length && kept[j].text == kept[i].text) {
      j++;
    }
    final run = j - i;
    if (run > repeatRun) {
      // 되풀이: 짧은 소리 ("ん" 등) 면 모두 빼고, 아니면 첫 줄만
      final core = kept[i].text.replaceAll(RegExp(r'[\s\p{P}]', unicode: true), '');
      if (core.length > 2) out.add(Cue(kept[i].start, kept[i].end, _wrap(kept[i].text, maxLine)));
    } else {
      for (var k = i; k < j; k++) {
        out.add(Cue(kept[k].start, kept[k].end, _wrap(kept[k].text, maxLine)));
      }
    }
    i = j;
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
