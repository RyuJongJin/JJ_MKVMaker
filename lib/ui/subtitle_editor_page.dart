import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../app/app_controller.dart';
import '../app/subtitle_editor_controller.dart';
import '../core/models.dart';
import '../core/srt.dart';
import '../core/text_codec.dart';
import '../services/preview_player.dart';
import 'app_actions.dart';
import 'theme.dart';
import 'timeline.dart';
import '../l10n/tr.dart';

/// 자막을 불러와 편집 화면을 연다.
Future<void> openSubtitleEditor(
    BuildContext context, AppController c, VideoItem v, SubtitleEntry s) async {
  final nav = Navigator.of(context);
  final messenger = ScaffoldMessenger.of(context);
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => const Center(child: CircularProgressIndicator()),
  );
  List<Cue> cues;
  try {
    cues = await c.loadCues(v, s);
  } catch (e) {
    nav.pop();
    messenger.showSnackBar(SnackBar(content: Text(trf('자막을 불러올 수 없습니다: {0}', [e]))));
    return;
  }
  nav.pop();
  final charset = s.kind == SubtitleKind.external && s.codec == 'srt'
      ? (s.charset ?? 'UTF-8')
      : 'UTF-8';
  await nav.push(MaterialPageRoute<void>(
    builder: (_) => SubtitleEditorPage(
      app: c,
      video: v,
      entry: s,
      editor: SubtitleEditorController(cues, saveCharset: charset),
      player: c.services.createPlayer?.call(),
    ),
  ));
}

class SubtitleEditorPage extends StatefulWidget {
  final AppController app;
  final VideoItem video;
  final SubtitleEntry entry;
  final SubtitleEditorController editor;

  /// 영상 재생기 (없으면 자막 표만 표시)
  final PreviewPlayer? player;

  const SubtitleEditorPage({
    super.key,
    required this.app,
    required this.video,
    required this.entry,
    required this.editor,
    this.player,
  });

  @override
  State<SubtitleEditorPage> createState() => _SubtitleEditorPageState();
}

class _SubtitleEditorPageState extends State<SubtitleEditorPage> {
  late SubtitleEntry _entry = widget.entry;
  final _shift = TextEditingController(text: '0');
  bool _saving = false;

  // 재생 상태
  final _position = ValueNotifier(Duration.zero);
  final _active = ValueNotifier<Cue?>(null);
  final _subs = <StreamSubscription<Object?>>[];
  Duration _duration = Duration.zero;
  bool _playing = false;
  double _rate = 1.0;
  String? _playerError;

  SubtitleEditorController get e => widget.editor;
  PreviewPlayer? get _pl => widget.player;

  @override
  void initState() {
    super.initState();
    final pl = _pl;
    if (pl == null) return;
    _subs
      ..add(pl.positionStream.listen((d) {
        _position.value = d;
        _updateActive();
      }))
      ..add(pl.durationStream.listen((d) => setState(() => _duration = d)))
      ..add(pl.playingStream.listen((b) => setState(() => _playing = b)))
      ..add(pl.errorStream.listen((m) => setState(() => _playerError = m)));
    e.addListener(_updateActive);
    pl.open(widget.video.path).catchError((Object err) {
      if (mounted) setState(() => _playerError = '$err');
    });
  }

  void _updateActive() {
    final list = e.activeAt(_position.value);
    _active.value = list.isEmpty ? null : list.first;
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    e.removeListener(_updateActive);
    _pl?.dispose();
    _position.dispose();
    _active.dispose();
    _shift.dispose();
    widget.editor.dispose();
    super.dispose();
  }

  // ───────── 재생 조작 ─────────

  void _seek(Duration d) {
    if (d.isNegative) d = Duration.zero;
    if (_duration > Duration.zero && d > _duration) d = _duration;
    _position.value = d; // 화면 즉시 반영
    _updateActive();
    _pl?.seek(d);
  }

  void _seekBy(int ms) => _seek(_position.value + Duration(milliseconds: ms));

  /// 줄 선택 + 그 줄 시작으로 이동
  void _selectCue(Cue c) {
    e.select(c);
    _seek(c.start);
  }

  void _playSelected() {
    final c = e.selected;
    if (c == null || _pl == null) return;
    _seek(c.start);
    if (!_playing) _pl!.playOrPause();
  }

  void _setStartHere() {
    final c = e.selected;
    if (c != null) e.setStart(c, _position.value);
  }

  void _setEndHere() {
    final c = e.selected;
    if (c != null) e.setEnd(c, _position.value);
  }

