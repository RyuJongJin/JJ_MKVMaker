import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../app/app_controller.dart';
import '../core/file_ops.dart';
import '../core/playlist.dart' show isVideoFile;
import '../platform/android/android_storage.dart';
import 'app_actions.dart';
import 'explorer_look.dart';
import 'player_page.dart';
import 'theme.dart';
import '../l10n/tr.dart';

/// 파일 탐색기 (X-plore 참고): 두 창 (트리 목록) + 가운데 기능 버튼 줄.
///
/// - 폴더를 누르면 그 자리에서 펼치고 · 접는다 (트리). 마지막으로 누른 폴더가 그 창의 "지금 폴더".
/// - 동영상을 누르면 기본 동작 (내장 플레이어, 또는 환경 설정 > 재생 > 확장자별 재생 프로그램),
///   길게 누르거나 오른쪽 클릭하면 메뉴 (내장 플레이어 · 다른 앱으로 열기 · MKV 목록에 추가 · 이름 바꾸기 …).
/// - 오른쪽 동그라미로 여러 개를 표시해 복사 · 이동 · 삭제 · 재생한다. 복사 · 이동은 다른 창의 지금 폴더로.
/// - 창 배치 (두 창 / 한 창, 좌우 / 위아래, 버튼 줄 위치) 와 버튼 구성은 바꿀 수 있다 (위쪽 ⋮ 메뉴).
class ExplorerPage extends StatefulWidget {
  final AppController c;
  const ExplorerPage({super.key, required this.c});

  static const routeName = 'explorer';
  static int _open = 0;

  /// 파일 탐색기로: 이미 열려 있으면 그 화면으로 돌아간다 (보던 폴더 그대로)
  static Future<void> open(NavigatorState nav, {required AppController c}) async {
    if (_open > 0) {
      var found = false;
      nav.popUntil((r) {
        if (r.settings.name == routeName) found = true;
        return found || r.isFirst;
      });
      if (found) return;
    }
    await nav.push(MaterialPageRoute<void>(
      settings: const RouteSettings(name: routeName),
      builder: (_) => ExplorerPage(c: c),
    ));
  }

  @override
  State<ExplorerPage> createState() => _ExplorerPageState();
}

/// 기능 버튼 (가운데 줄). 이름은 설정 (explorerButtons) 에 저장된다.
enum ExplorerButton {
  up(Icons.arrow_upward, '상위 폴더'),
  refresh(Icons.refresh, '새로 고침'),
  select(Icons.checklist, '선택'),
  play(Icons.play_circle_outline, '재생'),
  addMkv(Icons.playlist_add, 'MKV 목록에 추가'),
  newFolder(Icons.create_new_folder_outlined, '새 폴더'),
  rename(Icons.drive_file_rename_outline, '이름 변경'),
  copy(Icons.copy_outlined, '복사'),
  move(Icons.drive_file_move_outline, '이동'),
  paste(Icons.content_paste, '붙여넣기'),
  delete(Icons.delete_outline, '삭제'),
  search(Icons.search, '찾기'),
  sort(Icons.sort, '정렬 기준'),
  hidden(Icons.visibility_outlined, '숨은 항목 표시'),
  history(Icons.history, '내역'),
  layout(Icons.view_quilt_outlined, '창 배치'),
  buttons(Icons.tune, '버튼 구성');

  final IconData icon;
  final String label;
  const ExplorerButton(this.icon, this.label);

  static List<ExplorerButton> fromSettings(List<String> names) {
    final out = [
      for (final n in names)
        for (final b in values)
          if (b.name == n) b,
    ];
    return out.isEmpty ? values.toList() : out;
  }
}

/// 한 창의 상태: 저장 장치 (맨 위), 펼친 폴더, 읽어 둔 목록, 표시한 항목
class _Pane extends ChangeNotifier {
  String root;
  String current;
  String? focused;
  final expanded = <String>{};
  final cache = <String, List<FileEntry>>{};
  final loading = <String>{};
  final errors = <String, String>{};
  final marked = <String>{};

  /// 목록 스크롤 (폴더로 이동하면 그 폴더가 보이게)
  final scroll = ScrollController();

  /// "폴더 + 파일 목록" 배치의 오른쪽 파일 목록 스크롤
  final listScroll = ScrollController();

  _Pane(this.root) : current = root;

  /// 화면을 닫은 뒤 끝난 파일 작업 · 읽기가 알리지 않게
  bool _disposed = false;

  void changed() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    scroll.dispose();
    listScroll.dispose();
    super.dispose();
  }
}

/// 트리 · 목록의 한 줄
class _Row {
  final FileEntry entry;
  final int depth;
  final bool isRoot;

  /// 파일 목록 맨 위의 ".." (상위 폴더로)
  final bool isUp;
  const _Row(this.entry, this.depth, {this.isRoot = false, this.isUp = false});
}

class _ExplorerPageState extends State<ExplorerPage> {
  AppController get c => widget.c;

