import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../app/app_controller.dart';
import '../app/bookmarks_controller.dart';
import '../app/download_manager.dart';
import '../core/bookmarks.dart';
import '../core/download_detect.dart' show CookieRecord, toNetscapeCookies;
import '../core/web_address.dart';
import 'app_actions.dart';
import 'downloads_page.dart';
import 'theme.dart';
import 'work_panel.dart';

/// 브라우저 조작 (앱 안 웹뷰)
abstract class WebNav {
  Future<void> load(String url);
  Future<void> back();
  Future<void> forward();
  Future<void> reload();
  Future<void> stop();

  /// YouTube · Google 로그인 쿠키를 yt-dlp 용 cookies.txt 로 내보내기
  Future<void> exportCookies();
}

/// 웹뷰 → 화면으로 알리는 통로
class BrowserHost {
  final void Function(String url) onUrl;
  final void Function(String title) onTitle;
  final void Function(double progress) onProgress;
  final void Function(bool hasVideo) onVideo;
  final void Function(bool back, bool forward) onHistory;
  final void Function(WebNav nav) attach;
  const BrowserHost({
    required this.onUrl,
    required this.onTitle,
    required this.onProgress,
    required this.onVideo,
    required this.onHistory,
    required this.attach,
  });
}

/// 웹 브라우저 (앱 안 Edge 엔진). 동영상 페이지면 상단 [다운로드] 로 바로 받는다.
class BrowserPage extends StatefulWidget {
  final AppController c;
  final DownloadManager? downloads;
  final BookmarksController bookmarks;
  final String? initialUrl;

  /// 테스트용 웹뷰 대체
  final Widget Function(BrowserHost host, String url)? viewBuilder;

  const BrowserPage({
    super.key,
    required this.c,
    required this.bookmarks,
    this.downloads,
    this.initialUrl,
    this.viewBuilder,
  });

  @override
  State<BrowserPage> createState() => _BrowserPageState();
}

class _BrowserPageState extends State<BrowserPage> {
  late String _url = widget.initialUrl ?? widget.c.settings.homeUrl;
  String _title = '';
  double _progress = 1;
  bool _hasVideo = false, _canBack = false, _canFwd = false, _panel = false;
  WebNav? _nav;

  /// 오른쪽 작업 현황 (화면 분할). 앱을 켜 둔 동안은 열림 여부 · 너비를 기억.
  static bool? _workOpen;
  static double _workWidth = 360;
  late bool _work = _workOpen ?? widget.c.busy;
  void _toggleWork() => setState(() => _workOpen = _work = !_work);
  late final _address = TextEditingController(text: _url);
  final _addressFocus = FocusNode();
  late final BrowserHost _host = BrowserHost(
    onUrl: (u) {
      if (!mounted || u.isEmpty) return;
      setState(() => _url = u);
      if (!_addressFocus.hasFocus) _address.text = u;
    },
    onTitle: (t) => mounted ? setState(() => _title = t) : null,
    onProgress: (p) => mounted ? setState(() => _progress = p) : null,
    onVideo: (v) => mounted ? setState(() => _hasVideo = v) : null,
    onHistory: (b, f) {
      if (!mounted) return;
      setState(() {
        _canBack = b;
        _canFwd = f;
      });
    },
    attach: (n) => _nav = n,
  );

  BookmarksController get bm => widget.bookmarks;

  @override
  void dispose() {
    _address.dispose();
    _addressFocus.dispose();
    super.dispose();
  }

  void _go(String input) {
    final url = normalizeAddress(input);
    _address.text = url;
    _addressFocus.unfocus();
    _nav?.load(url);
  }

  bool get _canDownload =>
      widget.downloads != null && (looksLikeVideoPage(_url) || (_hasVideo && _url.startsWith('http')));

  Future<void> _download() async {
    // 로그인 쿠키를 먼저 내보내 yt-dlp 가 같은 로그인으로 받도록
    try {
      await _nav?.exportCookies();
    } catch (_) {}
    if (!mounted) return;
    final t = widget.downloads!.addPage(_url);
    final m = ScaffoldMessenger.of(context);
    m.showSnackBar(SnackBar(
      content: Text(t == null ? '이미 받는 중이거나 받을 수 없는 주소입니다.' : '다운로드 추가: ${_title.isEmpty ? _url : _title}'),
      action: t == null
          ? null
          : SnackBarAction(
              label: '목록 보기',
              onPressed: () => Navigator.push(
                  context, MaterialPageRoute<void>(builder: (_) => DownloadsPage(d: widget.downloads!))),
            ),
    ));
  }

