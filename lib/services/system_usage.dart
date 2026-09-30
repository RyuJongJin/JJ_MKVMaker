import 'dart:async';

import 'package:flutter/foundation.dart';

/// PC 전체의 CPU · 메모리 사용량 (한 번 잰 값)
class UsageSample {
  /// 0.0 ~ 1.0
  final double cpu;
  final int memUsed, memTotal;

  /// 다운로드 대상 디스크의 남은 용량 · 전체 용량 (바이트, 알 수 없으면 null) 과 그 드라이브 (예: "M:")
  final int? diskFree, diskTotal;
  final String disk;
  const UsageSample({
    required this.cpu,
    required this.memUsed,
    required this.memTotal,
    this.diskFree,
    this.diskTotal,
    this.disk = '',
  });

  double get mem => memTotal <= 0 ? 0 : memUsed / memTotal;

  /// 디스크가 거의 찼는지: 남은 용량이 5% 미만이거나 10GB 미만
  bool get diskLow =>
      diskFree != null &&
      (diskFree! < 10 * 1024 * 1024 * 1024 || (diskTotal != null && diskTotal! > 0 && diskFree! / diskTotal! < 0.05));
}

/// 사용량을 읽는 경계.
/// Windows: platform/windows/windows_usage.dart  ·  그 밖: 없음 (표시 숨김)
abstract class SystemUsage {
  /// 지난번 호출 이후의 CPU 사용률과 지금 메모리. 아직 알 수 없으면 (첫 호출) null.
  UsageSample? read();

  /// [path] 가 있는 디스크의 (남은 용량, 전체 용량). 알 수 없으면 null.
  (int, int)? disk(String path);
}

/// 일정 간격으로 사용량을 읽어 알려 준다 (위쪽 막대의 CPU · MEM 표시)
class UsageMonitor extends ValueNotifier<UsageSample?> {
  final SystemUsage source;
  final Duration interval;

  /// 용량을 볼 디스크의 경로 (다운로드 폴더가 있는 드라이브, 예: "M:\\")
  final String Function()? diskPath;
  Timer? _timer;

  UsageMonitor(this.source, {this.interval = const Duration(seconds: 2), this.diskPath}) : super(null);

  // 보는 화면이 있을 때만 잰다
  @override
  void addListener(VoidCallback listener) {
    super.addListener(listener);
    if (_timer == null) {
      _tick();
      _timer = Timer.periodic(interval, (_) => _tick());
    }
  }

  @override
  void removeListener(VoidCallback listener) {
    super.removeListener(listener);
    if (!hasListeners) {
      _timer?.cancel();
      _timer = null;
    }
  }

  void _tick() {
    try {
      final s = source.read();
      if (s == null) return;
      final path = diskPath?.call() ?? '';
      final d = path.isEmpty ? null : source.disk(path);
      value = UsageSample(
        cpu: s.cpu,
        memUsed: s.memUsed,
        memTotal: s.memTotal,
        diskFree: d?.$1,
        diskTotal: d?.$2,
        disk: path.replaceAll(RegExp(r'[\\/]+$'), ''),
      );
    } catch (_) {}
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}
