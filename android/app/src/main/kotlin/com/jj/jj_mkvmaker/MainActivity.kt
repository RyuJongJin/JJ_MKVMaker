package com.jj.jj_mkvmaker

import android.Manifest
import android.content.Context
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
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.plugin.common.MethodChannel
import java.io.File

/// 저장소 전체 접근 (동영상 옆 jj_mkv 폴더에 MKV 를 만들기 위해) 확인 · 요청, 다운로드 프로그램 준비
class MainActivity : FlutterActivity() {
    companion object {
        /// 작업 알림을 눌렀을 때: 작업 현황 화면을 연다
        const val ACTION_SHOW_JOBS = "com.jj.jj_mkvmaker.SHOW_JOBS"

        private const val ENGINE_ID = "main"

        /// 백그라운드로 실행 (환경 설정, Dart 가 알려 준다): 켜져 있으면 화면을 닫아도 (← · 최근 앱에서 밀기)
        /// Dart 엔진을 없애지 않아 동기화 · MKV 만들기 · 다운로드가 계속된다 (작업 알림 서비스가 프로세스를 살려 둠).
        @Volatile
        var background = false
    }

    /// 앞 화면이 닫힌 뒤 살아 있던 엔진을 다시 붙였는지 (Dart 는 이미 돌고 있다)
    private var reusedEngine = false

    /// 엔진은 앱 (프로세스) 이 갖는다: 화면이 닫혀도 [background] 면 살려 두고, 다시 열면 그 엔진을 붙인다
    override fun provideFlutterEngine(context: Context): FlutterEngine {
        val cache = FlutterEngineCache.getInstance()
        cache.get(ENGINE_ID)?.let {
            reusedEngine = true
            return it
        }
        return FlutterEngine(context.applicationContext).also { cache.put(ENGINE_ID, it) }
    }

    /// 백그라운드로 실행이 꺼져 있으면 지금처럼 화면과 함께 엔진도 끝낸다
    override fun shouldDestroyEngineWithHost(): Boolean {
        if (background) return false
        FlutterEngineCache.getInstance().remove(ENGINE_ID)
        return true
    }

    /// 첫 화면에서 ←: 백그라운드로 실행이면 앱을 끝내지 않고 뒤로 보낸다 (홈 버튼과 같음)
    override fun popSystemNavigator(): Boolean {
        if (!background) return false
        moveTaskToBack(true)
        return true
    }

    private var channel: MethodChannel? = null

    /// 앱이 켜질 때 작업 알림으로 열렸는지 (Dart 가 준비되면 가져간다)
    private var pendingShowJobs = false

