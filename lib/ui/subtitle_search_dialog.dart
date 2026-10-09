import 'package:flutter/material.dart';

import '../core/secret_gate.dart';
import '../app/app_controller.dart';
import '../core/languages.dart';
import '../core/models.dart';
import '../core/subtitle_search.dart';
import 'theme.dart';
import '../l10n/tr.dart';

/// 인터넷 자막 찾기 → 목록에서 골라 받기
Future<void> showSubtitleSearch(BuildContext context, AppController c, VideoItem v) =>
    showDialog<void>(context: context, builder: (_) => _SearchDialog(c: c, v: v));

class _SearchDialog extends StatefulWidget {
  final AppController c;
  final VideoItem v;
  const _SearchDialog({required this.c, required this.v});

  @override
  State<_SearchDialog> createState() => _SearchDialogState();
}

class _SearchDialogState extends State<_SearchDialog> {
  final _title = TextEditingController();
  final _year = TextEditingController();
  final _season = TextEditingController();
  final _episode = TextEditingController();
  final _key = TextEditingController();
  late Set<Language> _langs = {
    for (final code in widget.c.settings.aiTargets)
      if (languageOf(code) != undetermined) languageOf(code),
  };
  String? _hash;
  bool _useHash = true;
  bool _busy = false;

  /// 받은 자막을 한국어로 번역해 함께 추가
  bool _translateKo = true;
  String? _error;
  List<SubtitleSearchResult>? _results;
  final Set<SubtitleSearchResult> _picked = {};

  AppController get c => widget.c;

  @override
  void initState() {
    super.initState();
    if (_langs.isEmpty) _langs = {for (final x in defaultTargetLanguages) languageOf(x)};
    c.guessSubtitleQuery(widget.v, _langs.toList()).then((q) {
      if (!mounted) return;
      setState(() {
        _title.text = q.title;
        _year.text = q.year?.toString() ?? '';
        _season.text = q.season?.toString() ?? '';
        _episode.text = q.episode?.toString() ?? '';
        _hash = q.movieHash;
      });
      if (c.subtitleProvider?.configured ?? false) _search();
    });
  }

  @override
  void dispose() {
    for (final t in [_title, _year, _season, _episode, _key]) {
      t.dispose();
    }
    super.dispose();
  }

