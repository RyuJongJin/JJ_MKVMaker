import 'package:flutter/widgets.dart';

/// 자막 싱크 편집용 영상 재생기 경계.
///
/// 구현: platform/common/media_kit_player.dart (Windows·Android 공용)
abstract class PreviewPlayer {
  Stream<Duration> get positionStream;
  Stream<Duration> get durationStream;
  Stream<bool> get playingStream;
  Stream<String> get errorStream;

  Duration get position;
  Duration get duration;
  bool get isPlaying;

  /// 영상 열기. 영상에 들어 있는 자막은 표시하지 않는다 (편집 중인 자막을 따로 그림).
  Future<void> open(String path);

  Future<void> playOrPause();
  Future<void> pause();
  Future<void> seek(Duration position);
  Future<void> setRate(double rate);

  /// 영상 화면 위젯
  Widget buildView();

  Future<void> dispose();
}
