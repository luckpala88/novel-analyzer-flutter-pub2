import 'dart:convert';

/// JSON修复工具 — 对应v318的parseResponse
/// 处理被max_tokens截断的JSON、markdown包裹、全角标点等
class JsonRepair {
  /// 解析可能不完整的JSON字符串
  /// v1194：裸数组兼容——AI格式漂移时输出[{...},...]（无键包装），实测分组
  /// 三连"解析失败"浪费3次重试+中断。截取[到]解析为List返回，null=无数组
  static List<dynamic>? parseListResponse(String text) {
    var s = text.trim();
    final firstBracket = s.indexOf('[');
    if (firstBracket < 0) return null;
    s = s.substring(firstBracket);
    final lastBracket = s.lastIndexOf(']');
    if (lastBracket < 0) return null;
    s = s.substring(0, lastBracket + 1);
    try {
      final v = jsonDecode(s);
      return v is List ? v : null;
    } catch (e) {
      return null;
    }
  }

  /// v1239：最近一次jsonDecode失败原因（含offset）——供调用方dump排障
  ///（此前所有catch静默吞掉，AI输出中段语法错误如值内未转义英文引号无从定位）
  static String? lastDecodeError;

  static Map<String, dynamic>? parseResponse(String text) {
    lastDecodeError = null;
    var s = text.trim();

    // 0. 剥离JSON前的思考文本（Gemini pro等思考型模型会把"让我分析…"
    //    之类的闲话/thinking流混在JSON前转发）——从首个{截起，{前的全丢
    final firstBrace = s.indexOf('{');
    if (firstBrace > 0) {
      s = s.substring(firstBrace);
    }

    // v1237b：开头的```json被上面首{截断剥掉后，结尾的裸```残留挂在}]后
    //（Claude整包输出=围栏包裹，Gemini不带围栏所以此前没暴露）——剥尾部裸围栏
    s = s.replaceFirst(RegExp(r'```\s*$'), '').trim();

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
      lastDecodeError = e.toString(); // v1239：透出报错含offset
      // 继续修复
    }

    // 4.5 v1240：值内裸引号修复重试——Claude爱在中文值里用"强调词"，
    // 英文双引号直接截断JSON字符串=解析炸（v1239 offset定位实证）。
    // 判定：in-string遇引号，仅当后面是结构续接（"}、,接键名/}］）才算
    // 结构闭引号，否则=内容引号替换为中文引号（交替开闭）
    final unquoted = _escapeInnerQuotes(s);
    if (unquoted != s) {
      try {
        return jsonDecode(unquoted) as Map<String, dynamic>;
      } catch (e) {
        lastDecodeError = e.toString();
        s = unquoted; // 后续截断修复基于净化后的串
      }
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

  /// v1240：修复字符串值内未转义的英文双引号
  static String _escapeInnerQuotes(String s) {
    final out = StringBuffer();
    var inStr = false;
    var esc = false;
    var alt = 0;
    for (var i = 0; i < s.length; i++) {
      final c = s[i];
      if (esc) {
        out.write(c);
        esc = false;
        continue;
      }
      if (inStr && c == '\\') {
        out.write(c);
        esc = true;
        continue;
      }
      if (c != '"') {
        out.write(c);
        continue;
      }
      if (!inStr) {
        inStr = true;
        alt = 0;
        out.write(c);
        continue;
      }
      // in-string 遇引号——看后面是否结构续接
      var j = i + 1;
      while (j < s.length &&
          (s[j] == ' ' || s[j] == '\t' || s[j] == '\n' || s[j] == '\r')) {
        j++;
      }
      final next = j < s.length ? s[j] : '';
      var k = j < s.length ? j + 1 : j;
      while (k < s.length &&
          (s[k] == ' ' || s[k] == '\t' || s[k] == '\n' || s[k] == '\r')) {
        k++;
      }
      final next2 = k < s.length ? s[k] : '';
      // 结构闭引号：后跟}]}、键名闭引号后跟:、逗号后接新键名/收尾
      // （python等价验证：病灶样本/正常输出零改动/嵌套结构四形态全过）
      final structural = next == '}' ||
          next == ']' ||
          next == ':' ||
          (next == ',' && (next2 == '"' || next2 == '}' || next2 == ']'));
      if (structural) {
        inStr = false;
        out.write(c);
      } else {
        alt++;
        out.write(alt.isOdd ? '\u201C' : '\u201D');
      }
    }
    return out.toString();
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
