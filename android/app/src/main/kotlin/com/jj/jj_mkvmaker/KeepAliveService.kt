package com.jj.jj_mkvmaker

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.PowerManager

/// 다운로드 · MKV 만들기 · AI 자막이 진행 중일 때 앱이 화면에서 내려가도 Android 가 멈추지 않도록 하는
/// 포그라운드 서비스. 알림에 진행 상황을 보여 주고, 화면이 꺼져도 CPU 가 잠들지 않게 한다.
/// 실제 작업은 앱 (Dart) 이 같은 프로세스에서 계속한다. 작업이 모두 끝나면 앱이 멈춘다.
class KeepAliveService : Service() {
    private var wakeLock: PowerManager.WakeLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val text = intent?.getStringExtra(EXTRA_TEXT) ?: ""
        val progress = intent?.getIntExtra(EXTRA_PROGRESS, -1) ?: -1
        val n = notification(this, text, progress)
        running = true
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(NOTIFICATION_ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        } else {
            startForeground(NOTIFICATION_ID, n)
        }
        if (wakeLock == null) {
            wakeLock = (getSystemService(Context.POWER_SERVICE) as PowerManager)
                .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "jj_mkvmaker:jobs")
                .apply { acquire(6 * 60 * 60 * 1000L) }
        }
        return START_NOT_STICKY
    }

    /// Android 15 부터 dataSync 서비스는 하루 6시간까지 → 시간이 다 되면 멈춘다 (작업은 앱이 화면에 있으면 계속)
    override fun onTimeout(startId: Int, fgsType: Int) {
        stopSelf()
    }

    override fun onDestroy() {
        running = false
        wakeLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
        super.onDestroy()
    }

    companion object {
        const val CHANNEL_ID = "jobs"
        const val NOTIFICATION_ID = 1
        const val EXTRA_TEXT = "text"
        const val EXTRA_PROGRESS = "progress"

        /// 서비스가 떠 있는지 (떠 있으면 알림만 바꾼다 - 백그라운드에서는 서비스를 새로 시작할 수 없음)
        @Volatile
        var running = false

        fun update(context: Context, text: String, progress: Int) {
            val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            nm.notify(NOTIFICATION_ID, notification(context, text, progress))
        }

        private fun notification(context: Context, text: String, progress: Int): Notification {
            val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && nm.getNotificationChannel(CHANNEL_ID) == null) {
                nm.createNotificationChannel(
                    NotificationChannel(CHANNEL_ID, "작업 진행", NotificationManager.IMPORTANCE_LOW).apply {
                        description = "다운로드 · MKV 만들기 · AI 자막 진행 상황"
                        setShowBadge(false)
                    }
                )
            }
            val open = PendingIntent.getActivity(
                context, 0,
                Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
            )
            val b = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                Notification.Builder(context, CHANNEL_ID)
            } else {
                @Suppress("DEPRECATION") Notification.Builder(context)
            }
            b.setSmallIcon(android.R.drawable.stat_sys_download)
                .setContentTitle("JJ_MKVMaker 작업 중")
                .setContentText(text)
                .setContentIntent(open)
                .setOngoing(true)
                .setOnlyAlertOnce(true)
            if (progress in 0..100) b.setProgress(100, progress, false)
            return b.build()
        }
    }
}
