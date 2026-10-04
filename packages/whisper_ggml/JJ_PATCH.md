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

## Android: FFmpeg 하나만 넣기
- pubspec.yaml · lib/src/whisper_audio_convert.dart: `ffmpeg_kit_flutter_new_min` → `ffmpeg_kit_flutter_new_min_gpl`
  (앱이 MKV 만들기에 쓰는 것과 같은 것. 두 가지가 함께 들어가면 같은 이름의 Java 클래스 · 네이티브 라이브러리가 겹쳐 빌드 · 실행이 안 됨)
- android/build.gradle: compileSdk 34 → 36 (ffmpeg-kit min-gpl 이 35 이상을 요구)

## 음성인식 취소 (JJ_MKVMaker)
- android/src/whisper/main.cpp: 요청 JSON 의 `abort_flag` (Dart 가 가진 int32 의 주소) 를 `whisper_full_params.abort_callback` 에 연결. 값이 0 이 아니면 whisper 가 다음 계산 단계에서 멈춘다.
  Android arm64 의 힙 주소는 맨 위 바이트에 태그가 있어 Dart int 로는 음수 → 부호 있는 정수도 받는다.
- lib/src/whisper.dart: `transcribe(abortFlagAddress:)` → 요청 JSON 에 `abort_flag` 추가.
