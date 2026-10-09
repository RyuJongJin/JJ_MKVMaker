import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show MethodChannel;
import 'package:path/path.dart' as p;

import '../app/ai_local.dart';
import '../app/ai_upscale.dart';
import '../app/app_controller.dart';
import '../core/ai_catalog.dart';
import '../core/reader_sources.dart';
import '../core/vfs.dart';
import '../l10n/tr.dart';
import '../services/image_ai.dart' show ImageAiException;
import 'ai_image_page.dart' show aiSaveDir;
import 'confirm.dart';
import 'explorer_page.dart' show ExplorerPage;
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

/// 준비: 모델 · 엔진이 없으면 그 자리에서 무엇을 받을지 고르고 받는다 (156 - 설정 화면으로 보내지 않음). 못 하면 null
/// 시험용: 받기 · 엔진 고르기 없이 쓸 업스케일러 (가짜 엔진)
@visibleForTesting
AiUpscaler Function()? debugUpscalerForTest;

Future<AiUpscaler?> _prepare(BuildContext context, AppController c) async {
  if (debugUpscalerForTest case final f?) return f();
  final store = AiStore.instance ??= AiStore(Directory.systemTemp.path);
  Future<AiUpscaler?> ready() =>
      prepareUpscaler(store, modelSetting: c.settings.aiUpModel, device: c.settings.aiDevice, autoDevice: c.settings.aiAutoDevice);
  final up = await ready();
  if (up != null || !context.mounted) return up;
  // 엔진 (Windows 는 받아야 함) · 모델 중 없는 것
  final engine = await pickUpscaleDevice(store, device: c.settings.aiDevice) == null && Platform.isWindows ? aiFile('engine-vulkan') : null;
  if (!context.mounted) return null;
  final setting = c.settings.aiUpModel;
  final anime = aiFile('esrgan-anime6b'), photo = aiFile('esrgan-x4plus');
  final choices = setting == 'photo'
      ? [photo]
      : setting == 'anime'
          ? [anime]
          : [anime, photo];
  final models = choices.any((f) => store.isFileInstalled(f)) ? <AiFile>[] : choices;
  String label(AiFile f) =>
      '${f.id == anime.id ? tr('만화 · 그림용') : tr('사진용')} (${AiStore.sizeText(f.size + (engine?.size ?? 0))})';
  final picked = await showDialog<AiFile?>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(tr('AI 해상도 올리기')),
      content: Text([
        if (models.isNotEmpty) tr('해상도 올리기 모델을 받아야 합니다. 어느 것을 받을까요?'),
        if (models.length > 1) tr('만화 · 그림용은 가볍고 빠르며, 사진용은 사진의 질감을 더 잘 살리지만 그래픽카드가 없으면 느립니다.'),
        if (engine != null) trf('AI 엔진 ({0}) 도 함께 받습니다.', [engine.name]),
      ].join('\n\n')),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('취소'))),
        if (models.isEmpty && engine != null)
          FilledButton(onPressed: () => Navigator.pop(ctx, engine), child: Text(trf('받기 ({0})', [AiStore.sizeText(engine.size)]))),
        for (final f in models) FilledButton(onPressed: () => Navigator.pop(ctx, f), child: Text(label(f))),
      ],
    ),
  );
  if (picked == null || !context.mounted) return null;
  final files = [?engine, if (picked != engine) picked];
  final ok = await _download(context, store, files);
  if (!ok || !context.mounted) return null;
  return ready();
}

/// 받는 동안 진행 창 (취소). 다 받았으면 true
Future<bool> _download(BuildContext context, AiStore store, List<AiFile> files) async {
  final nav = Navigator.of(context);
  var cancelled = false;
  unawaited(showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => AlertDialog(
      title: Text(tr('받는 중')),
      content: SizedBox(
        width: 420,
        child: ListenableBuilder(
          listenable: store,
          builder: (_, _) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            for (final f in files) ...[
              Text(f.name, style: const TextStyle(fontSize: 13)),
              Text(store.isFileInstalled(f) ? tr('받음') : store.progressText(f.id) ?? tr('준비하는 중'),
                  style: const TextStyle(fontSize: 12, color: JjColors.textDim)),
              const SizedBox(height: 8),
            ],
          ]),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () {
            cancelled = true;
            for (final f in files) {
              store.cancel(f.id);
            }
          },
          child: Text(tr('취소')),
        ),
      ],
    ),
  ));
  String? error;
  try {
    await store.installAll(files);
  } on ImageAiException catch (e) {
    error = e.message;
  } catch (_) {
    error = tr('받지 못했습니다. 잠시 뒤 다시 해 주세요');
  }
  nav.pop();
  final ok = files.every(store.isFileInstalled);
  if (!ok && !cancelled && context.mounted) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(error ?? tr('받지 못했습니다. 잠시 뒤 다시 해 주세요'))));
  }
  return ok;
}

