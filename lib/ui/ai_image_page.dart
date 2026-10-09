import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../app/ai_local.dart';
import '../app/app_controller.dart';
import '../core/reader_sources.dart';
import '../core/sd_cli.dart';
import '../l10n/tr.dart';
import '../services/image_ai.dart';
import 'ai_settings.dart';
import 'app_actions.dart';
import 'browser_page.dart' show browserRouteObserver;
import 'reader_page.dart';
import 'theme.dart';

/// 123: AI 그림 - 글 → 그림 · 그림 → 그림. 기기 안 (SD1.5 + LCM) 이 기본이고, 사용자가 추가한 서버 · 서비스도 같은 화면에서.
/// 결과는 새 파일로 저장하고 (원본을 덮지 않음), 옆에 프롬프트 · 시드 · 모델을 json 으로 남긴다.
class AiImagePage extends StatefulWidget {
  const AiImagePage({super.key, required this.c, this.initImage});
  final AppController c;

  /// 보기 화면 · 탐색기의 [AI 그림으로] - 그림 → 그림의 바탕 그림
  final String? initImage;

  static const routeName = 'aiimage';

  static Future<void> open(NavigatorState nav, {required AppController c, String? initImage}) async {
    var found = false;
    if (initImage == null) {
      nav.popUntil((r) {
        if (r.settings.name == routeName) found = true;
        return found || r.isFirst;
      });
      if (found) return;
    }
    await nav.push(MaterialPageRoute<void>(
      settings: const RouteSettings(name: routeName),
      builder: (_) => AiImagePage(c: c, initImage: initImage),
    ));
  }

  @override
  State<AiImagePage> createState() => _AiImagePageState();
}

/// 결과를 저장할 폴더 (비어 있으면 사진 폴더의 JJ_MKVMaker_AI)
String aiSaveDir(String setting) {
  if (setting.isNotEmpty) return setting;
  if (Platform.isAndroid) return '/storage/emulated/0/Pictures/JJ_MKVMaker_AI';
  final home = Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'] ?? Directory.systemTemp.path;
  return p.join(home, 'Pictures', 'JJ_MKVMaker_AI');
}

class _AiImagePageState extends State<AiImagePage> with RouteAware {
  AppController get c => widget.c;
  late final _prompt = TextEditingController(text: c.settings.aiPrompt);
  final _promptFocus = FocusNode();
  late final _negative = TextEditingController(text: c.settings.aiNegative);
  final _seed = TextEditingController(text: '-1');
  late String? _init = widget.initImage;
  /// 159: 지난 결과를 되살린다 (설정의 목록 + 그림 옆 json 의 시드). 지워진 파일은 빼고 보여 준다
  late final _results = <GeneratedImage>[
    for (final path in c.settings.aiRecent)
      if (File(path).existsSync()) GeneratedImage(path, _seedOf(path)),
  ];
  String? _error;

  static int _seedOf(String path) {
    try {
      final j = jsonDecode(File('${p.withoutExtension(path)}.json').readAsStringSync()) as Map;
      return (j['seed'] as num?)?.toInt() ?? -1;
    } catch (_) {
      return -1;
    }
  }

  /// 목록을 설정에 남긴다 (최근 100장)
  void _saveRecent() {
    final paths = [for (final g in _results) g.path].take(100).toList();
    c.updateSettings((x) => x.aiRecent = paths);
  }

