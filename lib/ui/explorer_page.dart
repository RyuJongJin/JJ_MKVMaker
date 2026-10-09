import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../app/app_controller.dart';
import '../app/copy_center.dart';
import '../app/live_sync.dart';
import '../app/settings.dart' show CopyTask;
import '../app/transfer_job.dart';
import '../core/secret_gate.dart';
import '../core/sync_tools.dart';
import '../core/file_ops.dart';
import '../core/playlist.dart' show isAudioFile, isVideoFile;
import '../core/vfs.dart';
import '../core/webdav.dart' show DavRegistry;
import '../platform/android/android_storage.dart';
import 'app_actions.dart';
import 'explorer_look.dart';
import 'monitor_page.dart';
import 'player_page.dart';
import 'rsync_setup.dart';
import 'theme.dart';
import 'file_error.dart';
import 'dav_external.dart';
import '../platform/windows/recycle_bin.dart';
import '../core/sync_preview.dart';
import 'path_label.dart';
import 'sync_preview_view.dart';
import 'webdav_settings.dart';
import 'reader_page.dart';
import '../app/component_store.dart';
import '../app/components.dart';
import 'zip_page.dart';
import '../core/reader_sources.dart';
import '../l10n/tr.dart';

/// 파일 탐색기 (X-plore 참고): 두 창 (트리 목록) + 가운데 기능 버튼 줄.
///
/// - 폴더를 누르면 그 자리에서 펼치고 · 접는다 (트리). 마지막으로 누른 폴더가 그 창의 "지금 폴더".
/// - 동영상을 누르면 기본 동작 (내장 플레이어, 또는 환경 설정 > 재생 > 확장자별 재생 프로그램),
///   길게 누르거나 오른쪽 클릭하면 메뉴 (내장 플레이어 · 다른 앱으로 열기 · MKV 목록에 추가 · 이름 바꾸기 …).
/// - 오른쪽 동그라미로 여러 개를 표시해 복사 · 이동 · 삭제 · 재생한다. 복사 · 이동은 다른 창의 지금 폴더로.
/// - 창 배치 (두 창 / 한 창, 좌우 / 위아래, 버튼 줄 위치) 와 버튼 구성은 바꿀 수 있다 (위쪽 ⋮ 메뉴).
///
/// [rsync] 면 Rsync 화면: 같은 모양이지만 늘 좌우 두 창 · 폴더만 · 창마다 폴더 하나만 고른다.
/// 가운데 → (왼쪽 → 오른쪽) · ← (오른쪽 → 왼쪽) · ⇄ (둘 다 함께) 로 rsync, [모니터링] 에 실행한 것이 남는다.
class ExplorerPage extends StatefulWidget {
  final AppController c;
  final bool rsync;
  const ExplorerPage({super.key, required this.c, this.rsync = false});

  /// 165: 드라이브를 열 수 있는지 (시험에서 응답 없는 드라이브로 바꾼다). 화면을 멈추지 않는 비동기
  @visibleForTesting
  static Future<bool> Function(String path) probeDrive = (path) => Directory(path).exists();

  /// 시험: 이 기기의 저장 장치 목록 (null 이면 실제 목록)
  @visibleForTesting
  static List<(String, String)> Function()? debugVolumes;

  static const routeName = 'explorer';
  static const rsyncRouteName = 'rsync';
  static int _open = 0, _openRsync = 0;

  /// 파일 탐색기로: 이미 열려 있으면 그 화면으로 돌아간다 (보던 폴더 그대로)
  static Future<void> open(NavigatorState nav, {required AppController c}) => _show(nav, c, rsync: false);

  /// Rsync 화면으로 (이미 열려 있으면 그 화면으로)
  static Future<void> openRsync(NavigatorState nav, {required AppController c}) => _show(nav, c, rsync: true);

