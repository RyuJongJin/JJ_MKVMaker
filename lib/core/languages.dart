import '../l10n/tr.dart';

/// 언어 코드 표.
///
/// - 파일명에는 ISO 639-1 (ko, en, ja) 사용  → 파일명_ko.srt
/// - MKV 트랙 태그에는 ISO 639-2/B (kor, eng, jpn) 사용 → 플레이어 언어 인식용
/// - 번역기(NLLB-200)는 자체 코드(kor_Hang 등) 사용 → 번역 단계에서 사용
class Language {
  final String code; // ISO 639-1 (파일명)
  final String mkv; // ISO 639-2/B (MKV 태그)
  final String nllb; // NLLB-200 코드
  final String koName; // 한국어 표시명 (번역 사전의 열쇠)
  final List<String> aliases; // 파일명에서 인식할 추가 표기 (번역하지 않음)

  const Language(this.code, this.mkv, this.nllb, this.koName,
      [this.aliases = const []]);

  /// 화면에 보일 이름 (화면 언어로)
  String get name => tr(koName);
}

const undetermined = Language('und', 'und', '', '미지정');

/// 기본 번역 언어 (확정 사항 1)
const defaultTargetLanguages = ['ko', 'en', 'ja'];

const languages = <Language>[
  Language('ko', 'kor', 'kor_Hang', '한국어', ['kr', 'korean', '한국어', '한글']),
  Language('en', 'eng', 'eng_Latn', '영어', ['english', '영어']),
  Language('ja', 'jpn', 'jpn_Jpan', '일본어', ['jp', 'japanese', '일본어']),
  Language('zh-Hans', 'chi', 'zho_Hans', '중국어 간체',
      ['zh', 'zho', 'cn', 'chs', 'sc', 'chinese', 'zh-cn', '중국어']),
  Language('zh-Hant', 'chi', 'zho_Hant', '중국어 번체', ['cht', 'tc', 'zh-tw']),
  Language('es', 'spa', 'spa_Latn', '스페인어', ['spanish']),
  Language('fr', 'fre', 'fra_Latn', '프랑스어', ['fra', 'french']),
  Language('de', 'ger', 'deu_Latn', '독일어', ['deu', 'german']),
  Language('ru', 'rus', 'rus_Cyrl', '러시아어', ['russian']),
  Language('pt', 'por', 'por_Latn', '포르투갈어', ['portuguese']),
  Language('it', 'ita', 'ita_Latn', '이탈리아어', ['italian']),
  Language('vi', 'vie', 'vie_Latn', '베트남어', ['vietnamese']),
  Language('th', 'tha', 'tha_Thai', '태국어', ['thai']),
  Language('id', 'ind', 'ind_Latn', '인도네시아어', ['indonesian']),
  Language('ms', 'may', 'zsm_Latn', '말레이어', ['msa', 'malay']),
  Language('tl', 'tgl', 'tgl_Latn', '타갈로그어', ['fil', 'filipino']),
  Language('ar', 'ara', 'arb_Arab', '아랍어', ['arabic']),
  Language('hi', 'hin', 'hin_Deva', '힌디어', ['hindi']),
  Language('tr', 'tur', 'tur_Latn', '터키어', ['turkish']),
  Language('pl', 'pol', 'pol_Latn', '폴란드어', ['polish']),
  Language('nl', 'dut', 'nld_Latn', '네덜란드어', ['nld', 'dutch']),
  Language('uk', 'ukr', 'ukr_Cyrl', '우크라이나어', ['ukrainian']),
  Language('sv', 'swe', 'swe_Latn', '스웨덴어', ['swedish']),
  Language('cs', 'cze', 'ces_Latn', '체코어', ['ces', 'czech']),
  Language('el', 'gre', 'ell_Grek', '그리스어', ['ell', 'greek']),
  Language('he', 'heb', 'heb_Hebr', '히브리어', ['hebrew']),
  Language('fi', 'fin', 'fin_Latn', '핀란드어', ['finnish']),
  Language('da', 'dan', 'dan_Latn', '덴마크어', ['danish']),
  Language('no', 'nor', 'nob_Latn', '노르웨이어', ['nob', 'norwegian']),
  Language('hu', 'hun', 'hun_Latn', '헝가리어', ['hungarian']),
  Language('ro', 'rum', 'ron_Latn', '루마니아어', ['ron', 'romanian']),
  Language('fa', 'per', 'pes_Arab', '페르시아어', ['fas', 'persian']),
  Language('bn', 'ben', 'ben_Beng', '벵골어', ['bengali']),
  Language('ur', 'urd', 'urd_Arab', '우르두어', ['urdu']),
  Language('ta', 'tam', 'tam_Taml', '타밀어', ['tamil']),
  Language('ne', 'nep', 'npi_Deva', '네팔어', ['npi', 'nepali']),
  Language('mn', 'mon', 'khk_Cyrl', '몽골어', ['mongolian']),
  Language('km', 'khm', 'khm_Khmr', '크메르어', ['khmer']),
  Language('lo', 'lao', 'lao_Laoo', '라오어', ['lao']),
  Language('my', 'bur', 'mya_Mymr', '미얀마어', ['mya', 'burmese']),
];

/// 파일명 코드(ko) 또는 MKV 코드(kor) 또는 별칭으로 언어 찾기.
Language languageOf(String? token) {
  if (token == null || token.isEmpty) return undetermined;
  final t = token.toLowerCase();
  for (final l in languages) {
    if (l.code.toLowerCase() == t || l.mkv == t || l.aliases.contains(t)) {
      return l;
    }
  }
  // MKV 태그의 639-2/T 표기 (zho, deu 등)는 별칭에 포함되어 있음
  return undetermined;
}
