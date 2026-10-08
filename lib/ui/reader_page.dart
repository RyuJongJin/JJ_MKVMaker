import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app/app_controller.dart';
import '../core/reader_sources.dart';
import '../core/vfs.dart';
import '../l10n/tr.dart';
import 'theme.dart';

/// 그림 · 만화 · PDF 보기를 연다. [start] 처음 볼 장. 닫으면 [source] 를 정리한다.
Future<void> openReader(BuildContext context, AppController c, ReaderSource source, {int start = 0}) async {
  await Navigator.of(context).push(MaterialPageRoute<void>(
    builder: (_) => ReaderPage(c: c, source: source, start: start),
  ));
  await source.dispose();
}

/// 그림 · 만화 · PDF 보기.
/// - 화면 오른쪽 (1/3) 을 누르면 다음 장, 왼쪽을 누르면 이전 장, 가운데를 누르면 위 · 아래 막대 보이기 · 숨기기
///   (오른쪽에서 왼쪽으로 넘기기를 켜면 반대). 좌우로 밀어도 넘어간다.
/// - 위 막대: 한 쪽 맞추기 · 좌우 맞추기, 넘기는 방향, 어둡게 · 밝게, (PDF) 페이지 지우기 · 그림 넣기 · 저장
class ReaderPage extends StatefulWidget {
  final AppController c;
  final ReaderSource source;
  final int start;
  const ReaderPage({super.key, required this.c, required this.source, this.start = 0});

  @override
  State<ReaderPage> createState() => _ReaderPageState();
}

class _ReaderPageState extends State<ReaderPage> {
  AppController get c => widget.c;
  ReaderSource get src => widget.source;
  late final PageController _pages = PageController(initialPage: widget.start);
  late int _index = widget.start;
  bool _bars = true;
  final _cache = <int, Future<ReaderImage>>{};
  int _width = 0;

  /// PDF 는 페이지를 지우거나 넣으면 다시 그린다
  int _version = 0;

  @override
  void initState() {
    super.initState();
    // 보기 화면은 위 · 아래 시스템 막대까지 그림으로
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  }

  @override
  void dispose() {
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    for (final f in _cache.values) {
      unawaited(f.then((x) => x.dispose(), onError: (_) {}));
    }
    _pages.dispose();
    super.dispose();
  }

  Future<ReaderImage> _load(int i) => _cache.putIfAbsent(i, () => src.load(i, maxWidth: _width));

  /// 보는 장 가까이만 남기고 (메모리) 다음 장은 미리 읽는다
  void _trim() {
    for (final k in _cache.keys.toList()) {
      if ((k - _index).abs() > 3) {
        unawaited(_cache.remove(k)!.then((x) => x.dispose(), onError: (_) {}));
      }
    }
    if (_index + 1 < src.length) unawaited(_load(_index + 1));
  }

  void _reset() {
    for (final f in _cache.values) {
      unawaited(f.then((x) => x.dispose(), onError: (_) {}));
    }
    _cache.clear();
    _version++;
  }

