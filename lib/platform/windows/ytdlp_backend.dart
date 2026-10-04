import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../core/download_detect.dart';
import '../../services/downloader.dart';
import '../../l10n/tr.dart';

/// 실행 파일 찾기: 앱 옆 tools\ → 앱 폴더 → PATH
String locateTool(String name) {
  final exe = Platform.isWindows ? '$name.exe' : name;
  final appDir = p.dirname(Platform.resolvedExecutable);
  for (final dir in [p.join(appDir, 'tools'), appDir]) {
    final f = p.join(dir, exe);
    if (File(f).existsSync()) return f;
  }
  return name;
}

/// yt-dlp 로 동영상 다운로드 (작업마다 프로세스 하나)
///
/// 일시정지 = 프로세스 중지, 다시 시작하면 yt-dlp 가 .part 파일에서 이어 받는다.
class YtDlpBackend implements DownloadBackend {
  final String ytdlp;

  /// yt-dlp 가 영상·음성을 합칠 때 쓰는 ffmpeg 폴더
  final String? ffmpegDir;

  /// YouTube 추출용 JavaScript 실행기 "deno:경로" · "quickjs:경로" (없으면 일부 화질이 빠질 수 있음)
  final String? jsRuntime;

  /// yt-dlp 앞에 붙일 인수 (Android: python 으로 yt-dlp 스크립트를 실행 → [ytdlp] 는 python, 여기에 스크립트 경로)
  final List<String> prefixArgs;

  /// 추가 환경 변수 (Android: Python · ffmpeg 라이브러리 위치 등)
  final Map<String, String> environment;

  final _procs = <String, Process>{};
  final _stopping = <String>{};

  /// 형식 · 화질 인수 (환경 설정에서 읽음). 없으면 MP4 최고 화질.
  final List<String> Function() formatArgs;

  /// 쿠키 인수 (YouTube 로봇 확인 대응, 환경 설정에서 읽음)
  final List<String> Function() cookieArgs;

  /// [cookieArgs] 의 쿠키를 읽지 못했을 때 대신 쓸 쿠키 (앱 안 브라우저가 내보낸 cookies.txt)
  final List<String> Function() fallbackCookieArgs;

  /// 작업에 쓸 쿠키 인수: 0 = 설정대로 → 1 = 대신 쓸 쿠키 → 2 = 쿠키 없이
  List<String> _cookiesFor(DownloadTask t) => switch (t.extra['cookieStage'] ?? 0) {
        0 => cookieArgs(),
        1 => fallbackCookieArgs(),
        _ => const [],
      };

  YtDlpBackend({
    String? ytdlp,
    this.ffmpegDir,
    String? deno,
    String? jsRuntime,
    this.prefixArgs = const [],
    this.environment = const {},
    List<String> Function()? formatArgs,
    List<String> Function()? cookieArgs,
    List<String> Function()? fallbackCookieArgs,
  })  : ytdlp = ytdlp ?? locateTool('yt-dlp'),
        jsRuntime = jsRuntime ?? _denoRuntime(deno ?? _existing(locateTool('deno'))),
        formatArgs = formatArgs ?? (() => ytDlpFormatArgs(YtContainer.mp4, YtQuality.best)),
        cookieArgs = cookieArgs ?? (() => const []),
        fallbackCookieArgs = fallbackCookieArgs ?? (() => const []);

  static const _pyEnv = {'PYTHONIOENCODING': 'utf-8', 'PYTHONUTF8': '1'};
  Map<String, String> get _env => {..._pyEnv, ...environment};

  static String? _denoRuntime(String? deno) => deno == null ? null : 'deno:$deno';

