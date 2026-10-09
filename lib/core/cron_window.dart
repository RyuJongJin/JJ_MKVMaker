/// 실시간 동기화의 동작 시간 (cron 과 같은 글: "분 시 일 월 요일").
///
/// 시간 창으로 쓴다: 시 · 일 · 월 · 요일이 맞는 "그 시간 동안" 동기화한다 (분은 무시, 1시간 단위).
/// 여러 줄이면 하나라도 맞으면 동작. 빈 목록 = 계속 (앱이 켜져 있는 동안 늘).
///
/// 예: "0 9-17 * * 1-5" 평일 9시~17시 59분, "0 0-5 * * *" 매일 0시~5시 59분, "0 */2 * * 0,6" 주말 2시간마다 1시간씩.
library;

import '../l10n/tr.dart';

/// cron 글 한 줄
class CronExpr {
  final Set<int> minutes, hours, days, months, weekdays;
  final bool dayStar, weekdayStar;
  final String text;

  CronExpr._(this.text, this.minutes, this.hours, this.days, this.months, this.weekdays, this.dayStar, this.weekdayStar);

  static const _dows = {'SUN': 0, 'MON': 1, 'TUE': 2, 'WED': 3, 'THU': 4, 'FRI': 5, 'SAT': 6};
  static const _mons = {
    'JAN': 1, 'FEB': 2, 'MAR': 3, 'APR': 4, 'MAY': 5, 'JUN': 6, //
    'JUL': 7, 'AUG': 8, 'SEP': 9, 'OCT': 10, 'NOV': 11, 'DEC': 12,
  };

  /// 잘못된 글이면 FormatException
  static CronExpr parse(String text) {
    final f = text.trim().split(RegExp(r'\s+'));
    if (f.length != 5) throw FormatException(tr('cron 은 다섯 칸입니다 (분 시 일 월 요일)'), text);
    final wd = _field(f[4], 0, 7, _dows).map((d) => d == 7 ? 0 : d).toSet();
    return CronExpr._(text.trim(), _field(f[0], 0, 59), _field(f[1], 0, 23), _field(f[2], 1, 31), _field(f[3], 1, 12, _mons),
        wd, f[2] == '*', f[4] == '*');
  }

  static CronExpr? tryParse(String text) {
    try {
      return parse(text);
    } on FormatException {
      return null;
    }
  }

  static Set<int> _field(String s, int lo, int hi, [Map<String, int> names = const {}]) {
    int num(String x) {
      final n = names[x.toUpperCase()] ?? int.tryParse(x);
      if (n == null || n < lo || n > hi) throw FormatException(trf('범위 밖 값: {0} ({1}~{2})', [x, lo, hi]));
      return n;
    }

    final out = <int>{};
    for (final part in s.split(',')) {
      final stepParts = part.split('/');
      if (stepParts.length > 2) throw FormatException(trf('잘못된 칸: {0}', [part]));
      final step = stepParts.length == 2 ? int.tryParse(stepParts[1]) : 1;
      if (step == null || step < 1) throw FormatException(trf('잘못된 간격: {0}', [part]));
      final range = stepParts[0];
      int a, b;
      if (range == '*') {
        a = lo;
        b = hi;
      } else if (range.contains('-')) {
        final r = range.split('-');
        if (r.length != 2) throw FormatException(trf('잘못된 범위: {0}', [part]));
        a = num(r[0]);
        b = num(r[1]);
        if (b < a) throw FormatException(trf('거꾸로 된 범위: {0}', [part]));
      } else {
        a = num(range);
        b = stepParts.length == 2 ? hi : a;
      }
      for (var v = a; v <= b; v += step) {
        out.add(v);
      }
    }
    return out;
  }

  /// [t] 가 이 줄의 시간 창 안인지 (시 · 일 · 월 · 요일. cron 처럼 일 · 요일을 둘 다 정하면 둘 중 하나만 맞아도 됨)
  bool activeAt(DateTime t) {
    if (!hours.contains(t.hour) || !months.contains(t.month)) return false;
    final dom = days.contains(t.day), dow = weekdays.contains(t.weekday % 7);
    if (dayStar || weekdayStar) return dom && dow;
    return dom || dow;
  }

  /// 시간 격자로 나타낼 수 있는지 (일 · 월이 * 일 때)
  bool get gridable => dayStar && months.length == 12;
}

/// 일정 (cron 여러 줄). 빈 목록 = 계속
bool scheduleActive(List<String> lines, DateTime t) {
  if (lines.isEmpty) return true;
  for (final l in lines) {
    final e = CronExpr.tryParse(l);
    if (e != null && e.activeAt(t)) return true;
  }
  return false;
}

/// 다음에 동작이 시작되는 때 (지금 동작 중이면 null, 8일 안에 없으면 null)
DateTime? scheduleNextStart(List<String> lines, DateTime now) {
  if (lines.isEmpty || scheduleActive(lines, now)) return null;
  var t = DateTime(now.year, now.month, now.day, now.hour).add(const Duration(hours: 1));
  for (var i = 0; i < 24 * 8; i++, t = t.add(const Duration(hours: 1))) {
    if (scheduleActive(lines, t)) return t;
  }
  return null;
}

/// 지금 동작 중이면 끝나는 때
DateTime? scheduleEnd(List<String> lines, DateTime now) {
  if (lines.isEmpty || !scheduleActive(lines, now)) return null;
  var t = DateTime(now.year, now.month, now.day, now.hour).add(const Duration(hours: 1));
  for (var i = 0; i < 24 * 8; i++, t = t.add(const Duration(hours: 1))) {
    if (!scheduleActive(lines, t)) return t;
  }
  return null;
}

/// 요일 (0 = 일요일) × 시 (0~23) 격자 칸: 요일 * 24 + 시
Set<int> gridFromCron(List<String> lines) {
  final out = <int>{};
  for (final l in lines) {
    final e = CronExpr.tryParse(l);
    if (e == null || !e.gridable) continue;
    for (final d in e.weekdays) {
      for (final h in e.hours) {
        out.add(d * 24 + h);
      }
    }
  }
  return out;
}

/// 격자 → cron 줄 (같은 시간대를 가진 요일끼리 한 줄)
List<String> cronFromGrid(Set<int> cells) {
  if (cells.length == 7 * 24) return const ['0 * * * *'];
  final byHours = <String, List<int>>{};
  for (var d = 0; d < 7; d++) {
    final hours = [for (var h = 0; h < 24; h++) if (cells.contains(d * 24 + h)) h];
    if (hours.isEmpty) continue;
    byHours.putIfAbsent(_ranges(hours, 23), () => []).add(d);
  }
  return [for (final e in byHours.entries) '0 ${e.key} * * ${_ranges(e.value, 6)}'];
}

/// [1,2,3,5] → "1-3,5" (전부면 *)
String _ranges(List<int> v, int max) {
  if (v.length == max + 1) return '*';
  final parts = <String>[];
  var i = 0;
  while (i < v.length) {
    var j = i;
    while (j + 1 < v.length && v[j + 1] == v[j] + 1) {
      j++;
    }
    parts.add(i == j ? '${v[i]}' : '${v[i]}-${v[j]}');
    i = j + 1;
  }
  return parts.join(',');
}
