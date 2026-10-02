import 'dart:async';

import 'package:ffmpeg_kit_flutter_new_min_gpl/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_min_gpl/ffmpeg_kit_config.dart';
import 'package:ffmpeg_kit_flutter_new_min_gpl/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter_new_min_gpl/return_code.dart';

import '../../core/models.dart';
import '../../services/media_tool.dart';
import '../windows/process_media_tool.dart' show parseEncoderList, parseFfmpegInfo, parseProbeJson;

/// Android: 앱에 넣은 FFmpeg 라이브러리 (ffmpeg-kit) 로 실행하는 구현.
/// 명령 인수는 데스크톱 (ffmpeg.exe) 과 같다. 진행률만 "-progress pipe:1" 대신 통계 콜백으로 받는다.
class FfmpegKitMediaTool implements MediaTool {
  /// 실행 중인 작업 (취소용)
  final Set<int> _running = {};
  final Set<int> _cancelled = {};

  @override
  Future<String?> version() async {
    try {
      final v = await FFmpegKitConfig.getFFmpegVersion();
      return v == null ? null : 'ffmpeg version $v (Android)';
    } catch (_) {
      return null;
    }
  }

  @override
  Future<Set<String>> encoders() async {
    try {
      final s = await FFmpegKit.executeWithArguments(['-hide_banner', '-encoders']);
      return parseEncoderList(await s.getOutput() ?? '');
    } catch (_) {
      return {};
    }
  }

  @override
  Future<MediaInfo> probe(String path) async {
    try {
      final s = await FFprobeKit.executeWithArguments(
          ['-v', 'error', '-print_format', 'json', '-show_format', '-show_streams', path]);
      if (ReturnCode.isSuccess(await s.getReturnCode())) {
        final out = await s.getOutput() ?? '';
        final start = out.indexOf('{');
        if (start >= 0) return parseProbeJson(out.substring(start));
      }
    } catch (_) {}
    // ffprobe 로 안 되면 ffmpeg -i 의 출력으로
    final s = await FFmpegKit.executeWithArguments(['-hide_banner', '-nostdin', '-i', path]);
    final text = await s.getOutput() ?? '';
    final info = parseFfmpegInfo(text);
    if (info.streams.isEmpty) {
      throw MediaToolException('파일을 분석할 수 없습니다: ${text.trim().split('\n').last}');
    }
    return info;
  }

  @override
  Future<void> runFfmpeg(List<String> args, {Duration? duration, ProgressCallback? onProgress}) async {
    // 표준 출력으로 진행률을 쓰는 인수는 빼고 통계 콜백을 쓴다
    final a = <String>[];
    for (var i = 0; i < args.length; i++) {
      if (args[i] == '-progress' && i + 1 < args.length) {
        i++;
        continue;
      }
      a.add(args[i]);
    }
    final totalMs = duration?.inMilliseconds ?? 0;
    final done = Completer<void>();
    final errTail = <String>[];
    final session = await FFmpegKit.executeWithArgumentsAsync(
      a,
      (s) async {
        final id = s.getSessionId();
        _running.remove(id);
        final rc = await s.getReturnCode();
        if (_cancelled.remove(id) || ReturnCode.isCancel(rc)) {
          done.completeError(const MediaToolException('사용자가 취소했습니다.'));
        } else if (!ReturnCode.isSuccess(rc)) {
          done.completeError(MediaToolException('ffmpeg 오류 (코드 ${rc?.getValue()})\n${errTail.join('\n')}'));
        } else {
          done.complete();
        }
      },
      (log) {
        for (final line in log.getMessage().split('\n')) {
          if (line.trim().isEmpty) continue;
          errTail.add(line);
          if (errTail.length > 15) errTail.removeAt(0);
        }
      },
      (st) {
        if (onProgress != null && totalMs > 0 && st.getTime() > 0) {
          onProgress((st.getTime() / totalMs).clamp(0.0, 1.0));
        }
      },
    );
    final id = session.getSessionId();
    if (id != null && !done.isCompleted) _running.add(id);
    await done.future;
    onProgress?.call(1.0);
  }

  @override
  void cancel() {
    for (final id in _running.toList()) {
      _cancelled.add(id);
      unawaited(FFmpegKit.cancel(id));
    }
  }
}
