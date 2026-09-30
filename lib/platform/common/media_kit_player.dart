import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../services/preview_player.dart';
import 'media_kit_full_player.dart' show isNonFatalMpvMessage;

/// media_kit(libmpv) 기반 재생기. Windows·Android 공용.
class MediaKitPreviewPlayer implements PreviewPlayer {
  final Player _player = Player();
  late final VideoController _video = VideoController(_player,
      configuration: VideoControllerConfiguration(
          enableHardwareAcceleration: hardwareAcceleration));

  final bool hardwareAcceleration;

  MediaKitPreviewPlayer({this.hardwareAcceleration = true});

  static bool _initialized = false;

  /// 앱 시작 시 한 번 호출
  static void ensureInitialized() {
    if (_initialized) return;
    MediaKit.ensureInitialized();
    _initialized = true;
  }

  @override
  Stream<Duration> get positionStream => _player.stream.position;
  @override
  Stream<Duration> get durationStream => _player.stream.duration;
  @override
  Stream<bool> get playingStream => _player.stream.playing;
  @override
  Stream<String> get errorStream => _player.stream.error.where((m) => !isNonFatalMpvMessage(m));

  @override
  Duration get position => _player.state.position;
  @override
  Duration get duration => _player.state.duration;
  @override
  bool get isPlaying => _player.state.playing;

  @override
  Future<void> open(String path) async {
    await _player.open(Media(path), play: false);
    await _player.setSubtitleTrack(SubtitleTrack.no());
  }

  @override
  Future<void> playOrPause() => _player.playOrPause();
  @override
  Future<void> pause() => _player.pause();
  @override
  Future<void> seek(Duration position) =>
      _player.seek(position.isNegative ? Duration.zero : position);
  @override
  Future<void> setRate(double rate) => _player.setRate(rate);

  @override
  Widget buildView() => Video(
        controller: _video,
        controls: NoVideoControls,
        fill: Colors.black,
        subtitleViewConfiguration: const SubtitleViewConfiguration(visible: false),
      );

  @override
  Future<void> dispose() => _player.dispose();
}
