import '../l10n/tr.dart';
/// 다운로드 종류
enum DownloadKind {
  /// YouTube 등 동영상 사이트 → yt-dlp
  video,

  /// 마그넷 링크 · .torrent 주소 → aria2
  torrent,
}

class DetectedLink {
  final DownloadKind kind;
  final String url;
  const DetectedLink(this.kind, this.url);

  @override
  bool operator ==(Object other) => other is DetectedLink && other.url == url && other.kind == kind;
  @override
  int get hashCode => Object.hash(kind, url);
}

final _youtube = RegExp(
    r'https?://(?:www\.|m\.|music\.)?(?:youtube\.com/(?:watch\?[^\s]*v=|shorts/|live/|playlist\?[^\s]*list=|embed/)|youtu\.be/)[^\s<>"]+',
    caseSensitive: false);
final _magnet = RegExp(r'magnet:\?xt=urn:bt[im]h:[^\s<>"]+', caseSensitive: false);
final _torrentUrl = RegExp(r'https?://[^\s<>"]+\.torrent(?:\?[^\s<>"]*)?', caseSensitive: false);

/// 클립보드 글에서 다운로드할 주소 찾기 (중복 제거, 나온 순서대로)
List<DetectedLink> detectLinks(String text) {
  final found = <int, DetectedLink>{};
  for (final m in _youtube.allMatches(text)) {
    found[m.start] = DetectedLink(DownloadKind.video, _trimUrl(m[0]!));
  }
  for (final m in _magnet.allMatches(text)) {
    found[m.start] = DetectedLink(DownloadKind.torrent, m[0]!);
  }
  for (final m in _torrentUrl.allMatches(text)) {
    found[m.start] = DetectedLink(DownloadKind.torrent, _trimUrl(m[0]!));
  }
  final keys = found.keys.toList()..sort();
  final out = <DetectedLink>[];
  for (final k in keys) {
    if (!out.contains(found[k])) out.add(found[k]!);
  }
  return out;
}

/// 문장 끝의 괄호·마침표 등 제거
String _trimUrl(String u) => u.replaceFirst(RegExp(r'[).,;!?\]]+$'), '');

/// yt-dlp 진행 줄 (--progress-template "download:[JJ]%(progress._percent_str)s|...")
class YtDlpProgress {
  final double? percent;
  final String speed;
  final String eta;

  /// 지금 받는 파일(영상 또는 음성)의 받은 크기 · 전체 크기 (바이트, 모르면 null)
  final int? received;
  final int? total;
  const YtDlpProgress(this.percent, this.speed, this.eta, {this.received, this.total});
}

/// yt-dlp 는 영상과 음성을 따로 받은 뒤 합친다. 파일마다 0→100% 가 되므로
/// 그대로 보여 주면 "100% 가 됐다가 다시 처음부터" 처럼 보인다. 여러 파일을 하나의 진행으로 합친다.
class YtDlpTotals {
  /// 받기 전에 yt-dlp 가 알려 준 전체 크기 (영상 + 음성, 모르면 null)
  int? expected;
  int _base = 0, _cur = 0;
  int? _curTotal;
  double? _percent;

  /// 다음 파일을 받기 시작 (지금까지 받은 것은 끝난 것으로 더한다)
  void nextFile() {
    _base += _curTotal ?? _cur;
    _cur = 0;
    _curTotal = null;
    _percent = null;
  }

  void update(YtDlpProgress p) {
    if (p.received != null) _cur = p.received!;
    if (p.total != null) _curTotal = p.total;
    _percent = p.percent ?? _percent;
  }

  int get received => _base + _cur;

  /// 전체 크기: 미리 안 크기와 지금까지 본 크기 중 큰 쪽 (추정치가 작게 나오는 경우 대비)
  int? get total {
    final seen = _curTotal == null ? null : _base + _curTotal!;
    if (expected == null) return seen;
    return seen != null && seen > expected! ? seen : expected;
  }

  /// 전체 진행률. 크기를 전혀 모르면 yt-dlp 의 퍼센트를 그대로.
  double? get progress {
    final t = total;
    if (t == null || t <= 0) return _percent;
    return (received / t).clamp(0.0, 1.0);
  }
}

