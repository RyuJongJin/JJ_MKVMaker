import 'dart:convert';

/// NLLB-200 토크나이저 (Hugging Face tokenizer.json 의 BPE + Metaspace 를 Dart 로 구현)
///
/// - 입력: `[원어 코드] 토큰들 </s>`
/// - 출력(디코더 시작): `</s> [대상 언어 코드]`
class NllbTokenizer {
  static const meta = '▁'; // ▁
  static const padId = 1, eosId = 2, unkId = 3;

  final Map<String, int> _vocab;
  final List<String> _idToToken;
  final Map<String, int> _mergeRank;
  final Map<String, int> _special; // 언어 코드 등
  final Map<String, List<int>> _cache = {};

  NllbTokenizer._(this._vocab, this._idToToken, this._mergeRank, this._special);

  /// tokenizer.json 내용으로 생성 (16MB 이므로 별도 isolate 에서 호출 권장)
  factory NllbTokenizer.fromJson(String jsonText) {
    final t = jsonDecode(jsonText) as Map<String, dynamic>;
    final model = t['model'] as Map<String, dynamic>;
    if (model['type'] != 'BPE') throw FormatException('BPE 토크나이저가 아닙니다: ${model['type']}');

    final vocab = <String, int>{};
    final rawVocab = model['vocab'];
    if (rawVocab is Map) {
      rawVocab.forEach((k, v) => vocab[k as String] = v as int);
    } else {
      for (final e in rawVocab as List) {
        vocab[e[0] as String] = e[1] as int;
      }
    }
    final special = <String, int>{};
    for (final a in (t['added_tokens'] as List)) {
      final m = a as Map<String, dynamic>;
      special[m['content'] as String] = m['id'] as int;
      vocab[m['content'] as String] = m['id'] as int;
    }
    var maxId = 0;
    for (final v in vocab.values) {
      if (v > maxId) maxId = v;
    }
    final idToToken = List<String>.filled(maxId + 1, '');
    vocab.forEach((k, v) => idToToken[v] = k);

    final ranks = <String, int>{};
    final merges = model['merges'] as List;
    for (var i = 0; i < merges.length; i++) {
      final m = merges[i];
      // "a b" 문자열 또는 ["a","b"] 배열 형식 모두 지원
      final key = m is String ? m : '${m[0]} ${m[1]}';
      ranks[key] = i;
    }
    return NllbTokenizer._(vocab, idToToken, ranks, special);
  }

  int get vocabSize => _idToToken.length;

  /// 언어 코드 토큰 번호 (예: kor_Hang)
  int langId(String nllbCode) {
    final id = _special[nllbCode];
    if (id == null) throw ArgumentError('NLLB 언어 코드가 아닙니다: $nllbCode');
    return id;
  }

  bool isSpecial(int id) => id < 4 || _special.containsValue(id) && id >= 256000;

  /// 문장 → 인코더 입력 번호 `[원어] ... </s>`
  List<int> encode(String text, String srcLang, {int maxTokens = 256}) {
    final ids = <int>[langId(srcLang)];
    for (final word in _preTokenize(_normalize(text))) {
      ids.addAll(_bpe(word));
      if (ids.length >= maxTokens - 1) break;
    }
    if (ids.length > maxTokens - 1) ids.length = maxTokens - 1;
    ids.add(eosId);
    return ids;
  }

  /// 번호 → 문장 (특수 토큰 제외)
  String decode(Iterable<int> ids) {
    final sb = StringBuffer();
    for (final id in ids) {
      if (id < 0 || id >= _idToToken.length) continue;
      if (id <= unkId || id >= 256001) continue; // 특수·언어 코드
      sb.write(_idToToken[id]);
    }
    return sb.toString().replaceAll(meta, ' ').trim();
  }

  /// 간단한 정규화: 제어 문자 제거, 공백 정리, 전각 영숫자·기호 → 반각
  static String _normalize(String s) {
    final out = StringBuffer();
    for (final r in s.runes) {
      if (r < 0x20 && r != 0x0A && r != 0x09) continue;
      if (r >= 0xFF01 && r <= 0xFF5E) {
        out.writeCharCode(r - 0xFEE0);
      } else if (r == 0x3000) {
        out.write(' ');
      } else {
        out.writeCharCode(r);
      }
    }
    return out.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  /// Metaspace: 공백을 ▁ 로 바꾸고 앞에 ▁ 를 붙인 뒤, ▁ 앞에서 나눔
  static List<String> _preTokenize(String s) {
    if (s.isEmpty) return const [];
    final replaced = meta + s.replaceAll(' ', meta);
    final words = <String>[];
    var start = 0;
    for (var i = 1; i < replaced.length; i++) {
      if (replaced[i] == meta) {
        words.add(replaced.substring(start, i));
        start = i;
      }
    }
    words.add(replaced.substring(start));
    return words;
  }

  List<int> _bpe(String word) {
    final cached = _cache[word];
    if (cached != null) return cached;

    // 유니코드 문자 단위로 시작
    var parts = [for (final r in word.runes) String.fromCharCode(r)];
    while (parts.length > 1) {
      var best = -1;
      var bestRank = 1 << 62;
      for (var i = 0; i < parts.length - 1; i++) {
        final r = _mergeRank['${parts[i]} ${parts[i + 1]}'];
        if (r != null && r < bestRank) {
          bestRank = r;
          best = i;
        }
      }
      if (best < 0) break;
      final a = parts[best], b = parts[best + 1];
      // 같은 쌍을 한 번에 모두 병합
      final merged = <String>[];
      for (var i = 0; i < parts.length; i++) {
        if (i < parts.length - 1 && parts[i] == a && parts[i + 1] == b) {
          merged.add(a + b);
          i++;
        } else {
          merged.add(parts[i]);
        }
      }
      parts = merged;
    }

    final ids = <int>[];
    var lastUnk = false;
    for (final t in parts) {
      final id = _vocab[t];
      if (id == null) {
        if (!lastUnk) ids.add(unkId); // fuse_unk
        lastUnk = true;
      } else {
        ids.add(id);
        lastUnk = false;
      }
    }
    if (_cache.length < 50000) _cache[word] = ids;
    return ids;
  }
}