  void _alignHere() {
    final c = e.selected;
    if (c != null) e.alignFrom(c, _position.value);
  }

  void _insertHere() => e.insertAt(_position.value);

  Map<ShortcutActivator, VoidCallback> get _shortcuts => {
        const SingleActivator(LogicalKeyboardKey.space, control: true): () => _pl?.playOrPause(),
        const SingleActivator(LogicalKeyboardKey.arrowLeft, alt: true): () => _seekBy(-1000),
        const SingleActivator(LogicalKeyboardKey.arrowRight, alt: true): () => _seekBy(1000),
        const SingleActivator(LogicalKeyboardKey.arrowLeft, alt: true, shift: true): () => _seekBy(-100),
        const SingleActivator(LogicalKeyboardKey.arrowRight, alt: true, shift: true): () => _seekBy(100),
        const SingleActivator(LogicalKeyboardKey.f7): _insertHere,
        const SingleActivator(LogicalKeyboardKey.f8): _playSelected,
        const SingleActivator(LogicalKeyboardKey.f9): _setStartHere,
        const SingleActivator(LogicalKeyboardKey.f10): _setEndHere,
      };

  /// 표현할 수 없는 글자가 있으면 확인
  Future<bool> _confirmLoss() async {
    final lost = encodeText(formatSrt(e.cues), e.saveCharset).lostChars;
    if (lost == 0) return true;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('문자셋 경고')),
        content: Text(trf('{0} 로 표현할 수 없는 글자 {1}개가 ' '"?" 로 바뀝니다.\n계속 저장할까요? (UTF-8 을 권장합니다)', [saveCharsets[e.saveCharset], lost])),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('취소'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr('저장'))),
        ],
      ),
    );
    return ok ?? false;
  }

  Future<void> _save() async {
    if (!await _confirmLoss() || !mounted) return;
    setState(() => _saving = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final (path, _) = await widget.app
          .saveEdited(widget.video, _entry, e.cues, e.saveCharset);
      _entry = widget.video.subtitles
          .firstWhere((s) => s.path != null && p.equals(s.path!, path));
      e.markSaved();
      messenger.showSnackBar(
          SnackBar(content: Text(trf('저장했습니다: {0} (MKV 에 반영됨)', [p.basename(path)]))));
    } catch (err) {
      messenger.showSnackBar(SnackBar(content: Text(trf('저장 실패: {0}', [err]))));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _saveAs() async {
    if (!await _confirmLoss() || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    final name = '${widget.video.baseName}_${_entry.language.code}.srt';
    try {
      final (path, _) = await widget.app
          .saveCuesAs(widget.video, e.cues, e.saveCharset, name);
      if (path != null) {
        messenger.showSnackBar(SnackBar(content: Text(trf('저장했습니다: {0}', [path]))));
      }
    } catch (err) {
      messenger.showSnackBar(SnackBar(content: Text(trf('저장 실패: {0}', [err]))));
    }
  }

  Future<bool> _confirmLeave() async {
    if (!e.dirty) return true;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('저장하지 않은 변경')),
        content: Text(tr('변경 내용을 저장하지 않고 나갈까요?')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('계속 편집'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr('나가기'))),
        ],
      ),
    );
    return ok ?? false;
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: e,
      builder: (context, _) => PopScope(
        canPop: !e.dirty,
        onPopInvokedWithResult: (didPop, _) async {
          if (didPop) return;
          final nav = Navigator.of(context);
          if (await _confirmLeave()) {
            e.markSaved();
            nav.pop();
          }
        },
        child: CallbackShortcuts(
          bindings: _shortcuts,
          child: Focus(
            autofocus: true,
            child: Scaffold(
          body: Column(
            children: [
              _toolbar(context),
              _statusBar(),
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (_pl != null) ...[
                      Expanded(flex: 9, child: _videoPane()),
                      const VerticalDivider(width: 1),
                    ],
                    Expanded(flex: 11, child: _cueTable()),
                  ],
                ),
              ),
              if (_pl != null) ...[
                const Divider(height: 1),
                _transportBar(),
                SizedBox(
                  height: 104,
                  child: SubtitleTimeline(
                    editor: e,
                    position: _position,
                    duration: _duration,
                    followPlayhead: _playing,
                    onSeek: _seek,
                    onSelect: _selectCue,
                  ),
                ),
              ],
            ],
          ),
          floatingActionButton: e.cues.isEmpty
              ? FloatingActionButton.extended(
                  onPressed: () => e.insertAfter(-1),
                  icon: const Icon(Icons.add),
                  label: Text(tr('첫 줄 추가')),
                )
              : null,
            ),
          ),
        ),
      ),
    );
  }

  // ───────── 영상 · 자막 겹쳐 보기 ─────────

  Widget _videoPane() => Container(
        color: Colors.black,
        child: Stack(
          fit: StackFit.expand,
          children: [
            _pl!.buildView(),
            // 편집 중인 자막을 영상 위에 표시
            Positioned(
              left: 16,
              right: 16,
              bottom: 20,
              child: IgnorePointer(
                child: ValueListenableBuilder<Duration>(
                  valueListenable: _position,
                  builder: (_, pos, _) => ListenableBuilder(
                    listenable: e,
                    builder: (_, _) {
                      final text = e.activeAt(pos).map((c) => c.text).join('\n');
                      if (text.isEmpty) return const SizedBox();
                      return Center(
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                          color: Colors.black.withValues(alpha: 0.55),
                          child: Text(
                            text,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                                fontSize: 20, color: Colors.white, height: 1.3),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),
            if (_playerError != null)
              Positioned(
                left: 8,
                right: 8,
                top: 8,
                child: Container(
                  padding: const EdgeInsets.all(8),
                  color: JjColors.danger.withValues(alpha: 0.85),
                  child: Text(trf('영상 재생 오류: {0}', [_playerError]),
                      style: const TextStyle(fontSize: 12, color: Colors.white)),
                ),
              ),
          ],
        ),
      );

  Widget _cueTable() => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _HeaderRow(),
          const Divider(height: 1),
          Expanded(
            child: ValueListenableBuilder<Cue?>(
              valueListenable: _active,
              builder: (_, active, _) => ListView.builder(
                itemCount: e.cues.length,
                itemBuilder: (_, i) {
                  final c = e.cues[i];
                  return _CueRow(
                    key: ObjectKey(c),
                    index: i,
                    cue: c,
                    editor: e,
                    orderError: e.invalidOrder.contains(i),
                    selected: e.selected == c,
                    active: active == c,
                    onSelect: () => _selectCue(c),
                  );
                },
              ),
            ),
          ),
        ],
      );

  // ───────── 재생 조작 막대 ─────────

  Widget _transportBar() {
    final hasSel = e.selected != null;
    Widget btn(String label, String key, VoidCallback? onTap) => Padding(
          padding: const EdgeInsets.only(left: 6),
          child: Tooltip(
            message: key,
            child: OutlinedButton(
              style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  visualDensity: VisualDensity.compact),
              onPressed: onTap,
              child: Text(label, style: const TextStyle(fontSize: 12)),
            ),
          ),
        );

    return Container(
      height: 48,
      color: JjColors.panel,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        children: [
          IconButton(
            tooltip: tr('5초 뒤로'),
            icon: const Icon(Icons.replay_5),
            onPressed: () => _seekBy(-5000),
          ),
          IconButton(
            tooltip: tr('재생/정지 (Ctrl+Space)'),
            iconSize: 30,
            icon: Icon(_playing ? Icons.pause_circle : Icons.play_circle,
                color: JjColors.accent),
            onPressed: () => _pl?.playOrPause(),
          ),
          IconButton(
            tooltip: tr('5초 앞으로'),
            icon: const Icon(Icons.forward_5),
            onPressed: () => _seekBy(5000),
          ),
          const SizedBox(width: 6),
          ValueListenableBuilder<Duration>(
            valueListenable: _position,
            builder: (_, pos, _) => Text(
              '${formatSrtTime(pos)} / ${formatSrtTime(_duration)}',
              style: const TextStyle(fontFamily: 'Consolas', fontSize: 13),
            ),
          ),
          const SizedBox(width: 10),
          DropdownButton<double>(
            value: _rate,
            isDense: true,
            underline: const SizedBox(),
            style: const TextStyle(fontSize: 12, color: JjColors.text),
            items: [
              for (final r in const [0.5, 0.75, 1.0, 1.25, 1.5, 2.0])
                DropdownMenuItem(value: r, child: Text('${r}x')),
            ],
            onChanged: (r) {
              setState(() => _rate = r!);
              _pl?.setRate(r!);
            },
          ),
          // 폭이 좁으면 (휴대폰) 밀어서 본다. 넓으면 지금처럼 오른쪽에 붙는다 (reverse)
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              reverse: true,
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                btn(tr('+ 여기에 새 줄'), 'F7', _insertHere),
                btn(tr('선택 줄 재생'), 'F8', hasSel ? _playSelected : null),
                btn(tr('시작 = 현재'), 'F9', hasSel ? _setStartHere : null),
                btn(tr('끝 = 현재'), 'F10', hasSel ? _setEndHere : null),
                btn(tr('선택 줄부터 여기로 맞추기'), tr('선택한 줄과 그 뒤 모든 줄을 함께 이동'), hasSel ? _alignHere : null),
              ]),
            ),
          ),
        ],
      ),
    );
  }

  Widget _toolbar(BuildContext context) => Container(
        height: appBarHeight,
        color: JjColors.panel,
        padding: const EdgeInsets.only(left: 8, right: appBarRightPadding),
        child: Row(
          children: [
            const AppNavButtons(),
            const SizedBox(width: 4),
            Expanded(
              child: Text(
                trf('자막 편집 · {0}', [_entry.displayName]),
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
              ),
            ),
            // 폭이 좁으면 (휴대폰) 도구 줄을 밀어서 본다 - 설정 · 종료 버튼은 늘 오른쪽 끝에
            Flexible(
              flex: 4,
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  // 전체 싱크 이동
                  Text(tr('싱크'), style: TextStyle(fontSize: 12, color: JjColors.textDim)),
                  const SizedBox(width: 6),
                  SizedBox(
                    width: 80,
                    child: TextField(
                      controller: _shift,
                      textAlign: TextAlign.right,
                      style: const TextStyle(fontSize: 13),
                      decoration: const InputDecoration(
                          isDense: true, suffixText: 'ms', border: OutlineInputBorder()),
                    ),
                  ),
                  const SizedBox(width: 4),
                  OutlinedButton(
                    onPressed: () {
                      final ms = int.tryParse(_shift.text.trim());
                      if (ms == null) return;
                      e.shiftAll(ms);
                    },
                    child: Text(tr('전체 이동')),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton(onPressed: e.sortByTime, child: Text(tr('시간순 정렬'))),
                  const SizedBox(width: 12),
                  DropdownButton<String>(
                    value: e.saveCharset,
                    isDense: true,
                    underline: const SizedBox(),
                    style: const TextStyle(fontSize: 13, color: JjColors.text),
                    items: [
                      for (final c in saveCharsets.entries)
                        DropdownMenuItem(value: c.key, child: Text(c.value)),
                    ],
                    onChanged: (v) => e.setCharset(v!),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton(
                    onPressed: e.canSave ? _saveAs : null,
                    child: Text(tr('다른 이름으로 저장')),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    onPressed: e.canSave && !_saving ? _save : null,
                    icon: const Icon(Icons.save, size: 18),
                    label: Text(e.dirty ? tr('저장 (MKV 반영) *') : tr('저장 (MKV 반영)')),
                  ),
                ]),
              ),
            ),
            const AppActions(),
          ],
        ),
      );

  Widget _statusBar() {
    final order = e.invalidOrder;
    final msgs = <String>[
      trf('{0}줄', [e.cues.length]),
      if (e.badInput.isNotEmpty) trf('시간 형식 오류 {0}곳', [e.badInput.length]),
      if (order.isNotEmpty)
        trf('끝 시간이 시작보다 빠른 줄: {0}' '{1}', [order.take(10).map((i) => i + 1).join(', '), order.length > 10 ? ' …' : '']),
    ];
    final hasError = e.badInput.isNotEmpty || order.isNotEmpty;
    return Container(
      width: double.infinity,
      color: hasError ? JjColors.danger.withValues(alpha: 0.12) : JjColors.bg,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Text(msgs.join('   ·   '),
          style: TextStyle(
              fontSize: 12, color: hasError ? JjColors.danger : JjColors.textDim)),
    );
  }
}

