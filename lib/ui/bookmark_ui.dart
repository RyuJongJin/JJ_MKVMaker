import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../app/bookmarks_controller.dart';
import '../core/bookmarks.dart';
import 'app_actions.dart';
import 'theme.dart';
import '../l10n/tr.dart';

// 즐겨찾기 공용 화면 조각 (Chrome 의 즐겨찾기를 참고):
//  - 즐겨찾기 수정 창: 이름 · 주소 · 저장할 폴더 (+ 새 폴더)
//  - 오른쪽 클릭 메뉴: 열기 · 수정 · 삭제 · 이 폴더에 페이지 / 폴더 추가 · 관리자
//  - 끌어다 놓기: 즐겨찾기 · 폴더를 폴더 위에 놓으면 그 폴더 안으로
//  - 즐겨찾기 관리자 (전체 화면): 왼쪽 폴더 나무 · 오른쪽 내용 · 검색 · HTML 내보내기 / 가져오기

/// 끌고 다니는 즐겨찾기 (id)
class BookmarkDrag {
  final String id;
  const BookmarkDrag(this.id);
}

/// 폴더 고르기 목록 (깊이만큼 들여쓰기). [exclude] 와 그 안쪽 폴더는 뺀다 (폴더를 자기 안으로 옮길 수 없음)
List<DropdownMenuItem<String>> folderItems(BookmarksController bm, {String? exclude}) => [
      for (final (f, depth) in bm.tree.folders())
        if (exclude == null || (f.id != exclude && !bm.tree.isInside(f.id, exclude)))
          DropdownMenuItem(
            value: f.id,
            child: Padding(
              padding: EdgeInsets.only(left: depth * 14.0),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(depth == 0 ? Icons.folder_special_outlined : Icons.folder_outlined, size: 16, color: Colors.amber),
                const SizedBox(width: 6),
                Text(f.title),
              ]),
            ),
          ),
    ];

/// 즐겨찾기 · 폴더 수정 창. [justAdded] 면 Chrome 처럼 "즐겨찾기 추가됨" 으로 보이고 [삭제] 가 "추가 취소".
/// 이름 · 주소 · 저장할 폴더를 바꾸고, 그 자리에서 새 폴더를 만들어 넣을 수 있다.
Future<void> showBookmarkEditor(BuildContext context, BookmarksController bm, BookmarkNode n,
    {bool justAdded = false}) async {
  final r = await showDialog<String>(
    context: context,
    builder: (_) => _BookmarkEditor(bm: bm, n: n, justAdded: justAdded),
  );
  if (r == 'del' && context.mounted) {
    if (justAdded) {
      bm.remove(n.id);
    } else {
      removeBookmarkWithUndo(context, bm, n);
    }
  }
}

class _BookmarkEditor extends StatefulWidget {
  final BookmarksController bm;
  final BookmarkNode n;
  final bool justAdded;
  const _BookmarkEditor({required this.bm, required this.n, required this.justAdded});

  @override
  State<_BookmarkEditor> createState() => _BookmarkEditorState();
}

class _BookmarkEditorState extends State<_BookmarkEditor> {
  late final _title = TextEditingController(text: widget.n.title);
  late final _url = TextEditingController(text: widget.n.url ?? '');
  late String _folder = widget.bm.tree.parentOf(widget.n.id)?.id ?? BookmarkTree.barId;

  @override
  void dispose() {
    _title.dispose();
    _url.dispose();
    super.dispose();
  }

  Future<void> _newFolder() async {
    final f = await showNewFolderDialog(context, widget.bm, _folder);
    if (f != null) setState(() => _folder = f.id);
  }

  void _save() {
    final bm = widget.bm;
    final n = widget.n;
    bm.update(n.id, title: _title.text, url: n.isFolder ? null : _url.text);
    if (bm.tree.parentOf(n.id)?.id != _folder) bm.moveInto(n.id, _folder);
    Navigator.pop(context, 'save');
  }

