import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:xml/xml.dart';

import '../l10n/tr.dart';
import 'secret_gate.dart';

/// WebDAV 서버 설정 (환경 설정 > 파일 탐색기 > WebDAV). 비밀번호는 안전 저장소에 (설정 파일 · 보관본에는 넣지 않음).
class DavServer {
  final String id;
  final String name;

  /// 예: https://nas.local:5006/home  ·  https://cloud.example.com/remote.php/dav/files/me
  final String url;
  final String user;
  final String password;

  /// 인증서를 확인하지 않음 (자체 서명 인증서를 쓰는 집 NAS 등)
  final bool insecure;

  const DavServer({
    required this.id,
    required this.name,
    required this.url,
    this.user = '',
    this.password = '',
    this.insecure = false,
  });

  /// 탐색기 위쪽에 보일 이름
  String get label => name.trim().isNotEmpty ? name.trim() : (Uri.tryParse(url)?.host ?? 'WebDAV');

  DavServer copyWith({String? name, String? url, String? user, String? password, bool? insecure}) => DavServer(
        id: id,
        name: name ?? this.name,
        url: url ?? this.url,
        user: user ?? this.user,
        password: password ?? this.password,
        insecure: insecure ?? this.insecure,
      );

  /// 비밀번호는 넣지 않는다 (안전 저장소에 둔다 - 54). 저장해 두었는지만
  Map<String, Object?> toJson() =>
      {'id': id, 'name': name, 'url': url, 'user': user, 'hasPassword': password.isNotEmpty, 'insecure': insecure};

  factory DavServer.fromJson(Map<Object?, Object?> j) => DavServer(
        id: '${j['id'] ?? DateTime.now().microsecondsSinceEpoch}',
        name: j['name'] as String? ?? '',
        url: j['url'] as String? ?? '',
        user: j['user'] as String? ?? '',
        // 예전 설정 파일의 평문 비밀번호 (읽으면 안전 저장소로 옮긴다)
        password: j['password'] as String? ?? '',
        insecure: j['insecure'] == true,
      );
}

/// 목록의 한 항목 ([rel]: 서버 기준 경로, "/" 로 시작, 끝 / 없음 · 맨 위는 "/")
class DavItem {
  final String rel;
  final bool isDir;
  final int size;
  final DateTime modified;
  const DavItem(this.rel, {required this.isDir, this.size = 0, required this.modified});
}

/// 124 · 128: 마스터 비밀번호를 넣지 않아 저장된 비밀번호를 쓰지 못함 (원본을 못 읽은 것이 아니라 기다리는 중)
class DavLockedException extends DavException {
  const DavLockedException(super.message);
}

class DavException implements Exception {
  final String message;
  final int? status;

  /// 서버가 옮기라고 한 주소 (301 · 302 · 307 · 308)
  final String? location;
  const DavException(this.message, {this.status, this.location});

  /// http 주소의 서버가 https 로 옮기라고 했는지
  bool get wantsHttps => location != null && location!.toLowerCase().startsWith('https://');
  @override
  String toString() => message;
}

/// WebDAV 클라이언트: PROPFIND (목록) · GET · PUT · MKCOL · DELETE · MOVE · COPY. 기본 인증 (Basic).
class DavClient {
  final DavServer server;
  late final HttpClient _http = HttpClient()
    ..connectionTimeout = const Duration(seconds: 15)
    ..badCertificateCallback = server.insecure ? (_, _, _) => true : null;

  DavClient(this.server);

  late final Uri _base = () {
    final u = Uri.parse(server.url.trim());
    final path = u.path.endsWith('/') ? u.path.substring(0, u.path.length - 1) : u.path;
    return u.replace(path: path);
  }();

  /// 서버 기준 경로 → 주소 (각 부분을 인코딩)
  Uri uriOf(String rel, {bool dir = false}) {
    final parts = rel.split('/').where((x) => x.isNotEmpty).map(Uri.encodeComponent);
    final tail = parts.join('/');
    final path = '${_base.path}/$tail${dir && tail.isNotEmpty ? '/' : ''}';
    return _base.replace(path: path);
  }

  /// Authorization 헤더 값 (아이디 · 비밀번호가 없으면 null). 플레이어가 스트리밍할 때도 쓴다.
  String? get authHeader => _auth;

  String? get _auth => server.user.isEmpty && server.password.isEmpty
      ? null
      : 'Basic ${base64Encode(utf8.encode('${server.user}:${server.password}'))}';

  Future<HttpClientRequest> _open(String method, Uri uri) async {
    // 124: 저장된 비밀번호로 접속하기 전에 (마스터 비밀번호를 정해 두었으면 묻는다)
    if (server.password.isNotEmpty && !await SecretGate.pass()) throw DavLockedException(tr(secretGateMessage));
    final req = await _http.openUrl(method, uri);
    final a = _auth;
    if (a != null) req.headers.set(HttpHeaders.authorizationHeader, a);
    req.followRedirects = false;
    return req;
  }

