package com.luckpala.novel_analyzer

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.os.Build
import android.os.IBinder
import android.support.v4.media.session.MediaSessionCompat
import android.support.v4.media.session.PlaybackStateCompat
import androidx.core.app.NotificationCompat
import androidx.media.MediaBrowserServiceCompat

/// v556：TTS朗读媒体前台服务——蓝牙耳机媒体按键的完整形态
/// （探针实证：仅MediaSession+音频焦点ROM不路由按键，必须前台服务+
/// 媒体通知=音乐APP同款形态，系统才认它是"当前媒体应用"）
class TTSMediaService : MediaBrowserServiceCompat() {
    private var session: MediaSessionCompat? = null
    private var focusReq: AudioFocusRequest? = null
    private var playing = true

    companion object {
        const val CHANNEL_ID = "tts_media_service"
        const val NOTIFICATION_ID = 1002
        const val ACTION_START = "com.luckpala.novel_analyzer.tts_media.START"
        const val ACTION_UPDATE = "com.luckpala.novel_analyzer.tts_media.UPDATE"
        const val ACTION_TOGGLE = "com.luckpala.novel_analyzer.tts_media.TOGGLE"
        const val ACTION_STOP = "com.luckpala.novel_analyzer.tts_media.STOP"
        /// 按键回调（MainActivity注册→invokeMethod到Dart）
        @Volatile
        var onMediaButton: (() -> Unit)? = null
        var onMediaAction: ((String) -> Unit)? = null // v558：语义化动作play/pause/toggle
        @Volatile
        var onMediaDebug: ((String) -> Unit)? = null

        fun start(context: Context, playing: Boolean) = send(context, ACTION_START, playing)
        fun update(context: Context, playing: Boolean) = send(context, ACTION_UPDATE, playing)
        fun stop(context: Context) {
            val intent = Intent(context, TTSMediaService::class.java).setAction(ACTION_STOP)
            context.startService(intent)
        }

        private fun send(context: Context, action: String, playing: Boolean) {
            val intent = Intent(context, TTSMediaService::class.java)
                .setAction(action)
                .putExtra("playing", playing)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }
    }

