import 'package:path/path.dart' as p;

/// 파일 탐색기의 복사 · 이동 방법 (환경 설정 > 파일 탐색기 > 복사 · 동기화)
///
/// - builtin: 앱이 직접 복사 ("현재 방식"). 모든 기기.
/// - rsync: rsync (Windows 는 MSYS2 의 rsync 를 처음 쓸 때 내려받음, Android 는 직접 지정한 실행 파일)
/// - robocopy: Windows 에 들어 있는 robocopy (Windows 만)
enum CopyMethod {
  builtin('현재 방식'),
  rsync('rsync'),
  robocopy('robocopy');

  final String label;
  const CopyMethod(this.label);

  static CopyMethod of(String? name) => values.firstWhere((m) => m.name == name, orElse: () => builtin);
}

const defaultRsyncOptions = '-avPog';
const defaultRobocopyOptions = '/E /COPY:DAT /DCOPY:T /R:2 /W:2';

/// 옵션 글자를 인수로 나눈다 (큰따옴표 · 작은따옴표로 묶은 것은 하나로)
List<String> splitOptions(String s) {
  final out = <String>[];
  final cur = StringBuffer();
  String? quote;
  var has = false;
  for (final ch in s.split('')) {
    if (quote != null) {
      if (ch == quote) {
        quote = null;
      } else {
        cur.write(ch);
      }
    } else if (ch == '"' || ch == "'") {
      quote = ch;
      has = true;
    } else if (ch.trim().isEmpty) {
      if (cur.isNotEmpty || has) out.add(cur.toString());
      cur.clear();
      has = false;
    } else {
      cur.write(ch);
    }
  }
  if (cur.isNotEmpty || has) out.add(cur.toString());
  return out;
}

/// Windows 경로 → MSYS2 rsync 가 읽는 경로 (C:\a\b → /cygdrive/c/a/b, \\server\share\x → //server/share/x).
/// MSYS2 rsync 는 "C:" 를 원격 컴퓨터 이름으로 읽으므로 꼭 바꿔야 한다.
String toCygwinPath(String path, {bool windows = true}) {
  if (!windows) return path;
  final s = path.replaceAll('\\', '/');
  final m = RegExp(r'^([A-Za-z]):(/.*)?$').firstMatch(s);
  if (m != null) return '/cygdrive/${m[1]!.toLowerCase()}${m[2] ?? '/'}';
  return s; // //server/share 는 그대로 읽는다
}

/// rsync 인수: [options] + (대역폭 · 이동) + 원본들 + 대상 폴더/
/// 원본 폴더는 끝에 / 를 붙이지 않는다 (폴더째 대상 안으로 - 앱의 복사와 같은 결과).
List<String> rsyncArgs({
  required String options,
  required List<String> sources,
  required String dest,
  int bandwidthKBps = 0,
  bool move = false,
  bool windows = true,
}) {
  final opts = splitOptions(options);
  return [
    ...opts,
    if (bandwidthKBps > 0 && !opts.any((o) => o.startsWith('--bwlimit'))) '--bwlimit=$bandwidthKBps',
    if (move && !opts.contains('--remove-source-files')) '--remove-source-files',
    for (final s in sources) toCygwinPath(_noTrailingSlash(s), windows: windows),
    '${toCygwinPath(_noTrailingSlash(dest), windows: windows)}/',
  ];
}

String _noTrailingSlash(String s) => s.length > 3 && (s.endsWith('/') || s.endsWith('\\')) ? s.substring(0, s.length - 1) : s;

