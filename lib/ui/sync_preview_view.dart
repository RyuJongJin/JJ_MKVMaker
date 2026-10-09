import 'package:flutter/material.dart';

import '../app/settings.dart' show CopyTask;
import '../core/file_ops.dart' show formatSize;
import '../core/sync_preview.dart';
import '../core/sync_tools.dart';
import '../core/vfs.dart';
import '../l10n/tr.dart';
import 'path_label.dart';
import 'theme.dart';

/// rsync 실행 전 비교 (72): 파일별로 → · ← · 받는 쪽에만 있음 · 지워짐 (빨강). 창이 열리면 바로 센다.
/// [onResult]: 다 세면 결과 (실행 버튼에 지워질 수를 보여 주려고)
class SyncPreviewView extends StatefulWidget {
  final Future<List<PreviewItem>> Function() compute;
  final void Function(List<PreviewItem> items)? onResult;

  /// 비교하지 못함 (원본을 읽지 못함 등)
  final void Function(Object error)? onError;

  /// 비교를 (다시) 시작할 때 - 예전 결과로 실행하지 못하게 (97)
  final void Function()? onStart;
  final int limit;
  const SyncPreviewView({super.key, required this.compute, this.onResult, this.onError, this.onStart, this.limit = 2000});

  @override
  State<SyncPreviewView> createState() => _SyncPreviewViewState();
}

class _SyncPreviewViewState extends State<SyncPreviewView> {
  List<PreviewItem>? _items;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _run(first: true);
  }

  /// 마지막으로 시작한 비교 (늦게 끝난 예전 비교가 새 결과를 덮지 않게)
  int _gen = 0;

  Future<void> _run({bool first = false}) async {
    final gen = ++_gen;
    setState(() {
      _items = null;
      _error = null;
    });
    // 첫 비교는 화면을 그리는 중이라 다음 틀에, [다시 비교] 는 바로 알린다
    if (first) {
      WidgetsBinding.instance.addPostFrameCallback((_) => widget.onStart?.call());
    } else {
      widget.onStart?.call();
    }
    try {
      final r = await widget.compute();
      if (!mounted || gen != _gen) return;
      setState(() => _items = r);
      widget.onResult?.call(r);
    } catch (e) {
      if (!mounted || gen != _gen) return;
      setState(() => _error = e);
      widget.onError?.call(e);
    }
  }

  static String _arrow(PreviewItem x) => x.toRight ? '→' : '←';

  /// 110: 비교 중 · 끝 · 오류 어느 때나 같은 높이 (창 크기가 바뀌어 [취소] · [실행] 자리가 움직이지 않게)
  static const height = 300.0;

  @override
  Widget build(BuildContext context) =>
      SizedBox(height: height, child: Align(alignment: Alignment.topLeft, child: _body()));

  Widget _body() {
    final items = _items;
    if (_error != null) {
      return Row(children: [
        Expanded(
          child: Text(trf('비교하지 못했습니다: {0}', [_error!]), style: const TextStyle(fontSize: 12, color: Colors.redAccent)),
        ),
        IconButton(tooltip: tr('다시 비교'), icon: const Icon(Icons.refresh, size: 18), onPressed: _run),
      ]);
    }
    if (items == null) {
      return Row(children: [
        const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
        const SizedBox(width: 8),
        Text(tr('무엇이 바뀌는지 비교하는 중…'), style: const TextStyle(fontSize: 12, color: JjColors.textDim)),
      ]);
    }
    int n(PreviewAction a, [bool? right]) =>
        items.where((x) => x.action == a && (right == null || x.toRight == right)).length;
    final dels = n(PreviewAction.delete);
    final more = items.length >= widget.limit;
    final parts = [
      for (final right in [true, false])
        if (n(PreviewAction.add, right) + n(PreviewAction.update, right) > 0)
          trf('{0} 새로 {1} · 바뀜 {2}', [right ? '→' : '←', n(PreviewAction.add, right), n(PreviewAction.update, right)]),
      if (n(PreviewAction.onlyTarget) > 0) trf('받는 쪽에만 있음 {0} (그대로 둠)', [n(PreviewAction.onlyTarget)]),
    ];
    return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      Row(children: [
        Expanded(
          child: Text(
            items.isEmpty ? tr('바뀌는 것 없음 (양쪽이 같습니다)') : parts.join('  ·  ') + (more ? tr(' · 더 있음') : ''),
            style: TextStyle(fontSize: 12, color: items.isEmpty ? Colors.greenAccent : null),
          ),
        ),
        IconButton(tooltip: tr('다시 비교'), icon: const Icon(Icons.refresh, size: 18), onPressed: _run),
      ]),
      if (dels > 0)
        Text(trf('받는 쪽에서 {0}개가 지워집니다 (--delete, 되돌릴 수 없음)', [dels]),
            style: const TextStyle(fontSize: 12, color: Colors.redAccent, fontWeight: FontWeight.w600)),
      if (items.isNotEmpty)
        Container(
          margin: const EdgeInsets.only(top: 6),
          constraints: const BoxConstraints(maxHeight: height - 80),
          decoration: BoxDecoration(color: JjColors.bg, borderRadius: BorderRadius.circular(6)),
          padding: const EdgeInsets.all(8),
          // 창 (AlertDialog) 이 크기를 미리 재므로 ListView 대신 (500줄까지)
          child: SingleChildScrollView(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            // 지워질 것을 맨 위에
            for (final x in [
              ...items.where((x) => x.action == PreviewAction.delete),
              ...items.where((x) => x.action != PreviewAction.delete),
            ].take(500))
              Text(
                switch (x.action) {
                  PreviewAction.add => '${_arrow(x)} + ${x.rel}${x.isDir ? '/' : '  (${formatSize(x.size)})'}',
                  PreviewAction.update => '${_arrow(x)} ~ ${x.rel}  (${formatSize(x.size)})',
                  PreviewAction.onlyTarget => '   = ${x.rel}${x.isDir ? '/' : ''}  ${tr('(받는 쪽에만 있음)')}',
                  PreviewAction.delete => '${_arrow(x)} − ${x.rel}${x.isDir ? '/' : ''}  ${tr('(지워짐)')}',
                },
                style: TextStyle(
                  fontSize: 11.5,
                  fontFamily: 'monospace',
                  color: switch (x.action) {
                    PreviewAction.delete => Colors.redAccent,
                    PreviewAction.onlyTarget => JjColors.textDim,
                    _ => null,
                  },
                ),
              ),
            if (items.length > 500) Text(trf('… 외 {0}개', [items.length - 500]), style: const TextStyle(fontSize: 11)),
          ])),
        ),
    ]);
  }
}