/// 156-2: 걸린 시간을 남긴다 (다음에 "한 장 약 n초" 로)
Future<void> _recordSpeed(AppController c, AiUpscaler up, String input, Duration took) async {
  try {
    final mp = megapixels(await File(input).readAsBytes());
    if (mp == null || mp <= 0) return;
    final v = took.inMilliseconds / 1000 / mp;
    await c.updateSettings((x) => x.aiUpSecPerMp = {...x.aiUpSecPerMp, upscaleSpeedKey(up): v});
  } catch (_) {}
}

/// "이 기기에서 한 장 약 n초 (지난번 걸린 시간 기준)" (처음이면 null)
Future<String?> _estimateText(AppController c, AiUpscaler up, String input) async {
  try {
    final mp = megapixels(await File(input).readAsBytes());
    final d = mp == null ? null : upscaleEstimate(c.settings.aiUpSecPerMp, up, mp);
    return d == null ? null : trf('이 기기에서 한 장 약 {0} (지난번 걸린 시간 기준)', [AiJobs.durationText(d)]);
  } catch (_) {
    return null;
  }
}

/// 121: 한 장 올리기 → 진행 (취소) → [원본 / 올린 것] 비교 → [저장] (새 파일, 원본을 덮지 않음). 저장한 경로 (안 하면 null)
Future<String?> upscaleOne(BuildContext context, AppController c, {required String input, required String nameFrom, required String outDir}) async {
  // 176: 한 장도 작업 (AiJobs) 으로 - 하나씩만
  if (AiJobs.instance.busy) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(tr('이미 작업 중입니다'))));
    return null;
  }
  final up = await _prepare(context, c);
  if (up == null || !context.mounted) return null;
  final progress = ValueNotifier<double?>(null);
  // 167: 남은 시간 (타일 한 장에 걸린 초로) - 모르면 null
  final left = ValueNotifier<Duration?>(null);
  var cancelled = false;
  var toPhoto = false;
  // 176: [뒤에서 계속] - 진행 창만 닫고 작업은 계속 (작업 알림 · 작업 현황에서 보이고, 끝나면 [보기])
  var background = false;
  var dialogOpen = true;
  // 관리자: CPU 뿐이라 자동이 만화용을 고르면 사진은 질감이 뭉개질 수 있다 - 알리고 바로 바꿀 수 있게
  final cpuAnime = c.settings.aiUpModel == 'auto' && up.device.backend == 'cpu' && up.modelId == 'esrgan-anime6b';
  final estimate = await _estimateText(c, up, input);
  if (!context.mounted) return null;
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
            // 167: 모델을 읽는 동안은 숫자 없이 움직이는 막대 (예전엔 읽기 막대가 100% 로 보였다)
            ValueListenableBuilder<Duration?>(
              valueListenable: left,
              builder: (_, d, _) => Text(
                  v == null
                      ? tr('준비하는 중')
                      : d == null
                          ? '${(v * 100).round()}%'
                          : '${(v * 100).round()}% · ${trf('약 {0} 남음', [AiJobs.durationText(d)])}',
                  style: const TextStyle(fontSize: 12)),
            ),
            if (estimate != null) Text(estimate, style: const TextStyle(fontSize: 12, color: JjColors.textDim)),
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
        TextButton(
          onPressed: () {
            background = true;
            Navigator.pop(ctx);
          },
          child: Text(tr('뒤에서 계속')),
        ),
      ],
    ),
  ).whenComplete(() => dialogOpen = false));
  String? four;
  Object? error;
  final watch = Stopwatch()..start();
  final nameShort = p.basename(nameFrom);
  try {
    // 176: 작업 (AiJobs) 으로 - 작업 알림 · 앞 서비스 (Android) · 작업 현황에 나오고, 화면을 떠나도 계속한다
    await AiJobs.instance.runTask(trf('AI 해상도 올리기: {0}', [nameShort]), 1, (_, prog) async {
      four = await up.upscale4x(input, onProgress: (v) {
        progress.value = v;
        prog(v);
      }, onEta: (d) => left.value = d);
    }, onCancel: () {
      cancelled = true;
      up.cancel();
    }, uses: const {'esrgan-x4plus', 'esrgan-anime6b', 'engine-vulkan', 'engine-cuda', 'engine-cudart'});
    if (four != null) await _recordSpeed(c, up, input, watch.elapsed);
  } catch (e) {
    error = e;
  }
  if (dialogOpen) nav.pop(); // 진행 창
  if (toPhoto && context.mounted) {
    await c.updateSettings((x) => x.aiUpModel = 'photo');
    if (!context.mounted) return null;
    return upscaleOne(context, c, input: input, nameFrom: nameFrom, outDir: outDir);
  }
  final result = four;
  if (result == null) {
    final text = cancelled ? null : '$error';
    if (text == null) return null;
    if (!background && context.mounted) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(text)));
    } else {
      AiJobs.instance.done(trf('{0}: {1}', [nameShort, text]));
    }
    return null;
  }
  // 176: 화면에 남아 있으면 바로 비교, 떠났으면 (뒤에서 계속 · 화면 닫음) 결과를 남겨 두고 [보기]
  if (!background && context.mounted) return _compareAndSave(Navigator.of(context), c, result, input: input, nameFrom: nameFrom, outDir: outDir);
  final text = trf('{0} 올림 - [보기] 로 비교하고 저장', [nameShort]);
  AiJobs.instance.done(text,
      view: () async {
        AiJobs.instance.clearDoneView();
        await _compareAndSave(nav, c, result, input: input, nameFrom: nameFrom, outDir: outDir);
      },
      dispose: () {
        try {
          Directory(p.dirname(result)).deleteSync(recursive: true);
        } catch (_) {}
      });
  c.note('${tr('AI 해상도 올리기')}: $text');
  if (Platform.isAndroid) {
    try {
      await const MethodChannel('jj_mkvmaker/android').invokeMethod<void>('notifyDone', {'title': tr('AI 해상도 올리기'), 'text': text});
    } catch (_) {}
  }
  return null;
}

