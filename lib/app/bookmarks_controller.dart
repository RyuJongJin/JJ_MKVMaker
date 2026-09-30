import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../core/bookmarks.dart';

/// 즐겨찾기 (bookmarks.json 에 저장). 바뀔 때마다 저장한다.
class BookmarksController extends ChangeNotifier {
  final String? _path;
  BookmarkTree tree = BookmarkTree.defaults();

  /// 마지막으로 지운 것 (실행 취소용)
  (BookmarkNode, String, int)? _lastRemoved;

  BookmarksController([this._path]);

  Future<String> _file() async =>
      _path ?? p.join((await getApplicationSupportDirectory()).path, 'bookmarks.json');

  Future<void> load() async {
    try {
      final f = File(await _file());
      if (await f.exists()) {
        tree = BookmarkTree.fromJson(jsonDecode(await f.readAsString()) as Map<String, dynamic>);
      }
    } catch (_) {
      tree = BookmarkTree.defaults();
    }
    notifyListeners();
  }

  Future<void> _save() async {
    final f = File(await _file());
    await f.parent.create(recursive: true);
    await f.writeAsString(const JsonEncoder.withIndent(' ').convert(tree.toJson()));
  }

  void _changed() {
    notifyListeners();
    _save();
  }

  BookmarkNode addLink(String title, String url, {String parentId = BookmarkTree.barId, int? index}) {
    final n = tree.add(parentId, BookmarkNode.link(tree.newId(), title.trim().isEmpty ? url : title.trim(), url),
        index: index);
    _changed();
    return n;
  }

  BookmarkNode addFolder(String title, {String parentId = BookmarkTree.barId}) {
    final n = tree.add(parentId, BookmarkNode.folder(tree.newId(), title.trim().isEmpty ? '새 폴더' : title.trim()));
    _changed();
    return n;
  }

  void update(String id, {String? title, String? url}) {
    final n = tree.find(id);
    if (n == null) return;
    if (title != null && title.trim().isNotEmpty) n.title = title.trim();
    if (url != null && !n.isFolder && url.trim().isNotEmpty) n.url = url.trim();
    _changed();
  }

  bool remove(String id) {
    final r = tree.remove(id);
    if (r == null) return false;
    _lastRemoved = r;
    _changed();
    return true;
  }

  /// 방금 지운 것 되살리기
  bool undoRemove() {
    final r = _lastRemoved;
    if (r == null) return false;
    final (node, parentId, index) = r;
    tree.add(parentId, node, index: index);
    _lastRemoved = null;
    _changed();
    return true;
  }

  bool move(String id, String newParentId, int index) {
    final ok = tree.move(id, newParentId, index);
    if (ok) _changed();
    return ok;
  }

  /// 같은 폴더 안에서 순서 바꾸기. [newIndex] 는 옮긴 뒤의 최종 위치 (onReorderItem 규칙)
  void reorder(String parentId, int oldIndex, int newIndex) {
    final parent = tree.find(parentId);
    if (parent == null || !parent.isFolder) return;
    final list = parent.children!;
    if (oldIndex < 0 || oldIndex >= list.length) return;
    final item = list.removeAt(oldIndex);
    list.insert(newIndex.clamp(0, list.length), item);
    _changed();
  }

  /// Chrome · Edge 즐겨찾기 가져오기. 가져온 주소 수 (파일이 없으면 -1)
  Future<int> importFrom(String browser) async {
    final local = Platform.environment['LOCALAPPDATA'] ?? '';
    final file = switch (browser) {
      'chrome' => p.join(local, 'Google', 'Chrome', 'User Data', 'Default', 'Bookmarks'),
      'edge' => p.join(local, 'Microsoft', 'Edge', 'User Data', 'Default', 'Bookmarks'),
      'whale' => p.join(local, 'Naver', 'Naver Whale', 'User Data', 'Default', 'Bookmarks'),
      _ => browser, // 파일 경로 직접
    };
    final f = File(file);
    if (!await f.exists()) return -1;
    final name = switch (browser) {
      'chrome' => 'Chrome 에서 가져옴',
      'edge' => 'Edge 에서 가져옴',
      'whale' => 'Whale 에서 가져옴',
      _ => '가져온 즐겨찾기',
    };
    final n = tree.importChromium(jsonDecode(await f.readAsString()) as Map<String, dynamic>, name);
    if (n > 0) _changed();
    return n;
  }
}
