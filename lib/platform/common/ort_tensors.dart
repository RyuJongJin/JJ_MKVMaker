// ONNX Runtime C API 보조 함수 (onnxruntime 패키지가 제공하지 않는 기능)
// ignore_for_file: implementation_imports
import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:onnxruntime/onnxruntime.dart';
import 'package:onnxruntime/src/bindings/onnxruntime_bindings_generated.dart' as bg;

final _api = OrtEnv.instance.ortApiPtr.ref;

ffi.Pointer<bg.OrtMemoryInfo>? _cpuInfo;

ffi.Pointer<bg.OrtMemoryInfo> _memInfo() {
  if (_cpuInfo != null) return _cpuInfo!;
  final pp = calloc<ffi.Pointer<bg.OrtMemoryInfo>>();
  _check(_api.CreateCpuMemoryInfo.asFunction<
          bg.OrtStatusPtr Function(int, int, ffi.Pointer<ffi.Pointer<bg.OrtMemoryInfo>>)>()(
      bg.OrtAllocatorType.OrtDeviceAllocator, bg.OrtMemType.OrtMemTypeCPU, pp));
  _cpuInfo = pp.value;
  calloc.free(pp);
  return _cpuInfo!;
}

void _check(bg.OrtStatusPtr status) => OrtStatus.checkOrtStatus(status);

OrtValueTensor _create(ffi.Pointer<ffi.Void> data, int bytes, List<int> shape, int type) {
  final shapePtr = calloc<ffi.Int64>(shape.isEmpty ? 1 : shape.length);
  for (var i = 0; i < shape.length; i++) {
    shapePtr[i] = shape[i];
  }
  final out = calloc<ffi.Pointer<bg.OrtValue>>();
  _check(_api.CreateTensorWithDataAsOrtValue.asFunction<
          bg.OrtStatusPtr Function(ffi.Pointer<bg.OrtMemoryInfo>, ffi.Pointer<ffi.Void>, int,
              ffi.Pointer<ffi.Int64>, int, int, ffi.Pointer<ffi.Pointer<bg.OrtValue>>)>()(
      _memInfo(), data, bytes, shapePtr, shape.length, type, out));
  final v = OrtValueTensor(out.value, data);
  calloc.free(shapePtr);
  calloc.free(out);
  return v;
}

/// 모델 파일로 세션 만들기.
///
/// onnxruntime 1.4.1 의 OrtSession.fromFile 은 Windows 에서 경로를 UTF-8 로 넘겨 실패한다
/// (Windows 의 ORT 는 wchar_t 경로를 받음). 여기서는 플랫폼에 맞는 문자열로 직접 호출한다.
///
/// [lowMemory]: 메모리가 적은 기기 (Android) 용. 외부 데이터 모델 ([OnnxExternal]) 과 함께 쓴다.
/// 그래프 최적화를 끈다: 최적화 (BASIC 이상) 의 상수 접기는 int8 가중치를 float 로 풀어 디코더가 1GB 넘게 쓴다.
/// prepacking · 메모리 아레나도 끈다. 측정 (NLLB 디코더): 기본 최대 1.5GB → 외부 데이터 + 이 설정 112MB.
/// 대신 계산이 몇 배 느려진다.
OrtSession openSession(String path, {int threads = 1, bool lowMemory = false}) {
  final optPP = calloc<ffi.Pointer<bg.OrtSessionOptions>>();
  _check(_api.CreateSessionOptions.asFunction<
      bg.OrtStatusPtr Function(ffi.Pointer<ffi.Pointer<bg.OrtSessionOptions>>)>()(optPP));
  final opt = optPP.value;
  calloc.free(optPP);
  try {
    _check(_api.SetIntraOpNumThreads.asFunction<
        bg.OrtStatusPtr Function(ffi.Pointer<bg.OrtSessionOptions>, int)>()(opt, threads));
    _check(_api.SetInterOpNumThreads.asFunction<
        bg.OrtStatusPtr Function(ffi.Pointer<bg.OrtSessionOptions>, int)>()(opt, 1));
    _check(_api.SetSessionGraphOptimizationLevel.asFunction<
            bg.OrtStatusPtr Function(ffi.Pointer<bg.OrtSessionOptions>, int)>()(
        opt, lowMemory ? bg.GraphOptimizationLevel.ORT_DISABLE_ALL : bg.GraphOptimizationLevel.ORT_ENABLE_ALL));
    if (lowMemory) {
      final off = <ffi.Pointer<ffi.NativeFunction<bg.OrtStatusPtr Function(ffi.Pointer<bg.OrtSessionOptions>)>>>[
        _api.DisableCpuMemArena,
        _api.DisableMemPattern,
      ];
      for (final f in off) {
        _check(f.asFunction<bg.OrtStatusPtr Function(ffi.Pointer<bg.OrtSessionOptions>)>()(opt));
      }
      final add = _api.AddSessionConfigEntry.asFunction<
          bg.OrtStatusPtr Function(ffi.Pointer<bg.OrtSessionOptions>, ffi.Pointer<ffi.Char>, ffi.Pointer<ffi.Char>)>();
      for (final (k, v) in const [
        ('session.disable_prepacking', '1'),
        ('session.use_device_allocator_for_initializers', '1'),
      ]) {
        final kp = k.toNativeUtf8(), vp = v.toNativeUtf8();
        try {
          _check(add(opt, kp.cast(), vp.cast()));
        } finally {
          calloc
            ..free(kp)
            ..free(vp);
        }
      }
    }

    // 바인딩은 char* 로 선언되어 있지만 Windows 네이티브는 wchar_t* 를 읽는다
    final ffi.Pointer<ffi.Char> pathPtr = Platform.isWindows
        ? path.toNativeUtf16().cast()
        : path.toNativeUtf8().cast();
    final sessPP = calloc<ffi.Pointer<bg.OrtSession>>();
    try {
      _check(_api.CreateSession.asFunction<
              bg.OrtStatusPtr Function(ffi.Pointer<bg.OrtEnv>, ffi.Pointer<ffi.Char>,
                  ffi.Pointer<bg.OrtSessionOptions>, ffi.Pointer<ffi.Pointer<bg.OrtSession>>)>()(
          OrtEnv.instance.ptr, pathPtr, opt, sessPP));
      return OrtSession.fromAddress(sessPP.value.address);
    } finally {
      calloc
        ..free(pathPtr)
        ..free(sessPP);
    }
  } finally {
    _api.ReleaseSessionOptions
        .asFunction<void Function(ffi.Pointer<bg.OrtSessionOptions>)>()(opt);
  }
}