/// 4배 결과 [four] 를 [원본 / 올린 것] 비교 → [저장] (새 파일, 원본을 덮지 않음). 끝나면 임시 결과를 지운다
Future<String?> _compareAndSave(NavigatorState nav, AppController c, String four,
    {required String input, required String nameFrom, required String outDir}) async {
  final messenger = ScaffoldMessenger.maybeOf(nav.context);
  try {
    final save = await nav.push<bool>(MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => UpscaleCompareView(original: input, upscaled: four, title: p.basename(nameFrom)),
    ));
    if (save != true) return null;
    final saved = await saveUpscaled(four, source: nameFrom, original: input, o: upscaleOptionsOf(c, outDir: outDir));
    messenger?.showSnackBar(SnackBar(content: Text(trf('저장했습니다: {0}', [saved]))));
    return saved;
  } catch (e) {
    messenger?.showSnackBar(SnackBar(content: Text(trf('저장하지 못했습니다: {0}', [e]))));
    return null;
  } finally {
    try {
      await Directory(p.dirname(four)).delete(recursive: true);
    } catch (_) {}
  }
}

/// 157 · 162: 저장한 폴더 열기 - Android 는 이 앱의 파일 탐색기로 (삼성 파일 앱 대신), Windows 는 탐색기로
Future<void> openFolderInApp(NavigatorState nav, AppController c, String dir) async {
  if (Platform.isAndroid) {
    await ExplorerPage.openAt(nav, c: c, dir: dir);
  } else {
    await c.services.shell.revealFile(dir);
  }
}

