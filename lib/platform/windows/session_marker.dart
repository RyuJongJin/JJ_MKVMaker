import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// 지난 실행이 정상으로 끝났는지 알아내는 표시 (설정 폴더의 session.json).
///
/// 켤 때 "실행 중" 으로 적고 30초마다 살아 있는 시각을 고쳐 적는다. 종료 버튼 · 트레이 종료로 끝나면
/// "정상 종료" 로 바꾼다. 다음에 켤 때 "실행 중" 인 채로 남아 있으면 지난번은 비정상으로 끝난 것이다
/// (프로그램 오류 · 강제 종료 · 전원 꺼짐 등).
class SessionMarker {
  final String file;
  Timer? _beat;
  DateTime _start = DateTime.now();

  SessionMarker(this.file);

  /// 지난 실행이 비정상으로 끝났으면 (시작 시각, 마지막으로 살아 있던 시각), 아니면 null.
  /// 그리고 이번 실행을 "실행 중" 으로 적기 시작한다.
  (DateTime, DateTime)? start() {
    (DateTime, DateTime)? crashed;
    try {
      final f = File(file);
      if (f.existsSync()) {
        final j = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
        if (j['clean'] != true) {
          final s = DateTime.tryParse(j['start'] as String? ?? '');
          final seen = DateTime.tryParse(j['lastSeen'] as String? ?? '');
          if (s != null && seen != null) crashed = (s, seen);
        }
      }
    } catch (_) {}
    _start = DateTime.now();
    _write(clean: false);
    _beat?.cancel();
    _beat = Timer.periodic(const Duration(seconds: 30), (_) => _write(clean: false));
    return crashed;
  }

  /// 정상 종료로 표시 (종료 진행 창의 저장 단계에서)
  void markClean() {
    _beat?.cancel();
    _beat = null;
    _write(clean: true);
  }

  void _write({required bool clean}) {
    try {
      final tmp = File('$file.$pid.tmp')
        ..writeAsStringSync(jsonEncode({
          'pid': pid,
          'start': _start.toIso8601String(),
          'lastSeen': DateTime.now().toIso8601String(),
          'clean': clean,
        }), flush: true);
      tmp.renameSync(file);
    } catch (_) {}
  }
}
