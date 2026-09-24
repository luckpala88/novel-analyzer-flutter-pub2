/// v702：名称映射表解析+单遍替换共用工具
/// 来源：detection_page._applyNameMap（v388解析/v411单遍扫描防链式污染）
/// 用途：①输出层换名替换 ②浏览层换名预览（改编声明/场景声明/世界书条目显示时套映射，数据不动）
class NameMap {
  NameMap._();

  /// 解析"原著名→新名"行：恒等行（左=右）跳过，按原名长度降序（长名优先防截断）
  static List<(String, String)> parse(String mapping) {
    final pairs = <(String, String)>[];
    for (final line in mapping.split('\n')) {
      final m = RegExp(
        r'^\s*([^\s→>]+?)\s*[→>]\s*([^\s（(]+)',
      ).firstMatch(line.trim());
      if (m != null && m.group(1)! != m.group(2)!) {
        pairs.add((m.group(1)!, m.group(2)!));
      }
    }
    pairs.sort((a, b) => b.$1.length.compareTo(a.$1.length));
    return pairs;
  }

  /// 单遍扫描替换——所有原名合成一个正则，原文每处只替换一次。
  /// 旧串行replaceAll会链式污染：新名里含后续行的原名时被二次替换
  static String apply(String text, List<(String, String)> pairs) {
    if (text.isEmpty || pairs.isEmpty) return text;
    final fromRe = RegExp(pairs.map((p) => RegExp.escape(p.$1)).join('|'));
    final map = {for (final p in pairs) p.$1: p.$2};
    return text.replaceAllMapped(
      fromRe,
      (m) => map[m.group(0)] ?? m.group(0)!,
    );
  }

  /// 便捷：解析映射表文本+替换；映射表空或文本空原样返回
  static String applyMapping(String text, String mapping) {
    final src = mapping.trim();
    if (src.isEmpty || text.isEmpty) return text;
    return apply(text, parse(src));
  }
}
