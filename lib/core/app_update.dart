/// GitHub 저장소 (업데이트 확인)
const updateRepo = 'RyuJongJin/JJ_MKVMaker';

/// 버전 글 → 숫자 목록. 버전은 "년.월.일_순번" (예: 2026.09.30_001) 이고,
/// 같은 날 다시 내면 순번이 늘고 날이 바뀌면 001 부터 다시 시작한다.
///   "v2026.09.30_001" · "2026.9.30+1" → [2026, 9, 30, 1]
///   예전 방식 "v1.2.3" → [1, 2, 3]  (년도가 훨씬 크므로 새 방식이 항상 더 최신)
List<int> parseVersion(String v) {
  final core = v.trim().replaceFirst(RegExp(r'^[vV]'), '').split(RegExp(r'[\-\s]')).first;
  return [for (final part in core.split(RegExp(r'[._+]'))) int.tryParse(part) ?? 0];
}

/// 화면 · 태그에 쓰는 글: [2026, 9, 30, 1] → "2026.09.30_001", 예전 방식은 "1.2.3"
String formatVersion(String v) {
  final n = parseVersion(v);
  if (n.length < 3 || n[0] < 2000) return n.join('.');
  String two(int x) => x.toString().padLeft(2, '0');
  // Android 는 빌드 번호 자리에 날짜를 붙인 versionCode (261002001) 가 온다 → 끝 세 자리가 순번
  final seq = n.length > 3 ? n[3] % 1000 : 1;
  return '${n[0]}.${two(n[1])}.${two(n[2])}_${seq.toString().padLeft(3, '0')}';
}

/// a < b 면 음수, 같으면 0, a > b 면 양수
int compareVersions(String a, String b) {
  final x = parseVersion(a), y = parseVersion(b);
  for (var i = 0; i < x.length || i < y.length; i++) {
    final d = (i < x.length ? x[i] : 0) - (i < y.length ? y[i] : 0);
    if (d != 0) return d;
  }
  return 0;
}

/// GitHub Release 정보
class ReleaseInfo {
  final String version; // 2026.09.30_001
  final String tag; // v2026.09.30_001
  final String name;
  final String notes;
  final String pageUrl;

  /// Windows zip (없으면 null → 페이지만 안내)
  final String? zipUrl;
  final String? zipName;
  final int zipSize;

  /// GitHub 가 계산한 zip 의 SHA256 (소문자 16진수). 없으면 null
  final String? sha256;

  const ReleaseInfo({
    required this.version,
    required this.tag,
    required this.name,
    required this.notes,
    required this.pageUrl,
    this.zipUrl,
    this.zipName,
    this.zipSize = 0,
    this.sha256,
  });

  bool isNewerThan(String current) => compareVersions(version, current) > 0;
}

/// GitHub API `releases/latest` 응답 → ReleaseInfo (초안 · 시험판은 null)
ReleaseInfo? parseLatestRelease(Map<String, dynamic> j) {
  if (j['draft'] == true || j['prerelease'] == true) return null;
  final tag = j['tag_name'] as String?;
  if (tag == null) return null;
  Map<String, dynamic>? zip;
  for (final a in (j['assets'] as List? ?? const [])) {
    final m = a as Map<String, dynamic>;
    if (RegExp(r'win64\.zip$', caseSensitive: false).hasMatch(m['name'] as String? ?? '')) {
      zip = m;
      break;
    }
  }
  String? sha = (zip?['digest'] as String?)?.toLowerCase();
  if (sha != null && sha.startsWith('sha256:')) {
    sha = sha.substring(7);
  } else {
    // digest 가 없으면 설명에 적어 둔 SHA256 (64자리 16진수) 사용
    sha = RegExp(r'\b([0-9a-fA-F]{64})\b').firstMatch(j['body'] as String? ?? '')?.group(1)?.toLowerCase();
  }
  return ReleaseInfo(
    version: formatVersion(tag),
    tag: tag,
    name: j['name'] as String? ?? tag,
    notes: j['body'] as String? ?? '',
    pageUrl: j['html_url'] as String? ?? 'https://github.com/$updateRepo/releases',
    zipUrl: zip?['browser_download_url'] as String?,
    zipName: zip?['name'] as String?,
    zipSize: (zip?['size'] as num?)?.toInt() ?? 0,
    sha256: sha,
  );
}

/// 자동 확인은 하루에 한 번
bool updateCheckDue(String lastCheckIso, DateTime now) {
  final last = DateTime.tryParse(lastCheckIso);
  return last == null || now.difference(last) >= const Duration(hours: 20);
}
