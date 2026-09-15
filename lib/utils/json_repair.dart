import 'dart:convert';

/// JSON修复工具 — 对应v318的parseResponse
/// 处理被max_tokens截断的JSON、markdown包裹、全角标点等
class JsonRepair {
  /// 解析可能不完整的JSON字符串
  static Map<String, dynamic>? parseResponse(String text) {
    var s = text.trim();

    // 0. 剥离JSON前的思考文本（Gemini pro等思考型模型会把"让我分析…"
    //    之类的闲话/thinking流混在JSON前转发）——从首个{截起，{前的全丢
    final firstBrace = s.indexOf('{');
    if (firstBrace > 0) {
      s = s.substring(firstBrace);
    }

    // 1. 去除markdown代码块
    final closedMd = RegExp(r'```(?:json)?\s*([\s\S]*?)```').firstMatch(s);
    if (closedMd != null) {
      s = closedMd.group(1)!.trim();
    } else {
      // 未闭合的markdown块: ```json {... (没有结尾```)
      final openMd = RegExp(r'^```(?:json)?\s*').firstMatch(s);
      if (openMd != null) {
        s = s.substring(openMd.group(0)!.length).trim();
      }
    }

    // 2. 全角标点替换
    s = s.replaceAll('\uFF0C', ',').replaceAll('：', ':');

    // 3. 修复JSON字符串值中的字面控制字符
    // 某些模型(如Gemini)在JSON字符串值中输出原始\n而非\\n
    s = _fixControlCharsInStrings(s);

    // 4. 尝试直接解析
    try {
      return jsonDecode(s) as Map<String, dynamic>;
    } catch (e) {
      // 继续修复
    }

    // 4. 提取最外层JSON对象
    final objMatch = RegExp(r'\{[\s\S]*\}').firstMatch(s);
    if (objMatch != null) {
      try {
        return jsonDecode(objMatch.group(0)!) as Map<String, dynamic>;
      } catch (e) {
        // 继续修复
      }
    }

    // 5. 栈式修复截断的JSON
    final fixed = _fixTruncatedJson(s);
    if (fixed != null) {
      try {
        return jsonDecode(fixed) as Map<String, dynamic>;
      } catch (e) {
        // 尝试去掉最后一个不完整字段后重新修复
      }
    }

    // 6. 去掉最后一个不完整字段后重新修复
    final trimmed = _trimLastIncompleteField(s);
    if (trimmed != null) {
      final fixed2 = _fixTruncatedJson(trimmed);
      if (fixed2 != null) {
        try {
          return jsonDecode(fixed2) as Map<String, dynamic>;
        } catch (e) {}
      }
    }

    return null;
  }

  /// 修复JSON字符串值中的字面控制字符
  /// 某些模型(如Gemini)在JSON字符串值中输出原始\n \r \t而非\\n \\r \\t
  static String _fixControlCharsInStrings(String s) {
    final out = StringBuffer();
    bool inStr = false;
    bool esc = false;
    for (var i = 0; i < s.length; i++) {
      final c = s[i];
      if (esc) {
        out.write(c);
        esc = false;
        continue;
      }
      if (c == '\\') {
        out.write(c);
        esc = true;
        continue;
      }
      if (c == '"') {
        inStr = !inStr;
        out.write(c);
        continue;
      }
      if (inStr) {
        if (c == '\n') {
          out.write('\\n');
          continue;
        }
        if (c == '\r') {
          out.write('\\r');
          continue;
        }
        if (c == '\t') {
          out.write('\\t');
          continue;
        }
      }
      out.write(c);
    }
    return out.toString();
  }

  /// 栈式修复截断的JSON
  static String? _fixTruncatedJson(String s) {
    bool inStr = false;
    bool esc = false;
    final stack = <String>[];

    for (var i = 0; i < s.length; i++) {
      final c = s[i];
      if (esc) {
        esc = false;
        continue;
      }
      if (c == '\\') {
        esc = true;
        continue;
      }
      if (c == '"') {
        inStr = !inStr;
        continue;
      }
      if (inStr) continue;
      if (c == '{' || c == '[') {
        stack.add(c);
      } else if (c == '}' || c == ']') {
        // 弹出匹配的开括号
        for (var k = stack.length - 1; k >= 0; k--) {
          if (stack[k] == (c == '}' ? '{' : '[')) {
            stack.removeRange(k, stack.length);
            break;
          }
        }
      }
    }

    // 构建闭合字符串
    var closeStr = '';
    // 如果在字符串内，先闭合字符串
    if (inStr) {
      // 如果截断在反斜杠后，去掉它
      if (esc) {
        s = s.substring(0, s.length - 1);
      }
      closeStr += '"';
    }
    // 从内到外闭合栈中剩余的括号
    for (var j = stack.length - 1; j >= 0; j--) {
      closeStr += (stack[j] == '{' ? '}' : ']');
    }

    if (closeStr.isNotEmpty) {
      return s + closeStr;
    }
    return null;
  }

  /// 去掉最后一个不完整的字段
  static String? _trimLastIncompleteField(String s) {
    var lastComma = -1;
    bool inStr = false;
    bool esc = false;
    int depth = 0;

    for (var i = 0; i < s.length; i++) {
      final c = s[i];
      if (esc) {
        esc = false;
        continue;
      }
      if (c == '\\') {
        esc = true;
        continue;
      }
      if (c == '"') {
        inStr = !inStr;
        continue;
      }
      if (inStr) continue;
      if (c == '{' || c == '[') {
        depth++;
      } else if (c == '}' || c == ']') {
        depth--;
      } else if (c == ',' && depth <= 1) {
        lastComma = i;
      }
    }

    if (lastComma >= 0) {
      return s.substring(0, lastComma);
    }
    return null;
  }
}
