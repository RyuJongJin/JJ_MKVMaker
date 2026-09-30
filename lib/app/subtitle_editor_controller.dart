import 'package:flutter/foundation.dart';

import '../core/srt.dart';

/// 자막 편집 화면의 상태 (플랫폼 무관)
class SubtitleEditorController extends ChangeNotifier {
  final List<Cue> cues;

  /// 시간 입력 형식이 틀린 큐 (저장 막음)
  final Set<Cue> badInput = {};

  String saveCharset;
  bool dirty = false;

  SubtitleEditorController(this.cues, {required this.saveCharset});

  List<int> get invalidOrder => invalidCues(cues);

  bool get canSave => badInput.isEmpty && invalidOrder.isEmpty;

  void setText(Cue c, String text) {
    if (c.text == text) return;
    c.text = text;
    _changed();
  }

  /// 시간 입력. 형식이 틀리면 false.
  bool setTime(Cue c, String input, {required bool isStart}) {
    final d = parseSrtTime(input);
    if (d == null) {
      badInput.add(c);
      notifyListeners();
      return false;
    }
    badInput.remove(c);
    if (isStart) {
      c.start = d;
    } else {
      c.end = d;
    }
    _changed();
    return true;
  }

  /// [i] 번째 뒤에 새 줄 추가 (없으면 맨 앞). 앞 큐 끝 + 0.1초 부터 2초 길이.
  void insertAfter(int i) {
    final start = i >= 0 && i < cues.length
        ? cues[i].end + const Duration(milliseconds: 100)
        : Duration.zero;
    cues.insert(i + 1, Cue(start, start + const Duration(seconds: 2), ''));
    _changed();
  }

  void removeAt(int i) {
    final c = cues.removeAt(i);
    badInput.remove(c);
    if (selected == c) selected = null;
    _changed();
  }

  /// 전체 싱크 이동 (밀리초, 음수는 앞당김)
  void shiftAll(int ms) {
    if (ms == 0) return;
    shiftCues(cues, Duration(milliseconds: ms));
    _changed();
  }

  /// 시작 시간 순으로 정렬
  void sortByTime() {
    cues.sort((a, b) => a.start.compareTo(b.start));
    _changed();
  }

  // ───────── 싱크 편집 (3단계) ─────────

  /// 최소 자막 길이
  static const minLength = Duration(milliseconds: 100);

  /// 선택한 줄
  Cue? selected;

  void select(Cue? c) {
    if (selected == c) return;
    selected = c;
    notifyListeners();
  }

  /// [pos] 시점에 표시되는 줄들
  List<Cue> activeAt(Duration pos) =>
      [for (final c in cues) if (c.start <= pos && pos < c.end) c];

  /// 시작 시간 지정 (끝은 유지, 최소 길이 보장)
  void setStart(Cue c, Duration d) {
    d = _nonNeg(d);
    if (d > c.end - minLength) d = _nonNeg(c.end - minLength);
    c.start = d;
    badInput.remove(c);
    _changed();
  }

  /// 끝 시간 지정 (시작은 유지, 최소 길이 보장)
  void setEnd(Cue c, Duration d) {
    if (d < c.start + minLength) d = c.start + minLength;
    c.end = d;
    badInput.remove(c);
    _changed();
  }

  /// 길이를 유지한 채 시작 시간을 옮김
  void moveTo(Cue c, Duration start) {
    final len = c.end - c.start;
    c.start = _nonNeg(start);
    c.end = c.start + len;
    _changed();
  }

  /// [c] 와 그 뒤(시작 시간 기준)의 모든 줄을 함께 이동해 [c] 가 [start] 에서 시작하도록 맞춘다.
  /// 앞부분 싱크는 맞고 중간부터 어긋난 자막을 고칠 때 사용.
  void alignFrom(Cue c, Duration start) {
    final delta = _nonNeg(start) - c.start;
    if (delta == Duration.zero) return;
    final from = c.start;
    shiftCues(cues.where((e) => e.start >= from), delta);
    _changed();
  }

  /// [pos] 에서 시작하는 새 줄 추가 후 선택
  Cue insertAt(Duration pos) {
    final c = Cue(_nonNeg(pos), _nonNeg(pos) + const Duration(seconds: 2), '');
    var i = cues.indexWhere((e) => e.start > c.start);
    if (i < 0) i = cues.length;
    cues.insert(i, c);
    selected = c;
    _changed();
    return c;
  }

  static Duration _nonNeg(Duration d) => d.isNegative ? Duration.zero : d;

  void setCharset(String cs) {
    saveCharset = cs;
    notifyListeners();
  }

  void markSaved() {
    dirty = false;
    notifyListeners();
  }

  void _changed() {
    dirty = true;
    notifyListeners();
  }
}