  void _openExternal(String url) =>
      widget.c.services.shell.openUrl(url, browser: widget.c.settings.externalBrowser);

  // ───────── 즐겨찾기 ─────────

  Future<void> _star() async {
    final existing = bm.tree.findByUrl(_url);
    if (existing != null) {
      await editBookmark(context, bm, existing);
      return;
    }
    final n = bm.addLink(_title.isEmpty ? _url : _title, _url);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('즐겨찾기 표시줄에 추가: ${n.title}'),
      action: SnackBarAction(label: '수정', onPressed: () => editBookmark(context, bm, n)),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyL, control: true): () {
          _addressFocus.requestFocus();
          _address.selection = TextSelection(baseOffset: 0, extentOffset: _address.text.length);
        },
        const SingleActivator(LogicalKeyboardKey.f5): () => _nav?.reload(),
        const SingleActivator(LogicalKeyboardKey.keyD, control: true): _star,
        const SingleActivator(LogicalKeyboardKey.keyB, control: true, shift: true): () =>
            setState(() => _panel = !_panel),
        const SingleActivator(LogicalKeyboardKey.keyJ, control: true, shift: true): _toggleWork,
        const SingleActivator(LogicalKeyboardKey.arrowLeft, alt: true): () => _nav?.back(),
        const SingleActivator(LogicalKeyboardKey.arrowRight, alt: true): () => _nav?.forward(),
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          body: ListenableBuilder(
            listenable: Listenable.merge([bm, widget.c]),
            builder: (context, _) => Column(children: [
              _toolbar(),
              Expanded(child: Row(children: [
              if (_panel)
                SizedBox(
                  width: 320,
                  child: BookmarkPanel(
                    bm: bm,
                    currentUrl: _url,
                    currentTitle: _title,
                    onOpen: (u) => _go(u),
                    onOpenExternal: _openExternal,
                    onClose: () => setState(() => _panel = false),
                  ),
                ),
              if (_panel) const VerticalDivider(width: 1),
              Expanded(
                child: Column(children: [
                  _BookmarkBar(bm: bm, onOpen: _go, onOpenExternal: _openExternal),
                  SizedBox(
                    height: 2,
                    child: _progress < 1 ? LinearProgressIndicator(value: _progress) : null,
                  ),
                  Expanded(
                    child: widget.viewBuilder?.call(_host, _url) ??
                        _EdgeView(host: _host, initialUrl: _url, dataDir: widget.c.settings.webViewDataDir),
                  ),
                ]),
              ),
              if (_work) ...[
                _SplitHandle(onDrag: (dx) => setState(() {
                  final max = MediaQuery.sizeOf(context).width - 400;
                  _workWidth = (_workWidth - dx).clamp(260.0, max < 260 ? 260.0 : max);
                })),
                SizedBox(
                  width: _workWidth,
                  child: WorkPanel(
                    c: widget.c,
                    downloads: widget.downloads,
                    onClose: _toggleWork,
                    onOpenHome: () => Navigator.maybePop(context),
                  ),
                ),
              ],
              ])),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _toolbar() {
    final starred = bm.tree.findByUrl(_url) != null;
    IconButton btn(IconData i, String tip, VoidCallback? f, {Color? color}) => IconButton(
          tooltip: tip,
          visualDensity: VisualDensity.compact,
          icon: Icon(i, size: 20, color: color),
          onPressed: f,
        );
    return Container(
      height: appBarHeight,
      color: JjColors.panel,
      padding: const EdgeInsets.only(left: 6, right: appBarRightPadding),
      child: Row(children: [
        btn(Icons.video_library_outlined, 'MKV 화면으로', () => Navigator.maybePop(context), color: JjColors.accent),
        const SizedBox(width: 4),
        btn(Icons.arrow_back, '뒤로 (Alt+←)', _canBack ? () => _nav?.back() : null),
        btn(Icons.arrow_forward, '앞으로 (Alt+→)', _canFwd ? () => _nav?.forward() : null),
        _progress < 1
            ? btn(Icons.close, '중지', () => _nav?.stop())
            : btn(Icons.refresh, '새로고침 (F5)', () => _nav?.reload()),
        btn(Icons.home_outlined, '홈', () => _go(widget.c.settings.homeUrl)),
        const SizedBox(width: 6),
        Expanded(
          child: TextField(
            controller: _address,
            focusNode: _addressFocus,
            style: const TextStyle(fontSize: 13),
            decoration: InputDecoration(
              isDense: true,
              filled: true,
              fillColor: JjColors.bg,
              hintText: '주소 입력 또는 검색 (Ctrl+L)',
              prefixIcon: Icon(_url.startsWith('https') ? Icons.lock_outline : Icons.public, size: 16),
              prefixIconConstraints: const BoxConstraints(minWidth: 32),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(18), borderSide: BorderSide.none),
              suffixIcon: IconButton(
                tooltip: starred ? '즐겨찾기 수정 (Ctrl+D)' : '즐겨찾기 추가 (Ctrl+D)',
                icon: Icon(starred ? Icons.star : Icons.star_border, size: 18,
                    color: starred ? Colors.amber : JjColors.textDim),
                onPressed: _star,
              ),
            ),
            onSubmitted: _go,
          ),
        ),
        const SizedBox(width: 8),
        FilledButton.icon(
          onPressed: _canDownload ? _download : null,
          icon: const Icon(Icons.download, size: 18),
          label: const Text('다운로드'),
        ),
        const SizedBox(width: 4),
        btn(Icons.open_in_new, '외부 브라우저로 열기', () => _openExternal(_url)),
        if (widget.c.busy && !_work)
          InkWell(
            onTap: _toggleWork,
            borderRadius: BorderRadius.circular(6),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
              child: JobIndicator(c: widget.c, compact: true),
            ),
          ),
        btn(_work ? Icons.view_sidebar : Icons.view_sidebar_outlined, '작업 현황 보기 · 화면 분할 (Ctrl+Shift+J)',
            _toggleWork, color: widget.c.busy ? JjColors.accent : null),
        btn(_panel ? Icons.bookmarks : Icons.bookmarks_outlined, '즐겨찾기 관리 (Ctrl+Shift+B)',
            () => setState(() => _panel = !_panel)),
        AppActions(c: widget.c),
      ]),
    );
  }
}

/// 브라우저 ↔ 작업 현황 사이 끌어서 너비 바꾸는 막대
class _SplitHandle extends StatelessWidget {
  final ValueChanged<double> onDrag;
  const _SplitHandle({required this.onDrag});

