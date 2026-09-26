import 'dart:io';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';

/// 文件选择服务 — 通过MethodChannel调用Android原生文件选择器
/// 不依赖file_picker插件，减少native编译负担
class FilePickerService {
  static const MethodChannel _channel = MethodChannel(
    'com.luckpala.novel_analyzer/file_picker',
  );

  /// 选择TXT文件，返回文件路径和内容
  static Future<FilePickResult?> pickTextFile() async {
    // v366：桌面端（win等）——file_selector系统文件对话框（此前MethodChannel
    // 仅Android实现，桌面MissingPluginException被吞→点添加txt零反应）
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      try {
        // v804：加json——恢复备份要选json文件（安卓v798同款问题的桌面版）
        const typeGroup = XTypeGroup(label: '文本/数据文件', extensions: ['txt', 'json']);
        final file = await openFile(acceptedTypeGroups: [typeGroup]);
        if (file == null) return null;
        return FilePickResult(path: file.path, name: file.name);
      } catch (_) {
        return null;
      }
    }
    try {
      final result = await _channel.invokeMethod<Map>('pickTextFile');
      if (result == null) return null;
      final path = result['path'] as String?;
      if (path == null || path.isEmpty) return null;
      final name =
          result['name'] as String? ?? path.split(Platform.pathSeparator).last;
      return FilePickResult(path: path, name: name);
    } on PlatformException catch (e) {
      // 如果MethodChannel不可用（如桌面平台），返回null
      return null;
    } on MissingPluginException {
      return null;
    }
  }
}

class FilePickResult {
  final String path;
  final String name;
  FilePickResult({required this.path, required this.name});

  Future<Uint8List> readAsBytes() async {
    return await File(path).readAsBytes();
  }

  Future<String> readAsString() async {
    return await File(path).readAsString();
  }
}
