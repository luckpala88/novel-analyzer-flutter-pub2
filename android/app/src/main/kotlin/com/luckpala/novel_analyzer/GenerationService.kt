package com.luckpala.novel_analyzer

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.net.wifi.WifiManager
import android.os.Build
import android.os.IBinder
import android.os.PowerManager

/// 生成任务前台服务：息屏/后台时保持CPU运行+WiFi不断
/// 照抄HTML版v170 GenerationService方案：startForeground通知栏+WakeLock+WiFiLock+计数器
class GenerationService : Service() {
    private var wakeLock: PowerManager.WakeLock? = null
    private var wifiLock: WifiManager.WifiLock? = null

    companion object {
        const val CHANNEL_ID = "generation_service"
        const val NOTIFICATION_ID = 1001
        /// 计数器：多个生成任务并存时，最后一个结束才停服务
        private var activeCount = 0

        @Synchronized
        fun start(context: Context, msg: String) {
            activeCount++
            val intent = Intent(context, GenerationService::class.java)
            intent.putExtra("msg", msg)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        @Synchronized
        fun stop(context: Context) {
            activeCount = maxOf(0, activeCount - 1)
            if (activeCount == 0) {
                context.stopService(Intent(context, GenerationService::class.java))
            }
        }
    }

    override fun onCreate() {
        super.onCreate()
        // 前台通知（Android 13+需要POST_NOTIFICATIONS权限，没授权也不影响服务本身）
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID, "生成任务", NotificationManager.IMPORTANCE_LOW
            )
            channel.description = "批量生成时保持后台运行"
            val manager = getSystemService(NotificationManager::class.java)
            manager.createNotificationChannel(channel)
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val msg = intent?.getStringExtra("msg") ?: "正在生成内容，保持运行中..."
        val notification: Notification
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val builder = Notification.Builder(this, CHANNEL_ID)
                .setContentTitle("网文拆解器")
                .setContentText(msg)
                .setSmallIcon(android.R.drawable.stat_sys_download)
                .setOngoing(true)
            notification = builder.build()
        } else {
            @Suppress("DEPRECATION")
            notification = Notification.Builder(this)
                .setContentTitle("网文拆解器")
                .setContentText(msg)
                .setSmallIcon(android.R.drawable.stat_sys_download)
                .setOngoing(true)
                .build()
        }
        startForeground(NOTIFICATION_ID, notification)

        // WakeLock：CPU不睡（PARTIALWakeLock息屏仍运行）
        if (wakeLock == null) {
            val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
            wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "novel_analyzer:gen")
            wakeLock?.acquire(4 * 60 * 60 * 1000L) // 最长4小时防泄漏
        }
        // WiFiLock：WiFi高性能模式不断流
        if (wifiLock == null) {
            val wm = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
            @Suppress("DEPRECATION")
            wifiLock = wm.createWifiLock(WifiManager.WIFI_MODE_FULL_HIGH_PERF, "novel_analyzer:wifi")
            wifiLock?.acquire()
        }
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        wakeLock?.let { if (it.isHeld) it.release() }
        wifiLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
        wifiLock = null
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null
}
