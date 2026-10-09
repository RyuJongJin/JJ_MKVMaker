import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:path/path.dart' as p;
import 'package:webview_cef/webview_cef.dart' as cef;

import '../app/app_controller.dart';
import '../app/bookmarks_controller.dart';
import '../app/download_manager.dart';
import '../core/bookmarks.dart';
import '../core/download_detect.dart' show CookieExport, CookieRecord, internalBrowserCookies, isLoginCookieDomain, toNetscapeCookies;
import '../core/web_address.dart';
import '../core/web_translate.dart';
import '../app/i18n_controller.dart' show I18nController;
import '../core/youtube_ads.dart';
import '../platform/windows/cef_runtime.dart';
import '../platform/windows/com_guard.dart';
import '../services/downloader.dart' show DownloadState;
import 'app_actions.dart';
import 'bookmark_ui.dart';
import 'confirm.dart';
import 'downloads_page.dart';
import 'theme.dart';
import 'work_panel.dart';
import '../l10n/tr.dart';

/// 브라우저 조작 (앱 안 웹뷰)
abstract class WebNav {
  Future<void> load(String url);
  Future<void> back();
  Future<void> forward();
  Future<void> reload();
  Future<void> stop();

  /// YouTube · Google 로그인 쿠키를 yt-dlp 용 cookies.txt 로 내보내기
  Future<void> exportCookies();

  /// 페이지의 동영상 · 소리 멈추기 (다른 화면으로 갈 때)
  Future<void> pauseMedia();

  /// 페이지에서 스크립트 실행 (YouTube 광고 건너뛰기 등)
  Future<void> runScript(String js);

  /// 53: 쿠키 · 사이트 데이터 · 캐시 · 방문 기록 (뒤로 · 앞으로 목록) 지우기 - 엔진이 지원하는 것만
  Future<void> clearData();

  /// 페이지에서 스크립트를 실행하고 결과를 받는다 (페이지 번역). 실패하면 null.
  Future<Object?> evaluate(String js);

  /// 페이지의 JavaScript 켜기 · 끄기 (바뀌면 지금 페이지를 다시 읽는다)
  Future<void> setJavaScript(bool on);
}

/// 페이지의 모든 동영상 · 소리를 멈추는 스크립트
const pauseMediaScript = "document.querySelectorAll('video,audio').forEach(function(m){try{m.pause()}catch(e){}})";

/// 화면 이동 알림 (브라우저 위에 다른 화면이 올라오면 동영상을 멈춘다). MaterialApp.navigatorObservers 에 넣는다.
final browserRouteObserver = RouteObserver<ModalRoute<void>>();

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

  /// 브라우저 화면의 경로 이름 (이미 열려 있으면 그 화면으로 돌아가기 위해)
  static const routeName = 'browser';

  /// 열려 있는 브라우저 화면 수
  static int _open = 0;

  /// 마지막으로 보던 주소: MKV 화면으로 갔다가 브라우저를 다시 열면 홈이 아니라 이 주소로
  static String? _lastUrl;

  /// 마지막으로 붙은 웹뷰 (통합 테스트에서 페이지 내용을 읽는다)
  @visibleForTesting
  static WebNav? debugNav;

  /// 앱 안 웹뷰를 화면이 닫혀도 살려 둔다 (다시 열면 보던 페이지 · 재생 위치 · 뒤로 가기 기록 그대로)
  static final _keepAlive = InAppWebViewKeepAlive();
  static bool _keepAliveUsed = false;

  /// 웹 브라우저로: 이미 열린 브라우저가 있으면 그 화면으로 돌아가고 (보던 페이지 그대로),
  /// 없으면 새로 연다. 다운로드 목록 · 플레이어 등에서 브라우저 버튼을 눌러도 보던 페이지를 잃지 않는다.
  static Future<void> open(NavigatorState nav,
      {required AppController c, DownloadManager? downloads, required BookmarksController bookmarks}) async {
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
      builder: (_) => BrowserPage(c: c, downloads: downloads, bookmarks: bookmarks),
    ));
  }
}