  @override
  Widget build(BuildContext context) => MouseRegion(
        cursor: SystemMouseCursors.resizeColumn,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onHorizontalDragUpdate: (d) => onDrag(d.delta.dx),
          child: Container(
            width: 6,
            color: JjColors.bg,
            alignment: Alignment.center,
            child: Container(width: 1, color: JjColors.border),
          ),
        ),
      );
}

// ───────── 앱 안 Edge 웹뷰 ─────────

class _EdgeView extends StatefulWidget {
  final BrowserHost host;
  final String initialUrl;
  final String dataDir;
  const _EdgeView({required this.host, required this.initialUrl, required this.dataDir});

  @override
  State<_EdgeView> createState() => _EdgeViewState();
}

Future<WebViewEnvironment?>? _env;

/// 로그인 · 쿠키가 유지되는 데이터 폴더를 쓰는 브라우저 환경 (한 번만 만들어 재사용)
Future<WebViewEnvironment?> browserEnvironment(String dir) =>
    _env ??= Platform.isWindows
        ? WebViewEnvironment.create(settings: WebViewEnvironmentSettings(userDataFolder: dir.isEmpty ? null : dir))
        : Future.value(null);

class _EdgeViewState extends State<_EdgeView> {
  @override
  Widget build(BuildContext context) => FutureBuilder<WebViewEnvironment?>(
        future: browserEnvironment(widget.dataDir),
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
            return Center(
              child: Text('웹 브라우저(Edge WebView2)를 시작할 수 없습니다.\n${snap.error}',
                  textAlign: TextAlign.center),
            );
          }
          final h = widget.host;
          Future<void> check(InAppWebViewController c) async {
            h.onHistory(await c.canGoBack(), await c.canGoForward());
            try {
              final n = await c.evaluateJavascript(source: "document.querySelectorAll('video').length");
              h.onVideo((n is num ? n : int.tryParse('$n') ?? 0) > 0);
            } catch (_) {}
          }