  /// 저장 장치: (경로, 이름)
  List<(String, String)> _volumes = [];
  late final List<_Pane> _panes = [_Pane(''), _Pane('')];
  int _active = 0;
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    ExplorerPage._open++;
    for (final pane in _panes) {
      pane.addListener(_onPane);
    }
    _init();
  }

  @override
  void dispose() {
    ExplorerPage._open--;
    for (final pane in _panes) {
      pane.dispose();
    }
    super.dispose();
  }

  void _onPane() {
    if (mounted) setState(() {});
  }

  Future<void> _init() async {
    _volumes = await _loadVolumes();
    if (_volumes.isEmpty) _volumes = [(Platform.isWindows ? r'C:\' : '/', Platform.isWindows ? 'C:' : '/')];
    final saved = c.settings.explorerPaths;
    for (var i = 0; i < 2; i++) {
      final want = i < saved.length && Directory(saved[i]).existsSync() ? saved[i] : _volumes[0].$1;
      await _goTo(_panes[i], want, remember: false);
    }
    if (!mounted) return;
    setState(() => _ready = true);
    for (final pane in _panes) {
      _reveal(pane, pane.current); // 목록이 그려진 뒤에
    }
  }

  Future<List<(String, String)>> _loadVolumes() async {
    if (Platform.isWindows) return windowsDrives();
    if (Platform.isAndroid) {
      final v = await AndroidAccess.volumes();
      return [for (final x in v) (x.$1, x.$2.isEmpty ? p.basename(x.$1) : x.$2)];
    }
    return [('/', '/')];
  }

  String _volumeOf(String path) {
    String best = _volumes.first.$1;
    var len = -1;
    for (final (v, _) in _volumes) {
      final inside = samePath(v, path) || p.isWithin(v, path) ||
          (Platform.isWindows && p.isWithin(v.toLowerCase(), path.toLowerCase()));
      if (inside && v.length > len) {
        best = v;
        len = v.length;
      }
    }
    return best;
  }

  // ───────── 목록 읽기 · 이동 ─────────

  Future<void> _load(_Pane pane, String dir, {bool force = false}) async {
    if (!force && pane.cache.containsKey(dir)) return;
    pane.loading.add(dir);
    pane.changed();
    try {
      final list = await listEntries(dir, showHidden: c.settings.explorerShowHidden);
      pane.cache[dir] = _sorted(list);
      pane.errors.remove(dir);
    } catch (e) {
      pane.cache[dir] = const [];
      pane.errors[dir] = '$e';
    } finally {
      pane.loading.remove(dir);
      pane.changed();
    }
  }

  List<FileEntry> _sorted(List<FileEntry> list) {
    final by = SortBy.values.firstWhere((s) => s.name == c.settings.explorerSort, orElse: () => SortBy.name);
    return sortEntries(list, by, descending: c.settings.explorerSortDesc);
  }

  /// 그 폴더로: 저장 장치부터 그 폴더까지 펼치고 지금 폴더로 정한다
  Future<void> _goTo(_Pane pane, String dir, {bool remember = true}) async {
    pane.root = _volumeOf(dir);
    final chain = <String>[];
    var d = p.normalize(dir);
    while (true) {
      chain.insert(0, d);
      if (samePath(d, pane.root) || p.dirname(d) == d) break;
      d = p.dirname(d);
    }
    for (final x in chain) {
      pane.expanded.add(x);
      await _load(pane, x);
    }
    pane
      ..current = dir
      ..focused = dir;
    pane.changed();
    if (pane.listScroll.hasClients) pane.listScroll.jumpTo(0);
    _reveal(pane, dir);
    if (remember) _remember(pane, dir);
  }

  /// 그 항목이 목록 위쪽 1/4 쯤에 보이게 스크롤 (깊은 폴더로 가면 위쪽 폴더들의 다른 항목에 밀려 안 보이므로)
  void _reveal(_Pane pane, String path) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !pane.scroll.hasClients) return;
      final i = _rows(pane, foldersOnly: _split).indexWhere((r) => samePath(r.entry.path, path));
      if (i < 0) return;
      final pos = pane.scroll.position;
      final want = (i * _look.rowHeight - pos.viewportDimension / 4).clamp(0.0, pos.maxScrollExtent);
      pane.scroll.jumpTo(want);
    });
  }

  /// 마지막 폴더 · 내역 저장
  void _remember(_Pane pane, String dir) {
    final i = _panes.indexOf(pane);
    final paths = [..._panes.map((x) => x.current)];
    final hist = [dir, ...c.settings.explorerHistory.where((h) => !samePath(h, dir))].take(30).toList();
    unawaited(c.updateSettings((s) => s
      ..explorerPaths = paths
      ..explorerHistory = hist));
    if (i >= 0) _active = i;
  }

  /// 지금 모양 (환경 설정 > 파일 탐색기 > 스타일)
  ExplorerStyle get _look => ExplorerStyle.of(c.settings.explorerStyle);

  /// 왼쪽 폴더 트리 + 오른쪽 파일 목록 배치
  bool get _split => c.settings.explorerLayout == 'split';

  /// 한 번 누르면 선택 · 두 번 누르면 열기 (아니면 한 번에 바로 열기)
  bool get _selectMode => c.settings.explorerClick != 'open';

  /// 트리 줄. [foldersOnly]: 폴더만 ("폴더 + 파일 목록" 배치의 왼쪽)
  List<_Row> _rows(_Pane pane, {bool foldersOnly = false}) {
    final out = <_Row>[];
    final rootEntry = FileEntry(pane.root, isDir: true, modified: DateTime(0));
    out.add(_Row(rootEntry, 0, isRoot: true));
    void walk(String dir, int depth) {
      if (!pane.expanded.contains(dir)) return;
      for (final e in pane.cache[dir] ?? const <FileEntry>[]) {
        if (foldersOnly && !e.isDir) continue;
        out.add(_Row(e, depth));
        if (e.isDir) walk(e.path, depth + 1);
      }
    }

    walk(pane.root, 1);
    return out;
  }

  // ───────── 누르기 ─────────

  /// 선택 모드 (X-plore 처럼): 각 줄의 ✔ 동그라미가 보이고, 누르면 고르기 · 풀기
  bool _selecting = false;

  void _setSelecting(bool on) => setState(() {
        _selecting = on;
        if (!on) {
          for (final x in _panes) {
            x.marked.clear();
          }
        }
      });

  /// 한 번 누르기.
  /// - 선택 모드: 고르기 · 풀기 ([_toggleMark])
  /// - 폴더: 바로 펼치기 · 접기 (트리), 들어가기 (오른쪽 파일 목록)
  /// - 파일: 누르기 설정이 "선택" 이면 고르기만 (두 번 누르면 실행), "바로 실행" 이면 실행
  /// Ctrl 을 누른 채면 선택 모드로 고르기. 목록의 ".." 은 늘 상위 폴더로.
  Future<void> _onTap(_Pane pane, _Row row, {bool list = false}) async {
    final e = row.entry;
    setState(() => _active = _panes.indexOf(pane));
    if (row.isUp) {
      await _goTo(pane, e.path);
      return;
    }
    if (!row.isRoot && (_selecting || HardwareKeyboard.instance.isControlPressed)) {
      if (!_selecting) setState(() => _selecting = true);
      await _toggleMark(pane, e);
      return;
    }
    if (e.isDir || !_selectMode) return _onOpen(pane, row, list: list);
    pane.focused = e.path;
    if (!list) pane.current = p.dirname(e.path);
    pane.changed();
  }

  /// 선택 모드에서 누르기: 파일은 고르기 · 풀기.
  /// 폴더는 처음엔 고르기, 고른 폴더를 다시 누르면 폴더는 풀고 펼쳐서 그 안의 파일 · 폴더를 모두 고른다.
  Future<void> _toggleMark(_Pane pane, FileEntry e) async {
    pane.focused = e.path;
    if (!pane.marked.contains(e.path)) {
      setState(() => pane.marked.add(e.path));
      return;
    }
    setState(() => pane.marked.remove(e.path));
    if (!e.isDir) return;
    await _load(pane, e.path);
    setState(() {
      pane.expanded.add(e.path);
      pane.marked.addAll([for (final x in pane.cache[e.path] ?? const <FileEntry>[]) x.path]);
    });
  }

  /// 열기 (파일: 선택 설정이면 두 번 누르기, 바로 실행이면 한 번 누르기 / 폴더: 한 번 누르기):
  /// 트리의 폴더는 펼치기 · 접기, 목록의 폴더는 들어가기 (왼쪽 트리도 따라감), 파일은 실행.
  Future<void> _onOpen(_Pane pane, _Row row, {bool list = false}) async {
    final e = row.entry;
    setState(() => _active = _panes.indexOf(pane));
    pane.focused = e.path;
    if (row.isUp || (e.isDir && list)) {
      await _goTo(pane, e.path);
      return;
    }
    if (e.isDir) {
      await _toggle(pane, e);
      return;
    }
    if (!list) pane.current = p.dirname(e.path);
    pane.changed();
    await _open(e.path);
  }

  /// 트리 폴더 펼치기 · 접기 (› 화살표 · 열기)
  Future<void> _toggle(_Pane pane, FileEntry e) async {
    setState(() => _active = _panes.indexOf(pane));
    if (pane.expanded.contains(e.path)) {
      pane.expanded.remove(e.path);
      // 접은 폴더 안이 지금 폴더였으면 접은 폴더로
      if (isSameOrInside(pane.current, e.path)) pane.current = e.path;
      pane.changed();
      return;
    }
    pane
      ..expanded.add(e.path)
      ..current = e.path
      ..focused = e.path;
    await _load(pane, e.path);
    if (pane.listScroll.hasClients) pane.listScroll.jumpTo(0);
    _remember(pane, e.path);
  }

  /// 파일 열기 (기본 동작): 동영상은 내장 플레이어 (또는 확장자별 프로그램), 그 밖은 기본 연결 프로그램
  Future<void> _open(String path) async {
    if (isVideoFile(path)) {
      await playFiles(context, c, [path]);
      return;
    }
    final ok = await c.services.shell.openWith(path);
    if (!ok) _snack(tr('이 파일을 열 수 있는 앱이 없습니다.'));
  }

  Future<void> _menu(_Pane pane, FileEntry e, Offset at) async {
    setState(() => _active = _panes.indexOf(pane));
    pane.focused = e.path;
    pane.changed();
    final video = !e.isDir && isVideoFile(e.path);
    final dual = c.settings.explorerLayout == 'dual';
    final items = <(String, IconData, String)>[
      if (e.isDir) ('open', Icons.folder_open, tr('열기')),
      if (e.isDir && dual) ('openOther', Icons.vertical_split_outlined, tr('다른 창에서 열기')),
      if (e.isDir) ('playFolder', Icons.play_circle_outline, tr('이 폴더의 동영상 재생')),
      if (video) ('playInternal', Icons.play_circle_outline, tr('내장 플레이어로 재생')),
      if (!e.isDir) ('openWith', Icons.open_in_new, tr('다른 앱으로 열기')),
      if (!e.isDir && !video) ('openDefault', Icons.launch, tr('기본 앱으로 열기')),
      if (video) ('addMkv', Icons.playlist_add, tr('MKV 목록에 추가')),
      ('select', Icons.check_circle_outline, tr('선택')),
      ('rename', Icons.drive_file_rename_outline, tr('이름 변경')),
      if (dual) ('copy', Icons.copy_outlined, tr('다른 창으로 복사')),
      if (dual) ('move', Icons.drive_file_move_outline, tr('다른 창으로 이동')),
      // 어느 배치에서나: 담아 두었다가 원하는 폴더에서 붙여넣기
      ('clipCopy', Icons.content_copy, dual ? tr('복사 (붙여넣기로)') : tr('복사')),
      ('clipMove', Icons.content_cut, dual ? tr('이동 (붙여넣기로)') : tr('이동')),
      if (_clip.isNotEmpty)
        ('paste', Icons.content_paste, trf('{0} 에 붙여넣기 ({1}개)', [p.basename(e.isDir ? e.path : p.dirname(e.path)), _clip.length])),
      ('delete', Icons.delete_outline, tr('삭제')),
      if (!Platform.isAndroid || e.isDir) ('reveal', Icons.folder_outlined, tr('파일 관리자에서 보기')),
      ('info', Icons.info_outline, tr('정보')),
    ];
    final size = MediaQuery.sizeOf(context);
    final pick = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(at.dx, at.dy, size.width - at.dx, size.height - at.dy),
      items: [
        for (final (id, icon, label) in items)
          PopupMenuItem(
            value: id,
            child: Row(children: [Icon(icon, size: 18), const SizedBox(width: 12), Text(label)]),
          ),
      ],
    );
    if (pick == null || !mounted) return;
    switch (pick) {
      case 'open':
        await _goTo(pane, e.path);
      case 'openOther':
        final other = _panes[1 - _panes.indexOf(pane)];
        await _goTo(other, e.path);
        setState(() => _active = _panes.indexOf(other));
      case 'playFolder':
        await _playFolder(e.path);
      case 'playInternal':
        await playFiles(context, c, [e.path], internal: true);
      case 'openWith':
        if (!await c.services.shell.openWith(e.path, choose: true)) _snack(tr('이 파일을 열 수 있는 앱이 없습니다.'));
      case 'openDefault':
        if (!await c.services.shell.openWith(e.path)) _snack(tr('이 파일을 열 수 있는 앱이 없습니다.'));
      case 'addMkv':
        await _addMkv([e.path]);
      case 'select':
        setState(() => _selecting = true);
        if (!pane.marked.contains(e.path)) await _toggleMark(pane, e);
      case 'rename':
        await _rename(pane, e.path);
      case 'copy':
        await _transfer(pane, [e.path], move: false);
      case 'move':
        await _transfer(pane, [e.path], move: true);
      case 'clipCopy':
        _toClipboard(pane.marked.contains(e.path) ? pane.marked.toList() : [e.path], move: false);
      case 'clipMove':
        _toClipboard(pane.marked.contains(e.path) ? pane.marked.toList() : [e.path], move: true);
      case 'paste':
        await _paste(pane, e.isDir ? e.path : p.dirname(e.path));
      case 'delete':
        await _delete(pane, [e.path]);
      case 'reveal':
        await c.services.shell.revealFile(e.path);
      case 'info':
        await _info(e);
    }
  }

  // ───────── 기능 ─────────

  _Pane get _pane => _panes[_active];
  _Pane? get _other => c.settings.explorerLayout == 'dual' ? _panes[1 - _active] : null;

  /// 기능의 대상: 표시한 항목, 없으면 마지막으로 누른 항목 (저장 장치 맨 위는 빼고)
  List<String> _targets(_Pane pane) {
    if (pane.marked.isNotEmpty) return pane.marked.toList();
    final f = pane.focused;
    if (f == null || samePath(f, pane.root)) return const [];
    return [f];
  }

  void _snack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _refresh(_Pane pane, Iterable<String> dirs) async {
    for (final d in {...dirs}) {
      if (pane.cache.containsKey(d)) await _load(pane, d, force: true);
    }
  }

  /// 바뀐 폴더를 두 창 모두 다시 읽는다
  Future<void> _refreshAll(Iterable<String> dirs) async {
    for (final pane in _panes) {
      await _refresh(pane, dirs);
    }
  }

  Future<void> _button(ExplorerButton b) async {
    final pane = _pane;
    switch (b) {
      case ExplorerButton.up:
        if (samePath(pane.current, pane.root)) return;
        final up = p.dirname(pane.current);
        pane.expanded.remove(pane.current);
        await _goTo(pane, up);
      case ExplorerButton.select:
        _setSelecting(!_selecting);
      case ExplorerButton.refresh:
        pane.cache.clear();
        for (final d in pane.expanded.toList()) {
          await _load(pane, d, force: true);
        }
      case ExplorerButton.play:
        final t = _targets(pane);
        final videos = t.where((x) => !FileSystemEntity.isDirectorySync(x) && isVideoFile(x)).toList();
        if (videos.isNotEmpty) {
          await playFiles(context, c, videos, keepOrder: pane.marked.isNotEmpty);
        } else {
          await _playFolder(t.length == 1 && FileSystemEntity.isDirectorySync(t.first) ? t.first : pane.current);
        }
      case ExplorerButton.addMkv:
        final t = _targets(pane);
        await _addMkv(t.isEmpty ? [pane.current] : t);
      case ExplorerButton.newFolder:
        final name = await _askName(tr('새 폴더'), '');
        if (name == null) return;
        try {
          final made = await FileOps.makeFolder(pane.current, name);
          await _refreshAll([pane.current]);
          pane.focused = made;
          pane.changed();
        } catch (e) {
          _snack(trf('폴더를 만들 수 없습니다: {0}', [e]));
        }
      case ExplorerButton.rename:
        final t = _targets(pane);
        if (t.length != 1) {
          _snack(tr('이름을 바꿀 항목 하나를 고르세요.'));
          return;
        }
        await _rename(pane, t.first);
      case ExplorerButton.copy:
        await _transfer(pane, _targets(pane), move: false);
      case ExplorerButton.move:
        await _transfer(pane, _targets(pane), move: true);
      case ExplorerButton.paste:
        await _paste(pane, pane.current);
      case ExplorerButton.delete:
        await _delete(pane, _targets(pane));
      case ExplorerButton.search:
        await _search(pane);
      case ExplorerButton.sort:
        await _sortDialog();
      case ExplorerButton.hidden:
        await c.updateSettings((s) => s.explorerShowHidden = !s.explorerShowHidden);
        for (final x in _panes) {
          x.cache.clear();
          for (final d in x.expanded.toList()) {
            await _load(x, d, force: true);
          }
        }
        _snack(c.settings.explorerShowHidden ? tr('숨은 항목을 보입니다.') : tr('숨은 항목을 감춥니다.'));
      case ExplorerButton.history:
        await _historyDialog(pane);
      case ExplorerButton.layout:
        await _layoutDialog();
      case ExplorerButton.buttons:
        await _buttonsDialog();
    }
  }

  Future<void> _playFolder(String dir) async {
    final list = (await listEntries(dir)).where((e) => !e.isDir && isVideoFile(e.path)).map((e) => e.path).toList();
    if (list.isEmpty) {
      _snack(tr('이 폴더에 동영상이 없습니다.'));
      return;
    }
    if (!mounted) return;
    await playFiles(context, c, list);
  }

  Future<void> _addMkv(List<String> paths) async {
    final videos = <String>[];
    for (final x in paths) {
      if (FileSystemEntity.isDirectorySync(x)) {
        videos.addAll((await listEntries(x)).where((e) => !e.isDir && isVideoFile(e.path)).map((e) => e.path));
      } else if (isVideoFile(x)) {
        videos.add(x);
      }
    }
    if (videos.isEmpty) {
      _snack(tr('추가할 동영상이 없습니다.'));
      return;
    }
    await c.addVideos(videos, allowOutputFolder: true);
    _snack(trf('MKV 목록에 {0}개를 추가했습니다.', [videos.length]));
  }

  Future<void> _rename(_Pane pane, String path) async {
    final name = await _askName(tr('이름 변경'), p.basename(path));
    if (name == null || name == p.basename(path)) return;
    try {
      final now = await FileOps.rename(path, name);
      await _refreshAll([p.dirname(path)]);
      for (final x in _panes) {
        if (x.marked.remove(path)) x.marked.add(now);
      }
      pane.focused = now;
      pane.changed();
    } catch (e) {
      _snack(trf('이름을 바꿀 수 없습니다: {0}', [e]));
    }
  }

  Future<void> _delete(_Pane pane, List<String> paths) async {
    if (paths.isEmpty) {
      _snack(tr('지울 항목을 고르세요 (누르거나 오른쪽 동그라미로 표시).'));
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('삭제')),
        // 무엇을 지우는지 늘 보여 준다 (여러 개면 앞의 8개 이름 · 폴더)
        content: Text(paths.length == 1
            ? '${trf('"{0}" 을(를) 지울까요? 되돌릴 수 없습니다.', [p.basename(paths.first)])}\n${p.dirname(paths.first)}'
            : [
                trf('{0}개 항목을 지울까요? 되돌릴 수 없습니다.', [paths.length]),
                for (final x in paths.take(8)) '· ${p.basename(x)}',
                if (paths.length > 8) trf('… 외 {0}개', [paths.length - 8]),
                {for (final x in paths) p.dirname(x)}.join('\n'),
              ].join('\n')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('취소'))),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red.shade700),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr('삭제')),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await FileOps().delete(paths);
    } catch (e) {
      _snack(trf('지우지 못했습니다: {0}', [e]));
    }
    for (final x in _panes) {
      x.marked.removeAll(paths);
      if (_selecting && x.marked.isEmpty) _selecting = false;
      x.expanded.removeWhere((d) => paths.any((s) => isSameOrInside(d, s)));
      if (paths.any((s) => isSameOrInside(x.current, s))) x.current = p.dirname(paths.first);
    }
    await _refreshAll(paths.map(p.dirname));
  }

  /// 다른 창의 지금 폴더로 복사 · 이동 (진행 창 · 취소)
  /// 복사 · 이동 버튼: 두 창이면 다른 창의 지금 폴더로, 그 밖의 배치는 담아 두기 (붙여넣기로)
  Future<void> _transfer(_Pane pane, List<String> sources, {required bool move}) async {
    final other = _other;
    if (other == null) {
      _toClipboard(sources, move: move);
      return;
    }
    await _runTransfer(pane, sources, other.current, move: move);
  }

  /// 복사 · 이동할 항목 (붙여넣기 전까지 담아 둠)
  List<String> _clip = [];
  bool _clipMove = false;

  void _toClipboard(List<String> sources, {required bool move}) {
    if (sources.isEmpty) {
      _snack(tr('복사 · 이동할 항목을 고르세요 (누르거나 오른쪽 동그라미로 표시).'));
      return;
    }
    setState(() {
      _clip = [...sources];
      _clipMove = move;
    });
    _snack(trf('{0}개 항목을 담았습니다. 넣을 폴더에서 [붙여넣기] 를 누르세요 ({1}).',
        [sources.length, move ? tr('이동') : tr('복사')]));
  }

  Future<void> _paste(_Pane pane, String dest) async {
    if (_clip.isEmpty) {
      _snack(tr('붙여넣을 항목이 없습니다. 먼저 [복사] · [이동] 으로 담으세요.'));
      return;
    }
    final items = _clip, move = _clipMove;
    final done = await _runTransfer(pane, items, dest, move: move);
    // 옮긴 것은 다시 붙여넣을 수 없으므로 비운다 (복사는 여러 곳에 붙여넣을 수 있게 남김)
    if (done && move && mounted) setState(() => _clip = []);
  }

  /// [dest] 로 복사 · 이동 (확인 · 진행 창 · 취소). 끝까지 했으면 true.
  Future<bool> _runTransfer(_Pane pane, List<String> sources, String dest, {required bool move}) async {
    if (sources.isEmpty) {
      _snack(tr('복사 · 이동할 항목을 고르세요 (누르거나 오른쪽 동그라미로 표시).'));
      return false;
    }
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(move ? tr('이동') : tr('복사')),
        content: Text(trf('{0}개 항목을 다음 폴더로 {1}\n{2}', [sources.length, move ? tr('옮길까요?') : tr('복사할까요?'), dest])),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('취소'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(move ? tr('이동') : tr('복사'))),
        ],
      ),
    );
    if (go != true || !mounted) return false;
    final ops = FileOps();
    final progress = ValueNotifier<(String, double)>(('', 0));
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: Text(move ? tr('옮기는 중') : tr('복사하는 중')),
        content: ValueListenableBuilder<(String, double)>(
          valueListenable: progress,
          builder: (_, v, _) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(p.basename(v.$1), maxLines: 1, overflow: TextOverflow.ellipsis),
            const SizedBox(height: 10),
            LinearProgressIndicator(value: v.$2 <= 0 ? null : v.$2),
            const SizedBox(height: 6),
            Text('${(v.$2 * 100).round()}%', style: const TextStyle(fontSize: 12, color: JjColors.textDim)),
          ]),
        ),
        actions: [TextButton(onPressed: ops.cancel, child: Text(tr('취소')))],
      ),
    );
    Object? error;
    var made = <String>[];
    try {
      void onP(String f, int done, int total) => progress.value = (f, total == 0 ? 0 : done / total);
      made = move ? await ops.move(sources, dest, onProgress: onP) : await ops.copy(sources, dest, onProgress: onP);
    } on FileOpCancelled {
      error = tr('취소했습니다.');
    } catch (e) {
      error = e;
    }
    if (mounted) Navigator.of(context).pop();
    pane.marked.clear();
    if (_selecting && mounted) _setSelecting(false);
    await _refreshAll([dest, ...sources.map(p.dirname)]);
    // 넣은 폴더가 창의 지금 폴더면 펼쳐서 새 항목이 보이게
    for (final x in _panes) {
      if (samePath(x.current, dest)) {
        x.expanded.add(dest);
        await _load(x, dest, force: true);
      }
      x.changed();
    }
    _snack(error != null
        ? trf('끝나지 못했습니다: {0}', [error])
        : trf('{0}개 항목을 {1}', [made.length, move ? tr('옮겼습니다.') : tr('복사했습니다.')]));
    return error == null;
  }

  Future<String?> _askName(String title, String initial) {
    final ctl = TextEditingController(text: initial);
    final dot = initial.lastIndexOf('.');
    ctl.selection = TextSelection(baseOffset: 0, extentOffset: dot > 0 ? dot : initial.length);
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: ctl,
          autofocus: true,
          decoration: InputDecoration(hintText: tr('이름')),
          onSubmitted: (v) => Navigator.pop(ctx, v.trim().isEmpty ? null : v.trim()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('취소'))),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, ctl.text.trim().isEmpty ? null : ctl.text.trim()),
              child: Text(tr('확인'))),
        ],
      ),
    );
  }

  Future<void> _info(FileEntry e) async {
    final size = e.isDir ? await FileOps.totalSize([e.path]) : e.size;
    final meta = !e.isDir && isVideoFile(e.path) ? await _Meta.of(c, e.path) : null;
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(e.name),
        content: SelectableText([
          e.path,
          '${tr('크기')}: ${formatSize(size)}',
          if (e.modified.year > 1) '${tr('바뀐 날')}: ${_date(e.modified)}',
          if (meta != null && meta.isNotEmpty) '${tr('동영상')}: $meta',
        ].join('\n')),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('닫기')))],
      ),
    );
  }

  Future<void> _search(_Pane pane) async {
    final q = await _askName(trf('찾기: {0}', [pane.current]), '');
    if (q == null || !mounted) return;
    final found = await showDialog<FileEntry>(
      context: context,
      builder: (ctx) => _SearchDialog(root: pane.current, query: q, showHidden: c.settings.explorerShowHidden),
    );
    if (found == null) return;
    await _goTo(pane, found.isDir ? found.path : p.dirname(found.path));
    pane.focused = found.path;
    pane.changed();
  }

  Future<void> _sortDialog() async {
    final s = c.settings;
    var by = s.explorerSort;
    var desc = s.explorerSortDesc;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => AlertDialog(
          title: Text(tr('정렬 기준')),
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Wrap(spacing: 6, children: [
              for (final (v, label) in [
                ('name', tr('이름')),
                ('date', tr('바뀐 날')),
                ('size', tr('크기')),
                ('type', tr('종류 (확장자)')),
              ])
                ChoiceChip(label: Text(label), selected: by == v, onSelected: (_) => set(() => by = v)),
            ]),
            SwitchListTile(value: desc, title: Text(tr('거꾸로')), onChanged: (x) => set(() => desc = x)),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('취소'))),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr('확인'))),
          ],
        ),
      ),
    );
    if (ok != true) return;
    await c.updateSettings((x) => x
      ..explorerSort = by
      ..explorerSortDesc = desc);
    for (final pane in _panes) {
      for (final k in pane.cache.keys.toList()) {
        pane.cache[k] = _sorted(pane.cache[k]!);
      }
      pane.changed();
    }
  }

  Future<void> _historyDialog(_Pane pane) async {
    final hist = c.settings.explorerHistory.where((h) => Directory(h).existsSync()).toList();
    final pick = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(tr('내역 (최근 폴더)')),
        children: [
          if (hist.isEmpty) Padding(padding: const EdgeInsets.all(16), child: Text(tr('없음'))),
          for (final h in hist)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, h),
              child: Text(h, maxLines: 2, overflow: TextOverflow.ellipsis),
            ),
        ],
      ),
    );
    if (pick != null) await _goTo(pane, pick);
  }

  Future<void> _layoutDialog() async {
    final s = c.settings;
    var layout = s.explorerLayout, orient = s.explorerOrientation, bar = s.explorerToolbar;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) {
          Widget group(String title, String value, List<(String, String)> items, void Function(String) on) =>
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Padding(
                  padding: const EdgeInsets.only(top: 8, left: 4),
                  child: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
                ),
                Wrap(spacing: 6, children: [
                  for (final (v, label) in items)
                    ChoiceChip(label: Text(label), selected: value == v, onSelected: (_) => set(() => on(v))),
                ]),
              ]);
          return AlertDialog(
            title: Text(tr('창 배치')),
            content: SizedBox(
              width: 420,
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                group(tr('창'), layout, [
                  ('dual', tr('두 창')),
                  ('split', tr('폴더 + 파일 목록')),
                  ('single', tr('한 창')),
                ], (v) => layout = v),
                if (layout == 'split')
                  Padding(
                    padding: const EdgeInsets.only(top: 6, left: 4),
                    child: Text(tr('왼쪽에 폴더, 오른쪽에 왼쪽에서 고른 폴더의 파일들을 보여 줍니다 (Windows 탐색기처럼).'),
                        style: const TextStyle(fontSize: 12, color: JjColors.textDim)),
                  ),
                if (layout != 'single')
                  group(tr('두 창 배치'), orient, [
                    ('auto', tr('화면 모양 따라')),
                    ('side', tr('좌우')),
                    ('stacked', tr('위아래')),
                  ], (v) => orient = v),
                group(tr('기능 버튼 줄'), bar, [
                  ('middle', layout != 'single' ? tr('두 창 사이') : tr('왼쪽')),
                  ('edge', tr('끝 (오른쪽 · 아래)')),
                  ('hidden', tr('숨김')),
                ], (v) => bar = v),
                if (bar == 'hidden')
                  Padding(
                    padding: const EdgeInsets.only(top: 8, left: 4),
                    child: Text(tr('숨겨도 위쪽 ⋮ 메뉴에서 창 배치 · 버튼 구성을 바꿀 수 있습니다.'),
                        style: const TextStyle(fontSize: 12, color: JjColors.textDim)),
                  ),
              ]),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('취소'))),
              FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr('확인'))),
            ],
          );
        },
      ),
    );
    if (ok != true) return;
    await c.updateSettings((x) => x
      ..explorerLayout = layout
      ..explorerOrientation = orient
      ..explorerToolbar = bar);
    if (layout == 'single') setState(() => _active = 0);
    // 배치가 바뀌면 목록을 새로 그리므로 맨 위로 간다: 보던 폴더가 다시 보이게
    for (final pane in _panes) {
      _reveal(pane, pane.current);
    }
  }

  Future<void> _buttonsDialog() async {
    final current = ExplorerButton.fromSettings(c.settings.explorerButtons);
    final order = [...current, ...ExplorerButton.values.where((b) => !current.contains(b))];
    final on = {...current};
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => AlertDialog(
          title: Text(tr('버튼 구성')),
          content: SizedBox(
            width: 380,
            height: 460,
            child: Column(children: [
              Text(tr('보일 버튼을 고르고, 끌어서 순서를 바꿉니다.'),
                  style: const TextStyle(fontSize: 12, color: JjColors.textDim)),
              const SizedBox(height: 8),
              Expanded(
                child: ReorderableListView(
                  buildDefaultDragHandles: true,
                  onReorderItem: (a, b) => set(() => order.insert(b, order.removeAt(a))),
                  children: [
                    for (final b in order)
                      CheckboxListTile(
                        key: ValueKey(b),
                        dense: true,
                        value: on.contains(b),
                        secondary: Icon(b.icon),
                        title: Text(tr(b.label)),
                        controlAffinity: ListTileControlAffinity.leading,
                        onChanged: (v) => set(() => v == true ? on.add(b) : on.remove(b)),
                      ),
                  ],
                ),
              ),
            ]),
          ),
          actions: [
            TextButton(
              onPressed: () => set(() {
                order
                  ..clear()
                  ..addAll(ExplorerButton.values);
                on
                  ..clear()
                  ..addAll(ExplorerButton.values);
              }),
              child: Text(tr('기본값')),
            ),
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('취소'))),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr('확인'))),
          ],
        ),
      ),
    );
    if (ok != true) return;
    final names = [for (final b in order) if (on.contains(b)) b.name];
    await c.updateSettings((x) => x.explorerButtons = names.isEmpty ? [ExplorerButton.layout.name] : names);
  }

  // ───────── 화면 ─────────

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.f5): () => _button(ExplorerButton.refresh),
        const SingleActivator(LogicalKeyboardKey.delete): () => _button(ExplorerButton.delete),
        const SingleActivator(LogicalKeyboardKey.f2): () => _button(ExplorerButton.rename),
        const SingleActivator(LogicalKeyboardKey.backspace): () => _button(ExplorerButton.up),
        const SingleActivator(LogicalKeyboardKey.tab): () =>
            setState(() => _active = c.settings.explorerLayout == 'dual' ? 1 - _active : 0),
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          body: ListenableBuilder(
            listenable: c,
            builder: (context, _) => Column(children: [
              _topBar(),
              Expanded(child: _ready ? _body() : const Center(child: CircularProgressIndicator())),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _topBar() => Container(
        height: appBarHeight,
        color: JjColors.panel,
        padding: const EdgeInsets.only(left: 8, right: appBarRightPadding),
        child: Row(children: [
          const AppNavButtons(onExplorerPage: true),
          const SizedBox(width: 8),
          Text(tr('파일 탐색기'), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
          const SizedBox(width: 12),
          Expanded(
            child: Text(_ready ? _pane.current : '',
                maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: JjColors.textDim)),
          ),
          PopupMenuButton<ExplorerButton>(
            tooltip: tr('창 배치 · 버튼 구성'),
            icon: const Icon(Icons.more_vert),
            onSelected: _button,
            itemBuilder: (_) => [
              for (final b in [ExplorerButton.layout, ExplorerButton.buttons, ExplorerButton.sort, ExplorerButton.hidden])
                PopupMenuItem(
                  value: b,
                  child: Row(children: [Icon(b.icon, size: 18), const SizedBox(width: 12), Text(tr(b.label))]),
                ),
            ],
          ),
          AppActions(c: c),
        ]),
      );

  /// 모양 · 배치가 바뀌면 (줄 높이 · 창 너비가 달라져) 보던 폴더가 밀려나므로 다시 그 폴더로
  String _shape = '';

  Widget _body() {
    final s = c.settings;
    final shape = '${s.explorerStyle}|${s.explorerLayout}|${s.explorerOrientation}|${s.explorerToolbar}';
    if (_ready && shape != _shape) {
      if (_shape.isNotEmpty) {
        for (final pane in _panes) {
          _reveal(pane, pane.current);
        }
      }
      _shape = shape;
    }
    final dual = s.explorerLayout == 'dual';
    final split = _split;
    return LayoutBuilder(builder: (context, box) {
      final side = !(dual || split) ||
          switch (s.explorerOrientation) {
            'side' => true,
            'stacked' => false,
            _ => box.maxWidth >= box.maxHeight,
          };
      final bar = s.explorerToolbar == 'hidden'
          ? null
          : _Toolbar(
              buttons: ExplorerButton.fromSettings(s.explorerButtons),
              vertical: side,
              onPressed: _button,
              enabled: (b) => switch (b) {
                ExplorerButton.paste => _clip.isNotEmpty,
                _ => true,
              },
              selected: (b) =>
                  (b == ExplorerButton.hidden && s.explorerShowHidden) || (b == ExplorerButton.select && _selecting),
            );
      final middle = bar != null && s.explorerToolbar == 'middle';
      final edge = bar != null && s.explorerToolbar == 'edge';
      final children = <Widget>[
        if (dual) ...[
          Expanded(child: _paneView(0)),
          if (middle) bar,
          Expanded(child: _paneView(1)),
          if (edge) bar,
        ] else if (split) ...[
          // 왼쪽 폴더 트리 (좁게) · 오른쪽 그 폴더의 파일 목록
          Expanded(flex: 2, child: _paneView(0, foldersOnly: true)),
          if (middle) bar,
          Expanded(flex: 3, child: _listView(_panes[0])),
          if (edge) bar,
        ] else ...[
          if (middle) bar,
          Expanded(child: _paneView(0)),
          if (edge) bar,
        ],
      ];
      return side ? Row(children: children) : Column(children: children);
    });
  }

  Widget _frame(int i, List<Widget> children) {
    final active = i == _active;
    return GestureDetector(
      onTapDown: (_) {
        if (_active != i) setState(() => _active = i);
      },
      child: Container(
        margin: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: JjColors.bg,
          border: Border.all(color: active ? JjColors.accent : JjColors.border, width: active ? 1.5 : 1),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Column(children: children),
      ),
    );
  }

  /// 선택 모드 막대: 고른 수 · 모두 고르기 · 선택 끝
  Widget _marksBar(_Pane pane, {String? listDir}) => Container(
        color: JjColors.panel,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        child: Row(children: [
          Icon(Icons.checklist, size: 18, color: JjColors.accent),
          const SizedBox(width: 6),
          Text(trf('{0}개 표시함', [pane.marked.length]), style: const TextStyle(fontSize: 12)),
          const Spacer(),
          TextButton(
            onPressed: () => setState(() {
              final dir = listDir ?? pane.current;
              pane.marked.addAll([for (final x in pane.cache[dir] ?? const <FileEntry>[]) x.path]);
            }),
            child: Text(tr('모두 선택')),
          ),
          TextButton(onPressed: () => setState(pane.marked.clear), child: Text(tr('표시 지우기'))),
          TextButton(onPressed: () => _setSelecting(false), child: Text(tr('선택 끝'))),
        ]),
      );

  /// 트리 창 (저장 장치 고르기 + 트리)
  Widget _paneView(int i, {bool foldersOnly = false}) {
    final pane = _panes[i];
    final rows = _rows(pane, foldersOnly: foldersOnly);
    final look = _look;
    return _frame(i, [
      _paneHeader(pane),
      const Divider(height: 1),
      if (look.columns && !foldersOnly) ExplorerColumnsHeader(style: look, markColumn: _selecting),
      Expanded(
        child: ListView.builder(
          controller: pane.scroll,
          itemCount: rows.length,
          itemExtent: look.rowHeight,
          itemBuilder: (_, k) => _rowView(pane, rows[k], compact: foldersOnly),
        ),
      ),
      if (_selecting && !foldersOnly) _marksBar(pane),
    ]);
  }

  /// "폴더 + 파일 목록" 배치의 오른쪽: 왼쪽 트리에서 고른 폴더의 내용 (맨 위 ".." = 상위 폴더)
  Widget _listView(_Pane pane) {
    final dir = pane.current;
    final entries = pane.cache[dir] ?? const <FileEntry>[];
    final up = !samePath(dir, pane.root);
    final rows = [
      if (up) _Row(FileEntry(p.dirname(dir), isDir: true, modified: DateTime(0)), 0, isUp: true),
      for (final e in entries) _Row(e, 0),
    ];
    final look = _look;
    return _frame(0, [
      Container(
        height: 40,
        alignment: Alignment.centerLeft,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Text(dir, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: JjColors.textDim)),
      ),
      const Divider(height: 1),
      if (look.columns) ExplorerColumnsHeader(style: look, markColumn: _selecting),
      Expanded(
        child: pane.loading.contains(dir)
            ? const Center(child: CircularProgressIndicator())
            : entries.isEmpty && !up
                ? Center(child: Text(tr('비어 있음'), style: const TextStyle(color: JjColors.textDim)))
                : ListView.builder(
                    controller: pane.listScroll,
                    itemCount: rows.length,
                    itemExtent: look.rowHeight,
                    itemBuilder: (_, k) => _rowView(pane, rows[k], list: true),
                  ),
      ),
      if (_selecting) _marksBar(pane, listDir: dir),
    ]);
  }

  /// 창 위쪽: 저장 장치 고르기
  Widget _paneHeader(_Pane pane) => SizedBox(
        height: 40,
        child: ListView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          children: [
            for (final (path, label) in _volumes)
              Padding(
                padding: const EdgeInsets.only(right: 4),
                child: TextButton.icon(
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    backgroundColor: samePath(pane.root, path) ? JjColors.accent.withValues(alpha: 0.18) : null,
                    foregroundColor: samePath(pane.root, path) ? JjColors.accent : null,
                  ),
                  icon: Icon(Platform.isWindows ? Icons.storage : Icons.sd_storage_outlined, size: 16),
                  label: Text(label),
                  onPressed: () {
                    setState(() => _active = _panes.indexOf(pane));
                    _goTo(pane, path);
                  },
                ),
              ),
          ],
        ),
      );

  /// 한 줄. [list]: "폴더 + 파일 목록" 의 오른쪽 목록 (트리 아님). [compact]: 폴더 트리 (열 · 표시 버튼 없이)
  Widget _rowView(_Pane pane, _Row row, {bool list = false, bool compact = false}) {
    final e = row.entry;
    final look = _look;
    final isCurrent = e.isDir && !list && !row.isUp && samePath(pane.current, e.path);
    final isFocused = !row.isUp && pane.focused != null && samePath(pane.focused!, e.path);
    final marked = pane.marked.contains(e.path);
    final open = e.isDir && !list && pane.expanded.contains(e.path);
    final loading = pane.loading.contains(e.path);
    final name = row.isUp
        ? '..'
        : row.isRoot
            ? (_volumes.firstWhere((v) => samePath(v.$1, e.path), orElse: () => (e.path, e.path)).$2)
            : look == ExplorerStyle.totalcmd
                ? totalCmdName(e)
                : e.name;
    final dim = TextStyle(fontSize: look.fontSize - 2, color: JjColors.textDim);
    final nameStyle = TextStyle(
      fontSize: look.fontSize,
      fontWeight: isCurrent || (look == ExplorerStyle.totalcmd && e.isDir) ? FontWeight.w600 : FontWeight.normal,
      color: isCurrent ? JjColors.accent : null,
    );

    // 트리의 펼치기 화살표 (따로 누름)
    Widget chevron() => SizedBox(
          width: 20,
          child: e.isDir && !list && !row.isUp
              ? (loading
                  ? const Center(
                      child: SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 1.5)))
                  : InkResponse(
                      radius: 16,
                      onTap: () => _toggle(pane, e),
                      child: Icon(open ? Icons.expand_more : Icons.chevron_right, size: 18, color: JjColors.textDim),
                    ))
              : null,
        );

    Widget nameCell() => Row(children: [
          SizedBox(width: list ? 0 : row.depth * look.indent),
          if (!list) chevron(),
          SizedBox(
            width: look.rich ? 56 : look.iconSize + 6,
            height: look.rowHeight - 8,
            child: Center(child: _icon(e, row.isRoot, open, up: row.isUp)),
          ),
          SizedBox(width: look.rich ? 8 : 6),
          Expanded(
            child: look.rich && !e.isDir && !row.isUp
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: nameStyle),
                      Row(children: [
                        Text('${formatSize(e.size)} · ${_date(e.modified)}', style: dim),
                        if (isVideoFile(e.path)) ...[
                          const SizedBox(width: 8),
                          Flexible(child: _MetaText(c: c, path: e.path)),
                        ],
                      ]),
                    ],
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: nameStyle),
                      if (look.rich && e.isDir && pane.errors[e.path] != null)
                        Text(tr('읽을 수 없음'), style: dim.copyWith(color: Colors.redAccent)),
                    ],
                  ),
          ),
        ]);

    final real = !row.isRoot && !row.isUp;
    Widget cell(String t, int flex, {TextAlign align = TextAlign.start}) => Expanded(
          flex: flex,
          child: Text(t, style: dim, textAlign: align, maxLines: 1, overflow: TextOverflow.ellipsis),
        );
    final cells = !look.columns || compact || !real
        ? <Widget>[Expanded(child: nameCell())]
        : look == ExplorerStyle.windows
            ? [
                Expanded(flex: 6, child: nameCell()),
                cell(_date(e.modified), 3),
                cell(typeLabel(e), 2),
                cell(e.isDir ? '' : formatSize(e.size), 2, align: TextAlign.end),
              ]
            : [
                Expanded(flex: 6, child: nameCell()),
                cell(e.isDir ? '' : e.ext, 1),
                cell(e.isDir ? '<DIR>' : formatSize(e.size), 2, align: TextAlign.end),
                const SizedBox(width: 8),
                cell(_date(e.modified), 3),
              ];

    return GestureDetector(
      onSecondaryTapUp: real ? (d) => _menu(pane, e, d.globalPosition) : null,
      onLongPressStart: real ? (d) => _menu(pane, e, d.globalPosition) : null,
      child: Material(
        color: marked
            ? JjColors.accent.withValues(alpha: 0.18)
            : isFocused
                ? JjColors.panel
                : Colors.transparent,
        child: Row(children: [
          Expanded(
            child: InkWell(
              onTap: () => _onTap(pane, row, list: list),
              // 선택 모드: 두 번 누르면 열기 (바로 열기 모드는 두 번 누르기를 받지 않음 - 한 번 누르기가 늦어지지 않게)
              // 폴더는 한 번 누르기로 바로 펼치므로 두 번 누르기를 받지 않는다 (기다리지 않게)
              onDoubleTap: _selectMode && !_selecting && !e.isDir && !row.isUp
                  ? () => _onOpen(pane, row, list: list)
                  : null,
              child: Padding(
                padding: const EdgeInsets.only(left: 6, right: 4),
                child: Row(children: cells),
              ),
            ),
          ),
          // 표시 동그라미는 두 번 누르기 영역 밖 (기다리지 않고 바로)
          if (real && _selecting)
            SizedBox(
              width: 36,
              child: IconButton(
                tooltip: marked ? tr('표시 지우기') : tr('표시 (여러 개 고르기)'),
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                icon: Icon(marked ? Icons.check_circle : Icons.radio_button_unchecked,
                    size: look.rich ? 20 : 16, color: marked ? JjColors.accent : JjColors.textDim),
                onPressed: () {
                  setState(() => _active = _panes.indexOf(pane));
                  _toggleMark(pane, e);
                },
              ),
            )
          else if (_selecting)
            const SizedBox(width: 36),
        ]),
      ),
    );
  }

  Widget _icon(FileEntry e, bool isRoot, bool open, {bool up = false}) {
    final look = _look;
    if (up) return Icon(Icons.arrow_upward, size: look.iconSize, color: JjColors.textDim);
    if (isRoot) return Icon(Icons.sd_storage, color: JjColors.accent, size: look.iconSize - 2);
    // X-plore: 동영상 썸네일 · 그림 미리 보기
    if (look.rich && !e.isDir) {
      if (isVideoFile(e.path)) return _Thumb(c: c, entry: e);
      const images = {'jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp'};
      if (images.contains(e.ext)) {
        return ClipRRect(
          borderRadius: BorderRadius.circular(3),
          child: Image.file(File(e.path),
              width: 56, height: 44, fit: BoxFit.cover, cacheWidth: 112,
              errorBuilder: (_, _, _) => const Icon(Icons.image_outlined, size: 28)),
        );
      }
    }
    final (icon, color) = fileIcon(look, e, open: open);
    return Icon(icon, size: look.rich && !e.isDir ? 28 : look.iconSize, color: color);
  }
}

