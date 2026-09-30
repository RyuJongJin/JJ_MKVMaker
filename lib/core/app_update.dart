/// GitHub 저장소 (업데이트 확인)
const updateRepo = 'RyuJongJin/JJ_MKVMaker';

/// "v1.2.3" · "1.2.3+4" → [1, 2, 3] (숫자가 아닌 부분 무시)
List<int> parseVersion(String v) {
  final core = v.trim().replaceFirst(RegExp(r'^[vV]'), '').split(RegExp(r'[+\-\s]')).first;
  return [for (final part in core.split('.')) int.tryParse(part) ?? 0];
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
  final String version; // 1.0.1
  final String tag; // v1.0.1
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
    version: parseVersion(tag).join('.'),
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