  Future<void> _search() async {
    // 124 · 128: 사용자가 직접 찾는 것이니 마스터 창을 한 번 취소했어도 다시 묻는다
    await SecretGate.pass(force: true);
    if (!mounted) return;
    setState(() {
      _busy = true;
      _error = null;
      _picked.clear();
    });
    try {
      final r = await c.searchSubtitles(SubtitleQuery(
        title: _title.text,
        year: int.tryParse(_year.text),
        season: int.tryParse(_season.text),
        episode: int.tryParse(_episode.text),
        movieHash: _useHash ? _hash : null,
        languages: _langs.toList(),
      ));
      setState(() => _results = r);
    } catch (e) {
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _download() async {
    setState(() => _busy = true);
    final ko = languageOf('ko');
    final toKo = _translateKo && c.services.createTranslator != null && _picked.any((r) => r.language.code != ko.code);
    final n = await c.downloadSubtitles(widget.v, _picked.toList(), translateTo: toKo ? ko : null);
    if (!mounted) return;
    setState(() => _busy = false);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text((n == _picked.length
                ? trf('자막 {0}개를 받아 MKV 자막 목록에 추가했습니다.', [n])
                : trf('자막 {0}개 중 {1}개를 받았습니다. 아래 작업 기록을 확인하세요.', [_picked.length, n])) +
            (toKo && n > 0 ? tr('\n한국어 번역은 대기열에서 이어서 진행합니다.') : ''))));
    if (n > 0) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final provider = c.subtitleProvider;
    final ready = provider?.configured ?? false;
    return AlertDialog(
      title: Text(trf('인터넷 자막 찾기{0}', [provider == null ? '' : ' · ${provider.name}'])),
      content: SizedBox(
        width: 820,
        height: 560,
        child: provider == null
            ? Center(child: Text(tr('사용할 수 있는 자막 사이트가 없습니다.')))
            : !ready
                ? _setup()
                : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    _form(),
                    const SizedBox(height: 8),
                    if (_busy) const LinearProgressIndicator(minHeight: 2),
                    if (_error != null)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: SelectableText(_error!, style: const TextStyle(color: JjColors.danger)),
                      ),
                    Expanded(child: _list()),
                  ]),
      ),
      actions: [
        if (ready && c.services.createTranslator != null)
          Row(mainAxisSize: MainAxisSize.min, children: [
            Checkbox(value: _translateKo, onChanged: (x) => setState(() => _translateKo = x ?? false)),
            GestureDetector(
              onTap: () => setState(() => _translateKo = !_translateKo),
              child: Text(tr('받은 자막을 한국어로 번역해 함께 추가 (한국어 자막이 없을 때)'), style: TextStyle(fontSize: 12)),
            ),
            const SizedBox(width: 12),
          ]),
        TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('닫기'))),
        if (ready)
          FilledButton.icon(
            onPressed: _busy || _picked.isEmpty ? null : _download,
            icon: const Icon(Icons.download, size: 18),
            label: Text(trf('선택한 {0}개 받기', [_picked.length])),
          ),
      ],
    );
  }

  Widget _setup() => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(c.subtitleProvider!.setupHint, style: const TextStyle(height: 1.6)),
        const SizedBox(height: 16),
        Row(children: [
          Expanded(
            child: TextField(
              controller: _key,
              decoration: InputDecoration(labelText: tr('API 키'), border: OutlineInputBorder()),
            ),
          ),
          const SizedBox(width: 8),
          FilledButton(
            onPressed: () async {
              if (_key.text.trim().isEmpty) return;
              await c.updateSettings((s) => s.openSubtitlesKey = _key.text.trim());
              setState(() {});
              _search();
            },
            child: Text(tr('저장하고 검색')),
          ),
        ]),
        const SizedBox(height: 8),
        Text(tr('아이디·비밀번호는 환경 설정에서 넣을 수 있습니다 (선택, 하루 받기 횟수가 늘어남).'),
            style: TextStyle(fontSize: 12, color: JjColors.textDim)),
      ]);

  Widget _form() {
    Widget field(TextEditingController t, String label, double w) => SizedBox(
          width: w,
          child: TextField(
            controller: t,
            style: const TextStyle(fontSize: 13),
            decoration: InputDecoration(isDense: true, labelText: label, border: const OutlineInputBorder()),
            onSubmitted: (_) => _search(),
          ),
        );
    final extra = languages.where((l) => !_langs.contains(l)).toList();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Expanded(child: field(_title, tr('제목'), double.infinity)),
        const SizedBox(width: 8),
        field(_year, tr('연도'), 70),
        const SizedBox(width: 8),
        field(_season, tr('시즌'), 60),
        const SizedBox(width: 8),
        field(_episode, tr('회차'), 60),
        const SizedBox(width: 8),
        FilledButton.icon(
          onPressed: _busy ? null : _search,
          icon: const Icon(Icons.search, size: 18),
          label: Text(tr('검색')),
        ),
      ]),
      const SizedBox(height: 8),
      Wrap(spacing: 6, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
        for (final l in _langs)
          InputChip(
            label: Text('${l.name} (${l.code})', style: const TextStyle(fontSize: 12)),
            onDeleted: _langs.length > 1 ? () => setState(() => _langs.remove(l)) : null,
          ),
        PopupMenuButton<Language>(
          tooltip: tr('언어 추가'),
          itemBuilder: (_) => [for (final l in extra) PopupMenuItem(value: l, child: Text('${l.name} (${l.code})'))],
          onSelected: (l) => setState(() => _langs.add(l)),
          child: Chip(avatar: Icon(Icons.add, size: 16), label: Text(tr('언어'))),
        ),
        const SizedBox(width: 12),
        if (_hash != null)
          FilterChip(
            selected: _useHash,
            onSelected: (v) => setState(() => _useHash = v),
            label: Text(tr('이 파일에 맞는 자막 우선 (영상 해시)'), style: TextStyle(fontSize: 12)),
          ),
      ]),
    ]);
  }

  Widget _list() {
    final r = _results;
    if (r == null) return const SizedBox();
    if (r.isEmpty) {
      return Center(
          child: Text(tr('찾은 자막이 없습니다. 제목을 영어 원제로 바꾸거나 언어를 추가해 보세요.'),
              style: TextStyle(color: JjColors.textDim)));
    }
    return ListView.builder(
      itemCount: r.length,
      itemBuilder: (_, i) {
        final s = r[i];
        final on = _picked.contains(s);
        return CheckboxListTile(
          dense: true,
          value: on,
          onChanged: (_) => setState(() => on ? _picked.remove(s) : _picked.add(s)),
          title: Text(s.release, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(
            [
              '${s.language.name} (${s.language.code})',
              if (s.featureTitle != null && s.featureTitle!.isNotEmpty) s.featureTitle!,
              trf('받음 {0}', [s.downloads]),
              if (s.uploader != null) trf('올린 이 {0}', [s.uploader]),
              if (s.hearingImpaired) tr('청각장애인용'),
            ].join('  ·  '),
            style: const TextStyle(fontSize: 11),
          ),
          secondary: Row(mainAxisSize: MainAxisSize.min, children: [
            if (s.hashMatch) _badge(tr('이 파일용'), JjColors.success),
            if (s.machineTranslated) _badge(tr('기계 번역'), Colors.amber),
          ]),
        );
      },
    );
  }

  Widget _badge(String t, Color color) => Container(
        margin: const EdgeInsets.only(left: 4),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.18),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(t, style: TextStyle(fontSize: 10, color: color)),
      );
}
