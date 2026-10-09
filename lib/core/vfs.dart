import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'webdav.dart';

/// 로컬 경로와 WebDAV 경로 (`dav://<서버 id>/<경로>`) 를 같이 다루는 도구.
/// 로컬 경로는 원래 코드 (dart:io) 를 그대로 쓰고, dav:// 만 여기서 WebDAV 로 처리한다.
const davScheme = 'dav://';

bool isDav(String path) => path.startsWith(davScheme);

/// dav:// 경로: 서버 id 와 서버 기준 경로 ("/" 로 시작, 끝 / 없음, 맨 위는 "/")
class DavPath {
  final String server;
  final String rel;
  const DavPath(this.server, this.rel);

  /// "dav://id/a/b" · "dav://id/a\b" (p.join 이 붙인 \ ) · "dav://id" → 정리
  static DavPath parse(String path) {
    var rest = path.substring(davScheme.length).replaceAll('\\', '/');
    final slash = rest.indexOf('/');
    final server = slash < 0 ? rest : rest.substring(0, slash);
    var rel = slash < 0 ? '/' : rest.substring(slash);
    rel = rel.replaceAll(RegExp(r'/+'), '/');
    if (rel.length > 1 && rel.endsWith('/')) rel = rel.substring(0, rel.length - 1);
    if (rel.isEmpty) rel = '/';
    return DavPath(server, rel);
  }

  bool get isRoot => rel == '/';
  String get full => isRoot ? '$davScheme$server/' : '$davScheme$server$rel';
  String get name => isRoot ? '' : rel.substring(rel.lastIndexOf('/') + 1);
  DavPath get parent => isRoot ? this : DavPath(server, rel.lastIndexOf('/') <= 0 ? '/' : rel.substring(0, rel.lastIndexOf('/')));
  DavPath child(String n) => DavPath(server, isRoot ? '/$n' : '$rel/$n');
  DavClient get client => DavRegistry.client(server);
}

/// WebDAV 파일을 받지 않고 바로 재생 (스트리밍) 할 주소 · 헤더 (인증은 헤더로만 - 주소에 비밀번호를 넣지 않는다)
({String url, Map<String, String> headers, bool insecure}) davStream(String path) {
  final d = DavPath.parse(path);
  final server = DavRegistry.server(d.server);
  final client = d.client;
  final uri = client.uriOf(d.rel);
  final auth = client.authHeader;
  return (
    url: uri.toString(),
    headers: {'Authorization': ?auth},
    insecure: server?.insecure ?? false,
  );
}

/// 외부 프로그램 · 다른 앱에 넘길 주소: WebDAV 는 스트리밍 주소, 로컬은 그대로.
/// 사용자 결정 (55): 다른 앱으로 넘기는 주소에는 아이디 · 비밀번호를 넣지 않는다 (받는 앱이 물어본다)
String vPlayable(String path) => isDav(path) ? davStream(path).url : path;

/// 경로를 한 모양으로 (dav:// 만 정리, 로컬은 그대로)
String vNorm(String path) => isDav(path) ? DavPath.parse(path).full : path;
String vJoin(String dir, String name) => isDav(dir) ? DavPath.parse(dir).child(name).full : p.join(dir, name);
String vDirname(String path) => isDav(path) ? DavPath.parse(path).parent.full : p.dirname(path);
String vBasename(String path) => isDav(path) ? DavPath.parse(path).name : p.basename(path);

/// 같은 서버의 dav 경로끼리 같은지 · 안에 있는지 (로컬은 null - 원래 함수가 판단)
bool? davSame(String a, String b) {
  if (!isDav(a) && !isDav(b)) return null;
  if (isDav(a) != isDav(b)) return false;
  return DavPath.parse(a).full == DavPath.parse(b).full;
}

