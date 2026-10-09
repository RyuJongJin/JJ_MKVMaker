import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../app/app_controller.dart';
import '../core/reader_sources.dart';
import '../core/vfs.dart';
import '../l10n/tr.dart';
import 'ai_image_page.dart';
import 'ai_upscale_ui.dart';
import 'theme.dart';

/// 그림 · 만화 · PDF 보기를 연다. [start] 처음 볼 장. 닫으면 [source] 를 정리한다.
Future<void> openReader(BuildContext context, AppController c, ReaderSource source, {int start = 0}) async {
  await Navigator.of(context).push(MaterialPageRoute<void>(
    builder: (_) => ReaderPage(c: c, source: source, start: start),
  ));
  await source.dispose();
}

/// 보이는 한 쪽: 원본 [page] 장의 통째 (part -1) 또는 읽는 순서로 첫째 (0) · 둘째 (1) 반쪽 (119)
typedef ReaderSlot = ({int page, int part});

/// 그림 · 만화 · PDF 보기.
/// - 화면 오른쪽 (1/3) 을 누르면 다음 장, 왼쪽을 누르면 이전 장, 가운데를 누르면 위 · 아래 막대 보이기 · 숨기기
///   (오른쪽에서 왼쪽으로 넘기기를 켜면 반대). 좌우로 밀어도 넘어간다.
/// - 위 막대: 계속 보기 (117) · 두 쪽 나누기 (119) · 회전 · 상하 반전 (120) · 한 쪽 맞추기 · 좌우 맞추기, 넘기는 방향,
///   어둡게 · 밝게, (PDF) 페이지 지우기 · 그림 넣기 · 저장. 좁으면 못 들어간 버튼은 ⋮ 메뉴로.
class ReaderPage extends StatefulWidget {
  final AppController c;
  final ReaderSource source;
  final int start;
  const ReaderPage({super.key, required this.c, required this.source, this.start = 0});

  /// 계속 보기 동안 화면 켜 두기 (시험에서 바꿈)
  static Future<void> Function(bool on) keepScreenOn = (on) => on ? WakelockPlus.enable() : WakelockPlus.disable();

  @override
  State<ReaderPage> createState() => _ReaderPageState();
}

class _ReaderPageState extends State<ReaderPage> {
  AppController get c => widget.c;
  ReaderSource get src => widget.source;
  late final PageController _pages;

  /// 보는 쪽 ([_v] 의 번호)
  late int _index;
  bool _bars = true;
  final _cache = <int, Future<ReaderImage>>{};
  int _width = 0;

  /// PDF 는 페이지를 지우거나 넣으면 다시 그린다
  int _version = 0;

  @override
  void initState() {
    super.initState();
    _rebuildPages();
    final i = _v.indexWhere((e) => e.page == widget.start);
    _index = i < 0 ? 0 : i;
    _pages = PageController(initialPage: _index);
    _applySystemBars();
  }

  /// 보기 화면은 위 · 아래 시스템 막대까지 그림으로 (30: 설정으로 막대를 그대로 둘 수 있다)
  void _applySystemBars() => SystemChrome.setEnabledSystemUIMode(
      c.settings.readerSystemBars ? SystemUiMode.edgeToEdge : SystemUiMode.immersiveSticky);

  // ───────── 쪽 나누기 (119) · 회전 · 반전 (120) ─────────

  /// 보이는 쪽들
  List<ReaderSlot> _v = const [];
  ReaderSlot get _cur => _v.isEmpty ? (page: 0, part: -1) : _v[_index.clamp(0, _v.length - 1)];

  /// 원본 그림의 크기 (읽어 보고 안 것)
  final _dims = <int, Size>{};

  /// 시계 방향 90° 회전 수 · 상하 반전 (이 보기 화면을 닫을 때까지 모든 쪽에, 파일은 그대로)
  int _turns = 0;
  bool _flipV = false;

  /// 이 장을 반씩 나눠 볼지 (자동: 회전한 뒤 가로가 세로보다 긴 그림만)
  bool _splits(int page) {
    switch (c.settings.readerSplit) {
      case 'on':
        return true;
      case 'off':
        return false;
    }
    final d = _dims[page];
    if (d == null) return false;
    return _turns.isOdd ? d.height > d.width : d.width > d.height;
  }