          return InAppWebView(
            webViewEnvironment: snap.data,
            initialUrlRequest: URLRequest(url: WebUri(normalizeAddress(widget.initialUrl))),
            initialSettings: InAppWebViewSettings(
              javaScriptEnabled: true,
              mediaPlaybackRequiresUserGesture: false,
              supportMultipleWindows: false,
            ),
            onWebViewCreated: (c) => h.attach(_InAppNav(c, snap.data, widget.dataDir)),
            onLoadStart: (c, u) {
              h.onUrl(u?.toString() ?? '');
              h.onVideo(false);
            },
            onLoadStop: (c, u) async {
              h.onUrl(u?.toString() ?? '');
              h.onProgress(1);
              await check(c);
              // YouTube · Google 페이지를 보면 로그인 쿠키를 내보내 둔다 (다운로드에 사용)
              final host = u?.host ?? '';
              if (host.endsWith('youtube.com') || host.endsWith('google.com')) {
                try {
                  await _InAppNav(c, snap.data, widget.dataDir).exportCookies();
                } catch (_) {}
              }
            },
            // YouTube 처럼 페이지 이동 없이 주소만 바뀌는 사이트
            onUpdateVisitedHistory: (c, u, _) async {
              h.onUrl(u?.toString() ?? '');
              await Future<void>.delayed(const Duration(milliseconds: 800));
              await check(c);
            },
            onTitleChanged: (c, t) => h.onTitle(t ?? ''),
            onProgressChanged: (c, p) => h.onProgress(p / 100),
          );
        },
      );
}

class _InAppNav implements WebNav {
  final InAppWebViewController c;
  final WebViewEnvironment? env;
  final String dataDir;
  _InAppNav(this.c, this.env, this.dataDir);

  static const _cookieSites = [
    'https://www.youtube.com/',
    'https://m.youtube.com/',
    'https://accounts.google.com/',
    'https://www.google.com/',
  ];

  @override
  Future<void> exportCookies() async {
    if (dataDir.isEmpty) return;
    final cm = CookieManager.instance(webViewEnvironment: env);
    final all = <CookieRecord>[];
    for (final site in _cookieSites) {
      for (final k in await cm.getCookies(url: WebUri(site))) {
        // 만료 시각: Windows 는 초, Android 등은 밀리초로 준다 → 초로 통일
        final raw = k.expiresDate ?? 0;
        final exp = raw > 100000000000 ? raw ~/ 1000 : raw;
        all.add(CookieRecord(
          name: k.name,
          value: '${k.value ?? ''}',
          domain: k.domain ?? Uri.parse(site).host,
          path: k.path ?? '/',
          expires: (k.isSessionOnly ?? false) || exp <= 0 ? 0 : exp,
          secure: k.isSecure ?? false,
          httpOnly: k.isHttpOnly ?? false,
        ));
      }
    }
    if (all.isEmpty) return;
    // 임시 파일에 다 쓴 뒤 한 번에 바꿔 넣는다 (yt-dlp 가 쓰는 도중의 파일을 읽지 않도록)
    final target = '$dataDir${Platform.pathSeparator}cookies_youtube.txt';
    final tmp = File('$target.tmp');
    await tmp.parent.create(recursive: true);
    await tmp.writeAsString(toNetscapeCookies(all), flush: true);
    await tmp.rename(target);
  }
  @override
  Future<void> load(String url) => c.loadUrl(urlRequest: URLRequest(url: WebUri(url)));
  @override
  Future<void> back() => c.goBack();
  @override
  Future<void> forward() => c.goForward();
  @override
  Future<void> reload() => c.reload();
  @override
  Future<void> stop() => c.stopLoading();
}

// ───────── 즐겨찾기 표시줄 (주소창 아래) ─────────

class _BookmarkBar extends StatelessWidget {
  final BookmarksController bm;
  final void Function(String url) onOpen;
  final void Function(String url) onOpenExternal;
  const _BookmarkBar({required this.bm, required this.onOpen, required this.onOpenExternal});

  @override
  Widget build(BuildContext context) {
    final items = bm.tree.bar.children!;
    return Container(
      height: 32,
      color: JjColors.panel,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: items.isEmpty
          ? const Align(
              alignment: Alignment.centerLeft,
              child: Text('  ☆ 를 누르면 여기에 즐겨찾기가 추가됩니다',
                  style: TextStyle(fontSize: 11, color: JjColors.textDim)),
            )
          : ListView(
              scrollDirection: Axis.horizontal,
              children: [for (final n in items) _barItem(context, n)],
            ),
    );
  }

