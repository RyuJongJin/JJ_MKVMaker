import 'dart:async';
import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:window_manager/window_manager.dart';

import '../app/app_controller.dart';
import '../core/playlist.dart';
import '../core/srt.dart' show formatSrtTime;
import '../services/media_player.dart';
import 'theme.dart';

/// 파일들을 재생 (외부 프로그램이 지정된 확장자면 그 프로그램으로)
Future<void> playFiles(BuildContext context, AppController c, List<String> files) async {
  final create = c.services.createMediaPlayer;
  final plan = await c.preparePlayback(files);
  if (plan == null || create == null || !context.mounted) return;
  final (list, start) = plan;
  await Navigator.of(context).push(MaterialPageRoute<void>(
    builder: (_) => PlayerPage(c: c, player: create(), files: list, start: start),
  ));
}

class PlayerPage extends StatefulWidget {
  final AppController c;
  final MediaPlayer player;
  final List<String> files;
  final int start;

  const PlayerPage({
    super.key,
    required this.c,
    required this.player,
    required this.files,
    this.start = 0,
  });

  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> {
  MediaPlayer get pl => widget.player;
  AppController get c => widget.c;

  bool _full = false, _popup = false, _showList = false;
  bool _controlsVisible = true;
  Timer? _hideTimer;
  double? _seekDrag;
  double _volumeBeforeMute = 100;
  int _subsForIndex = -1;
  List<String> _externalSubs = [];
  String? _error;
  final _menu = MenuController();
  final _focus = FocusNode();
  StreamSubscription<String>? _errSub;

  @override
  void initState() {
    super.initState();
    pl.open(widget.files, start: widget.start);
    pl.state.addListener(_onState);
    // 오류는 3초 뒤에도 실제로 재생이 안 될 때만 표시 (mpv 는 대체 방법으로 계속 재생하는 경우가 많음)
    _errSub = pl.errors.listen((e) {
      Future<void>.delayed(const Duration(seconds: 3), () {
        final s = pl.state.value;
        final stuck = s.position < const Duration(milliseconds: 500) && s.duration == Duration.zero;
        if (mounted && stuck) setState(() => _error = e);
      });
    });
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _errSub?.cancel();
    pl.state.removeListener(_onState);
    if (_full) c.services.shell.setFullScreen(false);
    if (_popup) c.services.shell.setPopup(false);
    pl.dispose();
    _focus.dispose();
    super.dispose();
  }

  /// 파일이 바뀌면 그 파일의 외부 자막 목록 다시 읽기
  void _onState() {
    final i = pl.state.value.index;
    if (i != _subsForIndex && i >= 0 && i < pl.playlist.length) {
      _subsForIndex = i;
      c.externalSubtitlesFor(pl.playlist[i]).then((s) {
        if (mounted) setState(() => _externalSubs = s);
      });
    }
  }

  String get _currentFile {
    final i = pl.state.value.index;
    return i >= 0 && i < pl.playlist.length ? pl.playlist[i] : '';
  }

  // ───────── 창 모드 ─────────

  Future<void> _toggleFull() async {
    final on = !_full;
    await c.services.shell.setFullScreen(on);
    setState(() {
      _full = on;
      _popup = false;
    });
    _poke();
  }

  Future<void> _togglePopup() async {
    final on = !_popup;
    await c.services.shell.setPopup(on);
    setState(() {
      _popup = on;
      _full = false;
      _showList = false;
    });
    _poke();
  }

  Future<void> _escape() async {
    if (_full) {
      await _toggleFull();
    } else if (_popup) {
      await _togglePopup();
    }
  }

  Future<void> _fit(double factor) async {
    final s = pl.state.value;
    if (_full) setState(() => _full = false);
    if (_popup) setState(() => _popup = false);
    await c.services.shell.fitVideo(s.width ?? 1280, s.height ?? 720, factor);
  }

  /// 조작 막대 보이기 (전체 화면·팝업에서는 2.5초 뒤 숨김)
  void _poke() {
    if (!_controlsVisible) setState(() => _controlsVisible = true);
    _hideTimer?.cancel();
    if (_full || _popup) {
      _hideTimer = Timer(const Duration(milliseconds: 2500), () {
        if (mounted && pl.state.value.playing) setState(() => _controlsVisible = false);
      });
    }
  }

  // ───────── 재생 조작 ─────────

  void _seekBy(int sec) {
    final s = pl.state.value;
    pl.seek(s.position + Duration(seconds: sec));
    _poke();
  }

  void _volumeBy(double d) {
    pl.setVolume(pl.state.value.volume + d);
    _poke();
  }

  void _toggleMute() {
    final v = pl.state.value.volume;
    if (v > 0) {
      _volumeBeforeMute = v;
      pl.setVolume(0);
    } else {
      pl.setVolume(_volumeBeforeMute == 0 ? 100 : _volumeBeforeMute);
    }
  }

  /// 자막 켜기/끄기 (끈 상태에서 켜면 첫 번째 자막)
  void _toggleSubtitles() {
    final s = pl.state.value;
    if (s.subtitleId != null) {
      pl.setSubtitleTrack(null);
    } else {
      final all = _subtitleChoices();
      if (all.isNotEmpty) pl.setSubtitleTrack(all.first);
    }
  }

  List<TrackInfo> _subtitleChoices() => [
        ...pl.state.value.subtitleTracks,
        for (final f in _externalSubs) TrackInfo('file:$f', p.basename(f), file: f),
      ];

  Future<void> _addDropped(List<String> paths) async {
    final videos = await collectVideos(paths,
        isDirectory: (x) => FileSystemEntity.isDirectory(x),
        listDir: (x) async => Directory(x).list().map((e) => e.path).toList());
    if (videos.isNotEmpty) await pl.add(videos);
    setState(() => _showList = true);
  }

  Map<ShortcutActivator, VoidCallback> get _keys => {
        const SingleActivator(LogicalKeyboardKey.space): () => pl.playOrPause(),
        const SingleActivator(LogicalKeyboardKey.arrowLeft): () => _seekBy(-10),
        const SingleActivator(LogicalKeyboardKey.arrowRight): () => _seekBy(10),
        const SingleActivator(LogicalKeyboardKey.arrowLeft, shift: true): () => _seekBy(-60),
        const SingleActivator(LogicalKeyboardKey.arrowRight, shift: true): () => _seekBy(60),
        const SingleActivator(LogicalKeyboardKey.arrowUp): () => _volumeBy(5),
        const SingleActivator(LogicalKeyboardKey.arrowDown): () => _volumeBy(-5),
        const SingleActivator(LogicalKeyboardKey.keyF): _toggleFull,
        const SingleActivator(LogicalKeyboardKey.enter): _toggleFull,
        const SingleActivator(LogicalKeyboardKey.escape): _escape,
        const SingleActivator(LogicalKeyboardKey.keyN): () => pl.next(),
        const SingleActivator(LogicalKeyboardKey.keyP): () => pl.previous(),
        const SingleActivator(LogicalKeyboardKey.keyM): _toggleMute,
        const SingleActivator(LogicalKeyboardKey.keyS): _toggleSubtitles,
        const SingleActivator(LogicalKeyboardKey.keyL): () => setState(() => _showList = !_showList),
      };

  // ───────── 화면 ─────────

  @override
  Widget build(BuildContext context) {
    final chrome = !_full && !_popup;
    return CallbackShortcuts(
      bindings: _keys,
      child: Focus(
        focusNode: _focus,
        autofocus: true,
        child: Scaffold(
          backgroundColor: Colors.black,
          body: DropTarget(
            onDragDone: (d) => _addDropped(d.files.map((f) => f.path).toList()),
            child: Column(children: [
              if (chrome) _header(),
              Expanded(
                child: Row(children: [
                  Expanded(child: _videoArea()),
                  if (_showList && !_popup) SizedBox(width: 300, child: _playlistPanel()),
                ]),
              ),
              if (chrome) _controls(),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _header() => Container(
        height: 44,
        color: JjColors.panel,
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Row(children: [
          IconButton(
            tooltip: '돌아가기',
            icon: const Icon(Icons.arrow_back),
            onPressed: () => Navigator.maybePop(context),
          ),
          Expanded(
            child: ValueListenableBuilder<PlayerState>(
              valueListenable: pl.state,
              builder: (_, s, _) => Text(
                '${p.basename(_currentFile)}   (${s.index + 1}/${pl.playlist.length})',
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 14),
              ),
            ),
          ),
        ]),
      );

  Widget _videoArea() {
    final hideCursor = (_full || _popup) && !_controlsVisible;
    Widget view = pl.buildView();
    if (_popup) view = DragToMoveArea(child: view);
    return MouseRegion(
      cursor: hideCursor ? SystemMouseCursors.none : MouseCursor.defer,
      onHover: (_) => _poke(),
      child: MenuAnchor(
        controller: _menu,
        menuChildren: _contextMenu(),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onDoubleTap: _toggleFull,
          onSecondaryTapDown: (d) => _menu.open(position: d.localPosition),
          child: Stack(fit: StackFit.expand, children: [
            view,
            if (_error != null)
              Positioned(
                top: 8,
                left: 8,
                right: 8,
                child: Container(
                  padding: const EdgeInsets.all(8),
                  color: JjColors.danger.withValues(alpha: 0.85),
                  child: Text('재생 오류: $_error', style: const TextStyle(color: Colors.white)),
                ),
              ),
            // 전체 화면 · 팝업: 위에 떠 있는 조작 막대
            if (!(!_full && !_popup))
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: AnimatedOpacity(
                  opacity: _controlsVisible ? 1 : 0,
                  duration: const Duration(milliseconds: 200),
                  child: IgnorePointer(ignoring: !_controlsVisible, child: _controls(compact: _popup)),
                ),
              ),
          ]),
        ),
      ),
    );
  }

  List<Widget> _contextMenu() {
    final s = pl.state.value;
    final subs = _subtitleChoices();
    final vlc = c.services.shell.vlcPath;
    Widget item(String label, VoidCallback? onTap, {String? key, bool checked = false}) => MenuItemButton(
          onPressed: onTap,
          leadingIcon: SizedBox(width: 18, child: checked ? const Icon(Icons.check, size: 16) : null),
          trailingIcon: key == null ? null : Text(key, style: const TextStyle(fontSize: 11, color: JjColors.textDim)),
          child: Text(label),
        );
    return [
      item(s.playing ? '일시정지' : '재생', () => pl.playOrPause(), key: 'Space'),
      item('정지', () => pl.stop()),
      item('이전', () => pl.previous(), key: 'P'),
      item('다음', () => pl.next(), key: 'N'),
      const Divider(height: 1),
      item('전체 화면', _toggleFull, key: 'F', checked: _full),
      item('팝업 보기', _togglePopup, checked: _popup),
      SubmenuButton(menuChildren: [
        for (final f in const [0.5, 1.0, 2.0, 4.0]) item('원본의 $f배', () => _fit(f)),
      ], child: const Text('화면 크기')),
      const Divider(height: 1),
      item('자막 보기', _toggleSubtitles, key: 'S', checked: s.subtitleId != null),
      SubmenuButton(menuChildren: [
        item('끄기', () => pl.setSubtitleTrack(null), checked: s.subtitleId == null),
        for (final t in subs) item(t.label, () => pl.setSubtitleTrack(t), checked: s.subtitleId == t.id),
      ], child: const Text('자막 선택')),
      if (s.audioTracks.length > 1)
        SubmenuButton(menuChildren: [
          for (final t in s.audioTracks) item(t.label, () => pl.setAudioTrack(t), checked: s.audioId == t.id),
        ], child: const Text('음성 선택')),
      SubmenuButton(menuChildren: [
        for (final r in const [0.5, 0.75, 1.0, 1.25, 1.5, 2.0])
          item('${r}x', () => pl.setRate(r), checked: s.rate == r),
      ], child: const Text('재생 속도')),
      item('재생 목록', () => setState(() => _showList = !_showList), key: 'L', checked: _showList),
      const Divider(height: 1),
      if (vlc != null) item('VLC 로 열기', () => c.services.shell.openExternal(vlc, [_currentFile])),
      item('기본 프로그램으로 열기', () => c.services.shell.openExternal('system', [_currentFile])),
    ];
  }

  Widget _controls({bool compact = false}) => ValueListenableBuilder<PlayerState>(
        valueListenable: pl.state,
        builder: (_, s, _) {
          final total = s.duration.inMilliseconds.toDouble();
          final pos = (_seekDrag ?? s.position.inMilliseconds.toDouble()).clamp(0.0, total <= 0 ? 1.0 : total);
          IconButton btn(IconData i, String tip, VoidCallback onTap, {double size = 22}) => IconButton(
                tooltip: tip,
                iconSize: size,
                visualDensity: VisualDensity.compact,
                color: Colors.white,
                onPressed: onTap,
                icon: Icon(i),
              );
          return Container(
            color: (_full || _popup) ? Colors.black.withValues(alpha: 0.6) : JjColors.panel,
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Row(children: [
                Text(formatSrtTime(Duration(milliseconds: pos.round())).substring(0, 8),
                    style: const TextStyle(fontSize: 12, color: Colors.white70, fontFamily: 'Consolas')),
                Expanded(
                  child: SliderTheme(
                    data: const SliderThemeData(trackHeight: 3, overlayShape: RoundSliderOverlayShape(overlayRadius: 10)),
                    child: Slider(
                      value: pos,
                      max: total <= 0 ? 1 : total,
                      onChanged: total <= 0 ? null : (v) => setState(() => _seekDrag = v),
                      onChangeEnd: (v) {
                        pl.seek(Duration(milliseconds: v.round()));
                        setState(() => _seekDrag = null);
                      },
                    ),
                  ),
                ),
                Text(formatSrtTime(s.duration).substring(0, 8),
                    style: const TextStyle(fontSize: 12, color: Colors.white70, fontFamily: 'Consolas')),
              ]),
              Row(children: [
                btn(Icons.skip_previous, '이전 (P)', () => pl.previous()),
                if (!compact) btn(Icons.replay_10, '10초 뒤로 (←)', () => _seekBy(-10)),
                btn(s.playing ? Icons.pause_circle_filled : Icons.play_circle_fill, '재생/일시정지 (Space)',
                    () => pl.playOrPause(), size: 34),
                btn(Icons.stop, '정지', () => pl.stop()),
                if (!compact) btn(Icons.forward_10, '10초 앞으로 (→)', () => _seekBy(10)),
                btn(Icons.skip_next, '다음 (N)', () => pl.next()),
                const SizedBox(width: 8),
                btn(s.volume == 0 ? Icons.volume_off : Icons.volume_up, '음소거 (M)', _toggleMute),
                if (!compact)
                  SizedBox(
                    width: 100,
                    child: Slider(value: s.volume.clamp(0, 100), max: 100, onChanged: (v) => pl.setVolume(v)),
                  ),
                const Spacer(),
                if (!compact) ...[
                  _menuButton(Icons.speed, '재생 속도', [
                    for (final r in const [0.5, 0.75, 1.0, 1.25, 1.5, 2.0])
                      (label: '${r}x', checked: s.rate == r, onTap: () => pl.setRate(r)),
                  ]),
                  _menuButton(Icons.subtitles, '자막 (S)', [
                    (label: '끄기', checked: s.subtitleId == null, onTap: () => pl.setSubtitleTrack(null)),
                    for (final t in _subtitleChoices())
                      (label: t.label, checked: s.subtitleId == t.id, onTap: () => pl.setSubtitleTrack(t)),
                  ]),
                  if (s.audioTracks.length > 1)
                    _menuButton(Icons.audiotrack, '음성', [
                      for (final t in s.audioTracks)
                        (label: t.label, checked: s.audioId == t.id, onTap: () => pl.setAudioTrack(t)),
                    ]),
                  btn(Icons.playlist_play, '재생 목록 (L)', () => setState(() => _showList = !_showList)),
                ],
                btn(_popup ? Icons.close_fullscreen : Icons.picture_in_picture_alt, _popup ? '팝업 끄기' : '팝업 보기',
                    _togglePopup),
                btn(_full ? Icons.fullscreen_exit : Icons.fullscreen, '전체 화면 (F)', _toggleFull),
              ]),
            ]),
          );
        },
      );

  Widget _menuButton(IconData icon, String tip,
          List<({String label, bool checked, VoidCallback onTap})> items) =>
      PopupMenuButton<int>(
        tooltip: tip,
        icon: Icon(icon, color: Colors.white, size: 22),
        itemBuilder: (_) => [
          for (var i = 0; i < items.length; i++)
            CheckedPopupMenuItem(value: i, checked: items[i].checked, child: Text(items[i].label)),
        ],
        onSelected: (i) => items[i].onTap(),
      );

  // Material 배경이어야 목록 항목의 선택 표시 · 누름 효과가 보인다
  Widget _playlistPanel() => Material(
        color: JjColors.panel,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 4, 6),
            child: Row(children: [
              Text('재생 목록 ${pl.playlist.length}개', style: const TextStyle(fontSize: 13)),
              const Spacer(),
              IconButton(
                iconSize: 18,
                tooltip: '닫기',
                icon: const Icon(Icons.close),
                onPressed: () => setState(() => _showList = false),
              ),
            ]),
          ),
          const Divider(height: 1),
          Expanded(
            child: ValueListenableBuilder<PlayerState>(
              valueListenable: pl.state,
              builder: (_, s, _) => ListView.builder(
                itemCount: pl.playlist.length,
                itemBuilder: (_, i) => ListTile(
                  dense: true,
                  selected: i == s.index,
                  leading: Icon(i == s.index ? Icons.play_arrow : Icons.movie_outlined, size: 18),
                  title: Text(p.basename(pl.playlist[i]), maxLines: 2, overflow: TextOverflow.ellipsis),
                  onTap: () => pl.jump(i),
                ),
              ),
            ),
          ),
          const Padding(
            padding: EdgeInsets.all(8),
            child: Text('동영상을 끌어다 놓으면 목록에 추가됩니다',
                textAlign: TextAlign.center, style: TextStyle(fontSize: 11, color: JjColors.textDim)),
          ),
        ]),
      );
}