  static Future<void> _show(NavigatorState nav, AppController c, {required bool rsync}) async {
    final name = rsync ? rsyncRouteName : routeName;
    if ((rsync ? _openRsync : _open) > 0) {
      var found = false;
      nav.popUntil((r) {
        if (r.settings.name == name) found = true;
        return found || r.isFirst;
      });
      if (found) return;
    }
    await nav.push(MaterialPageRoute<void>(
      settings: RouteSettings(name: name),
      builder: (_) => ExplorerPage(c: c, rsync: rsync),
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
  // ── Rsync 화면에만 ──
  toRight(Icons.arrow_forward, '좌 → 우'),
  toLeft(Icons.arrow_back, '좌 ← 우'),
  both(Icons.compare_arrows, '좌 ⇄ 우'),
  monitor(Icons.monitor_heart_outlined, '모니터링'),
  // ──
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
  // 118: 두 창을 좌우 ⇆ / 위아래 ⇅ 로 한 번에 바꾸기 (한 창이면 두 창 (좌우) 으로)
  orient(Icons.swap_horiz, '좌우 ⇆ / 위아래 ⇅'),
  layout(Icons.view_quilt_outlined, '창 배치'),
  buttons(Icons.tune, '버튼 구성');

  final IconData icon;
  final String label;
  const ExplorerButton(this.icon, this.label);

  /// Rsync 화면에만 있는 버튼 (파일 탐색기 버튼 구성에서는 빼기)
  bool get rsyncOnly => this == toRight || this == toLeft || this == both || this == monitor;

  /// 파일 탐색기에서 고를 수 있는 버튼
  static List<ExplorerButton> get explorerValues => [for (final b in values) if (!b.rsyncOnly) b];

  /// Rsync 화면의 버튼 (늘 이대로, 두 창 사이)
  static const rsyncButtons = [up, refresh, newFolder, toRight, toLeft, both, monitor];

  static List<ExplorerButton> fromSettings(List<String> names) {
    final out = [
      for (final n in names)
        for (final b in explorerValues)
          if (b.name == n) b,
    ];
    return out.isEmpty ? explorerValues : out;
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

  /// 이 기기의 저장 장치: (경로, 이름)
  List<(String, String)> _local = [];

  /// 165: 드라이브마다 따로 뒤에서 확인 (Windows). null = 확인 중, true = 열 수 있음, false = 연결 안 됨
  final Map<String, bool?> _driveOk = {};
  final Set<String> _networkDrives = {};

  /// 꺼내는 장치 · CD (카드 리더 · USB): 열 수 없으면 "비어 있음" (연결 안 됨이 아니라 매체가 없는 것)
  final Set<String> _removableDrives = {};

  Future<void> _probeDrive(String path) async {
    if (mounted) setState(() => _driveOk[path] = null);
    bool ok;
    try {
      ok = await ExplorerPage.probeDrive(path);
    } catch (_) {
      ok = false;
    }
    if (mounted) setState(() => _driveOk[path] = ok);
  }

  /// 연결 안 된 드라이브를 누르면 다시 연결 (다시 읽기) - 되면 연다
  Future<void> _reconnect(_Pane pane, String path) async {
    await _probeDrive(path);
    if (!mounted) return;
    if (_driveOk[path] == true) {
      pane.cache.remove(path);
      await _goTo(pane, path);
    } else {
      _snack(_removableDrives.contains(path)
          ? trf('{0} 이 비어 있습니다 (카드 · USB · 디스크를 넣은 뒤 다시 누르세요).', [path])
          : trf('{0} 에 연결할 수 없습니다. 네트워크 · NAS 가 켜져 있는지 확인하세요.', [path]));
    }
  }

  /// 저장 장치 + WebDAV 서버 (환경 설정 > 파일 탐색기 > WebDAV): (경로, 이름)
  List<(String, String)> get _volumes => [
        ..._local,
        for (final s in c.settings.webdavServers) ('$davScheme${s.id}/', s.label),
      ];
  late final List<_Pane> _panes = [_Pane(''), _Pane('')];
  int _active = 0;
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    if (widget.rsync) {
      ExplorerPage._openRsync++;
    } else {
      ExplorerPage._open++;
    }
    for (final pane in _panes) {
      pane.addListener(_onPane);
    }
    _init();
  }

  @override
  void dispose() {
    if (widget.rsync) {
      ExplorerPage._openRsync--;
    } else {
      ExplorerPage._open--;
    }
    for (final pane in _panes) {
      pane.dispose();
    }
    if (_allFiles != null) _life.dispose();
    super.dispose();
  }

  void _onPane() {
    if (mounted) setState(() {});
  }

  Future<void> _init() async {
    _local = await _loadVolumes();
    if (_local.isEmpty) _local = [(Platform.isWindows ? r'C:\' : '/', Platform.isWindows ? 'C:' : '/')];
    if (Platform.isAndroid) unawaited(_checkAccess());
    final saved = widget.rsync ? c.settings.rsyncPaths : c.settings.explorerPaths;
    // 창마다 따로 읽는다: 한 창이 WebDAV 서버를 기다려도 다른 창 (이 기기 파일) 은 바로 보이게
    // 165: 지난 폴더가 느린 네트워크 드라이브여도 화면이 멈추지 않게 (뒤에서 확인, 오래 걸리면 그냥 열어 본다 - 못 읽으면 그 창에 이유)
    final reach = await Future.wait(
        [for (var i = 0; i < 2; i++) i < saved.length ? _reachableAsync(saved[i]) : Future.value(false)]);
    final wants = [
      for (var i = 0; i < 2; i++) reach[i] ? saved[i] : _local[0].$1,
    ];
    for (var i = 0; i < 2; i++) {
      _panes[i]
        ..root = _volumeOf(wants[i])
        ..current = wants[i]
        // 48 보충 (관리자): 처음 열면 아무것도 고르지 않은 상태 - 열자마자 폴더 통째가 복사 · 이동 대상이 되지 않게
        ..focused = null;
    }
    if (!mounted) return;
    setState(() => _ready = true);
    // 52: 다른 화면에 다녀와도 아직 도는 복사 · 이동의 진행 막대를 다시 보이고, 끝나면 그 폴더들을 새로 읽는다
    final center = CopyCenter.peekOf(c);
    if (center != null) {
      for (final job in center.jobs.values.where((j) => !j.finished)) {
        _adoptJob(job);
      }
    }
    // 165: 드라이브 종류 · 연결은 드라이브마다 따로 뒤에서 (느린 드라이브가 있어도 다른 드라이브 · 창은 바로)
    if (Platform.isWindows) {
      for (final (path, _) in _local) {
        final type = driveType(path);
        if (type == 4) _networkDrives.add(path);
        if (type == 2 || type == 5) _removableDrives.add(path);
        unawaited(_probeDrive(path));
      }
    }
    for (var i = 0; i < 2; i++) {
      final pane = _panes[i];
      unawaited(_goTo(pane, wants[i], remember: false).then((_) => _reveal(pane, pane.current)));
    }
  }

  // ───────── 권한 (Android) ─────────

  /// "모든 파일에 대한 접근" 권한 (없으면 폴더만 보이고 파일은 안 보인다). null = 아직 모름
  bool? _allFiles;

  /// 듀얼 앱 (복제한 앱) 인지: 저장소가 /storage/emulated/0 이 아님
  bool _dualApp = false;

  late final AppLifecycleListener _life = AppLifecycleListener(onResume: () {
    if (Platform.isAndroid && _allFiles == false) unawaited(_checkAccess(reload: true));
  });

  Future<void> _checkAccess({bool reload = false}) async {
    _life; // 다시 돌아오면 (권한 화면에서 허용하고 오면) 다시 확인
    final ok = await AndroidAccess.hasAllFiles();
    var dual = false;
    try {
      final root = await AndroidAccess.storageRoot();
      dual = root.contains('/emulated/') && !root.endsWith('/emulated/0');
    } catch (_) {}
    if (!mounted) return;
    final changed = ok != _allFiles;
    setState(() {
      _allFiles = ok;
      _dualApp = dual;
    });
    if (reload && changed && ok) {
      for (final pane in _panes) {
        pane.cache.clear();
        for (final d in pane.expanded.toList()) {
          await _load(pane, d, force: true);
        }
      }
    }
  }

  /// 권한이 없을 때 목록 위 안내 (이유 · 할 일 · 허용 화면 열기 · 다시 확인)
  Widget? _accessNotice(_Pane pane) {
    if (!Platform.isAndroid || _allFiles != false || isDav(pane.root)) return null;
    return _notice(
      icon: Icons.lock_outline,
      title: tr('파일이 보이지 않습니다: "모든 파일에 대한 접근" 권한이 없습니다'),
      body: _dualApp
          ? tr('지금은 듀얼 앱 (복제한 앱) 입니다. Android 가 듀얼 앱에는 이 권한을 주지 않을 수 있습니다. '
              '허용 화면에서 켤 수 없으면 배지 없는 원래 JJ_MKVMaker 아이콘으로 여세요.')
          : tr('폴더는 보여도 그 안의 동영상 · 파일은 이 권한이 있어야 보입니다. 허용 화면에서 JJ_MKVMaker 를 켜고 돌아오세요.'),
      actions: [
        FilledButton.tonal(onPressed: AndroidAccess.request, child: Text(tr('권한 허용 화면 열기'))),
        TextButton(onPressed: () => _checkAccess(reload: true), child: Text(tr('허용했으면 다시 확인'))),
      ],
    );
  }

  /// 목록 위 안내들 (없으면 null). 좁은 화면 (접은 폴드 · 두 창) 에서 목록이 밀려 사라지지 않게 높이를 제한한다
  Widget? _noticeArea(List<Widget?> notices, double paneHeight) {
    final list = notices.whereType<Widget>().toList();
    if (list.isEmpty) return null;
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: paneHeight.isFinite ? paneHeight * 0.35 : 240),
      child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: list)),
    );
  }

  /// 목록 위 안내 상자
  Widget _notice(
          {required IconData icon,
          required String title,
          required String body,
          required List<Widget> actions,
          Color color = Colors.redAccent}) =>
      Container(
        width: double.infinity,
        margin: const EdgeInsets.fromLTRB(6, 6, 6, 0),
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: color.withValues(alpha: 0.5)),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(icon, size: 18, color: color),
            const SizedBox(width: 8),
            Expanded(child: Text(title, style: const TextStyle(fontWeight: FontWeight.w600))),
          ]),
          const SizedBox(height: 4),
          Text(body, style: const TextStyle(fontSize: 12, color: JjColors.textDim)),
          Wrap(spacing: 8, children: actions),
        ]),
      );

  // ───────── 만들다 만 파일 (71) ─────────

  /// 복사 · 동기화가 중간에 끊겨 남은 임시 파일 (.jjpart · .jjsync). 지금 쓰는 중인 것 (2분 안에 바뀜) 은 빼고
  List<FileEntry> _partials(_Pane pane, String dir) {
    final old = DateTime.now().subtract(const Duration(minutes: 2));
    return [
      for (final e in pane.cache[dir] ?? const <FileEntry>[])
        if (!e.isDir && isPartialFile(e.name) && e.modified.isBefore(old)) e,
    ];
  }

  Widget? _partialNotice(_Pane pane, String dir) {
    final list = _partials(pane, dir);
    if (list.isEmpty) return null;
    return _notice(
      icon: Icons.broken_image_outlined,
      color: Colors.orangeAccent,
      title: trf('만들다 만 파일 {0}개', [list.length]),
      body: tr('복사 · 동기화가 중간에 끊겨 남은 임시 파일입니다 (.jjpart). 완성된 파일이 아니므로 지워도 됩니다. '
          '같은 파일을 다시 복사하면 새로 만듭니다.'),
      actions: [
        TextButton(
          onPressed: () async {
            final ok = await showDialog<bool>(
              context: context,
              builder: (ctx) => AlertDialog(
                scrollable: true,
                title: Text(trf('만들다 만 파일 {0}개를 지울까요?', [list.length])),
                content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                  for (final e in list.take(50)) Text(e.name, style: const TextStyle(fontSize: 12)),
                  if (list.length > 50) Text(trf('… 외 {0}개', [list.length - 50])),
                ]),
                actions: [
                  TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('취소'))),
                  FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr('지우기'))),
                ],
              ),
            );
            if (ok != true) return;
            final failed = <String>[];
            for (final e in list) {
              try {
                await vDelete(e.path);
              } catch (_) {
                failed.add(e.name);
              }
            }
            // 같은 폴더를 보는 다른 창도 새로
            for (final q in _panes) {
              if (q == pane || q.cache.containsKey(dir)) await _load(q, dir, force: true);
            }
            if (failed.isNotEmpty) _snack(trf('지우지 못한 파일: {0}', [failed.join(', ')]));
          },
          child: Text(tr('지우기')),
        ),
      ],
    );
  }

  // ───────── 읽을 수 없을 때 (12) ─────────

  /// 오류 → (무엇이 문제인지, 무엇을 하면 되는지)
  Widget? _errorNotice(_Pane pane, String dir) {
    final err = pane.errors[dir] ?? pane.errors[pane.root];
    if (err == null) return null;
    final where = pane.errors[dir] != null ? dir : pane.root;
    final dav = isDav(where);
    final server = dav ? DavRegistry.server(DavPath.parse(where).server) : null;
    final (title, body) = explainFileError(err, dav: dav, noPassword: server != null && server.password.isEmpty);
    final locked = isLockedError(err);
    return _notice(
      icon: dav ? Icons.cloud_off_outlined : Icons.error_outline,
      title: '${_displayPath(where)}: $title',
      body: body,
      actions: [
        FilledButton.tonal(
          onPressed: () async {
            // 133: 마스터를 취소해 막혔으면 여기서 다시 묻는다
            if (locked && !await SecretGate.pass(force: true)) return;
            pane.errors.remove(where);
            pane.changed();
            await _load(pane, where, force: true);
            for (final d in pane.expanded.toList()) {
              if (isSameOrInside(d, where) && d != where) await _load(pane, d, force: true);
            }
          },
          child: Text(locked ? tr('마스터 비밀번호 넣기') : tr('다시 시도')),
        ),
        if (dav && !locked) TextButton(onPressed: () => _editDav(pane, pane.root), child: Text(tr('서버 설정 고치기'))),
      ],
    );
  }

  /// 화면에 보일 경로 (5 · 14): Android 는 "SD 카드 › JJ_sdtest › jj_mkv", WebDAV 는 "☁ 서버 › 폴더", Windows 는 그대로
  String _displayPath(String path) {
    if (isDav(path)) {
      final d = DavPath.parse(path);
      final label = DavRegistry.server(d.server)?.label ?? 'WebDAV';
      return ['☁ $label', ...d.rel.split('/').where((s) => s.isNotEmpty)].join(' › ');
    }
    if (!Platform.isAndroid) return path;
    String? best;
    var label = '';
    for (final (v, l) in _local) {
      if ((samePath(v, path) || p.isWithin(v, path)) && (best == null || v.length > best.length)) {
        best = v;
        label = l;
      }
    }
    if (best == null) return path;
    final rest = p.relative(path, from: best);
    return [label, if (rest != '.') ...p.split(rest)].join(' › ');
  }

  Future<List<(String, String)>> _loadVolumes() async {
    if (ExplorerPage.debugVolumes case final f?) return f();
    if (Platform.isWindows) return windowsDrives();
    if (Platform.isAndroid) {
      final v = await AndroidAccess.volumes();
      return [for (final x in v) (x.$1, x.$2.isEmpty ? p.basename(x.$1) : x.$2)];
    }
    return [('/', '/')];
  }

  /// 설정에서 지운 WebDAV 서버를 보던 창은 이 기기의 첫 저장 장치로
  void _dropRemovedServers() {
    if (!_ready) return;
    for (final pane in _panes) {
      if (isDav(pane.root) && DavRegistry.server(DavPath.parse(pane.root).server) == null) {
        pane.marked.clear();
        pane.cache.removeWhere((k, _) => isDav(k));
        pane.expanded.removeWhere(isDav);
        pane.root = _local.first.$1; // 다시 그릴 때 또 하지 않게
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _goTo(pane, _local.first.$1);
        });
      }
    }
  }

  /// 다시 열 수 있는 폴더: 로컬은 있으면, WebDAV 는 그 서버가 아직 설정에 있으면 (열 때 확인)
  bool _reachable(String path) => isDav(path)
      ? DavRegistry.server(DavPath.parse(path).server) != null
      : Directory(path).existsSync();

  /// [_reachable] 을 화면을 멈추지 않고 (2초 넘게 걸리면 있다고 보고 열어 본다)
  Future<bool> _reachableAsync(String path) async {
    if (isDav(path)) return _reachable(path);
    try {
      return await Directory(path).exists().timeout(const Duration(seconds: 2), onTimeout: () => true);
    } catch (_) {
      return false;
    }
  }

  String _volumeOf(String path) {
    if (isDav(path)) return '$davScheme${DavPath.parse(path).server}/';
    // 37: Windows 네트워크 공유 (\\NAS\공유) 는 그 공유가 맨 위
    if (Platform.isWindows && path.startsWith(r'\\')) return uncRoot(path);
    String best = _local.first.$1;
    var len = -1;
    for (final (v, _) in _local) {
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
  /// [fresh]: 경로 입력 · 찾기 · 내역으로 갈 때 - 그 폴더를 새로 읽는다 (앱 밖에서 바뀐 것까지 보이게, 122)
  /// 폴더로 간다. 그 폴더를 "고른 항목" 으로 잡지 않는다 (48 보충 · 관리자: 누르거나 표시하지 않은 폴더가 복사 · 이동 대상이 되지 않게).
  /// 위치는 지금 폴더 표시 · 스크롤로 보인다. [focus] 는 그 폴더를 일부러 고를 때만
  Future<void> _goTo(_Pane pane, String dir, {bool remember = true, bool fresh = false, bool focus = false}) async {
    // 124 · 128: 사용자가 WebDAV 로 간 것이면 마스터 창을 한 번 취소했어도 다시 묻는다 (켤 때 되살리는 것은 [remember] 없음)
    if (remember && isDav(dir)) await SecretGate.pass(force: true);
    if (!mounted) return;
    pane.root = _volumeOf(dir);
    final chain = <String>[];
    dir = isDav(dir) ? vNorm(dir) : p.normalize(dir);
    var d = dir;
    while (true) {
      chain.insert(0, d);
      if (samePath(d, pane.root) || vDirname(d) == d) break;
      d = vDirname(d);
    }
    for (final (k, x) in chain.indexed) {
      pane.expanded.add(x);
      await _load(pane, x, force: fresh && k == chain.length - 1);
      // 122: 읽어 둔 목록에 다음 폴더가 없으면 (앱 밖에서 새로 만듦) 새로 읽어야 그 폴더까지 펼쳐진다
      if (k < chain.length - 1 && !(pane.cache[x] ?? const <FileEntry>[]).any((e) => samePath(e.path, chain[k + 1]))) {
        await _load(pane, x, force: true);
      }
    }
    pane.current = dir;
    if (focus) pane.focused = dir;
    pane.changed();
    if (pane.listScroll.hasClients) pane.listScroll.jumpTo(0);
    _reveal(pane, dir);
    if (remember) _remember(pane, dir);
  }

  /// 그 항목이 목록 위쪽 1/4 쯤에 보이게 스크롤 (깊은 폴더로 가면 위쪽 폴더들의 다른 항목에 밀려 안 보이므로)
  void _reveal(_Pane pane, String path) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !pane.scroll.hasClients) return;
      // 화면의 트리와 같은 줄로 센다 (폴더 + 파일 목록 배치 · Rsync 화면은 폴더만)
      final i = _rows(pane, foldersOnly: _split || widget.rsync).indexWhere((r) => samePath(r.entry.path, path));
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
    if (widget.rsync) {
      unawaited(c.updateSettings((s) => s.rsyncPaths = paths));
    } else {
      final hist = [dir, ...c.settings.explorerHistory.where((h) => !samePath(h, dir))].take(30).toList();
      unawaited(c.updateSettings((s) => s
        ..explorerPaths = paths
        ..explorerHistory = hist));
    }
    if (i >= 0) _active = i;
  }

  /// 지금 모양 (환경 설정 > 파일 탐색기 > 스타일)
  ExplorerStyle get _look => ExplorerStyle.of(c.settings.explorerStyle);

  /// 왼쪽 폴더 트리 + 오른쪽 파일 목록 배치
  bool get _split => !widget.rsync && c.settings.explorerLayout == 'split';

  /// 좌우 두 창 (Rsync 화면은 늘)
  bool get _dual =>
      widget.rsync ||
      c.settings.explorerLayout == 'dual' ||
      // 자동: 넓으면 두 창, 좁은 화면 (폰 세로) 은 한 창 - 같은 목록이 반씩 잘려 두 번 보이지 않게
      (c.settings.explorerLayout == 'auto' && !isCompact(context));

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
    if (widget.rsync) {
      await _pick(pane, e);
      return;
    }
    if (!row.isRoot && (_selecting || HardwareKeyboard.instance.isControlPressed)) {
      if (!_selecting) setState(() => _selecting = true);
      await _toggleMark(pane, e);
      return;
    }
    if (e.isDir || !_selectMode) return _onOpen(pane, row, list: list);
    pane.focused = e.path;
    if (!list) pane.current = vDirname(e.path);
    pane.changed();
  }

  /// 표시되었는지: 자기 자신, 또는 위 폴더가 표시되었으면 (폴더를 고르면 안의 것도 모두 고른 것).
  /// Rsync 화면은 고른 그 폴더만.
  bool _isMarked(_Pane pane, String path) =>
      pane.marked.any((m) => widget.rsync ? samePath(path, m) : isSameOrInside(path, m));

  /// Rsync 화면: 창마다 폴더 하나만 고른다 (다시 누르면 취소). 고르면 펼쳐서 안의 폴더가 보이게.
  Future<void> _pick(_Pane pane, FileEntry e) async {
    if (!e.isDir) return;
    if (pane.marked.length == 1 && samePath(pane.marked.first, e.path)) {
      setState(pane.marked.clear);
      return;
    }
    setState(() => pane.marked
      ..clear()
      ..add(e.path));
    if (!pane.expanded.contains(e.path)) {
      await _toggle(pane, e);
    } else {
      pane
        ..current = e.path
        ..focused = e.path
        ..changed();
    }
  }

  /// 다른 표시 안에 든 표시는 뺀다 (폴더 하나로 안의 것까지 고른 것이므로)
  void _normalizeMarks(_Pane pane) {
    final all = pane.marked.toList();
    pane.marked.removeWhere((m) => all.any((o) => !identical(o, m) && !samePath(o, m) && isSameOrInside(m, o)));
  }

  /// 선택 모드에서 누르기. 폴더는 자기 자신과 안의 파일 · 폴더 전체가 한 묶음이다.
  /// - 고르지 않은 것을 누르면 고른다 (폴더는 펼쳐서 안의 것도 모두 고른 모양으로 보여 줌)
  /// - 고른 것을 다시 누르면 자기 자신과 안의 것을 모두 푼다.
  ///   위 폴더를 골라서 함께 골라진 것이면 그것만 빼고, 같은 폴더의 나머지는 고른 채로 둔다.
  Future<void> _toggleMark(_Pane pane, FileEntry e) async {
    pane.focused = e.path;
    if (!_isMarked(pane, e.path)) {
      setState(() {
        pane.marked.removeWhere((m) => isSameOrInside(m, e.path)); // 안에 따로 고른 것은 이 폴더 하나로
        pane.marked.add(e.path);
      });
      if (e.isDir) {
        await _load(pane, e.path);
        setState(() => pane.expanded.add(e.path));
      }
      return;
    }
    final owner = pane.marked.firstWhere((m) => isSameOrInside(e.path, m));
    setState(() => pane.marked.removeWhere((m) => isSameOrInside(m, e.path)));
    if (samePath(owner, e.path)) return;
    // 위 폴더 [owner] 를 골라 둔 상태: owner 표시를 풀고, e 까지 내려가는 길의 다른 항목은 고른 채로
    final keep = <String>[];
    var dir = owner;
    while (!samePath(dir, e.path)) {
      await _load(pane, dir);
      String? next;
      for (final x in pane.cache[dir] ?? const <FileEntry>[]) {
        if (isSameOrInside(e.path, x.path)) {
          next = x.path;
        } else {
          keep.add(x.path);
        }
      }
      if (next == null) break;
      dir = next;
    }
    setState(() {
      pane.marked.remove(owner);
      pane.marked.addAll(keep);
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
    if (!list) pane.current = vDirname(e.path);
    pane.changed();
    await _open(e.path, pane: pane);
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

  /// 다른 앱으로 열지 못했을 때: 음악 · 동영상이면 내장 플레이어를 알려 준다 (29)
  String _noAppMessage(String path) => isAudioFile(path) || isVideoFile(path)
      ? tr('이 형식을 여는 앱이 없습니다. 길게 누르거나 오른쪽 클릭 → [내장 플레이어로 재생] 으로 들어 보세요.')
      : tr('이 파일을 열 수 있는 앱이 없습니다.');

  /// 파일 열기 (기본 동작): 동영상은 내장 플레이어 (또는 확장자별 프로그램), 그 밖은 기본 연결 프로그램
  Future<void> _open(String path, {_Pane? pane}) async {
    if (isVideoFile(path)) {
      await _play([path]);
      return;
    }
    // 이미지 · PDF · ZIP 보기 (컴포넌트를 켰을 때)
    if (c.settings.components.contains('viewer')) {
      final ext = extOf(path);
      if (c.settings.imageExts.contains(ext)) return _viewImages(path, pane);
      if (ext == 'pdf') return _viewPdf(path);
      if (zipExtensions.contains(ext)) return _openZip(path, pane);
    }
    // 문서 미리보기 (Windows: 설치한 변환기로 PDF 로 바꿔 봄)
    if (c.settings.components.contains('docs') && Platform.isWindows &&
        AppComponent.docExtensions.contains(extOf(path))) {
      return _viewDoc(path);
    }
    final local = await _fetch(path);
    if (local == null) return;
    final ok = await c.services.shell.openWith(local);
    if (!ok) _snack(_noAppMessage(path));
  }

  /// WebDAV 파일은 열거나 재생하려면 임시 폴더로 받는다 (dav_external.dart)
  Future<String?> _fetch(String path) => fetchDav(context, c, path);

  /// 동영상 재생 (WebDAV 는 받지 않고 바로 스트리밍)
  Future<void> _play(List<String> paths, {bool internal = false, bool keepOrder = false}) async {
    if (!mounted || paths.isEmpty) return;
    await playFiles(context, c, paths, internal: internal, keepOrder: keepOrder);
  }

  /// 그림 보기: 같은 폴더의 그림을 지금 정렬 순서대로 넘겨 본다
  Future<void> _viewImages(String path, _Pane? pane) async {
    final dir = vDirname(path);
    final list = pane?.cache[dir] ?? _sorted(await listEntries(dir, showHidden: c.settings.explorerShowHidden));
    final images = [
      for (final e in list)
        if (!e.isDir && c.settings.imageExts.contains(extOf(e.path))) e.path,
    ];
    if (!images.any((x) => samePath(x, path))) images.insert(0, path);
    final start = images.indexWhere((x) => samePath(x, path));
    final temp = await c.services.storage.tempDirectory();
    if (!mounted) return;
    await openReader(context, c, ImageFilesSource(images, tempDir: temp, title: vBasename(dir)), start: start);
  }

  /// 문서 → PDF (진행 창) → 보기
  Future<void> _viewDoc(String path) async {
    final temp = await c.services.storage.tempDirectory();
    if (!mounted) return;
    final dialog = showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        content: Row(children: [
          const CircularProgressIndicator(),
          const SizedBox(width: 16),
          Expanded(child: Text(trf('PDF 로 바꾸는 중: {0}', [vBasename(path)]))),
        ]),
      ),
    );
    String? pdf;
    Object? error;
    try {
      final local = await vLocalCopy(path, temp);
      pdf = await ComponentStore.shared.convertToPdf(local, p.join(temp, 'jj_docs'));
    } catch (e) {
      error = e;
    }
    if (mounted) Navigator.of(context).pop();
    await dialog;
    if (pdf == null) {
      _snack(trf('미리 볼 수 없습니다: {0}', [error]));
      return;
    }
    PdfSource src;
    try {
      src = await PdfSource.open(pdf, tempDir: temp);
    } catch (e) {
      _snack(trf('PDF 를 열 수 없습니다: {0}', [e]));
      return;
    }
    if (!mounted) return;
    await openReader(context, c, src);
  }

  Future<void> _viewPdf(String path) async {
    final temp = await c.services.storage.tempDirectory();
    PdfSource src;
    try {
      src = await PdfSource.open(path, tempDir: temp);
    } catch (e) {
      _snack(trf('PDF 를 열 수 없습니다: {0}', [e]));
      return;
    }
    if (!mounted) return;
    await openReader(context, c, src);
    await _refreshAll([vDirname(path)]);
  }

  /// ZIP: 환경 설정이 "만화 보기" 면 안의 그림을 바로 보고 (그림이 없으면 목록), 아니면 목록
  Future<void> _openZip(String path, _Pane? pane) async {
    try {
      if (c.settings.zipComic && await openZipComic(context, c, path)) return;
    } catch (e) {
      _snack(trf('열 수 없습니다: {0}', [e]));
      return;
    }
    if (!mounted) return;
    final other = pane == null || !_dual ? null : _panes[1 - _panes.indexOf(pane)].current;
    final out = await openZip(context, c, path, otherDir: other);
    if (out != null) await _refreshAll([out, vDirname(out)]);
  }

  /// 고른 그림들을 한 장씩 PDF 로 (같은 폴더에, 이름을 묻는다)
  Future<void> _imagesToPdf(List<String> images) async {
    if (images.isEmpty) return;
    final dir = vDirname(images.first);
    final first = vBasename(images.first);
    final name = await _askName(tr('PDF 로 만들기'), '${first.contains('.') ? first.substring(0, first.lastIndexOf('.')) : first}.pdf');
    if (name == null || name.trim().isEmpty) return;
    final out = vJoin(dir, name.toLowerCase().endsWith('.pdf') ? name : '$name.pdf');
    final temp = await c.services.storage.tempDirectory();
    try {
      await imagesToPdf(images, out, tempDir: temp);
      _snack(trf('그림 {0}장으로 PDF 를 만들었습니다: {1}', [images.length, vBasename(out)]));
    } catch (e) {
      _snack(trf('PDF 를 만들지 못했습니다: {0}', [e]));
    }
    await _refreshAll([dir]);
  }

  Future<void> _menu(_Pane pane, FileEntry e, Offset at) async {
    setState(() => _active = _panes.indexOf(pane));
    pane.focused = e.path;
    pane.changed();
    final video = !e.isDir && isVideoFile(e.path);
    final audio = !e.isDir && isAudioFile(e.path);
    final dav = isDav(e.path);
    // 그림 → PDF: 표시한 것 중 그림 (누른 것이 표시에 없으면 누른 것만)
    final viewer = c.settings.components.contains('viewer');
    final picked = pane.marked.contains(e.path) ? pane.marked.toList() : [e.path];
    final images = [for (final x in picked) if (c.settings.imageExts.contains(extOf(x))) x];
    final ext = extOf(e.path);
    final viewable = viewer && !e.isDir &&
        (c.settings.imageExts.contains(ext) || ext == 'pdf' || zipExtensions.contains(ext));
    final dual = _dual;
    // 25: Rsync 화면은 폴더만 보이므로 폴더에 맞는 것만 (고르기 · 열기 · 이름 변경 · 삭제 · 정보)
    final items = widget.rsync
        ? <(String, IconData, String)>[
            ('pickRsync', Icons.check_circle_outline,
                _isMarked(pane, e.path) ? tr('고르기 취소') : tr('rsync 에 고르기')),
            ('open', Icons.folder_open, tr('열기')),
            ('openOther', Icons.vertical_split_outlined, tr('다른 창에서 열기')),
            ('rename', Icons.drive_file_rename_outline, tr('이름 변경')),
            ('delete', Icons.delete_outline, tr('삭제')),
            if (!dav) ('reveal', Icons.folder_outlined, tr('파일 관리자에서 보기')),
            ('info', Icons.info_outline, tr('정보')),
          ]
        : <(String, IconData, String)>[
      if (e.isDir) ('open', Icons.folder_open, tr('열기')),
      if (e.isDir && dual) ('openOther', Icons.vertical_split_outlined, tr('다른 창에서 열기')),
      if (e.isDir) ('playFolder', Icons.play_circle_outline, tr('이 폴더의 동영상 재생')),
      if (video || audio) ('playInternal', Icons.play_circle_outline, tr('내장 플레이어로 재생')),
      if (viewable) ('view', Icons.visibility_outlined, tr('보기')),
      if (!e.isDir) ('openWith', Icons.open_in_new, tr('다른 앱으로 열기')),
      if (!e.isDir && !video) ('openDefault', Icons.launch, tr('기본 앱으로 열기')),
      if (video && !dav) ('addMkv', Icons.playlist_add, tr('MKV 목록에 추가')),
      if (viewer && images.isNotEmpty)
        ('toPdf', Icons.picture_as_pdf_outlined,
            images.length == 1 ? tr('PDF 로 만들기') : trf('그림 {0}장을 PDF 로 만들기', [images.length])),
      ('select', Icons.check_circle_outline, tr('선택')),
      ('rename', Icons.drive_file_rename_outline, tr('이름 변경')),
      if (dual) ('copy', Icons.copy_outlined, tr('다른 창으로 복사')),
      if (dual) ('move', Icons.drive_file_move_outline, tr('다른 창으로 이동')),
      // 어느 배치에서나: 담아 두었다가 원하는 폴더에서 붙여넣기
      ('clipCopy', Icons.content_copy, dual ? tr('복사 (붙여넣기로)') : tr('복사')),
      ('clipMove', Icons.content_cut, dual ? tr('이동 (붙여넣기로)') : tr('이동')),
      if (_clip.isNotEmpty)
        ('paste', Icons.content_paste, trf('{0} 에 붙여넣기 ({1}개)', [vBasename(e.isDir ? e.path : vDirname(e.path)), _clip.length])),
      ('delete', Icons.delete_outline, tr('삭제')),
      if (!dav && (!Platform.isAndroid || e.isDir)) ('reveal', Icons.folder_outlined, tr('파일 관리자에서 보기')),
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
            child: Row(children: [
              Icon(icon, size: 18),
              const SizedBox(width: 12),
              Flexible(child: Text(label, overflow: TextOverflow.ellipsis)),
            ]),
          ),
      ],
    );
    if (pick == null || !mounted) return;
    switch (pick) {
      case 'pickRsync':
        await _pick(pane, e);
      case 'open':
        await _goTo(pane, e.path);
      case 'openOther':
        final other = _panes[1 - _panes.indexOf(pane)];
        await _goTo(other, e.path);
        setState(() => _active = _panes.indexOf(other));
      case 'playFolder':
        await _playFolder(e.path);
      case 'playInternal':
        await _play([e.path], internal: true);
      case 'openWith':
        final local = await _fetch(e.path);
        if (local != null && !await c.services.shell.openWith(local, choose: true)) _snack(_noAppMessage(e.path));
      case 'openDefault':
        final local = await _fetch(e.path);
        if (local != null && !await c.services.shell.openWith(local)) _snack(_noAppMessage(e.path));
      case 'addMkv':
        await _addMkv([e.path]);
      case 'select':
        setState(() => _selecting = true);
        if (!_isMarked(pane, e.path)) await _toggleMark(pane, e);
      case 'rename':
        await _rename(pane, e.path);
      case 'copy':
        await _transfer(pane, _isMarked(pane, e.path) ? pane.marked.toList() : [e.path], move: false);
      case 'move':
        await _transfer(pane, _isMarked(pane, e.path) ? pane.marked.toList() : [e.path], move: true);
      case 'clipCopy':
        _toClipboard(_isMarked(pane, e.path) ? pane.marked.toList() : [e.path], move: false);
      case 'clipMove':
        _toClipboard(_isMarked(pane, e.path) ? pane.marked.toList() : [e.path], move: true);
      case 'paste':
        await _paste(pane, e.isDir ? e.path : vDirname(e.path));
      case 'delete':
        await _delete(pane, [e.path]);
      case 'view':
        await _open(e.path, pane: pane);
      case 'toPdf':
        await _imagesToPdf(images);
      case 'reveal':
        await c.services.shell.revealFile(e.path);
      case 'info':
        await _info(e);
    }
  }

  // ───────── 기능 ─────────

  _Pane get _pane => _panes[_active];
  _Pane? get _other => _dual ? _panes[1 - _active] : null;

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
        final up = vDirname(pane.current);
        pane.expanded.remove(pane.current);
        await _goTo(pane, up);
      case ExplorerButton.select:
        _setSelecting(!_selecting);
      case ExplorerButton.monitor:
        await MonitorPage.open(context, c);
      case ExplorerButton.toRight:
        await _runRsync(right: true, left: false);
      case ExplorerButton.toLeft:
        await _runRsync(right: false, left: true);
      case ExplorerButton.both:
        await _runRsync(right: true, left: true);
      case ExplorerButton.refresh:
        pane.cache.clear();
        for (final d in pane.expanded.toList()) {
          await _load(pane, d, force: true);
        }
      case ExplorerButton.play:
        final t = _targets(pane);
        final videos = t.where((x) => !vIsDirSync(x) && isVideoFile(x)).toList();
        if (videos.isNotEmpty) {
          await _play(videos, keepOrder: pane.marked.isNotEmpty);
        } else {
          await _playFolder(t.length == 1 && vIsDirSync(t.first) ? t.first : pane.current);
        }
      case ExplorerButton.addMkv:
        final t = _targets(pane);
        await _addMkv(t.isEmpty ? [pane.current] : t);
      case ExplorerButton.newFolder:
        final name = await _askName(tr('새 폴더'), '');
        if (name == null) return;
        try {
          final parent = pane.current;
          final made = await FileOps.makeFolder(parent, name);
          // 만든 폴더가 트리에 보이게: 부모를 펼치고 다시 읽은 뒤 그 줄까지 스크롤
          pane.expanded.add(parent);
          await _load(pane, parent, force: true);
          await _refreshAll([parent]);
          // Rsync 화면: 만든 폴더를 이 창의 원본 · 대상으로 바로 고른다
          if (widget.rsync) {
            pane.marked
              ..clear()
              ..add(made);
          }
          pane.focused = made;
          pane.changed();
          _reveal(pane, made);
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
      case ExplorerButton.orient:
        await _toggleOrientation();
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
    await _play(list);
  }

  Future<void> _addMkv(List<String> paths) async {
    if (paths.any(isDav)) {
      _snack(tr('WebDAV 의 동영상은 MKV 목록에 넣을 수 없습니다. 먼저 이 기기로 복사하세요.'));
      return;
    }
    final videos = <String>[];
    for (final x in paths) {
      if (vIsDirSync(x)) {
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
    final name = await _askName(tr('이름 변경'), vBasename(path));
    if (name == null || name == vBasename(path)) return;
    try {
      final now = await FileOps.rename(path, name);
      await _refreshAll([vDirname(path)]);
      for (final x in _panes) {
        if (x.marked.remove(path)) x.marked.add(now);
      }
      pane.focused = now;
      pane.changed();
    } catch (e) {
      _snack(trf('이름을 바꿀 수 없습니다: {0}', [e]));
    }
  }

  /// Shift+Delete 로 불렀는지 (휴지통을 거치지 않고 지우기를 미리 골라 둔다 - 65)
  bool _shiftDelete = false;

  /// 지우기. Windows 의 로컬 파일은 기본으로 휴지통으로 (창에서 "영구 삭제" 를 고르거나 Shift+Delete).
  /// WebDAV · Android 는 휴지통이 없어 바로 지운다. 여러 개면 실패해도 나머지를 계속하고, 못 지운 것을 알린다 (65).
  Future<void> _delete(_Pane pane, List<String> paths) async {
    final shift = _shiftDelete;
    _shiftDelete = false;
    if (paths.isEmpty) {
      _snack(tr('지울 항목을 고르세요 (누르거나 오른쪽 동그라미로 표시).'));
      return;
    }
    // 휴지통이 있는 곳: Windows 의 고정 디스크 (94: 네트워크 드라이브 · \\NAS · USB 메모리는 휴지통이 없어 처음부터 영구 삭제로 묻는다)
    final local = Platform.isWindows && paths.every((x) => !isDav(x));
    final canRecycle = local && c.settings.recycleOnDelete && paths.every(hasRecycleBin);
    var permanent = !canRecycle || shift;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => AlertDialog(
          scrollable: true,
          title: Text(permanent ? tr('영구 삭제') : tr('휴지통으로 보내기')),
          // 무엇을 지우는지 늘 보여 준다 (여러 개면 앞의 8개 이름 · 폴더)
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(paths.length == 1
                ? '${permanent ? trf('"{0}" 을(를) 지울까요? 되돌릴 수 없습니다.', [vBasename(paths.first)]) : trf('"{0}" 을(를) 휴지통으로 보낼까요?', [vBasename(paths.first)])}'
                    '\n${vDirname(paths.first)}'
                : [
                    permanent
                        ? trf('{0}개 항목을 지울까요? 되돌릴 수 없습니다.', [paths.length])
                        : trf('{0}개 항목을 휴지통으로 보낼까요?', [paths.length]),
                    for (final x in paths.take(8)) '· ${vBasename(x)}',
                    if (paths.length > 8) trf('… 외 {0}개', [paths.length - 8]),
                    {for (final x in paths) vDirname(x)}.join('\n'),
                  ].join('\n')),
            if (local && !canRecycle)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(tr('이 위치 (네트워크 드라이브 · 네트워크 공유 · USB 메모리 등) 에는 휴지통이 없어 바로 지워집니다.'),
                    style: const TextStyle(fontSize: 12, color: Colors.orangeAccent)),
              ),
            if (canRecycle)
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: permanent,
                onChanged: (v) => set(() => permanent = v ?? false),
                title: Text(tr('휴지통을 거치지 않고 영구 삭제 (Shift+Delete)')),
              ),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('취소'))),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: permanent ? Colors.red.shade700 : null),
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(permanent ? tr('영구 삭제') : tr('휴지통으로')),
            ),
          ],
        ),
      ),
    );
    if (ok != true) return;
    // 하나씩: 실패해도 나머지는 계속. 실제로 어떻게 됐는지 세어 그대로 알린다 (94)
    final failed = <(String, String)>[];
    // 144: 경로가 너무 길어 휴지통이 받지 않은 것 (이유는 한 번, [영구 삭제] 로 바로 지울 수 있게)
    final tooLong = <String>[];
    var recycled = 0, nuked = 0, kept = 0;
    // 148: 휴지통으로 보낸 것 (되돌리기용) - 정보 파일 시각은 초 단위라 조금 앞에서부터
    final since = DateTime.now().subtract(const Duration(seconds: 2));
    final sent = <String>[];
    for (final x in paths) {
      try {
        if (!permanent) {
          switch (moveToRecycleBin(x)) {
            case RecycleResult.recycled:
              recycled++;
              sent.add(x);
            case RecycleResult.deletedPermanently:
              nuked++;
            case RecycleResult.cancelled:
              kept++;
          }
        } else {
          await FileOps().delete([x]);
        }
      } on LongPathException {
        tooLong.add(x);
      } catch (e) {
        failed.add((x, e is FileSystemException ? (e.osError?.message ?? e.message) : '$e'));
      }
    }
    if ((failed.isNotEmpty || tooLong.isNotEmpty) && mounted) {
      final nukeLong = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          scrollable: true,
          icon: const Icon(Icons.error_outline, color: Colors.redAccent),
          title: Text(trf('{0}개 중 {1}개를 지우지 못했습니다', [paths.length, failed.length + tooLong.length])),
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            // 144: 긴 경로는 이유 한 줄 + 이름만 (영구 삭제는 아래 버튼으로)
            if (tooLong.isNotEmpty) ...[
              Text(tr('경로가 너무 길어 휴지통에 넣을 수 없습니다 (Windows 의 휴지통은 260자 넘는 경로를 받지 않습니다).'),
                  style: const TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 4),
              for (final x in tooLong.take(30)) Text('· ${vBasename(x)}', style: const TextStyle(fontSize: 12)),
              if (tooLong.length > 30) Text(trf('… 외 {0}개', [tooLong.length - 30])),
              const SizedBox(height: 8),
            ],
            for (final (x, why) in failed.take(30)) ...[
              Text(vBasename(x), style: const TextStyle(fontWeight: FontWeight.w600)),
              Text('${vDirname(x)} · $why', style: const TextStyle(fontSize: 12, color: JjColors.textDim)),
              const SizedBox(height: 4),
            ],
            if (failed.length > 30) Text(trf('… 외 {0}개', [failed.length - 30])),
            const SizedBox(height: 6),
            // 이유를 이미 위에 적었으므로 짐작하는 말은 빼고, 실제로 지운 것이 있을 때만 "나머지는 지웠습니다"
            if (failed.length + tooLong.length < paths.length) Text(tr('나머지는 지웠습니다.'), style: const TextStyle(fontSize: 12)),
          ]),
          actions: [
            if (tooLong.isNotEmpty) ...[
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('그대로 두기'))),
              FilledButton(
                style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
                onPressed: () => Navigator.pop(ctx, true),
                child: Text(trf('영구 삭제 ({0}개, 되돌릴 수 없음)', [tooLong.length])),
              ),
            ] else
              FilledButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('확인'))),
          ],
        ),
      );
      // 144: 사용자가 [영구 삭제] 를 고른 긴 경로만 지운다
      if (nukeLong == true) {
        final notDeleted = <String>[];
        for (final x in tooLong) {
          try {
            await FileOps().delete([x]);
          } catch (e) {
            notDeleted.add('${vBasename(x)}: ${e is FileSystemException ? (e.osError?.message ?? e.message) : e}');
          }
        }
        _snack([
          if (tooLong.length > notDeleted.length) trf('{0}개를 영구 삭제했습니다.', [tooLong.length - notDeleted.length]),
          if (notDeleted.isNotEmpty) trf('지우지 못함: {0}', [notDeleted.take(3).join(' · ')]),
        ].join(' '));
      }
    } else if (!permanent && mounted) {
      final text = [
        if (recycled > 0) trf('{0}개 항목을 휴지통으로 보냈습니다.', [recycled]),
        // 휴지통보다 커서 Windows 가 물었고 사용자가 영구 삭제를 골랐다
        if (nuked > 0) trf('{0}개는 휴지통에 들어가지 않아 영구 삭제했습니다 (Windows 가 묻고 고른 대로).', [nuked]),
        if (kept > 0) trf('{0}개는 지우지 않았습니다 (취소).', [kept]),
      ].join(' ');
      // 148: 휴지통으로 보낸 것은 바로 [되돌리기]
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        duration: const Duration(seconds: 10),
        content: Text(text),
        action: sent.isEmpty ? null : SnackBarAction(label: tr('되돌리기'), onPressed: () => _undoRecycle(sent, since)),
      ));
    }
    for (final x in _panes) {
      x.marked.removeAll(paths);
      if (_selecting && x.marked.isEmpty) _selecting = false;
      x.expanded.removeWhere((d) => paths.any((s) => isSameOrInside(d, s)));
      if (paths.any((s) => isSameOrInside(x.current, s))) x.current = vDirname(paths.first);
    }
    await _refreshAll(paths.map(p.dirname));
  }

  /// 148: 방금 휴지통으로 보낸 것을 원래 자리로 (원래 자리에 같은 이름이 생겼으면 그것은 두고 알림)
  Future<void> _undoRecycle(List<String> paths, DateTime since) async {
    final failed = <String>[];
    var back = 0;
    for (final x in paths) {
      try {
        restoreFromRecycleBin(x, since: since);
        back++;
      } catch (e) {
        failed.add('${vBasename(x)}: ${e is FileSystemException ? e.message : e}');
      }
    }
    await _refreshAll(paths.map(p.dirname));
    for (final x in _panes) {
      x.changed();
    }
    _snack([
      if (back > 0) trf('{0}개 항목을 되돌렸습니다.', [back]),
      if (failed.isNotEmpty) trf('되돌리지 못함: {0}', [failed.take(3).join(' · ')]),
    ].join(' '));
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

  /// 154: 고른 것이 없을 때 (복사 · 이동이 같은 말)
  String _pickFirst(bool move) => move
      ? tr('옮길 항목을 고르세요 (누르거나 오른쪽 동그라미로 표시).')
      : tr('복사할 항목을 고르세요 (누르거나 오른쪽 동그라미로 표시).');

  /// 154: 항목 이름 (앞의 3개 + "외 n개")
  /// 48: 받는 폴더에 같은 이름이 있는 원본 (같은 폴더로 복사는 늘 새 이름이라 빼고)
  static Future<List<String>> _findClashes(List<String> sources, String dest) async {
    final out = <String>[];
    for (final s in sources) {
      if (samePath(vDirname(s), dest)) continue;
      try {
        if (await vExists(vJoin(dest, vBasename(s)))) out.add(s);
      } catch (_) {}
    }
    return out;
  }

  static String _namesOf(List<String> paths) {
    final names = [for (final x in paths.take(3)) vBasename(x)].join(', ');
    return paths.length > 3 ? trf('{0} 외 {1}개', [names, paths.length - 3]) : names;
  }

  void _toClipboard(List<String> sources, {required bool move}) {
    if (sources.isEmpty) {
      _snack(_pickFirst(move));
      return;
    }
    setState(() {
      _clip = [...sources];
      _clipMove = move;
    });
    _snack(trf('{0} 을 담았습니다. 넣을 폴더에서 [붙여넣기] 를 누르세요 ({1}).',
        [_namesOf(sources), move ? tr('이동') : tr('복사')]));
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

  /// 지금 도는 복사 · 이동 (아래에서 올라오는 진행 막대)
  /// (Rsync 화면의 ⇄ 는 둘이 함께)
  List<TransferJob> _jobs = const [];

  /// 52: 이 화면을 떠난 사이에 시작된 (또는 앞의 화면이 시작한) 작업을 다시 보이고, 끝나면 새로 읽고 막대를 내린다
  void _adoptJob(TransferJob job) {
    if (_jobs.contains(job)) return;
    setState(() => _jobs = [..._jobs, job]);
    unawaited(job.done.then((_) async {
      if (!mounted) return;
      await _refreshAll([job.dest, ...job.sources.map(vDirname)]);
      for (final x in _panes) {
        x.changed();
      }
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      if (mounted && _jobs.contains(job)) setState(() => _jobs = [for (final j in _jobs) if (j != job) j]);
    }));
  }

  /// 한쪽이라도 WebDAV 면 rsync 대신 앱이 직접 맞춘다 (rsync 는 WebDAV 를 모름)
  bool _viaDav(Iterable<String> paths) => paths.any(isDav);

  /// rsync 가 없으면 (Windows · 내려받기 설정) 지금 내려받을지 묻는다. 쓸 수 있는 rsync 경로 (없으면 null)
  Future<String?> _ensureRsync() async {
    final s = c.settings;
    final have = await rsyncExecutable(s);
    if (have != null) return have;
    if (!mounted) return null;
    if (s.rsyncSource == 'custom' || !Platform.isWindows) {
      _snack(tr('rsync 실행 파일을 찾을 수 없습니다. 환경 설정 > 파일 탐색기에서 경로를 확인하세요.'));
      return null;
    }
    return installRsyncWithDialog(context);
  }

  /// [dest] 로 복사 · 이동 (확인 · 아래 진행 막대 · 취소). 끝까지 했으면 true.
  Future<bool> _runTransfer(_Pane pane, List<String> sources, String dest, {required bool move}) async {
    if (sources.isEmpty) {
      _snack(_pickFirst(move));
      return false;
    }
    // 23: 앞의 복사 · 이동이 끝나지 않아도 함께 시작한다 (아래 진행 막대에 하나씩). 같은 것을 같은 곳으로만 막는다
    if (_jobs.any((j) => !j.finished && samePath(j.dest, dest) && j.sources.toSet().containsAll(sources))) {
      _snack(tr('같은 항목을 같은 곳으로 복사 · 이동하는 중입니다.'));
      return false;
    }
    // 원본 · 대상이 없거나 (다른 곳에서 지움 - 목록을 새로 고침) 폴더를 자기 안으로 넣으려 하면 시작하지 않는다
    final problem = transferProblem(sources, dest, move: move);
    if (problem != null) {
      _snack(problem);
      pane.marked.removeWhere((m) => vMissingSync(m));
      await _refreshAll([dest, ...sources.map(p.dirname)]);
      for (final x in _panes) {
        x.changed();
      }
      return false;
    }
    // 파일 탐색기: 현재 방식 · robocopy (rsync 는 Rsync 화면 - 그쪽만 모니터링에 남는다)
    final center = CopyCenter.of(c);
    final task = center.fresh(sources, dest, move: move);
    final method = CopyMethod.of(task.method);
    // 48: 받는 폴더에 같은 이름이 있으면 덮어쓰기 · 건너뛰기 · 이름 바꾸기를 고른다
    // (앱이 직접 할 때만 - robocopy · rsync 는 그 프로그램의 규칙. 같은 폴더로 복사는 늘 새 이름)
    final builtin = method == CopyMethod.builtin || _viaDav([...sources, dest]);
    // 확인 창은 바로 띄우고, 같은 이름은 창 안에서 뒤에서 찾는다 (느린 네트워크 · WebDAV 폴더라도 창이 늦게 뜨지 않게).
    // 다 찾기 전에 누르면 이름 바꾸기 (원래 파일을 건드리지 않는 쪽)
    final clashesFuture = builtin ? _findClashes(sources, dest) : Future.value(const <String>[]);
    // 48: 환경 설정 "같은 이름이 있을 때" 가 늘 하는 것이면 묻지 않고 그대로 (확인 창에 알림만)
    final always = switch (c.settings.copyConflict) {
      'rename' => NameConflict.rename,
      'overwrite' => NameConflict.overwrite,
      'skip' => NameConflict.skip,
      _ => null,
    };
    var conflict = always ?? NameConflict.rename;
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setInner) => AlertDialog(
          scrollable: true,
          title: Text(move ? tr('이동') : tr('복사')),
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${trf('{0}개 항목을 다음 폴더로 {1}\n{2}', [sources.length, move ? tr('옮길까요?') : tr('복사할까요?'), vDisplay(dest)])}'
                '\n${_namesOf(sources)}'
                '\n\n${trf('방법: {0}', [tr(method.label)])}'
                '${method == CopyMethod.builtin ? '' : ' · ${task.options}'}'
                '${task.bandwidthKBps > 0 ? ' · ${trf('속도 제한 {0} KB/s', [task.bandwidthKBps])}' : ''}'),
            FutureBuilder<List<String>>(
              future: clashesFuture,
              builder: (ctx, snap) {
                if (snap.connectionState != ConnectionState.done) {
                  return Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(tr('같은 이름이 있는지 확인하는 중 …'), style: const TextStyle(fontSize: 12, color: JjColors.textDim)),
                  );
                }
                final clashes = snap.data ?? const <String>[];
                if (clashes.isEmpty) return const SizedBox.shrink();
                return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const SizedBox(height: 12),
                  Text(trf('같은 이름이 이미 있습니다: {0}', [_namesOf(clashes)]),
                      style: const TextStyle(color: Colors.orangeAccent)),
                  if (always != null)
                    Text(
                        trf('환경 설정대로 {0} (환경 설정 > 파일 탐색기 > 같은 이름이 있을 때)', [
                          switch (always) {
                            NameConflict.rename => tr('이름을 바꿉니다'),
                            NameConflict.overwrite => tr('덮어씁니다'),
                            NameConflict.skip => tr('건너뜁니다'),
                          }
                        ]),
                        style: const TextStyle(fontSize: 12))
                  else
                  RadioGroup<NameConflict>(
                    groupValue: conflict,
                    onChanged: (x) => setInner(() => conflict = x ?? conflict),
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      for (final (v, label) in [
                        (NameConflict.rename, tr('이름 바꾸기 (예: 이름 (2))')),
                        (NameConflict.overwrite, tr('덮어쓰기 (원래 파일은 없어집니다)')),
                        (NameConflict.skip, tr('건너뛰기')),
                      ])
                        RadioListTile<NameConflict>(dense: true, contentPadding: EdgeInsets.zero, value: v, title: Text(label)),
                    ]),
                  ),
                ]);
              },
            ),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('취소'))),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(move ? tr('이동') : tr('복사'))),
          ],
        ),
      ),
    );
    if (go != true || !mounted) return false;
    // 104: 설정의 옵션에 지우기 (robocopy /MIR · /PURGE 등) 가 있으면 미리 보기를 거친다
    if (!await confirmDeletingRun(context, task) || !mounted) return false;
    String? rsync;
    if (method == CopyMethod.rsync && !_viaDav([...sources, dest])) {
      rsync = await _ensureRsync();
      if (rsync == null || !mounted) return false;
    }
    final job = await center.start(task, rsyncExe: rsync, conflict: conflict);
    if (job == null || !mounted) return false;
    setState(() => _jobs = [..._jobs.where((j) => !j.finished), job]);
    await job.done;
    final error = job.error;
    if (!mounted) return false;
    pane.marked.clear();
    if (_selecting) _setSelecting(false);
    await _refreshAll([dest, ...sources.map(p.dirname)]);
    // 넣은 폴더가 창의 지금 폴더면 펼쳐서 새 항목이 보이게
    for (final x in _panes) {
      if (samePath(x.current, dest)) {
        x.expanded.add(dest);
        await _load(x, dest, force: true);
      }
      x.changed();
    }
    _snack(error is FileOpCancelled
        ? tr('취소했습니다.')
        : error != null
            ? trf('끝나지 못했습니다: {0}', [error])
            : [
                trf('{0}개 항목을 {1}', [job.made.length, move ? tr('옮겼습니다.') : tr('복사했습니다.')]),
                if (job.skipped.isNotEmpty) trf('같은 이름이라 건너뜀: {0}', [_namesOf(job.skipped)]),
              ].join(' · '));
    // 다 되면 진행 막대가 잠깐 100% 를 보인 뒤 내려간다
    await Future<void>.delayed(const Duration(milliseconds: 1200));
    if (mounted && _jobs.contains(job)) setState(() => _jobs = [for (final j in _jobs) if (j != job) j]);
    return error == null;
  }

  /// Rsync 화면: 고른 왼쪽 · 오른쪽 폴더로 rsync. [right] 왼쪽 → 오른쪽, [left] 오른쪽 → 왼쪽 (둘 다면 함께).
  /// 폴더 "안의 것" 을 맞춘다 (원본/ → 대상/). 함께 할 때는 받는 쪽이 더 새 파일은 건너뛴다 (-u).
  /// 실행한 것은 모니터링에 남는다 (같은 것을 다시 하면 기억한 옵션으로).
  /// 확인 창이 떠 있는 동안 또 누르면 무시 (창이 겹쳐 아래 창을 잘못 누르지 않게 - 110)
  bool _rsyncAsking = false;

  Future<void> _runRsync({required bool right, required bool left}) async {
    if (_rsyncAsking) return;
    _rsyncAsking = true;
    try {
      await _runRsyncInner(right: right, left: left);
    } finally {
      _rsyncAsking = false;
    }
  }

  Future<void> _runRsyncInner({required bool right, required bool left}) async {
    final l = _panes[0].marked.firstOrNull, r = _panes[1].marked.firstOrNull;
    if (l == null || r == null) {
      _snack(tr('왼쪽 · 오른쪽 창에서 폴더를 하나씩 고르세요.'));
      return;
    }
    final runs = [if (right) (l, r), if (left) (r, l)];
    // 34: 대상이 원본과 같거나 원본 안이면 막는다 (맞출 때마다 원본이 바뀜). 원본이 대상 안 (안쪽 → 바깥) 은 지우기가 없을 때만
    if (runs.any((x) => isSameOrInside(x.$2, x.$1))) {
      _snack(tr('대상이 원본과 같거나 원본 안에 있습니다 (맞출 때마다 원본이 바뀝니다). 다른 폴더를 고르세요.'));
      return;
    }
    final nested = runs.any((x) => isSameOrInside(x.$1, x.$2));
    if (nested && !c.settings.allowInnerToOuter) {
      _snack(tr('원본이 대상 안에 있습니다 (환경 설정에서 막아 둠). 다른 폴더를 고르세요.'));
      return;
    }
    // 23: 다른 쌍은 함께 돌릴 수 있다. 같은 폴더끼리 도는 중이면 (서로 덮어쓰지 않게) 막는다
    if (_jobs.any((j) =>
        !j.finished &&
        runs.any((x) =>
            (samePath(j.sources.first, x.$1) && samePath(j.dest, x.$2)) ||
            (samePath(j.sources.first, x.$2) && samePath(j.dest, x.$1))))) {
      _snack(tr('이 두 폴더는 지금 rsync 하는 중입니다. 끝난 뒤에 하세요.'));
      return;
    }
    for (final (src, dst) in runs) {
      final problem = transferProblem([src], dst, move: false);
      if (problem != null) {
        _snack(problem);
        for (final x in _panes) {
          x.marked.removeWhere((m) => vMissingSync(m));
        }
        await _refreshAll([vDirname(l), vDirname(r)]);
        return;
      }
    }
    final both = right && left;
    final center = CopyCenter.of(c);
    // 확인 창에는 기억한 옵션 (없으면 지금 설정) 을 보여 주고, 실행할 때 모니터링에 기억한다
    // 96: 확인 창 · 미리 보기 · 실행이 같은 작업 (원본 파일 지우기 = 이동 작업) 과 같은 옵션을 쓴다
    List<CopyTask> shownTasks(bool move) =>
        [for (final (src, dst) in runs) center.peek([src], dst, contents: true, method: 'rsync', move: move)];
    var tasks = shownTasks(false);
    String opts(CopyTask t) => both ? withUpdateOption(t.options) : t.options;
    // 95: ⇄ 는 → 다음에 ← (차례로). ← 에서는 지우지 않는다 (→ 가 방금 복사한 것을 지우지 않게)
    String runOpts(int i) => both && i > 0 ? withoutDeleteOptions(opts(tasks[i])) : opts(tasks[i]);
    if (nested && tasks.any((t) => optionsDelete(opts(t)))) {
      _snack(tr('원본이 대상 안에 있으면 지우기 (--delete) 를 함께 쓸 수 없습니다 (대상의 다른 파일이 모두 지워집니다).'));
      return;
    }
    // 한 방향 (→ · ←) 만: 원본 파일 지우기 (--remove-source-files) 와 끝난 뒤 원본 정리
    var removeSource = false;
    var prune = 'keep';
    // 72: 실행 전 비교 결과 (지워질 수를 실행 버튼에)
    List<PreviewItem>? preview;
    Object? previewError;
    // 93: 지우는 실행 (--delete 등. 100: WebDAV 도 따른다) 은 비교가 끝나 지울 목록이 보인 뒤에만
    bool deletes() => tasks.any((t) => optionsDelete(opts(t)));
    // 105: 원본이 대상 안인데 지우기가 들어가면 막는다 - 창 안에서 옵션이 바뀔 때 (원본 파일 지우기) 와 실행 직전에도 본다
    bool nestedDelete() => nested && deletes();
    if (!mounted) return;
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, set) => AlertDialog(
        scrollable: true,
        // 110: 버튼이 좁아 세로로 쌓여도 [취소] 가 먼저 (아래 · 위가 바뀌어 [취소] 자리에 [실행] 이 오지 않게)
        actionsOverflowDirection: VerticalDirection.down,
        title: Text(both ? tr('rsync 양쪽 (⇄)') : 'rsync'),
        content: SizedBox(
          width: 560,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            for (final t in tasks) ...[
              // 109: 끝 폴더가 보이게 짧게, 전체 경로는 작게
              Text(shortPath(t.sources.first), style: const TextStyle(fontWeight: FontWeight.w600)),
              Text('→  ${shortPath(t.dest)}', style: const TextStyle(fontWeight: FontWeight.w600)),
              Text('${vDisplay(t.sources.first)}/  →  ${vDisplay(t.dest)}/',
                  style: const TextStyle(fontSize: 11, color: JjColors.textDim)),
              // 111: 이 쌍은 처음 실행 때 기억한 옵션을 쓴다 (환경 설정의 rsync 옵션을 바꿔도 그대로)
              if (center.tasks.any((x) => x.id == t.id))
                Text(tr('이 폴더 쌍은 기억한 옵션을 씁니다 (환경 설정이 아니라 모니터링 > 복사 · rsync 에서 고칩니다)'),
                    style: const TextStyle(fontSize: 11, color: JjColors.textDim)),
              Text('rsync ${runOpts(tasks.indexOf(t))}${removeSource ? ' --remove-source-files' : ''}'
                  '${t.bandwidthKBps > 0 ? ' · ${trf('속도 제한 {0} KB/s', [t.bandwidthKBps])}' : ''}',
                  style: const TextStyle(fontSize: 12, fontFamily: 'monospace', color: JjColors.textDim)),
              const SizedBox(height: 10),
            ],
            Text(tr('폴더 안의 것을 맞춥니다 (대상에 같은 이름의 폴더를 새로 만들지 않음).'),
                style: const TextStyle(fontSize: 12, color: JjColors.textDim)),
            if (nested)
              Text(tr('원본이 대상 폴더 안에 있습니다: 원본의 내용이 대상 폴더 바로 아래에 복사됩니다 (원본 폴더는 그대로 남음).'),
                  style: const TextStyle(fontSize: 12, color: Colors.orangeAccent)),
            // 72: 무엇이 바뀌는지 파일별로 (→ · ← · 받는 쪽에만 있음 · 지워짐)
            const SizedBox(height: 8),
            SyncPreviewView(
              // 옵션이 바뀌면 (원본 파일 지우기) 다시 비교
              key: ValueKey([for (var i = 0; i < tasks.length; i++) runOpts(i)].join('|')),
              compute: () async => both
                  ? previewBoth(l, r, delete: deletes())
                  : [
                      for (final t in tasks)
                        ...await previewSync(t.sources.first, t.dest,
                            toRight: t.sources.first == l, delete: deletes(), update: optionsUpdate(opts(t))),
                    ],
              // 97: 다시 비교하는 동안은 예전 결과로 실행하지 못하게
              onStart: () => set(() {
                preview = null;
                previewError = null;
              }),
              onResult: (items) => set(() {
                preview = items;
                previewError = null;
              }),
              onError: (e) => set(() {
                preview = null;
                previewError = e;
              }),
            ),
            if (nestedDelete())
              Text(tr('원본이 대상 안에 있으면 지우기 (--delete) 를 함께 쓸 수 없습니다 (대상의 다른 파일이 모두 지워집니다).'),
                  style: const TextStyle(fontSize: 12, color: Colors.redAccent, fontWeight: FontWeight.w600)),
            // 110: 이 줄은 늘 같은 자리를 차지한다 (글이 사라져 창 높이가 바뀌면 버튼이 움직인다)
            SizedBox(
              height: 34,
              child: deletes() && preview == null
                  ? Text(
                      previewError != null
                          ? tr('지우기가 들어간 실행이라, 비교하지 못하면 실행할 수 없습니다. 원본 · 대상을 확인한 뒤 [다시 비교] 를 누르세요.')
                          : tr('지우기가 들어간 실행이라, 지울 목록이 나온 뒤에 실행할 수 있습니다.'),
                      style: const TextStyle(fontSize: 12, color: Colors.orangeAccent),
                    )
                  : null,
            ),
            const SizedBox(height: 4),
            if (_viaDav([l, r]))
              Text(tr('WebDAV: rsync 대신 앱이 직접 맞춥니다 (크기 · 바뀐 때 비교, 옵션 중 -u · --delete · --remove-source-files 를 따름).'),
                  style: const TextStyle(fontSize: 12, color: JjColors.accent)),
            if (both)
              Text(tr('양쪽을 함께: 받는 쪽이 더 새 파일은 덮어쓰지 않습니다 (-u).'),
                  style: const TextStyle(fontSize: 12, color: JjColors.textDim))
            else ...[
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: removeSource,
                onChanged: (v) => set(() {
                  removeSource = v ?? false;
                  tasks = shownTasks(removeSource);
                  preview = null;
                  previewError = null;
                }),
                title: Text(tr('원본 파일 지우기 (--remove-source-files)')),
                subtitle: Text(tr('대상으로 옮긴 파일을 원본에서 지웁니다 (이동)')),
              ),
              if (removeSource) ...[
                Text(tr('끝난 뒤 원본의 빈 폴더를 지웁니다 (find 원본/ -type d -empty -delete). 원본 폴더는:'),
                    style: const TextStyle(fontSize: 12, color: JjColors.textDim)),
                const SizedBox(height: 6),
                PruneChoice(value: prune, onChanged: (v) => set(() => prune = v)),
              ],
            ],
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('취소'))),
          Builder(builder: (_) {
            final dels = preview?.where((x) => x.action == PreviewAction.delete).length ?? 0;
            return FilledButton(
              style: dels > 0 ? FilledButton.styleFrom(backgroundColor: JjColors.danger) : null,
              onPressed: nestedDelete() || (deletes() && preview == null) ? null : () => Navigator.pop(ctx, true),
              // 110: 글자는 늘 같게 (비교가 끝나 글이 길어지면 버튼 배치가 바뀌어 [취소] 를 누르려다 [실행] 을 누르게 됨).
              // 지울 수는 위의 빨간 글 "받는 쪽에서 N개가 지워집니다" 로 보인다
              child: Text(removeSource ? tr('이동') : tr('실행')),
            );
          }),
        ],
      )),
    );
    // 110: 무엇을 골랐는지 작업 기록에 (실행 · 취소 · 닫힘)
    c.note(trf('Rsync 확인 창 ({0}): {1}', [
      both ? '⇄' : right ? '→' : '←',
      go == true ? tr('실행') : go == false ? tr('취소') : tr('닫힘 (실행 안 함)'),
    ]));
    if (go != true || !mounted) return;
    if (nestedDelete()) {
      _snack(tr('원본이 대상 안에 있으면 지우기 (--delete) 를 함께 쓸 수 없습니다 (대상의 다른 파일이 모두 지워집니다).'));
      return;
    }
    final dav = _viaDav([l, r]);
    final exe = dav ? '' : await _ensureRsync();
    if (exe == null || !mounted) return;
    // 96: 확인 창에 보인 그 옵션으로 (기억한 작업의 옵션이 달라도)
    final shownOpts = [for (var i = 0; i < tasks.length; i++) runOpts(i)];
    var run = [
      for (final (src, dst) in runs) await center.remember([src], dst, contents: true, method: 'rsync', move: removeSource),
    ];
    if (removeSource) {
      run = [for (final t in run) t.copyWith(prune: prune)];
      for (final t in run) {
        await center.update(t);
      }
    }
    // 95: 차례로 (→ 가 끝난 뒤 ←). 앞의 것이 실패 · 취소되면 뒤의 것은 하지 않는다
    final jobs = <TransferJob>[];
    for (var i = 0; i < run.length; i++) {
      c.note(trf('rsync 시작 ({0}): {1} → {2}', [tr('Rsync 화면 확인 창의 [실행]'), run[i].sources.first, run[i].dest]));
      final j = await center.start(run[i].copyWith(options: shownOpts[i]), rsyncExe: dav ? null : exe);
      if (j == null || !mounted) break;
      jobs.add(j);
      setState(() => _jobs = [..._jobs.where((x) => !x.finished), j]);
      await j.done;
      if (j.error != null) break;
    }
    if (jobs.isEmpty || !mounted) return;
    // 원본 폴더까지 지웠으면 고른 표시도 뺀다
    for (final x in _panes) {
      x.marked.removeWhere((m) => vMissingSync(m));
    }
    await _refreshAll([l, r, vDirname(l), vDirname(r)]);
    for (final x in _panes) {
      x.changed();
    }
    final error = jobs.map((j) => j.error).whereType<Object>().firstOrNull;
    _snack(error is FileOpCancelled
        ? tr('취소했습니다.')
        : error != null
            ? trf('끝나지 못했습니다: {0}', [error])
            : trf('rsync 끝: {0}', [jobs.map((j) => '${vBasename(j.sources.first)} → ${vBasename(j.dest)}').join(' · ')]));
    await Future<void>.delayed(const Duration(milliseconds: 1200));
    if (mounted) setState(() => _jobs = [for (final j in _jobs) if (!jobs.contains(j)) j]);
  }

  /// 아래에서 올라오는 진행 막대 (위: 전체 항목 중 · 아래: 지금 폴더의 파일 중)
  Widget _transferPanel() {
    final jobs = _jobs;
    return AnimatedSlide(
      offset: jobs.isEmpty ? const Offset(0, 1.2) : Offset.zero,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
      child: jobs.isEmpty
          ? const SizedBox(height: 0)
          : Material(
              elevation: 12,
              color: JjColors.panel,
              borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 12, 12),
                // 여러 개가 함께 돌면 (23) 높이를 넘지 않게 넘겨 보기
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.45),
                  child: SingleChildScrollView(
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      for (final (k, job) in jobs.indexed) ...[
                        if (k > 0) const Divider(height: 18),
                        ListenableBuilder(listenable: job, builder: (context, _) => _jobView(job)),
                      ],
                    ]),
                  ),
                ),
              ),
            ),
    );
  }

  /// 진행 막대 하나 (위: 전체 항목 중 · 아래: 지금 폴더의 파일 중)
  Widget _jobView(TransferJob job) {
    String pct(double v) => '${(v * 100).round()}%';
    final cur = job.index < job.total ? job.index : job.total - 1;
    final curFiles = job.total == 0 ? 0 : job.filesTotal[cur.clamp(0, job.total - 1)];
    final curDone = job.total == 0 ? 0 : job.filesDone[cur.clamp(0, job.total - 1)];
    final title = job.finished
        ? (job.error == null ? tr('완료') : tr('멈춤'))
        : job.move
            ? tr('옮기는 중')
            : tr('복사하는 중');
    Widget line(String label, double value, String right) => Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Row(children: [
            SizedBox(
              width: 300,
              child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12.5)),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(3),
                child: LinearProgressIndicator(
                  minHeight: 8,
                  value: job.counting ? null : value,
                  // 빈 곳과 찬 곳이 분명히 다르게
                  color: JjColors.accent,
                  backgroundColor: JjColors.border,
                ),
              ),
            ),
            const SizedBox(width: 10),
            SizedBox(
              width: 150,
              child: Text(right, textAlign: TextAlign.end, style: const TextStyle(fontSize: 12, color: JjColors.textDim)),
            ),
          ]),
        );
    return Column(mainAxisSize: MainAxisSize.min, children: [
      Row(children: [
        Icon(job.move ? Icons.drive_file_move_outline : Icons.copy_outlined, size: 18, color: JjColors.accent),
        const SizedBox(width: 8),
        Text('$title · ${tr(job.method.label)}', style: const TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(width: 12),
        Expanded(
          // Rsync 화면: 원본 → 대상 (⇄ 는 두 줄)
          child: Text(widget.rsync ? '${job.sources.join(', ')}/  →  ${job.dest}/' : job.dest,
              maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, color: JjColors.textDim)),
        ),
        if (!job.finished) TextButton(onPressed: job.cancel, child: Text(tr('취소'))),
      ]),
      // Rsync 화면 (폴더 하나를 맞춤): 위 = 지금 복사하는 파일 (그 파일의 진행률 · 속도), 아래 = 폴더 전체 (파일 수)
      if (widget.rsync) ...[
        line(
          job.counting
              ? tr('파일 세는 중…')
              : job.pruning
                  ? (job.finished ? trf('빈 폴더 {0}개 지움', [job.pruned]) : tr('원본의 빈 폴더 정리 중…'))
                  : job.finished
                      ? tr('끝')
                      : job.currentFile.isEmpty
                          ? tr('시작하는 중…')
                          : job.currentFile.split('/').last,
          job.finished ? 1.0 : (job.filePercent ?? 0),
          [
            if (job.filePercent != null && !job.finished) pct(job.filePercent!),
            if (!job.finished && job.speed != null) '${formatSize(job.speed!.round())}/s',
          ].join(' · '),
        ),
        line(
          trf('{0} 전체', [job.currentName.isEmpty ? vBasename(job.sources.first) : job.currentName]),
          job.folderProgress,
          '${pct(job.folderProgress)} · ${job.checkTotal > 0 && !job.finished ? trf('항목 {0}/{1}', [job.checked, job.checkTotal]) : trf('파일 {0}/{1}', [job.allDone, job.allFiles])}',
        ),
      ] else ...[
        // 파일 탐색기 (여러 항목): 위 = 전체 항목 중 · 아래 = 지금 폴더의 파일 중
        line(
          trf('전체 {0}개 중 {1}번째', [job.total, (cur + 1).clamp(1, job.total)]),
          job.overall,
          '${pct(job.overall)} · ${trf('파일 {0}/{1}', [job.allDone, job.allFiles])}'
                  '${!job.finished && job.speed != null ? ' · ${formatSize(job.speed!.round())}/s' : ''}',
        ),
        line(
          job.counting
              ? tr('파일 세는 중…')
              : job.pruning
                  ? (job.finished ? trf('빈 폴더 {0}개 지움', [job.pruned]) : tr('원본의 빈 폴더 정리 중…'))
                  : trf('{0} 안의 파일', [job.currentName]),
          job.current,
          '${pct(job.current)} · ${trf('파일 {0}/{1}', [curDone, curFiles])}',
        ),
      ],
    ]);
  }

  Future<String?> _askName(String title, String initial, {String? hint, bool selectAll = false}) {
    final ctl = TextEditingController(text: initial);
    final dot = initial.lastIndexOf('.');
    ctl.selection = TextSelection(baseOffset: 0, extentOffset: dot > 0 && !selectAll ? dot : initial.length);
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        scrollable: true,
        title: Text(title),
        content: TextField(
          controller: ctl,
          autofocus: true,
          decoration: InputDecoration(hintText: hint ?? tr('이름')),
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
    final meta = !e.isDir && !isDav(e.path) && isVideoFile(e.path) ? await _Meta.of(c, e.path) : null;
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        scrollable: true,
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
    await _goTo(pane, found.isDir ? found.path : vDirname(found.path), fresh: true);
    pane.focused = found.path;
    pane.changed();
    _reveal(pane, found.path);
  }

  Future<void> _sortDialog() async {
    final s = c.settings;
    var by = s.explorerSort;
    var desc = s.explorerSortDesc;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => AlertDialog(
        scrollable: true,
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
    final hist = c.settings.explorerHistory.where(_reachable).toList();
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
    if (pick != null) await _goTo(pane, pick, fresh: true);
  }

  /// 118: 두 창이면 좌우 ⇆ 위아래 를 바꾸고, 한 창이면 두 창 (좌우) 으로. 한 번 눌러 바로
  Future<void> _toggleOrientation() async {
    final s = c.settings;
    if (!(_dual || _split)) {
      await c.updateSettings((x) => x
        ..explorerLayout = 'dual'
        ..explorerOrientation = 'side');
    } else {
      // 지금 보이는 배치의 반대 ('화면 모양 따라' 였으면 지금 모양에서 정함)
      final size = MediaQuery.sizeOf(context);
      final nowSide = switch (s.explorerOrientation) {
        'side' => true,
        'stacked' => false,
        _ => size.width >= size.height,
      };
      await c.updateSettings((x) => x.explorerOrientation = nowSide ? 'stacked' : 'side');
    }
    if (!mounted) return;
    setState(() {});
    for (final pane in _panes) {
      _reveal(pane, pane.current);
    }
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
        scrollable: true,
            title: Text(tr('창 배치')),
            content: SizedBox(
              width: 420,
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                group(tr('창'), layout, [
                  ('auto', tr('화면 크기 따라 (기본)')),
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
                    ('side', tr('좌우 (기본)')),
                    ('stacked', tr('위아래')),
                    ('auto', tr('화면 모양 따라')),
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
    final order = [...current, ...ExplorerButton.explorerValues.where((b) => !current.contains(b))];
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
                  ..addAll(ExplorerButton.explorerValues);
                on
                  ..clear()
                  ..addAll(ExplorerButton.explorerValues);
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

  /// 49: 뒤로 키가 화면을 닫기 전에 할 일이 있는지 (고른 것이 있거나 맨 위 폴더가 아님)
  bool get _backHasWork =>
      _selecting || _panes.any((x) => x.marked.isNotEmpty) || (_ready && !samePath(_pane.current, _pane.root));

  /// 49: 뒤로 키 - 먼저 고른 것 풀기, 그다음 상위 폴더, 맨 위면 화면 닫기 (위쪽 ← 는 늘 닫기)
  Future<void> _onBack() async {
    if (_selecting || _panes.any((x) => x.marked.isNotEmpty)) {
      _setSelecting(false);
      return;
    }
    if (!samePath(_pane.current, _pane.root)) {
      await _button(ExplorerButton.up);
      return;
    }
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_backHasWork,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_onBack());
      },
      child: _buildPage(context),
    );
  }

  Widget _buildPage(BuildContext context) {
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.f5): () => _button(ExplorerButton.refresh),
        const SingleActivator(LogicalKeyboardKey.delete): () => _button(ExplorerButton.delete),
        // 65: Shift+Delete = 휴지통을 거치지 않고 (창에서 한 번 더 확인)
        const SingleActivator(LogicalKeyboardKey.delete, shift: true): () {
          _shiftDelete = true;
          _button(ExplorerButton.delete);
        },
        const SingleActivator(LogicalKeyboardKey.f2): () => _button(ExplorerButton.rename),
        const SingleActivator(LogicalKeyboardKey.backspace): () => _button(ExplorerButton.up),
        const SingleActivator(LogicalKeyboardKey.tab): () =>
            setState(() => _active = _dual ? 1 - _active : 0),
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          body: SwipeNav(
            current: widget.rsync ? 'rsync' : 'explorer',
            child: ListenableBuilder(
            listenable: c,
            builder: (context, _) {
              _dropRemovedServers();
              return Column(children: [
                _topBar(),
                Expanded(
                  child: Stack(children: [
                    Positioned.fill(child: _ready ? _body() : const Center(child: CircularProgressIndicator())),
                    // 복사 · 이동 진행: 아래에서 올라오고 끝나면 내려간다
                    Positioned(left: 8, right: 8, bottom: 0, child: _transferPanel()),
                  ]),
                ),
              ]);
            },
          ),
          ),
        ),
      ),
    );
  }

  Widget _topBar() => AppTopBar(
        nav: AppNavButtons(onExplorerPage: !widget.rsync, onRsyncPage: widget.rsync),
        actions: AppActions(c: c),
        middle: Row(children: [
          Text(widget.rsync ? 'Rsync' : tr('파일 탐색기'), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
          const SizedBox(width: 12),
          Expanded(
            child: Text(_ready ? _displayPath(_pane.current) : '',
                maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: JjColors.textDim)),
          ),
          PopupMenuButton<ExplorerButton>(
            tooltip: tr('창 배치 · 버튼 구성'),
            icon: const Icon(Icons.more_vert),
            onSelected: _button,
            itemBuilder: (_) => [
              for (final b in [
                if (!widget.rsync) ...[ExplorerButton.layout, ExplorerButton.buttons],
                ExplorerButton.sort,
                ExplorerButton.hidden,
              ])
                PopupMenuItem(
                  value: b,
                  child: Row(children: [Icon(b.icon, size: 18), const SizedBox(width: 12), Text(tr(b.label))]),
                ),
            ],
          ),
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
    final dual = _dual;
    final split = _split;
    return LayoutBuilder(builder: (context, box) {
      final side = !(dual || split) ||
          switch (s.explorerOrientation) {
            'side' => true,
            'stacked' => false,
            _ => box.maxWidth >= box.maxHeight,
          };
      final bar = s.explorerToolbar == 'hidden' && !widget.rsync
          ? null
          : _Toolbar(
              // Rsync 화면: 늘 같은 버튼 (→ ← ⇄ 모니터링) 을 두 창 사이에
              buttons: widget.rsync ? ExplorerButton.rsyncButtons : ExplorerButton.fromSettings(s.explorerButtons),
              vertical: side,
              onPressed: _button,
              enabled: (b) => switch (b) {
                ExplorerButton.paste => _clip.isNotEmpty,
                _ => true,
              },
              selected: (b) =>
                  (b == ExplorerButton.hidden && s.explorerShowHidden) || (b == ExplorerButton.select && _selecting),
              twoPanes: dual || split,
            );
      final middle = bar != null && (widget.rsync || s.explorerToolbar == 'middle');
      final edge = bar != null && !widget.rsync && s.explorerToolbar == 'edge';
      final children = <Widget>[
        if (dual) ...[
          Expanded(child: _paneView(0, foldersOnly: widget.rsync)),
          if (middle) bar,
          Expanded(child: _paneView(1, foldersOnly: widget.rsync)),
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
              _normalizeMarks(pane);
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
    // 38: 창 높이를 알아야 안내 상자의 높이를 제한할 수 있다
    return LayoutBuilder(builder: (context, box) => _frame(i, [
      _paneHeader(pane),
      const Divider(height: 1),
      // 38: 안내가 길어도 목록을 덮지 않게 (창 높이의 35% 까지, 넘치면 넘겨 봄)
      ?_noticeArea([_accessNotice(pane), _errorNotice(pane, pane.current), _partialNotice(pane, pane.current)], box.maxHeight),
      // 읽는 중 (WebDAV 서버를 기다릴 때 등)
      if (pane.loading.isNotEmpty) const LinearProgressIndicator(minHeight: 2),
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
    ]));
  }

  /// "폴더 + 파일 목록" 배치의 오른쪽: 왼쪽 트리에서 고른 폴더의 내용 (맨 위 ".." = 상위 폴더)
  Widget _listView(_Pane pane) {
    final dir = pane.current;
    final entries = pane.cache[dir] ?? const <FileEntry>[];
    final up = !samePath(dir, pane.root);
    final rows = [
      if (up) _Row(FileEntry(vDirname(dir), isDir: true, modified: DateTime(0)), 0, isUp: true),
      for (final e in entries) _Row(e, 0),
    ];
    final look = _look;
    // 38: 창 높이를 알아야 안내 상자의 높이를 제한할 수 있다
    return LayoutBuilder(builder: (context, box) => _frame(0, [
      Container(
        height: 40,
        alignment: Alignment.centerLeft,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Text(_displayPath(dir), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: JjColors.textDim)),
      ),
      const Divider(height: 1),
      ?_noticeArea([_accessNotice(pane), _errorNotice(pane, dir), _partialNotice(pane, dir)], box.maxHeight),
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
    ]));
  }

  /// 창 위쪽: 저장 장치 고르기
  Widget _paneHeader(_Pane pane) => SizedBox(
        height: 40,
        child: ListView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          children: [
            // 37: 지금 열어 둔 네트워크 공유 (\\NAS\공유) 도 탭으로
            for (final (path, label) in [
              ..._volumes,
              for (final x in _panes)
                if (Platform.isWindows && x.root.startsWith(r'\\') && !_volumes.any((v) => samePath(v.$1, x.root)))
                  (x.root, x.root),
            ])
              Padding(
                padding: const EdgeInsets.only(right: 4),
                child: TextButton.icon(
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    backgroundColor: samePath(pane.root, path) ? JjColors.accent.withValues(alpha: 0.18) : null,
                    foregroundColor: samePath(pane.root, path) ? JjColors.accent : null,
                  ),
                  icon: Icon(
                      isDav(path)
                          ? Icons.cloud_outlined
                          : _networkDrives.contains(path)
                              ? Icons.lan_outlined
                              : Platform.isWindows
                                  ? Icons.storage
                                  : Icons.sd_storage_outlined,
                      size: 16),
                  // 165: 열 수 없는 드라이브는 숨기지 않고 "연결 안 됨" - 누르면 다시 연결 (다시 읽기)
                  label: _driveOk[path] == false
                      ? Text('$label · ${_removableDrives.contains(path) ? tr('비어 있음') : tr('연결 안 됨')} ⟳',
                          style: TextStyle(color: _removableDrives.contains(path) ? JjColors.textDim : Colors.orangeAccent))
                      : Text(label),
                  onPressed: () {
                    setState(() => _active = _panes.indexOf(pane));
                    if (_driveOk[path] == false) {
                      unawaited(_reconnect(pane, path));
                    } else {
                      _goTo(pane, path);
                    }
                  },
                  onLongPress: isDav(path) ? () => _editDav(pane, path) : null,
                ),
              ),
            if (c.settings.webdavServers.isEmpty)
              TextButton.icon(
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                ),
                icon: const Icon(Icons.cloud_outlined, size: 16),
                label: const Text('WebDAV'),
                onPressed: () => _editDav(pane, null),
              )
            else
              IconButton(
                tooltip: tr('WebDAV 서버 추가'),
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.add, size: 16),
                onPressed: () => _editDav(pane, null),
              ),
            // 37: 경로를 직접 넣어 가기 (Windows 는 \\NAS\공유 도)
            IconButton(
              tooltip: tr('경로 입력'),
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.edit_location_alt_outlined, size: 16),
              onPressed: () => _enterPath(pane),
            ),
          ],
        ),
      );

  /// 경로를 직접 넣어 가기 (37). 없는 폴더면 알린다
  Future<void> _enterPath(_Pane pane) async {
    setState(() => _active = _panes.indexOf(pane));
    final input = await _askName(
        Platform.isWindows ? tr('경로 입력 (예: D:\\영상 · \\\\NAS\\공유)') : tr('경로 입력'), pane.current,
        hint: tr('경로'), selectAll: true);
    if (input == null || !mounted) return;
    var path = input.trim().replaceAll('"', '');
    if (path.isEmpty) return;
    if (Platform.isWindows && RegExp(r'^\\\\[^\\/]+[\\/]?$').hasMatch(path)) {
      _snack(tr('네트워크 공유는 공유 폴더 이름까지 넣으세요 (예: \\\\NAS\\영상).'));
      return;
    }
    if (!isDav(path) && Platform.isWindows && RegExp(r'^[a-zA-Z]:$').hasMatch(path)) path = '$path\\';
    final ok = isDav(path) || await Directory(path).exists();
    if (!mounted) return;
    if (!ok) {
      _snack(trf('폴더가 없거나 열 수 없습니다: {0}', [path]));
      return;
    }
    await _goTo(pane, path, fresh: true);
  }

  /// WebDAV 서버 추가 (없으면 [root] 는 null) · 고치기 (탭 길게 누르기). 저장하면 그 서버로 간다.
  Future<void> _editDav(_Pane pane, String? root) async {
    setState(() => _active = _panes.indexOf(pane));
    final old = root == null ? null : DavRegistry.server(DavPath.parse(root).server);
    final saved = await editDavServer(context, c, old: old);
    if (saved == null || !mounted) return;
    for (final x in _panes) {
      x.cache.removeWhere((k, _) => isDav(k) && DavPath.parse(k).server == saved.id);
    }
    await _goTo(pane, '$davScheme${saved.id}/');
  }

  /// 한 줄. [list]: "폴더 + 파일 목록" 의 오른쪽 목록 (트리 아님). [compact]: 폴더 트리 (열 · 표시 버튼 없이)
  Widget _rowView(_Pane pane, _Row row, {bool list = false, bool compact = false}) {
    final e = row.entry;
    final look = _look;
    final isCurrent = e.isDir && !list && !row.isUp && samePath(pane.current, e.path);
    final isFocused = !row.isUp && pane.focused != null && samePath(pane.focused!, e.path);
    final marked = _isMarked(pane, e.path);
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

    // 좁은 창 (폰 세로의 좌우 두 창) 에서 깊은 폴더: 들여쓰기는 이름 자리를 남기는 만큼만 (넘치지 않게)
    Widget nameCell() => LayoutBuilder(builder: (context, box) {
          final fixed = (list ? 0 : 20) + (look.rich ? 64 : look.iconSize + 12) + 48.0;
          final indent = list ? 0.0 : (row.depth * look.indent).clamp(0.0, (box.maxWidth - fixed).clamp(0.0, double.infinity));
          return Row(children: [
          SizedBox(width: indent),
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
                        // 좁은 화면 · 깊은 폴더에서 넘치지 않게
                        Flexible(
                          child: Text('${formatSize(e.size)} · ${_date(e.modified)}',
                              style: dim, maxLines: 1, overflow: TextOverflow.ellipsis),
                        ),
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
        });

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
      // Rsync 화면은 고르기만 (파일 기능 메뉴 없음)
      // 25: Rsync 화면에서도 (폴더 메뉴)
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
          if ((real || (widget.rsync && row.isRoot)) && (_selecting || widget.rsync))
            SizedBox(
              width: 36,
              child: IconButton(
                tooltip: widget.rsync
                    ? (marked ? tr('고르기 취소') : tr('이 폴더를 rsync 원본 · 대상으로 고르기'))
                    : marked
                        ? tr('표시 지우기')
                        : tr('표시 (여러 개 고르기)'),
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                // ✔ 모양: 고르지 않은 것은 흐리게, 고른 것은 진하게
                icon: Icon(marked ? Icons.check_circle : Icons.check_circle_outline,
                    size: look.rich ? 22 : 18,
                    color: marked ? JjColors.accent : JjColors.textDim.withValues(alpha: 0.35)),
                onPressed: () {
                  setState(() => _active = _panes.indexOf(pane));
                  widget.rsync ? _pick(pane, e) : _toggleMark(pane, e);
                },
              ),
            )
          else if (_selecting || widget.rsync)
            const SizedBox(width: 36),
        ]),
      ),
    );
  }

  Widget _icon(FileEntry e, bool isRoot, bool open, {bool up = false}) {
    final look = _look;
    if (up) return Icon(Icons.arrow_upward, size: look.iconSize, color: JjColors.textDim);
    if (isRoot) return Icon(isDav(e.path) ? Icons.cloud : Icons.sd_storage, color: JjColors.accent, size: look.iconSize - 2);
    // X-plore: 동영상 썸네일 · 그림 미리 보기 (WebDAV 는 받아야 하므로 아이콘만)
    if (look.rich && !e.isDir && !isDav(e.path)) {
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

  /// 창이 둘인지 (두 창 · 폴더 + 파일 목록). 하나면 [orient] 는 "두 창으로"
  final bool twoPanes;
  const _Toolbar(
      {required this.buttons,
      required this.vertical,
      required this.onPressed,
      required this.enabled,
      required this.selected,
      this.twoPanes = true});

  /// 118: 지금 배치를 보여 준다 (누르면 반대로)
  String _orientLabel() => !twoPanes ? '두 창으로' : vertical ? '좌우 ⇆' : '위아래 ⇅';
  String _orientTip() => !twoPanes
      ? '두 창으로 보기 (좌우)'
      : vertical
          ? '창 배치: 좌우 (누르면 위아래)'
          : '창 배치: 위아래 (누르면 좌우)';

  /// 창이 위아래로 놓이면 (버튼 줄이 가로) "좌 → 우" 대신 "위 → 아래"
  String _label(ExplorerButton b) => b == ExplorerButton.orient
      ? _orientLabel()
      : vertical
      ? b.label
      : switch (b) {
          ExplorerButton.toRight => '위 → 아래',
          ExplorerButton.toLeft => '위 ← 아래',
          ExplorerButton.both => '위 ⇄ 아래',
          _ => b.label,
        };

  IconData _icon(ExplorerButton b) => b == ExplorerButton.orient
      ? (!twoPanes ? Icons.vertical_split_outlined : vertical ? Icons.swap_horiz : Icons.swap_vert)
      : vertical
      ? b.icon
      : switch (b) {
          ExplorerButton.toRight => Icons.arrow_downward,
          ExplorerButton.toLeft => Icons.arrow_upward,
          ExplorerButton.both => Icons.swap_vert,
          _ => b.icon,
        };

  @override
  Widget build(BuildContext context) {
    Widget btn(ExplorerButton b) {
      final on = enabled(b);
      final sel = selected(b);
      return Tooltip(
        message: tr(b == ExplorerButton.orient ? _orientTip() : _label(b)),
        child: InkWell(
          onTap: on ? () => onPressed(b) : null,
          borderRadius: BorderRadius.circular(6),
          child: SizedBox(
            width: 72,
            height: 58,
            child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
              Icon(_icon(b), size: 22, color: !on ? JjColors.textDim.withValues(alpha: 0.4) : sel ? JjColors.accent : null),
              const SizedBox(height: 2),
              Text(tr(_label(b)),
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

  /// 24: 찾기를 멈추는 개수 · 읽지 못한 폴더
  static const limit = 2000;
  final _skipped = <(String, String)>[];

  @override
  void initState() {
    super.initState();
    _sub = searchFiles(widget.root, widget.query, showHidden: widget.showHidden, limit: limit, onSkipped: (dir, e) {
      if (mounted) {
        setState(() => _skipped.add((dir, e is FileSystemException ? (e.osError?.message ?? e.message) : '$e')));
      }
    }).listen(
      (e) => setState(() => _found.add(e)),
      onDone: () => setState(() => _done = true),
      onError: (_) {},
    );
  }

  /// 아래 안내: 개수 한도에서 멈춤 · 읽지 못한 폴더
  Widget? _footer() {
    final limited = _found.length >= limit;
    if (!limited && _skipped.isEmpty) return null;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      if (limited)
        Text(trf('{0}개를 찾아 여기서 멈췄습니다. 이름을 더 자세히 넣거나 아래 폴더로 들어가 찾으세요.', [limit]),
            style: const TextStyle(fontSize: 12, color: Colors.orangeAccent)),
      if (_skipped.isNotEmpty)
        ExpansionTile(
          tilePadding: EdgeInsets.zero,
          dense: true,
          title: Text(trf('읽지 못한 폴더 {0}개 (권한 · 연결 문제) - 그 안은 찾지 못했습니다', [_skipped.length]),
              style: const TextStyle(fontSize: 12, color: Colors.orangeAccent)),
          children: [
            for (final (dir, why) in _skipped.take(50))
              Align(
                alignment: Alignment.centerLeft,
                child: Text('$dir · $why', style: const TextStyle(fontSize: 11, color: JjColors.textDim)),
              ),
          ],
        ),
    ]);
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
          child: Column(children: [
            Expanded(
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
                      subtitle: Text(vDirname(e.path), maxLines: 1, overflow: TextOverflow.ellipsis),
                      onTap: () => Navigator.pop(context, e),
                    );
                  },
                ),
            ),
            ?_footer(),
          ]),
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
