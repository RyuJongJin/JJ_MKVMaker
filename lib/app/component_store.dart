import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../core/app_update.dart' show updateRepo;
import '../l10n/tr.dart';

/// 컴포넌트 목록 (GitHub 릴리스 "components" 의 components.json) 주소
const componentsManifestUrl = 'https://github.com/$updateRepo/releases/download/components/components.json';

/// 컴포넌트를 설치할 때 받는 파일 하나
class ComponentFile {
  final String name;
  final String url;

  /// 'msi' (Windows 설치 파일 → 관리 설치로 풀기) · 'zip' (풀기, 예: Java 런타임) · 'oxt' (LibreOffice 확장) · 'file' (그대로 둠)
  final String kind;
  final String? sha256;
  final int size;
  const ComponentFile({required this.name, required this.url, required this.kind, this.sha256, this.size = 0});

  factory ComponentFile.fromJson(Map<String, dynamic> j) => ComponentFile(
        name: j['name'] as String? ?? '',
        url: j['url'] as String,
        kind: j['kind'] as String? ?? 'file',
        sha256: (j['sha256'] as String?)?.toLowerCase(),
        size: (j['size'] as num?)?.toInt() ?? 0,
      );
}

/// components.json: { "format": 1, "components": { "(id)": { "version": "...", "windows": [파일...], "android": [...] } } }
class ComponentManifest {
  final Map<String, Map<String, dynamic>> components;
  const ComponentManifest(this.components);

  factory ComponentManifest.parse(String text) {
    final j = jsonDecode(text) as Map<String, dynamic>;
    final c = (j['components'] as Map<String, dynamic>? ?? const {});
    return ComponentManifest({for (final e in c.entries) e.key: e.value as Map<String, dynamic>});
  }

  /// 이 기기 ([platform]) 에서 그 컴포넌트를 설치할 때 받을 파일들 (없으면 null = 이 기기에서는 못 씀)
  List<ComponentFile>? files(String id, String platform) {
    final list = components[id]?[platform] as List?;
    return list == null ? null : [for (final x in list) ComponentFile.fromJson(x as Map<String, dynamic>)];
  }

  String version(String id) => components[id]?['version'] as String? ?? '';
}

class ComponentException implements Exception {
  final String message;
  const ComponentException(this.message);
  @override
  String toString() => message;
}

/// 컴포넌트 설치 (받기 · 확인 · 풀기) · 제거, 그리고 설치한 도구 쓰기 (문서 → PDF).
/// 앱 데이터 폴더의 components/(id) 아래에 둔다 (앱을 업데이트해도 지워지지 않게).
class ComponentStore {
  final String dataDir;
  final String manifestUrl;
  final HttpClient _http = HttpClient()..userAgent = 'JJMKVMaker';
  bool _cancel = false;

  ComponentStore(this.dataDir, {this.manifestUrl = componentsManifestUrl});

  static ComponentStore? _shared;

  /// 앱의 컴포넌트 저장소 (앱 데이터 폴더). 시험에서는 [ComponentStore.shared] 를 바꿔 쓴다.
  static ComponentStore get shared => _shared ??= ComponentStore(_dataDir ?? Directory.systemTemp.path);
  static set shared(ComponentStore s) => _shared = s;

  /// main 에서 정함 (앱 데이터 폴더)
  static String? _dataDir;
  static set dataDirectory(String d) => _dataDir = d;

  static String get platform => Platform.isWindows
      ? 'windows'
      : Platform.isAndroid
          ? 'android'
          : 'other';

  Directory dirOf(String id) => Directory(p.join(dataDir, 'components', id));
  File _mark(String id) => File(p.join(dirOf(id).path, 'installed.json'));

  bool isInstalled(String id) => _mark(id).existsSync();

  void cancel() => _cancel = true;

  Future<ComponentManifest> manifest() async {
    final req = await _http.getUrl(Uri.parse(manifestUrl));
    final res = await req.close();
    final body = await res.transform(utf8.decoder).join();
    if (res.statusCode != 200) throw ComponentException(trf('컴포넌트 목록을 받을 수 없습니다 ({0})', [res.statusCode]));
    return ComponentManifest.parse(body);
  }

  /// 설치: 목록의 파일을 받아 (SHA-256 확인) 풀고 설치 표시를 남긴다.
  /// [onProgress] (지금 하는 일, 0~1 또는 모르면 null)
  Future<void> install(String id, {void Function(String step, double? progress)? onProgress}) async {
    _cancel = false;
    final m = await manifest();
    final files = m.files(id, platform);
    if (files == null) throw ComponentException(tr('이 기기에서는 쓸 수 없는 컴포넌트입니다'));
    final dir = dirOf(id);
    final dl = Directory(p.join(dir.path, '_download'));
    await dl.create(recursive: true);
    try {
      final got = <(ComponentFile, File)>[];
      for (final f in files) {
        final out = File(p.join(dl.path, f.name.isEmpty ? p.basename(Uri.parse(f.url).path) : f.name));
        await _download(f, out, (d) => onProgress?.call(trf('받는 중: {0}', [f.name]), d));
        got.add((f, out));
      }
      for (final (f, file) in got) {
        if (_cancel) throw ComponentException(tr('취소했습니다'));
        switch (f.kind) {
          case 'msi':
            onProgress?.call(trf('푸는 중: {0}', [f.name]), null);
            await _runMsiAdmin(file.path, p.join(dir.path, 'app'));
          case 'zip':
            onProgress?.call(trf('푸는 중: {0}', [f.name]), null);
            await extractFileToDisk(file.path, p.join(dir.path, 'jre'));
          case 'oxt':
            onProgress?.call(trf('확장 설치: {0}', [f.name]), null);
            await _addExtension(id, file.path);
          default:
            await file.copy(p.join(dir.path, p.basename(file.path)));
        }
      }
      await _mark(id).writeAsString(jsonEncode({'version': m.version(id), 'installed': DateTime.now().toIso8601String()}));
    } finally {
      try {
        await dl.delete(recursive: true);
      } catch (_) {}
    }
  }