    override fun onCreate() {
        super.onCreate()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID, "电子书朗读", NotificationManager.IMPORTANCE_LOW
            )
            channel.description = "朗读时保持媒体控制"
            channel.setShowBadge(false)
            getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                abandonFocus()
                session?.isActive = false
                session?.release()
                session = null
                stopForeground(true)
                stopSelf()
                return START_NOT_STICKY
            }
            ACTION_TOGGLE -> {
                // 通知栏按钮：切换状态并通知Flutter
                playing = !playing
                onMediaButton?.invoke()
            }
            else -> {
                playing = intent?.getBooleanExtra("playing", true) ?: true
            }
        }
        ensureSession()
        updatePlaybackState(playing)
        requestFocus()
        startForegroundWithNotification()
        return START_NOT_STICKY
    }

    private fun ensureSession() {
        if (session != null) return
        session = MediaSessionCompat(this, "NovelAnalyzerTTS")
        // v557：MediaBrowserService注册（系统蓝牙栈按此识别媒体应用）
        setSessionToken(session!!.sessionToken)
        session = session!!.apply {
            setCallback(object : MediaSessionCompat.Callback() {
                override fun onMediaButtonEvent(mediaButtonEvent: Intent): Boolean {
                    val ev = mediaButtonEvent.getParcelableExtra<android.view.KeyEvent>(Intent.EXTRA_KEY_EVENT)
                        ?: return false
                    when (ev.keyCode) {
                        android.view.KeyEvent.KEYCODE_MEDIA_PLAY -> {
                            onMediaAction?.invoke("play")
                            onMediaDebug?.invoke("收到PLAY(播放)")
                            return true
                        }
                        android.view.KeyEvent.KEYCODE_MEDIA_PAUSE -> {
                            onMediaAction?.invoke("pause")
                            onMediaDebug?.invoke("收到PAUSE(暂停)")
                            return true
                        }
                        android.view.KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE,
                        android.view.KeyEvent.KEYCODE_HEADSETHOOK -> {
                            onMediaAction?.invoke("toggle")
                            onMediaDebug?.invoke("收到PLAY_PAUSE(切换)")
                            return true
                        }
                    }
                    return super.onMediaButtonEvent(mediaButtonEvent)
                }
                override fun onPlay() { onMediaAction?.invoke("play"); onMediaDebug?.invoke("onPlay(播放)") }
                override fun onPause() { onMediaAction?.invoke("pause"); onMediaDebug?.invoke("onPause(暂停)") }
            })
        }
        session?.isActive = true
    }

    private fun updatePlaybackState(playing: Boolean) {
        val ms = session ?: return
        this.playing = playing
        val state = if (playing) PlaybackStateCompat.STATE_PLAYING else PlaybackStateCompat.STATE_PAUSED
        ms.setPlaybackState(
            PlaybackStateCompat.Builder()
                .setActions(PlaybackStateCompat.ACTION_PLAY or PlaybackStateCompat.ACTION_PAUSE or PlaybackStateCompat.ACTION_PLAY_PAUSE)
                .setState(state, 0L, 0f)
                .build()
        )
    }

    private fun requestFocus() {
        try {
            val am = getSystemService(Context.AUDIO_SERVICE) as AudioManager
            if (Build.VERSION.SDK_INT >= 26) {
                if (focusReq == null) {
                    focusReq = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
                        .setAudioAttributes(
                            AudioAttributes.Builder()
                                .setUsage(AudioAttributes.USAGE_MEDIA)
                                .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                                .build())
                        .build()
                }
                am.requestAudioFocus(focusReq!!)
            } else {
                @Suppress("DEPRECATION")
                am.requestAudioFocus(null, AudioManager.STREAM_MUSIC, AudioManager.AUDIOFOCUS_GAIN)
            }
        } catch (e: Exception) { }
    }

    private fun abandonFocus() {
        try {
            val am = getSystemService(Context.AUDIO_SERVICE) as AudioManager
            if (Build.VERSION.SDK_INT >= 26) focusReq?.let { am.abandonAudioFocusRequest(it) }
        } catch (e: Exception) { }
    }

    private fun startForegroundWithNotification() {
        val toggleIntent = Intent(this, TTSMediaService::class.java).setAction(ACTION_TOGGLE)
        val togglePi = PendingIntent.getService(
            this, 0, toggleIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val toggleLabel = if (playing) "暂停" else "继续"
        val toggleIcon = if (playing) android.R.drawable.ic_media_pause else android.R.drawable.ic_media_play
        val style = androidx.media.app.NotificationCompat.MediaStyle()
            .setMediaSession(session?.sessionToken)
            .setShowActionsInCompactView(0)
        val notification = NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("电子书朗读中")
            .setContentText(if (playing) "正在朗读…耳机按键可暂停/继续" else "已暂停…耳机按键可继续")
            .setSmallIcon(android.R.drawable.stat_sys_headset)
            .setOngoing(true)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .addAction(toggleIcon, toggleLabel, togglePi)
            .setStyle(style)
            .build()
        if (Build.VERSION.SDK_INT >= 29) {
            startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    // v557：MediaBrowserServiceCompat必须实现——蓝牙/系统浏览器查询用，
    // 不暴露任何可浏览内容
    override fun onGetRoot(
        clientPackageName: String,
        clientUid: Int,
        rootHints: android.os.Bundle?
    ): BrowserRoot? = BrowserRoot("root", null)

    override fun onLoadChildren(
        parentId: String,
        result: Result<MutableList<android.media.browse.MediaBrowser.MediaItem>>
    ) {
        result.sendResult(mutableListOf())
    }

    override fun onBind(intent: Intent?): IBinder? = null
}
