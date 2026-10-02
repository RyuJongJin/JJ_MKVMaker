# ffmpeg_kit_flutter_new_min_gpl 2.6.2 사본 (JJ_MKVMaker 패치)

원본: https://pub.dev/packages/ffmpeg_kit_flutter_new_min_gpl 2.6.2 (pubspec.yaml 의 dependency_overrides 로 사용)

## 고친 문제
원본은 Windows 에도 FFmpeg DLL (약 30MB) 을 프로그램 폴더에 넣는다.
JJ_MKVMaker 의 Windows 판은 동봉한 ffmpeg.exe 를 쓰므로 필요 없다.

## 수정
- pubspec.yaml: 플러그인 플랫폼을 android 만 남김 (ios · macos · windows · linux 제거)
- windows · linux · macos · ios · example 폴더 제거

## 통계 이벤트 줄이기 (2026-10-02)
FFmpeg 는 프레임마다 통계(진행률)를 보낸다. 17분 영상 하나에 수만 개가 Dart 로 넘어가 메인 스레드 줄이 밀리고,
완료 이벤트가 그 뒤에 서 있어 FFmpeg 가 4초 만에 끝나도 앱은 2분 넘게 "작업 중" 으로 남았다.
- android/.../FFmpegKitFlutterPlugin.java: 통계는 세션마다 0.25초에 한 번만 보낸다 (`shouldEmitStatistics`)