YtDlpProgress? parseYtDlpProgress(String line) {
  if (!line.startsWith('[JJ]')) return null;
  final parts = line.substring(4).split('|');
  final pct = double.tryParse(parts[0].replaceAll('%', '').trim());
  String part(int i) => i < parts.length ? parts[i].trim() : '';
  String clean(String s) => s == 'NA' || s == 'Unknown' || s.startsWith('Unknown') ? '' : s;
  // 크기는 "12345" 또는 "12345.0", 모르면 "NA"
  int? bytes(int i) => double.tryParse(part(i))?.round();
  return YtDlpProgress(pct == null ? null : pct / 100, clean(part(1)), clean(part(2)),
      received: bytes(3), total: bytes(4));
}

/// YouTube 재생목록 주소인지 (재생목록 ID 반환).
/// 믹스(RD…) · 좋아요(LL) · 나중에 볼 동영상(WL) 은 제외 (끝없는 목록 · 로그인 필요)
String? youtubePlaylistId(String url) {
  final m = RegExp(r'[?&]list=([\w-]+)').firstMatch(url);
  if (m == null) return null;
  final id = m[1]!;
  if (id.startsWith('RD') || id == 'LL' || id == 'WL') return null;
  return id;
}

/// 폴더 이름으로 쓸 수 없는 글자 제거
String safeFolderName(String s) {
  final t = s.replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
  final cut = t.length > 80 ? t.substring(0, 80).trim() : t;
  return cut.replaceAll(RegExp(r'[. ]+$'), '');
}

/// YouTube 받을 형식
enum YtContainer {
  mp4('MP4 (동영상)'),
  webm('WebM (동영상)'),
  mp3('음성만 MP3'),
  m4a('음성만 M4A');

  /// 한국어 원문 (번역 사전의 열쇠)
  final String koLabel;

  /// 화면에 보일 이름 (화면 언어로)
  String get label => tr(koLabel);
  const YtContainer(this.koLabel);

  bool get audioOnly => this == mp3 || this == m4a;
}

/// YouTube 화질 (세로 픽셀 이하 중 가장 좋은 것)
enum YtQuality {
  best('최고 화질', null),
  p2160('4K (2160p)', 2160),
  p1440('1440p', 1440),
  p1080('1080p', 1080),
  p720('720p', 720),
  p480('480p', 480),
  p360('360p', 360);

  /// 한국어 원문 (번역 사전의 열쇠)
  final String koLabel;

  /// 화면에 보일 이름 (화면 언어로)
  String get label => tr(koLabel);
  final int? height;
  const YtQuality(this.koLabel, this.height);
}

/// yt-dlp 형식 인수
///
/// [preferH264]: 같은 크기면 H.264 를 먼저 고른다 (Android: 휴대폰 · 태블릿은 AV1 · VP9 을 하드웨어로 못 푸는 일이 많아
/// 재생이 끊기고 배터리를 많이 씀). YouTube 의 H.264 는 1080p 까지라 그보다 큰 화질을 고르면 크기가 먼저다.
List<String> ytDlpFormatArgs(YtContainer c, YtQuality q, {bool preferH264 = false}) {
  final res = q.height == null ? '' : 'res:${q.height},';
  final codec = preferH264 ? 'vcodec:h264,' : '';
  return switch (c) {
    YtContainer.mp4 => ['-S', '$res${codec}ext:mp4:m4a', '--merge-output-format', 'mp4', '--remux-video', 'mp4'],
    YtContainer.webm => ['-S', '${res}ext:webm:webm', '--merge-output-format', 'webm'],
    YtContainer.mp3 => ['-f', 'ba/b', '-x', '--audio-format', 'mp3', '--audio-quality', '0'],
    YtContainer.m4a => ['-f', 'ba[ext=m4a]/ba/b', '-x', '--audio-format', 'm4a'],
  };
}

/// yt-dlp 에 넘기는 로그인 쿠키의 사이트 (YouTube · Google · Instagram · X · 네이버 / 치지직 - 28)
const loginCookieDomains = ['youtube.com', 'google.com', 'instagram.com', 'x.com', 'twitter.com', 'naver.com'];

/// [d] (".x.com" 등) 가 [loginCookieDomains] 중 하나이거나 그 아래인지 (netflix.com 이 x.com 으로 잡히지 않게)
bool isLoginCookieDomain(String d) {
  final h = (d.startsWith('.') ? d.substring(1) : d).toLowerCase();
  return loginCookieDomains.any((x) => h == x || h.endsWith('.$x'));
}

/// 앱 안 브라우저(내장 Edge) 의 쿠키를 쓰는 값
const internalBrowserCookies = '*internal';

