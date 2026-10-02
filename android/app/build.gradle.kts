import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// 배포 서명 키 (android/key.properties, 저장소에 올리지 않음). 없으면 디버그 키로 서명.
val keyProps = Properties().apply {
    val f = rootProject.file("key.properties")
    if (f.exists()) f.inputStream().use { load(it) }
}

android {
    namespace = "com.jj.jj_mkvmaker"
    compileSdk = flutter.compileSdkVersion
    // whisper_ggml 이 NDK 29 를 요구 (더 낮은 버전용 코드와 호환)
    ndkVersion = "29.0.13113456"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.jj.jj_mkvmaker"
        // ffmpeg-kit 은 Android 7.0 (API 24) 이상
        minSdk = maxOf(24, flutter.minSdkVersion)
        targetSdk = flutter.targetSdkVersion
        // 버전 "년.월.일+순번" 의 순번은 날마다 1 부터 다시 시작하므로 그대로 쓰면 다음 날 판이 "더 낮은 버전" 으로
        // 설치가 거부된다. 날짜를 앞에 붙여 늘 커지게 한다: 2026.10.2+1 → 261002001
        versionCode = flutter.versionName.split(".").let { (y, m, d) ->
            (y.toInt() % 100) * 10_000_000 + m.toInt() * 100_000 + d.toInt() * 1_000 + flutter.versionCode
        }
        versionName = flutter.versionName
        // 요즘 휴대폰 · 태블릿 (64비트 ARM) 만. 플러그인이 다른 CPU 용 라이브러리를 넣어도 앱 본체가 없으면 실행되지 않으므로 뺀다
        ndk {
            abiFilters += listOf("arm64-v8a")
        }
    }

    signingConfigs {
        if (keyProps.getProperty("storeFile") != null) {
            create("release") {
                storeFile = file(keyProps.getProperty("storeFile"))
                storePassword = keyProps.getProperty("storePassword")
                keyAlias = keyProps.getProperty("keyAlias")
                keyPassword = keyProps.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            signingConfig = signingConfigs.findByName("release") ?: signingConfigs.getByName("debug")
        }
    }

    // ffmpeg · whisper 등 네이티브 라이브러리를 압축하지 않고 그대로 (설치 후 바로 로드)
    packaging {
        jniLibs {
            useLegacyPackaging = true
            // 64비트 ARM 만 (위 abiFilters 와 같은 뜻, 플러그인 라이브러리까지 확실히 빼기)
            excludes += setOf("lib/x86_64/**", "lib/x86/**", "lib/armeabi-v7a/**")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

// 다운로드 (앱 안 브라우저 · 다운로드 목록): Android 용 yt-dlp (Python 포함) · ffmpeg (영상 · 음성 합치기) · aria2c (토렌트)
// 실행 파일을 앱에 넣고 처음 켤 때 풀어 둔다. 실행은 Dart (YtDlpBackend · Aria2Backend) 가 Windows 와 같은 방식으로 한다.
dependencies {
    implementation("io.github.junkfood02.youtubedl-android:library:0.18.1")
    implementation("io.github.junkfood02.youtubedl-android:ffmpeg:0.18.1")
    implementation("io.github.junkfood02.youtubedl-android:aria2c:0.18.1")
}
