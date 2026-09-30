import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../core/models.dart';
import '../../services/media_tool.dart';

/// ffmpeg.exe / ffprobe.exe 를 자식 프로세스로 실행하는 구현 (데스크톱용).
class ProcessMediaTool implements MediaTool {
  final String ffmpeg;
  final String ffprobe;
  /// 실행 중인 ffmpeg (여러 개 동시 실행 가능)
  final Set<Process> _running = {};

  /// 취소로 종료시킨 프로세스
  final Set<Process> _killed = {};

  ProcessMediaTool(this.ffmpeg, this.ffprobe);

  /// 찾는 순서:
  /// 1. 실행 파일 옆 ffmpeg\ 폴더 (배포본에 동봉)
  /// 2. 실행 파일과 같은 폴더
  /// 3. 시스템 PATH
  factory ProcessMediaTool.locate() {
    final exe = Platform.isWindows ? '.exe' : '';
    final appDir = p.dirname(Platform.resolvedExecutable);
    for (final dir in [p.join(appDir, 'ffmpeg'), appDir]) {
      final f = p.join(dir, 'ffmpeg$exe');
      if (File(f).existsSync()) {
        return ProcessMediaTool(f, p.join(dir, 'ffprobe$exe'));
      }
    }
    return ProcessMediaTool('ffmpeg', 'ffprobe');
  }

  @override
  Future<String?> version() async {
    try {
      final r = await Process.run(ffmpeg, ['-hide_banner', '-version'],
          stdoutEncoding: utf8);
      if (r.exitCode != 0) return null;
      return (r.stdout as String).split('\n').first.trim();
    } on ProcessException {
      return null;
    }
  }

  @override
  Future<Set<String>> encoders() async {
    try {
      final r = await Process.run(ffmpeg, ['-hide_banner', '-encoders'],
          stdoutEncoding: utf8);
      if (r.exitCode != 0) return {};
      return parseEncoderList(r.stdout as String);
    } on ProcessException {
      return {};
    }
  }

  /// ffprobe 가 없거나 차단된 경우(예: Windows 스마트 앱 컨트롤) ffmpeg 로 대체
  bool _ffprobeUnavailable = false;

  @override
  Future<MediaInfo> probe(String path) async {
    if (!_ffprobeUnavailable) {
      try {
        final r = await Process.run(
          ffprobe,
          ['-v', 'error', '-print_format', 'json', '-show_format', '-show_streams', path],
          stdoutEncoding: utf8,
          stderrEncoding: utf8,
        );
        if (r.exitCode != 0) {
          throw MediaToolException(
              '파일을 분석할 수 없습니다: ${(r.stderr as String).trim()}');
        }
        return parseProbeJson(r.stdout as String);
      } on ProcessException {
        _ffprobeUnavailable = true;
      }
    }
    return _probeWithFfmpeg(path);
  }

  Future<MediaInfo> _probeWithFfmpeg(String path) async {
    final ProcessResult r;
    try {
      // 출력 파일 없이 -i 만 주면 정보를 stderr 에 출력하고 코드 1 로 끝난다
      r = await Process.run(ffmpeg, ['-hide_banner', '-nostdin', '-i', path],
          stderrEncoding: const Utf8Codec(allowMalformed: true));
    } on ProcessException catch (e) {
      throw MediaToolException('ffmpeg 를 실행할 수 없습니다: ${e.message}');
    }
    final text = r.stderr as String;
    final info = parseFfmpegInfo(text);
    if (info.streams.isEmpty) {
      throw MediaToolException(
          '파일을 분석할 수 없습니다: ${text.trim().split('\n').last}');
    }
    return info;
  }

  @override
  Future<void> runFfmpeg(
    List<String> args, {
    Duration? duration,
    ProgressCallback? onProgress,
  }) async {
    final Process proc;
    try {
      proc = await Process.start(ffmpeg, args);
    } on ProcessException catch (e) {
      throw MediaToolException('ffmpeg 를 실행할 수 없습니다: ${e.message}');
    }
    _running.add(proc);

    final totalUs = duration?.inMicroseconds ?? 0;
    final stdoutDone = proc.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .forEach((line) {
      // -progress pipe:1 출력: out_time_us=12345678
      if (onProgress == null || totalUs <= 0) return;
      if (line.startsWith('out_time_us=') || line.startsWith('out_time_ms=')) {
        final us = int.tryParse(line.substring(line.indexOf('=') + 1));
        if (us != null && us >= 0) onProgress((us / totalUs).clamp(0.0, 1.0));
      }
    });
    // 오류 메시지용으로 stderr 마지막 부분만 보관
    final errTail = <String>[];
    final stderrDone = proc.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .forEach((line) {
      errTail.add(line);
      if (errTail.length > 15) errTail.removeAt(0);
    });

    final code = await proc.exitCode;
    await Future.wait([stdoutDone, stderrDone]);
    _running.remove(proc);

    if (_killed.remove(proc)) throw const MediaToolException('사용자가 취소했습니다.');
    if (code != 0) {
      throw MediaToolException('ffmpeg 오류 (코드 $code)\n${errTail.join('\n')}');
    }
    onProgress?.call(1.0);
  }