  Never _fail(String what, HttpClientResponse res, [String body = '']) {
    // 다른 주소로 옮기라고 함 (http → https 등): 이유와 할 일을 알린다
    if (const [301, 302, 303, 307, 308].contains(res.statusCode)) {
      final loc = res.headers.value(HttpHeaders.locationHeader);
      final https = loc != null && loc.toLowerCase().startsWith('https://') && server.url.toLowerCase().startsWith('http://');
      throw DavException(
        https
            ? trf('서버가 https 주소로 옮기라고 합니다 ({0}). 서버 설정의 주소를 https:// 로 바꾸세요.', [loc])
            : trf('서버가 다른 주소로 옮기라고 합니다 ({0}). 서버 설정의 주소를 확인하세요.', [loc ?? '-']),
        status: res.statusCode,
        location: loc,
      );
    }
    final hint = switch (res.statusCode) {
      // 54: 비밀번호가 틀린 것이 아니라 저장된 것이 없다 (동기화 · 복사 오류에도 그대로 보인다)
      401 when server.password.isEmpty => ' (${tr('저장된 비밀번호가 없습니다. 한 번만 다시 넣어 주세요')})',
      401 => ' (아이디 · 비밀번호를 확인하세요)',
      403 => ' (권한 없음)',
      404 => ' (없는 경로)',
      405 => ' (서버가 이 기능을 허용하지 않음)',
      507 => ' (서버 저장 공간 부족)',
      _ => '',
    };
    throw DavException('WebDAV $what 실패: ${res.statusCode} ${res.reasonPhrase}$hint', status: res.statusCode);
  }

  static const _propfindBody = '<?xml version="1.0" encoding="utf-8"?>'
      '<d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/><d:getcontentlength/><d:getlastmodified/></d:prop></d:propfind>';

  Future<String> _propfind(String rel, {required int depth, String body = _propfindBody}) async {
    final req = await _open('PROPFIND', uriOf(rel, dir: depth > 0));
    req.headers
      ..set('Depth', '$depth')
      ..contentType = ContentType('application', 'xml', charset: 'utf-8');
    // 길이를 꼭 알린다 (chunked 로 보내면 404 등에서 본문을 읽지 않는 서버가 남은 본문을 다음 요청으로 오해함)
    final bytes = utf8.encode(body);
    req.contentLength = bytes.length;
    req.add(bytes);
    final res = await req.close();
    final text = await res.transform(utf8.decoder).join();
    if (res.statusCode == 404) throw DavException('없는 경로: $rel', status: 404);
    if (res.statusCode != 207 && res.statusCode != 200) _fail('목록', res, text);
    return text;
  }

  /// 응답의 href → 서버 기준 경로
  String _relOf(String href) {
    var path = Uri.tryParse(href)?.path ?? href;
    path = Uri.decodeFull(path);
    final base = Uri.decodeFull(_base.path);
    if (path.startsWith(base)) path = path.substring(base.length);
    path = path.replaceAll(RegExp(r'/+'), '/');
    if (path.length > 1 && path.endsWith('/')) path = path.substring(0, path.length - 1);
    return path.isEmpty ? '/' : (path.startsWith('/') ? path : '/$path');
  }

  List<DavItem> _parse(String xml) {
    final doc = XmlDocument.parse(xml);
    final out = <DavItem>[];
    for (final r in doc.findAllElements('response', namespaceUri: 'DAV:')) {
      final href = r.findElements('href', namespaceUri: 'DAV:').firstOrNull?.innerText.trim();
      if (href == null) continue;
      // 200 인 propstat 만
      XmlElement? prop;
      for (final ps in r.findElements('propstat', namespaceUri: 'DAV:')) {
        final st = ps.findElements('status', namespaceUri: 'DAV:').firstOrNull?.innerText ?? '';
        if (st.contains(' 200')) prop = ps.findElements('prop', namespaceUri: 'DAV:').firstOrNull;
      }
      prop ??= r.findAllElements('prop', namespaceUri: 'DAV:').firstOrNull;
      final isDir = prop?.findAllElements('collection', namespaceUri: 'DAV:').isNotEmpty ?? href.endsWith('/');
      final len = int.tryParse(prop?.findElements('getcontentlength', namespaceUri: 'DAV:').firstOrNull?.innerText.trim() ?? '');
      final mod = prop?.findElements('getlastmodified', namespaceUri: 'DAV:').firstOrNull?.innerText.trim();
      DateTime when;
      try {
        when = mod == null || mod.isEmpty ? DateTime.fromMillisecondsSinceEpoch(0) : HttpDate.parse(mod).toLocal();
      } catch (_) {
        when = DateTime.fromMillisecondsSinceEpoch(0);
      }
      out.add(DavItem(_relOf(href), isDir: isDir, size: isDir ? 0 : (len ?? 0), modified: when));
    }
    return out;
  }

  /// 폴더 안의 항목 (자기 자신은 뺌)
  Future<List<DavItem>> list(String rel) async {
    final self = _norm(rel);
    final items = _parse(await _propfind(self, depth: 1));
    return [for (final i in items) if (i.rel != self) i];
  }