    /// 다른 앱에서 연 동영상 (앱이 켜질 때 받은 것: Dart 가 준비되면 가져간다)
    private var pendingOpen: List<Map<String, String?>> = emptyList()

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        pendingOpen = openedFiles(intent)
        pendingShowJobs = intent?.action == ACTION_SHOW_JOBS
        val ch = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "jj_mkvmaker/android")
        channel = ch
        if (reusedEngine) {
            // Dart 는 이미 돌고 있어 take… 로 가져가지 않는다: 바로 보낸다
            if (pendingShowJobs) ch.invokeMethod("showJobs", null)
            if (pendingOpen.isNotEmpty()) ch.invokeMethod("openFiles", pendingOpen)
            pendingShowJobs = false
            pendingOpen = emptyList()
        }
        ch.setMethodCallHandler { call, result ->
            when (call.method) {
                "setBackground" -> {
                    background = call.argument<Boolean>("on") ?: false
                    result.success(null)
                }
                "exitApp" -> {
                    // [종료]: 작업 알림 · 살려 둔 엔진까지 모두 끝낸다
                    result.success(null)
                    background = false
                    stopService(Intent(applicationContext, KeepAliveService::class.java))
                    FlutterEngineCache.getInstance().remove(ENGINE_ID)
                    finishAndRemoveTask()
                    android.os.Handler(mainLooper).postDelayed({
                        android.os.Process.killProcess(android.os.Process.myPid())
                    }, 300)
                }
                "takeOpenedFiles" -> {
                    result.success(pendingOpen)
                    pendingOpen = emptyList()
                }
                "takeShowJobs" -> {
                    result.success(pendingShowJobs)
                    pendingShowJobs = false
                }
                "hasAllFilesAccess" -> result.success(hasAllFilesAccess())
                "requestAllFilesAccess" -> {
                    requestAllFilesAccess()
                    result.success(null)
                }
                "storageRoot" -> result.success(Environment.getExternalStorageDirectory().path)
                // 앱에 들어 있는 rsync (librsync.so) 가 풀리는 곳
                "nativeLibDir" -> result.success(applicationInfo.nativeLibraryDir)
                "storageVolumes" -> result.success(storageVolumes())
                "openUrl" -> result.success(openUrl(call.argument<String>("url") ?: ""))
                "installApk" -> try {
                    installApk(call.argument<String>("path") ?: "")
                    result.success(null)
                } catch (e: IllegalStateException) {
                    // 설치 허용 설정 화면을 열었다: 앱이 받은 파일로 다시 설치하게 따로 알린다
                    result.error("PERMISSION", e.message ?: e.toString(), null)
                } catch (e: Exception) {
                    result.error("INSTALL", e.message ?: e.toString(), null)
                }
                "openFolder" -> result.success(openFolder(call.argument<String>("path") ?: ""))
                // 예전 버전으로 되돌리기: Android 는 낮은 버전을 위에 설치하지 못해 앱을 지우는 확인 창을 연다
                "uninstallSelf" -> {
                    startActivity(Intent(Intent.ACTION_DELETE, Uri.parse("package:$packageName")).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                    result.success(null)
                }
                "diskSpace" -> result.success(
                    try {
                        val st = android.os.StatFs(call.argument<String>("path") ?: "")
                        listOf(st.availableBytes, st.totalBytes)
                    } catch (e: Exception) {
                        null
                    }
                )
                "openWith" -> result.success(
                    openWith(call.argument<String>("path") ?: "", call.argument<Boolean>("choose") ?: false)
                )
                "setAppIcon" -> result.success(setAppIcon(call.argument<String>("id") ?: ""))
                "keepAlive" -> {
                    keepAlive(call.argument<String>("text") ?: "", call.argument<Int>("progress") ?: -1,
                        call.argument<String>("icon") ?: "")
                    result.success(null)
                }
                "stopKeepAlive" -> {
                    stopService(Intent(applicationContext, KeepAliveService::class.java))
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
    /// 처음이면 "이 출처의 앱 설치 허용" 설정 화면을 먼저 연다 (허용하고 돌아와 [설치 계속] - 받은 파일을 그대로 쓴다)
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

    /// 앱이 켜져 있을 때 다른 앱에서 동영상을 열면 (launchMode singleTop)
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        if (intent.action == ACTION_SHOW_JOBS) {
            channel?.invokeMethod("showJobs", null)
            return
        }
        val files = openedFiles(intent)
        if (files.isNotEmpty()) channel?.invokeMethod("openFiles", files)
    }

    /// 연결 프로그램 (VIEW) · 공유 (SEND) 로 받은 동영상: [{path (실제 경로, 모르면 null), uri, name}]
    private fun openedFiles(intent: Intent?): List<Map<String, String?>> {
        if (intent == null) return emptyList()
        val uris = mutableListOf<Uri>()
        when (intent.action) {
            Intent.ACTION_VIEW -> intent.data?.let { uris.add(it) }
            Intent.ACTION_SEND -> intentStream(intent)?.let { uris.add(it) }
            Intent.ACTION_SEND_MULTIPLE -> intentStreams(intent)?.let { uris.addAll(it) }
        }
        return uris.map { mapOf("path" to realPath(it), "uri" to it.toString(), "name" to displayName(it)) }
    }

    @Suppress("DEPRECATION")
    private fun intentStream(i: Intent): Uri? =
        if (Build.VERSION.SDK_INT >= 33) i.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
        else i.getParcelableExtra(Intent.EXTRA_STREAM)

    @Suppress("DEPRECATION")
    private fun intentStreams(i: Intent): List<Uri>? =
        if (Build.VERSION.SDK_INT >= 33) i.getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java)
        else i.getParcelableArrayListExtra(Intent.EXTRA_STREAM)

    private fun displayName(uri: Uri): String? = try {
        contentResolver.query(uri, arrayOf(android.provider.OpenableColumns.DISPLAY_NAME), null, null, null)?.use {
            if (it.moveToFirst()) it.getString(0) else null
        }
    } catch (e: Exception) {
        null
    } ?: uri.lastPathSegment?.substringAfterLast('/')

    /// content:// → 실제 파일 경로 ("모든 파일에 대한 접근" 이 있으면 그 경로로 읽고 옆에 MKV 를 만들 수 있다). 모르면 null.
    private fun realPath(uri: Uri): String? {
        fun ok(path: String?) = path != null && File(path).isFile
        if (uri.scheme == "file") return uri.path?.takeIf { ok(it) }
        if (uri.scheme != "content") return null
        // 1. 저장소 문서 (primary:Download/a.mp4 · XXXX-XXXX:Movies/a.mp4)
        try {
            if (android.provider.DocumentsContract.isDocumentUri(this, uri) &&
                uri.authority == "com.android.externalstorage.documents"
            ) {
                val id = android.provider.DocumentsContract.getDocumentId(uri)
                val vol = id.substringBefore(':')
                val rel = id.substringAfter(':', "")
                val base = if (vol == "primary") Environment.getExternalStorageDirectory().path else "/storage/$vol"
                val path = "$base/$rel"
                if (ok(path)) return path
            }
        } catch (e: Exception) {
        }
        // 2. 미디어 저장소 등이 알려 주는 경로 (_data)
        try {
            contentResolver.query(uri, arrayOf("_data"), null, null, null)?.use {
                if (it.moveToFirst()) {
                    val path = it.getString(0)
                    if (ok(path)) return path
                }
            }
        } catch (e: Exception) {
        }
        // 3. 주소 안의 경로 조각을 저장소 맨 위에 붙여 본다 (파일 앱마다 주소 모양이 달라서)
        //    예: content://…/device_storage/0/Download/a.mp4 → /storage/emulated/0/Download/a.mp4 (크기가 같을 때만)
        val size = try {
            contentResolver.query(uri, arrayOf(android.provider.OpenableColumns.SIZE), null, null, null)?.use {
                if (it.moveToFirst() && !it.isNull(0)) it.getLong(0) else -1L
            } ?: -1L
        } catch (e: Exception) {
            -1L
        }
        val segs = uri.pathSegments.flatMap { Uri.decode(it).split('/') }.filter { it.isNotEmpty() }
        val roots = storageVolumes().map { it["path"] as String }
        for (i in segs.indices) {
            val rest = segs.drop(i).joinToString("/")
            for (root in roots) {
                val f = File(root, rest)
                if (f.isFile && (size < 0 || f.length() == size)) return f.absolutePath
            }
            // 경로 조각 안에 저장소 경로가 그대로 있는 경우 (/storage/emulated/0/…)
            val abs = "/$rest"
            if (abs.startsWith("/storage/") && ok(abs)) return abs
        }
        return null
    }

    /// 쓸 수 있는 저장소 (내장 · SD 카드 · USB 메모리): [{path, label, removable}]
    private fun storageVolumes(): List<Map<String, Any>> {
        val sm = getSystemService(STORAGE_SERVICE) as android.os.storage.StorageManager
        val out = mutableListOf<Map<String, Any>>()
        for (v in sm.storageVolumes) {
            if (v.state != Environment.MEDIA_MOUNTED) continue
            val dir: File? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                v.directory
            } else {
                try {
                    v.javaClass.getMethod("getPathFile").invoke(v) as File?
                } catch (e: Exception) {
                    null
                }
            }
            if (dir == null) continue
            out.add(
                mapOf(
                    "path" to dir.absolutePath,
                    "label" to (v.getDescription(this) ?: dir.name),
                    "removable" to v.isRemovable,
                )
            )
        }
        return out
    }

    /// 웹 주소를 기기의 기본 브라우저로
    private fun openUrl(url: String): Boolean = try {
        startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        true
    } catch (e: Exception) {
        false
    }

    /// 폴더를 파일 앱으로 연다 (내장 저장소 안의 폴더만). 열 앱이 없으면 false.
    /// 앱 아이콘 바꾸기: 고른 아이콘의 activity-alias 만 켜고 나머지는 끈다 (앱은 계속 켜 둔 채로)
    private fun setAppIcon(id: String): Boolean {
        val ids = listOf("yellow", "black", "film_jj", "film", "blue")
        if (id !in ids) return false
        val pm = packageManager
        for (i in ids) {
            val name = "$packageName.Icon" + i.split('_').joinToString("") { it.replaceFirstChar(Char::uppercaseChar) }
            val state = if (i == id) PackageManager.COMPONENT_ENABLED_STATE_ENABLED
            else PackageManager.COMPONENT_ENABLED_STATE_DISABLED
            val cn = android.content.ComponentName(this, name)
            if (pm.getComponentEnabledSetting(cn) != state) {
                pm.setComponentEnabledSetting(cn, state, PackageManager.DONT_KILL_APP)
            }
        }
        return true
    }

    /// 파일 탐색기: 파일을 다른 앱으로 연다. [choose] 면 늘 앱 고르기 창 (이 앱은 뺌), 아니면 기본 앱 (없으면 고르기 창).
    /// SD 카드 · USB 파일도 넘길 수 있게 FileProvider 의 root 경로를 쓴다 (res/xml/jj_file_paths.xml).
    private fun openWith(path: String, choose: Boolean): Boolean {
        val f = File(path)
        if (!f.isFile) return false
        val uri = try {
            androidx.core.content.FileProvider.getUriForFile(this, "$packageName.files", f)
        } catch (e: Exception) {
            return false
        }
        val mime = android.webkit.MimeTypeMap.getSingleton().getMimeTypeFromExtension(f.extension.lowercase()) ?: "*/*"
        val view = Intent(Intent.ACTION_VIEW)
            .setDataAndType(uri, mime)
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
        fun chooser(): Intent = Intent.createChooser(view, null)
            .putExtra(Intent.EXTRA_EXCLUDE_COMPONENTS, arrayOf(android.content.ComponentName(this, MainActivity::class.java)))
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        return try {
            startActivity(if (choose) chooser() else view)
            true
        } catch (e: Exception) {
            try {
                startActivity(chooser())
                true
            } catch (e2: Exception) {
                false
            }
        }
    }

    private fun openFolder(path: String): Boolean {
        // 내장 저장소 (primary) 또는 SD 카드 · USB (/storage/XXXX-XXXX → 문서 ID "XXXX-XXXX:...")
        val root = Environment.getExternalStorageDirectory().path
        val (volumeId, rel) = when {
            path.startsWith(root) -> "primary" to path.removePrefix(root).trim('/')
            path.startsWith("/storage/") -> {
                val rest = path.removePrefix("/storage/")
                rest.substringBefore('/') to rest.substringAfter('/', "").trim('/')
            }
            else -> return false
        }
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
            "com.android.externalstorage.documents", "$volumeId:$rel"
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

    private fun keepAlive(text: String, progress: Int, icon: String) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU && !askedNotifications && !isDestroyed &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) {
            askedNotifications = true
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 2)
        }
        if (KeepAliveService.running) {
            KeepAliveService.update(applicationContext, text, progress, icon)
            return
        }
        val i = Intent(applicationContext, KeepAliveService::class.java)
            .putExtra(KeepAliveService.EXTRA_TEXT, text)
            .putExtra(KeepAliveService.EXTRA_PROGRESS, progress)
            .putExtra(KeepAliveService.EXTRA_ICON, icon)
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) applicationContext.startForegroundService(i)
            else applicationContext.startService(i)
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