  /// 실행 중인 ffmpeg 모두 중단
  @override
  void cancel() {
    for (final proc in _running.toList()) {
      _killed.add(proc);
      // 'q' 로 정상 종료를 요청하지 않고 즉시 중단 (-nostdin 사용 중)
      proc.kill();
    }
  }
}

/// `ffmpeg -encoders` 출력 → 영상 인코더 이름
/// 예) " V....D libx264              libx264 H.264 / AVC ..."
Set<String> parseEncoderList(String text) => {
      for (final m in RegExp(r'^\s*V[.A-Z]{5}\s+(\S+)', multiLine: true).allMatches(text))
        if (m[1] != '=') m[1]!, // 범례 줄 " V..... = Video" 제외
    };

final _streamLine = RegExp(
    r'^\s*Stream #0:(\d+)(?:\[[^\]]*\])?(?:\(([^)]*)\))?(?:\[[^\]]*\])?: (\w+): ([^\s,]+)');
final _durationLine = RegExp(r'Duration: (\d+):(\d+):(\d+(?:\.\d+)?)');
final _resolution = RegExp(r', (\d{2,5})x(\d{2,5})[\s,]');
final _titleLine = RegExp(r'^\s+title\s*:\s?(.*)$', caseSensitive: false);

/// `ffmpeg -i 파일` 의 stderr 출력 → MediaInfo
///
/// 예) Stream #0:2(kor): Subtitle: subrip (srt) (default)
MediaInfo parseFfmpegInfo(String text) {
  Duration? duration;
  final streams = <StreamInfo>[];
  // 스트림 줄 아래 Metadata 의 title 을 붙이기 위해 가변 값으로 모은다
  final pending = <Map<String, Object?>>[];
  var inInput0 = false;

  for (final line in const LineSplitter().convert(text)) {
    if (line.startsWith('Input #')) {
      inInput0 = line.startsWith('Input #0');
      continue;
    }
    if (!inInput0) continue;

    final d = _durationLine.firstMatch(line);
    if (d != null && duration == null) {
      final secs = int.parse(d[1]!) * 3600 + int.parse(d[2]!) * 60 + double.parse(d[3]!);
      duration = Duration(microseconds: (secs * 1e6).round());
      continue;
    }
    final m = _streamLine.firstMatch(line);
    if (m != null) {
      final res = _resolution.firstMatch('$line ');
      pending.add({
        'index': int.parse(m[1]!),
        'lang': m[2] ?? '',
        'type': m[3]!.toLowerCase(),
        'codec': m[4]!,
        'default': line.contains('(default)'),
        'w': res == null ? null : int.parse(res[1]!),
        'h': res == null ? null : int.parse(res[2]!),
        'title': null,
      });
      continue;
    }
    final t = _titleLine.firstMatch(line);
    if (t != null && pending.isNotEmpty && pending.last['title'] == null) {
      pending.last['title'] = t[1]!.trim();
    }
  }

  for (final s in pending) {
    final lang = s['lang'] as String;
    streams.add(StreamInfo(
      index: s['index'] as int,
      type: s['type'] as String,
      codec: s['codec'] as String,
      language: lang == 'und' ? '' : lang,
      title: s['title'] as String?,
      isDefault: s['default'] as bool,
      width: s['w'] as int?,
      height: s['h'] as int?,
    ));
  }
  return MediaInfo(duration: duration, streams: streams);
}

/// ffprobe JSON → MediaInfo (테스트를 위해 공개 함수로 분리)
MediaInfo parseProbeJson(String json) {
  final data = jsonDecode(json) as Map<String, dynamic>;
  final streams = <StreamInfo>[];
  for (final s in (data['streams'] as List? ?? const [])) {
    final m = s as Map<String, dynamic>;
    final tags = (m['tags'] as Map?)?.cast<String, dynamic>() ?? const {};
    final disp = (m['disposition'] as Map?)?.cast<String, dynamic>() ?? const {};
    streams.add(StreamInfo(
      index: m['index'] as int,
      type: (m['codec_type'] as String?) ?? 'unknown',
      codec: (m['codec_name'] as String?) ?? 'unknown',
      language: (tags['language'] ?? tags['LANGUAGE'] ?? '') as String,
      title: (tags['title'] ?? tags['TITLE']) as String?,
      isDefault: disp['default'] == 1,
      width: m['width'] as int?,
      height: m['height'] as int?,
    ));
  }
  final format = (data['format'] as Map?)?.cast<String, dynamic>();
  final secs = double.tryParse('${format?['duration'] ?? ''}');
  return MediaInfo(
    duration: secs == null ? null : Duration(microseconds: (secs * 1e6).round()),
    streams: streams,
  );
}