  @override
  Widget build(BuildContext context) {
    final n = widget.n;
    return AlertDialog(
      title: Text(widget.justAdded ? tr('즐겨찾기 추가됨') : (n.isFolder ? tr('폴더 수정') : tr('즐겨찾기 수정'))),
      content: SizedBox(
        width: 440,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
            controller: _title,
            autofocus: true,
            decoration: InputDecoration(labelText: tr('이름'), border: OutlineInputBorder()),
            onSubmitted: (_) => _save(),
          ),
          if (!n.isFolder) ...[
            const SizedBox(height: 12),
            TextField(
                controller: _url, decoration: InputDecoration(labelText: tr('주소'), border: OutlineInputBorder())),
          ],
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
              child: DropdownButtonFormField<String>(
                // 새 폴더를 만들면 그 폴더가 골라진 상태로 다시 그린다
                key: ValueKey(_folder),
                initialValue: _folder,
                isExpanded: true,
                decoration: InputDecoration(labelText: tr('폴더'), border: OutlineInputBorder()),
                items: folderItems(widget.bm, exclude: n.isFolder ? n.id : null),
                onChanged: (v) => setState(() => _folder = v!),
              ),
            ),
            const SizedBox(width: 8),
            OutlinedButton.icon(
              onPressed: _newFolder,
              icon: const Icon(Icons.create_new_folder_outlined, size: 18),
              label: Text(tr('새 폴더')),
            ),
          ]),
        ]),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, 'del'),
          child: Text(widget.justAdded ? tr('추가 취소') : tr('삭제'), style: const TextStyle(color: JjColors.danger)),
        ),
        if (!widget.justAdded) TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('취소'))),
        FilledButton(onPressed: _save, child: Text(widget.justAdded ? tr('완료') : tr('저장'))),
      ],
    );
  }
}

/// 새 폴더 (폴더 [parentId] 안의 맨 뒤). 만든 폴더, 취소하면 null.
Future<BookmarkNode?> showNewFolderDialog(BuildContext context, BookmarksController bm, String parentId) async {
  final name = await askText(context, tr('새 폴더'), tr('폴더 이름'), tr('새 폴더'),
      help: trf('"{0}" 안에 만듭니다', [bm.tree.find(parentId)?.title ?? '']));
  if (name == null) return null;
  return bm.addFolder(name, parentId: parentId);
}

/// 새 즐겨찾기 (이름 · 주소 직접 입력) - 폴더 [parentId] 안에
Future<void> showNewBookmarkDialog(BuildContext context, BookmarksController bm, String parentId,
    {String title = '', String url = ''}) async {
  final t = TextEditingController(text: title);
  final u = TextEditingController(text: url);
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(tr('즐겨찾기 추가')),
      content: SizedBox(
        width: 440,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
              controller: t, autofocus: true, decoration: InputDecoration(labelText: tr('이름'), border: OutlineInputBorder())),
          const SizedBox(height: 12),
          TextField(
            controller: u,
            decoration: InputDecoration(labelText: tr('주소'), hintText: 'https://…', border: OutlineInputBorder()),
            onSubmitted: (_) => Navigator.pop(ctx, true),
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: Text(trf('폴더: {0}', [bm.tree.find(parentId)?.title ?? '']),
                style: const TextStyle(fontSize: 12, color: JjColors.textDim)),
          ),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('취소'))),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr('추가'))),
      ],
    ),
  );
  if (ok == true) {
    var url = u.text.trim();
    if (url.isNotEmpty) {
      if (!url.contains('://')) url = 'https://$url';
      bm.addLink(t.text, url, parentId: parentId);
    }
  }
  await Future<void>.delayed(const Duration(milliseconds: 300));
  t.dispose();
  u.dispose();
}

/// 글 하나 묻기 (취소하면 null)
Future<String?> askText(BuildContext context, String title, String label, String initial, {String? help}) async {
  final ctrl = TextEditingController(text: initial)..selection = TextSelection(baseOffset: 0, extentOffset: initial.length);
  final r = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: SizedBox(
        width: 380,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          TextField(
            controller: ctrl,
            autofocus: true,
            decoration: InputDecoration(labelText: label, border: const OutlineInputBorder()),
            onSubmitted: (t) => Navigator.pop(ctx, t),
          ),
          if (help != null) ...[
            const SizedBox(height: 6),
            Text(help, style: const TextStyle(fontSize: 12, color: JjColors.textDim)),
          ],
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('취소'))),
        FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text), child: Text(tr('확인'))),
      ],
    ),
  );
  await Future<void>.delayed(const Duration(milliseconds: 300)); // 닫히는 애니메이션 뒤 정리
  ctrl.dispose();
  return r;
}