String _date(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')} '
    '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

/// 기능 버튼 줄 (세로: 두 창 사이 · 가로: 위아래 배치일 때)
class _Toolbar extends StatelessWidget {
  final List<ExplorerButton> buttons;
  final bool vertical;
  final void Function(ExplorerButton) onPressed;
  final bool Function(ExplorerButton) enabled;
  final bool Function(ExplorerButton) selected;
  const _Toolbar(
      {required this.buttons, required this.vertical, required this.onPressed, required this.enabled, required this.selected});

  @override
  Widget build(BuildContext context) {
    Widget btn(ExplorerButton b) {
      final on = enabled(b);
      final sel = selected(b);
      return Tooltip(
        message: tr(b.label),
        child: InkWell(
          onTap: on ? () => onPressed(b) : null,
          borderRadius: BorderRadius.circular(6),
          child: SizedBox(
            width: 72,
            height: 58,
            child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
              Icon(b.icon, size: 22, color: !on ? JjColors.textDim.withValues(alpha: 0.4) : sel ? JjColors.accent : null),
              const SizedBox(height: 2),
              Text(tr(b.label),
                  maxLines: 2,
                  textAlign: TextAlign.center,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 10.5, height: 1.1, color: on ? null : JjColors.textDim)),
            ]),
          ),
        ),
      );
    }

    return Container(
      color: JjColors.panel,
      width: vertical ? 76 : null,
      height: vertical ? null : 62,
      child: SingleChildScrollView(
        scrollDirection: vertical ? Axis.vertical : Axis.horizontal,
        padding: const EdgeInsets.all(2),
        child: vertical
            ? Column(children: [for (final b in buttons) btn(b)])
            : Row(children: [for (final b in buttons) btn(b)]),
      ),
    );
  }
}

