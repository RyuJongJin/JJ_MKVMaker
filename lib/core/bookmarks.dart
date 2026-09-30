import 'dart:math' as math;

/// 즐겨찾기 항목 (주소) 또는 폴더 (children 이 있음)
class BookmarkNode {
  final String id;
  String title;
  String? url;
  final List<BookmarkNode>? children;

  BookmarkNode.link(this.id, this.title, String this.url) : children = null;
  BookmarkNode.folder(this.id, this.title, [List<BookmarkNode>? items])
      : url = null,
        children = items ?? [];

  bool get isFolder => children != null;

  Map<String, Object?> toJson() => {
        'id': id,
        'title': title,
        if (url != null) 'url': url,
        if (children != null) 'children': [for (final c in children!) c.toJson()],
      };

  static BookmarkNode fromJson(Map<String, dynamic> j) {
    final kids = j['children'] as List?;
    return kids != null
        ? BookmarkNode.folder(j['id'] as String, j['title'] as String? ?? '',
            [for (final k in kids) fromJson(k as Map<String, dynamic>)])
        : BookmarkNode.link(j['id'] as String, j['title'] as String? ?? '', j['url'] as String? ?? '');
  }
}

/// 즐겨찾기 전체. [bar] = 즐겨찾기 표시줄 (브라우저 위쪽 줄), [other] = 기타 즐겨찾기
class BookmarkTree {
  final BookmarkNode bar;
  final BookmarkNode other;
  int _seq;

  BookmarkTree(this.bar, this.other, [this._seq = 1000]);

  static const barId = 'bar', otherId = 'other';

  /// 처음 쓰는 경우 기본 즐겨찾기
  factory BookmarkTree.defaults() => BookmarkTree(
        BookmarkNode.folder(barId, '즐겨찾기 표시줄', [
          BookmarkNode.link('b1', 'YouTube', 'https://www.youtube.com/'),
          BookmarkNode.link('b2', 'YouTube 구독', 'https://www.youtube.com/feed/subscriptions'),
          BookmarkNode.link('b3', 'OpenSubtitles', 'https://www.opensubtitles.com/'),
        ]),
        BookmarkNode.folder(otherId, '기타 즐겨찾기'),
      );

  String newId() => 'n${++_seq}${math.Random().nextInt(1 << 20)}';

  List<BookmarkNode> get roots => [bar, other];

  Map<String, Object?> toJson() => {'seq': _seq, 'bar': bar.toJson(), 'other': other.toJson()};

  factory BookmarkTree.fromJson(Map<String, dynamic> j) => BookmarkTree(
        BookmarkNode.fromJson(j['bar'] as Map<String, dynamic>),
        BookmarkNode.fromJson(j['other'] as Map<String, dynamic>),
        (j['seq'] as num?)?.toInt() ?? 1000,
      );

  BookmarkNode? find(String id) {
    BookmarkNode? walk(BookmarkNode n) {
      if (n.id == id) return n;
      for (final c in n.children ?? const <BookmarkNode>[]) {
        final r = walk(c);
        if (r != null) return r;
      }
      return null;
    }

    for (final r in roots) {
      final f = walk(r);
      if (f != null) return f;
    }
    return null;
  }

  BookmarkNode? parentOf(String id) {
    BookmarkNode? walk(BookmarkNode n) {
      for (final c in n.children ?? const <BookmarkNode>[]) {
        if (c.id == id) return n;
        final r = walk(c);
        if (r != null) return r;
      }
      return null;
    }

    for (final r in roots) {
      final f = walk(r);
      if (f != null) return f;
    }
    return null;
  }

  /// [url] 과 같은 주소의 즐겨찾기 (끝의 / 무시)
  BookmarkNode? findByUrl(String url) {
    String norm(String u) => u.trim().replaceFirst(RegExp(r'/+$'), '');
    final target = norm(url);
    BookmarkNode? walk(BookmarkNode n) {
      if (n.url != null && norm(n.url!) == target) return n;
      for (final c in n.children ?? const <BookmarkNode>[]) {
        final r = walk(c);
        if (r != null) return r;
      }
      return null;
    }

    for (final r in roots) {
      final f = walk(r);
      if (f != null) return f;
    }
    return null;
  }