/// int64 텐서 (release() 하면 데이터도 해제됨)
OrtValueTensor int64Tensor(List<int> data, List<int> shape) {
  final p = calloc<ffi.Int64>(data.isEmpty ? 1 : data.length);
  for (var i = 0; i < data.length; i++) {
    p[i] = data[i];
  }
  return _create(p.cast(), data.length * 8, shape,
      ONNXTensorElementDataType.int64.value);
}

/// float 텐서. [shape] 에 0 이 있으면 빈 텐서.
OrtValueTensor floatTensor(Float32List data, List<int> shape) {
  final p = calloc<ffi.Float>(data.isEmpty ? 1 : data.length);
  if (data.isNotEmpty) p.asTypedList(data.length).setAll(0, data);
  return _create(p.cast(), data.length * 4, shape,
      ONNXTensorElementDataType.float.value);
}

OrtValueTensor boolTensor(bool v) {
  final p = calloc<ffi.Bool>(1)..value = v;
  return _create(p.cast(), 1, [1], ONNXTensorElementDataType.bool.value);
}

/// 텐서 모양
List<int> tensorShape(OrtValue v) {
  final infoPP = calloc<ffi.Pointer<bg.OrtTensorTypeAndShapeInfo>>();
  _check(_api.GetTensorTypeAndShape.asFunction<
      bg.OrtStatusPtr Function(ffi.Pointer<bg.OrtValue>,
          ffi.Pointer<ffi.Pointer<bg.OrtTensorTypeAndShapeInfo>>)>()(v.ptr, infoPP));
  final info = infoPP.value;
  final countP = calloc<ffi.Size>();
  _check(_api.GetDimensionsCount.asFunction<
      bg.OrtStatusPtr Function(
          ffi.Pointer<bg.OrtTensorTypeAndShapeInfo>, ffi.Pointer<ffi.Size>)>()(info, countP));
  final n = countP.value;
  final dims = calloc<ffi.Int64>(n == 0 ? 1 : n);
  _check(_api.GetDimensions.asFunction<
      bg.OrtStatusPtr Function(
          ffi.Pointer<bg.OrtTensorTypeAndShapeInfo>, ffi.Pointer<ffi.Int64>, int)>()(info, dims, n));
  final shape = [for (var i = 0; i < n; i++) dims[i]];
  _api.ReleaseTensorTypeAndShapeInfo
      .asFunction<void Function(ffi.Pointer<bg.OrtTensorTypeAndShapeInfo>)>()(info);
  calloc
    ..free(dims)
    ..free(countP)
    ..free(infoPP);
  return shape;
}

/// float 텐서 데이터를 복사 없이 읽기 (텐서를 release 하기 전까지만 유효)
Float32List floatView(OrtValue v) {
  final shape = tensorShape(v);
  final count = shape.fold<int>(1, (a, b) => a * b);
  final pp = calloc<ffi.Pointer<ffi.Void>>();
  _check(_api.GetTensorMutableData.asFunction<
      bg.OrtStatusPtr Function(ffi.Pointer<bg.OrtValue>, ffi.Pointer<ffi.Pointer<ffi.Void>>)>()(
      v.ptr, pp));
  final data = pp.value.cast<ffi.Float>();
  calloc.free(pp);
  return data.asTypedList(count);
}
