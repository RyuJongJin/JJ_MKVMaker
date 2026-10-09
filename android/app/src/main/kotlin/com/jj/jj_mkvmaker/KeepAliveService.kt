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

/// 다운로드 · MKV 만들기 · AI 자막 · 실시간 동기화 (백그라운드로 실행) 가 진행 중일 때 앱이 화면에서 내려가도 Android 가 멈추지 않도록 하는
/// 포그라운드 서비스. 알림에 진행 상황을 보여 주고, 화면이 꺼져도 CPU 가 잠들지 않게 한다.
/// 실제 작업은 앱 (Dart) 이 같은 프로세스에서 계속한다. 작업이 모두 끝나면 앱이 멈춘다.
class KeepAliveService : Service() {
    private var wakeLock: PowerManager.WakeLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val text = intent?.getStringExtra(EXTRA_TEXT) ?: ""
        val progress = intent?.getIntExtra(EXTRA_PROGRESS, -1) ?: -1
        val icon = intent?.getStringExtra(EXTRA_ICON) ?: ""
        val n = notification(this, text, progress, icon)
        running = true
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            // 실시간 동기화는 앱이 켜져 있는 내내 지켜봐야 하므로 하루 6시간 제한이 있는 dataSync 대신 specialUse (Android 14+)
            startForeground(NOTIFICATION_ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
        } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(NOTIFICATION_ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        } else {
            startForeground(NOTIFICATION_ID, n)
        }
        if (wakeLock == null) {
            wakeLock = (getSystemService(Context.POWER_SERVICE) as PowerManager)
                .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "jj_mkvmaker:jobs")
                .apply {
                    setReferenceCounted(false)
                    acquire(RENEW_MS * 2)
                }
            // 22: 6시간이 지나면 잠금이 풀려 화면을 끈 채 걸어 둔 동기화 · 긴 작업이 조용히 멈출 수 있었다 → 작업 중에는 늘 다시 건다
            renewer.postDelayed(renew, RENEW_MS)
        }
        return START_NOT_STICKY
    }

    /// Android 15 부터 dataSync 서비스는 하루 6시간까지 → 시간이 다 되면 멈춘다 (작업은 앱이 화면에 있으면 계속)
    override fun onTimeout(startId: Int, fgsType: Int) {
        stopSelf()
    }

    private val renewer = android.os.Handler(android.os.Looper.getMainLooper())
    private val renew = object : Runnable {
        override fun run() {
            wakeLock?.let { if (running) it.acquire(RENEW_MS * 2) }
            if (running) renewer.postDelayed(this, RENEW_MS)
        }
    }

    /// 최근 앱에서 밀어 닫음: "백그라운드로 실행" 이 꺼져 있으면 작업이 멈추므로 알림을 남기고 서비스도 끝낸다 (21)
    override fun onTaskRemoved(rootIntent: Intent?) {
        if (!MainActivity.background) {
            notifyStopped(this)
            stopSelf()
        }
        super.onTaskRemoved(rootIntent)
    }

    override fun onDestroy() {
        renewer.removeCallbacks(renew)
        running = false
        wakeLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
        super.onDestroy()
    }

    companion object {
        const val CHANNEL_ID = "jobs"
        const val NOTIFICATION_ID = 1
        const val STOPPED_ID = 2

        /// 잠금을 다시 거는 간격 (1시간, 잠금은 그 두 배 동안)
        const val RENEW_MS = 60 * 60 * 1000L

        /// 앱을 닫아 작업이 멈췄다는 알림 (누르면 앱을 다시 연다)
        fun notifyStopped(context: Context) {
            val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            val open = PendingIntent.getActivity(
                context, 1, Intent(context, MainActivity::class.java),
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
            )
            val b = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                Notification.Builder(context, CHANNEL_ID)
            } else {
                @Suppress("DEPRECATION") Notification.Builder(context)
            }
            b.setSmallIcon(android.R.drawable.stat_notify_error)
                .setContentTitle("JJ_MKVMaker 작업이 멈췄습니다")
                .setContentText("앱을 닫아 진행 중이던 작업이 멈췄습니다. 닫아도 계속하려면 환경 설정에서 '백그라운드로 실행' 을 켜세요.")
                .setStyle(Notification.BigTextStyle().bigText(
                    "앱을 닫아 진행 중이던 작업 (MKV · 다운로드 · 동기화) 이 멈췄습니다. 앱을 닫아도 계속하려면 환경 설정 > Rsync > '백그라운드로 실행' 을 켜세요."))
                .setContentIntent(open)
                .setAutoCancel(true)
            nm.notify(STOPPED_ID, b.build())
        }
        const val EXTRA_TEXT = "text"
        const val EXTRA_PROGRESS = "progress"
        const val EXTRA_ICON = "icon"

        /// 서비스가 떠 있는지 (떠 있으면 알림만 바꾼다 - 백그라운드에서는 서비스를 새로 시작할 수 없음)
        @Volatile
        var running = false

        fun update(context: Context, text: String, progress: Int, icon: String) {
            val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            nm.notify(NOTIFICATION_ID, notification(context, text, progress, icon))
        }

        private fun notification(context: Context, text: String, progress: Int, icon: String): Notification {
            val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && nm.getNotificationChannel(CHANNEL_ID) == null) {
                nm.createNotificationChannel(
                    NotificationChannel(CHANNEL_ID, "작업 진행", NotificationManager.IMPORTANCE_LOW).apply {
                        description = "다운로드 · MKV 만들기 · AI 자막 · 동기화 진행 상황"
                        setShowBadge(false)
                    }
                )
            }
            val open = PendingIntent.getActivity(
                context, 0,
                // 누르면 앱의 "작업 현황" 화면으로 (지금 하는 작업 · 진행률 · 대기열 · 다운로드)
                Intent(context, MainActivity::class.java)
                    .setAction(MainActivity.ACTION_SHOW_JOBS)
                    .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
            )
            val b = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                Notification.Builder(context, CHANNEL_ID)
            } else {
                @Suppress("DEPRECATION") Notification.Builder(context)
            }
            // 다운로드 중이면 내려받기 아이콘, 그 밖 (실시간 동기화 · MKV · AI 자막) 은 좌우로 오가는 화살표
            b.setSmallIcon(if (icon == "download") android.R.drawable.stat_sys_download else R.drawable.ic_stat_sync_anim)
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