/// robocopy 한 번 실행할 인수 (robocopy 는 "폴더 → 폴더" 라 원본마다 따로 만든다).
/// - 폴더: robocopy <폴더> <대상>\<폴더 이름> [옵션]
/// - 파일: robocopy <파일이 있는 폴더> <대상> <파일 이름들…> [옵션] (같은 폴더의 파일은 한 번에)
/// 대역폭: robocopy 에는 속도 제한이 없어 /IPG (조각 사이 쉬는 시간) 로 비슷하게 맞춘다.
List<List<String>> robocopyRuns({
  required String options,
  required List<String> folders,
  required List<String> files,
  required String dest,
  int bandwidthKBps = 0,
  bool move = false,
}) {
  final opts = splitOptions(options);
  final extra = [
    if (bandwidthKBps > 0 && !opts.any((o) => o.toUpperCase().startsWith('/IPG'))) '/IPG:${robocopyIpg(bandwidthKBps)}',
    if (move && !opts.any((o) => o.toUpperCase().startsWith('/MOV'))) '/MOVE',
  ];
  final runs = <List<String>>[
    for (final f in folders) [f, p.join(dest, p.basename(f)), ...opts, ...extra],
  ];
  final byDir = <String, List<String>>{};
  for (final f in files) {
    byDir.putIfAbsent(p.dirname(f), () => []).add(p.basename(f));
  }
  // 파일만 옮길 때 /E · /MOVE 는 하위 폴더까지 건드리므로 뺀다
  final fileOpts = opts.where((o) => !const ['/E', '/S', '/MIR'].contains(o.toUpperCase())).toList();
  final fileExtra = extra.map((o) => o == '/MOVE' ? '/MOV' : o).toList();
  byDir.forEach((dir, names) => runs.add([dir, dest, ...names, ...fileOpts, ...fileExtra]));
  return runs;
}

/// robocopy /IPG 밀리초: robocopy 는 64KB 조각마다 쉰다 → 64 / KB/s 초
int robocopyIpg(int kbps) => kbps <= 0 ? 0 : (64 * 1000 / kbps).round().clamp(1, 60000);

/// rsync · robocopy 의 성공 종료 코드
bool rsyncOk(int code) => code == 0 || code == 24; // 24: 복사 도중 원본 파일이 사라짐
bool robocopyOk(int code) => code >= 0 && code < 8;

/// rsync -v 출력에서 "다 보낸 파일" 줄을 골라낸다 (-P 의 \r 진행 줄 · 머리글 · 요약 · 폴더 줄은 뺌).
/// 결과: 원본 기준 상대 경로 (예: "sub/inner.txt")
class RsyncOutput {
  final _buf = StringBuffer();

  /// 지금 파일의 진행률 (-P 의 "  1,234  45%  1.2MB/s" 줄)
  double? currentPercent;

  List<String> feed(String chunk) {
    _buf.write(chunk);
    final text = _buf.toString();
    final cut = text.lastIndexOf(RegExp(r'[\r\n]'));
    if (cut < 0) return const [];
    _buf
      ..clear()
      ..write(text.substring(cut + 1));
    final done = <String>[];
    for (final raw in text.substring(0, cut).split(RegExp(r'[\r\n]'))) {
      final line = raw.trimRight();
      if (line.isEmpty) continue;
      if (line.startsWith(' ')) {
        final m = RegExp(r'\s(\d{1,3})%\s').firstMatch(line);
        if (m != null) currentPercent = int.parse(m[1]!) / 100;
        continue;
      }
      if (line.endsWith('/')) continue; // 폴더
      if (line.startsWith('sending ') ||
          line.startsWith('receiving ') ||
          line.startsWith('sent ') ||
          line.startsWith('total size') ||
          line.startsWith('created directory') ||
          line.startsWith('deleting ') ||
          line.startsWith('rsync:') ||
          line.startsWith('rsync error') ||
          line.contains(' -> ')) {
        continue;
      }
      currentPercent = null;
      done.add(line);
    }
    return done;
  }
}

/// robocopy 출력에서 파일 줄 ("New File", "Newer", "Older", "Changed" … 뒤의 크기 · 이름) 을 센다
class RobocopyOutput {
  final _buf = StringBuffer();
  double? currentPercent;

  static final _file = RegExp(
      r'^\s*(New File|Newer|Older|Changed|Same|Tweaked|Modified|\*EXTRA File|새 파일|최신|이전|변경됨|같음)\s+[\d.]+\s*[kmgt]?\s+(.+)$',
      caseSensitive: false);