  /// 보이는 쪽 목록을 다시 만든다. 보던 장은 그대로 보이게 (쪽 번호가 밀리면 그 자리로 옮긴다)
  void _rebuildPages() {
    final cur = _v.isEmpty ? null : _cur;
    _v = [
      for (var i = 0; i < src.length; i++)
        if (_splits(i)) ...[(page: i, part: 0), (page: i, part: 1)] else (page: i, part: -1),
    ];
    if (cur == null) return;
    int find(int part) => _v.indexWhere((e) => e.page == cur.page && e.part == part);
    var to = find(cur.part);
    if (to < 0) to = find(cur.part < 0 ? 0 : -1);
    if (to < 0) to = _index.clamp(0, math.max(0, _v.length - 1));
    if (to != _index) {
      _index = to;
      _jumpLater();
    }
  }

  void _jumpLater() => WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _pages.hasClients && _pages.page?.round() != _index) _pages.jumpToPage(_index);
      });

  /// 읽은 그림의 크기를 기억한다 (자동 나누기 판단)
  void _learn(int page, ReaderImage r) {
    if (_dims.containsKey(page)) return;
    final v = _version;
    unawaited(_sizeOf(r).then((size) {
      if (!mounted || size == null || v != _version || _dims.containsKey(page)) return;
      _dims[page] = size;
      if (c.settings.readerSplit == 'auto') setState(_rebuildPages);
    }));
  }

  static Future<Size?> _sizeOf(ReaderImage r) {
    final img = r.image;
    if (img != null) return Future.value(Size(img.width.toDouble(), img.height.toDouble()));
    final provider = r.provider;
    if (provider == null) return Future.value(null);
    final done = Completer<Size?>();
    final stream = provider.resolve(ImageConfiguration.empty);
    late final ImageStreamListener l;
    l = ImageStreamListener((info, _) {
      if (!done.isCompleted) done.complete(Size(info.image.width.toDouble(), info.image.height.toDouble()));
      info.dispose();
      stream.removeListener(l);
    }, onError: (_, _) {
      if (!done.isCompleted) done.complete(null);
      stream.removeListener(l);
    });
    stream.addListener(l);
    return done.future;
  }

  void _rotate(int d) => setState(() {
        _turns = (_turns + d) % 4;
        _resetZoom();
        _rebuildPages();
      });

  Future<void> _cycleSplit() async {
    await c.updateSettings((x) => x.readerSplit = switch (x.readerSplit) { 'auto' => 'on', 'on' => 'off', _ => 'auto' });
    if (!mounted) return;
    setState(() {
      _resetZoom();
      _rebuildPages();
    });
  }

  // ───────── 계속 보기 (117) ─────────

  bool _playing = false;
  Timer? _timer;

  /// 계속 보기를 멈추게 한 누름은 장 넘기기 · 막대 숨기기로 쓰지 않는다
  bool _swallowTap = false;

  void _play(bool on) {
    _timer?.cancel();
    _timer = null;
    if (on && _v.isNotEmpty) {
      _timer = Timer.periodic(Duration(seconds: c.settings.readerAutoSeconds), (_) => _tick());
    }
    if (on == _playing) return;
    setState(() => _playing = on);
    unawaited(ReaderPage.keepScreenOn(on).catchError((_) {}));
  }

  void _tick() {
    if (!mounted) return;
    if (_index >= _v.length - 1) {
      _play(false);
      _snack(tr('마지막 장이라 계속 보기를 멈췄습니다.'));
      return;
    }
    _pages.jumpToPage(_index + 1);
  }

  Future<void> _setSeconds(int d) async {
    await c.updateSettings((x) => x.readerAutoSeconds = (x.readerAutoSeconds + d).clamp(1, 60));
    if (!mounted) return;
    setState(() {});
    if (_playing) _play(true); // 새 간격으로
  }

  // ───────── 확대 (30) ─────────

  /// 쪽마다 확대 상태 (보는 쪽만 쓰고, 쪽을 넘기면 원래대로)
  final _zoom = <int, TransformationController>{};
  TransformationController _zoomOf(int i) => _zoom.putIfAbsent(i, TransformationController.new);

  /// 확대해 보고 있는지 (그동안은 밀어도 장이 넘어가지 않고 그림을 옮긴다)
  bool _zoomed = false;

  /// 화면에 닿은 손가락 수: 둘이면 (벌리고 오므리기) 옆으로 움직여도 장을 넘기지 않고 확대 · 축소
  int _fingers = 0;
  bool get _pinching => _fingers >= 2;
  void _finger(int d) {
    final was = _pinching;
    _fingers = math.max(0, _fingers + d);
    if (was != _pinching) setState(() {});
  }

  bool get _holdPage => _zoomed || _pinching;

  /// 확대한 배율에 맞춰 더 크게 다시 그린 쪽 (흐릿하지 않게)
  final _sharp = <int, Future<ReaderImage>>{};
  final _sharpWidth = <int, int>{};

  /// 반쪽은 두 배 너비로 읽는다 (반쪽이 화면 가득이어도 원본 해상도로)
  int _baseWidth(ReaderSlot s) => s.part >= 0 ? math.min(_width * 2, 8192) : _width;

  void _onZoomEnd(int i) {
    final s = _zoomOf(i).value.getMaxScaleOnAxis();
    final zoomed = s > 1.01;
    if (zoomed != _zoomed) setState(() => _zoomed = zoomed);
    if (s < 1.3 || i >= _v.length) return;
    final slot = _v[i];
    final base = _baseWidth(slot);
    final want = (base * s).round().clamp(base, 8192);
    if (want <= (_sharpWidth[i] ?? base) * 1.2) return;
    _sharpWidth[i] = want;
    final old = _sharp[i];
    setState(() {
      _sharp[i] = src.load(slot.page, maxWidth: want);
    });
    if (old != null) unawaited(old.then((x) => x.dispose(), onError: (_) {}));
  }

  void _resetZoom() {
    for (final z in _zoom.values) {
      z.dispose();
    }
    _zoom.clear();
    for (final f in _sharp.values) {
      unawaited(f.then((x) => x.dispose(), onError: (_) {}));
    }
    _sharp.clear();
    _sharpWidth.clear();
    _zoomed = false;
  }

  @override
  void dispose() {
    _timer?.cancel();
    if (_playing) unawaited(ReaderPage.keepScreenOn(false).catchError((_) {}));
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    for (final f in [..._cache.values, ..._cacheHalf.values]) {
      unawaited(f.then((x) => x.dispose(), onError: (_) {}));
    }
    _resetZoom();
    _pages.dispose();
    super.dispose();
  }

  Future<ReaderImage> _load(int page) => _cache.putIfAbsent(page, () {
        final f = src.load(page, maxWidth: _width);
        f.then((r) {
          if (mounted) _learn(page, r);
        }, onError: (_) {});
        return f;
      });

  /// 반쪽으로 보는 장 (두 배 너비)
  final _cacheHalf = <int, Future<ReaderImage>>{};
  Future<ReaderImage> _loadHalf(int page) =>
      _cacheHalf.putIfAbsent(page, () => src.load(page, maxWidth: math.min(_width * 2, 8192)));

  /// 보는 장 가까이만 남기고 (메모리) 다음 장은 미리 읽는다. 앞 장도 크기를 알아 둔다 (자동 나누기로 쪽 번호가 밀리지 않게)
  void _trim() {
    final page = _cur.page;
    for (final m in [_cache, _cacheHalf]) {
      for (final k in m.keys.toList()) {
        if ((k - page).abs() > 3) {
          unawaited(m.remove(k)!.then((x) => x.dispose(), onError: (_) {}));
        }
      }
    }
    for (final n in [page + 1, page - 1]) {
      if (n >= 0 && n < src.length) unawaited(_load(n).then((_) {}, onError: (_) {}));
    }
  }

  /// 다시 읽기 (PDF 페이지를 바꿨을 때). [page] 를 보던 자리로
  void _reset({int? page}) {
    final keep = page ?? _cur.page;
    for (final f in [..._cache.values, ..._cacheHalf.values]) {
      unawaited(f.then((x) => x.dispose(), onError: (_) {}));
    }
    _cache.clear();
    _cacheHalf.clear();
    _dims.clear();
    _resetZoom();
    _version++;
    _v = const [];
    _rebuildPages();
    final i = _v.indexWhere((e) => e.page == keep.clamp(0, math.max(0, src.length - 1)));
    _index = i < 0 ? 0 : i;
    _jumpLater();
  }

  void _go(int delta) {
    final to = (_index + delta).clamp(0, math.max(0, _v.length - 1)).toInt();
    if (to == _index) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
          duration: const Duration(seconds: 1), content: Text(delta > 0 ? tr('마지막 장입니다.') : tr('첫 장입니다.'))));
      return;
    }
    _pages.jumpToPage(to);
  }

  void _onTap(TapUpDetails d, double width) {
    if (_swallowTap) {
      _swallowTap = false;
      return;
    }
    final x = d.localPosition.dx;
    final rtl = c.settings.readerRtl;
    if (x > width * 2 / 3) {
      _go(rtl ? -1 : 1);
    } else if (x < width / 3) {
      _go(rtl ? 1 : -1);
    } else {
      setState(() => _bars = !_bars);
    }
  }

  /// 그림을 누르거나 밀면 계속 보기를 멈춘다 (117)
  void _onPointerDown() {
    _finger(1);
    _swallowTap = _playing;
    if (_playing) {
      _play(false);
      _snack(tr('계속 보기를 멈췄습니다.'));
    }
  }

  ColorFilter _brightness(double b) {
    final double s = 1 + math.min(b, 0.0);
    final double o = math.max(b, 0.0) * 160;
    return ColorFilter.matrix(<double>[s, 0, 0, 0, o, 0, s, 0, 0, o, 0, 0, s, 0, o, 0, 0, 0, 1, 0]);
  }

  Widget _page(int i, Size box) {
    final fit = c.settings.readerFit;
    final slot = _v[i];
    final half = slot.part >= 0;
    Widget failed(Object? e) => SizedBox(
        width: 320,
        height: 120,
        child: Center(child: Text(trf('열 수 없습니다: {0}', [e]), style: const TextStyle(color: Colors.white70))));
    // 확대해 다시 그린 것이 있으면 그것 (다 그릴 때까지는 앞의 그림을 그대로 보인다)
    final page = FutureBuilder<ReaderImage>(
      key: ValueKey('$_version:${slot.page}:${slot.part}'),
      future: _sharp[i] ?? (half ? _loadHalf(slot.page) : _load(slot.page)),
      builder: (context, snap) {
        if (snap.hasError) return Center(child: failed(snap.error));
        final r = snap.data;
        if (r == null) return const Center(child: CircularProgressIndicator());
        Widget picture = r.image != null
            ? RawImage(image: r.image, filterQuality: FilterQuality.medium)
            : Image(image: r.provider!, gaplessPlayback: true, filterQuality: FilterQuality.medium,
                errorBuilder: (_, e, _) => failed(e));
        // 120: 회전 · 상하 반전 (보기만, 파일은 그대로)
        if (_turns != 0) picture = RotatedBox(quarterTurns: _turns, child: picture);
        if (_flipV) picture = Transform.flip(flipY: true, child: picture);
        // 119: 반쪽 - 읽는 방향의 쪽부터 (오른쪽 → 왼쪽이면 오른쪽 반이 먼저)
        if (half) {
          final right = (slot.part == 0) == c.settings.readerRtl;
          picture = ClipRect(
            child: Align(
                alignment: right ? Alignment.centerRight : Alignment.centerLeft, widthFactor: 0.5, child: picture),
          );
        }
        if (fit == 'width') {
          return SingleChildScrollView(
              physics: _holdPage ? const NeverScrollableScrollPhysics() : null,
              child: SizedBox(width: box.width, child: FittedBox(fit: BoxFit.fitWidth, child: picture)));
        }
        return SizedBox.expand(child: FittedBox(fit: BoxFit.contain, child: picture));
      },
    );
    // 30: 두 손가락으로 확대 · 축소 (확대했을 때만 그림을 끌어 옮긴다)
    return InteractiveViewer(
      transformationController: _zoomOf(i),
      minScale: 1,
      maxScale: 6,
      panEnabled: _zoomed,
      onInteractionUpdate: (_) {
        final z = _zoomOf(i).value.getMaxScaleOnAxis() > 1.01;
        if (z != _zoomed) setState(() => _zoomed = z);
      },
      onInteractionEnd: (_) => _onZoomEnd(i),
      child: page,
    );
  }

  Future<void> _updateSettings(void Function(dynamic s) f) async {
    await c.updateSettings((s) => f(s));
    if (mounted) setState(() {});
  }

  // ───────── PDF 편집 ─────────

  PdfSource? get _pdf => src is PdfSource ? src as PdfSource : null;

  Future<void> _deletePage() async {
    final pdf = _pdf!;
    if (pdf.length <= 1) {
      _snack(tr('마지막 한 페이지는 지울 수 없습니다.'));
      return;
    }
    final page = _cur.page;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('페이지 지우기')),
        content: Text(trf('{0} 페이지를 지울까요? (저장해야 파일에 반영됩니다)', [page + 1])),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('취소'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr('지우기'))),
        ],
      ),
    );
    if (ok != true) return;
    await pdf.deletePage(page);
    if (!mounted) return;
    setState(() => _reset(page: page));
  }

  Future<void> _insertImages() async {
    final pdf = _pdf!;
    final page = _cur.page;
    final files = await c.services.storage.pickFiles(title: tr('PDF 에 넣을 그림 선택'), extensions: c.settings.imageExts);
    if (files.isEmpty || !mounted) return;
    final temp = await c.services.storage.tempDirectory();
    try {
      await pdf.insertImages(files, after: page, tempDir: temp);
    } catch (e) {
      _snack(trf('넣지 못했습니다: {0}', [e]));
      return;
    }
    setState(() => _reset(page: page));
    _snack(trf('그림 {0}장을 {1} 페이지 뒤에 넣었습니다 (저장해야 파일에 반영됩니다).', [files.length, page + 1]));
  }

  Future<void> _save() async {
    try {
      final path = await _pdf!.save();
      _snack(trf('저장했습니다: {0}', [vDisplay(path)]));
      setState(() {});
    } catch (e) {
      _snack(trf('저장하지 못했습니다: {0}', [e]));
    }
  }

  Future<bool> _confirmLeave() async {
    final pdf = _pdf;
    if (pdf == null || !pdf.dirty) return true;
    final r = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('저장하지 않은 변경')),
        content: Text(tr('페이지를 바꾼 것을 저장할까요?')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, 'cancel'), child: Text(tr('취소'))),
          TextButton(onPressed: () => Navigator.pop(ctx, 'discard'), child: Text(tr('저장 안 함'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, 'save'), child: Text(tr('저장'))),
        ],
      ),
    );
    if (r == 'save') await _save();
    return r == 'save' || r == 'discard';
  }

  void _snack(String text) {
    if (!mounted) return;
    final m = ScaffoldMessenger.maybeOf(context);
    m?.hideCurrentSnackBar();
    m?.showSnackBar(SnackBar(duration: const Duration(seconds: 2), content: Text(text)));
  }

  // ───────── 화면 ─────────

  /// 위 막대의 버튼들 (앞의 것일수록 먼저 보이고, 못 들어가면 ⋮ 메뉴로)
  List<_BarItem> _barItems() {
    final s = c.settings;
    final pdf = _pdf;
    final secs = s.readerAutoSeconds;
    _BarItem one(_Act a) => _BarItem(48, [a]);
    final split = switch (s.readerSplit) {
      'on' => tr('두 쪽 나눠 보기: 켜기 (누르면 끄기)'),
      'off' => tr('두 쪽 나눠 보기: 끄기 (누르면 자동)'),
      _ => tr('두 쪽 나눠 보기: 자동 - 가로로 긴 그림만 (누르면 켜기)'),
    };
    return [
      // 117: 계속 보기 · 간격 (▲ 늘리기 · ▼ 줄이기)
      one(_Act(Icon(_playing ? Icons.pause : Icons.play_arrow),
          _playing ? tr('계속 보기 멈추기') : trf('계속 보기 ({0}초마다 다음 장)', [secs]), () => _play(!_playing),
          on: _playing)),
      _BarItem(112, [
        _Act(const Icon(Icons.keyboard_arrow_up), trf('계속 보기 간격 늘리기 (지금 {0}초)', [secs]),
            secs < 60 ? () => _setSeconds(1) : null),
        _Act(const Icon(Icons.keyboard_arrow_down), trf('계속 보기 간격 줄이기 (지금 {0}초)', [secs]),
            secs > 1 ? () => _setSeconds(-1) : null),
      ], seconds: secs),
      if (pdf != null) ...[
        one(_Act(const Icon(Icons.save_outlined), tr('저장'), pdf.dirty ? _save : null)),
        one(_Act(const Icon(Icons.delete_outline), tr('이 페이지 지우기'), _deletePage)),
        one(_Act(const Icon(Icons.add_photo_alternate_outlined), tr('그림을 페이지로 넣기 (이 페이지 뒤)'), _insertImages)),
      ],
      // 119 · 120
      one(_Act(const Icon(Icons.vertical_split_outlined), split, _cycleSplit, on: s.readerSplit != 'off')),
      one(_Act(const Icon(Icons.rotate_right), tr('90° 회전 (시계 방향)'), () => _rotate(1), on: _turns != 0)),
      one(_Act(const Icon(Icons.rotate_left), tr('반대로 90° 회전'), () => _rotate(3), on: _turns != 0)),
      one(_Act(const RotatedBox(quarterTurns: 1, child: Icon(Icons.flip)), tr('상하 반전'),
          () => setState(() => _flipV = !_flipV), on: _flipV)),
      one(_Act(const Icon(Icons.fit_screen_outlined), tr('한 쪽 맞추기'), () => _updateSettings((x) => x.readerFit = 'page'),
          on: s.readerFit == 'page')),
      one(_Act(const Icon(Icons.width_full_outlined), tr('좌우 맞추기 (세로로 밀어 봄)'),
          () => _updateSettings((x) => x.readerFit = 'width'), on: s.readerFit == 'width')),
      one(_Act(const Icon(Icons.swap_horiz),
          s.readerRtl ? tr('넘기는 방향: 오른쪽 → 왼쪽 (만화)') : tr('넘기는 방향: 왼쪽 → 오른쪽'),
          () => _updateSettings((x) => x.readerRtl = !x.readerRtl), on: s.readerRtl)),
      one(_Act(const Icon(Icons.brightness_low), tr('어둡게'),
          () => _updateSettings((x) => x.readerBrightness = (x.readerBrightness - 0.1).clamp(-0.7, 0.7)))),
      one(_Act(const Icon(Icons.brightness_high), tr('밝게'),
          () => _updateSettings((x) => x.readerBrightness = (x.readerBrightness + 0.1).clamp(-0.7, 0.7)))),
      // 30: 시계 · 알림 · 뒤로 막대를 그대로 / 화면 가득
      one(_Act(Icon(s.readerSystemBars ? Icons.fullscreen : Icons.fullscreen_exit),
          s.readerSystemBars ? tr('화면 가득 (시스템 막대 숨기기)') : tr('시스템 막대 보이기 (시계 · 알림 · 뒤로)'), () async {
        await _updateSettings((x) => x.readerSystemBars = !x.readerSystemBars);
        _applySystemBars();
      }, on: s.readerSystemBars)),
      // AI 는 막대가 좁으면 먼저 ⋮ 로 (늘 쓰는 버튼이 막대에 남게)
      // 121: AI 해상도 올리기 (이 장 · 모든 장) - 새 파일로 저장, 원본 · ZIP 은 그대로
      if (_aiOn && src is! PdfSource) ...[
        one(_Act(const Icon(Icons.hd_outlined), tr('AI 해상도 올리기 (이 장)'), _upscalePage)),
        one(_Act(const Icon(Icons.burst_mode_outlined), tr('AI 해상도 올리기 (모든 장)'), () => upscaleAll(context, c, src))),
      ],
      // 123: 이 그림을 바탕으로 AI 그림 (그림 → 그림, 원본은 그대로)
      if (_aiSource case final path?)
        one(_Act(const Icon(Icons.auto_awesome_outlined), tr('AI 그림으로 (이 그림을 바탕으로)'),
            () => AiImagePage.open(Navigator.of(context), c: c, initImage: path))),
    ];
  }

  bool get _aiOn => c.settings.components.contains('aiimage');

  Future<void> _upscalePage() async {
    final page = _cur.page;
    final file = await readerPageFile(c, src, page);
    if (file == null || !mounted) return;
    final saved = await upscaleOne(context, c, input: file.$1, nameFrom: file.$2, outDir: file.$3);
    if (saved == null || !mounted) return;
    // 저장한 뒤 올린 것으로 계속 보기 (설정) - 이 기기의 그림 파일 목록일 때
    final s = src;
    if (c.settings.aiUpAfter == 'upscaled' && s is ImageFilesSource && !isDav(s.paths[page])) {
      setState(() {
        s.paths[page] = saved;
        _reset(page: page);
      });
    }
  }

  /// 지금 보는 그림 파일 (이 기기의 그림 파일일 때, AI 그림 컴포넌트가 켜져 있을 때)
  String? get _aiSource {
    final s = src;
    if (!c.settings.components.contains('aiimage') || s is! ImageFilesSource || _v.isEmpty) return null;
    final path = s.paths[_cur.page];
    return isDav(path) ? null : path;
  }

  Widget _barButton(_Act a, {bool compact = false}) => IconButton(
        tooltip: a.tip,
        color: a.on ? JjColors.accent : Colors.white,
        disabledColor: Colors.white38,
        icon: a.icon,
        visualDensity: compact ? VisualDensity.compact : null,
        constraints: compact ? const BoxConstraints(minWidth: 36, minHeight: 40) : null,
        padding: compact ? EdgeInsets.zero : null,
        onPressed: a.onTap,
      );

  Widget _topBar() {
    final pdf = _pdf;
    return Container(
      // 113: 반투명 검정은 그림 위에서만 보이고 옆의 검은 여백에서는 안 보여 막대가 갈라져 보였다 → 거의 불투명한 어두운 회색 한 줄
      color: _barColor,
      padding: EdgeInsets.only(top: MediaQuery.paddingOf(context).top),
      child: SizedBox(
        height: 52,
        child: LayoutBuilder(builder: (context, box) {
          final items = _barItems();
          // 닫기 · 제목 (조금이라도) 을 뺀 자리에 들어가는 만큼 앞에서부터, 나머지는 ⋮ 메뉴 (없애지 않는다)
          final room = box.maxWidth - 48 - 72;
          var shown = items.length;
          if (items.fold<double>(0, (a, x) => a + x.width) > room) {
            var used = 48.0; // ⋮
            shown = 0;
            while (shown < items.length && used + items[shown].width <= room) {
              used += items[shown].width;
              shown++;
            }
          }
          final rest = [for (final x in items.skip(shown)) ...x.acts];
          return Row(children: [
            _barButton(_Act(const Icon(Icons.arrow_back), tr('닫기'), () => Navigator.maybePop(context))),
            Expanded(
              child: Text(
                '${src.title}${pdf?.dirty == true ? ' *' : ''}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white, fontSize: 14),
              ),
            ),
            // 버튼은 오른쪽 끝에 붙인다 (113)
            for (final x in items.take(shown))
              if (x.seconds != null)
                Row(mainAxisSize: MainAxisSize.min, children: [
                  _barButton(x.acts[0], compact: true),
                  SizedBox(
                    width: 40,
                    child: Text(trf('{0}초', [x.seconds!]),
                        textAlign: TextAlign.center, style: const TextStyle(color: Colors.white, fontSize: 13)),
                  ),
                  _barButton(x.acts[1], compact: true),
                ])
              else
                _barButton(x.acts.single),
            if (rest.isNotEmpty)
              PopupMenuButton<int>(
                tooltip: tr('더 보기'),
                icon: const Icon(Icons.more_vert, color: Colors.white),
                onSelected: (k) => rest[k].onTap?.call(),
                itemBuilder: (_) => [
                  for (final (k, a) in rest.indexed)
                    PopupMenuItem<int>(
                      value: k,
                      enabled: a.onTap != null,
                      child: Row(children: [
                        IconTheme.merge(data: IconThemeData(color: a.on ? JjColors.accent : null), child: a.icon),
                        const SizedBox(width: 12),
                        Flexible(child: Text(a.tip)),
                      ]),
                    ),
                ],
              ),
          ]);
        }),
      ),
    );
  }

  /// 위 · 아래 막대 색 (그림 위 · 검은 여백 위 어디서나 같은 띠로 보이게 거의 불투명)
  static const _barColor = Color(0xF0222428);

  /// 쪽 번호: 통째면 "12", 반쪽이면 "12-1" · "12-2"
  String _label(ReaderSlot s) => s.part < 0 ? '${s.page + 1}' : '${s.page + 1}-${s.part + 1}';

  Widget _bottomBar() {
    final n = src.length;
    final count = _v.length;
    return Container(
      color: _barColor,
      padding: EdgeInsets.only(bottom: MediaQuery.paddingOf(context).bottom, left: 12, right: 12),
      child: Row(children: [
        // 125: 반으로 나눈 쪽이 있으면 전체 수가 파일 수 (장) 임을 단위로 ("2-1 / 3장")
        Text(
            count != n ? trf('{0} / {1}장', [_label(_cur), n]) : '${n == 0 ? 0 : _label(_cur)} / $n',
            style: const TextStyle(color: Colors.white, fontFamily: 'Consolas')),
        Expanded(
          child: count < 2
              ? const SizedBox(height: 48)
              : Directionality(
                  textDirection: c.settings.readerRtl ? TextDirection.rtl : TextDirection.ltr,
                  child: Slider(
                    value: _index.clamp(0, count - 1).toDouble(),
                    max: (count - 1).toDouble(),
                    divisions: count - 1,
                    onChanged: (v) => _pages.jumpToPage(v.round()),
                  ),
                ),
        ),
        // 113: 쪽 이름은 오른쪽 끝 (넓은 화면에서 가운데로 떨어지지 않게)
        ConstrainedBox(
          constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.3),
          child: Text(n == 0 ? '' : src.pageName(_cur.page),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.end,
              style: const TextStyle(color: Colors.white70, fontSize: 12)),
        ),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = c.settings;
    return PopScope(
      canPop: _pdf?.dirty != true,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (await _confirmLeave() && context.mounted) {
          _pdf?.dirty = false;
          Navigator.of(context).pop();
        }
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: LayoutBuilder(builder: (context, box) {
          // 화면 너비 (기기 픽셀) 에 맞춰 그림을 줄여 읽는다
          _width = (box.maxWidth * MediaQuery.devicePixelRatioOf(context)).round().clamp(320, 4096);
          return Stack(children: [
            Positioned.fill(
              child: Listener(
                onPointerDown: (_) => _onPointerDown(),
                onPointerUp: (_) => _finger(-1),
                onPointerCancel: (_) => _finger(-1),
                child: GestureDetector(
                onTapUp: (d) => _onTap(d, box.maxWidth),
                child: ColorFiltered(
                  colorFilter: _brightness(s.readerBrightness),
                  child: _v.isEmpty
                      ? Center(child: Text(tr('볼 그림이 없습니다.'), style: const TextStyle(color: Colors.white70)))
                      : PageView.builder(
                          key: ValueKey(_version),
                          controller: _pages,
                          reverse: s.readerRtl,
                          // 확대해 보는 동안은 밀어도 넘기지 않는다 (그림 옮기기)
                          physics: _holdPage ? const NeverScrollableScrollPhysics() : null,
                          itemCount: _v.length,
                          onPageChanged: (i) => setState(() {
                            _index = i;
                            _resetZoom();
                            _trim();
                          }),
                          itemBuilder: (_, i) => _page(i, box.biggest),
                        ),
                ),
              ),
              ),
            ),
            if (_bars) ...[
              Positioned(left: 0, right: 0, top: 0, child: _topBar()),
              Positioned(left: 0, right: 0, bottom: 0, child: _bottomBar()),
            ],
          ]);
        }),
      ),
    );
  }
}

/// 위 막대 버튼 하나 (⋮ 메뉴에서는 [icon] 과 [tip] 으로 한 줄)
class _Act {
  final Widget icon;
  final String tip;
  final VoidCallback? onTap;
  final bool on;
  const _Act(this.icon, this.tip, this.onTap, {this.on = false});
}

/// 위 막대의 한 칸 ([width] 만큼 자리를 차지). [seconds] 가 있으면 ▲ · 초 · ▼ 묶음
class _BarItem {
  final double width;
  final List<_Act> acts;
  final int? seconds;
  const _BarItem(this.width, this.acts, {this.seconds});
}