class _BrowserPageState extends State<BrowserPage> with RouteAware {
  late String _url = widget.initialUrl ?? BrowserPage._lastUrl ?? widget.c.settings.homeUrl;
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
      BrowserPage._lastUrl = u;
      if (u != _url) _trFails = 0; // 다른 페이지: 번역을 다시 시도
      setState(() => _url = u);
      if (!_addressFocus.hasFocus) _address.text = u;
      _applyAdSettings();
      _translateNow();
    },
    onTitle: (t) => mounted ? setState(() => _title = t) : null,
    onProgress: (p) {
      if (!mounted) return;
      setState(() => _progress = p);
      if (p >= 1) _translateNow(); // 다 읽었다: 바로 번역 (2초를 기다리지 않고)
    },
    onVideo: (v) => mounted ? setState(() => _hasVideo = v) : null,
    onHistory: (b, f) {
      if (!mounted) return;
      setState(() {
        _canBack = b;
        _canFwd = f;
      });
    },
    attach: (n) => _nav = BrowserPage.debugNav = n,
  );

  BookmarksController get bm => widget.bookmarks;

  // ───────── 페이지 번역 (환경 설정 > 웹 브라우저 > 웹 페이지 자동 번역) ─────────

  static final _translator = WebPageTranslator();

  /// 이 화면에서 번역 중인지. 처음엔 설정을 따르고, 도구 막대의 [번역] 버튼으로 바꾼다.
  late bool _trOn = widget.c.settings.webTranslate;

  /// 버튼으로 직접 켰다: 이미 화면 언어로 보이는 페이지도 번역한다
  bool _trForce = false;
  bool _trBusy = false;
  int _trFails = 0;
  Timer? _trTimer;

  /// 브라우저가 다른 화면에 가려져 있지 않은지
  bool _visible = true;

  /// 바뀌었는지 비교할 설정 (initState 에서 정한다. late 초기화는 처음 읽을 때 - 이미 바뀐 뒤 - 정해져 안 됨)
  late bool _lastTranslate, _lastJs;
  late String _lastLang;

  void _onSettings() {
    if (!mounted) return;
    _applyCookieExport();
    final s = widget.c.settings;
    if (s.webJavaScript != _lastJs) {
      _lastJs = s.webJavaScript;
      _nav?.setJavaScript(_lastJs);
    }
    if (s.webTranslate != _lastTranslate) {
      _lastTranslate = s.webTranslate;
      _setTranslate(_lastTranslate, force: false);
    } else if (s.uiLanguage != _lastLang && _trOn) {
      _translateNow(); // 다른 언어로 다시 번역 (스크립트가 앞의 번역을 되돌린 뒤 번역)
    }
    _lastLang = s.uiLanguage;
  }

  void _setTranslate(bool on, {required bool force}) {
    setState(() {
      _trOn = on;
      _trForce = on && force;
      _trFails = 0;
    });
    if (on) {
      _translateNow();
    } else {
      _trTimer?.cancel();
      _trTimer = null;
      _nav?.evaluate(webTranslateRestoreScript);
    }
  }

  /// 지금 번역하고, 켜져 있는 동안 2초마다 새로 나온 글자를 번역한다 (YouTube 처럼 글이 계속 바뀌는 페이지)
  void _translateNow() {
    if (!_trOn) return;
    _trTimer ??= Timer.periodic(const Duration(seconds: 2), (_) => _translateTick());
    _translateTick();
  }

  Future<void> _translateTick() async {
    final nav = _nav;
    if (!_trOn || _trBusy || nav == null || !_visible || !_url.startsWith('http') || _trFails >= 3) return;
    _trBusy = true;
    try {
      final target = googleLang(uiLanguage); // 실제 화면 언어 (시스템 언어 따르기면 그 언어)
      // 한 번에 300개씩, 페이지가 크면 몇 번 더
      for (var round = 0; round < 10 && mounted && _trOn; round++) {
        final got = CollectedText.parse(await nav.evaluate(webTranslateCollectScript(target, force: _trForce)));
        if (got == null || got.texts.isEmpty) break;
        final out = await _translator.translate(got.texts, target);
        // 대부분 이미 화면 언어면 (직접 켠 게 아니면) 이 페이지는 더 번역하지 않는다
        final chars = got.texts.fold<int>(0, (a, t) => a + t.length);
        var same = 0;
        for (var i = 0; i < out.length; i++) {
          if (out[i] == null) same += got.texts[i].length;
        }
        if (!mounted || !_trOn) break;
        await nav.evaluate(webTranslateApplyScript({for (var i = 0; i < got.ids.length; i++) got.ids[i]: out[i]},
            same: round == 0 && chars > 0 && same >= chars * 0.8));
        if (!got.more) break;
      }
      _trFails = 0;
    } catch (e) {
      // 번역 서버에 닿지 않음 등: 세 번 실패하면 다른 페이지로 갈 때까지 쉰다
      if (++_trFails == 3 && mounted) {
        ScaffoldMessenger.maybeOf(context)
            ?.showSnackBar(SnackBar(content: Text(trf('웹 페이지를 번역하지 못했습니다: {0}', [e]))));
      }
    } finally {
      _trBusy = false;
    }
  }

  @override
  void initState() {
    super.initState();
    BrowserPage._open++;
    final s = widget.c.settings;
    _lastTranslate = s.webTranslate;
    _lastJs = s.webJavaScript;
    _lastLang = s.uiLanguage;
    _applyCookieExport();
    widget.c.addListener(_onSettings);
    if (_trOn) _translateNow();
    // 66-2: 브라우저 가운데는 페이지가 좌우로 밀리므로 화면 옮기기는 위쪽 막대에서 - 처음 한 번만 알린다.
    // 알림 (SnackBar) 은 다른 알림 (다운로드 등) 을 뒤로 밀어 기다리게 하므로 위쪽 막대 아래의 한 줄로
    if (s.swipeNav && !s.browserSwipeHinted) {
      _swipeHint = true;
      WidgetsBinding.instance.addPostFrameCallback((_) => widget.c.updateSettings((x) => x.browserSwipeHinted = true));
    }
  }

  /// 66-2: 화면 옮기기 안내 한 줄 (처음 한 번, ✕ 로 닫음)
  bool _swipeHint = false;

  Widget _swipeHintBar() => Material(
        color: JjColors.accent.withValues(alpha: 0.14),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 2, 4, 2),
          child: Row(children: [
            const Icon(Icons.swipe, size: 16, color: JjColors.accent),
            const SizedBox(width: 8),
            Expanded(
                child: Text(tr('웹 브라우저에서는 위쪽 막대를 좌우로 밀면 다른 화면으로 옮깁니다 (가운데는 페이지가 밀립니다).'),
                    style: const TextStyle(fontSize: 12))),
            IconButton(
              tooltip: tr('안내 닫기'),
              visualDensity: VisualDensity.compact,
              iconSize: 16,
              icon: const Icon(Icons.close),
              onPressed: () => setState(() => _swipeHint = false),
            ),
          ]),
        ),
      );

  /// 53: 쿠키를 쓰도록 정했을 때만 · 고른 사이트만 내보낸다
  void _applyCookieExport() {
    final s = widget.c.settings;
    CookieExport.enabled = s.ytCookiesBrowser == internalBrowserCookies;
    CookieExport.sites = s.loginCookieSites;
  }

  /// 53: 쿠키 · 방문 기록 지우기 (확인 뒤). 다운로드용으로 내보낸 쿠키 파일도 지운다
  Future<void> _clearData() async {
    final ok = await confirmAction(
      context,
      title: tr('쿠키 · 방문 기록 지우기'),
      body: tr('앱 안 브라우저의 쿠키 (로그인) · 사이트 데이터 · 캐시 · 방문 기록과, 다운로드용으로 내보낸 쿠키 파일을 지웁니다. '
          '사이트에 다시 로그인해야 합니다. 즐겨찾기는 그대로입니다.'),
      ok: tr('지우기'),
    );
    if (!ok || !mounted) return;
    try {
      await _nav?.clearData();
    } catch (_) {}
    await deleteExportedCookies(widget.c.settings.webViewDataDir);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('쿠키 · 방문 기록을 지웠습니다.'))));
    unawaited(_nav?.reload());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route != null) browserRouteObserver.subscribe(this, route);
  }

  /// 다운로드 목록 · 플레이어 · 설정 등이 위에 올라왔다: 보던 동영상을 멈춘다 (가려진 채 소리만 나지 않게)
  @override
  void didPushNext() {
    _visible = false;
    // 환경 설정 > 웹 브라우저 > "다른 화면으로 가면 페이지 소리 멈춤" (끄면 다른 화면에서도 계속 들림)
    if (widget.c.settings.webPauseOnLeave) _nav?.pauseMedia();
  }

  /// 설정 화면 등에서 돌아왔다: 바뀐 광고 설정을 지금 페이지에 적용
  @override
  void didPopNext() {
    _visible = true;
    _applyAdSettings();
    _translateNow();
  }

  /// YouTube 페이지면 광고 건너뛰기 · 숨기기 스크립트를 넣는다 (환경 설정 > 시작 · 웹 브라우저)
  void _applyAdSettings() {
    if (!(Uri.tryParse(_url)?.host ?? '').endsWith('youtube.com')) return;
    final s = widget.c.settings;
    _nav?.runScript(youtubeAdScript(skip: s.youtubeAdSkip, hide: s.youtubeAdHide, badge: tr('광고 건너뛰는 중…')));
  }

  /// MKV 화면 등으로 가며 브라우저 화면이 닫힌다: 살려 둔 웹뷰에서 소리만 나지 않게 멈춘다
  @override
  void didPop() {
    if (widget.c.settings.webPauseOnLeave) _nav?.pauseMedia();
  }

  @override
  void dispose() {
    browserRouteObserver.unsubscribe(this);
    BrowserPage._open--;
    widget.c.removeListener(_onSettings);
    _trTimer?.cancel();
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

  /// 27: 어느 사이트에서나 받아 볼 수 있다 (yt-dlp 가 지원하면 받고, 아니면 다운로드 목록에 이유가 보인다)
  bool get _canDownload => widget.downloads != null && _url.startsWith('http');

  /// 동영상이 있어 보이는 페이지 (버튼을 눈에 띄게)
  bool get _likelyVideo => looksLikeVideoPage(_url) || _hasVideo;

  String get _downloadTip =>
      _likelyVideo ? tr('다운로드') : tr('다운로드 (이 페이지에서 동영상을 찾지 못했지만 받아 볼 수 있습니다)');

  Future<void> _download() async {
    // 로그인 쿠키를 먼저 내보내 yt-dlp 가 같은 로그인으로 받도록
    try {
      await _nav?.exportCookies();
    } catch (_) {}
    if (!mounted) return;
    final d = widget.downloads!;
    final t = d.addPage(_url);
    final m = ScaffoldMessenger.of(context);
    if (t == null) {
      m.showSnackBar(SnackBar(content: Text(tr('이미 받는 중이거나 받을 수 없는 주소입니다.'))));
      return;
    }
    // 알림은 앱 전체에 떠 있으므로 이 브라우저 화면이 아니라 앱의 Navigator 로 연다
    // (화면을 오가 이 브라우저 화면이 닫혀도 "목록 보기" 가 된다)
    final nav = Navigator.of(context);
    final bar = m.showSnackBar(SnackBar(
      content: Text(trf('다운로드 추가: {0}', [_title.isEmpty ? _url : _title])),
      duration: const Duration(minutes: 10),
      showCloseIcon: true, // [✕] 로 바로 닫기
      persist: false, // Flutter 3.47+: [action] 이 있으면 기본은 안 사라짐 → duration 대로 닫기
      action: SnackBarAction(label: tr('목록 보기'), onPressed: () => DownloadsPage.open(nav, d)),
    ));
    // 받기 준비가 끝나면 (진행률이 나오거나 · 끝 · 실패 · 취소 · 목록에서 지움) 알림을 닫는다
    void check() {
      final ready = !d.tasks.contains(t) ||
          t.progress != null ||
          (t.state != DownloadState.queued && t.state != DownloadState.downloading);
      if (ready) {
        d.removeListener(check);
        bar.close();
      }
    }

    d.addListener(check);
    unawaited(bar.closed.then((_) => d.removeListener(check)));
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
      // Android 뒤로 키: 앞 웹 페이지가 있으면 웹 페이지 뒤로 (없으면 브라우저 화면을 닫는다).
      // 앱 위쪽의 ← (화면 이동) 은 이것과 상관없이 브라우저 화면을 닫는다 (AppNavButtons.onBrowserPage).
      child: PopScope(
        canPop: !(defaultTargetPlatform == TargetPlatform.android && _canBack),
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) _nav?.back();
        },
        child: Focus(
        autofocus: true,
        child: Scaffold(
          body: ListenableBuilder(
            listenable: Listenable.merge([bm, widget.c]),
            builder: (context, _) => Column(children: [
              _toolbar(),
              if (_swipeHint) _swipeHintBar(),
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
                            // Chrome 엔진은 JavaScript 설정을 만든 뒤에 바꿀 수 없어 바뀌면 새로 만든다
                            ? _CefView(
                                key: ValueKey(widget.c.settings.webJavaScript),
                                host: _host,
                                initialUrl: _url,
                                dataDir: widget.c.settings.webViewDataDir,
                                javaScript: widget.c.settings.webJavaScript)
                            : _EdgeView(
                                host: _host,
                                initialUrl: _url,
                                dataDir: widget.c.settings.webViewDataDir,
                                javaScript: widget.c.settings.webJavaScript)),
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
      ),
    );
  }

  /// 위쪽 막대: 여기서 좌우로 밀면 화면 이동 (웹 페이지 위에서는 웹 페이지의 스크롤과 다투어 위 · 아래가 이상했음)
  Widget _toolbar() => SwipeNav(current: 'browser', anywhere: true, child: _toolbarBar());

  Widget _toolbarBar() {
    final starred = bm.tree.findByUrl(_url) != null;
    IconButton btn(IconData i, String tip, VoidCallback? f, {Color? color}) => IconButton(
          tooltip: tip,
          visualDensity: VisualDensity.compact,
          icon: Icon(i, size: 20, color: color),
          onPressed: f,
        );
    // 주소 칸이 좁아지면 (폰 세로 · 태블릿 세로 · 폰 가로 100%) 자주 안 쓰는 버튼은 ⋮ 메뉴로 - 주소가 "http" 만 보이거나
    // 아예 사라지던 것. 버튼을 없애지는 않는다.
    return AppTopBar(
      nav: const AppNavButtons(onBrowserPage: true),
      actions: AppActions(c: widget.c),
      middle: LayoutBuilder(builder: (context, box) {
        final compact = box.maxWidth < 640;
        return Row(children: [
        if (!compact) ...[
          Container(width: 1, height: 24, color: JjColors.border),
          const SizedBox(width: 4),
        ],
        // 웹 페이지 이동 (앱 화면 이동인 왼쪽 버튼과 구분되는 모양)
        btn(Icons.arrow_back_ios_new, tr('이전 페이지 (Alt+←)'), _canBack ? () => _nav?.back() : null),
        btn(Icons.arrow_forward_ios, tr('다음 페이지 (Alt+→)'), _canFwd ? () => _nav?.forward() : null),
        _progress < 1
            ? btn(Icons.close, tr('중지'), () => _nav?.stop())
            : btn(Icons.refresh, tr('새로고침 (F5)'), () => _nav?.reload()),
        if (!compact) btn(Icons.home_outlined, tr('홈'), () => _go(widget.c.settings.homeUrl)),
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
              hintText: tr('주소 입력 또는 검색 (Ctrl+L)'),
              prefixIcon: Icon(_url.startsWith('https') ? Icons.lock_outline : Icons.public, size: 16),
              prefixIconConstraints: const BoxConstraints(minWidth: 32),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(18), borderSide: BorderSide.none),
              suffixIcon: IconButton(
                tooltip: starred ? tr('즐겨찾기 수정 (Ctrl+D)') : tr('즐겨찾기 추가 (Ctrl+D)'),
                icon: Icon(starred ? Icons.star : Icons.star_border, size: 18,
                    color: starred ? Colors.amber : JjColors.textDim),
                onPressed: _star,
              ),
            ),
            onSubmitted: _go,
          ),
        ),
        const SizedBox(width: 4),
        if (!compact)
        btn(
            Icons.translate,
            _trOn
                ? tr('원문 보기 (번역 끄기)')
                : trf('이 페이지를 {0}(으)로 번역', [I18nController.nativeName(widget.c.settings.uiLanguage)]),
            () => _setTranslate(!_trOn, force: true),
            color: _trOn ? JjColors.accent : null),
        const SizedBox(width: 4),
        if (compact)
          _likelyVideo
              ? IconButton.filled(
                  tooltip: _downloadTip,
                  visualDensity: VisualDensity.compact,
                  onPressed: _canDownload ? _download : null,
                  icon: const Icon(Icons.download, size: 18),
                )
              : IconButton.filledTonal(
                  tooltip: _downloadTip,
                  visualDensity: VisualDensity.compact,
                  onPressed: _canDownload ? _download : null,
                  icon: const Icon(Icons.download, size: 18),
                )
        else
          Tooltip(
            message: _downloadTip,
            child: _likelyVideo
                ? FilledButton.icon(
                    onPressed: _canDownload ? _download : null,
                    icon: const Icon(Icons.download, size: 18),
                    label: Text(tr('다운로드')),
                  )
                : FilledButton.tonalIcon(
                    onPressed: _canDownload ? _download : null,
                    icon: const Icon(Icons.download, size: 18),
                    label: Text(tr('다운로드')),
                  ),
          ),
        const SizedBox(width: 4),
        if (!compact) btn(Icons.open_in_new, tr('외부 브라우저로 열기'), () => _openExternal(_url)),
        if (!compact) btn(Icons.cookie_outlined, tr('쿠키 · 방문 기록 지우기'), _clearData),
        if (widget.c.busy && !_work && !compact)
          InkWell(
            onTap: _toggleWork,
            borderRadius: BorderRadius.circular(6),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
              child: JobIndicator(c: widget.c, compact: true),
            ),
          ),
        if (!compact)
          btn(_work ? Icons.view_sidebar : Icons.view_sidebar_outlined, tr('작업 현황 보기 · 화면 분할 (Ctrl+Shift+J)'),
              _toggleWork, color: widget.c.busy ? JjColors.accent : null),
        if (!compact)
          btn(_panel ? Icons.bookmarks : Icons.bookmarks_outlined, tr('즐겨찾기 관리 (Ctrl+Shift+B)'),
              () => setState(() => _panel = !_panel))
        else
          PopupMenuButton<String>(
            tooltip: tr('더 보기'),
            icon: const Icon(Icons.more_vert, size: 20),
            onSelected: (v) => switch (v) {
              'home' => _go(widget.c.settings.homeUrl),
              'translate' => _setTranslate(!_trOn, force: true),
              'external' => _openExternal(_url),
              'work' => _toggleWork(),
              'clear' => _clearData(),
              _ => setState(() => _panel = !_panel),
            },
            itemBuilder: (_) => [
              PopupMenuItem(value: 'home', child: ListTile(dense: true, leading: const Icon(Icons.home_outlined), title: Text(tr('홈')))),
              PopupMenuItem(
                  value: 'translate',
                  child: ListTile(
                      dense: true,
                      leading: Icon(Icons.translate, color: _trOn ? JjColors.accent : null),
                      title: Text(_trOn ? tr('원문 보기 (번역 끄기)') : tr('이 페이지 번역')))),
              PopupMenuItem(
                  value: 'bookmarks',
                  child: ListTile(dense: true, leading: const Icon(Icons.bookmarks_outlined), title: Text(tr('즐겨찾기 관리')))),
              PopupMenuItem(
                  value: 'work',
                  child: ListTile(dense: true, leading: const Icon(Icons.view_sidebar_outlined), title: Text(tr('작업 현황')))),
              PopupMenuItem(
                  value: 'external',
                  child: ListTile(dense: true, leading: const Icon(Icons.open_in_new), title: Text(tr('외부 브라우저로 열기')))),
              PopupMenuItem(
                  value: 'clear',
                  child: ListTile(dense: true, leading: const Icon(Icons.cookie_outlined), title: Text(tr('쿠키 · 방문 기록 지우기')))),
            ],
          ),
      ]);
      }),
    );
  }
}

