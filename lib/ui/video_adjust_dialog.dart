import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../app/app_controller.dart';
import '../core/encode_options.dart';
import '../core/models.dart';
import '../l10n/tr.dart';
import 'theme.dart';

/// 화면 · 색 보정 (파이널 컷의 뷰어 + 인스펙터처럼): 왼쪽은 지금 보고 있는 동영상의 한 장면 미리보기,
/// 오른쪽은 화면 비율 · 맞추기 · 회전 · 색 보정. 바꾸면 바로 MKV 만들기 설정에 들어간다.
Future<void> showVideoAdjust(BuildContext context, AppController c) => showDialog<void>(
      context: context,
      builder: (_) => Dialog(
        insetPadding: const EdgeInsets.all(16),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1100, maxHeight: 720),
          child: _VideoAdjust(c: c),
        ),
      ),
    );

class _VideoAdjust extends StatefulWidget {
  final AppController c;
  const _VideoAdjust({required this.c});

  @override
  State<_VideoAdjust> createState() => _VideoAdjustState();
}

class _VideoAdjustState extends State<_VideoAdjust> {
  AppController get c => widget.c;
  EncodeSettings get s => c.encode;
  VideoItem? get v => c.selected;

  Uint8List? _after, _before;
  bool _showBefore = false, _busy = false;
  String? _error;
  Timer? _debounce;
  int _seq = 0;
  String? _dir;

