import 'dart:io';

/// 종료가 어디서 오래 걸리는지 남기는 기록 (설정 폴더의 exit.log, 매번 새로 씀).
/// 종료가 느리다는 신고가 있을 때 이 파일로 어느 단계인지 바로 알 수 있다.
class ExitTrace {
  static String? file;
  static final _watch = Stopwatch();

  static void start() {
    _watch
      ..reset()
      ..start();
    _write('종료 시작 ${DateTime.now().toIso8601String()}', FileMode.write);
  }

  static void mark(String what) {
    if (!_watch.isRunning) return;
    _write('${_watch.elapsedMilliseconds.toString().padLeft(6)}ms  $what', FileMode.append);
  }

  static void _write(String line, FileMode mode) {
    final f = file;
    if (f == null) return;
    try {
      File(f).writeAsStringSync('$line\n', mode: mode, flush: true);
    } catch (_) {}
  }
}
