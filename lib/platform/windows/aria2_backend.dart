import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:path/path.dart' as p;

import '../../core/download_detect.dart';
import '../../services/downloader.dart';
import '../../l10n/tr.dart';
import 'ytdlp_backend.dart' show locateTool;

/// aria2 로 토렌트 · 마그넷 다운로드.
///
/// aria2c 를 RPC 모드(127.0.0.1 전용, 비밀 토큰)로 한 번 띄우고 JSON-RPC 로 제어한다.
/// 받기가 끝나면 올려 주기(시딩)는 바로 멈춘다 (--seed-time=0).
class Aria2Backend implements DownloadBackend {
  final String aria2c;
  Process? _daemon;
  int? _port;
  late final String _secret = _randomToken();
  final _client = HttpClient();
  Timer? _poll;
  final _tasks = <String, (DownloadTask, void Function())>{};

  /// 추가 환경 변수 · 인수 (Android: 라이브러리 위치 · 인증서 파일)
  final Map<String, String> environment;
  final List<String> extraArgs;

  Aria2Backend({String? aria2c, this.environment = const {}, this.extraArgs = const []})
      : aria2c = aria2c ?? locateTool('aria2c');

  @override
  DownloadKind get kind => DownloadKind.torrent;

  @override
  Future<(String, List<PlaylistEntry>)?> expandPlaylist(String url) async => null;

  static String _randomToken() {
    final r = math.Random.secure();
    return List.generate(24, (_) => r.nextInt(36).toRadixString(36)).join();
  }