  void _go(int delta) {
    final to = (_index + delta).clamp(0, math.max(0, src.length - 1)).toInt();
    if (to == _index) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
          duration: const Duration(seconds: 1), content: Text(delta > 0 ? tr('마지막 장입니다.') : tr('첫 장입니다.'))));
      return;
    }
    _pages.jumpToPage(to);
  }

  void _onTap(TapUpDetails d, double width) {
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

  ColorFilter _brightness(double b) {
    final double s = 1 + math.min(b, 0.0);
    final double o = math.max(b, 0.0) * 160;
    return ColorFilter.matrix(<double>[s, 0, 0, 0, o, 0, s, 0, 0, o, 0, 0, s, 0, o, 0, 0, 0, 1, 0]);
  }

  Widget _page(int i, Size box) {
    final fit = c.settings.readerFit;
    return FutureBuilder<ReaderImage>(
      key: ValueKey('$_version:$i'),
      future: _load(i),
      builder: (context, snap) {
        if (snap.hasError) {
          return Center(
              child: Text(trf('열 수 없습니다: {0}', [snap.error]), style: const TextStyle(color: Colors.white70)));
        }
        final r = snap.data;
        if (r == null) return const Center(child: CircularProgressIndicator());
        Widget picture(BoxFit f, {double? width}) => r.image != null
            ? RawImage(image: r.image, fit: f, width: width)
            : Image(image: r.provider!, fit: f, width: width, gaplessPlayback: true, filterQuality: FilterQuality.medium,
                errorBuilder: (_, e, _) =>
                    Center(child: Text(trf('열 수 없습니다: {0}', [e]), style: const TextStyle(color: Colors.white70))));
        if (fit == 'width') {
          return SingleChildScrollView(child: picture(BoxFit.fitWidth, width: box.width));
        }
        return SizedBox.expand(child: picture(BoxFit.contain));
      },
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
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('페이지 지우기')),
        content: Text(trf('{0} 페이지를 지울까요? (저장해야 파일에 반영됩니다)', [_index + 1])),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('취소'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr('지우기'))),
        ],
      ),
    );
    if (ok != true) return;
    await pdf.deletePage(_index);
    if (!mounted) return;
    setState(() {
      _reset();
      _index = _index.clamp(0, pdf.length - 1);
    });
    _pages.jumpToPage(_index);
  }

  Future<void> _insertImages() async {
    final pdf = _pdf!;
    final files = await c.services.storage.pickFiles(title: tr('PDF 에 넣을 그림 선택'), extensions: c.settings.imageExts);
    if (files.isEmpty || !mounted) return;
    final temp = await c.services.storage.tempDirectory();
    try {
      await pdf.insertImages(files, after: _index, tempDir: temp);
    } catch (e) {
      _snack(trf('넣지 못했습니다: {0}', [e]));
      return;
    }
    setState(_reset);
    _snack(trf('그림 {0}장을 {1} 페이지 뒤에 넣었습니다 (저장해야 파일에 반영됩니다).', [files.length, _index + 1]));
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
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(text)));
  }

  // ───────── 화면 ─────────

  Widget _topBar() {
    final s = c.settings;
    final pdf = _pdf;
    IconButton btn(IconData i, String tip, VoidCallback? f, {bool on = false}) => IconButton(
          tooltip: tip,
          color: on ? JjColors.accent : Colors.white,
          icon: Icon(i),
          onPressed: f,
        );
    return Container(
      color: Colors.black.withValues(alpha: 0.75),
      padding: EdgeInsets.only(top: MediaQuery.paddingOf(context).top),
      child: SizedBox(
        height: 52,
        child: Row(children: [
          btn(Icons.arrow_back, tr('닫기'), () => Navigator.maybePop(context)),
          Expanded(
            child: Text(
              '${src.title}${pdf?.dirty == true ? ' *' : ''}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white, fontSize: 14),
            ),
          ),
          // 좁아도 버튼은 옆으로 밀어 본다
          Flexible(
            flex: 3,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              reverse: true,
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                btn(Icons.fit_screen_outlined, tr('한 쪽 맞추기'), () => _updateSettings((x) => x.readerFit = 'page'),
                    on: s.readerFit == 'page'),
                btn(Icons.width_full_outlined, tr('좌우 맞추기 (세로로 밀어 봄)'), () => _updateSettings((x) => x.readerFit = 'width'),
                    on: s.readerFit == 'width'),
                btn(Icons.swap_horiz, s.readerRtl ? tr('넘기는 방향: 오른쪽 → 왼쪽 (만화)') : tr('넘기는 방향: 왼쪽 → 오른쪽'),
                    () => _updateSettings((x) => x.readerRtl = !x.readerRtl), on: s.readerRtl),
                btn(Icons.brightness_low, tr('어둡게'),
                    () => _updateSettings((x) => x.readerBrightness = (x.readerBrightness - 0.1).clamp(-0.7, 0.7))),
                btn(Icons.brightness_high, tr('밝게'),
                    () => _updateSettings((x) => x.readerBrightness = (x.readerBrightness + 0.1).clamp(-0.7, 0.7))),
                if (pdf != null) ...[
                  btn(Icons.delete_outline, tr('이 페이지 지우기'), _deletePage),
                  btn(Icons.add_photo_alternate_outlined, tr('그림을 페이지로 넣기 (이 페이지 뒤)'), _insertImages),
                  btn(Icons.save_outlined, tr('저장'), pdf.dirty ? _save : null),
                ],
              ]),
            ),
          ),
        ]),
      ),
    );
  }

  Widget _bottomBar() {
    final n = src.length;
    return Container(
      color: Colors.black.withValues(alpha: 0.75),
      padding: EdgeInsets.only(bottom: MediaQuery.paddingOf(context).bottom, left: 12, right: 12),
      child: Row(children: [
        Text('${n == 0 ? 0 : _index + 1} / $n', style: const TextStyle(color: Colors.white, fontFamily: 'Consolas')),
        Expanded(
          child: n < 2
              ? const SizedBox(height: 48)
              : Directionality(
                  textDirection: c.settings.readerRtl ? TextDirection.rtl : TextDirection.ltr,
                  child: Slider(
                    value: _index.toDouble(),
                    max: (n - 1).toDouble(),
                    divisions: n - 1,
                    onChanged: (v) => _pages.jumpToPage(v.round()),
                  ),
                ),
        ),
        Flexible(
          child: Text(n == 0 ? '' : src.pageName(_index),
              maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white70, fontSize: 12)),
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
              child: GestureDetector(
                onTapUp: (d) => _onTap(d, box.maxWidth),
                child: ColorFiltered(
                  colorFilter: _brightness(s.readerBrightness),
                  child: src.length == 0
                      ? Center(child: Text(tr('볼 그림이 없습니다.'), style: const TextStyle(color: Colors.white70)))
                      : PageView.builder(
                          key: ValueKey(_version),
                          controller: _pages,
                          reverse: s.readerRtl,
                          itemCount: src.length,
                          onPageChanged: (i) => setState(() {
                            _index = i;
                            _trim();
                          }),
                          itemBuilder: (_, i) => _page(i, box.biggest),
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
