# flutter_inappwebview_android 1.1.3 사본 (JJ_MKVMaker 패치)

원본: https://pub.dev/packages/flutter_inappwebview_android 1.1.3 (pubspec.yaml 의 dependency_overrides 로 사용)

## 고친 문제
새 Android 빌드 도구 (AGP 9) 가 `getDefaultProguardFile('proguard-android.txt')` 를 더는 받지 않아 APK 빌드가 실패함.

## 수정
- android/build.gradle: `proguard-android.txt` → `proguard-android-optimize.txt`
- example 폴더 제거
