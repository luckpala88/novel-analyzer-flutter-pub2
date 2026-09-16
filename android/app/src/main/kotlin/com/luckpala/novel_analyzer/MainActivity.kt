package com.luckpala.novel_analyzer

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.PowerManager
import android.provider.OpenableColumns
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.luckpala.novel_analyzer/file_picker"
    private val REQUEST_CODE = 1001
    private var pendingResult: MethodChannel.Result? = null
    private var storagePermResult: MethodChannel.Result? = null // v386：存储权限异步回调
    private var ttsMediaChannel: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "pickTextFile" -> {
                    pendingResult = result
                    val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                        addCategory(Intent.CATEGORY_OPENABLE)
                        type = "text/plain"
                        putExtra(Intent.EXTRA_MIME_TYPES, arrayOf("text/plain", "text/any", "application/octet-stream"))
                    }
                    startActivityForResult(intent, REQUEST_CODE)
                }
                "requestStoragePermission" -> {
                    // v386：老手机（Android<=9）公共目录写入必须运行时授权——
                    // manifest声明了WRITE_EXTERNAL_STORAGE但从未运行时申请过，
                    // 备份/导出静默失败（writeFile返回false被忽略）
                    if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.Q) {
                        result.success(true) // 10+公共Documents走SAF/直接写无需此权限
                    } else if (checkSelfPermission(android.Manifest.permission.WRITE_EXTERNAL_STORAGE) == android.content.pm.PackageManager.PERMISSION_GRANTED) {
                        result.success(true)
                    } else {
                        storagePermResult = result
                        requestPermissions(arrayOf(
                            android.Manifest.permission.WRITE_EXTERNAL_STORAGE,
                            android.Manifest.permission.READ_EXTERNAL_STORAGE
                        ), 2002)
                    }
                }
                else -> result.notImplemented()
            }
        }
        // v550：TTS媒体按键桥——蓝牙耳机播放/暂停键（AVRCP）经MediaSession回调Dart
        // v556：服务按键回调→Dart
        TTSMediaService.onMediaButton = { runOnUiThread { ttsMediaChannel?.invokeMethod("playPause", null) } }
        TTSMediaService.onMediaDebug = { msg -> runOnUiThread { ttsMediaChannel?.invokeMethod("mediaDebug", msg) } }
        ttsMediaChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.luckpala.novel_analyzer/tts_media").also { ch ->
            ch.setMethodCallHandler { call, result ->
                when (call.method) {
                    "setActive" -> {
                        val active = call.argument<Boolean>("active") ?: false
                        val playing = call.argument<Boolean>("playing") ?: false
                        // v556：会话迁移到前台媒体服务（ROM路由蓝牙按键的前提）
                        if (active) TTSMediaService.start(this, playing)
                        else TTSMediaService.stop(this)
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
        }
        // 生成任务前台服务桥：Dart调startGen/stopGen（计数器管理，最后一个任务结束才停服务）
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.luckpala/novel_analyzer/gen_service").setMethodCallHandler { call, result ->
            when (call.method) {
                "startGen" -> {
                    val msg = call.argument<String>("msg") ?: "正在生成内容..."
                    // 电池优化白名单：国产ROM对未加白的APP后台断网（连接失败）。
                    // 只弹一次（pref记录），拒绝也不影响任务本身
                    try {
                        val prefs = getSharedPreferences("app_native", Context.MODE_PRIVATE)
                        val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
                        if (!prefs.getBoolean("battery_whitelist_asked", false) &&
                            !pm.isIgnoringBatteryOptimizations(packageName)) {
                            prefs.edit().putBoolean("battery_whitelist_asked", true).apply()
                            val i = Intent(android.provider.Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                                Uri.parse("package:$packageName"))
                            i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            startActivity(i)
                        }
                    } catch (e: Exception) { /* 豁免弹窗失败不影响生成 */ }
                    try {
                        GenerationService.start(this, msg)
                        result.success(true)
                    } catch (e: Exception) {
                        result.success(false)
                    }
                }
                "stopGen" -> {
                    try {
                        GenerationService.stop(this)
                        result.success(true)
                    } catch (e: Exception) {
                        result.success(false)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Android 13+ 请求通知权限（前台服务通知显示用，拒绝也不影响服务运行）
        if (Build.VERSION.SDK_INT >= 33) {
            if (checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS)
                != android.content.pm.PackageManager.PERMISSION_GRANTED) {
                requestPermissions(arrayOf(android.Manifest.permission.POST_NOTIFICATIONS), 2001)
            }
        }
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        // v386：存储权限申请结果回传Dart
        if (requestCode == 2002) {
            storagePermResult?.success(grantResults.isNotEmpty() && grantResults[0] == android.content.pm.PackageManager.PERMISSION_GRANTED)
            storagePermResult = null
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == REQUEST_CODE) {
            if (resultCode == RESULT_OK && data?.data != null) {
                val uri = data.data!!
                val result = getFilePathFromUri(uri)
                pendingResult?.success(result)
            } else {
                pendingResult?.success(null)
            }
            pendingResult = null
        }
    }

    private fun getFilePathFromUri(uri: Uri): Map<String, String> {
        var path: String? = null
        var name: String? = null
        try {
            // 查询原文件名（用户选的是"我的文风参考.txt"，不能显示成picked_123456.txt）
            contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
                if (cursor.moveToFirst()) {
                    val idx = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    if (idx >= 0) name = cursor.getString(idx)
                }
            }
            contentResolver.openInputStream(uri)?.use { input ->
                val tempFile = File(cacheDir, "picked_${System.currentTimeMillis()}.txt")
                tempFile.outputStream().use { output -> input.copyTo(output) }
                path = tempFile.absolutePath
            }
        } catch (e: Exception) {
            path = uri.toString()
        }
        return mapOf("path" to (path ?: uri.toString()), "name" to (name ?: "unknown.txt"))
    }
}
