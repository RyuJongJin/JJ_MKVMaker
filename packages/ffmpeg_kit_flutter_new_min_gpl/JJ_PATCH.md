# ffmpeg_kit_flutter_new_min_gpl 2.6.2 사본 (JJ_MKVMaker 패치)

원본: https://pub.dev/packages/ffmpeg_kit_flutter_new_min_gpl 2.6.2 (pubspec.yaml 의 dependency_overrides 로 사용)

## 고친 문제
원본은 Windows 에도 FFmpeg DLL (약 30MB) 을 프로그램 폴더에 넣는다.
JJ_MKVMaker 의 Windows 판은 동봉한 ffmpeg.exe 를 쓰므로 필요 없다.

## 수정
- pubspec.yaml: 플러그인 플랫폼을 android 만 남김 (ios · macos · windows · linux 제거)
- windows · linux · macos · ios · example 폴더 제거
