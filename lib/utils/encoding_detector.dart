import 'dart:typed_data';
import 'dart:convert';

/// 编码检测工具
/// 中文TXT文件可能是UTF-8/GBK/GB2312编码
class EncodingDetector {
  /// 检测编码并解码
  static String decode(Uint8List bytes) {
    // 1. 查BOM
    if (bytes.length >= 3 &&
        bytes[0] == 0xEF &&
        bytes[1] == 0xBB &&
        bytes[2] == 0xBF) {
      // UTF-8 BOM
      return utf8.decode(bytes.sublist(3));
    }
    if (bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE) {
      // UTF-16 LE
      return _decodeUtf16le(bytes.sublist(2));
    }
    if (bytes.length >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF) {
      // UTF-16 BE
      return _decodeUtf16be(bytes.sublist(2));
    }

    // 2. 尝试UTF-8
    try {
      final decoded = utf8.decode(bytes, allowMalformed: true);
      final replacementCount = '\uFFFD'.allMatches(decoded).length;
      if (replacementCount < bytes.length ~/ 100) {
        // 替换字符少于1%，认为是UTF-8
        return decoded;
      }
    } catch (e) {
      // 继续尝试GBK
    }

    // 3. 尝试GBK
    try {
      final decoded = _decodeGbk(bytes);
      final replacementCount = '\uFFFD'.allMatches(decoded).length;
      // 比较UTF-8和GBK的替换字符数量，取较少的
      final utf8Decoded = utf8.decode(bytes, allowMalformed: true);
      final utf8Replacements = '\uFFFD'.allMatches(utf8Decoded).length;
      if (replacementCount < utf8Replacements) {
        return decoded;
      }
      return utf8Decoded;
    } catch (e) {
      return utf8.decode(bytes, allowMalformed: true);
    }
  }

  /// GBK解码
  /// Flutter没有内置GBK解码器，需要第三方包
  /// 这里用简化的映射或fallback
  static String _decodeGbk(Uint8List bytes) {
    // Flutter默认不支持GBK，使用latin1 fallback
    // 实际项目中需要引入 gbk_codec 或类似包
    try {
      return utf8.decode(bytes, allowMalformed: true);
    } catch (e) {
      return String.fromCharCodes(bytes);
    }
  }

  static String _decodeUtf16le(Uint8List bytes) {
    final buffer = StringBuffer();
    for (int i = 0; i + 1 < bytes.length; i += 2) {
      final code = bytes[i] | (bytes[i + 1] << 8);
      buffer.writeCharCode(code);
    }
    return buffer.toString();
  }

  static String _decodeUtf16be(Uint8List bytes) {
    final buffer = StringBuffer();
    for (int i = 0; i + 1 < bytes.length; i += 2) {
      final code = (bytes[i] << 8) | bytes[i + 1];
      buffer.writeCharCode(code);
    }
    return buffer.toString();
  }
}