  Widget _barItem(BuildContext context, BookmarkNode n) {
    final label = n.title.length > 24 ? '${n.title.substring(0, 23)}…' : n.title;
    if (n.isFolder) {
      return MenuAnchor(
        menuChildren: _folderMenu(n),
        builder: (context, ctl, _) => TextButton.icon(
          onPressed: () => ctl.isOpen ? ctl.close() : ctl.open(),
          icon: const Icon(Icons.folder_outlined, size: 15),
          label: Text(label, style: const TextStyle(fontSize: 12)),
        ),
      );
    }
    return GestureDetector(
      onSecondaryTapDown: (d) => _itemMenu(context, n, d.globalPosition),
      child: Tooltip(
        message: '${n.title}\n${n.url}',
        waitDuration: const Duration(milliseconds: 600),
        child: TextButton.icon(
          onPressed: () => onOpen(n.url!),
          icon: const Icon(Icons.public, size: 14),
          label: Text(label, style: const TextStyle(fontSize: 12)),
        ),
      ),
    );
  }

  List<Widget> _folderMenu(BookmarkNode f) => [
        if (f.children!.isEmpty) const MenuItemButton(child: Text('(비어 있음)')),
        for (final c in f.children!)
          c.isFolder
              ? SubmenuButton(
                  leadingIcon: const Icon(Icons.folder_outlined, size: 16),
                  menuChildren: _folderMenu(c),
                  child: Text(c.title),
                )
              : MenuItemButton(
                  leadingIcon: const Icon(Icons.public, size: 16),
                  onPressed: () => onOpen(c.url!),
                  child: Text(c.title),
                ),
      ];

  Future<void> _itemMenu(BuildContext context, BookmarkNode n, Offset at) async {
    final r = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(at.dx, at.dy, at.dx, at.dy),
      items: const [
        PopupMenuItem(value: 'open', child: Text('열기')),
        PopupMenuItem(value: 'ext', child: Text('외부 브라우저로 열기')),
        PopupMenuDivider(),
        PopupMenuItem(value: 'edit', child: Text('수정')),
        PopupMenuItem(value: 'del', child: Text('삭제')),
      ],
    );
    if (!context.mounted) return;
    switch (r) {
      case 'open':
        onOpen(n.url!);
      case 'ext':
        onOpenExternal(n.url!);
      case 'edit':
        await editBookmark(context, bm, n);
      case 'del':
        removeBookmarkWithUndo(context, bm, n);
    }
  }
}

// ───────── 즐겨찾기 관리 패널 (Chrome 즐겨찾기 관리자 참고) ─────────

class BookmarkPanel extends StatefulWidget {
  final BookmarksController bm;
  final String currentUrl;
  final String currentTitle;
  final void Function(String url) onOpen;
  final void Function(String url) onOpenExternal;
  final VoidCallback onClose;

  const BookmarkPanel({
    super.key,
    required this.bm,
    required this.currentUrl,
    required this.currentTitle,
    required this.onOpen,
    required this.onOpenExternal,
    required this.onClose,
  });

  @override
  State<BookmarkPanel> createState() => _BookmarkPanelState();
}

class _BookmarkPanelState extends State<BookmarkPanel> {
  String _folderId = BookmarkTree.barId;

  BookmarksController get bm => widget.bm;

