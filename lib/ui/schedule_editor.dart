import 'package:flutter/material.dart';

import '../core/cron_window.dart';
import '../l10n/tr.dart';
import 'theme.dart';

/// 요일 이름 (0 = 일요일)
List<String> weekdayNames() => [tr('일'), tr('월'), tr('화'), tr('수'), tr('목'), tr('금'), tr('토')];

/// 일정 요약: "계속" · cron 줄 · 지금 상태 (동작 중 ~ 끝 / 다음 시작)
String scheduleSummary(List<String> lines, [DateTime? now]) {
  final t = now ?? DateTime.now();
  if (lines.isEmpty) return tr('계속 (앱이 켜져 있는 동안)');
  String hm(DateTime d) => '${weekdayNames()[d.weekday % 7]} ${d.hour.toString().padLeft(2, '0')}:00';
  final end = scheduleEnd(lines, t);
  if (scheduleActive(lines, t)) return trf('동작 중 · {0} 까지', [end == null ? '…' : hm(end)]);
  final next = scheduleNextStart(lines, t);
  return trf('대기 · 다음 시작 {0}', [next == null ? '-' : hm(next)]);
}

/// 일정 편집: 계속 / 시간 지정 (요일 × 시 격자를 누르거나 끌어서 칠하기, cron 글로도). 취소면 null.
Future<List<String>?> editSchedule(BuildContext context, List<String> initial) =>
    showDialog<List<String>>(context: context, builder: (_) => _ScheduleDialog(initial: initial));

class _ScheduleDialog extends StatefulWidget {
  final List<String> initial;
  const _ScheduleDialog({required this.initial});

  @override
  State<_ScheduleDialog> createState() => _ScheduleDialogState();
}

class _ScheduleDialogState extends State<_ScheduleDialog> {
  late bool _always = widget.initial.isEmpty;
  late Set<int> _cells = widget.initial.isEmpty ? {for (var d = 1; d <= 5; d++) for (var h = 9; h < 18; h++) d * 24 + h} : gridFromCron(widget.initial);

  /// 격자로 나타낼 수 없는 줄 (일 · 월을 정한 cron) 은 글로만 둔다
  late List<String> _extra = [for (final l in widget.initial) if (!(CronExpr.tryParse(l)?.gridable ?? false)) l];
  late final _text = TextEditingController(text: _lines.join('\n'));
  String? _error;

  List<String> get _lines => [...cronFromGrid(_cells), ..._extra];

  void _syncText() => _text.text = _lines.join('\n');

  void _set(Set<int> cells) {
    setState(() {
      _cells = cells;
      _error = null;
    });
    _syncText();
  }