/// 53: 다운로드용으로 내보낸 로그인 쿠키 파일 (평문) 을 지운다
Future<void> deleteExportedCookies(String dataDir) async {
  if (dataDir.isEmpty) return;
  for (final name in [CookieExport.fileName, '${CookieExport.fileName}.tmp']) {
    try {
      final f = File('$dataDir${Platform.pathSeparator}$name');
      if (await f.exists()) await f.delete();
    } catch (_) {}
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

/// Edge · Android 웹뷰 설정 (처음 만들 때와 JavaScript 켜기 · 끄기에 같이 쓴다)
InAppWebViewSettings _webSettings({required bool javaScript}) => InAppWebViewSettings(
      javaScriptEnabled: javaScript,
      mediaPlaybackRequiresUserGesture: false,
      supportMultipleWindows: false,
      // Android: 텍스처로 그린다. 기본 hybrid composition 은 백그라운드로 실행 중 화면 (Activity) 이 새로 붙을 때
      // Impeller 가 "EGL Bad Access" 로 그리지 못해 앱 화면이 비어 버린다.
      useHybridComposition: false,
    );

class _EdgeView extends StatefulWidget {
  final BrowserHost host;
  final String initialUrl;
  final String dataDir;
  final bool javaScript;
  const _EdgeView({required this.host, required this.initialUrl, required this.dataDir, required this.javaScript});

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
  /// 살려 둔 웹뷰를 이 화면이 쓰는지 (브라우저 화면은 하나뿐이지만, 혹시 둘이면 둘째는 새 웹뷰)
  InAppWebViewKeepAlive? _keepAlive;

  @override
  void initState() {
    super.initState();
    if (!BrowserPage._keepAliveUsed) {
      BrowserPage._keepAliveUsed = true;
      _keepAlive = BrowserPage._keepAlive;
    }
  }

  @override
  void dispose() {
    if (_keepAlive != null) BrowserPage._keepAliveUsed = false;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<WebViewEnvironment?>(
        future: browserEnvironment(widget.dataDir),
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
            return Center(
              child: Text(trf('웹 브라우저(Edge WebView2)를 시작할 수 없습니다.\n{0}', [snap.error]),
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
            keepAlive: _keepAlive,
            webViewEnvironment: snap.data,
            initialUrlRequest: URLRequest(url: WebUri(normalizeAddress(widget.initialUrl))),
            initialSettings: _webSettings(javaScript: widget.javaScript),
            onWebViewCreated: (c) async {
              final nav = _InAppNav(c, snap.data, widget.dataDir);
              h.attach(nav);
              // 살려 둔 웹뷰는 처음 설정 그대로이므로 지금 설정에 맞춘다
              await nav.setJavaScript(widget.javaScript);
              // 살려 둔 웹뷰를 다시 붙였으면 보던 주소 · 제목 · 뒤로 가기 상태를 다시 알린다
              final u = await c.getUrl();
              if (u != null) h.onUrl(u.toString());
              final t = await c.getTitle();
              if (t != null) h.onTitle(t);
              await check(c);
            },
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

  @override
  Future<void> pauseMedia() async {
    try {
      await c.evaluateJavascript(source: pauseMediaScript);
    } catch (_) {}
  }

  @override
  Future<void> runScript(String js) async {
    try {
      await c.evaluateJavascript(source: js);
    } catch (_) {}
  }

  @override
  Future<Object?> evaluate(String js) async {
    try {
      return await c.evaluateJavascript(source: js);
    } catch (_) {
      return null;
    }
  }

  /// Edge 는 앱이 넣는 스크립트 (번역 · 동영상 찾기) 는 JavaScript 를 꺼도 실행된다. Android 는 꺼지면 안 된다.
  @override
  Future<void> setJavaScript(bool on) async {
    try {
      if ((await c.getSettings())?.javaScriptEnabled == on) return;
      await c.setSettings(settings: _webSettings(javaScript: on));
      await c.reload();
    } catch (_) {}
  }

  static const _cookieSites = [
    'https://www.youtube.com/',
    'https://m.youtube.com/',
    'https://accounts.google.com/',
    'https://www.google.com/',
    // 28: 로그인해야 받을 수 있는 동영상이 많은 곳 (앱 안 브라우저에서 로그인하면 yt-dlp 가 같은 로그인으로 받는다)
    'https://www.instagram.com/',
    'https://x.com/',
    'https://twitter.com/',
    'https://chzzk.naver.com/',
    'https://www.naver.com/',
    'https://nid.naver.com/',
    'https://tv.naver.com/',
  ];

  @override
  Future<void> clearData() async {
    Future<void> quiet(Future<void> Function() f) async {
      try {
        await f();
      } catch (_) {} // 그 엔진이 지원하지 않는 것은 건너뛴다
    }

    await quiet(() => CookieManager.instance(webViewEnvironment: env).deleteAllCookies());
    await quiet(() => WebStorageManager.instance().deleteAllData());
    await quiet(() => c.clearHistory());
    await quiet(() => InAppWebViewController.clearAllCache());
  }

  @override
  Future<void> exportCookies() async {
    if (dataDir.isEmpty) return;
    final cm = CookieManager.instance(webViewEnvironment: env);
    final all = <CookieRecord>[];
    if (!CookieExport.enabled) return;
    for (final site in _cookieSites) {
      if (!isLoginCookieDomain(Uri.parse(site).host)) continue;
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
  final bool javaScript;
  const _CefView(
      {super.key, required this.host, required this.initialUrl, required this.dataDir, required this.javaScript});

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
      await _c.initialize(normalizeAddress(widget.initialUrl), javaScript: widget.javaScript);
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
        child: Text(trf('Chrome 엔진을 시작할 수 없습니다. 환경 설정에서 Edge 로 바꿔 쓰세요.\n{0}', [_error]),
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

  @override
  Future<void> pauseMedia() async {
    try {
      await c.evaluateJavascript(pauseMediaScript);
    } catch (_) {}
  }

  @override
  Future<void> runScript(String js) async {
    try {
      await c.evaluateJavascript(js);
    } catch (_) {}
  }

  /// JavaScript 를 끈 Chrome 엔진에서는 결과를 받지 못한다 (null)
  @override
  Future<Object?> evaluate(String js) async {
    try {
      return await c.evaluateJavascript(js).timeout(const Duration(seconds: 10));
    } catch (_) {
      return null;
    }
  }

  /// Chrome 엔진은 만든 뒤에 바꿀 수 없다: 화면이 JavaScript 설정을 열쇠로 웹뷰를 새로 만든다 ([_CefView])
  @override
  Future<void> setJavaScript(bool on) async {}

  /// YouTube · Google 등의 쿠키를 yt-dlp 용 cookies.txt 로 (Edge 와 같은 파일 - 지금 쓰는 엔진의 로그인이 쓰인다).
  /// Chrome 엔진은 쿠키의 이름 · 값만 알려 주므로 만료 · 보안 표시는 기본값으로 적는다.
  @override
  Future<void> clearData() async {
    // Chrome 엔진은 모두 지우기가 없어 쿠키를 하나씩 지운다
    try {
      final raw = await cef.WebviewManager().visitAllCookies();
      if (raw is Map) {
        for (final e in raw.entries) {
          if (e.value is! Map) continue;
          for (final name in (e.value as Map).keys) {
            await cef.WebviewManager().deleteCookie('${e.key}', '$name');
          }
        }
      }
    } catch (_) {}
  }

  @override
  Future<void> exportCookies() async {
    if (dataDir.isEmpty || !CookieExport.enabled) return;
    final raw = await cef.WebviewManager().visitAllCookies();
    if (raw is! Map) return;
    final all = <CookieRecord>[];
    final later = DateTime.now().add(const Duration(days: 30)).millisecondsSinceEpoch ~/ 1000;
    raw.forEach((domain, cookies) {
      final d = '$domain';
      if (!isLoginCookieDomain(d) || cookies is! Map) return;
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
      // 다른 폴더에서 온 것만 (표시줄 안에서는 다른 즐겨찾기 위에 놓아 순서를 바꾼다. 길게 눌렀다 떼도 맨 뒤로 가지 않게)
      onWillAcceptWithDetails: (d) =>
          bm.canMoveInto(d.data.id, BookmarkTree.barId) && bm.tree.parentOf(d.data.id)?.id != BookmarkTree.barId,
      onAcceptWithDetails: (d) => bm.moveInto(d.data.id, BookmarkTree.barId),
      builder: (context, _, _) => GestureDetector(
        behavior: HitTestBehavior.opaque,
        onSecondaryTapDown: (d) => _menu(context, d.globalPosition),
        // 터치 화면: 길게 누르면 같은 메뉴
        onLongPressStart: (d) => _menu(context, d.globalPosition),
        child: Container(
          height: 32,
          color: JjColors.panel,
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: items.isEmpty
              ? Align(
                  alignment: Alignment.centerLeft,
                  child: Text(tr('  ☆ 를 누르면 여기에 즐겨찾기가 추가됩니다 · 오른쪽 클릭: 폴더 추가'),
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
            // 길게 누르기는 메뉴에 (마우스를 올리면 주소)
            triggerMode: TooltipTriggerMode.manual,
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
      // 길게 누르기 (터치 화면): 움직이지 않고 떼면 메뉴, 끌면 옮기기 (BookmarkDraggable)
      child: BookmarkDraggable(n: n, onMenu: (at) => _menu(context, at, n), child: button),
    );
  }

  List<Widget> _folderMenu(BuildContext context, BookmarkNode f) => [
        if (f.children!.isEmpty) MenuItemButton(child: Text(tr('(비어 있음)'))),
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
          child: Text(tr('이 폴더에 현재 페이지 추가')),
        ),
        MenuItemButton(
          leadingIcon: const Icon(Icons.create_new_folder_outlined, size: 16),
          onPressed: () => showNewFolderDialog(context, bm, f.id),
          child: Text(tr('이 폴더에 새 폴더')),
        ),
        MenuItemButton(
          leadingIcon: const Icon(Icons.edit_outlined, size: 16),
          onPressed: () => showBookmarkEditor(context, bm, f),
          child: Text(tr('폴더 이름 바꾸기 · 이동')),
        ),
        MenuItemButton(
          leadingIcon: const Icon(Icons.bookmarks_outlined, size: 16),
          onPressed: () => onOpenManager(folderId: f.id),
          child: Text(tr('즐겨찾기 관리자에서 보기')),
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
            Text(tr('즐겨찾기'), style: TextStyle(fontWeight: FontWeight.w600)),
            const Spacer(),
            if (widget.onOpenManager != null)
              IconButton(
                tooltip: tr('즐겨찾기 관리자 (Ctrl+Shift+O)'),
                iconSize: 18,
                icon: const Icon(Icons.open_in_full),
                onPressed: () => widget.onOpenManager!(folderId: _folderId),
              ),
            IconButton(tooltip: tr('닫기'), iconSize: 18, icon: const Icon(Icons.close), onPressed: widget.onClose),
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
              label: Text(tr('현재 페이지'), style: TextStyle(fontSize: 12)),
            ),
            OutlinedButton.icon(
              onPressed: () async {
                await showNewFolderDialog(context, bm, _folderId);
              },
              icon: const Icon(Icons.create_new_folder_outlined, size: 16),
              label: Text(tr('폴더'), style: TextStyle(fontSize: 12)),
            ),
            PopupMenuButton<String>(
              tooltip: tr('다른 브라우저의 즐겨찾기 가져오기'),
              itemBuilder: (_) => [
                PopupMenuItem(value: 'chrome', child: Text(tr('Chrome 에서 가져오기'))),
                PopupMenuItem(value: 'edge', child: Text(tr('Edge 에서 가져오기'))),
                PopupMenuItem(value: 'whale', child: Text(tr('Whale 에서 가져오기'))),
              ],
              onSelected: (b) async {
                final n = await bm.importFrom(b);
                if (!context.mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                    content: Text(n < 0
                        ? tr('이 브라우저의 즐겨찾기 파일을 찾지 못했습니다.')
                        : trf('{0}개를 "기타 즐겨찾기" 에 가져왔습니다.', [n]))));
                if (n > 0) setState(() => _folderId = BookmarkTree.otherId);
              },
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.download_for_offline_outlined, size: 16),
                  SizedBox(width: 4),
                  Text(tr('가져오기'), style: TextStyle(fontSize: 12)),
                ]),
              ),
            ),
          ]),
        ),
        const Divider(height: 12),
        Expanded(
          child: items.isEmpty
              ? Center(child: Text(tr('비어 있는 폴더'), style: TextStyle(color: JjColors.textDim)))
              : ReorderableListView.builder(
                  buildDefaultDragHandles: false,
                  itemCount: items.length,
                  onReorderItem: (o, n) => bm.reorder(folder.id, o, n),
                  itemBuilder: (_, i) {
                    final n = items[i];
                    // 오른쪽 클릭 · 길게 누르기 (터치 화면) 로 같은 메뉴
                    void menuAt(Offset at) => showBookmarkMenu(context,
                        bm: bm,
                        globalPosition: at,
                        n: n,
                        folderId: folder.id,
                        onOpen: widget.onOpen,
                        onOpenExternal: widget.onOpenExternal,
                        currentUrl: widget.currentUrl,
                        currentTitle: widget.currentTitle);
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
                          onMenu: menuAt,
                          child: Icon(n.isFolder ? Icons.folder : Icons.public,
                              size: 18, color: n.isFolder ? Colors.amber : JjColors.textDim),
                        ),
                      ]),
                      title: Text(n.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: n.isFolder
                          ? Text(trf('{0}개', [n.children!.length]), style: const TextStyle(fontSize: 11))
                          : Text(n.url!, maxLines: 1, overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 11)),
                      onTap: () => n.isFolder ? setState(() => _folderId = n.id) : widget.onOpen(n.url!),
                      trailing: PopupMenuButton<String>(
                        tooltip: tr('더 보기'),
                        iconSize: 18,
                        itemBuilder: (_) => [
                          if (!n.isFolder) PopupMenuItem(value: 'ext', child: Text(tr('외부 브라우저로 열기'))),
                          PopupMenuItem(value: 'edit', child: Text(tr('수정'))),
                          PopupMenuItem(value: 'move', child: Text(tr('다른 폴더로 이동'))),
                          if (i > 0) PopupMenuItem(value: 'up', child: Text(tr('위로'))),
                          if (i < items.length - 1) PopupMenuItem(value: 'down', child: Text(tr('아래로'))),
                          const PopupMenuDivider(),
                          PopupMenuItem(value: 'del', child: Text(tr('삭제'))),
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
                        onSecondaryTapDown: (d) => menuAt(d.globalPosition),
                        onLongPressStart: (d) => menuAt(d.globalPosition),
                        child: n.isFolder ? BookmarkFolderDrop(bm: bm, folderId: n.id, child: tile) : tile,
                      ),
                    );
                  },
                ),
        ),
        Padding(
          padding: EdgeInsets.all(8),
          child: Text(tr('⋮⋮ 를 끌어 순서 바꾸기 · 아이콘을 끌어 폴더에 넣기 · 오른쪽 클릭 (길게 누르기) 메뉴'),
              textAlign: TextAlign.center, style: TextStyle(fontSize: 11, color: JjColors.textDim)),
        ),
      ]),
    );
  }

  Future<void> _moveTo(BuildContext context, BookmarkNode n) async {
    final target = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(trf('"{0}" 이동', [n.title])),
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