  List<BookmarkNode> _path() {
    final out = <BookmarkNode>[];
    var id = _folderId;
    while (true) {
      final n = bm.tree.find(id);
      if (n == null) break;
      out.insert(0, n);
      final parent = bm.tree.parentOf(id);
      if (parent == null) break;
      id = parent.id;
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final folder = bm.tree.find(_folderId) ?? bm.tree.bar;
    final items = folder.children!;
    return Material(
      color: JjColors.panel,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 4, 0),
          child: Row(children: [
            const Icon(Icons.bookmarks_outlined, size: 18, color: JjColors.accent),
            const SizedBox(width: 6),
            const Text('즐겨찾기', style: TextStyle(fontWeight: FontWeight.w600)),
            const Spacer(),
            IconButton(tooltip: '닫기', iconSize: 18, icon: const Icon(Icons.close), onPressed: widget.onClose),
          ]),
        ),
        // 최상위 폴더 선택
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Wrap(spacing: 4, children: [
            for (final r in bm.tree.roots)
              ChoiceChip(
                label: Text(r.title, style: const TextStyle(fontSize: 11)),
                selected: _path().first.id == r.id,
                onSelected: (_) => setState(() => _folderId = r.id),
              ),
          ]),
        ),
        // 현재 폴더 경로
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
          child: Wrap(crossAxisAlignment: WrapCrossAlignment.center, children: [
            for (final (i, n) in _path().indexed) ...[
              if (i > 0) const Icon(Icons.chevron_right, size: 14, color: JjColors.textDim),
              InkWell(
                onTap: () => setState(() => _folderId = n.id),
                child: Padding(
                  padding: const EdgeInsets.all(2),
                  child: Text(n.title,
                      style: TextStyle(fontSize: 12, color: n.id == _folderId ? JjColors.text : JjColors.accent)),
                ),
              ),
            ],
          ]),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Wrap(spacing: 4, runSpacing: 4, children: [
            OutlinedButton.icon(
              onPressed: widget.currentUrl.startsWith('http')
                  ? () => bm.addLink(widget.currentTitle.isEmpty ? widget.currentUrl : widget.currentTitle,
                      widget.currentUrl,
                      parentId: _folderId)
                  : null,
              icon: const Icon(Icons.add, size: 16),
              label: const Text('현재 페이지', style: TextStyle(fontSize: 12)),
            ),
            OutlinedButton.icon(
              onPressed: () async {
                final name = await _ask(context, '새 폴더', '폴더 이름', '새 폴더');
                if (name != null) bm.addFolder(name, parentId: _folderId);
              },
              icon: const Icon(Icons.create_new_folder_outlined, size: 16),
              label: const Text('폴더', style: TextStyle(fontSize: 12)),
            ),
            PopupMenuButton<String>(
              tooltip: '다른 브라우저의 즐겨찾기 가져오기',
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'chrome', child: Text('Chrome 에서 가져오기')),
                PopupMenuItem(value: 'edge', child: Text('Edge 에서 가져오기')),
                PopupMenuItem(value: 'whale', child: Text('Whale 에서 가져오기')),
              ],
              onSelected: (b) async {
                final n = await bm.importFrom(b);
                if (!context.mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                    content: Text(n < 0
                        ? '이 브라우저의 즐겨찾기 파일을 찾지 못했습니다.'
                        : '$n개를 "기타 즐겨찾기" 에 가져왔습니다.')));
                if (n > 0) setState(() => _folderId = BookmarkTree.otherId);
              },
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.download_for_offline_outlined, size: 16),
                  SizedBox(width: 4),
                  Text('가져오기', style: TextStyle(fontSize: 12)),
                ]),
              ),
            ),
          ]),
        ),
        const Divider(height: 12),
        Expanded(
          child: items.isEmpty
              ? const Center(child: Text('비어 있는 폴더', style: TextStyle(color: JjColors.textDim)))
              : ReorderableListView.builder(
                  buildDefaultDragHandles: false,
                  itemCount: items.length,
                  onReorderItem: (o, n) => bm.reorder(folder.id, o, n),
                  itemBuilder: (_, i) {
                    final n = items[i];
                    return ListTile(
                      key: ValueKey(n.id),
                      dense: true,
                      leading: ReorderableDragStartListener(
                        index: i,
                        child: Icon(n.isFolder ? Icons.folder : Icons.public,
                            size: 18, color: n.isFolder ? Colors.amber : JjColors.textDim),
                      ),
                      title: Text(n.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: n.isFolder
                          ? Text('${n.children!.length}개', style: const TextStyle(fontSize: 11))
                          : Text(n.url!, maxLines: 1, overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 11)),
                      onTap: () => n.isFolder ? setState(() => _folderId = n.id) : widget.onOpen(n.url!),
                      trailing: PopupMenuButton<String>(
                        tooltip: '더 보기',
                        iconSize: 18,
                        itemBuilder: (_) => [
                          if (!n.isFolder) const PopupMenuItem(value: 'ext', child: Text('외부 브라우저로 열기')),
                          const PopupMenuItem(value: 'edit', child: Text('수정')),
                          const PopupMenuItem(value: 'move', child: Text('다른 폴더로 이동')),
                          if (i > 0) const PopupMenuItem(value: 'up', child: Text('위로')),
                          if (i < items.length - 1) const PopupMenuItem(value: 'down', child: Text('아래로')),
                          const PopupMenuDivider(),
                          const PopupMenuItem(value: 'del', child: Text('삭제')),
                        ],
                        onSelected: (v) async {
                          switch (v) {
                            case 'ext':
                              widget.onOpenExternal(n.url!);
                            case 'edit':
                              await editBookmark(context, bm, n);
                            case 'move':
                              await _moveTo(context, n);
                            case 'up':
                              bm.move(n.id, folder.id, i - 1);
                            case 'down':
                              bm.move(n.id, folder.id, i + 2);
                            case 'del':
                              removeBookmarkWithUndo(context, bm, n);
                          }
                        },
                      ),
                    );
                  },
                ),
        ),
        const Padding(
          padding: EdgeInsets.all(8),
          child: Text('왼쪽 아이콘을 끌어 순서를 바꿉니다',
              textAlign: TextAlign.center, style: TextStyle(fontSize: 11, color: JjColors.textDim)),
        ),
      ]),
    );
  }

  Future<void> _moveTo(BuildContext context, BookmarkNode n) async {
    final target = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text('"${n.title}" 이동'),
        children: [
          for (final (f, depth) in bm.tree.folders())
            if (f.id != n.id && !bm.tree.isInside(f.id, n.id))
              SimpleDialogOption(
                onPressed: () => Navigator.pop(ctx, f.id),
                child: Padding(
                  padding: EdgeInsets.only(left: depth * 16.0),
                  child: Row(children: [
                    const Icon(Icons.folder_outlined, size: 16),
                    const SizedBox(width: 6),
                    Text(f.title),
                  ]),
                ),
              ),
        ],
      ),
    );
    if (target != null) {
      final dest = bm.tree.find(target)!;
      bm.move(n.id, target, dest.children!.length);
    }
  }
}

