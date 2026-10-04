/// YouTube 광고 건너뛰기 · 광고 영역 숨기기 스크립트 (앱 안 웹 브라우저가 YouTube 페이지에 넣는다).
///
/// - 건너뛰기: [건너뛰기] 버튼이 나오면 누르고, 건너뛸 수 없는 광고는 소리를 끄고 끝으로 빨리 감는다.
///   광고가 나오는 동안 화면 위쪽에 "광고 건너뛰는 중…" 을 잠깐 보여 준다.
/// - 숨기기: 목록 · 영상 옆 · 영상 위의 광고 배너를 감춘다.
///
/// 여러 번 넣어도 한 번만 동작하고, 다시 넣으면 켜기 · 끄기 설정만 바뀐다 (페이지를 다시 읽지 않아도 됨).
String youtubeAdScript({required bool skip, required bool hide}) => '''
(function(cfg){
  var h = location.hostname;
  if (h !== 'youtube.com' && h.slice(-12) !== '.youtube.com') return;
  window.__jjAdCfg = cfg;
  if (window.__jjAd) return;
  window.__jjAd = 1;
  var css = null, badge = null;
  var HIDE = 'ytd-ad-slot-renderer,ytd-in-feed-ad-layout-renderer,ytd-banner-promo-renderer,'
    + 'ytd-promoted-sparkles-web-renderer,ytd-promoted-video-renderer,ytd-display-ad-renderer,'
    + 'ytd-companion-slot-renderer,ytd-action-companion-ad-renderer,ytd-statement-banner-renderer,'
    + '#player-ads,#masthead-ad,.ytp-ad-overlay-container,.ytp-ad-overlay-slot,.ytp-ad-image-overlay,'
    + 'ytm-promoted-sparkles-web-renderer,ytm-companion-ad-renderer,ytm-promoted-video-renderer,'
    + 'ad-slot-renderer,ytm-ad-slot-renderer,.ad-container,.masthead-ad'
    + '{display:none !important}';
  function showBadge(on) {
    if (on && !badge) {
      badge = document.createElement('div');
      badge.textContent = '광고 건너뛰는 중…';
      badge.style.cssText = 'position:fixed;top:12px;left:50%;transform:translateX(-50%);z-index:2147483647;'
        + 'background:rgba(0,0,0,.75);color:#fff;font:600 13px sans-serif;padding:6px 14px;border-radius:14px;pointer-events:none';
      (document.body || document.documentElement).appendChild(badge);
    } else if (!on && badge) {
      badge.remove();
      badge = null;
    }
  }
  function tick() {
    var c = window.__jjAdCfg || {};
    if (c.hide && !css) {
      css = document.createElement('style');
      css.textContent = HIDE;
      (document.head || document.documentElement).appendChild(css);
    } else if (!c.hide && css) {
      css.remove();
      css = null;
    }
    var v = document.querySelector('video');
    var p = document.querySelector('.html5-video-player');
    var ad = !!(p && (p.classList.contains('ad-showing') || p.classList.contains('ad-interrupting')));
    if (c.skip && ad) {
      var b = document.querySelector('.ytp-skip-ad-button,.ytp-ad-skip-button,.ytp-ad-skip-button-modern,'
        + '.ytp-ad-skip-button-container button,.ytp-ad-skip-button-slot button');
      if (b) { try { b.click(); } catch (e) {} }
      if (v) {
        if (!v.__jjAd) { v.__jjAd = 1; v.__jjMuted = v.muted; v.__jjRate = v.playbackRate; }
        v.muted = true;
        try { if (isFinite(v.duration) && v.duration > 0.5) v.currentTime = v.duration - 0.1; } catch (e) {}
        try { v.playbackRate = 16; } catch (e) {}
      }
      showBadge(true);
    } else {
      if (v && v.__jjAd) {
        v.__jjAd = 0;
        v.muted = v.__jjMuted;
        try { v.playbackRate = v.__jjRate || 1; } catch (e) {}
      }
      showBadge(false);
    }
  }
  setInterval(tick, 300);
  tick();
})({skip: $skip, hide: $hide});
''';
