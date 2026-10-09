import 'package:flutter/widgets.dart';

/// 음성·자막 트랙
class TrackInfo {
  final String id;
  final String label;

  /// 외부 자막 파일이면 경로
  final String? file;
  const TrackInfo(this.id, this.label, {this.file});

  @override
  bool operator ==(Object other) => other is TrackInfo && other.id == id && other.file == file;
  @override
  int get hashCode => Object.hash(id, file);
}

/// 플레이어 상태 (화면 갱신용 한 묶음)
class PlayerState {
  final Duration position;
  final Duration duration;
  final bool playing;
  final bool completed;
  final int index;
  final double volume; // 0~100
  final double rate;
  final int? width;
  final int? height;
  final List<TrackInfo> audioTracks;
  final List<TrackInfo> subtitleTracks;
  final String? audioId;
  final String? subtitleId;

  const PlayerState({
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.playing = false,
    this.completed = false,
    this.index = 0,
    this.volume = 100,
    this.rate = 1,
    this.width,
    this.height,
    this.audioTracks = const [],
    this.subtitleTracks = const [],
    this.audioId,
    this.subtitleId,
  });
}

/// 동영상 플레이어 경계 (재생 목록 · 트랙 · 음량)
/// 구현: platform/common/media_kit_full_player.dart (mpv, Windows·Android 공용)
/// 내장 플레이어 자막 글자 크기 배율 (환경 설정 값, 1.0 = 기본). 플레이어 화면이 따라 바꾼다
final playerSubtitleScale = ValueNotifier<double>(1.0);

abstract class MediaPlayer {
  /// 상태가 바뀔 때마다 알림
  ValueNotifier<PlayerState> get state;
  Stream<String> get errors;

  Future<void> open(List<String> files, {int start = 0});
  Future<void> add(List<String> files);
  Future<void> jump(int index);
  Future<void> next();
  Future<void> previous();

  Future<void> playOrPause();
  Future<void> play();
  Future<void> stop();
  Future<void> seek(Duration position);
  Future<void> setVolume(double volume);
  Future<void> setRate(double rate);

  Future<void> setAudioTrack(TrackInfo t);

  /// 자막 트랙 (null 이면 끄기). [TrackInfo.file] 이 있으면 외부 파일을 불러온다.
  Future<void> setSubtitleTrack(TrackInfo? t);

  List<String> get playlist;

  Widget buildView();

  Future<void> dispose();
}
