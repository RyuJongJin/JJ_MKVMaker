import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../services/secret_store.dart';

/// PBKDF2-HMAC-SHA256 ([length] 바이트).
/// 반복마다 HMAC 의 안 · 바깥 열쇠 블록을 다시 계산하지 않도록 SHA-256 을 직접 돌린다 (폰에서도 빠르게).
Uint8List pbkdf2Sha256(List<int> password, List<int> salt, int iterations, int length) {
  var key = password;
  if (key.length > 64) key = sha256.convert(key).bytes;
  final ipad = Uint8List(64), opad = Uint8List(64);
  for (var i = 0; i < 64; i++) {
    final k = i < key.length ? key[i] : 0;
    ipad[i] = k ^ 0x36;
    opad[i] = k ^ 0x5c;
  }
  // 안 · 바깥 열쇠 블록을 한 번 넣은 상태
  final inner = Uint32List.fromList(_h0), outer = Uint32List.fromList(_h0);
  final w = Uint32List(64);
  _compress(inner, ipad, 0, w);
  _compress(outer, opad, 0, w);

  // 32 바이트 메시지 하나 (앞 블록 64 바이트 다음) 의 HMAC: 패딩까지 넣은 한 블록
  final block = Uint8List(64);
  block[32] = 0x80;
  block[62] = 0x03; // (64 + 32) * 8 = 768 비트 = 0x300
  final st = Uint32List(8);
  Uint8List hmac32(Uint8List msg) {
    block.setRange(0, 32, msg);
    st.setAll(0, inner);
    _compress(st, block, 0, w);
    _store(st, block);
    st.setAll(0, outer);
    _compress(st, block, 0, w);
    final out = Uint8List(32);
    _store(st, out);
    return out;
  }

  final hmac = Hmac(sha256, password);
  final out = BytesBuilder();
  for (var n = 1; out.length < length; n++) {
    var u = Uint8List.fromList(hmac.convert([...salt, n >> 24 & 0xff, n >> 16 & 0xff, n >> 8 & 0xff, n & 0xff]).bytes);
    final t = Uint8List.fromList(u);
    for (var i = 1; i < iterations; i++) {
      u = hmac32(u);
      for (var k = 0; k < 32; k++) {
        t[k] ^= u[k];
      }
    }
    out.add(t);
  }
  return Uint8List.fromList(out.toBytes().sublist(0, length));
}

const _h0 = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19];
const _k = [
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5, //
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
];

int _rotr(int x, int n) => ((x >> n) | (x << (32 - n))) & 0xffffffff;

/// SHA-256 블록 하나 ([data] 의 [off] 부터 64 바이트) 를 [h] 에 더한다
void _compress(Uint32List h, Uint8List data, int off, Uint32List w) {
  for (var i = 0; i < 16; i++) {
    final j = off + i * 4;
    w[i] = data[j] << 24 | data[j + 1] << 16 | data[j + 2] << 8 | data[j + 3];
  }
  for (var i = 16; i < 64; i++) {
    final a = w[i - 15], b = w[i - 2];
    final s0 = _rotr(a, 7) ^ _rotr(a, 18) ^ (a >> 3);
    final s1 = _rotr(b, 17) ^ _rotr(b, 19) ^ (b >> 10);
    w[i] = (w[i - 16] + s0 + w[i - 7] + s1) & 0xffffffff;
  }
  var a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7];
  for (var i = 0; i < 64; i++) {
    final s1 = _rotr(e, 6) ^ _rotr(e, 11) ^ _rotr(e, 25);
    final ch = (e & f) ^ (~e & 0xffffffff & g);
    final t1 = (hh + s1 + ch + _k[i] + w[i]) & 0xffffffff;
    final s0 = _rotr(a, 2) ^ _rotr(a, 13) ^ _rotr(a, 22);
    final maj = (a & b) ^ (a & c) ^ (b & c);
    final t2 = (s0 + maj) & 0xffffffff;
    hh = g;
    g = f;
    f = e;
    e = (d + t1) & 0xffffffff;
    d = c;
    c = b;
    b = a;
    a = (t1 + t2) & 0xffffffff;
  }
  h[0] = (h[0] + a) & 0xffffffff;
  h[1] = (h[1] + b) & 0xffffffff;
  h[2] = (h[2] + c) & 0xffffffff;
  h[3] = (h[3] + d) & 0xffffffff;
  h[4] = (h[4] + e) & 0xffffffff;
  h[5] = (h[5] + f) & 0xffffffff;
  h[6] = (h[6] + g) & 0xffffffff;
  h[7] = (h[7] + hh) & 0xffffffff;
}