/// 찾기 결과 (찾는 대로 보여 주고, 누르면 그 자리로)
class _SearchDialog extends StatefulWidget {
  final String root;
  final String query;
  final bool showHidden;
  const _SearchDialog({required this.root, required this.query, required this.showHidden});

  @override
  State<_SearchDialog> createState() => _SearchDialogState();
}

class _SearchDialogState extends State<_SearchDialog> {
  final _found = <FileEntry>[];
  StreamSubscription<FileEntry>? _sub;
  bool _done = false;

  @override
  void initState() {
    super.initState();
    _sub = searchFiles(widget.root, widget.query, showHidden: widget.showHidden).listen(
      (e) => setState(() => _found.add(e)),
      onDone: () => setState(() => _done = true),
      onError: (_) {},
    );
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Row(children: [
          Expanded(child: Text(trf('"{0}" 찾기 · {1}개', [widget.query, _found.length]))),
          if (!_done) const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
        ]),
        content: SizedBox(
          width: 560,
          height: 420,
          child: _found.isEmpty && _done
              ? Center(child: Text(tr('찾은 것이 없습니다.')))
              : ListView.builder(
                  itemCount: _found.length,
                  itemBuilder: (_, i) {
                    final e = _found[i];
                    return ListTile(
                      dense: true,
                      leading: Icon(e.isDir ? Icons.folder : Icons.insert_drive_file_outlined,
                          color: e.isDir ? Colors.amber : null),
                      title: Text(e.name),
                      subtitle: Text(p.dirname(e.path), maxLines: 1, overflow: TextOverflow.ellipsis),
                      onTap: () => Navigator.pop(context, e),
                    );
                  },
                ),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('닫기')))],
      );
}

