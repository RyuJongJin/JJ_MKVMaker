import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app/subtitle_editor_controller.dart';
import '../core/srt.dart';
import 'theme.dart';
import '../l10n/tr.dart';

/// CapCut 스타일 자막 타임라인.
///
/// - 빈 곳 클릭/드래그: 재생 위치 이동
/// - 자막 블록 드래그: 이동 / 양 끝 드래그: 시작·끝 조절
/// - 휠: 좌우 스크롤, Ctrl+휠: 확대·축소
class SubtitleTimeline extends StatefulWidget {
  final SubtitleEditorController editor;
  final ValueNotifier<Duration> position;
  final Duration duration;
  final bool followPlayhead;
  final ValueChanged<Duration> onSeek;
  final ValueChanged<Cue> onSelect;

  const SubtitleTimeline({
    super.key,
    required this.editor,
    required this.position,
    required this.duration,
    required this.followPlayhead,
    required this.onSeek,
    required this.onSelect,
  });

  @override
  State<SubtitleTimeline> createState() => _SubtitleTimelineState();
}

class _SubtitleTimelineState extends State<SubtitleTimeline> {
  /// 화면에 보이는 구간 길이 (초)
  double _window = 30;
  static const _minWindow = 3.0, _maxWindow = 600.0;

  /// 보이는 구간 시작 (초)
  double _viewStart = 0;

  static const _rulerH = 22.0, _blockTop = 30.0, _blockH = 44.0, _edge = 7.0;

  // 드래그 상태
  Cue? _dragCue;
  _DragMode _mode = _DragMode.move;
  Duration _origStart = Duration.zero, _origEnd = Duration.zero;
  double _dragDx = 0;

  double get _total => math.max(widget.duration.inMilliseconds / 1000.0, 1);

  @override
  void initState() {
    super.initState();
    widget.position.addListener(_follow);
  }

  @override
  void didUpdateWidget(covariant SubtitleTimeline old) {
    super.didUpdateWidget(old);
    if (old.position != widget.position) {
      old.position.removeListener(_follow);
      widget.position.addListener(_follow);
    }
  }

  @override
  void dispose() {
    widget.position.removeListener(_follow);
    super.dispose();
  }

  /// 재생 위치가 화면 밖으로 나가면 따라간다
  void _follow() {
    if (_dragCue != null) return;
    final pos = _sec(widget.position.value);
    // 재생 중에는 오른쪽 15% 여유를 두고 미리 넘기고, 멈춘 상태에서는 벗어났을 때만 이동
    final playing = widget.followPlayhead;
    if (pos < _viewStart || pos > _viewStart + _window * (playing ? 0.85 : 1.0)) {
      _setView(pos - _window * (playing ? 0.15 : 0.3));
    }
  }

  void _setView(double start) {
    final max = math.max(0.0, _total - _window * 0.5);
    final v = start.clamp(0.0, max).toDouble();
    if (v != _viewStart) setState(() => _viewStart = v);
  }