void _store(Uint32List h, Uint8List out) {
  for (var i = 0; i < 8; i++) {
    out[i * 4] = h[i] >> 24 & 0xff;
    out[i * 4 + 1] = h[i] >> 16 & 0xff;
    out[i * 4 + 2] = h[i] >> 8 & 0xff;
    out[i * 4 + 3] = h[i] & 0xff;
  }
}

/// 비밀번호 해시 ("pbkdf2-sha256$반복$솔트$해시", 솔트 · 해시는 base64). 원문은 남기지 않는다.
class PasswordHash {
  static const scheme = 'pbkdf2-sha256';
  static const defaultIterations = 100000;

  static String make(String password, {List<int>? salt, int iterations = defaultIterations}) {
    final s = salt ?? List<int>.generate(16, (_) => Random.secure().nextInt(256));
    final h = pbkdf2Sha256(utf8.encode(password), s, iterations, 32);
    return '$scheme\$$iterations\$${base64Encode(s)}\$${base64Encode(h)}';
  }

  static bool verify(String password, String stored) {
    final parts = stored.split('\$');
    if (parts.length != 4 || parts[0] != scheme) return false;
    final n = int.tryParse(parts[1]);
    if (n == null || n < 1) return false;
    final List<int> salt, want;
    try {
      salt = base64Decode(parts[2]);
      want = base64Decode(parts[3]);
    } catch (_) {
      return false;
    }
    final got = pbkdf2Sha256(utf8.encode(password), salt, n, want.length);
    // 걸린 시간으로 맞은 글자 수가 드러나지 않게 끝까지 비교
    var diff = got.length ^ want.length;
    for (var i = 0; i < min(got.length, want.length); i++) {
      diff |= got[i] ^ want[i];
    }
    return diff == 0;
  }

  /// 화면이 멈추지 않게 따로 돌린다
  static Future<String> makeAsync(String password) => compute(_make, password);
  static Future<bool> verifyAsync(String password, String stored) => compute(_verify, [password, stored]);
  static String _make(String p) => make(p);
  static bool _verify(List<String> a) => verify(a[0], a[1]);
}

/// 마스터 입력 창에 넣은 값이 무엇이었는지
enum MasterInput { master, superPassword, wrong, wait }

/// 124: 비밀번호 세 가지 중 ① 최상 (모두 초기화하는 열쇠) · ② 마스터 (저장된 비밀번호 · 설정 · 비밀번호가 필요한 기능을 쓸 때).
/// 둘 다 사용자가 정하고, 솔트를 넣은 느린 해시로 안전 저장소에만 둔다. ③ 실제 비밀번호는 [SettingsStore] 가 다룬다.
///
/// 마스터는 기능을 여는 자물쇠다 (실제 비밀번호를 마스터로 암호화하지는 않는다 - 안전 저장소가 기기 열쇠로 이미 암호화).
/// 한 번 풀면 앱이 켜져 있는 동안 풀린 채로 둔다 (완전히 끄면 다시 묻는다).
class MasterLock extends ChangeNotifier {
  MasterLock(this.secrets, {this.now = DateTime.now});

  final SecretStore secrets;
  final DateTime Function() now;

  static const masterKey = 'sec.master', superKey = 'sec.super', failKey = 'sec.fails', askKey = 'sec.ask';
  static const askValues = ['never', 'startup', 'onUse'];

  /// 앱에서 쓰는 것 (main 이 정한다)
  static MasterLock? instance;

  /// 마스터를 묻는 창 (main 이 화면에 띄우는 함수를 넣는다, [reason] 은 창에 보일 까닭). 풀렸으면 true
  static Future<bool> Function(String? reason)? prompt;

  String? _master, _super, _askStored;
  bool unlocked = false;

  /// 128: 이번 실행에서 마스터 창을 취소했다 - 자동 · 배경 작업은 다시 묻지 않고 건너뛴다 (사용자가 직접 누른 곳만 다시 묻는다)
  bool declined = false;

  /// 연달아 틀린 수 · 이때까지 기다림 (앱을 껐다 켜도 남게 안전 저장소에)
  int fails = 0;
  DateTime? waitUntil;

  bool get hasMaster => _master != null;
  bool get hasSuper => _super != null;

  /// 'never' 물어보지 않기 · 'startup' 처음 시작 시 · 'onUse' 비밀번호가 저장된 기능을 쓸 때.
  /// 129: 평문 설정 파일이 아니라 안전 저장소에 둔다. 마스터가 있는데 값이 없거나 틀리면 'onUse' (자물쇠가 말없이 꺼지지 않게)
  String get ask {
    if (!hasMaster) return 'never';
    final a = _askStored;
    return a != null && askValues.contains(a) ? a : 'onUse';
  }

  Future<void> setAsk(String value) async {
    if (!askValues.contains(value)) return;
    _askStored = value;
    await secrets.write(askKey, value);
    notifyListeners();
  }