// ───────── 동영상 정보 · 썸네일 (보이는 줄만, 차례로) ─────────

/// 한 번에 하나씩 (FFmpeg 를 동시에 많이 띄우지 않게)
class _Queue {
  final int max;
  int _running = 0;
  final _waiting = Queue<Completer<void>>();
  _Queue(this.max);

  Future<T> run<T>(Future<T> Function() job) async {
    if (_running >= max) {
      final w = Completer<void>();
      _waiting.add(w);
      await w.future;
    }
    _running++;
    try {
      return await job();
    } finally {
      _running--;
      if (_waiting.isNotEmpty) _waiting.removeFirst().complete();
    }
  }
}

/// "1920×1080 · 1:23:45"
class _Meta {
  static final _cache = <String, Future<String>>{};
  static final _q = _Queue(2);

  static Future<String> of(AppController c, String path) => _cache[path] ??= _q.run(() async {
        try {
          final info = await c.services.mediaTool.probe(path);
          final v = info.ofType('video').where((s) => (s.width ?? 0) > 0).firstOrNull;
          final d = info.duration;
          return [
            if (v != null) '${v.width}×${v.height}',
            if (d != null) _dur(d),
          ].join(' · ');
        } catch (_) {
          return '';
        }
      });

  static String _dur(Duration d) {
    final h = d.inHours, m = d.inMinutes % 60, s = d.inSeconds % 60;
    String two(int x) => x.toString().padLeft(2, '0');
    return h > 0 ? '$h:${two(m)}:${two(s)}' : '$m:${two(s)}';
  }
}

