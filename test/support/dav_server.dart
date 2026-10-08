import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// 시험용 작은 WebDAV 서버 (실제 HTTP): [root] 폴더를 /dav/ 아래로 내보낸다. 기본 인증 (user / pass).
/// PROPFIND (Depth 0 · 1) · GET · PUT · MKCOL · DELETE · MOVE · COPY · quota.
class TestDavServer {
  final Directory root;
  final String user, pass;
  late HttpServer _server;
  final requests = <String>[];

  TestDavServer(this.root, {this.user = 'user', this.pass = 'pass'});

  String get url => 'http://127.0.0.1:${_server.port}/dav';

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen(_handle);
  }

  Future<void> stop() => _server.close(force: true);

  String _local(String uriPath) {
    var rel = Uri.decodeFull(uriPath);
    if (rel.startsWith('/dav')) rel = rel.substring(4);
    rel = rel.replaceAll(RegExp(r'^/+|/+$'), '');
    return rel.isEmpty ? root.path : p.join(root.path, p.joinAll(rel.split('/')));
  }

  String _href(String local, bool dir) {
    final rel = p.relative(local, from: root.path).replaceAll('\\', '/');
    final parts = rel == '.' ? <String>[] : rel.split('/');
    return '/dav/${parts.map(Uri.encodeComponent).join('/')}${dir && parts.isNotEmpty ? '/' : ''}';
  }

  String _entry(FileSystemEntity e) {
    final dir = e is Directory;
    final st = e.statSync();
    return '<d:response><d:href>${_href(e.path, dir)}</d:href><d:propstat><d:prop>'
        '<d:resourcetype>${dir ? '<d:collection/>' : ''}</d:resourcetype>'
        '${dir ? '' : '<d:getcontentlength>${st.size}</d:getcontentlength>'}'
        '<d:getlastmodified>${HttpDate.format(st.modified)}</d:getlastmodified>'
        '<d:quota-available-bytes>1000000</d:quota-available-bytes><d:quota-used-bytes>500</d:quota-used-bytes>'
        '</d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>';
  }

  Future<void> _handle(HttpRequest req) async {
    final res = req.response;
    requests.add('${req.method} ${req.uri.path}');
    final auth = req.headers.value(HttpHeaders.authorizationHeader);
    if (auth != 'Basic ${base64Encode(utf8.encode('$user:$pass'))}') {
      res.statusCode = 401;
      await res.close();
      return;
    }
    final local = _local(req.uri.path);
    final type = FileSystemEntity.typeSync(local);
    try {
      switch (req.method) {
        case 'PROPFIND':
          await req.drain<void>();
          if (type == FileSystemEntityType.notFound) {
            res.statusCode = 404;
            break;
          }
          final depth = req.headers.value('Depth') ?? '1';
          final items = <FileSystemEntity>[type == FileSystemEntityType.directory ? Directory(local) : File(local)];
          if (depth != '0' && type == FileSystemEntityType.directory) items.addAll(Directory(local).listSync());
          res.statusCode = 207;
          res.headers.contentType = ContentType('application', 'xml', charset: 'utf-8');
          res.write('<?xml version="1.0" encoding="utf-8"?><d:multistatus xmlns:d="DAV:">${items.map(_entry).join()}</d:multistatus>');
        case 'GET':
          if (type != FileSystemEntityType.file) {
            res.statusCode = 404;
            break;
          }
          res.contentLength = File(local).lengthSync();
          await res.addStream(File(local).openRead());
        case 'PUT':
          if (!Directory(p.dirname(local)).existsSync()) {
            await req.drain<void>();
            res.statusCode = 409;
            break;
          }
          final out = File(local).openWrite();
          await out.addStream(req);
          await out.close();
          res.statusCode = 201;
        case 'MKCOL':
          await req.drain<void>();
          if (type != FileSystemEntityType.notFound) {
            res.statusCode = 405;
          } else if (!Directory(p.dirname(local)).existsSync()) {
            res.statusCode = 409;
          } else {
            Directory(local).createSync();
            res.statusCode = 201;
          }
        case 'DELETE':
          await req.drain<void>();
          if (type == FileSystemEntityType.directory) {
            Directory(local).deleteSync(recursive: true);
          } else if (type == FileSystemEntityType.file) {
            File(local).deleteSync();
          } else {
            res.statusCode = 404;
            break;
          }
          res.statusCode = 204;
        case 'MOVE' || 'COPY':
          await req.drain<void>();
          final dest = _local(Uri.parse(req.headers.value('Destination')!).path);
          if (FileSystemEntity.typeSync(dest) != FileSystemEntityType.notFound && req.headers.value('Overwrite') == 'F') {
            res.statusCode = 412;
            break;
          }
          if (req.method == 'MOVE') {
            if (type == FileSystemEntityType.directory) {
              Directory(local).renameSync(dest);
            } else {
              File(local).renameSync(dest);
            }
          } else {
            if (type == FileSystemEntityType.directory) {
              _copyDir(Directory(local), Directory(dest));
            } else {
              File(local).copySync(dest);
            }
          }
          res.statusCode = 201;
        default:
          await req.drain<void>();
          res.statusCode = 405;
      }
    } catch (e) {
      res.statusCode = 500;
      res.write('$e');
    }
    await res.close();
  }

  static void _copyDir(Directory from, Directory to) {
    to.createSync(recursive: true);
    for (final e in from.listSync()) {
      final t = p.join(to.path, p.basename(e.path));
      if (e is Directory) {
        _copyDir(e, Directory(t));
      } else if (e is File) {
        e.copySync(t);
      }
    }
  }
}