  void _applyText() {
    final lines = _text.text.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).toList();
    for (final l in lines) {
      try {
        CronExpr.parse(l);
      } on FormatException catch (e) {
        setState(() => _error = '${e.message}: $l');
        return;
      }
    }
    setState(() {
      _cells = gridFromCron(lines);
      _extra = [for (final l in lines) if (!CronExpr.parse(l).gridable) l];
      _error = null;
    });
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final lines = _lines;
    return AlertDialog(
      title: Text(tr('동기화 시간')),
      content: SizedBox(
        width: 760,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Wrap(spacing: 8, children: [
              ChoiceChip(
                label: Text(tr('계속')),
                selected: _always,
                onSelected: (_) => setState(() => _always = true),
              ),
              ChoiceChip(
                label: Text(tr('시간 지정 (cron)')),
                selected: !_always,
                onSelected: (_) => setState(() => _always = false),
              ),
            ]),
            const SizedBox(height: 8),
            Text(
              _always
                  ? tr('앱이 켜져 있는 동안 늘 동기화합니다.')
                  : tr('칠한 시간에만 동기화하고, 그 밖의 시간에는 바뀐 것을 모아 두었다가 다음 시작 시간에 맞춥니다. '
                      '칸을 누르거나 끌어서 칠합니다 (요일 이름 · 시 숫자를 누르면 그 줄 전체).'),
              style: const TextStyle(fontSize: 12, color: JjColors.textDim),
            ),
            if (!_always) ...[
              const SizedBox(height: 10),
              _WeekGrid(cells: _cells, onChanged: _set),
              const SizedBox(height: 8),
              Wrap(spacing: 6, runSpacing: 6, children: [
                for (final (label, cells) in [
                  (tr('평일 9~18시'), {for (var d = 1; d <= 5; d++) for (var h = 9; h < 18; h++) d * 24 + h}),
                  (tr('밤 0~6시'), {for (var d = 0; d < 7; d++) for (var h = 0; h < 6; h++) d * 24 + h}),
                  (tr('주말 종일'), {for (final d in [0, 6]) for (var h = 0; h < 24; h++) d * 24 + h}),
                  (tr('매일 종일'), {for (var i = 0; i < 7 * 24; i++) i}),
                  (tr('모두 지우기'), <int>{}),
                ])
                  ActionChip(label: Text(label), onPressed: () => _set(cells)),
              ]),
              const SizedBox(height: 12),
              Text(tr('cron (분 시 일 월 요일) · 한 줄에 하나'), style: const TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 4),
              TextField(
                controller: _text,
                minLines: 2,
                maxLines: 5,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
                decoration: InputDecoration(
                  isDense: true,
                  border: const OutlineInputBorder(),
                  errorText: _error,
                  helperText: tr('예: 0 9-17 * * 1-5 (평일 9시~17시 59분) · 0 0-5 * * * (매일 0~5시). 분은 무시하고 1시간 단위'),
                  suffixIcon: IconButton(tooltip: tr('글을 격자에 반영'), icon: const Icon(Icons.check), onPressed: _applyText),
                ),
                onSubmitted: (_) => _applyText(),
              ),
              const SizedBox(height: 8),
              Text(lines.isEmpty ? tr('칠한 시간이 없어 동기화하지 않습니다.') : scheduleSummary(lines),
                  style: const TextStyle(fontSize: 12, color: JjColors.accent)),
            ],
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('취소'))),
        FilledButton(
          onPressed: _error != null ? null : () => Navigator.pop(context, _always ? const <String>[] : lines),
          child: Text(tr('저장')),
        ),
      ],
    );
  }
}

/// 요일 (세로 7) × 시 (가로 24) 격자. 누르면 켜기 · 끄기, 끌면 첫 칸의 반대로 칠하기.
class _WeekGrid extends StatefulWidget {
  final Set<int> cells;
  final ValueChanged<Set<int>> onChanged;
  const _WeekGrid({required this.cells, required this.onChanged});

  @override
  State<_WeekGrid> createState() => _WeekGridState();
}

class _WeekGridState extends State<_WeekGrid> {
  static const _label = 34.0, _head = 18.0, _rowH = 26.0;
  bool? _paint;
  Set<int> _work = {};

  int? _cellAt(Offset pos, double cellW) {
    final x = pos.dx - _label, y = pos.dy - _head;
    if (x < 0 || y < 0) return null;
    final h = (x / cellW).floor(), d = (y / _rowH).floor();
    if (h < 0 || h > 23 || d < 0 || d > 6) return null;
    return d * 24 + h;
  }

  void _toggleRow(int d) {
    final all = [for (var h = 0; h < 24; h++) d * 24 + h];
    final on = all.every(widget.cells.contains);
    widget.onChanged({...widget.cells}..removeAll(all)..addAll(on ? const [] : all));
  }