  @override
  void initState() {
    super.initState();
    _render(before: true);
    _render();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  /// 미리보기 장면 (영상 길이의 1/3, 모르면 5초)
  Duration get _at {
    final d = v?.info?.duration;
    return d == null || d == Duration.zero ? const Duration(seconds: 5) : d ~/ 3;
  }

  /// FFmpeg 로 한 장면을 그려 PNG 로 (조정 전 · 후)
  Future<void> _render({bool before = false}) async {
    final video = v;
    if (video == null) return;
    final seq = before ? -1 : ++_seq;
    if (!before) setState(() => _busy = true);
    try {
      _dir ??= await c.services.storage.tempDirectory();
      final out = p.join(_dir!, 'jj_adjust_${before ? 'before' : 'after'}_${DateTime.now().microsecondsSinceEpoch}.png');
      final settings = before ? const EncodeSettings() : s;
      final vf = buildVideoFilter(settings, video.info?.ofType('video').firstOrNull, preview: true) ??
          'scale=480:480:force_original_aspect_ratio=decrease';
      final at = _at;
      await c.services.mediaTool.runFfmpeg([
        '-hide_banner', '-v', 'error', '-nostdin', //
        '-ss', '${at.inMilliseconds / 1000}', '-i', video.path,
        '-frames:v', '1', '-vf', vf, '-y', out,
      ]);
      final bytes = await File(out).readAsBytes();
      unawaited(File(out).delete().catchError((_) => File(out)));
      if (!mounted) return;
      if (before) {
        setState(() => _before = bytes);
      } else if (seq == _seq) {
        setState(() {
          _after = bytes;
          _error = null;
          _busy = false;
        });
      }
    } catch (e) {
      if (mounted && (before || seq == _seq)) {
        setState(() {
          _error = '$e';
          _busy = false;
        });
      }
    }
  }

  void _set(EncodeSettings e) {
    c.setAdjust(e);
    setState(() {});
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), _render);
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 760;
    final viewer = _viewer();
    final inspector = _inspector();
    return Column(children: [
      // 제목 줄
      Container(
        color: JjColors.panelHigh,
        padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
        child: Row(children: [
          const Icon(Icons.tune, color: JjColors.accent, size: 20),
          const SizedBox(width: 8),
          Text(tr('화면 · 색 보정'), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
          const SizedBox(width: 12),
          Expanded(
            child: Text(tr('MKV 만들기에 적용됩니다 (영상을 다시 인코딩)'),
                overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, color: JjColors.textDim)),
          ),
          TextButton.icon(
            onPressed: s.adjusts ? () => _set(s.resetAdjust()) : null,
            icon: const Icon(Icons.restart_alt, size: 18),
            label: Text(tr('모두 초기화')),
          ),
          IconButton(tooltip: tr('닫기'), icon: const Icon(Icons.close), onPressed: () => Navigator.pop(context)),
        ]),
      ),
      Expanded(
        child: wide
            ? Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Expanded(child: viewer),
                SizedBox(width: 340, child: inspector),
              ])
            : Column(children: [
                SizedBox(height: 260, child: viewer),
                Expanded(child: inspector),
              ]),
      ),
    ]);
  }

  /// 뷰어: 조정 후 장면 (누르고 있으면 조정 전)
  Widget _viewer() {
    final img = _showBefore ? _before : _after;
    return Container(
      color: Colors.black,
      child: Stack(children: [
        Positioned.fill(
          child: v == null
              ? Center(child: Text(tr('미리보기: 목록에서 동영상을 고르세요'), style: const TextStyle(color: JjColors.textDim)))
              : _error != null
                  ? Center(
                      child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(_error!, style: const TextStyle(color: JjColors.danger, fontSize: 12)),
                    ))
                  : img == null
                      ? const Center(child: CircularProgressIndicator())
                      : Padding(
                          padding: const EdgeInsets.all(12),
                          child: Image.memory(img, fit: BoxFit.contain, gaplessPlayback: true),
                        ),
        ),
        if (v != null)
          Positioned(
            left: 8,
            bottom: 8,
            child: GestureDetector(
              onTapDown: (_) => setState(() => _showBefore = true),
              onTapUp: (_) => setState(() => _showBefore = false),
              onTapCancel: () => setState(() => _showBefore = false),
              child: Chip(
                avatar: const Icon(Icons.compare, size: 16),
                label: Text(_showBefore ? tr('조정 전') : tr('누르고 있으면 조정 전')),
              ),
            ),
          ),
        if (_busy)
          const Positioned(right: 12, top: 12, child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))),
        if (v != null)
          Positioned(
            right: 8,
            bottom: 8,
            child: Text('${v!.fileName} · ${_fmt(_at)}',
                style: const TextStyle(fontSize: 11, color: Colors.white70)),
          ),
      ]),
    );
  }

  static String _fmt(Duration d) =>
      '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';

  /// 인스펙터: 화면 비율 · 맞추기 · 회전 · 색 보정
  Widget _inspector() {
    Widget head(String t) => Padding(
          padding: const EdgeInsets.fromLTRB(0, 16, 0, 8),
          child: Text(t, style: const TextStyle(fontSize: 13, color: JjColors.accent, fontWeight: FontWeight.w600)),
        );
    const frameIcons = {
      FrameChoice.original: Icons.crop_original,
      FrameChoice.landscape: Icons.crop_landscape,
      FrameChoice.portrait: Icons.crop_portrait,
      FrameChoice.square: Icons.crop_square,
      FrameChoice.portrait45: Icons.crop_portrait,
    };
    return Container(
      color: JjColors.panel,
      child: ListView(padding: const EdgeInsets.fromLTRB(16, 0, 16, 16), children: [
        head(tr('화면 비율')),
        Wrap(spacing: 6, runSpacing: 6, children: [
          for (final f in FrameChoice.values)
            ChoiceChip(
              avatar: Icon(frameIcons[f], size: 16),
              label: Text(f.label),
              selected: s.frame == f,
              onSelected: (_) => _set(s.copyWith(frame: f)),
            ),
        ]),
        head(tr('맞추기 (비율이 다를 때)')),
        Wrap(spacing: 6, runSpacing: 6, children: [
          for (final f in FitChoice.values)
            ChoiceChip(
              label: Text(f.label),
              selected: s.fit == f,
              onSelected: s.frame == FrameChoice.original ? null : (_) => _set(s.copyWith(fit: f)),
            ),
        ]),
        head(tr('회전')),
        Wrap(spacing: 6, runSpacing: 6, children: [
          for (final r in RotateChoice.values)
            ChoiceChip(
              label: Text(r.label),
              selected: s.rotate == r,
              onSelected: (_) => _set(s.copyWith(rotate: r)),
            ),
        ]),
        head(tr('색 보정')),
        _slider(tr('밝기'), Icons.wb_sunny_outlined, s.brightness, (x) => s.copyWith(brightness: x)),
        _slider(tr('대비'), Icons.contrast, s.contrast, (x) => s.copyWith(contrast: x)),
        _slider(tr('채도'), Icons.palette_outlined, s.saturation, (x) => s.copyWith(saturation: x)),
        _slider(tr('색온도'), Icons.thermostat, s.temperature, (x) => s.copyWith(temperature: x),
            hint: tr('− 차갑게 · + 따뜻하게')),
        const SizedBox(height: 12),
        Text(
          s.adjusts ? '${tr('적용')}: ${s.adjustSummary}' : tr('바꾼 것이 없습니다 (원본 그대로)'),
          style: const TextStyle(fontSize: 12, color: JjColors.textDim),
        ),
      ]),
    );
  }

  Widget _slider(String label, IconData icon, int value, EncodeSettings Function(int) apply, {String? hint}) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Icon(icon, size: 16, color: JjColors.textDim),
        const SizedBox(width: 6),
        Text(label, style: const TextStyle(fontSize: 13)),
        if (hint != null) ...[
          const SizedBox(width: 6),
          Text(hint, style: const TextStyle(fontSize: 11, color: JjColors.textDim)),
        ],
        const Spacer(),
        SizedBox(
          width: 40,
          child: Text(value > 0 ? '+$value' : '$value', textAlign: TextAlign.right, style: const TextStyle(fontSize: 13)),
        ),
        IconButton(
          tooltip: tr('0 으로'),
          visualDensity: VisualDensity.compact,
          iconSize: 16,
          icon: const Icon(Icons.restart_alt),
          onPressed: value == 0 ? null : () => _set(apply(0)),
        ),
      ]),
      Slider(
        min: -100,
        max: 100,
        divisions: 40,
        value: value.toDouble(),
        label: value > 0 ? '+$value' : '$value',
        onChanged: (x) => _set(apply(x.round())),
      ),
    ]);
  }
}