  Future<void> load() async {
    final all = await secrets.readAll();
    _master = all[masterKey];
    _super = all[superKey];
    _askStored = all[askKey];
    final f = (all[failKey] ?? '').split('|');
    fails = int.tryParse(f.first) ?? 0;
    final until = f.length > 1 ? int.tryParse(f[1]) : null;
    waitUntil = until == null || until == 0 ? null : DateTime.fromMillisecondsSinceEpoch(until);
    notifyListeners();
  }

  /// 지금 기다려야 하는 시간 (없으면 null)
  Duration? get waiting {
    final w = waitUntil;
    if (w == null) return null;
    final left = w.difference(now());
    return left.isNegative ? null : left;
  }

  /// 5번째 틀림부터 30초 · 1분 · 2분 … (최대 15분) 기다리게 한다
  static Duration waitFor(int fails) {
    if (fails < 5) return Duration.zero;
    final s = 30 * (1 << min(fails - 5, 5));
    return Duration(seconds: min(s, 15 * 60));
  }

  Future<void> _saveFails() =>
      secrets.write(failKey, '$fails|${waitUntil?.millisecondsSinceEpoch ?? 0}');

  /// 마스터 입력 창의 값을 확인한다 (최상을 넣으면 [MasterInput.superPassword] - 초기화 창으로)
  Future<MasterInput> check(String input) async {
    if (waiting != null) return MasterInput.wait;
    final m = _master, s = _super;
    MasterInput r = MasterInput.wrong;
    if (m != null && await PasswordHash.verifyAsync(input, m)) {
      r = MasterInput.master;
    } else if (s != null && await PasswordHash.verifyAsync(input, s)) {
      r = MasterInput.superPassword;
    }
    if (r == MasterInput.master) declined = false;
    if (r == MasterInput.wrong) {
      fails++;
      final w = waitFor(fails);
      waitUntil = w == Duration.zero ? null : now().add(w);
    } else {
      fails = 0;
      waitUntil = null;
      if (r == MasterInput.master) unlocked = true;
    }
    await _saveFails();
    notifyListeners();
    return r;
  }

  /// 마스터를 정한다 · 바꾼다. 최상과 같으면 false (정하지 않음)
  Future<bool> setMaster(String password) async {
    final s = _super;
    if (s != null && await PasswordHash.verifyAsync(password, s)) return false;
    _master = await PasswordHash.makeAsync(password);
    await secrets.write(masterKey, _master!);
    unlocked = true;
    notifyListeners();
    return true;
  }

  /// 최상을 정한다 · 바꾼다. 마스터와 같으면 false
  Future<bool> setSuper(String password) async {
    final m = _master;
    if (m != null && await PasswordHash.verifyAsync(password, m)) return false;
    _super = await PasswordHash.makeAsync(password);
    await secrets.write(superKey, _super!);
    notifyListeners();
    return true;
  }

  Future<void> clearMaster() async {
    _master = null;
    _askStored = null;
    await secrets.delete(masterKey);
    await secrets.delete(askKey);
    unlocked = true;
    declined = false;
    notifyListeners();
  }

  Future<void> clearSuper() async {
    _super = null;
    await secrets.delete(superKey);
    notifyListeners();
  }

  /// 마스터를 물어야 하는지 ([startup]: 앱을 켤 때 묻는 자리인지)
  bool needsPrompt({bool startup = false}) {
    if (!hasMaster || unlocked) return false;
    return switch (ask) {
      'never' => false,
      'startup' => true, // 켤 때 묻고, 그때 취소했으면 쓸 때 다시 묻는다
      _ => !startup,
    };
  }

  Future<bool>? _pending;

  /// 비밀번호가 저장된 기능을 쓰기 전에: 필요하면 마스터를 묻는다. 써도 되면 true.
  /// - 시작할 때 · 설정 화면 · 배경 작업이 동시에 불러도 창은 하나 (128).
  /// - 한 번 취소하면 이번 실행 동안 자동 · 배경 호출은 묻지 않고 false. [force]: 사용자가 직접 누른 곳 (다시 묻는다)
  Future<bool> ensure({bool force = false, String? reason}) {
    if (!needsPrompt()) return Future.value(true);
    final pending = _pending;
    if (pending != null) return pending;
    if (declined && !force) return Future.value(false);
    final p = prompt;
    if (p == null) return Future.value(false);
    return _pending = p(reason).then((ok) {
      declined = !ok && !unlocked;
      return ok;
    }).whenComplete(() => _pending = null);
  }

  /// [instance] 가 없으면 (시험 · 마스터 기능을 쓰지 않음) 늘 true
  static Future<bool> gate() => instance?.ensure() ?? Future.value(true);
}
