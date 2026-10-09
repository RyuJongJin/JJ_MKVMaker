import 'dart:io';

import 'package:flutter/material.dart';

import '../app/ai_local.dart';
import '../app/app_controller.dart';
import '../app/copy_center.dart' show diskSpace;
import '../core/ai_catalog.dart';
import '../core/secret_gate.dart';
import '../l10n/tr.dart';
import '../services/image_ai.dart';
import 'ai_image_page.dart' show aiSaveDir;
import 'confirm.dart';
import 'folder_picker.dart';
import 'license_texts.dart' show showLicenseDocument;
import 'setting_tile.dart';
import 'theme.dart';

/// 기기 안에서 그리는 데 아직 받지 않은 파일 (Windows 는 실행 파일까지, TAESD 포함) - AI 그림 화면 · 받기 화면이 같은 값을 보인다 (139)
List<AiFile> aiMissingFiles(AiStore store) => [
      if (Platform.isWindows) aiFile('engine-vulkan'),
      for (final id in [...sd15LcmFiles, 'taesd']) aiFile(id),
    ].where((f) => !store.isInstalled(f.id)).toList();

int aiMissingSize(AiStore store) => aiMissingFiles(store).fold<int>(0, (a, f) => a + f.size);

/// AI 그림 화면의 [받기 화면으로] · 설정 버튼: AI 설정 (모델 받기 · 처리 장치 · 서비스) 을 따로 연다
Future<void> openAiModels(BuildContext context, AppController c) => Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (ctx) => Scaffold(
        appBar: AppBar(
          // 140: 뒤로 버튼 이름도 화면 언어로
          leading: IconButton(tooltip: tr('뒤로'), icon: const Icon(Icons.arrow_back), onPressed: () => Navigator.maybePop(ctx)),
          title: Text(tr('AI 그림 · 해상도 올리기')),
        ),
        body: ListView(padding: const EdgeInsets.all(12), children: [AiSettings(c: c)]),
      ),
    ));

/// 123 · 121: 환경 설정 > AI 그림 · 해상도 올리기
class AiSettings extends StatefulWidget {
  const AiSettings({super.key, required this.c});
  final AppController c;

  @override
  State<AiSettings> createState() => _AiSettingsState();
}

