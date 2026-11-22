package com.luckpala.novel_analyzer

import android.app.Activity
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.Bitmap
import android.graphics.PixelFormat
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.ImageReader
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.IBinder
import android.os.Looper
import android.util.Base64

/// v1594：屏捕取榜前台服务——MediaProjection定时截帧（番茄APP字体反爬，
/// DOM/无障碍都拿不到明文，OCR读渲染像素是唯一明文通道）。
/// 用户手动翻番茄APP榜单页，本服务每5秒截一帧JPEG-base64（画面没变跳过），
/// 上限30帧；停止时Dart取走全部帧喂GLM-4V提取
class ScreenCaptureService : Service() {
    private var projection: MediaProjection? = null
    private var virtualDisplay: VirtualDisplay? = null
    private var imageReader: ImageReader? = null
    private val frames = ArrayList<String>()
    private var lastBytes: ByteArray? = null
    private var running = false
    private val mainHandler = Handler(Looper.getMainLooper())
    private var workerThread: HandlerThread? = null
    private var workerHandler: Handler? = null

    companion object {
        const val CHANNEL_ID = "screen_capture"
        const val NOTIFICATION_ID = 1002
        const val INTERVAL_MS = 5000L
        const val MAX_FRAMES = 30

        @Volatile
        var instance: ScreenCaptureService? = null
            private set

        @Synchronized
        fun start(context: Context, resultCode: Int, data: Intent): Boolean {
            return try {
                val intent = Intent(context, ScreenCaptureService::class.java)
                intent.putExtra("resultCode", resultCode)
                intent.putExtra("data", data)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(intent)
                } else {
                    context.startService(intent)
                }
                true
            } catch (e: Exception) {
                false
            }
        }

        @Synchronized
        fun stop(context: Context): ArrayList<String> {
            val frames = instance?.snapshotFrames() ?: ArrayList()
            try {
                context.stopService(Intent(context, ScreenCaptureService::class.java))
            } catch (e: Exception) { }
            return frames
        }
    }

    fun snapshotFrames(): ArrayList<String> {
        synchronized(frames) { return ArrayList(frames) }
    }

    override fun onCreate() {
        super.onCreate()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID, "屏捕取榜", NotificationManager.IMPORTANCE_LOW
            )
            channel.description = "屏捕取榜时保持录屏采集"
            getSystemService(NotificationManager::class.java)
                .createNotificationChannel(channel)
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        instance = this
        // Android 14+：必须先startForeground(type=MEDIA_PROJECTION)再getMediaProjection
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(NOTIFICATION_ID, buildNotification(),
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION)
        } else {
            startForeground(NOTIFICATION_ID, buildNotification())
        }
        val resultCode = intent?.getIntExtra("resultCode", Activity.RESULT_CANCELED)
            ?: Activity.RESULT_CANCELED
        val data: Intent? = intent?.getParcelableExtra("data")
        if (data != null && !running) {
            try {
                val mpm = getSystemService(Context.MEDIA_PROJECTION_SERVICE)
                        as MediaProjectionManager
                projection = mpm.getMediaProjection(resultCode, data)
                projection?.registerCallback(object : MediaProjection.Callback() {
                    override fun onStop() {
                        teardown()
                        stopSelf()
                    }
                }, mainHandler)
                setupCapture()
                running = true
                captureFrame() // 立即截第一帧
                scheduleNext()
            } catch (e: Exception) {
                teardown()
                stopSelf()
            }
        }
        return START_NOT_STICKY
    }

    private fun setupCapture() {
        val metrics = resources.displayMetrics
        val w = metrics.widthPixels
        val h = metrics.heightPixels
        workerThread = HandlerThread("capture_worker").also { it.start() }
        workerHandler = Handler(workerThread!!.looper)
        imageReader = ImageReader.newInstance(w, h, PixelFormat.RGBA_8888, 4)
        virtualDisplay = projection!!.createVirtualDisplay(
            "novel_rank_capture", w, h, metrics.densityDpi,
            DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR,
            imageReader!!.surface, null, workerHandler
        )
    }

    private fun scheduleNext() {
        mainHandler.postDelayed({
            if (running) {
                captureFrame()
                scheduleNext()
            }
        }, INTERVAL_MS)
    }

    private fun captureFrame() {
        val reader = imageReader ?: return
        val h = workerHandler ?: return
        h.post {
            try {
                val img = reader.acquireLatestImage() ?: return@post
                try {
                    val plane = img.planes[0]
                    val buffer = plane.buffer
                    val pixelStride = plane.pixelStride
                    val rowStride = plane.rowStride
                    val rowPadding = rowStride - pixelStride * img.width
                    val bitmap = Bitmap.createBitmap(
                        img.width + rowPadding / pixelStride, img.height,
                        Bitmap.Config.ARGB_8888
                    )
                    bitmap.copyPixelsFromBuffer(buffer)
                    val cropped = Bitmap.createBitmap(
                        bitmap, 0, 0, img.width, img.height
                    )
                    // 缩到0.55+JPEG62——单帧~120KB，GLM-4V读小字足够
                    val scaled = Bitmap.createScaledBitmap(
                        cropped,
                        (img.width * 0.55).toInt().coerceAtLeast(1),
                        (img.height * 0.55).toInt().coerceAtLeast(1),
                        true
                    )
                    val baos = java.io.ByteArrayOutputStream()
                    scaled.compress(Bitmap.CompressFormat.JPEG, 62, baos)
                    val bytes = baos.toByteArray()
                    // 画面没变（用户没滚动）跳过——省GLM-4V调用
                    if (bytes.contentEquals(lastBytes)) return@post
                    synchronized(frames) {
                        if (frames.size >= MAX_FRAMES) frames.removeAt(0)
                        frames.add(Base64.encodeToString(bytes, Base64.NO_WRAP))
                    }
                    lastBytes = bytes
                } finally {
                    img.close()
                }
            } catch (e: Exception) { /* 截帧失败跳过本轮 */ }
        }
    }

    private fun buildNotification(): Notification {
        return Notification.Builder(this, CHANNEL_ID)
            .setContentTitle("屏捕取榜运行中")
            .setContentText("正在采集屏幕帧——去番茄APP翻榜单页")
            .setSmallIcon(android.R.drawable.ic_menu_camera)
            .build()
    }

    private fun teardown() {
        running = false
        mainHandler.removeCallbacksAndMessages(null)
        try { virtualDisplay?.release() } catch (e: Exception) { }
        try { imageReader?.close() } catch (e: Exception) { }
        try { projection?.stop() } catch (e: Exception) { }
        virtualDisplay = null
        imageReader = null
        projection = null
        workerThread?.quitSafely()
        workerThread = null
        workerHandler = null
    }

    override fun onDestroy() {
        teardown()
        instance = null
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null
}
