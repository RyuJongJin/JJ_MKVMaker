import 'package:flutter_test/flutter_test.dart';
import 'package:jj_mkvmaker/core/download_detect.dart';

/// 28: yt-dlp 에 넘기는 로그인 쿠키의 사이트 (경계가 맞는 것만)
void main() {
  test('Instagram · X · 네이버 (치지직) · YouTube 쿠키만, 비슷한 이름은 빼고', () {
    for (final d in ['.instagram.com', 'x.com', '.x.com', 'chzzk.naver.com', '.naver.com', 'www.youtube.com', 'TWITTER.COM']) {
      expect(isLoginCookieDomain(d), isTrue, reason: d);
    }
    for (final d in ['netflix.com', '.box.com', 'notnaver.com', 'example.com']) {
      expect(isLoginCookieDomain(d), isFalse, reason: d);
    }
  });
}
