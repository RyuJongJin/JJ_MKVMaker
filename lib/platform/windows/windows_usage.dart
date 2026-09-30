import 'dart:ffi';

import 'package:ffi/ffi.dart';

import '../../services/system_usage.dart';

typedef _GetSystemTimesC = Int32 Function(Pointer<Uint64> idle, Pointer<Uint64> kernel, Pointer<Uint64> user);
typedef _GetSystemTimesD = int Function(Pointer<Uint64> idle, Pointer<Uint64> kernel, Pointer<Uint64> user);
typedef _MemStatusC = Int32 Function(Pointer<Uint8> buffer);
typedef _MemStatusD = int Function(Pointer<Uint8> buffer);
typedef _DiskFreeC = Int32 Function(
    Pointer<Utf16> dir, Pointer<Uint64> freeForUser, Pointer<Uint64> total, Pointer<Uint64> free);
typedef _DiskFreeD = int Function(
    Pointer<Utf16> dir, Pointer<Uint64> freeForUser, Pointer<Uint64> total, Pointer<Uint64> free);

/// Windows: PC 전체 CPU 사용률 (GetSystemTimes 의 앞뒤 차이) · 물리 메모리 (GlobalMemoryStatusEx)
class WindowsUsage implements SystemUsage {
  final _GetSystemTimesD _times;
  final _MemStatusD _mem;
  final _DiskFreeD _disk;
  int? _idle, _total;

  WindowsUsage._(this._times, this._mem, this._disk);

  factory WindowsUsage() {
    final k = DynamicLibrary.open('kernel32.dll');
    return WindowsUsage._(
      k.lookupFunction<_GetSystemTimesC, _GetSystemTimesD>('GetSystemTimes'),
      k.lookupFunction<_MemStatusC, _MemStatusD>('GlobalMemoryStatusEx'),
      k.lookupFunction<_DiskFreeC, _DiskFreeD>('GetDiskFreeSpaceExW'),
    );
  }

  /// 이 사용자가 쓸 수 있는 남은 용량 · 디스크 전체 용량 (GetDiskFreeSpaceEx)
  @override
  (int, int)? disk(String path) {
    final dir = path.toNativeUtf16();
    final n = calloc<Uint64>(3);
    try {
      if (_disk(dir, n, n + 1, n + 2) == 0) return null;
      return (n[0], n[1]);
    } finally {
      calloc
        ..free(dir)
        ..free(n);
    }
  }

  @override
  UsageSample? read() {
    // FILETIME (32비트 2개) 은 64비트 정수 하나와 같은 모양
    final t = calloc<Uint64>(3);
    // MEMORYSTATUSEX: 길이(4) · 사용률(4) · 전체 물리(8) · 남은 물리(8) · … 모두 64바이트
    final m = calloc<Uint8>(64);
    try {
      if (_times(t, t + 1, t + 2) == 0) return null;
      final idle = t[0];
      final total = t[1] + t[2]; // 커널 시간에 쉬는 시간이 들어 있다
      final prevIdle = _idle, prevTotal = _total;
      _idle = idle;
      _total = total;

      m.cast<Uint32>().value = 64;
      if (_mem(m) == 0) return null;
      final memTotal = (m + 8).cast<Uint64>().value;
      final memFree = (m + 16).cast<Uint64>().value;

      if (prevIdle == null || prevTotal == null || total <= prevTotal) return null;
      final cpu = 1 - (idle - prevIdle) / (total - prevTotal);
      return UsageSample(cpu: cpu.clamp(0.0, 1.0), memUsed: memTotal - memFree, memTotal: memTotal);
    } finally {
      calloc
        ..free(t)
        ..free(m);
    }
  }
}