  Future<void> _ensureDaemon() async {
    if (_daemon != null) return;
    // 빈 포트 고르기
    final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    _port = s.port;
    await s.close();
    _daemon = await Process.start(aria2c, [
      '--enable-rpc', '--rpc-listen-all=false', '--rpc-listen-port=$_port',
      '--rpc-secret=$_secret',
      '--seed-time=0', '--continue=true', '--max-concurrent-downloads=5',
      '--bt-save-metadata=false', '--follow-torrent=mem',
      '--console-log-level=warn', '--summary-interval=0',
      '--file-allocation=none', '--auto-file-renaming=false',
      ...extraArgs,
    ], environment: environment.isEmpty ? null : environment);
    _daemon!.stdout.drain<void>();
    _daemon!.stderr.drain<void>();
    unawaited(_daemon!.exitCode.then((_) => _daemon = null));
    // RPC 준비 대기
    for (var i = 0; i < 50; i++) {
      try {
        await _call('aria2.getVersion', []);
        return;
      } catch (_) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
    throw SocketException(tr('aria2 RPC 에 연결할 수 없습니다.'));
  }

  Future<dynamic> _call(String method, List<Object?> params) async {
    final payload = utf8.encode(jsonEncode({
      'jsonrpc': '2.0', 'id': 'jj', 'method': method,
      'params': ['token:$_secret', ...params],
    }));
    final req = await _client.postUrl(Uri.parse('http://127.0.0.1:$_port/jsonrpc'));
    req.headers.contentType = ContentType.json;
    // aria2 는 chunked 전송을 해석하지 못하므로 길이를 명시
    req.contentLength = payload.length;
    req.add(payload);
    final res = await req.close();
    final body = jsonDecode(await res.transform(utf8.decoder).join()) as Map;
    if (body['error'] != null) throw Exception((body['error'] as Map)['message']);
    return body['result'];
  }

  @override
  Future<void> start(DownloadTask t, void Function() changed) async {
    await Directory(t.dir).create(recursive: true);
    try {
      await _ensureDaemon();
      final gid = t.extra['gid'] as String?;
      if (gid != null) {
        await _call('aria2.unpause', [gid]);
      } else {
        t.extra['gid'] = await _call('aria2.addUri', [
          [t.source],
          {'dir': t.dir},
        ]) as String;
      }
      t
        ..state = DownloadState.downloading
        ..error = null;
      _tasks[t.id] = (t, changed);
      _poll ??= Timer.periodic(const Duration(seconds: 1), (_) => _refresh());
    } catch (e) {
      t
        ..state = DownloadState.failed
        ..error = trf('aria2 오류: {0}', [e]);
    }
    changed();
  }

  Future<void> _refresh() async {
    for (final (t, changed) in _tasks.values.toList()) {
      final gid = t.extra['gid'] as String?;
      if (gid == null || t.state != DownloadState.downloading) continue;
      try {
        final s = await _call('aria2.tellStatus', [
          gid,
          ['status', 'totalLength', 'completedLength', 'downloadSpeed', 'followedBy',
            'bittorrent', 'files', 'errorMessage'],
        ]) as Map;
        // 마그넷: 메타데이터를 받은 뒤 실제 다운로드로 넘어감
        final followed = s['followedBy'] as List?;
        if (followed != null && followed.isNotEmpty) {
          t.extra['gid'] = followed.first as String;
          continue;
        }
        final total = int.tryParse('${s['totalLength']}') ?? 0;
        final done = int.tryParse('${s['completedLength']}') ?? 0;
        final speed = int.tryParse('${s['downloadSpeed']}') ?? 0;
        final name = ((s['bittorrent'] as Map?)?['info'] as Map?)?['name'] as String?;
        if (name != null && name.isNotEmpty) t.title = name;
        for (final f in (s['files'] as List? ?? const [])) {
          final path = (f as Map)['path'] as String? ?? '';
          if (path.isNotEmpty && !path.startsWith('[METADATA]')) t.files.add(path);
        }
        if (t.title == t.source && t.files.isNotEmpty) t.title = p.basename(t.files.first);
        t
          ..progress = total > 0 ? done / total : null
          ..receivedBytes = total > 0 ? done : null
          ..totalBytes = total > 0 ? total : null
          ..speed = speed > 0 ? '${formatBytes(speed)}/s' : ''
          ..eta = speed > 0 && total > done ? _eta((total - done) ~/ speed) : '';
        switch (s['status']) {
          case 'complete':
            t
              ..state = DownloadState.done
              ..progress = 1
              ..speed = ''
              ..eta = '';
            _tasks.remove(t.id);
          case 'error':
            t
              ..state = DownloadState.failed
              ..error = '${s['errorMessage']}';
            _tasks.remove(t.id);
          case 'removed':
            _tasks.remove(t.id);
        }
        changed();
      } catch (_) {
        // 일시적인 RPC 오류는 다음 주기에 다시 시도
      }
    }
  }

  static String _eta(int sec) {
    if (sec >= 3600) return trf('{0}시간 {1}분', [sec ~/ 3600, (sec % 3600) ~/ 60]);
    if (sec >= 60) return trf('{0}분 {1}초', [sec ~/ 60, sec % 60]);
    return trf('{0}초', [sec]);
  }

  @override
  Future<void> pause(DownloadTask t) async {
    final gid = t.extra['gid'] as String?;
    if (gid != null && _daemon != null) {
      try {
        await _call('aria2.forcePause', [gid]);
      } catch (_) {}
    }
    t
      ..state = DownloadState.paused
      ..speed = ''
      ..eta = '';
  }

  @override
  Future<void> cancel(DownloadTask t) async {
    final gid = t.extra['gid'] as String?;
    if (gid != null && _daemon != null) {
      try {
        await _call('aria2.forceRemove', [gid]);
        await _call('aria2.removeDownloadResult', [gid]);
      } catch (_) {}
    }
    _tasks.remove(t.id);
    t
      ..state = DownloadState.cancelled
      ..speed = ''
      ..eta = '';
    await Future<void>.delayed(const Duration(milliseconds: 300)); // 파일 핸들 해제 대기
    for (final f in t.files) {
      for (final path in [f, '$f.aria2']) {
        try {
          final file = File(path);
          if (await file.exists()) await file.delete();
        } catch (_) {}
      }
    }
  }

  @override
  Future<void> shutdown() async {
    _poll?.cancel();
    _poll = null;
    final d = _daemon;
    if (d != null) {
      try {
        await _call('aria2.forceShutdown', []);
        await d.exitCode.timeout(const Duration(seconds: 5));
      } catch (_) {
        d.kill();
      }
    }
    _daemon = null;
    _client.close(force: true);
  }
}
