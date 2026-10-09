import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 비밀 값 (WebDAV · OpenSubtitles 아이디 · 비밀번호 · API 키) 을 두는 곳.
/// 사용자 결정 (10/9): 설정 파일 (settings.json · .bak · 버전 보관본) 에 평문으로 쓰지 않는다.
/// Android 는 Keystore 키로 암호화해 앱 전용 저장소에, Windows 는 DPAPI (이 Windows 사용자만 풀 수 있음) 로 암호화한 파일에.
/// 설정 파일과 따로 있어 업데이트 · 예전 버전 설치 · 되돌리기 · 설정 복원 뒤에도 남는다.
abstract class SecretStore {
  Future<Map<String, String>> readAll();
  Future<void> write(String key, String value);
  Future<void> delete(String key);

  /// 저장소를 풀 수 없어 새로 시작했으면 풀지 못한 원래 파일을 보관한 곳 (켤 때 알림 - 40-5)
  String? get lostCopy => null;

  /// 이 기기의 안전 저장소
  factory SecretStore.platform() {
    if (Platform.isWindows) return _DpapiSecretStore();
    if (Platform.isAndroid) return _AndroidSecretStore();
    return MemorySecretStore();
  }
}

/// Android: MainActivity 의 SecretBox (AndroidKeyStore AES-GCM 키 · SharedPreferences "jj_secrets")
class _AndroidSecretStore implements SecretStore {
  static const _ch = MethodChannel('jj_mkvmaker/android');

  @override
  String? get lostCopy => null;

  @override
  Future<Map<String, String>> readAll() async {
    final m = await _ch.invokeMethod<Map<Object?, Object?>>('secretReadAll');
    return {for (final e in (m ?? const {}).entries) '${e.key}': '${e.value}'};
  }

  @override
  Future<void> write(String key, String value) => _ch.invokeMethod('secretWrite', {'key': key, 'value': value});
  @override
  Future<void> delete(String key) => _ch.invokeMethod('secretDelete', {'key': key});
}

/// Windows: 모든 값을 JSON 으로 묶어 DPAPI (CryptProtectData, 지금 사용자 범위) 로 암호화한 secrets.dat
class _DpapiSecretStore implements SecretStore {
  Future<File> _file() async => File(p.join((await getApplicationSupportDirectory()).path, 'secrets.dat'));

  Map<String, String>? _cache;

  /// 읽은 파일의 고친 시각 · 크기 (130: 다른 창 · 프로세스가 고쳤으면 다시 읽는다)
  (DateTime, int)? _stamp;

  @override
  String? lostCopy;

  @override
  Future<Map<String, String>> readAll() async => Map.of(await _load());

  /// 파일이 읽은 뒤로 바뀌지 않았으면 기억해 둔 것, 바뀌었으면 (두 번째 재생 창 · 다른 실행이 씀) 다시 읽는다
  Future<Map<String, String>> _load() async {
    final f = await _file();
    if (!await f.exists()) {
      _stamp = null;
      return _cache = {};
    }
    final st = await f.stat();
    final stamp = (st.modified, st.size);
    if (_cache != null && _stamp == stamp) return _cache!;
    final bytes = await f.readAsBytes();
    try {
      final j = jsonDecode(utf8.decode(_dpapi(bytes, protect: false))) as Map;
      _stamp = stamp;
      return _cache = {for (final e in j.entries) '${e.key}': '${e.value}'};
    } catch (_) {
      // 풀 수 없음 (다른 PC · 다른 사용자에서 복사해 옴 등): 지우지 않고 보관한 뒤 새로 시작
      final stamp = DateTime.now().toIso8601String().replaceAll(':', '').split('.').first;
      final kept = p.join(f.parent.path, 'secrets.broken-$stamp.dat');
      try {
        await f.copy(kept);
        lostCopy = kept;
      } catch (_) {
        // 보관하지 못하면 저장소를 쓰지 않는다 (덮어써서 잃지 않게)
        rethrow;
      }
      return _cache = {};
    }
  }

  Future<void> _save(Map<String, String> m) async {
    final f = await _file();
    await f.parent.create(recursive: true);
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsBytes(_dpapi(Uint8List.fromList(utf8.encode(jsonEncode(m))), protect: true), flush: true);
    await tmp.rename(f.path);
    final st = await f.stat();
    _stamp = (st.modified, st.size);
    _cache = m;
  }

  /// 130: 쓰기 · 지우기 바로 전에 파일을 다시 읽어 (다른 창이 그사이 바꾼 것과) 합친다
  @override
  Future<void> write(String key, String value) async => _save({...await _load(), key: value});

  @override
  Future<void> delete(String key) async {
    final m = Map.of(await _load());
    if (m.remove(key) != null) await _save(m);
  }
}

final class _Blob extends Struct {
  @Uint32()
  external int cbData;
  external Pointer<Uint8> pbData;
}

typedef _CryptNative = Int32 Function(
    Pointer<_Blob>, Pointer<Utf16>, Pointer<_Blob>, Pointer<Void>, Pointer<Void>, Uint32, Pointer<_Blob>);
typedef _CryptDart = int Function(
    Pointer<_Blob>, Pointer<Utf16>, Pointer<_Blob>, Pointer<Void>, Pointer<Void>, int, Pointer<_Blob>);

/// CryptProtectData / CryptUnprotectData (CRYPTPROTECT_UI_FORBIDDEN)
Uint8List _dpapi(Uint8List data, {required bool protect}) {
  final crypt32 = DynamicLibrary.open('crypt32.dll');
  final kernel32 = DynamicLibrary.open('kernel32.dll');
  final fn = protect
      ? crypt32.lookupFunction<_CryptNative, _CryptDart>('CryptProtectData')
      : crypt32.lookupFunction<_CryptNative, _CryptDart>('CryptUnprotectData');
  final localFree = kernel32.lookupFunction<Pointer<Void> Function(Pointer<Void>), Pointer<Void> Function(Pointer<Void>)>('LocalFree');
  final input = calloc<_Blob>();
  final output = calloc<_Blob>();
  final buf = calloc<Uint8>(data.isEmpty ? 1 : data.length);
  try {
    buf.asTypedList(data.length).setAll(0, data);
    input.ref
      ..cbData = data.length
      ..pbData = buf;
    final ok = fn(input, nullptr, nullptr, nullptr, nullptr, 0x1, output);
    if (ok == 0) throw StateError('DPAPI ${protect ? 'protect' : 'unprotect'} failed');
    final out = Uint8List.fromList(output.ref.pbData.asTypedList(output.ref.cbData));
    localFree(output.ref.pbData.cast());
    return out;
  } finally {
    calloc.free(buf);
    calloc.free(input);
    calloc.free(output);
  }
}

/// 시험용 · 설정 파일 경로를 직접 준 경우 (메모리에만)
class MemorySecretStore implements SecretStore {
  final Map<String, String> values = {};

  /// 시험: 읽기 · 쓰기 실패 흉내
  bool failRead = false;
  bool failWrite = false;

  @override
  String? lostCopy;

  @override
  Future<Map<String, String>> readAll() async {
    if (failRead) throw StateError('secret store unavailable');
    return Map.of(values);
  }

  @override
  Future<void> write(String key, String value) async {
    if (failWrite) throw StateError('secret store write failed');
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async => values.remove(key);
}
