import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../app/ai_local.dart';
import '../app/ai_upscale.dart';
import '../app/app_controller.dart';
import '../core/reader_sources.dart';
import '../core/vfs.dart';
import '../l10n/tr.dart';
import 'ai_image_page.dart' show aiSaveDir;
import 'ai_settings.dart';
import 'confirm.dart';
import 'theme.dart';

UpscaleOptions upscaleOptionsOf(AppController c, {String? outDir}) {
  final s = c.settings;
  return UpscaleOptions(
    model: s.aiUpModel,
    scale: s.aiUpScale,
    format: s.aiUpFormat,
    jpgQuality: s.aiUpJpgQuality,
    outDir: outDir ?? s.aiUpDir,
  );
}

/// 보기 화면의 i 번째 장을 이 기기의 파일로 (WebDAV 는 받아 두고, ZIP 은 꺼내 임시 파일로) 과
/// 저장할 이름 기준 (ZIP 은 ZIP 옆 "ZIP이름_AI" 폴더, WebDAV 는 AI 그림 저장 폴더 - 원본 · ZIP 은 바꾸지 않음)
Future<(String input, String nameFrom, String outDir)?> readerPageFile(AppController c, ReaderSource src, int i) async {
  final s = c.settings;
  if (src is ImageFilesSource) {
    final path = src.paths[i];
    if (!isDav(path)) return (path, path, s.aiUpDir);
    final local = await vLocalCopy(path, src.tempDir);
    return (local, p.join(aiSaveDir(s.aiSaveDir), vBasename(path)), s.aiUpDir.isEmpty ? aiSaveDir(s.aiSaveDir) : s.aiUpDir);
  }
  if (src is ZipImagesSource) {
    final e = src.entries[i];
    final tmp = await Directory.systemTemp.createTemp('jj_zip_up_');
    final name = p.basename(e.name);
    final f = File(p.join(tmp.path, name))..writeAsBytesSync(e.readBytes() ?? const []);
    final beside = isDav(src.path)
        ? aiSaveDir(s.aiSaveDir)
        : p.join(p.dirname(src.path), '${p.basenameWithoutExtension(src.path)}_AI');
    final out = s.aiUpDir.isEmpty ? beside : s.aiUpDir;
    return (f.path, p.join(out, name), out);
  }
  return null; // PDF 등은 아직
}

/// 준비: 모델 · 엔진이 없으면 받기 화면으로 (null)
Future<AiUpscaler?> _prepare(BuildContext context, AppController c) async {
  final store = AiStore.instance ??= AiStore(Directory.systemTemp.path);
  final up = await prepareUpscaler(store, modelSetting: c.settings.aiUpModel, device: c.settings.aiDevice, autoDevice: c.settings.aiAutoDevice);
  if (up == null && context.mounted) {
    ScaffoldMessenger.maybeOf(context)
        ?.showSnackBar(SnackBar(content: Text(tr('해상도 올리기 모델을 받아 주세요 (환경 설정 > AI 그림)'))));
    await openAiModels(context, c);
  }
  return up;
}

/// 121: 한 장 올리기 → 진행 (취소) → [원본 / 올린 것] 비교 → [저장] (새 파일, 원본을 덮지 않음). 저장한 경로 (안 하면 null)
Future<String?> upscaleOne(BuildContext context, AppController c, {required String input, required String nameFrom, required String outDir}) async {
  final up = await _prepare(context, c);
  if (up == null || !context.mounted) return null;
  final progress = ValueNotifier<double?>(null);
  var cancelled = false;
  var toPhoto = false;
  // 관리자: CPU 뿐이라 자동이 만화용을 고르면 사진은 질감이 뭉개질 수 있다 - 알리고 바로 바꿀 수 있게
  final cpuAnime = c.settings.aiUpModel == 'auto' && up.device.backend == 'cpu' && up.modelId == 'esrgan-anime6b';
  final nav = Navigator.of(context);
  unawaited(showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => AlertDialog(
      title: Text(tr('AI 해상도 올리기')),
      content: SizedBox(
        width: 420,
        child: ValueListenableBuilder<double?>(
          valueListenable: progress,
          builder: (_, v, _) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(trf('{0} · {1}배 · {2}', [p.basename(nameFrom), c.settings.aiUpScale, up.device.label])),
            const SizedBox(height: 10),
            LinearProgressIndicator(value: v),
            const SizedBox(height: 4),
            Text(v == null ? tr('준비하는 중') : '${(v * 100).round()}%', style: const TextStyle(fontSize: 12)),
            if (cpuAnime) ...[
              const SizedBox(height: 10),
              Text(tr("사진에는 '사진' 모델이 더 낫지만, 이 기기 (그래픽카드 없음) 에서는 한 장에 약 20분 걸립니다."),
                  style: const TextStyle(fontSize: 12, color: JjColors.textDim)),
              TextButton(
                onPressed: () {
                  toPhoto = true;
                  cancelled = true;
                  up.cancel();
                },
                child: Text(tr("'사진' 모델로 바꿔 다시")),
              ),
            ],
          ]),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () {
            cancelled = true;
            up.cancel();
          },
          child: Text(tr('취소')),
        ),
      ],
    ),
  ));
  String? four;
  Object? error;
  try {
    four = await up.upscale4x(input, onProgress: (v) => progress.value = v);
  } catch (e) {
    error = e;
  }
  nav.pop(); // 진행 창
  if (!context.mounted) return null;
  if (toPhoto) {
    await c.updateSettings((x) => x.aiUpModel = 'photo');
    if (!context.mounted) return null;
    return upscaleOne(context, c, input: input, nameFrom: nameFrom, outDir: outDir);
  }
  if (four == null) {
    if (!cancelled) ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text('$error')));
    return null;
  }
  try {
    final save = await Navigator.of(context).push<bool>(MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => _CompareView(original: input, upscaled: four!, title: p.basename(nameFrom)),
    ));
    if (save != true || !context.mounted) return null;
    final saved = await saveUpscaled(four, source: nameFrom, original: input, o: upscaleOptionsOf(c, outDir: outDir));
    if (context.mounted) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(trf('저장했습니다: {0}', [saved]))));
    }
    return saved;
  } catch (e) {
    if (context.mounted) ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(trf('저장하지 못했습니다: {0}', [e]))));
    return null;
  } finally {
    try {
      await Directory(p.dirname(four)).delete(recursive: true);
    } catch (_) {}
  }
}