  void _toggleCol(int h) {
    final all = [for (var d = 0; d < 7; d++) d * 24 + h];
    final on = all.every(widget.cells.contains);
    widget.onChanged({...widget.cells}..removeAll(all)..addAll(on ? const [] : all));
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, box) {
        final cellW = (box.maxWidth - _label) / 24;
        final names = weekdayNames();
        void paintAt(Offset pos) {
          final i = _cellAt(pos, cellW);
          if (i == null || _paint == null) return;
          final next = {..._work};
          _paint! ? next.add(i) : next.remove(i);
          if (next.length != _work.length) {
            _work = next;
            widget.onChanged(next);
          }
        }

        return SizedBox(
          height: _head + _rowH * 7,
          child: Stack(children: [
            // 시 숫자 (누르면 그 시간 전체 요일)
            for (var h = 0; h < 24; h++)
              Positioned(
                left: _label + h * cellW,
                top: 0,
                width: cellW,
                height: _head,
                child: InkWell(
                  onTap: () => _toggleCol(h),
                  child: Center(
                    child: Text(h % 3 == 0 ? '$h' : '', style: const TextStyle(fontSize: 10, color: JjColors.textDim)),
                  ),
                ),
              ),
            // 요일 이름 (누르면 그 요일 전체)
            for (var d = 0; d < 7; d++)
              Positioned(
                left: 0,
                top: _head + d * _rowH,
                width: _label,
                height: _rowH,
                child: InkWell(
                  onTap: () => _toggleRow(d),
                  child: Center(
                    child: Text(names[d],
                        style: TextStyle(fontSize: 12, color: d == 0 ? Colors.redAccent : d == 6 ? Colors.lightBlueAccent : null)),
                  ),
                ),
              ),
            Positioned(
              left: _label,
              top: _head,
              right: 0,
              height: _rowH * 7,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapUp: (e) {
                  final i = _cellAt(e.localPosition + const Offset(_label, _head), cellW);
                  if (i == null) return;
                  final next = {...widget.cells};
                  next.contains(i) ? next.remove(i) : next.add(i);
                  widget.onChanged(next);
                },
                onPanStart: (e) {
                  final i = _cellAt(e.localPosition + const Offset(_label, _head), cellW);
                  _work = {...widget.cells};
                  _paint = i == null ? null : !widget.cells.contains(i);
                  paintAt(e.localPosition + const Offset(_label, _head));
                },
                onPanUpdate: (e) => paintAt(e.localPosition + const Offset(_label, _head)),
                onPanEnd: (_) => _paint = null,
                child: CustomPaint(painter: _GridPainter(widget.cells, cellW, _rowH)),
              ),
            ),
          ]),
        );
      });
}

class _GridPainter extends CustomPainter {
  final Set<int> cells;
  final double cellW, rowH;
  _GridPainter(this.cells, this.cellW, this.rowH);

  @override
  void paint(Canvas canvas, Size size) {
    final on = Paint()..color = JjColors.accent;
    final off = Paint()..color = JjColors.border.withValues(alpha: 0.45);
    for (var d = 0; d < 7; d++) {
      for (var h = 0; h < 24; h++) {
        final r = Rect.fromLTWH(h * cellW + 1, d * rowH + 1, cellW - 2, rowH - 2);
        canvas.drawRRect(RRect.fromRectAndRadius(r, const Radius.circular(3)), cells.contains(d * 24 + h) ? on : off);
      }
    }
  }

  @override
  bool shouldRepaint(_GridPainter old) => old.cells != cells || old.cellW != cellW;
}

/// 읽기 전용 작은 격자 (모니터링 · 설정의 목록에서 일정 한눈에)
class WeekGridPreview extends StatelessWidget {
  final List<String> lines;
  final double width;
  const WeekGridPreview({super.key, required this.lines, this.width = 168});

  @override
  Widget build(BuildContext context) {
    final cells = lines.isEmpty ? {for (var i = 0; i < 168; i++) i} : gridFromCron(lines);
    final cellW = width / 24;
    return SizedBox(
      width: width,
      height: cellW * 7 * 1.2,
      child: CustomPaint(painter: _GridPainter(cells, cellW, cellW * 1.2)),
    );
  }
}
