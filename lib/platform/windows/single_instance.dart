import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../core/playlist.dart';

/// 이 프로세스를 바로 끝낸다. Dart 의 exit() 는 엔진 · 창 · 플러그인 DLL 을 정리하는 중에 Windows 의
/// coremessaging.dll 등에서 접근 위반 (0xc0000005) 으로 꺼지기도 한다 - 특히 막 뜬 두 번째 실행이 바로 끝날 때
/// (재현: 앱이 켜져 있을 때 한 번 더 실행 → APPCRASH). 저장할 것이 없는 경우에만 쓴다.
Never endProcessNow() {
  if (Platform.isWindows) Process.killPid(pid);
  exit(0);
}

/// 프로그램을 하나만 실행하고, 나중에 실행된 것은 인수를 첫 번째 창에 넘기고 끝낸다.
///
/// 탐색기에서 파일 여러 개를 골라 "재생" 하면 파일마다 프로그램이 실행되므로,
/// 짧은 시간([gather]) 안에 들어온 요청을 하나로 모아 전달한다.
class SingleInstance {
  static const _magic = 'JJMKVMAKER1';

  final int port;
  final Duration gather;
  ServerSocket? _server;
  final _pending = <LaunchAction, List<String>>{};
  Timer? _timer;
  void Function(LaunchRequest)? _onRequest;

  SingleInstance({this.port = 47821, this.gather = const Duration(milliseconds: 700)});

  /// 첫 번째 실행이면 true (요청을 받을 준비). 이미 실행 중이면 인수를 넘기고 false.
  /// [waitForExit]: 재시작 - 기존 창이 닫힐 때까지 (최대 15초) 기다렸다가 첫 번째가 된다.
  /// [forward] 가 false 면 이미 실행 중이어도 인수를 넘기지 않는다 (새 재생 창으로 따로 뜰 때).
  Future<bool> claim(LaunchRequest initial, {bool waitForExit = false, bool forward = true}) async {
    for (var i = 0;; i++) {
      try {
        _server = await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
        break;
      } on SocketException {
        if (waitForExit && i < 60) {
          await Future<void>.delayed(const Duration(milliseconds: 250));
          continue;
        }
        if (!forward) return false;
        if (await _forward(initial)) return false;
        return true; // 다른 프로그램이 포트를 쓰는 경우: 넘기지 못했으므로 그냥 실행
      }
    }
    _server!.listen(_accept);
    _add(initial);
    return true;
  }

  /// 모인 요청을 처리할 함수 (앱 준비가 끝난 뒤 등록)
  void listen(void Function(LaunchRequest) onRequest) {
    _onRequest = onRequest;
    if (_pending.isNotEmpty) _schedule();
  }

  Future<bool> _forward(LaunchRequest r) async {
    try {
      final s = await Socket.connect(InternetAddress.loopbackIPv4, port,
          timeout: const Duration(seconds: 2));
      s.write('$_magic ${jsonEncode(r.toArgs())}\n');
      await s.flush();
      final reply = await utf8.decoder.bind(s).join().timeout(const Duration(seconds: 3));
      await s.close();
      return reply.startsWith('OK');
    } catch (_) {
      return false;
    }
  }

  void _accept(Socket s) {
    utf8.decoder.bind(s).transform(const LineSplitter()).first.then((line) {
      if (line.startsWith('$_magic ')) {
        final args = (jsonDecode(line.substring(_magic.length + 1)) as List).cast<String>();
        _add(LaunchRequest.parse(args));
        s.write('OK');
      }
      return s.close();
    }).catchError((_) => s.destroy());
  }

  void _add(LaunchRequest r) {
    // 파일 없이 실행된 경우도 "창 보이기" 요청으로 전달
    _pending.putIfAbsent(r.action, () => []).addAll(r.files);
    _schedule();
  }

  void _schedule() {
    if (_onRequest == null) return;
    _timer?.cancel();
    _timer = Timer(gather, () {
      final items = Map.of(_pending);
      _pending.clear();
      for (final e in items.entries) {
        _onRequest!(LaunchRequest(e.key, e.value.toSet().toList()));
      }
    });
  }

  Future<void> close() async {
    _timer?.cancel();
    await _server?.close();
  }
}