/// yt-dlp 쿠키 인수 (YouTube 로그인 · 로봇 확인 대응). cookies.txt 가 있으면 우선.
/// 앱 안 브라우저: [internalCookieFile] (브라우저가 내보낸 cookies.txt) 만 쓴다.
/// 아직 없으면 (앱 안 브라우저를 쓴 적이 없음) 쿠키 없이 받는다 - 프로필 폴더를 직접 읽는 방식은
/// 브라우저가 켜져 있거나 암호화 방식이 달라 실패하는 일이 많아 쓰지 않는다.
List<String> ytDlpCookieArgs({
  String browser = '',
  String file = '',
  String internalProfile = '',
  String internalCookieFile = '',
}) {
  if (file.trim().isNotEmpty) return ['--cookies', file.trim()];
  if (browser == internalBrowserCookies) {
    return internalCookieFile.isEmpty ? const [] : ['--cookies', internalCookieFile];
  }
  if (browser.trim().isNotEmpty) return ['--cookies-from-browser', browser.trim()];
  return const [];
}

/// 쿠키 한 개 (브라우저 → yt-dlp 로 넘기기용)
class CookieRecord {
  final String name, value, domain, path;

  /// 만료 시각 (초, 0 = 세션 쿠키)
  final int expires;
  final bool secure, httpOnly;
  const CookieRecord({
    required this.name,
    required this.value,
    required this.domain,
    this.path = '/',
    this.expires = 0,
    this.secure = false,
    this.httpOnly = false,
  });
}

/// yt-dlp 가 읽는 Netscape 형식 cookies.txt
String toNetscapeCookies(Iterable<CookieRecord> cookies) {
  final sb = StringBuffer('# Netscape HTTP Cookie File\n# JJ_MKVMaker 앱 안 브라우저에서 내보냄\n\n');
  final seen = <String>{};
  for (final c in cookies) {
    if (c.name.isEmpty || c.domain.isEmpty) continue;
    if (!seen.add('${c.domain}|${c.path}|${c.name}')) continue;
    final sub = c.domain.startsWith('.');
    final value = c.value.replaceAll(RegExp(r'[\t\r\n]'), '');
    sb.writeln([
      '${c.httpOnly ? '#HttpOnly_' : ''}${c.domain}',
      sub ? 'TRUE' : 'FALSE',
      c.path.isEmpty ? '/' : c.path,
      c.secure ? 'TRUE' : 'FALSE',
      '${c.expires}',
      c.name,
      value,
    ].join('\t'));
  }
  return sb.toString();
}

/// yt-dlp 오류를 알기 쉬운 안내로
/// 쿠키를 읽지 못해 난 오류인지 (브라우저가 켜져 있음 · 암호 해독 실패 · 파일 없음 등).
/// 이런 오류는 쿠키 없이 다시 받으면 되는 경우가 많다.
bool isCookieReadError(String err) {
  final e = err.toLowerCase();
  return e.contains('cookie') &&
      (e.contains('could not find') ||
          e.contains('could not copy') ||
          e.contains('failed to decrypt') ||
          e.contains('permission denied') ||
          e.contains('database') ||
          e.contains('unsupported browser') ||
          e.contains('no such file'));
}

String friendlyYtDlpError(String err) {
  if (err.contains('Sign in to confirm') || err.contains('not a bot')) {
    return tr('YouTube 가 로봇 확인을 요구합니다. 환경 설정 > 다운로드 > YouTube 쿠키 에서 ' '브라우저(Firefox 권장) 또는 cookies.txt 를 지정한 뒤 다시 받으세요.');
  }
  if (err.contains('Private video') || err.contains('members-only')) return tr('비공개 · 회원 전용 영상입니다.');
  if (err.contains('Video unavailable')) return tr('볼 수 없는 영상입니다 (삭제 · 지역 제한).');
  if (isCookieReadError(err)) {
    return tr('브라우저 쿠키를 읽지 못했습니다. 환경 설정 > 다운로드 > YouTube 쿠키 에서 "앱 안 브라우저" 를 고르거나, ' '고른 브라우저가 설치되어 있는지 확인하세요 (Chrome · Edge 는 브라우저를 닫아야 읽힙니다).');
  }
  return err;
}

/// 바이트 → 읽기 쉬운 크기
String formatBytes(num b) {
  if (b < 1024) return '${b.round()}B';
  const units = ['KB', 'MB', 'GB', 'TB'];
  var v = b / 1024;
  var i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  return '${v.toStringAsFixed(v < 10 ? 1 : 0)}${units[i]}';
}
