import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jj_mkvmaker/app/settings.dart';
import 'package:jj_mkvmaker/core/youtube_ads.dart';
import 'package:path/path.dart' as p;

/// 가짜 YouTube 페이지 (DOM 흉내) 에서 스크립트를 실제로 돌려 본다 (node 가 있을 때)
const _harness = r'''
var timers = [];
global.setInterval = function (f) { timers.push(f); return timers.length; };
function el(cls) {
  return { classList: { _c: cls.slice(), contains: function (x) { return this._c.indexOf(x) >= 0; },
           remove: function (x) { this._c = this._c.filter(function (y) { return y !== x; }); } },
           clicked: 0, click: function () { this.clicked++; }, style: {}, remove: function () { this.removed = 1; } };
}
var player = el(['html5-video-player', 'ad-showing']);
var skip = el(['ytp-skip-ad-button']);
var video = { muted: false, playbackRate: 1.5, duration: 30, currentTime: 2 };
var appended = [];
var body = { appendChild: function (n) { appended.push(n); } };
global.location = { hostname: process.argv[3] };
global.document = {
  body: body, head: body, documentElement: body,
  createElement: function () { return el([]); },
  querySelector: function (q) {
    if (q === 'video') return video;
    if (q === '.html5-video-player') return player;
    if (q.indexOf('skip') >= 0) return player.classList.contains('ad-showing') ? skip : null;
    return null;
  },
};
global.window = global;
require(process.argv[2]);
var r = { installed: timers.length };
r.skipClicked = skip.clicked; r.muted = video.muted; r.rate = video.playbackRate; r.time = video.currentTime;
r.badge = appended.some(function (n) { return n.textContent === '광고 건너뛰는 중…'; });
r.style = appended.some(function (n) { return (n.textContent || '').indexOf('display:none') >= 0; });
player.classList.remove('ad-showing');
timers.forEach(function (f) { f(); });
r.afterMuted = video.muted; r.afterRate = video.playbackRate;
console.log(JSON.stringify(r));
''';

void main() {
  test('설정: 광고 건너뛰기 · 숨기기 기본 켜짐, 저장', () {
    final s = AppSettings();
    expect([s.youtubeAdSkip, s.youtubeAdHide], [true, true]);
    s
      ..youtubeAdSkip = false
      ..youtubeAdHide = false;
    final back = AppSettings.fromJson(s.toJson());
    expect([back.youtubeAdSkip, back.youtubeAdHide], [false, false]);
    expect(youtubeAdScript(skip: false, hide: true), contains('{skip: false, hide: true}'));
  });

  final node = Platform.isWindows ? r'C:\Program Files\nodejs\node.exe' : '/usr/bin/node';
  test('가짜 YouTube 페이지: 건너뛰기 버튼 누르기 · 소리 끄고 빨리 감기 · 끝나면 되돌리기', () async {
    final dir = Directory.systemTemp.createTempSync('jj_ads_');
    addTearDown(() => dir.deleteSync(recursive: true));
    Future<Map<String, Object?>> run(String host, {bool skip = true, bool hide = true}) async {
      final script = File(p.join(dir.path, 'ad_${host}_$skip$hide.js'))
        ..writeAsStringSync(youtubeAdScript(skip: skip, hide: hide));
      final harness = File(p.join(dir.path, 'harness.js'))..writeAsStringSync(_harness);
      final r = await Process.run(node, [harness.path, script.path, host]);
      expect(r.exitCode, 0, reason: '${r.stderr}');
      return Map<String, Object?>.from(jsonDecode((r.stdout as String).trim()) as Map);
    }

    final yt = await run('www.youtube.com');
    expect(yt['installed'], 1);
    expect(yt['skipClicked'], 1);
    expect(yt['muted'], true);
    expect(yt['rate'], 16);
    expect(yt['time'], closeTo(29.9, 0.01));
    expect(yt['badge'], true);
    expect(yt['style'], true);
    // 광고가 끝나면 원래 소리 · 속도로
    expect(yt['afterMuted'], false);
    expect(yt['afterRate'], 1.5);

    // 끄면 아무것도 하지 않는다
    final off = await run('m.youtube.com', skip: false, hide: false);
    expect([off['skipClicked'], off['muted'], off['style']], [0, false, false]);

    // YouTube 가 아닌 사이트에는 넣지 않는다
    final other = await run('example.com');
    expect(other['installed'], 0);
  }, skip: File(node).existsSync() ? false : 'node 없음');
}
