import 'download_detect.dart';

/// 주소창 입력 → 이동할 주소. 주소가 아니면 Google 검색.
String normalizeAddress(String input) {
  final t = input.trim();
  if (t.isEmpty) return 'about:blank';
  if (RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*://').hasMatch(t) || t.startsWith('about:')) return t;
  // 공백이 없고 점이 있으면 주소 (예: youtube.com, 192.168.0.1:8080/x)
  if (!t.contains(' ') && RegExp(r'^[^\s/]+\.[^\s/]+(:\d+)?(/.*)?$').hasMatch(t) ||
      RegExp(r'^localhost(:\d+)?(/.*)?$').hasMatch(t)) {
    return 'https://$t';
  }
  return 'https://www.google.com/search?q=${Uri.encodeQueryComponent(t)}';
}

/// yt-dlp 로 받을 수 있는 동영상 페이지로 보이는지 (주소만으로 판단).
/// 페이지 안에 &lt;video&gt; 가 있는지는 브라우저가 따로 확인한다.
bool looksLikeVideoPage(String url) {
  if (detectLinks(url).isNotEmpty) return true; // YouTube · 마그넷 · torrent
  return RegExp(
    r'^https?://([\w-]+\.)*(vimeo\.com/\d|dailymotion\.com/video|twitch\.tv/|tiktok\.com/@[^/]+/video|'
    r'instagram\.com/(reel|p)/|x\.com/[^/]+/status|twitter\.com/[^/]+/status|facebook\.com/.+/videos|'
    r'tv\.naver\.com/v|chzzk\.naver\.com/(video|clips)|afreecatv\.com|sooplive\.co\.kr|bilibili\.com/video|nicovideo\.jp/watch)',
    caseSensitive: false,
  ).hasMatch(url);
}
