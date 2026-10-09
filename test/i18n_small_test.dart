import 'package:flutter_test/flutter_test.dart';
import 'package:jj_mkvmaker/app/i18n_controller.dart';
import 'package:jj_mkvmaker/core/bookmarks.dart';
import 'package:jj_mkvmaker/core/languages.dart';
import 'package:jj_mkvmaker/core/mkv_command_builder.dart';
import 'package:jj_mkvmaker/l10n/tr.dart';
import 'package:jj_mkvmaker/platform/android/android_storage.dart';

/// 61: 다국어 작은 것들
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(() => i18n.apply('ko', save: false));

  test('영어 복수형: 수가 1 이면 단수 ("1 videos" → "1 video"), 11 · 21 · 1.5 는 그대로', () {
    expect(englishSingular('Added 1 videos to the list.'), 'Added 1 video to the list.');
    expect(englishSingular('(1 files)'), '(1 file)');
    expect(englishSingular('1 copies · 1 entries'), '1 copy · 1 entry');
    expect(englishSingular('11 videos · 21 files · 1.1 videos · 0,1 items'), '11 videos · 21 files · 1.1 videos · 0,1 items');
    expect(englishSingular('2 videos'), '2 videos');
  });

  test('영어 화면에서 trf 가 단수를 쓴다 (한국어 · 일본어는 그대로)', () async {
    await i18n.apply('en', save: false);
    expect(trf('{0}개 항목을 다음 폴더로 옮길까요?\n{1}', [1, 'D:']), 'Move 1 item to this folder?\nD:');
    expect(trf('{0}개 항목을 다음 폴더로 옮길까요?\n{1}', [3, 'D:']), 'Move 3 items to this folder?\nD:');
    await i18n.apply('ja', save: false);
    expect(trf('{0}개 항목을 다음 폴더로 복사할까요?\n{1}', [1, 'D:']), contains('1 件'));
  });

  test('MKV 기본 자막 · 플레이어가 먼저 켤 자막은 화면 언어 (목록에 없는 언어면 한국어)', () async {
    expect(preferredDefaultLanguage, 'kor');
    await i18n.apply('ja', save: false);
    expect(preferredDefaultLanguage, 'jpn');
    final ja = preferredSubtitlePattern();
    expect(ja.hasMatch('movie.ja.srt'), isTrue);
    expect(ja.hasMatch('movie.jpn.srt'), isTrue);
    expect(ja.hasMatch('日本語'), isTrue, reason: '트랙 이름 (화면 언어로 된 언어 이름)');
    expect(ja.hasMatch('movie.ko.srt'), isFalse);
    await i18n.apply('en', save: false);
    expect(preferredDefaultLanguage, 'eng');
    expect(preferredSubtitlePattern().hasMatch('Movie.en.srt'), isTrue);
    expect(preferredSubtitlePattern().hasMatch('Movie.kor.srt'), isFalse);
    // 한국어 (예전 그대로)
    final ko = preferredSubtitlePattern('ko');
    for (final s in ['a.ko.srt', 'a.kor.ass', 'a (ko).srt', '한국어']) {
      expect(ko.hasMatch(s), isTrue, reason: s);
    }
    expect(preferredSubtitlePattern('xx').hasMatch('a.ko.srt'), isTrue, reason: '모르는 언어면 한국어');
  });

  test('Android 저장소 이름: 내장 · SD 카드는 앱 화면 언어로, USB 등은 기기 이름 그대로', () async {
    await i18n.apply('en', save: false);
    expect(AndroidAccess.volumeLabel('디바이스 저장공간', primary: true, removable: false), 'Internal storage');
    expect(AndroidAccess.volumeLabel('SD 카드', primary: false, removable: true), 'SD card');
    expect(AndroidAccess.volumeLabel('USB 저장소', primary: false, removable: true), 'USB 저장소');
  });

  test('기본 즐겨찾기 이름은 바꾸지 않았으면 화면 언어로 (예전 판이 다른 언어로 저장했어도), 바꾼 이름은 그대로', () async {
    final t = BookmarkTree.defaults();
    expect(t.bar.children![1].title, 'YouTube 구독');
    await i18n.apply('en', save: false);
    expect(t.bar.children![1].title, 'YouTube subscriptions');
    expect(t.bar.title, 'Bookmarks bar');
    // 예전 판이 일본어로 저장해 둔 기본 이름
    final old = BookmarkTree.fromJson({
      'bar': {'id': 'bar', 'title': 'ブックマークバー', 'children': [
        {'id': 'b2', 'title': 'YouTube 登録チャンネル', 'url': 'https://www.youtube.com/feed/subscriptions'},
        {'id': 'n1', 'title': 'YouTube 구독', 'url': 'https://x'},
      ]},
      'other': {'id': 'other', 'title': '내 것', 'children': []},
    });
    expect(old.bar.title, 'Bookmarks bar');
    expect(old.bar.children![0].title, 'YouTube subscriptions');
    expect(old.bar.children![1].title, 'YouTube 구독', reason: '기본이 아닌 항목 (사용자가 만든 것) 은 그대로');
    expect(old.other.title, '내 것', reason: '바꾼 이름은 그대로');
    // 저장은 원래 이름 그대로 (언어를 바꿔도 저장 파일이 바뀌지 않게)
    expect((t.toJson()['bar'] as Map)['title'], '즐겨찾기 표시줄');
  });
}