  @override
  Future<(String, List<PlaylistEntry>)?> expandPlaylist(String url) async {
    final listId = youtubePlaylistId(url);
    if (listId == null) return null;
    // 영상은 받지 않고 목록만 빠르게 읽는다
    Future<ProcessResult> read(List<String> cookies) => Process.run(
          ytdlp,
          [
            ...prefixArgs,
            '--flat-playlist', '-J', '--no-warnings', '--encoding', 'utf-8',
            if (jsRuntime != null) ...['--js-runtimes', jsRuntime!],
            ...cookies,
            'https://www.youtube.com/playlist?list=$listId',
          ],
          environment: _env,
          stdoutEncoding: utf8,
          stderrEncoding: utf8,
        );
    // 고른 브라우저의 쿠키를 못 읽으면: 앱 안 브라우저의 쿠키 → 쿠키 없이 (영상 받기와 같은 순서)
    final tries = <List<String>>[];
    for (final c in [cookieArgs(), fallbackCookieArgs(), const <String>[]]) {
      if (!tries.any((t) => t.join(' ') == c.join(' '))) tries.add(c);
    }
    late ProcessResult r;
    for (final cookies in tries) {
      r = await read(cookies);
      if (r.exitCode == 0 || !isCookieReadError(r.stderr as String)) break;
    }
    if (r.exitCode != 0) {
      throw ProcessException(
          ytdlp, [url], trf('재생목록을 읽을 수 없습니다: {0}', [friendlyYtDlpError((r.stderr as String).trim())]), r.exitCode);
    }
    final j = jsonDecode(r.stdout as String) as Map<String, dynamic>;
    final entries = <PlaylistEntry>[];
    for (final e in (j['entries'] as List? ?? const [])) {
      final m = e as Map;
      final id = m['id'] as String?;
      final title = (m['title'] as String?) ?? id ?? '';
      // 삭제 · 비공개 영상은 건너뜀
      if (id == null || title == '[Deleted video]' || title == '[Private video]') continue;
      entries.add(PlaylistEntry('https://www.youtube.com/watch?v=$id', title));
    }
    return ((j['title'] as String?) ?? listId, entries);
  }

  static String? _existing(String path) => File(path).existsSync() ? path : null;

  @override
  DownloadKind get kind => DownloadKind.video;

  List<String> argsFor(DownloadTask t) => [
        // --print 를 쓰면 yt-dlp 가 조용한 모드가 되어 진행률이 나오지 않는다 → 다시 켠다
        '--no-quiet', '--progress',
        '--newline', '--no-colors', '--encoding', 'utf-8',
        '--no-playlist', '--windows-filenames', '--no-mtime',
        '--progress-template',
        'download:[JJ]%(progress._percent_str)s|%(progress._speed_str)s|%(progress._eta_str)s'
            '|%(progress.downloaded_bytes)s|%(progress.total_bytes,progress.total_bytes_estimate)s',
        '--print', 'before_dl:[JJT]%(title)s',
        // 영상 + 음성을 합친 전체 크기 (모르면 NA)
        '--print', 'before_dl:[JJS]%(filesize,filesize_approx)s',
        '--print', 'after_move:[JJF]%(filepath)s',
        '-P', t.dir,
        '-o', '%(title).150B [%(id)s].%(ext)s',
        ...formatArgs(),
        ..._cookiesFor(t),
        if (ffmpegDir != null) ...['--ffmpeg-location', ffmpegDir!],
        if (jsRuntime != null) ...['--js-runtimes', jsRuntime!],
        t.source,
      ];

