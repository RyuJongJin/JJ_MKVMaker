import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:path/path.dart' as p;
import 'package:webview_cef/webview_cef.dart' as cef;

import '../app/app_controller.dart';
import '../app/bookmarks_controller.dart';
import '../app/download_manager.dart';
import '../core/bookmarks.dart';
import '../core/download_detect.dart' show CookieRecord, toNetscapeCookies;
import '../core/web_address.dart';
import '../platform/windows/cef_runtime.dart';
import '../platform/windows/com_guard.dart';
import 'app_actions.dart';
import 'bookmark_ui.dart';
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

  /// 즐겨찾기 관리자 (전체 화면, Ctrl+Shift+O)
  void _openManager({String? folderId}) => Navigator.push(
        context,
        MaterialPageRoute<void>(
          builder: (_) => BookmarkManagerPage(
            bm: bm,
            onOpen: _go,
            onOpenExternal: _openExternal,
            currentUrl: _url.startsWith('http') ? _url : '',
            currentTitle: _title,
            initialFolderId: folderId,
          ),
        ),
      );

  Future<void> _star() async {
    final existing = bm.tree.findByUrl(_url);
    if (existing != null) {
      await editBookmark(context, bm, existing);
      return;
    }
    final n = bm.addLink(_title.isEmpty ? _url : _title, _url);
    if (!mounted) return;
    await showBookmarkEditor(context, bm, n, justAdded: true);
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
        const SingleActivator(LogicalKeyboardKey.keyO, control: true, shift: true): _openManager,
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
                    onOpenManager: _openManager,
                    onClose: () => setState(() => _panel = false),
                  ),
                ),
              if (_panel) const VerticalDivider(width: 1),
              Expanded(
                child: Column(children: [
                  _BookmarkBar(
                    bm: bm,
                    onOpen: _go,
                    onOpenExternal: _openExternal,
                    currentUrl: _url,
                    currentTitle: _title,
                    onOpenManager: _openManager,
                  ),
                  SizedBox(
                    height: 2,
                    child: _progress < 1 ? LinearProgressIndicator(value: _progress) : null,
                  ),
                  Expanded(
                    child: widget.viewBuilder?.call(_host, _url) ??
                        // 환경 설정에서 Chrome 을 고르고 엔진이 이번 실행에 준비되어 있으면 Chrome, 아니면 Edge
                        (widget.c.settings.browserEngine == 'chrome' && CefRuntime.readyThisRun
                            ? _CefView(host: _host, initialUrl: _url, dataDir: widget.c.settings.webViewDataDir)
                            : _EdgeView(host: _host, initialUrl: _url, dataDir: widget.c.settings.webViewDataDir)),
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
      padding: const EdgeInsets.only(left: 8, right: appBarRightPadding),
      child: Row(children: [
        const AppNavButtons(),
        const SizedBox(width: 8),
        Container(width: 1, height: 24, color: JjColors.border),
        const SizedBox(width: 4),
        // 웹 페이지 이동 (앱 화면 이동인 왼쪽 버튼과 구분되는 모양)
        btn(Icons.arrow_back_ios_new, '이전 페이지 (Alt+←)', _canBack ? () => _nav?.back() : null),
        btn(Icons.arrow_forward_ios, '다음 페이지 (Alt+→)', _canFwd ? () => _nav?.forward() : null),
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
    _env ??= Platform.isWindows ? _createEnvironment(dir) : Future.value(null);

Future<WebViewEnvironment?> _createEnvironment(String dir) async {
  Future<WebViewEnvironment> create() =>
      WebViewEnvironment.create(settings: WebViewEnvironmentSettings(userDataFolder: dir.isEmpty ? null : dir));
  try {
    // COM 이 풀려 있으면 "CoInitialize 가 호출되지 않았습니다" 로 실패한다 → 만들기 전에 다시 준비
    ComGuard.ensure();
    try {
      return await create();
    } catch (_) {
      ComGuard.ensure();
      return await create();
    }
  } catch (_) {
    // 실패한 결과를 붙들고 있지 않는다: 브라우저를 다시 열면 새로 시도
    _env = null;
    rethrow;
  }
}

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

// ───────── 앱 안 Chrome (CEF) ─────────

/// 내장 Chrome 엔진 (환경 설정에서 고르고 내려받은 경우). 기능은 Edge 화면과 같다:
/// 주소 · 제목 · 진행 · 동영상 페이지 판별 · 뒤로 / 앞으로 · YouTube 쿠키를 yt-dlp 용으로 내보내기.
class _CefView extends StatefulWidget {
  final BrowserHost host;
  final String initialUrl;
  final String dataDir;
  const _CefView({required this.host, required this.initialUrl, required this.dataDir});

  @override
  State<_CefView> createState() => _CefViewState();
}

/// Chrome 엔진 시작은 프로그램이 켜져 있는 동안 한 번만
Future<void>? _cefStarted;

class _CefViewState extends State<_CefView> {
  late final cef.WebViewController _c = cef.WebviewManager().createWebView(
      loading: const Center(child: CircularProgressIndicator()));
  Object? _error;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    final h = widget.host;
    try {
      // 로그인 · 쿠키를 Edge 와 따로 보관 (데이터 폴더 아래 cef)
      _cefStarted ??= cef.WebviewManager()
          .initialize(rootCachePath: widget.dataDir.isEmpty ? null : p.join(p.dirname(widget.dataDir), 'cef'));
      await _cefStarted;
      _c.setWebviewListener(cef.WebviewEventsListener(
        onUrlChanged: (u) {
          h.onUrl(u);
          // YouTube 처럼 페이지 이동 없이 주소만 바뀌는 사이트
          Future<void>.delayed(const Duration(milliseconds: 800), _check);
        },
        onTitleChanged: h.onTitle,
        // 읽기 시작 · 끝 (본문만 - packages/webview_cef/JJ_PATCH.md 3)
        onLoadStart: (_, u) {
          if (u.startsWith('http')) h.onUrl(u);
          h.onProgress(0.1);
          h.onVideo(false);
        },
        onLoadEnd: (_, u) async {
          h.onProgress(1);
          await _check();
          final host = Uri.tryParse(u)?.host ?? '';
          if (host.endsWith('youtube.com') || host.endsWith('google.com')) {
            try {
              await _CefNav(_c, widget.dataDir).exportCookies();
            } catch (_) {}
          }
        },
      ));
      await _c.initialize(normalizeAddress(widget.initialUrl));
      h.attach(_CefNav(_c, widget.dataDir));
      h.onHistory(true, true); // Chrome 엔진은 뒤로 · 앞으로 가능 여부를 알려 주지 않는다
      if (mounted) setState(() {});
    } catch (e) {
      // ignore: avoid_print
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _check() async {
    try {
      final n = await _c.evaluateJavascript("document.querySelectorAll('video').length");
      widget.host.onVideo((n is num ? n : int.tryParse('$n') ?? 0) > 0);
    } catch (_) {}
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Center(
        child: Text('Chrome 엔진을 시작할 수 없습니다. 환경 설정에서 Edge 로 바꿔 쓰세요.\n$_error',
            textAlign: TextAlign.center),
      );
    }
    return ValueListenableBuilder<bool>(
      valueListenable: _c,
      builder: (_, ready, _) => ready ? _c.webviewWidget : _c.loadingWidget,
    );
  }
}

class _CefNav implements WebNav {
  final cef.WebViewController c;
  final String dataDir;
  _CefNav(this.c, this.dataDir);

  /// YouTube · Google 쿠키를 yt-dlp 용 cookies.txt 로 (Edge 와 같은 파일 - 지금 쓰는 엔진의 로그인이 쓰인다).
  /// Chrome 엔진은 쿠키의 이름 · 값만 알려 주므로 만료 · 보안 표시는 기본값으로 적는다.
  @override
  Future<void> exportCookies() async {
    if (dataDir.isEmpty) return;
    final raw = await cef.WebviewManager().visitAllCookies();
    if (raw is! Map) return;
    final all = <CookieRecord>[];
    final later = DateTime.now().add(const Duration(days: 30)).millisecondsSinceEpoch ~/ 1000;
    raw.forEach((domain, cookies) {
      final d = '$domain';
      if (!(d.endsWith('youtube.com') || d.endsWith('google.com')) || cookies is! Map) return;
      cookies.forEach((name, value) => all.add(CookieRecord(
          name: '$name', value: '$value', domain: d, expires: later, secure: true)));
    });
    if (all.isEmpty) return;
    final target = '$dataDir${Platform.pathSeparator}cookies_youtube.txt';
    final tmp = File('$target.tmp');
    await tmp.parent.create(recursive: true);
    await tmp.writeAsString(toNetscapeCookies(all), flush: true);
    await tmp.rename(target);
  }

  @override
  Future<void> load(String url) => c.loadUrl(url);
  @override
  Future<void> back() => c.goBack();
  @override
  Future<void> forward() => c.goForward();
  @override
  Future<void> reload() => c.reload();
  @override
  Future<void> stop() async {} // Chrome 엔진에는 멈춤이 없다
}

// ───────── 즐겨찾기 표시줄 (주소창 아래) ─────────

class _BookmarkBar extends StatelessWidget {
  final BookmarksController bm;
  final void Function(String url) onOpen;
  final void Function(String url) onOpenExternal;
  final String currentUrl;
  final String currentTitle;
  final void Function({String? folderId}) onOpenManager;
  const _BookmarkBar({
    required this.bm,
    required this.onOpen,
    required this.onOpenExternal,
    this.currentUrl = '',
    this.currentTitle = '',
    required this.onOpenManager,
  });

  void _menu(BuildContext context, Offset at, [BookmarkNode? n]) => showBookmarkMenu(context,
      bm: bm,
      globalPosition: at,
      n: n,
      folderId: BookmarkTree.barId,
      onOpen: onOpen,
      onOpenExternal: onOpenExternal,
      currentUrl: currentUrl,
      currentTitle: currentTitle,
      onOpenManager: () => onOpenManager(folderId: n != null && n.isFolder ? n.id : null));

  @override
  Widget build(BuildContext context) {
    final items = bm.tree.bar.children!;
    // 빈 곳: 오른쪽 클릭 메뉴 (페이지 · 폴더 추가, 관리자), 다른 폴더의 즐겨찾기를 끌어다 놓으면 표시줄 맨 뒤로
    return DragTarget<BookmarkDrag>(
      onWillAcceptWithDetails: (d) => bm.canMoveInto(d.data.id, BookmarkTree.barId),
      onAcceptWithDetails: (d) => bm.moveInto(d.data.id, BookmarkTree.barId),
      builder: (context, _, _) => GestureDetector(
        behavior: HitTestBehavior.opaque,
        onSecondaryTapDown: (d) => _menu(context, d.globalPosition),
        child: Container(
          height: 32,
          color: JjColors.panel,
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: items.isEmpty
              ? const Align(
                  alignment: Alignment.centerLeft,
                  child: Text('  ☆ 를 누르면 여기에 즐겨찾기가 추가됩니다 · 오른쪽 클릭: 폴더 추가',
                      style: TextStyle(fontSize: 11, color: JjColors.textDim)),
                )
              : ListView(
                  scrollDirection: Axis.horizontal,
                  children: [for (final (i, n) in items.indexed) _barItem(context, n, i)],
                ),
        ),
      ),
    );
  }

  Widget _barItem(BuildContext context, BookmarkNode n, int index) {
    final label = n.title.length > 24 ? '${n.title.substring(0, 23)}…' : n.title;
    final Widget button;
    if (n.isFolder) {
      // 폴더: 누르면 내용 (하위 폴더는 옆으로 펼침), 즐겨찾기를 끌어다 놓으면 그 안으로
      button = BookmarkFolderDrop(
        bm: bm,
        folderId: n.id,
        child: MenuAnchor(
          menuChildren: _folderMenu(context, n),
          builder: (context, ctl, _) => TextButton.icon(
            onPressed: () => ctl.isOpen ? ctl.close() : ctl.open(),
            icon: const Icon(Icons.folder, size: 15, color: Colors.amber),
            label: Text(label, style: const TextStyle(fontSize: 12)),
          ),
        ),
      );
    } else {
      // 주소: 다른 즐겨찾기를 이 위에 놓으면 그 자리 (앞) 로 옮긴다
      button = DragTarget<BookmarkDrag>(
        onWillAcceptWithDetails: (d) => d.data.id != n.id && bm.canMoveInto(d.data.id, BookmarkTree.barId),
        onAcceptWithDetails: (d) => bm.move(d.data.id, BookmarkTree.barId, index),
        builder: (context, cand, _) => Container(
          decoration: BoxDecoration(
            border: Border(left: BorderSide(color: cand.isNotEmpty ? JjColors.accent : Colors.transparent, width: 2)),
          ),
          child: Tooltip(
            message: '${n.title}\n${n.url}',
            waitDuration: const Duration(milliseconds: 600),
            child: TextButton.icon(
              onPressed: () => onOpen(n.url!),
              icon: const Icon(Icons.public, size: 14),
              label: Text(label, style: const TextStyle(fontSize: 12)),
            ),
          ),
        ),
      );
    }
    return GestureDetector(
      onSecondaryTapDown: (d) => _menu(context, d.globalPosition, n),
      child: BookmarkDraggable(n: n, child: button),
    );
  }

  List<Widget> _folderMenu(BuildContext context, BookmarkNode f) => [
        if (f.children!.isEmpty) const MenuItemButton(child: Text('(비어 있음)')),
        for (final c in f.children!)
          c.isFolder
              ? SubmenuButton(
                  leadingIcon: const Icon(Icons.folder, size: 16, color: Colors.amber),
                  menuChildren: _folderMenu(context, c),
                  child: Text(c.title),
                )
              : MenuItemButton(
                  leadingIcon: const Icon(Icons.public, size: 16),
                  onPressed: () => onOpen(c.url!),
                  child: Text(c.title),
                ),
        const Divider(height: 8),
        MenuItemButton(
          leadingIcon: const Icon(Icons.bookmark_add_outlined, size: 16),
          onPressed: currentUrl.startsWith('http')
              ? () => bm.addLink(currentTitle.isEmpty ? currentUrl : currentTitle, currentUrl, parentId: f.id)
              : null,
          child: const Text('이 폴더에 현재 페이지 추가'),
        ),
        MenuItemButton(
          leadingIcon: const Icon(Icons.create_new_folder_outlined, size: 16),
          onPressed: () => showNewFolderDialog(context, bm, f.id),
          child: const Text('이 폴더에 새 폴더'),
        ),
        MenuItemButton(
          leadingIcon: const Icon(Icons.edit_outlined, size: 16),
          onPressed: () => showBookmarkEditor(context, bm, f),
          child: const Text('폴더 이름 바꾸기 · 이동'),
        ),
        MenuItemButton(
          leadingIcon: const Icon(Icons.bookmarks_outlined, size: 16),
          onPressed: () => onOpenManager(folderId: f.id),
          child: const Text('즐겨찾기 관리자에서 보기'),
        ),
      ];
}

// ───────── 즐겨찾기 관리 패널 (Chrome 즐겨찾기 관리자 참고) ─────────

class BookmarkPanel extends StatefulWidget {
  final BookmarksController bm;
  final String currentUrl;
  final String currentTitle;
  final void Function(String url) onOpen;
  final void Function(String url) onOpenExternal;
  final VoidCallback onClose;

  /// 즐겨찾기 관리자 (전체 화면) 열기
  final void Function({String? folderId})? onOpenManager;

  const BookmarkPanel({
    super.key,
    required this.bm,
    required this.currentUrl,
    required this.currentTitle,
    required this.onOpen,
    required this.onOpenExternal,
    required this.onClose,
    this.onOpenManager,
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
            if (widget.onOpenManager != null)
              IconButton(
                tooltip: '즐겨찾기 관리자 (Ctrl+Shift+O)',
                iconSize: 18,
                icon: const Icon(Icons.open_in_full),
                onPressed: () => widget.onOpenManager!(folderId: _folderId),
              ),
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
              BookmarkFolderDrop(
                bm: bm,
                folderId: n.id,
                child: InkWell(
                  onTap: () => setState(() => _folderId = n.id),
                  child: Padding(
                    padding: const EdgeInsets.all(2),
                    child: Text(n.title,
                        style: TextStyle(fontSize: 12, color: n.id == _folderId ? JjColors.text : JjColors.accent)),
                  ),
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
                await showNewFolderDialog(context, bm, _folderId);
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
                    final tile = ListTile(
                      dense: true,
                      leading: Row(mainAxisSize: MainAxisSize.min, children: [
                        ReorderableDragStartListener(
                          index: i,
                          child: const Icon(Icons.drag_indicator, size: 16, color: JjColors.textDim),
                        ),
                        const SizedBox(width: 4),
                        // 아이콘을 끌어 폴더 줄 · 위 경로에 놓으면 그 폴더로
                        BookmarkDraggable(
                          n: n,
                          child: Icon(n.isFolder ? Icons.folder : Icons.public,
                              size: 18, color: n.isFolder ? Colors.amber : JjColors.textDim),
                        ),
                      ]),
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
                    return KeyedSubtree(
                      key: ValueKey(n.id),
                      child: GestureDetector(
                        onSecondaryTapDown: (d) => showBookmarkMenu(context,
                            bm: bm,
                            globalPosition: d.globalPosition,
                            n: n,
                            folderId: folder.id,
                            onOpen: widget.onOpen,
                            onOpenExternal: widget.onOpenExternal,
                            currentUrl: widget.currentUrl,
                            currentTitle: widget.currentTitle),
                        child: n.isFolder ? BookmarkFolderDrop(bm: bm, folderId: n.id, child: tile) : tile,
                      ),
                    );
                  },
                ),
        ),
        const Padding(
          padding: EdgeInsets.all(8),
          child: Text('⋮⋮ 를 끌어 순서 바꾸기 · 아이콘을 끌어 폴더에 넣기 · 오른쪽 클릭 메뉴',
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

// ───────── 공용 (bookmark_ui.dart) ─────────

/// 즐겨찾기 수정 (이름 · 주소 · 폴더)
Future<void> editBookmark(BuildContext context, BookmarksController bm, BookmarkNode n) =>
    showBookmarkEditor(context, bm, n);
