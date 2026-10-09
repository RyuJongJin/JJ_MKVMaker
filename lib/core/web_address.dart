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

/// 137: 동영상 페이지 주소가 정해져 있는 사이트 (YouTube 등). 이런 사이트는 주소만으로 판단한다 -
/// 첫 화면 · 구독 목록에도 미리보기 &lt;video&gt; 가 있어 "동영상 있음" 으로 보였다.
bool isKnownVideoSite(String url) => RegExp(
      r'^https?://([\w-]+\.)*(youtube\.com|youtu\.be|vimeo\.com|dailymotion\.com|twitch\.tv|tiktok\.com|instagram\.com|'
      r'tv\.naver\.com|chzzk\.naver\.com|bilibili\.com|nicovideo\.jp)(/|$)',
      caseSensitive: false,
    ).hasMatch(url);

/// 137: 다운로드 버튼을 눈에 띄게 (채움) 할지 - 주소가 동영상 페이지이거나, 주소로 판단하지 않는 사이트에서 &lt;video&gt; 를 찾았을 때
bool downloadLooksUseful(String url, {required bool pageHasVideo}) =>
    looksLikeVideoPage(url) || (pageHasVideo && !isKnownVideoSite(url));