/// 삭제 + "실행 취소"
void removeBookmarkWithUndo(BuildContext context, BookmarksController bm, BookmarkNode n) {
  if (!bm.remove(n.id)) return;
  // 되돌리기는 바로 보여야 하므로 앞서 떠 있던 알림은 치운다
  ScaffoldMessenger.of(context)
    ..clearSnackBars()
    ..showSnackBar(SnackBar(
      content: Text(n.isFolder ? trf('폴더 삭제: {0} (안의 {1}개 포함)', [n.title, bm.tree.countLinks(n)]) : trf('삭제: {0}', [n.title])),
      persist: false, // Flutter 3.47+: [action] 이 있으면 기본은 안 사라짐 → duration 대로 닫기
      action: SnackBarAction(label: tr('실행 취소'), onPressed: bm.undoRemove),
    ));
}

/// 즐겨찾기 오른쪽 클릭 메뉴 (Chrome 과 같은 항목). [n] 이 null 이면 빈 곳 (폴더 [folderId] 에 추가만).
Future<void> showBookmarkMenu(
  BuildContext context, {
  required BookmarksController bm,
  required Offset globalPosition,
  BookmarkNode? n,
  required String folderId,
  required void Function(String url) onOpen,
  void Function(String url)? onOpenExternal,
  String currentUrl = '',
  String currentTitle = '',
  VoidCallback? onOpenManager,
}) async {
  // 화면 크기 배율이 걸려 있어도 누른 자리에 뜨도록 메뉴가 그려질 곳 기준으로
  final overlay = Overlay.of(context).context.findRenderObject()! as RenderBox;
  final at = overlay.globalToLocal(globalPosition);
  // 폴더 위에서 연 메뉴: "추가" 는 그 폴더 안에
  final addTo = n != null && n.isFolder ? n.id : folderId;
  PopupMenuItem<String> item(String v, IconData icon, String label, {bool enabled = true}) => PopupMenuItem(
        value: v,
        enabled: enabled,
        height: 36,
        child: Row(children: [
          Icon(icon, size: 18, color: enabled ? null : JjColors.textDim),
          const SizedBox(width: 10),
          Text(label, style: const TextStyle(fontSize: 13)),
        ]),
      );
  final r = await showMenu<String>(
    context: context,
    position: RelativeRect.fromLTRB(at.dx, at.dy, overlay.size.width - at.dx, overlay.size.height - at.dy),
    items: [
      if (n != null && !n.isFolder) ...[
        item('open', Icons.open_in_browser, tr('열기')),
        if (onOpenExternal != null) item('ext', Icons.open_in_new, tr('외부 브라우저로 열기')),
        const PopupMenuDivider(),
      ],
      if (n != null) ...[
        item('edit', Icons.edit_outlined, n.isFolder ? tr('이름 바꾸기 · 이동') : tr('수정 · 이동')),
        item('del', Icons.delete_outline, tr('삭제'),
            enabled: n.id != BookmarkTree.barId && n.id != BookmarkTree.otherId),
        const PopupMenuDivider(),
      ],
      item('addPage', Icons.bookmark_add_outlined,
          n != null && n.isFolder ? tr('이 폴더에 현재 페이지 추가') : tr('현재 페이지 추가'), enabled: currentUrl.startsWith('http')),
      item('addLink', Icons.add_link, tr('즐겨찾기 추가…')),
      item('addFolder', Icons.create_new_folder_outlined, n != null && n.isFolder ? tr('이 폴더에 새 폴더') : tr('새 폴더…')),
      if (onOpenManager != null) ...[
        const PopupMenuDivider(),
        item('manager', Icons.bookmarks_outlined, tr('즐겨찾기 관리자')),
      ],
    ],
  );
  if (r == null || !context.mounted) return;
  switch (r) {
    case 'open':
      onOpen(n!.url!);
    case 'ext':
      onOpenExternal?.call(n!.url!);
    case 'edit':
      await showBookmarkEditor(context, bm, n!);
    case 'del':
      removeBookmarkWithUndo(context, bm, n!);
    case 'addPage':
      bm.addLink(currentTitle.isEmpty ? currentUrl : currentTitle, currentUrl, parentId: addTo);
    case 'addLink':
      await showNewBookmarkDialog(context, bm, addTo);
    case 'addFolder':
      await showNewFolderDialog(context, bm, addTo);
    case 'manager':
      onOpenManager?.call();
  }
}

