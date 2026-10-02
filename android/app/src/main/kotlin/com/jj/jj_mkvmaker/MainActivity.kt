package com.jj.jj_mkvmaker

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.Settings
import com.yausername.aria2c.Aria2c
import com.yausername.ffmpeg.FFmpeg
import com.yausername.youtubedl_android.YoutubeDL
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

/// 저장소 전체 접근 (동영상 옆 jj_mkv 폴더에 MKV 를 만들기 위해) 확인 · 요청, 다운로드 프로그램 준비
class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "jj_mkvmaker/android").setMethodCallHandler { call, result ->
            when (call.method) {
                "hasAllFilesAccess" -> result.success(hasAllFilesAccess())
                "requestAllFilesAccess" -> {
                    requestAllFilesAccess()
                    result.success(null)
                }
                "storageRoot" -> result.success(Environment.getExternalStorageDirectory().path)
                "openUrl" -> result.success(openUrl(call.argument<String>("url") ?: ""))
                "installApk" -> try {
                    installApk(call.argument<String>("path") ?: "")
                    result.success(null)
                } catch (e: Exception) {
                    result.error("INSTALL", e.message ?: e.toString(), null)
                }
                "openFolder" -> result.success(openFolder(call.argument<String>("path") ?: ""))
                "keepAlive" -> {
                    keepAlive(call.argument<String>("text") ?: "", call.argument<Int>("progress") ?: -1)
                    result.success(null)
                }
                "stopKeepAlive" -> {
                    stopService(Intent(this, KeepAliveService::class.java))
                    result.success(null)
                }
                "downloadToolsInit" -> inBackground(result) { downloadToolsInit() }
                "downloadToolsUpdate" -> inBackground(result) {
                    YoutubeDL.updateYoutubeDL(applicationContext)?.name ?: ""
                }
                else -> result.notImplemented()
            }
        }
    }

    /// 받은 업데이트 APK 로 Android 설치 화면을 연다. 앱 전용 폴더의 파일이라 FileProvider 로 넘긴다.
    /// 처음이면 "이 출처의 앱 설치 허용" 설정 화면을 먼저 연다 (허용한 뒤 다시 [업데이트])
    private fun installApk(path: String) {
        val src = File(path)
        if (!src.isFile) throw IllegalArgumentException("APK 파일이 없습니다: $path")
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && !packageManager.canRequestPackageInstalls()) {
            startActivity(
                Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:$packageName"))
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            )
            throw IllegalStateException("\"이 출처의 앱 설치 허용\" 을 켠 뒤 다시 [업데이트] 를 누르세요")
        }
        // FileProvider 가 내보내는 폴더 (cache/updates) 로 옮긴다
        val dir = File(cacheDir, "updates").apply { mkdirs() }
        val apk = File(dir, "update.apk")
        if (src.absolutePath != apk.absolutePath) {
            apk.delete()
            if (!src.renameTo(apk)) {
                src.copyTo(apk, overwrite = true)
                src.delete()
            }
        }
        val uri = androidx.core.content.FileProvider.getUriForFile(this, "$packageName.files", apk)
        startActivity(
            Intent(Intent.ACTION_VIEW)
                .setDataAndType(uri, "application/vnd.android.package-archive")
                .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
        )
    }

    /// 웹 주소를 기기의 기본 브라우저로
    private fun openUrl(url: String): Boolean = try {
        startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        true
    } catch (e: Exception) {
        false
    }

    /// 폴더를 파일 앱으로 연다 (내장 저장소 안의 폴더만). 열 앱이 없으면 false.
    private fun openFolder(path: String): Boolean {
        val root = Environment.getExternalStorageDirectory().path
        if (!path.startsWith(root)) return false
        val rel = path.removePrefix(root).trim('/')
        // 1. 삼성 "내 파일": 그 폴더로 바로 연다
        try {
            startActivity(
                Intent("samsung.myfiles.intent.action.LAUNCH_MY_FILES")
                    .setPackage("com.sec.android.app.myfiles")
                    .putExtra("samsung.myfiles.intent.extra.START_PATH", path)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            )
            return true
        } catch (e: Exception) {
        }
        // 2. 시스템 "파일" 앱 (Google / AOSP). 다른 파일 관리자 (X-plore 등) 는 이 주소의 폴더로 가지 않아 앱을 정해 연다
        val uri = android.provider.DocumentsContract.buildDocumentUri(
            "com.android.externalstorage.documents", "primary:$rel"
        )
        for (pkg in listOf("com.google.android.documentsui", "com.android.documentsui", null)) {
            try {
                startActivity(
                    Intent(Intent.ACTION_VIEW)
                        .setDataAndType(uri, android.provider.DocumentsContract.Document.MIME_TYPE_DIR)
                        .apply { if (pkg != null) setPackage(pkg) }
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_GRANT_READ_URI_PERMISSION)
                )
                return true
            } catch (e: Exception) {
            }
        }
        return false
    }

    /// 작업 진행 알림 (포그라운드 서비스) 시작 · 갱신. 처음 한 번 알림 권한을 묻는다 (Android 13+, 거절해도 작업은 계속)
    private var askedNotifications = false

    private fun keepAlive(text: String, progress: Int) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU && !askedNotifications &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) {
            askedNotifications = true
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 2)
        }
        if (KeepAliveService.running) {
            KeepAliveService.update(this, text, progress)
            return
        }
        val i = Intent(this, KeepAliveService::class.java)
            .putExtra(KeepAliveService.EXTRA_TEXT, text)
            .putExtra(KeepAliveService.EXTRA_PROGRESS, progress)
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) startForegroundService(i) else startService(i)
        } catch (e: Exception) {
            // 백그라운드에서는 새로 시작할 수 없다 (Android 12+). 이미 떠 있으면 다음 갱신 때 바뀐다
            android.util.Log.w("jj_mkvmaker", "keepAlive", e)
        }
    }

    /// 오래 걸리는 일 (처음 켤 때 실행 파일 풀기 · yt-dlp 업데이트) 은 메인 스레드 밖에서
    private fun inBackground(result: MethodChannel.Result, work: () -> Any?) {
        Thread {
            try {
                val value = work()
                runOnUiThread { result.success(value) }
            } catch (e: Throwable) {
                android.util.Log.e("jj_mkvmaker", "download tools", e)
                val cause = generateSequence(e) { it.cause }.last()
                runOnUiThread { result.error("TOOLS", "${e.javaClass.simpleName}: ${cause.message ?: cause}", null) }
            }
        }.start()
    }

    /// youtubedl-android 가 앱에 넣은 Python · yt-dlp · ffmpeg · aria2c 를 풀고, 직접 실행할 경로 · 환경 변수를 돌려준다.
    /// 경로 규칙은 youtubedl-android 0.18.1 의 YoutubeDL.init / FFmpeg.init / Aria2c.init 과 같다.
    private fun downloadToolsInit(): Map<String, Any> {
        YoutubeDL.init(applicationContext)
        FFmpeg.init(applicationContext)
        Aria2c.init(applicationContext)
        val bin = applicationInfo.nativeLibraryDir
        val base = File(noBackupFilesDir, YoutubeDL.baseName)
        val packages = File(base, "packages")
        val python = File(packages, "python").absolutePath
        val ffmpeg = File(packages, "ffmpeg").absolutePath
        val aria2c = File(packages, "aria2c").absolutePath
        val cert = "$python/usr/etc/tls/cert.pem"
        return mapOf(
            "python" to "$bin/libpython.so",
            "ytdlp" to File(File(base, YoutubeDL.ytdlpDirName), YoutubeDL.ytdlpBin).absolutePath,
            "ffmpeg" to "$bin/libffmpeg.so",
            "quickjs" to "$bin/libqjs.so",
            "aria2c" to "$bin/libaria2c.so",
            "cert" to cert,
            "version" to (YoutubeDL.versionName(applicationContext) ?: ""),
            "env" to mapOf(
                "LD_LIBRARY_PATH" to "$python/usr/lib:$ffmpeg/usr/lib:$aria2c/usr/lib",
                "SSL_CERT_FILE" to cert,
                "PATH" to (System.getenv("PATH") ?: "") + ":" + bin,
                "PYTHONHOME" to "$python/usr",
                "HOME" to "$python/usr",
                "TMPDIR" to cacheDir.absolutePath,
            ),
        )
    }

    private fun hasAllFilesAccess(): Boolean =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            Environment.isExternalStorageManager()
        } else {
            checkSelfPermission(Manifest.permission.WRITE_EXTERNAL_STORAGE) == PackageManager.PERMISSION_GRANTED
        }

    private fun requestAllFilesAccess() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            try {
                startActivity(Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION, Uri.parse("package:$packageName")))
            } catch (e: Exception) {
                startActivity(Intent(Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION))
            }
        } else {
            requestPermissions(
                arrayOf(Manifest.permission.READ_EXTERNAL_STORAGE, Manifest.permission.WRITE_EXTERNAL_STORAGE), 1
            )
        }
    }
}
