# whisper_ggml 2.6.0 사본 (JJ_MKVMaker 패치)

원본: https://pub.dev/packages/whisper_ggml 2.6.0

## 고친 문제
Windows 에서 음성인식이 끝나는 순간 앱이 종료됨 (예외 코드 0xc0000374, 힙 손상).

- 네이티브(main.cpp)는 응답 문자열을 C 런타임 `malloc` 으로 할당
- Dart 는 `package:ffi` 의 `malloc.free` 로 해제 → Windows 에서는 `CoTaskMemFree` 이므로 다른 힙

## 수정
- android/src/whisper/main.cpp: `free_response()` 내보내기 추가 (같은 C 런타임의 `free` 호출)
- lib/src/whisper.dart, lib/src/whisper_live.dart: `malloc.free(res)` → `Whisper.freeNativeResponse()`
- example 폴더 제거

원본 패키지에서 고쳐지면 pubspec.yaml 을 다시 `whisper_ggml: ^버전` 으로 바꾸면 된다.
