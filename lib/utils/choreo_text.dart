/// v1211：scene_choreos 串的段落提取与剥壳工具
/// 数据源：analysis.metadata['scene_choreos'] 整串（"场景N:…；场景M:…"）
/// 展示：分散到弧线页各场景概述卡下（v1211用户裁决——不再集中大块展示）
class ChoreoText {
  /// 从整串提取场景No的目的段（场景号1-based，与_ensureSceneChoreo同匹配口径）
  static String extract(String all, int sceneNo) {
    if (all.trim().isEmpty || sceneNo <= 0) return '';
    final m = RegExp('场景\\s*$sceneNo\\s*[:：]([\\s\\S]*?)(?=场景\\s*\\d+\\s*[:：]|\$)')
        .firstMatch(all);
    var seg = (m?.group(1) ?? '').trim();
    seg = seg.replaceAll(RegExp(r'[；;]+$'), ''); // 段尾分隔符
    return strip(seg);
  }

  /// v1211：剥存量壳——v1211前AI输出"场景N:有目的（…）/场景M:水文（…）"，
  /// v1211起直接写目的内容或"无"；旧数据展示时在渲染层剥壳兼容
  static String strip(String s) {
    var t = s.trim();
    if (t.isEmpty) return '';
    if (t.startsWith('水文')) return '无';
    final m = RegExp(r'^有目的[（(](.*)[)）]$').firstMatch(t);
    if (m != null) return m.group(1)?.trim() ?? t;
    return t;
  }
}