bool? davInside(String a, String b) {
  if (!isDav(a) && !isDav(b)) return null;
  if (isDav(a) != isDav(b)) return false;
  final x = DavPath.parse(a), y = DavPath.parse(b);
  if (x.server != y.server) return false;
  return x.rel == y.rel || y.isRoot || x.rel.startsWith('${y.rel}/');
}

/// 항목 정보 (없으면 null)
Future<({bool isDir, int size, DateTime modified})?> vStat(String path) async {
  if (isDav(path)) {
    final d = DavPath.parse(path);
    final s = await d.client.stat(d.rel);
    return s == null ? null : (isDir: s.isDir, size: s.size, modified: s.modified);
  }
  final st = await FileStat.stat(path);
  if (st.type == FileSystemEntityType.notFound) return null;
  return (isDir: st.type == FileSystemEntityType.directory, size: st.size, modified: st.modified);
}

Future<bool> vIsDir(String path) async => (await vStat(path))?.isDir ?? false;
Future<bool> vExists(String path) async => (await vStat(path)) != null;

/// 동기 확인 (dav 는 네트워크라 알 수 없으므로 "있다" 로 본다)
bool vMissingSync(String path) => !isDav(path) && FileSystemEntity.typeSync(path) == FileSystemEntityType.notFound;
bool vIsDirSync(String path) => isDav(path) ? !DavPath.parse(path).name.contains('.') : FileSystemEntity.isDirectorySync(path);

/// 폴더 안의 항목: (경로, 폴더인지, 크기, 바뀐 때).
/// [strict]: 폴더를 읽지 못하면 빈 목록 대신 오류 (동기화의 "지우기" 가 원본을 빈 것으로 보지 않게)
Future<List<({String path, bool isDir, int size, DateTime modified})>> vList(String dir, {bool strict = false}) async {
  if (isDav(dir)) {
    final d = DavPath.parse(dir);
    return [
      for (final i in await d.client.list(d.rel))
        (path: DavPath(d.server, i.rel).full, isDir: i.isDir, size: i.size, modified: i.modified),
    ];
  }
  final out = <({String path, bool isDir, int size, DateTime modified})>[];
  final list = strict ? Directory(dir).list(followLinks: false) : Directory(dir).list(followLinks: false).handleError((_) {});
  await for (final e in list) {
    try {
      final st = await e.stat();
      final isDir = st.type == FileSystemEntityType.directory;
      out.add((path: e.path, isDir: isDir, size: isDir ? 0 : st.size, modified: st.modified));
    } catch (_) {}
  }
  return out;
}

Future<void> vMkdirs(String dir) async {
  if (isDav(dir)) {
    final d = DavPath.parse(dir);
    await d.client.mkdirs(d.rel);
  } else {
    await Directory(dir).create(recursive: true);
  }
}

/// 지우기 (폴더면 안의 것까지)
Future<void> vDelete(String path) async {
  if (isDav(path)) {
    final d = DavPath.parse(path);
    await d.client.delete(d.rel);
    return;
  }
  final t = FileSystemEntity.typeSync(path, followLinks: false);
  if (t == FileSystemEntityType.directory) {
    await Directory(path).delete(recursive: true);
  } else if (t != FileSystemEntityType.notFound) {
    await File(path).delete();
  }
}

Future<Stream<List<int>>> vOpenRead(String path) async {
  if (isDav(path)) {
    final d = DavPath.parse(path);
    return d.client.openRead(d.rel);
  }
  return File(path).openRead();
}