  @override
  Future<void> start(DownloadTask t, void Function() changed) async {
    if (_procs.containsKey(t.id)) return;
    await Directory(t.dir).create(recursive: true);
    t
      ..state = DownloadState.downloading
      ..error = null;
    changed();

    final Process proc;
    try {
      proc = await Process.start(ytdlp, [...prefixArgs, ...argsFor(t)], environment: _env);
    } on ProcessException catch (e) {
      t
        ..state = DownloadState.failed
        ..error = trf('yt-dlp 를 실행할 수 없습니다: {0}', [e.message]);
      changed();
      return;
    }
    _procs[t.id] = proc;

    final errTail = <String>[];
    // 영상 · 음성을 따로 받아도 하나의 진행률 · 크기로 보이게 합친다
    final totals = YtDlpTotals();
    var files = 0;
    void onLine(String line) {
      final prog = parseYtDlpProgress(line);
      if (prog != null) {
        totals.update(prog);
        t
          ..progress = totals.progress ?? t.progress
          ..receivedBytes = totals.received
          ..totalBytes = totals.total
          ..speed = prog.speed
          ..eta = prog.eta;
        changed();
      } else if (line.startsWith('[JJS]')) {
        totals.expected = double.tryParse(line.substring(5).trim())?.round();
      } else if (line.startsWith('[JJT]')) {
        t.title = line.substring(5).trim();
        changed();
      } else if (line.startsWith('[JJF]')) {
        t.files.add(line.substring(5).trim());
      } else if (line.startsWith('[download] Destination: ')) {
        if (files++ > 0) totals.nextFile();
        t.files.add(line.substring('[download] Destination: '.length).trim());
      } else if (line.startsWith('[Merger] Merging formats into "')) {
        t
          ..speed = ''
          ..eta = tr('영상 · 음성 합치는 중');
        changed();
        t.files.add(line.substring('[Merger] Merging formats into "'.length).replaceFirst(RegExp(r'"$'), ''));
      }
    }

    final outDone = proc.stdout
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .forEach(onLine);
    final errDone = proc.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .forEach((l) {
      errTail.add(l);
      if (errTail.length > 8) errTail.removeAt(0);
    });

    final code = await proc.exitCode;
    await Future.wait([outDone, errDone]);
    _procs.remove(t.id);
    if (_stopping.remove(t.id)) return; // 일시정지·취소는 호출한 쪽에서 상태 설정
    if (code == 0) {
      t
        ..state = DownloadState.done
        ..progress = 1
        ..receivedBytes = t.totalBytes ?? t.receivedBytes
        ..speed = ''
        ..eta = '';
    } else {
      final err = errTail.join('\n');
      // 쿠키를 읽지 못한 경우 (고른 브라우저가 없거나 켜져 있음 등):
      // 앱 안 브라우저의 쿠키로, 그것도 안 되면 쿠키 없이 다시 받는다
      if (isCookieReadError(err)) {
        final stage = t.extra['cookieStage'] as int? ?? 0;
        final used = _cookiesFor(t).join(' ');
        final fallback = fallbackCookieArgs().join(' ');
        // 쿠키를 쓰고 있었을 때만 다시 시도 (쿠키 없이 받다가 난 오류는 그대로 알린다)
        if (stage < 2 && used.isNotEmpty) {
          t.extra['cookieStage'] = stage == 0 && fallback.isNotEmpty && fallback != used ? 1 : 2;
          return start(t, changed);
        }
      }
      t
        ..state = DownloadState.failed
        ..error = friendlyYtDlpError(
            errTail.where((l) => l.contains('ERROR')).join('\n').ifEmpty(errTail.join('\n')));
    }
    changed();
  }

  Future<void> _stop(DownloadTask t) async {
    final proc = _procs[t.id];
    if (proc == null) return;
    _stopping.add(t.id);
    // yt-dlp 가 띄운 ffmpeg 까지 함께 종료
    if (Platform.isWindows) {
      await Process.run('taskkill', ['/PID', '${proc.pid}', '/T', '/F']);
    } else {
      proc.kill();
    }
    await proc.exitCode.timeout(const Duration(seconds: 5), onTimeout: () => -1);
  }

  @override
  Future<void> pause(DownloadTask t) async {
    await _stop(t);
    t
      ..state = DownloadState.paused
      ..speed = ''
      ..eta = '';
  }

  @override
  Future<void> cancel(DownloadTask t) async {
    await _stop(t);
    t
      ..state = DownloadState.cancelled
      ..speed = ''
      ..eta = '';
    for (final f in t.files) {
      for (final path in [f, '$f.part', '$f.ytdl']) {
        try {
          final file = File(path);
          if (await file.exists()) await file.delete();
        } catch (_) {}
      }
    }
    // 조각 파일 (영상.f137.mp4.part 등)
    try {
      final dir = Directory(t.dir);
      if (await dir.exists()) {
        await for (final e in dir.list()) {
          final n = p.basename(e.path);
          if (e is File && (n.endsWith('.part') || n.endsWith('.ytdl')) &&
              t.files.any((f) => n.startsWith(p.basenameWithoutExtension(f)))) {
            await e.delete();
          }
        }
      }
    } catch (_) {}
  }

  @override
  Future<void> shutdown() async {
    for (final id in _procs.keys.toList()) {
      final proc = _procs[id]!;
      _stopping.add(id);
      if (Platform.isWindows) {
        await Process.run('taskkill', ['/PID', '${proc.pid}', '/T', '/F']);
      } else {
        proc.kill();
      }
    }
    _procs.clear();
  }
}

extension on String {
  String ifEmpty(String other) => isEmpty ? other : this;
}