  /// 폴더 [parentId] 의 [index] 위치에 추가 (없으면 맨 뒤)
  BookmarkNode add(String parentId, BookmarkNode node, {int? index}) {
    final parent = find(parentId);
    if (parent == null || !parent.isFolder) throw ArgumentError('폴더가 아닙니다: $parentId');
    final list = parent.children!;
    list.insert((index ?? list.length).clamp(0, list.length), node);
    return node;
  }

  /// 삭제. 되살리기용으로 (노드, 부모 id, 위치) 반환. 기본 폴더는 지울 수 없음.
  (BookmarkNode, String, int)? remove(String id) {
    if (id == barId || id == otherId) return null;
    final parent = parentOf(id);
    if (parent == null) return null;
    final i = parent.children!.indexWhere((c) => c.id == id);
    return (parent.children!.removeAt(i), parent.id, i);
  }

  /// [id] 가 [ancestorId] 의 안쪽(자손)인지
  bool isInside(String id, String ancestorId) {
    final a = find(ancestorId);
    if (a == null) return false;
    bool walk(BookmarkNode n) => n.children?.any((c) => c.id == id || walk(c)) ?? false;
    return walk(a);
  }

  /// 이동 (같은 폴더 안 순서 바꾸기 포함). 폴더를 자기 안으로 옮길 수는 없음.
  bool move(String id, String newParentId, int index) {
    if (id == barId || id == otherId) return false;
    if (id == newParentId || isInside(newParentId, id)) return false;
    final target = find(newParentId);
    if (target == null || !target.isFolder) return false;
    final from = parentOf(id);
    if (from == null) return false;
    final oldIndex = from.children!.indexWhere((c) => c.id == id);
    final node = from.children!.removeAt(oldIndex);
    var i = index;
    if (identical(from, target) && oldIndex < index) i--; // 같은 폴더에서 뒤로 옮길 때
    target.children!.insert(i.clamp(0, target.children!.length), node);
    return true;
  }

  /// 모든 폴더 (이동 대상 고르기용): (폴더, 깊이)
  List<(BookmarkNode, int)> folders() {
    final out = <(BookmarkNode, int)>[];
    void walk(BookmarkNode n, int depth) {
      if (!n.isFolder) return;
      out.add((n, depth));
      for (final c in n.children!) {
        walk(c, depth + 1);
      }
    }

    for (final r in roots) {
      walk(r, 0);
    }
    return out;
  }

  /// Chrome · Edge 의 "Bookmarks" 파일 (JSON) 을 [folderTitle] 폴더로 가져오기. 가져온 주소 수 반환.
  int importChromium(Map<String, dynamic> json, String folderTitle) {
    final rootsJ = json['roots'] as Map<String, dynamic>? ?? const {};
    final folder = BookmarkNode.folder(newId(), folderTitle);
    var count = 0;
    BookmarkNode? conv(Map<String, dynamic> n) {
      if (n['type'] == 'url') {
        final u = n['url'] as String? ?? '';
        if (!u.startsWith('http')) return null;
        count++;
        return BookmarkNode.link(newId(), n['name'] as String? ?? u, u);
      }
      if (n['type'] == 'folder') {
        final f = BookmarkNode.folder(newId(), n['name'] as String? ?? '폴더');
        for (final c in (n['children'] as List? ?? const [])) {
          final x = conv(c as Map<String, dynamic>);
          if (x != null) f.children!.add(x);
        }
        return f;
      }
      return null;
    }

    for (final key in ['bookmark_bar', 'other', 'synced']) {
      final r = rootsJ[key];
      if (r is! Map<String, dynamic>) continue;
      final f = conv(r);
      if (f != null && f.children!.isNotEmpty) folder.children!.add(f);
    }
    if (count > 0) other.children!.add(folder);
    return count;
  }
}