class _AiSettingsState extends State<AiSettings> {
  AppController get c => widget.c;
  AiStore get store => AiStore.instance ??= AiStore(Directory.systemTemp.path);
  bool _nvidia = false;
  List<SdDevice> _devices = const [];
  String? _error;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final nv = await AiStore.hasNvidia();
    final devs = await sdDevices(store);
    if (mounted) {
      setState(() {
        _nvidia = nv;
        _devices = devs;
      });
    }
  }

  String get _platform => Platform.isAndroid ? 'android' : 'windows';

  List<AiFile> get _files => [
        for (final f in aiCatalog)
          if ((f.platforms.isEmpty || f.platforms.contains(_platform)) && (f.needs != 'nvidia' || _nvidia)) f,
      ];

  /// 받기 전에 라이선스 조건 (있으면) 을 보여 주고 동의를 받는다
  Future<bool> _agree(AiFile f) async {
    // 149-④: 한 번 동의했으면 다시 묻지 않는다
    if (f.terms == null || c.settings.aiAgreed.contains(f.id)) return true;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        scrollable: true,
        title: Text(trf('{0} 라이선스', [tr(f.license)])),
        content: SizedBox(
          width: 520,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(tr(f.terms!)),
            const SizedBox(height: 8),
            SelectableText(f.licenseUrl, style: const TextStyle(fontSize: 12, color: JjColors.textDim)),
            if (f.licenseAsset != null)
              TextButton(
                onPressed: () => showLicenseDocument(ctx, trf('{0} 라이선스', [tr(f.license)]), f.licenseAsset!),
                child: Text(tr('라이선스 원문 보기')),
              ),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('취소'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr('동의하고 받기'))),
        ],
      ),
    );
    if (ok == true) await c.updateSettings((x) => x.aiAgreed = {...x.aiAgreed, f.id}.toList());
    return ok == true;
  }

  /// 받기: 조건 동의를 먼저 모두 받은 뒤 차례로 (기다리는 것은 "차례 기다림")
  Future<void> _install(List<AiFile> files) async {
    final agreed = <AiFile>[];
    for (final f in files) {
      if (store.isFileInstalled(f)) continue;
      if (await _agree(f)) agreed.add(f);
    }
    if (agreed.isEmpty) return;
    try {
      setState(() => _error = null);
      await store.installAll(agreed);
    } on ImageAiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      // 쉬운 말로만 (원문 · 주소는 보이지 않게)
      if (mounted) setState(() => _error = tr('받지 못했습니다. 잠시 뒤 [이어 받기] 를 눌러 주세요'));
    }
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([c, store, AiJobs.instance]),
      builder: (context, _) {
        final s = c.settings;
        final missing = aiMissingFiles(store);
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          SettingTile(
            leading: const Icon(Icons.auto_awesome_outlined),
            title: Text(tr('기기 안에서 그리기 (stable-diffusion.cpp · SD1.5 + LCM)')),
            subtitle: Text(missing.isEmpty
                ? tr('모두 받았습니다. 512×512 한 장에 폰은 약 1분, PC 는 장치에 따라 1 ~ 5분 걸립니다.')
                : trf('그리려면 {0} 를 받아야 합니다 (모델은 받은 뒤 이 기기에만 있고, 그림 · 프롬프트는 밖으로 나가지 않습니다).',
                    [AiStore.sizeText(missing.fold<int>(0, (a, f) => a + f.size))])),
            trailing: missing.isEmpty
                ? null
                : FilledButton.tonal(onPressed: () => _install(missing), child: Text(tr('필요한 것 모두 받기'))),
          ),
          // 149-③: 받기 전에 필요한 공간과 지금 남은 공간을 늘 한 줄로
          if (missing.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
              child: FutureBuilder<(int, int)?>(
                future: diskSpace(store.root),
                builder: (context, snap) {
                  final need = missing.fold<int>(0, (a, f) => a + store.neededSpace(f));
                  final free = snap.data?.$1;
                  return Text(
                    free == null
                        ? trf('필요한 공간 {0}', [AiStore.sizeText(need)])
                        : trf('필요한 공간 {0} · 남은 공간 {1}', [AiStore.sizeText(need), AiStore.sizeText(free)]),
                    style: TextStyle(fontSize: 12, color: free != null && free < need ? Colors.redAccent : JjColors.textDim),
                  );
                },
              ),
            ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(_error!, style: const TextStyle(color: Colors.redAccent)),
            ),
          for (final f in _files) _fileRow(f),
          const Divider(),
          SettingTile(
            leading: const Icon(Icons.memory),
            title: Text(tr('처리 장치')),
            subtitle: Text(s.aiDevice == 'auto'
                ? (s.aiAutoDevice.isEmpty
                    ? tr('자동: 처음 그릴 때 짧게 재서 가장 빠른 장치를 고릅니다')
                    : trf('자동: 잰 결과 {0} 가 가장 빠릅니다', [_devices.where((d) => d.key == s.aiAutoDevice).firstOrNull?.label ?? s.aiAutoDevice]))
                : tr('직접 고름')),
            trailing: DropdownButton<String>(
              value: s.aiDevice == 'auto' || _devices.any((d) => d.key == s.aiDevice) ? s.aiDevice : 'auto',
              items: [
                DropdownMenuItem(value: 'auto', child: Text(tr('자동 (가장 빠른 것)'))),
                for (final d in _devices) DropdownMenuItem(value: d.key, child: Text(d.label)),
              ],
              onChanged: (v) => c.updateSettings((x) => x
                ..aiDevice = v ?? 'auto'
                ..aiAutoDeviceFor = ''), // 다시 고르면 다음에 다시 잼
            ),
          ),
          SwitchListTile(
            value: s.aiTaesd,
            onChanged: (v) => c.updateSettings((x) => x.aiTaesd = v),
            title: Text(tr('빠른 디코더 (TAESD)')),
            subtitle: Text(tr('그림이 거의 같고 마지막 단계가 10배쯤 빠릅니다 (받아 두었을 때)')),
          ),
          SettingTile(
            leading: const Icon(Icons.folder_outlined),
            title: Text(tr('저장 폴더')),
            subtitle: Text(aiSaveDir(s.aiSaveDir)),
            trailing: Wrap(spacing: 6, children: [
              OutlinedButton(
                onPressed: () async {
                  final d = await pickFolder(context, tr('AI 그림 저장 폴더'), aiSaveDir(s.aiSaveDir));
                  if (d != null) await c.updateSettings((x) => x.aiSaveDir = d);
                },
                child: Text(tr('바꾸기')),
              ),
              if (s.aiSaveDir.isNotEmpty)
                TextButton(onPressed: () => c.updateSettings((x) => x.aiSaveDir = ''), child: Text(tr('처음대로'))),
            ]),
          ),
          const Divider(),
          // 121: 해상도 올리기 (보기 화면 위쪽 막대의 [AI 해상도 올리기])
          SettingTile(
            leading: const Icon(Icons.hd_outlined),
            title: Text(tr('해상도 올리기 모델')),
            subtitle: Text(tr('자동: 그래픽카드 (GPU) 가 있으면 사진용, CPU 뿐이면 가볍고 빠른 만화용. 원본은 덮어쓰지 않고 새 파일로 저장합니다')),
            trailing: DropdownButton<String>(
              value: s.aiUpModel,
              items: [
                DropdownMenuItem(value: 'auto', child: Text(tr('자동'))),
                DropdownMenuItem(value: 'photo', child: Text(tr('사진'))),
                DropdownMenuItem(value: 'anime', child: Text(tr('만화 · 그림'))),
              ],
              onChanged: (v) => c.updateSettings((x) => x.aiUpModel = v ?? 'auto'),
            ),
          ),
          SettingTile(
            leading: const Icon(Icons.zoom_out_map),
            title: Text(tr('배율')),
            trailing: DropdownButton<int>(
              value: s.aiUpScale,
              items: [for (final n in const [2, 3, 4]) DropdownMenuItem(value: n, child: Text(trf('{0}배', [n])))],
              onChanged: (v) => c.updateSettings((x) => x.aiUpScale = v ?? 2),
            ),
          ),
          SettingTile(
            leading: const Icon(Icons.image_outlined),
            title: Text(tr('저장 형식')),
            subtitle: s.aiUpFormat == 'jpg' ? Text(trf('JPG 품질 {0}', [s.aiUpJpgQuality])) : Text(tr('WebP 등은 PNG 로 저장합니다')),
            trailing: DropdownButton<String>(
              value: s.aiUpFormat,
              items: [
                DropdownMenuItem(value: 'same', child: Text(tr('원본과 같은 형식'))),
                const DropdownMenuItem(value: 'png', child: Text('PNG')),
                const DropdownMenuItem(value: 'jpg', child: Text('JPG')),
              ],
              onChanged: (v) => c.updateSettings((x) => x.aiUpFormat = v ?? 'same'),
            ),
          ),
          if (s.aiUpFormat == 'jpg')
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Slider(
                value: s.aiUpJpgQuality.toDouble(),
                min: 50,
                max: 100,
                divisions: 50,
                label: '${s.aiUpJpgQuality}',
                onChanged: (v) => c.updateSettings((x) => x.aiUpJpgQuality = v.round()),
              ),
            ),
          SettingTile(
            leading: const Icon(Icons.drive_file_move_outline),
            title: Text(tr('저장 위치')),
            subtitle: Text(s.aiUpDir.isEmpty ? tr('원본 옆에 "이름_x2" (ZIP 은 ZIP 옆 "ZIP이름_AI" 폴더)') : s.aiUpDir),
            trailing: Wrap(spacing: 6, children: [
              OutlinedButton(
                onPressed: () async {
                  final d = await pickFolder(context, tr('해상도를 올린 그림 저장 폴더'), s.aiUpDir.isEmpty ? null : s.aiUpDir);
                  if (d != null) await c.updateSettings((x) => x.aiUpDir = d);
                },
                child: Text(tr('폴더 고르기')),
              ),
              if (s.aiUpDir.isNotEmpty)
                TextButton(onPressed: () => c.updateSettings((x) => x.aiUpDir = ''), child: Text(tr('원본 옆으로'))),
            ]),
          ),
          SettingTile(
            leading: const Icon(Icons.visibility_outlined),
            title: Text(tr('저장한 뒤')),
            trailing: DropdownButton<String>(
              value: s.aiUpAfter,
              items: [
                DropdownMenuItem(value: 'upscaled', child: Text(tr('올린 것으로 계속 보기'))),
                DropdownMenuItem(value: 'original', child: Text(tr('원본으로'))),
              ],
              onChanged: (v) => c.updateSettings((x) => x.aiUpAfter = v ?? 'upscaled'),
            ),
          ),
          const Divider(),
          SettingTile(
            leading: const Icon(Icons.public),
            title: Text(tr('서버 · 서비스 (기기 밖)')),
            subtitle: Text(tr('직접 운영하는 서버 (ComfyUI · Automatic1111, 예: Tailscale 주소) 나 인터넷 서비스 (OpenAI 이미지 API 형식). '
                '넣지 않으면 기기 안에서만 그립니다. 쓸 때는 그림 · 프롬프트가 기기 밖으로 나간다고 늘 알립니다. API 키는 안전 저장소에 둡니다.')),
            trailing: TextButton.icon(
              onPressed: () => editAiService(context, c),
              icon: const Icon(Icons.add, size: 18),
              label: Text(tr('서비스 추가')),
            ),
          ),
          for (final x in s.aiServices)
            Padding(
              padding: const EdgeInsets.only(left: 16),
              child: SettingTile(
                dense: true,
                leading: const Icon(Icons.cloud_outlined),
                title: Text(x.label),
                subtitle: Text('${_kindName(x.kind)} · ${x.url}${x.apiKey.isNotEmpty ? ' · ${tr('키 있음')}' : ''}',
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                  IconButton(
                    tooltip: tr('고치기'),
                    icon: const Icon(Icons.edit_outlined, size: 18),
                    onPressed: () => editAiService(context, c, old: x),
                  ),
                  IconButton(
                    tooltip: tr('지우기'),
                    icon: const Icon(Icons.delete_outline, size: 18),
                    onPressed: () async {
                      final ok = await confirmAction(context,
                          title: trf('"{0}" 을(를) 지울까요?', [x.label]), body: tr('서비스 설정과 저장된 API 키를 지웁니다.'), ok: tr('지우기'));
                      if (!ok) return;
                      await c.updateSettings((y) {
                        y.aiServices = [for (final z in y.aiServices) if (z.id != x.id) z];
                        if (y.aiEngine == x.id) y.aiEngine = 'local';
                      });
                    },
                  ),
                ]),
              ),
            ),
        ]);
      },
    );
  }

  Widget _fileRow(AiFile f) {
    final installed = store.isInstalled(f.id);
    final prog = store.progress[f.id];
    final busy = store.progress.containsKey(f.id);
    final waiting = store.queued.contains(f.id);
    // 받다가 끊겨 조각이 남아 있으면 [이어 받기]
    final partial = !installed && !busy && store.neededSpace(f) < (f.kind == 'engine' ? f.size * 3 : f.size);
    return Padding(
      padding: const EdgeInsets.only(left: 16),
      child: SettingTile(
        dense: true,
        leading: Icon(installed ? Icons.check_circle : Icons.download_outlined,
            color: installed ? JjColors.success : JjColors.textDim, size: 20),
        title: Text(tr(f.name)),
        // 149-①②: 진행 막대 옆에 % · 받은 크기 / 전체 · 남은 시간, 기다리는 것은 "차례 기다림"
        subtitle: busy
            ? Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                LinearProgressIndicator(value: prog),
                const SizedBox(height: 2),
                Text(store.progressText(f.id) ?? '', style: const TextStyle(fontSize: 12)),
              ])
            : Wrap(crossAxisAlignment: WrapCrossAlignment.center, children: [
                Text([
                  AiStore.sizeText(f.size),
                  tr(f.license),
                  if (installed) tr('받음'),
                  // 받을 때 SHA-256 을 공식 값과 맞춰 보았다
                  if (installed && store.isVerified(f)) tr('확인됨'),
                  if (waiting) tr('차례 기다림'),
                  ?store.failures[f.id],
                ].join(' · ')),
                // 175: 라이선스 원문 (저작권 줄 · 허가 문구 그대로)
                if (f.licenseAsset != null)
                  TextButton(
                    style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact, padding: const EdgeInsets.symmetric(horizontal: 6)),
                    onPressed: () => showLicenseDocument(context, trf('{0} 라이선스', [tr(f.license)]), f.licenseAsset!),
                    child: Text(tr('원문')),
                  ),
              ]),
        trailing: busy || waiting
            ? TextButton(onPressed: () => store.cancel(f.id), child: Text(tr('취소')))
            : installed
                ? TextButton(
                    // 151: 그리는 · 올리는 중에 쓰는 파일은 지울 수 없게
                    onPressed: AiJobs.instance.busy && AiJobs.instance.inUse.contains(f.id)
                        ? null
                        : () async {
                      final ok = await confirmAction(context,
                          title: trf('{0} 을(를) 지울까요?', [tr(f.name)]), body: tr('다시 쓰려면 다시 받아야 합니다.'), ok: tr('지우기'));
                      if (ok) {
                        await store.remove(f.id);
                        await _refresh();
                      }
                    },
                    child: Text(tr('지우기')))
                : OutlinedButton(
                    onPressed: () => _install([f]),
                    child: Text(store.failures[f.id]?.contains(tr('파일이 깨졌습니다')) == true
                        ? tr('다시 받기')
                        : partial
                            ? tr('이어 받기')
                            : tr('받기'))),
      ),
    );
  }
}

