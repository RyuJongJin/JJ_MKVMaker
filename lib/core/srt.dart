/// SRT 자막 한 줄(큐)
class Cue {
  Duration start;
  Duration end;
  String text;

  Cue(this.start, this.end, this.text);

  Cue copy() => Cue(start, end, text);
}

final _timeLine = RegExp(
    r'(\d{1,2}):(\d{1,2}):(\d{1,2})[,.](\d{1,3})\s*-->\s*(\d{1,2}):(\d{1,2}):(\d{1,2})[,.](\d{1,3})');

/// SRT 텍스트 → 큐 목록. 번호 누락·빈 줄 불규칙·마침표 밀리초 등을 너그럽게 처리한다.
List<Cue> parseSrt(String text) {
  final src = text.replaceFirst('﻿', '').replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  final lines = src.split('\n');
  final cues = <Cue>[];
  Cue? cur;
  final buf = <String>[];

  void flush() {
    if (cur != null) {
      // 다음 큐 번호로 보이는 마지막 숫자 줄 제거
      while (buf.isNotEmpty && buf.last.trim().isEmpty) {
        buf.removeLast();
      }
      cur!.text = buf.join('\n');
      cues.add(cur!);
    }
    cur = null;
    buf.clear();
  }

  for (var i = 0; i < lines.length; i++) {
    final m = _timeLine.firstMatch(lines[i]);
    if (m != null) {
      // 바로 앞 줄이 번호였다면 이전 큐 본문에서 제외
      if (buf.isNotEmpty && RegExp(r'^\s*\d+\s*$').hasMatch(buf.last)) {
        buf.removeLast();
      }
      flush();
      cur = Cue(_dur(m, 1), _dur(m, 5), '');
      continue;
    }
    if (cur != null) buf.add(lines[i]);
  }
  flush();
  return cues;
}

Duration _dur(RegExpMatch m, int g) {
  final ms = m[g + 3]!.padRight(3, '0');
  return Duration(
    hours: int.parse(m[g]!),
    minutes: int.parse(m[g + 1]!),
    seconds: int.parse(m[g + 2]!),
    milliseconds: int.parse(ms),
  );
}

/// 큐 목록 → SRT 텍스트 (번호는 순서대로 다시 매김, 줄바꿈 CRLF)
String formatSrt(List<Cue> cues) {
  final sb = StringBuffer();
  for (var i = 0; i < cues.length; i++) {
    final c = cues[i];
    sb
      ..write('${i + 1}\r\n')
      ..write('${formatSrtTime(c.start)} --> ${formatSrtTime(c.end)}\r\n')
      ..write(c.text.replaceAll('\r\n', '\n').replaceAll('\n', '\r\n'))
      ..write('\r\n\r\n');
  }
  return sb.toString();
}

/// 00:01:02,345
String formatSrtTime(Duration d) {
  if (d.isNegative) d = Duration.zero;
  String two(int n) => n.toString().padLeft(2, '0');
  final ms = (d.inMilliseconds % 1000).toString().padLeft(3, '0');
  return '${two(d.inHours)}:${two(d.inMinutes % 60)}:${two(d.inSeconds % 60)},$ms';
}

final _timeInput = RegExp(r'^\s*(?:(\d{1,2}):)?(\d{1,2}):(\d{1,2})(?:[,.](\d{1,3}))?\s*$');

/// 화면 입력 → 시간. "00:01:02,345", "1:02.5", "01:02" 허용. 형식이 틀리면 null.
Duration? parseSrtTime(String s) {
  final m = _timeInput.firstMatch(s);
  if (m == null) return null;
  final min = int.parse(m[2]!), sec = int.parse(m[3]!);
  if (min > 59 || sec > 59) return null;
  return Duration(
    hours: int.parse(m[1] ?? '0'),
    minutes: min,
    seconds: sec,
    milliseconds: int.parse((m[4] ?? '0').padRight(3, '0')),
  );
}

/// 모든 큐의 시간을 [offset] 만큼 이동 (0 미만은 0으로)
void shiftCues(Iterable<Cue> cues, Duration offset) {
  for (final c in cues) {
    c.start = _clamp(c.start + offset);
    c.end = _clamp(c.end + offset);
  }
}

Duration _clamp(Duration d) => d.isNegative ? Duration.zero : d;

/// 시간 오류 검사: 끝 < 시작 인 큐 번호 (0부터)
List<int> invalidCues(List<Cue> cues) => [
      for (var i = 0; i < cues.length; i++)
        if (cues[i].end < cues[i].start) i,
    ];
