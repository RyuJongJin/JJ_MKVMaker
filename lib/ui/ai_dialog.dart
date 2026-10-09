import 'dart:io';

import 'package:flutter/material.dart';

import '../app/app_controller.dart';
import '../core/languages.dart';
import '../core/models.dart';
import '../services/model_store.dart';
import 'license_texts.dart' show NllbLicenseNote;
import 'theme.dart';
import '../l10n/tr.dart';

/// AI 자막 만들기 설정 창
/// [targets] 를 주면 그 동영상들만 (탐색기 "자막 만들기" 메뉴 · 여러 개 선택)
/// [thenBuild]: 자막을 만든 뒤 그 동영상들을 이어서 MKV 로 만든다
Future<void> showAiDialog(BuildContext context, AppController c, VideoItem current,
    {List<VideoItem>? targets, bool thenBuild = false}) async {
  final list = targets ?? [current];
  Future<void> run(List<VideoItem> v, AiOptions o) =>
      thenBuild ? c.aiThenBuild(v, o) : c.generateAiSubtitles(v, o);
  // 환경 설정에서 "매번 묻기" 를 끄면 마지막 설정으로 바로 시작
  if (!c.settings.askAiOptions) {
    await run(list, c.aiOptions);
    return;
  }
  final result = await showDialog<(AiOptions, bool)>(
    context: context,
    builder: (_) => _AiDialog(
        c: c, videoCount: targets == null ? c.videos.length : 1, targetCount: list.length, thenBuild: thenBuild),
  );
  if (result == null) return;
  final (opts, all) = result;
  await run(all ? List.of(c.videos) : list, opts);
}

class _AiDialog extends StatefulWidget {
  final AppController c;
  final int videoCount;

  /// 이번에 자막을 만들 동영상 수 · 이어서 MKV 도 만드는지 (제목에 표시)
  final int targetCount;
  final bool thenBuild;
  const _AiDialog({required this.c, required this.videoCount, this.targetCount = 1, this.thenBuild = false});

  @override
  State<_AiDialog> createState() => _AiDialogState();
}

class _AiDialogState extends State<_AiDialog> {
  late AiOptions _o = widget.c.aiOptions;
  bool _all = false;
  final Map<String, bool> _installed = {};

  @override
  void initState() {
    super.initState();
    for (final m in [...whisperModels, nllbModel]) {
      widget.c.services.models.isInstalled(m).then((ok) {
        if (mounted) setState(() => _installed[m.id] = ok);
      });
    }
  }

  Widget _status(ModelSpec m) {
    final ok = _installed[m.id];
    if (ok == null) return const SizedBox();
    return Text(ok ? tr('설치됨') : trf('처음 사용 시 내려받기 {0}', [m.sizeLabel]),
        style: TextStyle(fontSize: 11, color: ok ? JjColors.success : JjColors.textDim));
  }

  @override
  Widget build(BuildContext context) {
    final extra = languages.where((l) => !_o.targets.contains(l)).toList();
    return AlertDialog(
      title: Text(trf('AI 자막 만들기{0}' '{1}', [widget.thenBuild ? tr(' → MKV 만들기') : '', widget.targetCount > 1 ? trf(' (동영상 {0}개)', [widget.targetCount]) : ''])),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(trf('영상의 음성을 인식하고 선택한 언어로 번역합니다. 모든 처리는 이 {0}에서 이루어집니다.', [Platform.isAndroid ? tr('기기') : 'PC']),
                  style: const TextStyle(fontSize: 12, color: JjColors.textDim)),
              const SizedBox(height: 16),
              _label(tr('원어 (영상 속 언어)')),
              DropdownButton<Language>(
                value: _o.source,
                isExpanded: true,
                items: [
                  DropdownMenuItem(value: undetermined, child: Text(tr('자동 감지'))),
                  for (final l in languages)
                    DropdownMenuItem(value: l, child: Text('${l.name} (${l.code})')),
                ],
                onChanged: (l) => setState(() => _o = _o.copyWith(source: l)),
              ),
              const SizedBox(height: 16),
              _label(tr('만들 자막 언어 (파일명_언어코드.srt)')),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final l in _o.targets)
                    InputChip(
                      label: Text('${l.name} (${l.code})'),
                      onDeleted: _o.targets.length > 1
                          ? () => setState(() => _o = _o.copyWith(targets: {..._o.targets}..remove(l)))
                          : null,
                    ),
                  PopupMenuButton<Language>(
                    tooltip: tr('언어 추가'),
                    itemBuilder: (_) => [
                      for (final l in extra)
                        PopupMenuItem(value: l, child: Text('${l.name} (${l.code})')),
                    ],
                    onSelected: (l) => setState(() => _o = _o.copyWith(targets: {..._o.targets, l})),
                    child: Chip(avatar: Icon(Icons.add, size: 16), label: Text(tr('언어 추가'))),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              _label(tr('음성인식 모델')),
              RadioGroup<String>(
                groupValue: _o.whisper.id,
                onChanged: (id) => setState(() => _o =
                    _o.copyWith(whisper: whisperModels.firstWhere((m) => m.id == id))),
                child: Column(children: [
                  for (final m in whisperModels)
                    RadioListTile<String>(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      value: m.id,
                      title: Text(m.label),
                      subtitle: _status(m),
                    ),
                ]),
              ),
              Row(children: [
                Text(tr('번역 모델: NLLB-200 (로컬)  '), style: TextStyle(fontSize: 13)),
                _status(nllbModel),
              ]),
              const NllbLicenseNote(),
              if (widget.videoCount > 1) ...[
                const SizedBox(height: 8),
                CheckboxListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  value: _all,
                  onChanged: (v) => setState(() => _all = v ?? false),
                  title: Text(trf('목록의 동영상 {0}개 모두', [widget.videoCount])),
                ),
              ],
              const SizedBox(height: 8),
              Text(tr('※ 시간이 오래 걸립니다 (영상 1시간 ≈ 음성인식 15~30분 + 언어당 번역 10~20분)'),
                  style: TextStyle(fontSize: 11, color: JjColors.textDim)),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('취소'))),
        FilledButton.icon(
          onPressed: () => Navigator.pop(context, (_o, _all)),
          icon: const Icon(Icons.auto_awesome, size: 18),
          label: Text(tr('시작')),
        ),
      ],
    );
  }

  Widget _label(String t) => Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Text(t, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
      );
}
