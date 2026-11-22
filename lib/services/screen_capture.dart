import 'package:flutter/services.dart';

/// v1594：屏捕取榜通道客户端——MediaProjection录屏授权+前台服务定时截帧，
/// 帧喂GLM-4V提取（番茄APP字体反爬，OCR读像素是唯一明文通道）
class ScreenCapture {
  static const _ch = MethodChannel('com.luckpala/screen_capture');

  /// 弹录屏授权→用户同意→启动前台服务。false=拒绝或启动失败
  static Future<bool> startCapture() async {
    try {
      return await _ch.invokeMethod('startCapture') == true;
    } catch (e) {
      return false;
    }
  }

  /// 跳转系统APP（番茄=com.dragon.read）。false=未安装
  static Future<bool> openApp(String pkg) async {
    try {
      return await _ch.invokeMethod('openApp', {'pkg': pkg}) == true;
    } catch (e) {
      return false;
    }
  }

  /// {running: bool, frames: int}
  static Future<Map> status() async {
    try {
      return Map.from(await _ch.invokeMethod('status') ?? {});
    } catch (e) {
      return {'running': false, 'frames': 0};
    }
  }

  /// 停止采集并取走全部帧（base64 JPEG）
  static Future<List<String>> stopCapture() async {
    try {
      final list = await _ch.invokeMethod('stopCapture') as List?;
      return list?.cast<String>() ?? [];
    } catch (e) {
      return [];
    }
  }
}
