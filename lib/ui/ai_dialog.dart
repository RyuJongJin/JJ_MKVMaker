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
  Future<(AiOptions, bool)?> full() => showDialog<(AiOptions, bool)>(
        context: context,
        builder: (_) => _AiDialog(c: c, videos: list, videoCount: targets == null ? c.videos.length : 1, thenBuild: thenBuild),
      );
  // 환경 설정에서 "매번 묻기" 를 끄면 사용자가 고른 대로 묻지 않는다 (마지막 설정으로).
  // 138: 다만 [MKV 만들기] 와 헷갈려 잘못 누른 것을 되돌릴 수 있게 3초 알림 ([취소]) 뒤에 시작한다.
  if (!c.settings.askAiOptions) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return run(list, c.aiOptions);
    var cancelled = false;
    messenger.showSnackBar(SnackBar(
      duration: aiStartDelay,
      content: Text(aiStartNotice(list, c.aiOptions, thenBuild: thenBuild)),
      action: SnackBarAction(label: tr('취소'), onPressed: () => cancelled = true),
    ));
    await Future<void>.delayed(aiStartDelay);
    if (cancelled) return;
    return run(list, c.aiOptions);
  }
  final result = await full();
  if (result == null) return;
  final (opts, all) = result;
  await run(all ? List.of(c.videos) : list, opts);
}

/// 138: "매번 묻기" 를 껐을 때 시작 전에 [취소] 할 수 있는 시간
const aiStartDelay = Duration(seconds: 3);

/// 138: "AI 자막 (동영상 n개 · 약 m분) 을 시작합니다" (길이를 모르면 시간 없이)
String aiStartNotice(List<VideoItem> videos, AiOptions o, {required bool thenBuild}) {
  final known = videos.map((v) => v.info?.duration).whereType<Duration>().toList();
  final est = known.length == videos.length ? aiEstimateMinutes(known.fold(Duration.zero, (a, b) => a + b), aiTranslateCount(o)) : null;
  final what = [trf('동영상 {0}개', [videos.length]), if (est != null) trf('약 {0}~{1}분', [est.$1, est.$2])].join(' · ');
  return thenBuild ? trf('AI 자막 → MKV ({0}) 을 시작합니다', [what]) : trf('AI 자막 ({0}) 을 시작합니다', [what]);
}

/// 138: AI 작업 (자막 · 자막 & MKV) 의 색 - [MKV 만들기] (청록) 와 헷갈리지 않게
const aiColor = Color(0xFFB388FF);

/// 138: AI 작업 시간 어림 (분): 영상 1시간 ≈ 음성인식 15~30분 + 번역할 언어마다 10~20분. 길이를 모르면 null
(int, int)? aiEstimateMinutes(Duration total, int translateLanguages) {
  if (total <= Duration.zero) return null;
  final h = total.inSeconds / 3600;
  return ((h * (15 + 10 * translateLanguages)).ceil(), (h * (30 + 20 * translateLanguages)).ceil());
}

/// 번역할 언어 수 (원어와 같은 언어는 번역하지 않음, 원어 자동 감지면 하나는 원어로 본다)
int aiTranslateCount(AiOptions o) => o.source == undetermined
    ? (o.targets.length - 1).clamp(0, 99)
    : o.targets.where((t) => t.code != o.source.code).length;

/// 138: 시작 전에 보여 줄 계획: 할 일 · 대상 수 · 자막 언어 · 예상 시간
class AiPlanSummary extends StatelessWidget {
  final List<VideoItem> videos;
  final AiOptions o;
  final bool thenBuild;
  const AiPlanSummary({super.key, required this.videos, required this.o, required this.thenBuild});

  @override
  Widget build(BuildContext context) {
    final known = videos.map((v) => v.info?.duration).whereType<Duration>().toList();
    final total = known.fold(Duration.zero, (a, b) => a + b);
    final est = known.length == videos.length ? aiEstimateMinutes(total, aiTranslateCount(o)) : null;
    String hm(Duration d) => d.inHours > 0 ? trf('{0}시간 {1}분', [d.inHours, d.inMinutes % 60]) : trf('{0}분', [d.inMinutes.clamp(1, 59)]);
    final rows = [
      (tr('할 일'), thenBuild ? tr('AI 자막 만들기 → 이어서 MKV 만들기') : tr('AI 자막 만들기 (MKV 는 만들지 않음)')),
      (tr('대상'), trf('동영상 {0}개', [videos.length])),
      (tr('자막 언어'), [for (final l in o.targets) l.name].join(' · ')),
      (
        tr('예상 시간'),
        est == null
            ? tr('동영상 길이를 몰라 셀 수 없습니다 (영상 1시간 ≈ 음성인식 15~30분 + 언어당 번역 10~20분)')
            : trf('약 {0}~{1}분 (동영상 {2})', [est.$1, est.$2, hm(total)]),
      ),
    ];
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
          color: aiColor.withValues(alpha: 0.08), border: Border.all(color: aiColor.withValues(alpha: 0.5)), borderRadius: BorderRadius.circular(8)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        for (final (k, v) in rows)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              SizedBox(width: 84, child: Text(k, style: const TextStyle(fontSize: 12, color: JjColors.textDim))),
              Expanded(child: Text(v, style: const TextStyle(fontSize: 13))),
            ]),
          ),
      ]),
    );
  }
}

class _AiDialog extends StatefulWidget {
  final AppController c;
  final int videoCount;

  /// 이번에 자막을 만들 동영상 · 이어서 MKV 도 만드는지 (제목 · 계획에 표시)
  final List<VideoItem> videos;
  final bool thenBuild;
  const _AiDialog({required this.c, required this.videos, required this.videoCount, this.thenBuild = false});

  int get targetCount => videos.length;

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
              const SizedBox(height: 10),
              // 138: 무엇을 할지 먼저 (바꾸면 따라 바뀐다)
              AiPlanSummary(videos: _all ? widget.c.videos : widget.videos, o: _o, thenBuild: widget.thenBuild),
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
          style: FilledButton.styleFrom(backgroundColor: aiColor),
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
