import 'file_ops.dart' show isPartialFile, SourceUnreadableException;
import 'sync_tools.dart' show splitOptions;
import 'vfs.dart';

/// rsync (Rsync 화면의 → · ← · ⇄) 를 실행하기 전에 무엇이 바뀌는지 미리 보기 (72).
enum PreviewAction {
  /// 받는 쪽에 없어 새로 복사
  add,

  /// 받는 쪽에도 있지만 달라서 덮어씀
  update,

  /// 받는 쪽에만 있음 (지우기 없이 그대로 남음)
  onlyTarget,

  /// 받는 쪽에만 있어 지워짐 (--delete)
  delete,
}

class PreviewItem {
  /// 원본 폴더 기준 상대 경로 ("/" 구분)
  final String rel;
  final PreviewAction action;

  /// true = 왼쪽 → 오른쪽, false = 오른쪽 → 왼쪽
  final bool toRight;
  final bool isDir;
  final int size;
  const PreviewItem(this.rel, this.action, {required this.toRight, this.isDir = false, this.size = 0});
}

/// rsync 의 지우기 옵션인지: --delete · --delete-before/during/delay/after/excluded/missing-args · --del (별칭)
/// (97: --del 을 놓치면 확인 · 잠금 없이 지운다)
bool isRsyncDeleteOption(String o) => o == '--del' || o.startsWith('--delete') || o.startsWith('--del=');

/// rsync 옵션에 지우기 (--delete 계열) 가 있는지
bool optionsDelete(String options) => splitOptions(options).any(isRsyncDeleteOption);

/// 옵션 글을 낱말로 나누되 따옴표는 그대로 둔 원래 글 조각 (106: --exclude="My Folder" 가 갈라지지 않게)
List<String> rawOptionTokens(String s) {
  final out = <String>[];
  final cur = StringBuffer();
  String? quote;
  for (final ch in s.split('')) {
    if (quote != null) {
      cur.write(ch);
      if (ch == quote) quote = null;
    } else if (ch == '"' || ch == "'") {
      quote = ch;
      cur.write(ch);
    } else if (ch.trim().isEmpty) {
      if (cur.isNotEmpty) out.add(cur.toString());
      cur.clear();
    } else {
      cur.write(ch);
    }
  }
  if (cur.isNotEmpty) out.add(cur.toString());
  return out;
}

/// 지우기 옵션을 뺀 rsync 옵션 (⇄ 의 두 번째 ← 처럼 지우면 안 되는 실행). 다른 옵션은 따옴표까지 원래 글 그대로
String withoutDeleteOptions(String options) => rawOptionTokens(options)
    .where((raw) => !splitOptions(raw).any(isRsyncDeleteOption))
    .join(' ');

/// 원본을 지우는 rsync · robocopy 옵션인지 (--remove-source-files · --remove-sent-files · /MOV · /MOVE) - 107
bool isSourceRemovingOption(String o) =>
    o == '--remove-source-files' || o == '--remove-sent-files' || o.toUpperCase() == '/MOV' || o.toUpperCase() == '/MOVE';

/// rsync 옵션에 -u (받는 쪽이 더 새 파일은 건너뜀) 가 있는지
bool optionsUpdate(String options) =>
    splitOptions(options).any((o) => o == '--update' || (o.startsWith('-') && !o.startsWith('--') && o.contains('u')));

/// [src] 안의 것 → [dst] 안으로 맞출 때 바뀌는 것. 원본을 읽지 못한 폴더에서는 "지워짐" 을 세지 않는다.
/// [limit] 개를 넘으면 멈춘다 (화면에는 "… 이상").
Future<List<PreviewItem>> previewSync(String src, String dst,
    {required bool toRight, bool delete = false, bool update = false, int limit = 2000}) async {
  final out = <PreviewItem>[];
  Future<void> walk(String s, String d, String rel) async {
    if (out.length >= limit) return;
    final there = <String, ({String path, bool isDir, int size, DateTime modified})>{};
    try {
      for (final e in await vList(d)) {
        there[vBasename(e.path)] = e;
      }
    } catch (_) {} // 받는 쪽 폴더가 아직 없음
    List<({String path, bool isDir, int size, DateTime modified})> items;
    try {
      items = await vList(s, strict: true);
    } catch (e) {
      // 맨 위 원본을 읽지 못하면 비교 실패 (93: 지우는 실행을 막는다). 안쪽 폴더는 그 폴더의 "지워짐" 만 세지 않는다
      if (rel.isEmpty) throw SourceUnreadableException(src, cause: e);
      return;
    }
    final names = <String>{};
    for (final e in items) {
      if (out.length >= limit) return;
      final name = vBasename(e.path);
      if (isPartialFile(name)) continue;
      names.add(name);
      final r = rel.isEmpty ? name : '$rel/$name';
      final t = there[name];
      if (e.isDir) {
        if (t == null) out.add(PreviewItem(r, PreviewAction.add, toRight: toRight, isDir: true));
        await walk(e.path, vJoin(d, name), r);
        continue;
      }
      if (t == null) {
        out.add(PreviewItem(r, PreviewAction.add, toRight: toRight, size: e.size));
      } else if (t.size != e.size || t.modified.difference(e.modified).inSeconds.abs() > 2) {
        // -u: 받는 쪽이 더 새 것이면 건너뜀
        if (update && t.modified.isAfter(e.modified.add(const Duration(seconds: 2)))) continue;
        out.add(PreviewItem(r, PreviewAction.update, toRight: toRight, size: e.size));
      }
    }
    for (final e in there.values) {
      final name = vBasename(e.path);
      if (names.contains(name) || isPartialFile(name)) continue;
      out.add(PreviewItem(rel.isEmpty ? name : '$rel/$name', delete ? PreviewAction.delete : PreviewAction.onlyTarget,
          toRight: toRight, isDir: e.isDir, size: e.size));
    }
  }

  await walk(src, dst, '');
  return out;
}

/// ⇄ (양쪽 함께, -u): 두 방향을 합친다. 한쪽에만 있는 것은 다른 쪽으로 복사되므로 "한쪽에만 있음" 은 빼고,
/// 양쪽에 있고 다른 파일은 더 새 쪽에서 받는 쪽으로 (한 번만).
/// [delete]: --delete 와 함께면 먼저 도는 왼쪽 → 오른쪽에서 오른쪽에만 있는 것이 지워진다 (그 뒤 ← 로 건너가지 않음)
Future<List<PreviewItem>> previewBoth(String left, String right, {bool delete = false, int limit = 2000}) async {
  final a = await previewSync(left, right, toRight: true, update: true, delete: delete, limit: limit);
  final b = await previewSync(right, left, toRight: false, update: true, limit: limit);
  final gone = {for (final x in a) if (x.action == PreviewAction.delete) x.rel};
  final seen = <String>{};
  return [
    for (final x in a)
      if (x.action == PreviewAction.delete && seen.add(x.rel)) x,
    for (final x in [...a, ...b])
      if ((x.action == PreviewAction.add || x.action == PreviewAction.update) &&
          !gone.any((g) => x.rel == g || x.rel.startsWith('$g/')) &&
          seen.add(x.rel))
        x,
  ];
}