class _MetaText extends StatelessWidget {
  final AppController c;
  final String path;
  const _MetaText({required this.c, required this.path});

  @override
  Widget build(BuildContext context) => FutureBuilder<String>(
        future: _Meta.of(c, path),
        builder: (_, s) => Text(s.data ?? '',
            maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11, color: JjColors.accent)),
      );
}

/// 동영상 썸네일 (임시 폴더의 jj_thumbs 에 저장해 다시 쓰기). MKV 만들기 등 작업 중에는 만들지 않는다 (FFmpeg 를 같이 씀).
class _Thumbs {
  static final _cache = <String, Future<File?>>{};
  static final _q = _Queue(1);

  static Future<File?> of(AppController c, FileEntry e) {
    final key = '${e.path}|${e.size}|${e.modified.millisecondsSinceEpoch}';
    return _cache[key] ??= _q.run(() async {
      try {
        final dir = Directory(p.join(await c.services.storage.tempDirectory(), 'jj_thumbs'));
        await dir.create(recursive: true);
        final out = File(p.join(dir.path, '${md5.convert(utf8.encode(key))}.jpg'));
        if (await out.exists() && await out.length() > 0) return out;
        if (c.busy) {
          _cache.remove(key); // 작업이 끝나면 다시 시도
          return null;
        }
        for (final at in ['5', '0']) {
          await c.services.mediaTool.runFfmpeg([
            '-hide_banner', '-loglevel', 'error', '-ss', at, '-i', e.path, //
            '-frames:v', '1', '-vf', 'scale=160:-2', '-y', out.path,
          ]);
          if (await out.exists() && await out.length() > 0) return out;
        }
      } catch (_) {}
      return null;
    });
  }
}

class _Thumb extends StatelessWidget {
  final AppController c;
  final FileEntry entry;
  const _Thumb({required this.c, required this.entry});

  @override
  Widget build(BuildContext context) => FutureBuilder<File?>(
        future: _Thumbs.of(c, entry),
        builder: (_, s) {
          final f = s.data;
          if (f == null) return const Icon(Icons.movie_outlined, size: 28, color: JjColors.textDim);
          return ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: Stack(alignment: Alignment.center, children: [
              Image.file(f, width: 56, height: 44, fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => const Icon(Icons.movie_outlined, size: 28)),
              const Icon(Icons.play_arrow, size: 18, color: Colors.white70),
            ]),
          );
        },
      );
}