// ───────── 공용 대화상자 ─────────

Future<String?> _ask(BuildContext context, String title, String label, String initial) async {
  final ctrl = TextEditingController(text: initial);
  final r = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: ctrl,
        autofocus: true,
        decoration: InputDecoration(labelText: label, border: const OutlineInputBorder()),
        onSubmitted: (t) => Navigator.pop(ctx, t),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('취소')),
        FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text), child: const Text('확인')),
      ],
    ),
  );
  await Future<void>.delayed(const Duration(milliseconds: 300)); // 닫히는 애니메이션 뒤 정리
  ctrl.dispose();
  return r;
}

/// 즐겨찾기 수정 (이름 · 주소, 삭제)
Future<void> editBookmark(BuildContext context, BookmarksController bm, BookmarkNode n) async {
  final title = TextEditingController(text: n.title);
  final url = TextEditingController(text: n.url ?? '');
  final r = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(n.isFolder ? '폴더 수정' : '즐겨찾기 수정'),
      content: SizedBox(
        width: 420,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
              controller: title,
              autofocus: true,
              decoration: const InputDecoration(labelText: '이름', border: OutlineInputBorder())),
          if (!n.isFolder) ...[
            const SizedBox(height: 12),
            TextField(controller: url, decoration: const InputDecoration(labelText: '주소', border: OutlineInputBorder())),
          ],
        ]),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, 'del'),
          child: const Text('삭제', style: TextStyle(color: JjColors.danger)),
        ),
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('취소')),
        FilledButton(onPressed: () => Navigator.pop(ctx, 'save'), child: const Text('저장')),
      ],
    ),
  );
  if (r == 'save') bm.update(n.id, title: title.text, url: n.isFolder ? null : url.text);
  if (r == 'del' && context.mounted) removeBookmarkWithUndo(context, bm, n);
  await Future<void>.delayed(const Duration(milliseconds: 300));
  title.dispose();
  url.dispose();
}

/// 삭제 + "실행 취소"
void removeBookmarkWithUndo(BuildContext context, BookmarksController bm, BookmarkNode n) {
  if (!bm.remove(n.id)) return;
  // 되돌리기는 바로 보여야 하므로 앞서 떠 있던 알림은 치운다
  ScaffoldMessenger.of(context)
    ..clearSnackBars()
    ..showSnackBar(SnackBar(
    content: Text('삭제: ${n.title}'),
    action: SnackBarAction(label: '실행 취소', onPressed: bm.undoRemove),
  ));
}