/// [data] 를 [path] 에 쓴다 (로컬은 임시 이름에 쓴 뒤 바꾸고, [modified] 가 있으면 바뀐 때도 맞춘다)
Future<void> vWrite(String path, Stream<List<int>> data, {int? length, DateTime? modified}) async {
  if (isDav(path)) {
    // 임시 이름으로 다 올린 뒤 서버에서 이름을 바꾼다 (보내다 끊겨도 반쪽 파일이 완성된 이름으로 남지 않게)
    final d = DavPath.parse(path);
    final tmp = d.parent.child('${d.name}.jjpart');
    try {
      await d.client.write(tmp.rel, data, length: length);
    } catch (_) {
      try {
        await d.client.delete(tmp.rel);
      } catch (_) {}
      rethrow;
    }
    await d.client.move(tmp.rel, d.rel, overwrite: true);
    return;
  }
  final tmp = '$path.jjsync';
  final out = File(tmp).openWrite();
  try {
    await out.addStream(data);
  } catch (_) {
    // 실패 · 취소: 반쯤 쓴 임시 파일을 남기지 않는다 (원래 파일은 그대로)
    await out.close();
    try {
      await File(tmp).delete();
    } catch (_) {}
    rethrow;
  } finally {
    await out.close();
  }
  if (await File(path).exists()) await File(path).delete();
  await File(tmp).rename(path);
  if (modified != null) {
    try {
      await File(path).setLastModified(modified);
    } catch (_) {}
  }
}

/// 같은 서버 안에서 이름 바꾸기 · 옮기기
Future<void> vRename(String from, String to) async {
  if (isDav(from) && isDav(to)) {
    final a = DavPath.parse(from), b = DavPath.parse(to);
    if (a.server == b.server) {
      await a.client.move(a.rel, b.rel);
      return;
    }
  }
  if (isDav(from) || isDav(to)) throw FileSystemException('다른 저장소로는 이름만 바꿀 수 없습니다', from);
  if (FileSystemEntity.isDirectorySync(from)) {
    await Directory(from).rename(to);
  } else {
    await File(from).rename(to);
  }
}

/// [dir] 안에서 겹치지 않는 이름 ("이름 (2).확장자")
Future<String> vUniqueTarget(String dir, String name) async {
  var target = vJoin(dir, name);
  if (!await vExists(target)) return target;
  final ext = p.extension(name), base = p.basenameWithoutExtension(name);
  for (var i = 2;; i++) {
    target = vJoin(dir, '$base ($i)$ext');
    if (!await vExists(target)) return target;
  }
}

/// 원격 파일을 열거나 재생하려면 로컬로 받아야 한다: 임시 폴더에 받은 경로 (로컬이면 그대로)
Future<String> vLocalCopy(String path, String tempDir, {void Function(int done, int total)? onProgress}) async {
  if (!isDav(path)) return path;
  final d = DavPath.parse(path);
  final st = await d.client.stat(d.rel);
  final dir = Directory(p.join(tempDir, 'jj_webdav', d.server, p.dirname(d.rel.substring(1))));
  await dir.create(recursive: true);
  final out = File(p.join(dir.path, d.name));
  // 이미 받아 둔 것 (크기 · 바뀐 때 같음) 은 다시 받지 않는다
  if (st != null && await out.exists() && await out.length() == st.size && !(await out.lastModified()).isBefore(st.modified)) {
    return out.path;
  }
  var done = 0;
  final sink = out.openWrite();
  try {
    await for (final chunk in await d.client.openRead(d.rel)) {
      sink.add(chunk);
      done += chunk.length;
      onProgress?.call(done, st?.size ?? 0);
    }
  } finally {
    await sink.close();
  }
  return out.path;
}

/// 폴더 안 파일 수 (안쪽까지)
Future<int> vCountFiles(String path) async {
  if (!await vIsDir(path)) return 1;
  var n = 0;
  for (final e in await vList(path)) {
    n += e.isDir ? await vCountFiles(e.path) : 1;
  }
  return n;
}

/// 화면에 보일 경로: WebDAV 는 내부 id 대신 "☁ 서버 이름/경로"
String vDisplay(String path) => isDav(path) ? '☁ ${vVolumeLabel(path)}' : path;

/// 저장소 이름 (화면 표시): dav 는 서버 이름
String vVolumeLabel(String path) {
  if (!isDav(path)) return path;
  final d = DavPath.parse(path);
  return '${DavRegistry.server(d.server)?.label ?? 'WebDAV'}${d.rel == '/' ? '' : d.rel}';
}