/// 폴더 위에 즐겨찾기를 끌어다 놓을 수 있게 감싼다 (놓을 수 있으면 테두리 강조)
class BookmarkFolderDrop extends StatelessWidget {
  final BookmarksController bm;
  final String folderId;
  final Widget child;
  const BookmarkFolderDrop({super.key, required this.bm, required this.folderId, required this.child});

  @override
  Widget build(BuildContext context) => DragTarget<BookmarkDrag>(
        onWillAcceptWithDetails: (d) => bm.canMoveInto(d.data.id, folderId),
        onAcceptWithDetails: (d) => bm.moveInto(d.data.id, folderId),
        builder: (context, candidates, _) => DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: candidates.isNotEmpty ? JjColors.accent : Colors.transparent, width: 2),
            color: candidates.isNotEmpty ? JjColors.accent.withValues(alpha: 0.12) : null,
          ),
          child: child,
        ),
      );
}

/// 끌 수 있는 즐겨찾기 (끄는 동안 이름표가 따라온다)
class BookmarkDraggable extends StatelessWidget {
  final BookmarkNode n;
  final Widget child;
  const BookmarkDraggable({super.key, required this.n, required this.child});

  @override
  Widget build(BuildContext context) => Draggable<BookmarkDrag>(
        data: BookmarkDrag(n.id),
        dragAnchorStrategy: pointerDragAnchorStrategy,
        feedback: Material(
          color: JjColors.panelHigh,
          elevation: 4,
          borderRadius: BorderRadius.circular(6),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(n.isFolder ? Icons.folder : Icons.public, size: 16, color: n.isFolder ? Colors.amber : null),
              const SizedBox(width: 6),
              Text(n.title, style: const TextStyle(fontSize: 12, color: JjColors.text)),
            ]),
          ),
        ),
        childWhenDragging: Opacity(opacity: 0.4, child: child),
        child: child,
      );
}

// ───────── 즐겨찾기 관리자 (Chrome 의 chrome://bookmarks 참고) ─────────

class BookmarkManagerPage extends StatefulWidget {
  final BookmarksController bm;
  final void Function(String url) onOpen;
  final void Function(String url)? onOpenExternal;
  final String currentUrl;
  final String currentTitle;
  final String? initialFolderId;

  const BookmarkManagerPage({
    super.key,
    required this.bm,
    required this.onOpen,
    this.onOpenExternal,
    this.currentUrl = '',
    this.currentTitle = '',
    this.initialFolderId,
  });

  @override
  State<BookmarkManagerPage> createState() => _BookmarkManagerPageState();
}

class _BookmarkManagerPageState extends State<BookmarkManagerPage> {
  late String _folder = widget.initialFolderId ?? BookmarkTree.barId;
  final _search = TextEditingController();
  final Set<String> _collapsed = {};

  BookmarksController get bm => widget.bm;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _open(String url) {
    widget.onOpen(url);
    Navigator.maybePop(context);
  }