class _HeaderRow extends StatelessWidget {
  const _HeaderRow();

  @override
  Widget build(BuildContext context) => Container(
        color: JjColors.panel,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(children: [
          SizedBox(width: 48, child: Text('#', style: _hdr)),
          SizedBox(width: 130, child: Text(tr('시작'), style: _hdr)),
          SizedBox(width: 130, child: Text(tr('끝'), style: _hdr)),
          Expanded(child: Text(tr('내용'), style: _hdr)),
          SizedBox(width: 96),
        ]),
      );
}

const _hdr = TextStyle(fontSize: 12, color: JjColors.textDim);

class _CueRow extends StatefulWidget {
  final int index;
  final Cue cue;
  final SubtitleEditorController editor;
  final bool orderError;
  final bool selected;

  /// 현재 재생 위치에서 표시 중인 줄
  final bool active;
  final VoidCallback? onSelect;

  const _CueRow({
    super.key,
    required this.index,
    required this.cue,
    required this.editor,
    required this.orderError,
    this.selected = false,
    this.active = false,
    this.onSelect,
  });

  @override
  State<_CueRow> createState() => _CueRowState();
}

class _CueRowState extends State<_CueRow> {
  late final _start = TextEditingController(text: formatSrtTime(widget.cue.start));
  late final _end = TextEditingController(text: formatSrtTime(widget.cue.end));
  late final _text = TextEditingController(text: widget.cue.text);
  final _startFocus = FocusNode();
  final _endFocus = FocusNode();
  bool _startBad = false, _endBad = false;