  static double _sec(Duration d) => d.inMicroseconds / 1e6;
  static Duration _dur(double s) => Duration(microseconds: (s * 1e6).round());

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, box) {
      final width = box.maxWidth;
      final pps = width / _window; // 초당 픽셀
      double x(Duration d) => (_sec(d) - _viewStart) * pps;
      Duration at(double px) => _dur(_viewStart + px / pps);

      return Listener(
        onPointerSignal: (e) {
          if (e is! PointerScrollEvent) return;
          final ctrl = HardwareKeyboard.instance.isControlPressed;
          if (ctrl) {
            // 마우스 위치를 기준으로 확대·축소
            final anchor = _viewStart + e.localPosition.dx / pps;
            final f = e.scrollDelta.dy > 0 ? 1.25 : 0.8;
            setState(() => _window = (_window * f).clamp(_minWindow, _maxWindow));
            _setView(anchor - e.localPosition.dx / (width / _window));
          } else {
            final d = (e.scrollDelta.dy != 0 ? e.scrollDelta.dy : e.scrollDelta.dx);
            _setView(_viewStart + d / pps);
          }
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (d) => widget.onSeek(at(d.localPosition.dx)),
          onHorizontalDragUpdate: (d) => widget.onSeek(at(d.localPosition.dx)),
          child: ClipRect(
            child: Stack(
              children: [
                Positioned.fill(
                  child: CustomPaint(
                    painter: _RulerPainter(
                        viewStart: _viewStart, window: _window, total: _total),
                  ),
                ),
                ListenableBuilder(
                  listenable: widget.editor,
                  builder: (_, _) => Stack(children: [
                    for (final c in widget.editor.cues)
                      if (_sec(c.end) >= _viewStart &&
                          _sec(c.start) <= _viewStart + _window)
                        _block(c, x(c.start), math.max(x(c.end) - x(c.start), 4), pps),
                  ]),
                ),
                // 재생 위치 선
                ValueListenableBuilder<Duration>(
                  valueListenable: widget.position,
                  builder: (_, pos, _) {
                    final px = x(pos);
                    if (px < -2 || px > width + 2) return const SizedBox();
                    return Positioned(
                      left: px - 1,
                      top: 0,
                      bottom: 0,
                      child: IgnorePointer(
                        child: Container(width: 2, color: Colors.white),
                      ),
                    );
                  },
                ),
                // 확대 정도 표시
                Positioned(
                  right: 8,
                  top: 3,
                  child: IgnorePointer(
                    child: Text(trf('보기 {0}초 · Ctrl+휠 확대/축소', [_window.toStringAsFixed(_window < 10 ? 1 : 0)]),
                        style: const TextStyle(fontSize: 10, color: JjColors.textDim)),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    });
  }

  Widget _block(Cue c, double left, double w, double pps) {
    final e = widget.editor;
    final sel = e.selected == c;
    final text = c.text.replaceAll('\n', ' ');

    void start(_DragMode m) {
      _dragCue = c;
      _mode = m;
      _origStart = c.start;
      _origEnd = c.end;
      _dragDx = 0;
      widget.onSelect(c);
    }

    void update(DragUpdateDetails d) {
      if (_dragCue != c) return;
      _dragDx += d.delta.dx;
      final dt = _dur(_dragDx / pps);
      switch (_mode) {
        case _DragMode.move:
          e.moveTo(c, _origStart + dt);
        case _DragMode.start:
          e.setStart(c, _origStart + dt);
        case _DragMode.end:
          e.setEnd(c, _origEnd + dt);
      }
    }

    void end(DragEndDetails _) => _dragCue = null;

    Widget handle(_DragMode m) => MouseRegion(
          cursor: SystemMouseCursors.resizeLeftRight,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onHorizontalDragStart: (_) => start(m),
            onHorizontalDragUpdate: update,
            onHorizontalDragEnd: end,
            child: SizedBox(
              width: _edge,
              child: sel
                  ? Center(
                      child: Container(
                          width: 2, height: 18, color: Colors.black.withValues(alpha: 0.6)))
                  : null,
            ),
          ),
        );

    return Positioned(
      left: left,
      top: _blockTop,
      width: w,
      height: _blockH,
      child: Container(
        decoration: BoxDecoration(
          color: sel ? JjColors.accent : JjColors.accent.withValues(alpha: 0.35),
          borderRadius: BorderRadius.circular(5),
          border: Border.all(
              color: sel ? Colors.white : JjColors.accent.withValues(alpha: 0.8),
              width: sel ? 1.5 : 1),
        ),
        child: Row(children: [
          if (w > _edge * 3) handle(_DragMode.start),
          Expanded(
            child: MouseRegion(
              cursor: SystemMouseCursors.move,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => widget.onSelect(c),
                onHorizontalDragStart: (_) => start(_DragMode.move),
                onHorizontalDragUpdate: update,
                onHorizontalDragEnd: end,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 4),
                  child: Text(
                    text,
                    maxLines: 2,
                    overflow: TextOverflow.clip,
                    style: TextStyle(
                        fontSize: 11,
                        height: 1.2,
                        color: sel ? Colors.black : JjColors.text),
                  ),
                ),
              ),
            ),
          ),
          if (w > _edge * 3) handle(_DragMode.end),
        ]),
      ),
    );
  }
}

enum _DragMode { move, start, end }

class _RulerPainter extends CustomPainter {
  final double viewStart, window, total;

  _RulerPainter({required this.viewStart, required this.window, required this.total});

  @override
  void paint(Canvas canvas, Size size) {
    final pps = size.width / window;
    canvas.drawRect(Offset.zero & size, Paint()..color = JjColors.bg);
    canvas.drawRect(Rect.fromLTWH(0, 0, size.width, _SubtitleTimelineState._rulerH),
        Paint()..color = JjColors.panel);

    // 영상 끝 이후는 어둡게
    final endX = (total - viewStart) * pps;
    if (endX < size.width) {
      canvas.drawRect(Rect.fromLTRB(math.max(endX, 0), 0, size.width, size.height),
          Paint()..color = Colors.black.withValues(alpha: 0.4));
    }

    // 눈금 간격: 화면에 10개 안팎
    const steps = [0.1, 0.5, 1.0, 2.0, 5.0, 10.0, 15.0, 30.0, 60.0, 120.0, 300.0];
    final step = steps.firstWhere((s) => window / s <= 12, orElse: () => 600);
    final minor = step / 5;
    final tick = Paint()..color = JjColors.textDim.withValues(alpha: 0.6);
    final tp = TextPainter(textDirection: TextDirection.ltr);

    var t = (viewStart / minor).floor() * minor;
    while (t <= viewStart + window) {
      final x = (t - viewStart) * pps;
      final major = ((t / step) - (t / step).round()).abs() < 1e-6;
      canvas.drawLine(Offset(x, major ? 8 : 15),
          Offset(x, _SubtitleTimelineState._rulerH), tick);
      if (major) {
        tp.text = TextSpan(
            text: _label(t, step),
            style: const TextStyle(fontSize: 10, color: JjColors.textDim));
        tp.layout();
        tp.paint(canvas, Offset(x + 3, 1));
      }
      t += minor;
    }
  }

  static String _label(double s, double step) {
    final m = (s ~/ 60), sec = s - m * 60;
    final ss = step < 1 ? sec.toStringAsFixed(1).padLeft(4, '0') : sec.round().toString().padLeft(2, '0');
    return '$m:$ss';
  }

  @override
  bool shouldRepaint(_RulerPainter o) =>
      o.viewStart != viewStart || o.window != window || o.total != total;
}
