# youtubedl-android (Android 다운로드): 코드 축소(R8)가 Jackson · 압축 풀기 클래스를 지우거나 이름을 바꾸면
# YoutubeDL 객체를 만들 때 ExceptionInInitializerError 가 난다 (youtubedl-android README 의 권장 규칙)
-keep class com.yausername.** { *; }
-keep class com.fasterxml.jackson.** { *; }
-keep class org.apache.commons.compress.archivers.zip.** { *; }
-dontwarn com.fasterxml.jackson.**
-dontwarn org.apache.commons.**