  /// 항목 정보 (없으면 null)
  Future<DavItem?> stat(String rel) async {
    try {
      final items = _parse(await _propfind(_norm(rel), depth: 0));
      return items.isEmpty ? null : items.first;
    } on DavException catch (e) {
      if (e.status == 404) return null;
      rethrow;
    }
  }

  /// 폴더 만들기 (이미 있으면 그대로)
  Future<void> mkdir(String rel) async {
    final res = await (await _open('MKCOL', uriOf(rel, dir: true))).close();
    await res.drain<void>();
    if (res.statusCode == 201 || res.statusCode == 200) return;
    if (res.statusCode == 405 && (await stat(rel))?.isDir == true) return; // 이미 있음
    _fail('폴더 만들기', res);
  }

  /// 위 폴더까지 차례로 만든다
  Future<void> mkdirs(String rel) async {
    var cur = '';
    for (final part in rel.split('/').where((x) => x.isNotEmpty)) {
      cur = '$cur/$part';
      if ((await stat(cur))?.isDir == true) continue;
      await mkdir(cur);
    }
  }

  Future<void> delete(String rel) async {
    final st = await stat(rel);
    final res = await (await _open('DELETE', uriOf(rel, dir: st?.isDir ?? false))).close();
    await res.drain<void>();
    if (res.statusCode == 404) return;
    if (res.statusCode >= 300) _fail('지우기', res);
  }

  Future<void> _moveOrCopy(String method, String from, String to, {bool overwrite = false}) async {
    final st = await stat(from);
    final req = await _open(method, uriOf(from, dir: st?.isDir ?? false));
    req.headers
      ..set('Destination', uriOf(to, dir: st?.isDir ?? false).toString())
      ..set('Overwrite', overwrite ? 'T' : 'F');
    if (st?.isDir ?? false) req.headers.set('Depth', 'infinity');
    final res = await req.close();
    await res.drain<void>();
    if (res.statusCode >= 300) _fail(method == 'MOVE' ? '이동' : '복사', res);
  }

  Future<void> move(String from, String to, {bool overwrite = false}) => _moveOrCopy('MOVE', from, to, overwrite: overwrite);
  Future<void> copy(String from, String to, {bool overwrite = false}) => _moveOrCopy('COPY', from, to, overwrite: overwrite);

  /// 받기: 내용을 조각으로 (끝나면 스트림이 닫힘)
  Future<Stream<List<int>>> openRead(String rel) async {
    final res = await (await _open('GET', uriOf(rel))).close();
    if (res.statusCode != 200) {
      await res.drain<void>();
      _fail('받기', res);
    }
    return res;
  }

  /// 올리기 ([length] 를 알면 Content-Length 로)
  Future<void> write(String rel, Stream<List<int>> data, {int? length}) async {
    final req = await _open('PUT', uriOf(rel));
    if (length != null) req.contentLength = length;
    await req.addStream(data);
    final res = await req.close();
    await res.drain<void>();
    if (res.statusCode >= 300) _fail('올리기', res);
  }

  /// 남은 용량 · 쓴 용량 (바이트, 서버가 알려 주지 않으면 null)
  Future<(int?, int?)> quota() async {
    try {
      final xml = await _propfind('/', depth: 0,
          body: '<?xml version="1.0" encoding="utf-8"?><d:propfind xmlns:d="DAV:"><d:prop>'
              '<d:quota-available-bytes/><d:quota-used-bytes/></d:prop></d:propfind>');
      final doc = XmlDocument.parse(xml);
      int? n(String name) => int.tryParse(doc.findAllElements(name, namespaceUri: 'DAV:').firstOrNull?.innerText.trim() ?? '');
      return (n('quota-available-bytes'), n('quota-used-bytes'));
    } catch (_) {
      return (null, null);
    }
  }

  void close() => _http.close(force: true);

  static String _norm(String rel) {
    var r = rel.replaceAll('\\', '/').replaceAll(RegExp(r'/+'), '/');
    if (!r.startsWith('/')) r = '/$r';
    if (r.length > 1 && r.endsWith('/')) r = r.substring(0, r.length - 1);
    return r;
  }
}

/// 설정의 WebDAV 서버들 (id → 클라이언트). 설정이 바뀌면 [configure].
class DavRegistry {
  static final _clients = <String, DavClient>{};
  static final _servers = <String, DavServer>{};

  static void configure(List<DavServer> servers) {
    final keep = {for (final s in servers) s.id: s};
    for (final id in _clients.keys.toList()) {
      final old = _servers[id], now = keep[id];
      // 비밀번호는 toJson 에 없으므로 따로 비교 (바꾸면 바로 새 비밀번호로 접속 - 40-2)
      if (now == null ||
          old == null ||
          old.password != now.password ||
          jsonEncode(old.toJson()) != jsonEncode(now.toJson())) {
        _clients.remove(id)?.close();
      }
    }
    _servers
      ..clear()
      ..addAll(keep);
  }

  static List<DavServer> get servers => _servers.values.toList();
  static DavServer? server(String id) => _servers[id];

  static DavClient client(String id) {
    final s = _servers[id];
    if (s == null) throw DavException('WebDAV 서버 설정이 없습니다 ($id)');
    return _clients.putIfAbsent(id, () => DavClient(s));
  }
}