String _kindName(String kind) => switch (kind) {
      'comfy' => 'ComfyUI',
      'openai' => tr('OpenAI 이미지 API 형식'),
      _ => 'Automatic1111 · Forge',
    };

/// 서비스 추가 · 고치기. 저장된 API 키가 칸에 채워지므로 고칠 때는 먼저 마스터 비밀번호 (127 과 같음)
Future<void> editAiService(BuildContext context, AppController c, {AiService? old}) async {
  if (old != null && old.apiKey.isNotEmpty && !await SecretGate.pass(force: true)) return;
  if (!context.mounted) return;
  final name = TextEditingController(text: old?.name ?? '');
  final url = TextEditingController(text: old?.url ?? 'http://');
  final model = TextEditingController(text: old?.model ?? '');
  final key = TextEditingController(text: old?.apiKey ?? '');
  var kind = old?.kind ?? 'a1111';
  var hide = true;
  final saved = await showDialog<AiService>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, set) => AlertDialog(
        scrollable: true,
        title: Text(old == null ? tr('서비스 추가') : tr('서비스 고치기')),
        content: SizedBox(
          width: 480,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Container(
              padding: const EdgeInsets.all(8),
              color: Colors.orangeAccent.withValues(alpha: 0.1),
              child: Text(tr('이 서비스로 그리면 그림 · 프롬프트가 기기 밖 (이 주소) 으로 나갑니다.'), style: const TextStyle(fontSize: 12)),
            ),
            TextField(controller: name, decoration: InputDecoration(labelText: tr('이름'))),
            DropdownButtonFormField<String>(
              initialValue: kind,
              decoration: InputDecoration(labelText: tr('방식')),
              items: [for (final k in AiService.kinds) DropdownMenuItem(value: k, child: Text(_kindName(k)))],
              onChanged: (v) => set(() => kind = v ?? 'a1111'),
            ),
            TextField(
              controller: url,
              keyboardType: TextInputType.url,
              decoration: InputDecoration(
                labelText: tr('주소'),
                helperText: switch (kind) {
                  'comfy' => tr('예: http://100.x.x.x:8188 (ComfyUI)'),
                  'openai' => tr('예: https://api.openai.com (경로 /v1/images/generations 를 붙여 부름)'),
                  _ => tr('예: http://100.x.x.x:7860 (--api 로 켠 Automatic1111 · Forge)'),
                },
              ),
            ),
            TextField(
              controller: model,
              decoration: InputDecoration(
                labelText: tr('모델 (선택)'),
                helperText: kind == 'comfy' ? tr('체크포인트 파일 이름 (예: sd_xl_turbo_1.0_fp16.safetensors)') : null,
              ),
            ),
            TextField(
              controller: key,
              obscureText: hide,
              decoration: InputDecoration(
                labelText: kind == 'a1111' ? tr('API 키 또는 아이디:비밀번호 (선택)') : tr('API 키 (선택)'),
                suffixIcon: IconButton(icon: Icon(hide ? Icons.visibility : Icons.visibility_off), onPressed: () => set(() => hide = !hide)),
              ),
            ),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('취소'))),
          FilledButton(
            onPressed: () {
              final u = url.text.trim();
              if (!u.startsWith('http://') && !u.startsWith('https://') || u.length < 10) return;
              Navigator.pop(
                ctx,
                AiService(
                  id: old?.id ?? 'ai${DateTime.now().millisecondsSinceEpoch}',
                  name: name.text.trim(),
                  url: u,
                  kind: kind,
                  model: model.text.trim(),
                  apiKey: key.text.trim(),
                ),
              );
            },
            child: Text(tr('저장')),
          ),
        ],
      ),
    ),
  );
  for (final x in [name, url, model, key]) {
    x.dispose();
  }
  if (saved == null) return;
  await c.updateSettings((x) => x.aiServices = [
        for (final y in x.aiServices) if (y.id != saved.id) y,
        saved,
      ]);
}
