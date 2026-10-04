import 'dart:async';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart' as mk;
import 'package:media_kit_video/media_kit_video.dart';
import 'package:path/path.dart' as p;

import '../../services/media_player.dart';
import '../../l10n/tr.dart';

/// mpv 가 오류 수준으로 남기지만 재생에는 지장이 없는 메시지.
///
/// 예) AV1 하드웨어 디코딩을 지원하지 않는 그래픽카드에서 mpv 는 d3d11va · dxva2 등을 차례로
/// 시도하다 실패하며 "Could not open codec." 을 남긴 뒤 소프트웨어(libdav1d)로 정상 재생한다.
bool isNonFatalMpvMessage(String m) =>
    m.contains('Could not open codec') ||
    m.contains('hardware decoding') ||
    m.contains('Could not create device') ||
    m.contains('Can not open external file');

/// mpv(media_kit) 동영상 플레이어. Windows·Android 공용.
class MediaKitFullPlayer implements MediaPlayer {
  final mk.Player _p = mk.Player();
  late final VideoController _video = VideoController(_p,
      configuration: VideoControllerConfiguration(enableHardwareAcceleration: hardwareAcceleration));

  /// 하드웨어 디코딩 사용 (지원하지 않는 코덱은 mpv 가 소프트웨어로 대체)
  final bool hardwareAcceleration;
  final _subs = <StreamSubscription<Object?>>[];
  final _errors = StreamController<String>.broadcast();
  List<String> _files = [];

  /// 외부 자막 파일로 켠 트랙 (mpv 목록에는 경로가 id 로 나타남)
  TrackInfo? _externalSub;

  @override
  final ValueNotifier<PlayerState> state = ValueNotifier(const PlayerState());

  MediaKitFullPlayer({this.hardwareAcceleration = true}) {
    final s = _p.stream;
    _subs
      ..add(s.position.listen((_) => _emit()))
      ..add(s.duration.listen((_) => _emit()))
      ..add(s.playing.listen((_) => _emit()))
      ..add(s.completed.listen((_) => _emit()))
      ..add(s.volume.listen((_) => _emit()))
      ..add(s.rate.listen((_) => _emit()))
      ..add(s.width.listen((_) => _emit()))
      ..add(s.height.listen((_) => _emit()))
      ..add(s.tracks.listen((_) => _emit()))
      ..add(s.track.listen((_) => _emit()))
      ..add(s.playlist.listen((_) {
        _externalSub = null; // 다음 파일로 넘어가면 외부 자막은 풀림
        _emit();
      }))
      ..add(s.error.where((m) => !isNonFatalMpvMessage(m)).listen(_errors.add));
  }

  static String _label(String? title, String? lang, String id) {
    final parts = [
      if (title != null && title.isNotEmpty) title,
      if (lang != null && lang.isNotEmpty) lang,
    ];
    return parts.isEmpty ? trf('트랙 {0}', [id]) : parts.join(' · ');
  }

  void _emit() {
    final st = _p.state;
    final audio = [
      for (final t in st.tracks.audio)
        if (t.id != 'auto' && t.id != 'no') TrackInfo(t.id, _label(t.title, t.language, t.id)),
    ];
    final subs = [
      for (final t in st.tracks.subtitle)
        if (t.id != 'auto' && t.id != 'no' && !t.uri && !t.data)
          TrackInfo(t.id, _label(t.title, t.language, t.id)),
    ];
    final sid = st.track.subtitle.id;
    state.value = PlayerState(
      position: st.position,
      duration: st.duration,
      playing: st.playing,
      completed: st.completed,
      index: st.playlist.index,
      volume: st.volume,
      rate: st.rate,
      width: st.width,
      height: st.height,
      audioTracks: audio,
      subtitleTracks: subs,
      audioId: st.track.audio.id,
      // mpv 의 'auto' 는 고른 자막이 없을 수도 있다 → 실제 목록에 있을 때만 켜진 것으로
      subtitleId: _externalSub?.id ?? (subs.any((t) => t.id == sid) ? sid : null),
    );
  }

  @override
  Stream<String> get errors => _errors.stream;

  @override
  List<String> get playlist => List.unmodifiable(_files);

  @override
  Future<void> open(List<String> files, {int start = 0}) async {
    _files = List.of(files);
    _externalSub = null;
    await _p.open(mk.Playlist([for (final f in files) mk.Media(f)], index: start));
  }

  @override
  Future<void> add(List<String> files) async {
    if (_files.isEmpty) return open(files);
    for (final f in files) {
      _files.add(f);
      await _p.add(mk.Media(f));
    }
    _emit();
  }

  @override
  Future<void> jump(int index) => _p.jump(index);
  @override
  Future<void> next() => _p.next();
  @override
  Future<void> previous() => _p.previous();
  @override
  Future<void> playOrPause() => _p.playOrPause();
  @override
  Future<void> play() => _p.play();

  /// 정지: 처음으로 돌아가 멈춤 (목록은 유지)
  @override
  Future<void> stop() async {
    await _p.pause();
    await _p.seek(Duration.zero);
  }

  @override
  Future<void> seek(Duration position) =>
      _p.seek(position.isNegative ? Duration.zero : position);
  @override
  Future<void> setVolume(double volume) => _p.setVolume(volume.clamp(0, 100).toDouble());
  @override
  Future<void> setRate(double rate) => _p.setRate(rate);

  @override
  Future<void> setAudioTrack(TrackInfo t) async {
    final a = _p.state.tracks.audio.where((x) => x.id == t.id).firstOrNull;
    if (a != null) await _p.setAudioTrack(a);
  }

  @override
  Future<void> setSubtitleTrack(TrackInfo? t) async {
    if (t == null) {
      _externalSub = null;
      await _p.setSubtitleTrack(mk.SubtitleTrack.no());
    } else if (t.file != null) {
      _externalSub = t;
      await _p.setSubtitleTrack(mk.SubtitleTrack.uri(t.file!, title: p.basename(t.file!)));
    } else {
      _externalSub = null;
      final s = _p.state.tracks.subtitle.where((x) => x.id == t.id).firstOrNull;
      if (s != null) await _p.setSubtitleTrack(s);
    }
    _emit();
  }

  @override
  Widget buildView() => Video(
        controller: _video,
        controls: NoVideoControls,
        fill: Colors.black,
        subtitleViewConfiguration: const SubtitleViewConfiguration(
          style: TextStyle(
            fontSize: 44,
            color: Colors.white,
            height: 1.3,
            shadows: [Shadow(blurRadius: 6, color: Colors.black), Shadow(offset: Offset(2, 2))],
          ),
          padding: EdgeInsets.fromLTRB(24, 0, 24, 36),
        ),
      );

  @override
  Future<void> dispose() async {
    for (final s in _subs) {
      await s.cancel();
    }
    await _errors.close();
    await _p.dispose();
    state.dispose();
  }
}
