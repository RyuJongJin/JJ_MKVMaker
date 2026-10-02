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