  Future<void> remove(String id) async {
    final dir = dirOf(id);
    if (await dir.exists()) await dir.delete(recursive: true);
  }

  Future<void> _download(ComponentFile f, File out, void Function(double? progress) onProgress) async {
    final req = await _http.getUrl(Uri.parse(f.url));
    final res = await req.close();
    if (res.statusCode != 200) throw ComponentException(trf('받을 수 없습니다 ({0}): {1}', [res.statusCode, f.url]));
    final total = res.contentLength > 0 ? res.contentLength : f.size;
    final sink = out.openWrite();
    final hash = AccumulatorSink<Digest>();
    final hasher = sha256.startChunkedConversion(hash);
    var done = 0;
    try {
      await for (final chunk in res) {
        if (_cancel) throw ComponentException(tr('취소했습니다'));
        sink.add(chunk);
        hasher.add(chunk);
        done += chunk.length;
        onProgress(total > 0 ? done / total : null);
      }
    } finally {
      await sink.close();
      hasher.close();
    }
    final sum = hash.events.single.toString();
    if (f.sha256 != null && f.sha256!.isNotEmpty && sum != f.sha256) {
      await out.delete();
      throw ComponentException(trf('파일이 손상되었습니다 (SHA-256 다름): {0}', [f.name]));
    }
  }

  /// Windows 설치 파일 (MSI) 을 관리 설치 (/a) 로 풀기: 관리자 권한 없이 폴더에 프로그램 파일만
  Future<void> _runMsiAdmin(String msi, String target) async {
    await Directory(target).create(recursive: true);
    final r = await Process.run('msiexec', ['/a', msi, '/qn', 'TARGETDIR=$target']);
    if (r.exitCode != 0) throw ComponentException(trf('설치 파일을 풀 수 없습니다 (msiexec {0})', [r.exitCode]));
  }

  // ───────── 문서 미리보기 (LibreOffice) ─────────

  /// 설치한 LibreOffice 의 soffice.exe (없으면 null)
  String? soffice([String id = 'docs']) {
    final root = Directory(p.join(dirOf(id).path, 'app'));
    if (!root.existsSync()) return null;
    for (final e in root.listSync(recursive: true, followLinks: false)) {
      if (e is File && p.basename(e.path).toLowerCase() == 'soffice.exe' && p.basename(p.dirname(e.path)) == 'program') {
        return e.path;
      }
    }
    return null;
  }

  /// 함께 받은 Java 런타임 (HWP 확장 H2Orestart 가 Java 로 동작) 의 폴더 (bin/java.exe 가 있는 곳)
  String? javaHome([String id = 'docs']) {
    final root = Directory(p.join(dirOf(id).path, 'jre'));
    if (!root.existsSync()) return null;
    for (final e in root.listSync(recursive: true, followLinks: false)) {
      if (e is File && p.basename(e.path).toLowerCase() == 'java.exe' && p.basename(p.dirname(e.path)) == 'bin') {
        return p.dirname(p.dirname(e.path));
      }
    }
    return null;
  }

  /// LibreOffice 가 쓸 환경: 받은 Java (JAVA_HOME)
  Map<String, String>? _env(String id) {
    final jh = javaHome(id);
    return jh == null ? null : {'JAVA_HOME': jh, 'PATH': '${p.join(jh, 'bin')};${Platform.environment['PATH'] ?? ''}'};
  }

  /// LibreOffice 사용자 설정 폴더 (앱 전용, 확장도 여기에)
  String _profileUrl(String id) => Uri.directory(p.join(dirOf(id).path, 'profile')).toString();

  Future<void> _addExtension(String id, String oxt) async {
    final office = soffice(id);
    if (office == null) throw ComponentException(tr('LibreOffice 를 먼저 설치해야 합니다'));
    final unopkg = p.join(p.dirname(office), 'unopkg.com');
    final r = await Process.run(unopkg, ['add', '--suppress-license', '-env:UserInstallation=${_profileUrl(id)}', oxt],
        environment: _env(id));
    if (r.exitCode != 0) throw ComponentException(trf('확장을 설치할 수 없습니다 ({0}): {1}', [r.exitCode, r.stderr]));
  }

  /// 문서를 PDF 로 ([outDir] 에 만든 PDF 경로)
  Future<String> convertToPdf(String input, String outDir, {String id = 'docs'}) async {
    final office = soffice(id);
    if (office == null) throw ComponentException(tr('문서 미리보기 컴포넌트를 먼저 설치하세요'));
    await Directory(outDir).create(recursive: true);
    final r = await Process.run(office, [
      '--headless', '--norestore', '--nologo', '--nodefault',
      '-env:UserInstallation=${_profileUrl(id)}',
      '--convert-to', 'pdf', '--outdir', outDir, input,
    ], environment: _env(id)).timeout(const Duration(minutes: 3));
    final out = p.join(outDir, '${p.basenameWithoutExtension(input)}.pdf');
    if (!File(out).existsSync()) {
      throw ComponentException(trf('PDF 로 바꾸지 못했습니다 ({0}) {1}', [r.exitCode, '${r.stderr}'.trim()]));
    }
    return out;
  }
}

/// sha256 의 startChunkedConversion 결과를 받는 그릇
class AccumulatorSink<T> implements Sink<T> {
  final events = <T>[];
  @override
  void add(T event) => events.add(event);
  @override
  void close() {}
}