  List<String> feed(String chunk) {
    _buf.write(chunk);
    final text = _buf.toString();
    final cut = text.lastIndexOf(RegExp(r'[\r\n]'));
    if (cut < 0) return const [];
    _buf
      ..clear()
      ..write(text.substring(cut + 1));
    final done = <String>[];
    for (final raw in text.substring(0, cut).split(RegExp(r'[\r\n]'))) {
      final line = raw.trim();
      final pct = RegExp(r'^(\d{1,3}(?:\.\d)?)%$').firstMatch(line);
      if (pct != null) {
        currentPercent = double.parse(pct[1]!) / 100;
        continue;
      }
      final m = _file.firstMatch(raw);
      if (m != null && !m[1]!.toLowerCase().startsWith('*extra')) {
        currentPercent = null;
        done.add(m[2]!.trim());
      }
    }
    return done;
  }
}

/// Windows 용 rsync: MSYS2 공식 저장소의 패키지 (처음 쓸 때 내려받음, 파일 SHA256 을 고정해 검증)
const msys2Repo = 'https://repo.msys2.org/msys/x86_64/';
const msys2RsyncPackages = <(String, String)>[
  ('rsync-3.5.1-2-x86_64.pkg.tar.zst', 'cba52e41d16f9873324fcf09853619964da87bc1ce116781a5449c968d4ffecc'),
  ('msys2-runtime-3.6.10-6-x86_64.pkg.tar.zst', 'b2db5bae3826f15cacb536f4c7c6c7e31d3fabec00aac8f127473aba7e994d22'),
  ('gcc-libs-15.3.0-1-x86_64.pkg.tar.zst', '0d99a122c453c05ae21ba3dcea910f2e0d93d38ae067c677a112a315b0f3cec5'),
  ('libiconv-1.19-1-x86_64.pkg.tar.zst', '0fa55ea2a6ccf97cf8c58b24b2615815e15e16e6e4e888091c263c2c83c5313d'),
  ('libidn2-2.3.8-1-x86_64.pkg.tar.zst', '55e0de96b893e9f67f14a4283d411fc2a45d7b59333bc16e2a9b16e5bfc9282f'),
  ('libintl-0.22.5-1-x86_64.pkg.tar.zst', '336d66b9d95cf9c1804958f8e260762a3e83bf158ed5981f783bc772a31073cf'),
  ('liblz4-1.10.0-1-x86_64.pkg.tar.zst', '1cbbe51ee91bf32691aabb15bdb7c8548e8b5ef8195122ef31f10edcca6e952f'),
  ('libopenssl-3.6.5-1-x86_64.pkg.tar.zst', '05f6cc946f0dde3aecc3632007fa1d874e40720226117b750327bc2a01846325'),
  ('libunistring-1.4.2-1-x86_64.pkg.tar.zst', 'bcd04706d95b5e7127d39834565bceed6b400192f5fb51599745aba28d5da018'),
  ('libxxhash-0.8.4-1-x86_64.pkg.tar.zst', 'ba784ad117626401cd5d3ec0cf70399f9de72a63755f96c28fa2032303f9c330'),
  ('libzstd-1.5.7-1-x86_64.pkg.tar.zst', '5e370b2e725a0a7e5ff58d84653c9a0cd5a10b9cfe930f2d949a28ad2a11c1f2'),
  ('popt-1.19-1-x86_64.pkg.tar.zst', 'b402bd1d03815c5e28b7ab415d8e20f487eff2460ae0271a99674eeb0d77194f'),
];

/// 패키지에서 꺼낼 파일 (rsync.exe 와 필요한 DLL 만)
const msys2RsyncFiles = {
  'rsync.exe', 'msys-2.0.dll', 'msys-gcc_s-seh-1.dll', 'msys-iconv-2.dll', 'msys-idn2-0.dll', 'msys-intl-8.dll',
  'msys-lz4-1.dll', 'msys-crypto-3.dll', 'msys-ssl-3.dll', 'msys-unistring-5.dll', 'msys-xxhash-0.dll',
  'msys-zstd-1.dll', 'msys-popt-0.dll', 'msys-charset-1.dll',
};