/// 121: 폴더 · ZIP 의 모든 장을 올려 저장 (백그라운드 - 작업 알림 · 작업 현황에 남은 장 · 예상 시간)
Future<void> upscaleAll(BuildContext context, AppController c, ReaderSource src) async {
  final n = src.length;
  final ok = await confirmAction(
    context,
    title: trf('{0}장 모두 해상도 올리기', [n]),
    body: trf('{0}배로 올려 새 파일로 저장합니다. 원본 · ZIP 은 그대로입니다. 화면을 닫아도 계속하며 작업 알림에 남은 장과 예상 시간이 보입니다.', [c.settings.aiUpScale]),
    ok: tr('시작'),
    danger: false,
  );
  if (!ok || !context.mounted) return;
  final up = await _prepare(context, c);
  if (up == null || !context.mounted) return;
  final messenger = ScaffoldMessenger.maybeOf(context);
  final failed = <String>[];
  String? lastDir;
  final done = await AiJobs.instance.runTask(tr('AI 해상도 올리기'), n, (i, progress) async {
    final file = await readerPageFile(c, src, i);
    if (file == null) return;
    try {
      final saved = await up.upscaleAndSave(file.$1, upscaleOptionsOf(c, outDir: file.$3), nameFrom: file.$2, onProgress: progress);
      lastDir = p.dirname(saved);
    } catch (e) {
      failed.add('${src.pageName(i)}: $e');
    }
  }, onCancel: up.cancel, uses: {'esrgan-x4plus', 'esrgan-anime6b', 'engine-vulkan', 'engine-cuda', 'engine-cudart'});
  messenger?.showSnackBar(SnackBar(
    duration: const Duration(seconds: 8),
    content: Text([
      trf('{0}장을 올려 저장했습니다{1}', [done - failed.length, lastDir == null ? '' : ': $lastDir']),
      if (failed.isNotEmpty) trf('{0}장은 실패했습니다', [failed.length]),
    ].join(' · ')),
  ));
}

/// 원본 / 올린 것을 바꿔 보며 비교 (확대해서 볼 수 있음)
class _CompareView extends StatefulWidget {
  const _CompareView({required this.original, required this.upscaled, required this.title});
  final String original;
  final String upscaled;
  final String title;

  @override
  State<_CompareView> createState() => _CompareViewState();
}

class _CompareViewState extends State<_CompareView> {
  bool _up = true;
  final _zoom = TransformationController();

  @override
  void dispose() {
    _zoom.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        leading: IconButton(tooltip: tr('닫기'), icon: const Icon(Icons.close), onPressed: () => Navigator.pop(context, false)),
        title: Text(widget.title, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          SegmentedButton<bool>(
            segments: [
              ButtonSegment(value: false, label: Text(tr('원본'))),
              ButtonSegment(value: true, label: Text(tr('올린 것'))),
            ],
            selected: {_up},
            onSelectionChanged: (v) => setState(() => _up = v.first),
          ),
          const SizedBox(width: 8),
          FilledButton.icon(
            onPressed: () => Navigator.pop(context, true),
            icon: const Icon(Icons.save_outlined, size: 18),
            label: Text(tr('저장')),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: InteractiveViewer(
        transformationController: _zoom,
        maxScale: 8,
        child: Center(
          // 같은 크기로 보여 확대해 비교한다 (원본은 부드럽게 늘리지 않고 픽셀 그대로)
          child: Image.file(File(_up ? widget.upscaled : widget.original),
              key: ValueKey(_up), fit: BoxFit.contain, filterQuality: _up ? FilterQuality.medium : FilterQuality.none,
              width: double.infinity, height: double.infinity),
        ),
      ),
      bottomNavigationBar: Container(
        color: JjColors.panel,
        padding: const EdgeInsets.all(8),
        child: Text(_up ? tr('올린 것 (AI)') : tr('원본'), textAlign: TextAlign.center),
      ),
    );
  }
}