  /// 150: 엔진 원문 ([자세히] 를 눌러야 보임) · 취소 (회색 한 줄, 오류 아님)
  String _detail = '';
  bool _showDetail = false;
  bool _cancelled = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route != null) browserRouteObserver.subscribe(this, route);
  }

  /// 152: 다른 화면으로 가면 글 칸의 포커스를 풀어 둔다 (돌아올 때 자판이 저절로 올라와 결과를 가리지 않게)
  @override
  void didPushNext() => FocusManager.instance.primaryFocus?.unfocus();
  String _step = '';

  AiStore get store => AiStore.instance ??= AiStore(Directory.systemTemp.path);

  @override
  void dispose() {
    browserRouteObserver.unsubscribe(this);
    _prompt.dispose();
    _promptFocus.dispose();
    _negative.dispose();
    _seed.dispose();
    super.dispose();
  }

  AiService? get _service => c.settings.aiServices.where((x) => x.id == c.settings.aiEngine).firstOrNull;

  bool get _local => _service == null;

  bool get _modelsReady => store.sd15Paths(taesd: false) != null;

  Future<void> _generate() async {
    final s = c.settings;
    if (_prompt.text.trim().isEmpty) {
      // 159: 아래 오류 줄은 화면 밖일 수 있다 - 바로 보이게 알리고 글 칸으로
      setState(() => _error = tr('그릴 내용을 적어 주세요'));
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(tr('그릴 내용을 적어 주세요'))));
      _promptFocus.requestFocus();
      return;
    }
    if (_local && !_modelsReady) {
      await openAiModels(context, c);
      if (!_modelsReady) return;
    }
    await c.updateSettings((x) => x
      ..aiNegative = _negative.text
      ..aiPrompt = _prompt.text);
    final req = ImageGenRequest(
      prompt: _prompt.text.trim(),
      negative: _negative.text.trim(),
      width: s.aiWidth,
      height: s.aiHeight,
      steps: s.aiSteps,
      cfg: s.aiCfg,
      seed: int.tryParse(_seed.text.trim()) ?? -1,
      count: s.aiCount,
      initImage: _init,
      strength: s.aiStrength,
      model: _local ? 'sd15-lcm' : (_service!.model.isEmpty ? _service!.kind : _service!.model),
    );
    setState(() {
      _error = null;
      _detail = '';
      _showDetail = false;
      _cancelled = false;
      _step = '';
    });
    try {
      final ImageAiEngine engine;
      if (_local) {
        final device = await pickAiDevice(c, store, onStep: (t) => mounted ? setState(() => _step = t) : null);
        if (device == null) throw ImageAiException(tr('AI 엔진이 없습니다. 환경 설정 > AI 그림에서 받아 주세요.'));
        engine = LocalSdEngine(device: device, models: store.sd15Paths(taesd: s.aiTaesd)!);
      } else {
        engine = RemoteImageEngine(_service!);
      }
      final made = await AiJobs.instance.run(engine, req, outDir: aiSaveDir(s.aiSaveDir));
      if (!mounted) return;
      setState(() => _results.insertAll(0, made));
      _saveRecent();
    } on ImageAiException catch (e) {
      if (mounted) {
        setState(() {
          _cancelled = e.cancelled;
          _error = e.message;
          _detail = e.detail;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _pickInit() async {
    final files = await c.services.storage.pickFiles(title: tr('바탕 그림 고르기'), extensions: c.settings.imageExts);
    if (files.isNotEmpty && mounted) setState(() => _init = files.first);
  }

  /// 결과 옆의 json 을 읽어 같은 조건으로 (시드 그대로)
  void _reuse(GeneratedImage g) {
    try {
      final j = File('${p.withoutExtension(g.path)}.json').readAsStringSync();
      final r = ImageGenRequest.fromJson(Map<String, Object?>.from(jsonDecode(j) as Map));
      setState(() {
        _prompt.text = r.prompt;
        _negative.text = r.negative;
        _seed.text = '${g.seed}';
        _init = r.initImage;
      });
    } catch (_) {
      setState(() => _seed.text = '${g.seed}');
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([c, AiJobs.instance, store]),
      builder: (context, _) {
        final s = c.settings;
        final jobs = AiJobs.instance;
        final compact = isCompact(context);
        return Scaffold(
          body: SwipeNav(
            current: 'aiimage',
            child: Column(children: [
              AppTopBar(
                nav: const AppNavButtons(onAiPage: true),
                actions: AppActions(c: c),
                middle: Text(tr('AI 그림'), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
              ),
              Expanded(
                child: ListView(padding: EdgeInsets.all(compact ? 8 : 16), children: [
                  _engineRow(),
                  if (!_local)
                    // 인터넷 서비스 · 자기 서버를 쓸 때는 늘 알린다
                    _notice(Icons.public, Colors.orangeAccent,
                        trf('그림 · 프롬프트가 기기 밖으로 나갑니다 ({0})', [_service!.label])),
                  if (_local && !_modelsReady)
                    _notice(Icons.download_outlined, JjColors.accent,
                        trf('기기 안에서 그리려면 모델을 받아야 합니다 ({0})', [AiStore.sizeText(aiMissingSize(store))]),
                        action: TextButton(onPressed: () => openAiModels(context, c), child: Text(tr('받기 화면으로')))),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _prompt,
                    focusNode: _promptFocus,
                    minLines: 2,
                    maxLines: 5,
                    decoration: InputDecoration(labelText: tr('그릴 것 (프롬프트, 영어가 잘 됩니다)'), border: const OutlineInputBorder()),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _negative,
                    decoration: InputDecoration(labelText: tr('빼고 싶은 것 (선택)'), border: const OutlineInputBorder()),
                  ),
                  const SizedBox(height: 8),
                  Wrap(spacing: 12, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
                    _drop<String>(tr('크기'), '${s.aiWidth}x${s.aiHeight}', const ['512x512', '512x768', '768x512', '768x768', '1024x1024'],
                        (v) => c.updateSettings((x) {
                              final wh = v.split('x');
                              x.aiWidth = int.parse(wh[0]);
                              x.aiHeight = int.parse(wh[1]);
                            })),
                    _drop<int>(tr('단계'), s.aiSteps, const [2, 4, 6, 8, 12, 20, 30], (v) => c.updateSettings((x) => x.aiSteps = v)),
                    _drop<int>(tr('개수'), s.aiCount, const [1, 2, 4, 8, 16], (v) => c.updateSettings((x) => x.aiCount = v)),
                    // 141: 이름이 잘리지 않게 짧게 · 넉넉히 (설명은 아래 줄)
                    SizedBox(
                      width: 190,
                      child: TextField(
                        controller: _seed,
                        keyboardType: TextInputType.number,
                        decoration: InputDecoration(labelText: tr('시드'), helperText: tr('-1 은 아무렇게나'), isDense: true),
                      ),
                    ),
                  ]),
                  const SizedBox(height: 8),
                  _initRow(s.aiStrength),
                  const SizedBox(height: 12),
                  if (jobs.busy) ...[
                    LinearProgressIndicator(value: jobs.progress),
                    const SizedBox(height: 4),
                    Row(children: [
                      Expanded(child: Text(jobs.statusLine ?? '', style: const TextStyle(fontSize: 12))),
                      OutlinedButton(onPressed: jobs.cancel, child: Text(tr('취소'))),
                    ]),
                  ] else
                    Row(children: [
                      FilledButton.icon(
                        onPressed: _generate,
                        icon: const Icon(Icons.auto_awesome),
                        label: Text(_init == null ? tr('만들기') : tr('그림을 바꿔 만들기')),
                      ),
                      const SizedBox(width: 12),
                      if (_step.isNotEmpty) Expanded(child: Text(_step, style: const TextStyle(fontSize: 12))),
                    ]),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(_error!, style: TextStyle(color: _cancelled ? JjColors.textDim : Colors.redAccent)),
                        if (_detail.isNotEmpty)
                          TextButton(
                            onPressed: () => setState(() => _showDetail = !_showDetail),
                            child: Text(_showDetail ? tr('자세히 닫기') : tr('자세히')),
                          ),
                        if (_showDetail) SelectableText(_detail, style: const TextStyle(fontSize: 11, color: JjColors.textDim)),
                      ]),
                    ),
                  const SizedBox(height: 12),
                  if (_results.isNotEmpty) Text(trf('만든 그림 · 저장: {0}', [aiSaveDir(s.aiSaveDir)]), style: const TextStyle(fontSize: 12)),
                  const SizedBox(height: 6),
                  Wrap(spacing: 8, runSpacing: 8, children: [for (final g in _results) _thumb(g)]),
                ]),
              ),
            ]),
          ),
        );
      },
    );
  }

  Widget _engineRow() {
    final s = c.settings;
    return Row(children: [
      Text(tr('엔진'), style: const TextStyle(fontSize: 13)),
      const SizedBox(width: 8),
      Flexible(
        child: DropdownButton<String>(
          isExpanded: true,
          value: _service == null ? 'local' : s.aiEngine,
          items: [
            DropdownMenuItem(value: 'local', child: Text(tr('이 기기 (SD1.5 + LCM)'))),
            for (final x in s.aiServices) DropdownMenuItem(value: x.id, child: Text('☁ ${x.label}')),
          ],
          onChanged: (v) => c.updateSettings((x) => x.aiEngine = v ?? 'local'),
        ),
      ),
      IconButton(
        tooltip: tr('AI 설정 · 모델 받기 · 서비스 추가'),
        icon: const Icon(Icons.tune),
        onPressed: () => openAiModels(context, c),
      ),
    ]);
  }

  Widget _initRow(double strength) => Wrap(spacing: 8, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
        // 바탕 그림이 무엇인지 바로 보이게 작은 그림으로
        if (_init != null)
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: Image.file(File(_init!), width: 64, height: 64, fit: BoxFit.cover,
                errorBuilder: (_, _, _) => const SizedBox(width: 64, height: 64, child: Icon(Icons.broken_image_outlined))),
          ),
        OutlinedButton.icon(
          onPressed: _pickInit,
          icon: const Icon(Icons.image_outlined, size: 18),
          label: Text(_init == null ? tr('바탕 그림 고르기 (그림 → 그림)') : p.basename(_init!)),
        ),
        if (_init != null) ...[
          IconButton(tooltip: tr('바탕 그림 빼기'), icon: const Icon(Icons.close), onPressed: () => setState(() => _init = null)),
          Text(trf('바꾸는 정도 {0}%', [(strength * 100).round()]), style: const TextStyle(fontSize: 12)),
          SizedBox(
            width: 200,
            child: Slider(
              value: strength,
              min: 0.05,
              max: 1,
              onChanged: (v) => c.updateSettings((x) => x.aiStrength = v),
            ),
          ),
        ],
      ]);

  Widget _thumb(GeneratedImage g) {
    // 153: 갤러리 등에서 지웠으면 빈칸 대신 알리고 목록에서 뺄 수 있게
    if (!File(g.path).existsSync()) {
      return SizedBox(
        width: 160,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 160,
            height: 160,
            color: JjColors.panel,
            alignment: Alignment.center,
            padding: const EdgeInsets.all(8),
            child: Text(tr('파일이 없습니다 (지워졌거나 옮겨짐)'),
                textAlign: TextAlign.center, style: const TextStyle(fontSize: 12, color: JjColors.textDim)),
          ),
          TextButton(
            onPressed: () {
              setState(() => _results.remove(g));
              _saveRecent();
            },
            child: Text(tr('목록에서 빼기'))),
        ]),
      );
    }
    final shown = [for (final r in _results) if (File(r.path).existsSync()) r];
    return Column(mainAxisSize: MainAxisSize.min, children: [
        InkWell(
          onTap: () => openReader(context, c, ImageFilesSource([for (final r in shown) r.path], tempDir: Directory.systemTemp.path, title: tr('AI 그림')),
              start: shown.indexOf(g)),
          child: Image.file(File(g.path), width: 160, height: 160, fit: BoxFit.cover),
        ),
        Row(mainAxisSize: MainAxisSize.min, children: [
          Text(trf('시드 {0}', [g.seed]), style: const TextStyle(fontSize: 11, color: JjColors.textDim)),
          IconButton(
            tooltip: tr('같은 조건으로 다시 (시드 그대로)'),
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.replay, size: 16),
            onPressed: () => _reuse(g),
          ),
          IconButton(
            tooltip: tr('이 그림을 바탕으로 (그림 → 그림)'),
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.edit_outlined, size: 16),
            onPressed: () => setState(() => _init = g.path),
          ),
        ]),
      ]);
  }

  Widget _drop<T>(String label, T value, List<T> items, void Function(T) on) => Row(mainAxisSize: MainAxisSize.min, children: [
        Text(label, style: const TextStyle(fontSize: 13)),
        const SizedBox(width: 6),
        DropdownButton<T>(
          value: items.contains(value) ? value : null,
          hint: Text('$value'),
          items: [for (final x in items) DropdownMenuItem(value: x, child: Text('$x'))],
          onChanged: (v) => v == null ? null : on(v),
        ),
      ]);

  Widget _notice(IconData icon, Color color, String text, {Widget? action}) => Container(
        margin: const EdgeInsets.only(top: 8),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: color.withValues(alpha: 0.5)),
        ),
        child: Row(children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: const TextStyle(fontSize: 13))),
          ?action,
        ]),
      );
}
