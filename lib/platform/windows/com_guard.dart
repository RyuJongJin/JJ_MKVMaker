import 'dart:ffi';
import 'dart:io';

typedef _CoInitC = Int32 Function(Pointer<Void> reserved, Uint32 mode);
typedef _CoInitD = int Function(Pointer<Void> reserved, int mode);
typedef _CoUninitC = Void Function();
typedef _CoUninitD = void Function();

/// Windows COM 준비 상태를 다루는 도우미.
///
/// 앱 안 브라우저 (Edge WebView2) 는 화면을 그리는 스레드에 COM 이 준비되어 있어야 만들어진다.
/// 실행 파일이 시작할 때 준비해 두지만, 다른 구성 요소가 그것을 풀어 버리면
/// "CoInitialize 가 호출되지 않았습니다" 로 브라우저가 뜨지 않는다 → 만들기 직전에 다시 준비한다.
class ComGuard {
  static final DynamicLibrary _ole = DynamicLibrary.open('ole32.dll');
  static final _CoInitD _init = _ole.lookupFunction<_CoInitC, _CoInitD>('CoInitializeEx');
  static final _CoUninitD _uninit = _ole.lookupFunction<_CoUninitC, _CoUninitD>('CoUninitialize');

  static const _apartmentThreaded = 0x2;

  /// 이 스레드에 COM 을 준비한다 (이미 되어 있으면 그대로). 돌려주는 값은 Windows 결과 코드:
  /// 0 = 새로 준비함 (풀려 있었음), 1 = 이미 준비되어 있었음, 음수 = 다른 방식으로 이미 준비됨 · 실패
  static int ensure() {
    if (!Platform.isWindows) return 1;
    try {
      return _init(nullptr, _apartmentThreaded);
    } catch (_) {
      return -1;
    }
  }

  /// 준비 상태를 확인하고, 풀려 있었으면 다시 준비한다. 다시 준비했으면 true.
  /// (이미 준비되어 있었으면 확인하느라 올린 만큼 도로 내려 원래대로 둔다)
  static bool repairIfNeeded() {
    final hr = ensure();
    if (hr == 1) _uninit();
    return hr == 0;
  }

  /// 시험용: 준비 상태를 한 단계 푼다
  static void releaseForTest() => _uninit();
}
