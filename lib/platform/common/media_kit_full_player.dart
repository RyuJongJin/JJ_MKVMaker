import 'dart:async';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart' as mk;
import 'package:media_kit_video/media_kit_video.dart';
import 'package:path/path.dart' as p;

import '../../core/secret_gate.dart';
import '../../core/vfs.dart';
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

  /// 마지막으로 건너뛴 때 · 위치 (건너뛴 직후의 "끝" 이 진짜인지 가리기)
  DateTime _seekAt = DateTime(0);
  Duration _seekTo = Duration.zero;
  bool _seekRetried = false;

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
      ..add(s.completed.listen((done) {
        _emit();
        if (done) unawaited(_onEnd());
      }))
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
    await _keepOpen();
    await _p.open(mk.Playlist([for (final f in files) await _media(f)], index: start));
  }

  @override
  Future<void> add(List<String> files) async {
    if (_files.isEmpty) return open(files);
    for (final f in files) {
      _files.add(f);
      await _p.add(await _media(f));
    }
    _emit();
  }

  /// 플레이어가 처음 가진 인증서 확인 값 (56: 자체 서명 서버를 튼 뒤 다른 것을 틀면 원래대로)
  String? _tlsDefault;

  /// WebDAV 는 받지 않고 바로 스트리밍 (주소 + 인증 헤더, 자체 서명 인증서면 확인 안 함)
  Future<mk.Media> _media(String f) async {
    final native = _p.platform;
    final dav = isDav(f) ? davStream(f) : null;
    if (native is mk.NativePlayer) {
      _tlsDefault ??= await native.getProperty('tls-verify');
      // 56: "인증서 확인 안 함" 서버의 것만 확인을 끄고, 그 밖은 원래 값으로 (한 번 끈 것이 계속 남지 않게)
      final want = dav != null && dav.insecure ? 'no' : _tlsDefault!;
      await native.setProperty('tls-verify', want);
    }
    if (dav == null) return mk.Media(f);
    // 124: 저장된 비밀번호로 여는 것이면 (마스터 비밀번호를 정해 두었으면 묻는다)
    // 사용자가 직접 튼 것이니 한 번 취소했어도 다시 묻는다
    if (dav.headers.isNotEmpty && !await SecretGate.pass(force: true)) throw Exception(tr(secretGateMessage));
    return mk.Media(dav.url, httpHeaders: dav.headers);
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
  Future<void> seek(Duration position) {
    _seekAt = DateTime.now();
    _seekTo = position.isNegative ? Duration.zero : position;
    _seekRetried = false;
    return _p.seek(_seekTo);
  }

  /// mpv 가 파일 끝에서 스스로 다음 파일로 넘어가지 않게 한다 (넘기기는 [_onEnd] 가 정한다).
  /// 일부 파일 (AVI 에서 옮긴 MKV 등) 은 Android 에서 건너뛰기 직후 mpv 가 끝에 닿은 것으로 잘못 보고
  /// 다음 편으로 넘어가 버렸다.
  Future<void> _keepOpen() async {
    final native = _p.platform;
    if (native is mk.NativePlayer) await native.setProperty('keep-open', 'always');
  }

  /// 파일 끝: 건너뛴 직후 (3초 안) 이고 건너뛴 곳이 끝 근처가 아니면 잘못 본 끝 → 그 곳으로 다시 (키프레임 기준).
  /// 다시 해도 끝이면 그 자리에 둔다. 진짜 끝이면 다음 파일로.
  Future<void> _onEnd() async {
    final st = _p.state;
    final dur = st.duration;
    final recent = DateTime.now().difference(_seekAt) < const Duration(seconds: 3);
    if (recent && dur > Duration.zero && _seekTo < dur - const Duration(seconds: 5)) {
      if (_seekRetried) return;
      _seekRetried = true;
      final native = _p.platform;
      if (native is mk.NativePlayer) {
        await native.command(['seek', (_seekTo.inMilliseconds / 1000).toStringAsFixed(3), 'absolute+keyframes']);
      } else {
        await _p.seek(_seekTo);
      }
      await _p.play();
      return;
    }
    if (st.playlist.index < st.playlist.medias.length - 1) {
      await _p.next();
      await _p.play();
    }
  }
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
  Widget buildView() => ValueListenableBuilder<double>(
        // 자막 글자 크기 (플레이어 메뉴 > 자막 크기)
        valueListenable: playerSubtitleScale,
        builder: (_, scale, _) => Video(
          controller: _video,
          controls: NoVideoControls,
          fill: Colors.black,
          subtitleViewConfiguration: SubtitleViewConfiguration(
            style: TextStyle(
              fontSize: 44 * scale,
              color: Colors.white,
              height: 1.3,
              shadows: const [Shadow(blurRadius: 6, color: Colors.black), Shadow(offset: Offset(2, 2))],
            ),
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 36),
          ),
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