  @override
  void didUpdateWidget(covariant _CueRow old) {
    super.didUpdateWidget(old);
    // 전체 이동 등 바깥에서 바뀐 시간을 입력칸에 반영 (입력 중이 아닐 때만)
    if (!_startFocus.hasFocus && !_startBad) _sync(_start, formatSrtTime(widget.cue.start));
    if (!_endFocus.hasFocus && !_endBad) _sync(_end, formatSrtTime(widget.cue.end));
  }

  void _sync(TextEditingController c, String v) {
    if (c.text != v) c.text = v;
  }

  @override
  void dispose() {
    _start.dispose();
    _end.dispose();
    _text.dispose();
    _startFocus.dispose();
    _endFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final e = widget.editor;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      decoration: BoxDecoration(
        color: widget.orderError
            ? JjColors.danger.withValues(alpha: 0.08)
            : widget.selected
                ? JjColors.accent.withValues(alpha: 0.12)
                : null,
        border: Border(
          bottom: const BorderSide(color: JjColors.border),
          left: BorderSide(
              color: widget.active ? JjColors.accent : Colors.transparent, width: 3),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 48,
            child: InkWell(
              onTap: widget.onSelect,
              child: Padding(
                padding: const EdgeInsets.only(top: 10, bottom: 10),
                child: Text('${widget.index + 1}',
                    style: TextStyle(
                        fontSize: 12,
                        color: widget.selected ? JjColors.accent : JjColors.textDim)),
              ),
            ),
          ),
          SizedBox(width: 130, child: _timeField(_start, _startFocus, _startBad, true)),
          SizedBox(width: 130, child: _timeField(_end, _endFocus, _endBad, false)),
          Expanded(
            child: TextField(
              controller: _text,
              minLines: 1,
              maxLines: 4,
              style: const TextStyle(fontSize: 14),
              decoration: const InputDecoration(isDense: true, border: InputBorder.none),
              onTap: () => e.select(widget.cue),
              onChanged: (t) => e.setText(widget.cue, t),
            ),
          ),
          SizedBox(
            width: 96,
            child: Row(children: [
              IconButton(
                tooltip: tr('아래에 줄 추가'),
                iconSize: 18,
                icon: const Icon(Icons.add, color: JjColors.textDim),
                onPressed: () => e.insertAfter(widget.index),
              ),
              IconButton(
                tooltip: tr('줄 삭제'),
                iconSize: 18,
                icon: const Icon(Icons.delete_outline, color: JjColors.textDim),
                onPressed: () => e.removeAt(widget.index),
              ),
            ]),
          ),
        ],
      ),
    );
  }

  Widget _timeField(
      TextEditingController c, FocusNode f, bool bad, bool isStart) {
    return Padding(
      padding: const EdgeInsets.only(right: 10),
      child: TextField(
        controller: c,
        focusNode: f,
        style: const TextStyle(fontSize: 13, fontFamily: 'Consolas'),
        decoration: InputDecoration(
          isDense: true,
          border: InputBorder.none,
          errorText: bad ? tr('형식 오류') : null,
          errorStyle: const TextStyle(fontSize: 10),
        ),
        onTap: () => widget.editor.select(widget.cue),
        onChanged: (t) {
          final ok = widget.editor.setTime(widget.cue, t, isStart: isStart);
          setState(() {
            if (isStart) {
              _startBad = !ok;
            } else {
              _endBad = !ok;
            }
          });
        },
        onEditingComplete: () {
          // 입력을 마치면 표준 형식으로 정리
          final d = parseSrtTime(c.text);
          if (d != null) c.text = formatSrtTime(d);
          f.unfocus();
        },
      ),
    );
  }
}