/// 지우기가 들어 있는 복사 작업인지 (104): rsync 의 --delete 계열 (WebDAV 도 따름 - 100), robocopy 의 /MIR · /PURGE (로컬만)
bool taskDeletes(CopyTask t) {
  final dav = [...t.sources, t.dest].any(isDav);
  return switch (CopyMethod.of(t.method)) {
    CopyMethod.rsync => optionsDelete(t.options),
    CopyMethod.robocopy => !dav && splitOptions(t.options).any((o) => o.toUpperCase() == '/MIR' || o.toUpperCase() == '/PURGE'),
    CopyMethod.builtin => false,
  };
}

/// 104: 지우기가 들어 있는 작업은 어디서 실행하든 (모니터링 [실행] · 옵션 저장 뒤 실행 · 최종 정리) Rsync 화면과 같은 미리 보기를 거친다.
/// 지울 목록이 나온 뒤에만 [실행] 이 켜진다. 지우기가 없으면 묻지 않고 true
Future<bool> confirmDeletingRun(BuildContext context, CopyTask t) async {
  if (!taskDeletes(t)) return true;
  List<PreviewItem>? preview;
  Object? error;
  final update = optionsUpdate(t.options);
  String dstOf(String src) => t.contents ? t.dest : vJoin(t.dest, vBasename(src));
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, set) {
        final dels = preview?.where((x) => x.action == PreviewAction.delete).length ?? 0;
        return AlertDialog(
          scrollable: true,
          actionsOverflowDirection: VerticalDirection.down, // 110: [취소] 가 먼저
          title: Text(tr('지우기가 들어 있는 작업입니다')),
          content: SizedBox(
            width: 560,
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              for (final s in t.sources) ...[
                Text(shortPath(s), style: const TextStyle(fontWeight: FontWeight.w600)),
                Text('→  ${shortPath(dstOf(s))}', style: const TextStyle(fontWeight: FontWeight.w600)),
                Text('${vDisplay(s)}  →  ${vDisplay(dstOf(s))}', style: const TextStyle(fontSize: 11, color: JjColors.textDim)),
              ],
              Text('${t.method} ${t.options}', style: const TextStyle(fontSize: 12, fontFamily: 'monospace', color: JjColors.textDim)),
              const SizedBox(height: 8),
              SyncPreviewView(
                compute: () async => [
                  for (final s in t.sources) ...await previewSync(s, dstOf(s), toRight: true, delete: true, update: update),
                ],
                onStart: () => set(() {
                  preview = null;
                  error = null;
                }),
                onResult: (items) => set(() => preview = items),
                onError: (e) => set(() {
                  preview = null;
                  error = e;
                }),
              ),
              // 110: 늘 같은 자리 (버튼이 움직이지 않게)
              SizedBox(
                height: 34,
                child: preview == null
                    ? Text(
                        error != null
                            ? tr('지우기가 들어간 실행이라, 비교하지 못하면 실행할 수 없습니다. 원본 · 대상을 확인한 뒤 [다시 비교] 를 누르세요.')
                            : tr('지우기가 들어간 실행이라, 지울 목록이 나온 뒤에 실행할 수 있습니다.'),
                        style: const TextStyle(fontSize: 12, color: Colors.orangeAccent),
                      )
                    : null,
              ),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('취소'))),
            FilledButton(
              style: dels > 0 ? FilledButton.styleFrom(backgroundColor: JjColors.danger) : null,
              onPressed: preview == null ? null : () => Navigator.pop(ctx, true),
              child: Text(tr('실행')), // 110: 글자를 바꾸지 않는다 (버튼 자리가 움직이지 않게)
            ),
          ],
        );
      },
    ),
  );
  return ok == true;
}