  Future<void> _export() async {
    final uri = await FilePicker.saveFile(
      dialogTitle: tr('즐겨찾기 내보내기 (HTML)'),
      fileName: tr('JJ_MKVMaker_즐겨찾기.html'),
      bytes: Uint8List.fromList(utf8.encode(bm.tree.toNetscapeHtml())),
      type: FileType.custom,
      allowedExtensions: const ['html'],
    );
    if (uri == null) return;
    final file = uri.scheme == 'file' ? uri.toFilePath() : uri.toString();
    await bm.exportHtml(file);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(trf('내보냈습니다: {0}', [file]))));
    }
  }

  Future<void> _importHtml() async {
    final r = await FilePicker.pickFiles(
        dialogTitle: tr('즐겨찾기 HTML 가져오기'), type: FileType.custom, allowedExtensions: const ['html', 'htm']);
    final path = r.isEmpty ? null : r.single.path;
    if (path == null) return;
    final n = await bm.importHtml(path);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(n > 0 ? trf('{0}개를 "기타 즐겨찾기" 에 가져왔습니다.', [n]) : tr('가져올 즐겨찾기가 없습니다.'))));
    if (n > 0) setState(() => _folder = BookmarkTree.otherId);
  }

  Future<void> _importBrowser(String b) async {
    final n = await bm.importFrom(b);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(n < 0 ? tr('이 브라우저의 즐겨찾기 파일을 찾지 못했습니다.') : trf('{0}개를 "기타 즐겨찾기" 에 가져왔습니다.', [n]))));
    if (n > 0) setState(() => _folder = BookmarkTree.otherId);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: bm,
        builder: (context, _) {
          if (bm.tree.find(_folder) == null) _folder = BookmarkTree.barId;
          final q = _search.text.trim();
          return Scaffold(
            body: Column(children: [
              _topBar(),
              const Divider(height: 1),
              Expanded(
                child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  SizedBox(width: 280, child: _tree()),
                  const VerticalDivider(width: 1),
                  Expanded(child: q.isEmpty ? _contents() : _results(q)),
                ]),
              ),
            ]),
          );
        },
      );

  Widget _topBar() => Container(
        height: appBarHeight,
        color: JjColors.panel,
        padding: const EdgeInsets.only(left: 8, right: appBarRightPadding),
        child: Row(children: [
          const AppNavButtons(),
          const SizedBox(width: 8),
          const Icon(Icons.bookmarks_outlined, color: JjColors.accent),
          const SizedBox(width: 8),
          Text(tr('즐겨찾기 관리자'), style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
          const SizedBox(width: 24),
          Expanded(
            child: TextField(
              controller: _search,
              style: const TextStyle(fontSize: 13),
              decoration: InputDecoration(
                isDense: true,
                filled: true,
                fillColor: JjColors.bg,
                hintText: tr('즐겨찾기 검색 (이름 · 주소)'),
                prefixIcon: const Icon(Icons.search, size: 18),
                suffixIcon: _search.text.isEmpty
                    ? null
                    : IconButton(
                        tooltip: tr('검색 지우기'),
                        icon: const Icon(Icons.close, size: 16),
                        onPressed: () => setState(_search.clear)),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(18), borderSide: BorderSide.none),
              ),
              onChanged: (_) => setState(() {}),
            ),
          ),
          const SizedBox(width: 8),
          PopupMenuButton<String>(
            tooltip: tr('관리 메뉴'),
            icon: const Icon(Icons.more_vert),
            itemBuilder: (_) => [
              PopupMenuItem(value: 'link', child: Text(tr('새 즐겨찾기 추가'))),
              PopupMenuItem(value: 'folder', child: Text(tr('새 폴더 추가'))),
              PopupMenuDivider(),
              PopupMenuItem(value: 'chrome', child: Text(tr('Chrome 에서 가져오기'))),
              PopupMenuItem(value: 'edge', child: Text(tr('Edge 에서 가져오기'))),
              PopupMenuItem(value: 'whale', child: Text(tr('Whale 에서 가져오기'))),
              PopupMenuItem(value: 'html', child: Text(tr('HTML 파일에서 가져오기'))),
              PopupMenuDivider(),
              PopupMenuItem(value: 'export', child: Text(tr('HTML 파일로 내보내기'))),
            ],
            onSelected: (v) async {
              switch (v) {
                case 'link':
                  await showNewBookmarkDialog(context, bm, _folder, title: widget.currentTitle, url: widget.currentUrl);
                case 'folder':
                  await showNewFolderDialog(context, bm, _folder);
                case 'chrome' || 'edge' || 'whale':
                  await _importBrowser(v);
                case 'html':
                  await _importHtml();
                case 'export':
                  await _export();
              }
            },
          ),
          const AppActions(),
        ]),
      );

  // 왼쪽: 폴더 나무 (누르면 오른쪽에 내용, 즐겨찾기를 끌어다 놓으면 그 폴더로)
  Widget _tree() {
    final rows = <Widget>[];
    void walk(BookmarkNode f, int depth) {
      final subs = f.children!.where((c) => c.isFolder).toList();
      final open = !_collapsed.contains(f.id);
      final selected = f.id == _folder;
      final row = BookmarkFolderDrop(
        bm: bm,
        folderId: f.id,
        child: InkWell(
          onTap: () => setState(() {
            _folder = f.id;
            _search.clear();
          }),
          onSecondaryTapDown: (d) => showBookmarkMenu(context,
              bm: bm,
              globalPosition: d.globalPosition,
              n: f,
              folderId: f.id,
              onOpen: _open,
              currentUrl: widget.currentUrl,
              currentTitle: widget.currentTitle),
          child: Container(
            color: selected ? JjColors.accent.withValues(alpha: 0.16) : null,
            padding: EdgeInsets.only(left: 6 + depth * 16.0, right: 8, top: 6, bottom: 6),
            child: Row(children: [
              SizedBox(
                width: 22,
                child: subs.isEmpty
                    ? null
                    : InkWell(
                        onTap: () => setState(() => open ? _collapsed.add(f.id) : _collapsed.remove(f.id)),
                        child: Icon(open ? Icons.expand_more : Icons.chevron_right, size: 18),
                      ),
              ),
              Icon(depth == 0 ? Icons.folder_special : (selected ? Icons.folder_open : Icons.folder),
                  size: 18, color: Colors.amber),
              const SizedBox(width: 8),
              Expanded(child: Text(f.title, maxLines: 1, overflow: TextOverflow.ellipsis)),
            ]),
          ),
        ),
      );
      rows.add(depth == 0 ? row : BookmarkDraggable(n: f, child: row));
      if (open) {
        for (final s in subs) {
          walk(s, depth + 1);
        }
      }
    }

    for (final r in bm.tree.roots) {
      walk(r, 0);
    }
    return Material(color: JjColors.panel, child: ListView(children: rows));
  }

  // 오른쪽: 고른 폴더의 내용 (끌어서 순서 바꾸기, 폴더 위로 끌면 그 안으로, 오른쪽 클릭 메뉴)
  Widget _contents() {
    final folder = bm.tree.find(_folder)!;
    final items = folder.children!;
    final path = bm.tree.pathTo(folder.id);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 12, 6),
        child: Row(children: [
          Expanded(
            child: Wrap(crossAxisAlignment: WrapCrossAlignment.center, children: [
              for (final (i, f) in path.indexed) ...[
                if (i > 0) const Icon(Icons.chevron_right, size: 16, color: JjColors.textDim),
                BookmarkFolderDrop(
                  bm: bm,
                  folderId: f.id,
                  child: InkWell(
                    onTap: () => setState(() => _folder = f.id),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                      child: Text(f.title,
                          style: TextStyle(
                              fontSize: 14,
                              fontWeight: f.id == folder.id ? FontWeight.w600 : FontWeight.normal,
                              color: f.id == folder.id ? JjColors.text : JjColors.accent)),
                    ),
                  ),
                ),
              ],
            ]),
          ),
          OutlinedButton.icon(
            onPressed: () => showNewBookmarkDialog(context, bm, folder.id,
                title: widget.currentTitle, url: widget.currentUrl),
            icon: const Icon(Icons.add_link, size: 18),
            label: Text(tr('즐겨찾기 추가')),
          ),
          const SizedBox(width: 8),
          OutlinedButton.icon(
            onPressed: () => showNewFolderDialog(context, bm, folder.id),
            icon: const Icon(Icons.create_new_folder_outlined, size: 18),
            label: Text(tr('새 폴더')),
          ),
        ]),
      ),
      const Divider(height: 1),
      Expanded(
        child: items.isEmpty
            ? Center(
                child: Text(tr('비어 있는 폴더입니다.\n위의 [즐겨찾기 추가] · [새 폴더] 를 누르거나, 즐겨찾기를 왼쪽 폴더로 끌어다 놓으세요.'),
                    textAlign: TextAlign.center, style: TextStyle(color: JjColors.textDim)))
            : ReorderableListView.builder(
                buildDefaultDragHandles: false,
                itemCount: items.length,
                onReorderItem: (o, n) => bm.reorder(folder.id, o, n),
                itemBuilder: (_, i) => _row(items[i], i, folder),
              ),
      ),
      Padding(
        padding: EdgeInsets.all(8),
        child: Text(tr('왼쪽 손잡이로 순서 바꾸기 · 아이콘을 끌어 왼쪽 폴더나 목록의 폴더 위에 놓으면 그 폴더로 이동 · 오른쪽 클릭 메뉴'),
            textAlign: TextAlign.center, style: TextStyle(fontSize: 11, color: JjColors.textDim)),
      ),
    ]);
  }

  Widget _row(BookmarkNode n, int i, BookmarkNode folder) {
    final tile = ListTile(
      dense: true,
      leading: Row(mainAxisSize: MainAxisSize.min, children: [
        ReorderableDragStartListener(
          index: i,
          child: const Icon(Icons.drag_indicator, size: 18, color: JjColors.textDim),
        ),
        const SizedBox(width: 6),
        // 아이콘을 끌면 다른 폴더로 옮기기
        BookmarkDraggable(
          n: n,
          child: Icon(n.isFolder ? Icons.folder : Icons.public, size: 20, color: n.isFolder ? Colors.amber : JjColors.textDim),
        ),
      ]),
      title: Text(n.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(n.isFolder ? trf('{0}개 · 주소 {1}개', [n.children!.length, bm.tree.countLinks(n)]) : n.url!,
          maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11)),
      onTap: () => n.isFolder ? setState(() => _folder = n.id) : _open(n.url!),
      trailing: IconButton(
        tooltip: tr('더 보기'),
        icon: const Icon(Icons.more_vert, size: 18),
        onPressed: () {
          final box = context.findRenderObject() as RenderBox?;
          final pos = box == null ? Offset.zero : box.localToGlobal(box.size.topRight(Offset.zero));
          _menu(n, folder, pos);
        },
      ),
    );
    final row = GestureDetector(
      onSecondaryTapDown: (d) => _menu(n, folder, d.globalPosition),
      child: n.isFolder ? BookmarkFolderDrop(bm: bm, folderId: n.id, child: tile) : tile,
    );
    return KeyedSubtree(key: ValueKey(n.id), child: row);
  }

  void _menu(BookmarkNode n, BookmarkNode folder, Offset pos) => showBookmarkMenu(context,
      bm: bm,
      globalPosition: pos,
      n: n,
      folderId: folder.id,
      onOpen: _open,
      onOpenExternal: widget.onOpenExternal,
      currentUrl: widget.currentUrl,
      currentTitle: widget.currentTitle);

  // 검색 결과 (위치 = 들어 있는 폴더)
  Widget _results(String q) {
    final found = bm.tree.search(q);
    if (found.isEmpty) return Center(child: Text(tr('찾는 즐겨찾기가 없습니다.'), style: TextStyle(color: JjColors.textDim)));
    return ListView(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
        child: Text(trf('"{0}" 검색 결과 {1}개', [q, found.length]), style: const TextStyle(fontWeight: FontWeight.w600)),
      ),
      for (final n in found)
        GestureDetector(
          onSecondaryTapDown: (d) => _menu(n, bm.tree.parentOf(n.id) ?? bm.tree.bar, d.globalPosition),
          child: ListTile(
            dense: true,
            leading: BookmarkDraggable(
              n: n,
              child: Icon(n.isFolder ? Icons.folder : Icons.public, size: 20, color: n.isFolder ? Colors.amber : JjColors.textDim),
            ),
            title: Text(n.title, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text(
                '${bm.tree.pathTo(n.id).reversed.skip(1).toList().reversed.map((f) => f.title).join(' › ')}'
                '${n.isFolder ? '' : '  ·  ${n.url}'}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11)),
            onTap: () => n.isFolder
                ? setState(() {
                    _folder = n.id;
                    _search.clear();
                  })
                : _open(n.url!),
          ),
        ),
    ]);
  }
}