/// 121: 폴더 · ZIP 의 모든 장을 올려 저장 (백그라운드 - 작업 알림 · 작업 현황에 남은 장 · 예상 시간)
Future<void> upscaleAll(BuildContext context, AppController c, ReaderSource src) async {
  final n = src.length;
  final up = await _prepare(context, c);
  if (up == null || !context.mounted) return;
  // 156-2: 첫 장 크기와 지난번 걸린 시간으로 한 장 · 모두의 예상 시간
  String? estimate;
  try {
    final first = n == 0 ? null : await readerPageFile(c, src, 0);
    final mp = first == null ? null : megapixels(await File(first.$1).readAsBytes());
    final d = mp == null ? null : upscaleEstimate(c.settings.aiUpSecPerMp, up, mp);
    if (d != null) {
      estimate = trf('이 기기에서 한 장 약 {0} · 모두 약 {1} (지난번 걸린 시간 기준)',
          [AiJobs.durationText(d), AiJobs.durationText(d * n)]);
    }
  } catch (_) {}
  if (!context.mounted) return;
  final ok = await confirmAction(
    context,
    title: trf('{0}장 모두 해상도 올리기', [n]),
    body: [
      trf('{0}배로 올려 새 파일로 저장합니다. 원본 · ZIP 은 그대로입니다. 화면을 닫아도 계속하며 작업 알림에 남은 장과 예상 시간이 보입니다.', [c.settings.aiUpScale]),
      ?estimate,
    ].join('\n\n'),
    ok: tr('시작'),
    danger: false,
  );
  if (!ok || !context.mounted) return;
  final messenger = ScaffoldMessenger.maybeOf(context);
  final nav = Navigator.of(context);
  final failed = <String>[];
  String? lastDir;
  final done = await AiJobs.instance.runTask(tr('AI 해상도 올리기'), n, (i, progress) async {
    final file = await readerPageFile(c, src, i);
    if (file == null) return;
    try {
      final watch = Stopwatch()..start();
      final saved = await up.upscaleAndSave(file.$1, upscaleOptionsOf(c, outDir: file.$3), nameFrom: file.$2, onProgress: progress);
      await _recordSpeed(c, up, file.$1, watch.elapsed);
      lastDir = p.dirname(saved);
    } catch (e) {
      failed.add('${src.pageName(i)}: $e');
    }
  }, onCancel: up.cancel, uses: {'esrgan-x4plus', 'esrgan-anime6b', 'engine-vulkan', 'engine-cuda', 'engine-cudart'});
  // 157: 끝나면 화면 · 작업 현황 · 알림 (Android) · 작업 기록에 "n장 저장: 폴더" 와 [열기]
  final saved = done - failed.length;
  final text = [
    if (done < n) trf('{0}장 중 {1}장에서 멈췄습니다', [n, done]),
    trf('{0}장 저장: {1}', [saved, lastDir ?? '-']),
    if (failed.isNotEmpty) trf('{0}장은 실패했습니다', [failed.length]),
  ].join(' · ');
  AiJobs.instance.done(text, dir: lastDir);
  c.note('${tr('AI 해상도 올리기')}: $text');
  if (Platform.isAndroid) {
    try {
      await const MethodChannel('jj_mkvmaker/android').invokeMethod<void>('notifyDone', {'title': tr('AI 해상도 올리기'), 'text': text});
    } catch (_) {}
  }
  final dir = lastDir;
  messenger?.showSnackBar(SnackBar(
    duration: const Duration(seconds: 10),
    content: Text(text),
    action: dir == null ? null : SnackBarAction(label: tr('열기'), onPressed: () => openFolderInApp(nav, c, dir)),
  ));
}

/// 원본 / 올린 것을 바꿔 보며 비교 (확대해서 볼 수 있음). [저장] 이면 true, 저장하지 않고 닫으면 false
class UpscaleCompareView extends StatefulWidget {
  const UpscaleCompareView({super.key, required this.original, required this.upscaled, required this.title});
  final String original;
  final String upscaled;
  final String title;

  @override
  State<UpscaleCompareView> createState() => UpscaleCompareViewState();
}

class UpscaleCompareViewState extends State<UpscaleCompareView> {
  bool _up = true;
  final _zoom = TransformationController();

  @override
  void dispose() {
    _zoom.dispose();
    super.dispose();
  }

  /// 160: 저장하지 않고 닫으면 올린 그림이 지워지므로 묻는다 (닫기 버튼 · 뒤로 키 · 뒤로 몸짓)
  Future<void> _close() async {
    final r = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('저장하지 않고 닫을까요?')),
        content: Text(tr('올린 그림은 지워집니다. 다시 보려면 해상도 올리기를 다시 해야 합니다.')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('취소'))),
          TextButton(onPressed: () => Navigator.pop(ctx, 'discard'), child: Text(tr('저장하지 않고 닫기'))),
          FilledButton.icon(
            onPressed: () => Navigator.pop(ctx, 'save'),
            icon: const Icon(Icons.save_outlined, size: 18),
            label: Text(tr('저장')),
          ),
        ],
      ),
    );
    if (!mounted || r == null) return;
    Navigator.pop(context, r == 'save');
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _close();
      },
      child: _page(context),
    );
  }

  Widget _page(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        leading: IconButton(tooltip: tr('닫기'), icon: const Icon(Icons.close), onPressed: _close),
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
