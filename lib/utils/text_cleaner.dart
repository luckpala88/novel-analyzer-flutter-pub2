import 'dart:convert';
import 'json_repair.dart';
/// 文本清理工具

class TextCleaner {
  /// 行首装饰emoji/符号剥离（AI自加的🎬➤⚠️等装饰前缀）
  /// 仅剥行首连续的装饰符号段+尾随空格，遇到首个中文/字母/数字即停——不伤正文
  static final RegExp _leadDecor = RegExp(
    r'^[\p{Extended_Pictographic}\u{FE0E}\u{FE0F}\u{200D}\u{20E3}'
    r'\u{2600}-\u{27BF}\u{2B00}-\u{2BFF}\u{25A0}-\u{25FF}'
    r'\u{2190}-\u{21FF}\u{2300}-\u{23FF}\u{2022}\u{25E6}\u{2043}]+\s*',
    unicode: true,
  );

  /// 清洗整段文本：逐行剥行首装饰符号（emoji是AI生成时自己加的，prompt从未教过）
  /// 用于：世界书content入库/发送AI/ST导出、创作正文入库——AI侧和导出侧零emoji负担，
  /// 浏览层图标由渲染时（contentSpans/折叠头）另行添加
  static String stripDecorativeEmoji(String content) {
    if (content.isEmpty) return content;
    return content
        .split('\n')
        .map((l) => l.replaceFirst(_leadDecor, ''))
        .join('\n');
  }

  /// 去掉结构标记行（v148重写：全变体覆盖），txt只留纯正文
  /// 用途：创作正文保存txt/二创编辑保存/导出——写回纯正文零分镜信息
  /// 覆盖变体：场景头（含章节范围）/概述行/分镜头（分镜N·分镜头N·【分镜N】·带空格·全半角冒号）/
  /// 维度行（中文名/英文名/中英标签/带emoji前缀）/叙事分镜小标题/模型备注/孤立[]行
  /// v545：自由创作模式——只剔除分镜结构行（分镜N头+维度行），保留场景头/
  /// 概述行/正文段。与stripShotHeaders的区别：场景头和概述是场景导航与
  /// 叙事目标，自由创作也需要它们，只省略分镜结构
  /// v597：只删分镜结构行（分镜N头），维度行不动——精简模式下自由创作用
  static String stripShotHeads(String content) {
    final out = <String>[];
    for (final line in content.split('\n')) {
      final t = line.trim();
      if (t.contains('分镜') &&
          RegExp(
            r'^[^\u4e00-\u9fa5\n]*#*\s*[\[【]?分[镜景](头)?\s*\d*\s*[\]】]?\s*[：:]?',
          ).hasMatch(t)) {
        continue;
      }
      out.add(line);
    }
    return out.join('\n');
  }

  /// v609：分镜顺序修复——AI把分镜1正文写在结构块前（先正文后分镜）时，
  /// 把首个分镜头之前的孤立正文段挪到首个分镜块结构行之后。
  /// 结构块边界：分镜头行起，连续维度行（行首"标签："），遇正文段停
  static String fixShotBodyOrder(String content) {
    final shotRe = RegExp(
      r'^[^\u4e00-\u9fa5\n]*#*\s*[\[【]?分[镜景](头)?\s*\d*\s*[\]】]?\s*[：:｜]?',
      multiLine: true,
    );
    final m = shotRe.firstMatch(content);
    if (m == null || m.start == 0) return content; // 无分镜/分镜已在最前
    final dimRe = RegExp(
      r'^[^\u4e00-\u9fa5\n\n]*(投放信息|作者意图|意图|转场手法|篇幅|文笔节奏|功能抽象|焦点|镜头类型|视角|叙述|语感|笔墨|语感锚|笔墨配额|叙事功能)(\s*[(（][A-Za-z /]+[)）])?\s*[：:]',
    );
    final lines = content.split('\n');
    var headEnd = -1; // 首个分镜头所在行
    var acc = 0;
    for (var i = 0; i < lines.length; i++) {
      final m2 = shotRe.firstMatch(lines[i] + '\n');
      if (m2 != null && m2.start == 0 && lines[i].trim().contains('分镜')) {
        headEnd = i;
        break;
      }
      acc += lines[i].length + 1;
      if (acc > m.start) break;
    }
    if (headEnd < 0) return content;
    var structEnd = headEnd + 1;
    while (structEnd < lines.length) {
      final t = lines[structEnd].trim();
      if (t.isEmpty || !dimRe.hasMatch(t)) break;
      structEnd++;
    }
    // 分镜头之前的行：结构头（场景头/章节/概述）留守，正文段收集
    final keep = <String>[];
    final move = <String>[];
    for (var i = 0; i < headEnd; i++) {
      final t = lines[i].trim();
      final isStructHead =
          RegExp(r'^[^\u4e00-\u9fa5\n]*#*\s*场[景面]\s*\d+\s*[：:]').hasMatch(t) ||
          RegExp(r'^第[一二三四五六七八九十百千0-9]+章').hasMatch(t) ||
          RegExp(r'^[^\u4e00-\u9fa5\n]*#*\s*(弧线\s*\d+\s*)?概[述说]\s*[：:]').hasMatch(t);
      if (t.isEmpty) continue;
      isStructHead ? keep.add(lines[i]) : move.add(lines[i]);
    }
    if (move.isEmpty) return content;
    final out = <String>[
      ...keep,
      ...lines.sublist(headEnd, structEnd),
      ...move,
      ...lines.sublist(structEnd),
    ];
    return out.join('\n');
  }

  static String stripShotStructOnly(String content) {
    final dimRe = RegExp(
      r'^[^\u4e00-\u9fa5\n]*(投放信息|作者意图|意图|转场手法|篇幅|文笔节奏|语感锚|语感|笔墨配额|笔墨|功能抽象|叙事功能|镜头类型|镜头子类型|视角|焦点|叙述)(\s*[(（][A-Za-z /]+[)）])?\s*[：:]',
    );
    final out = <String>[];
    for (final line in content.split('\n')) {
      final t = line.trim();
      // 分镜头全变体
      if (t.contains('分镜') &&
          RegExp(
            r'^[^\u4e00-\u9fa5\n]*#*\s*[\[【]?分[镜景](头)?\s*\d*\s*[\]】]?\s*[：:]?',
          ).hasMatch(t)) {
        continue;
      }
      // 维度行（含污染守卫同款容忍：先过维度正则）
      if (dimRe.hasMatch(t)) continue;
      out.add(line);
    }
    // 收敛连续空行（结构行删除后的残阵）
    final sb = StringBuffer();
    var blank = 0;
    for (final l in out) {
      if (l.trim().isEmpty) {
        blank++;
        if (blank > 1) continue;
      } else {
        blank = 0;
      }
      sb.writeln(l);
    }
    return sb.toString().trim();
  }

  static String stripShotHeaders(String content, {bool keepModelNote = false}) {
    // v275：分镜块去重+JSON残渣剥除前置（整场景重复退化的输出/存量
    // 坏数据——txt导出全路径过一遍）
    content = dedupeShotBlocks(content);
    // 前置剥离行首装饰emoji（AI自加，旧数据兜底）
    content = stripDecorativeEmoji(content);
    final lines = content.split('\n');
    // v266：块级粘连检测先行——粘连块（块内无正文段）的超长维度值
    // =藏身正文，行号映射后面判定用（兼容模式"摘要+正文"同行的确定性
    /// 判定，补v262行级阈值的60-200字盲区——用户实测正文提纯被剔除）
    final glued = detectGluedBody(content);
    final pure = <String>[];
    for (var idx = 0; idx < lines.length; idx++) {
      final line = lines[idx];
      final t = line.trim();
      // 场景头（## 场景N：xxx（第X-Y章））
      if (RegExp(r'^[^\u4e00-\u9fa5\n]*#*\s*场[景面]\s*\d+\s*[：:]').hasMatch(t))
        continue;
      // 概述行（场景概述/弧线N概述——AI照搬条目开头，纯正文不要）
      if (RegExp(r'^[^\u4e00-\u9fa5\n]*#*\s*(弧线\s*\d+\s*)?概[述说]\s*[：:]')
          .hasMatch(t))
        continue;
      // 分镜头全变体（【分镜1】/分镜1：/分镜头 2：/分镜N，冒号可选）
      if (t.contains('分镜') &&
          RegExp(
            r'^[^\u4e00-\u9fa5\n]*#*\s*[\[【]?分[镜景](头)?\s*\d*\s*[\]】]?\s*[：:]?',
          ).hasMatch(t))
        continue;
      // 叙事分镜小标题
      if (RegExp(r'^📷\s*叙事分镜').hasMatch(t)) continue;
      if (!keepModelNote && RegExp(r'^\[模型[：:].*\]').hasMatch(t)) {
        continue; // v609：keepModelNote=true保留备注行（二创显示层不丢备注）
      }
      // v259：维度行防污染双分支——值≤60字=真维度行整行丢；值超长=
      // 正文以维度值身份藏身（伪JSON污染形态：功能抽象：+几千字正文挤
      // 同一行），剥标签留正文（丢标签救正文——渲染/导出兜底）
      final dimCn = RegExp(
        r'^[^\u4e00-\u9fa5\n]*\s*(投放信息|投放|作者意图|意图|转场手法|转场|篇幅|文笔节奏|功能抽象|焦点|镜头类型|视角|镜头子类型|叙述|语感|笔墨|语感锚|笔墨配额|叙事功能)(\s*[(（][A-Za-z /]+[)）])?\s*(/\s*[A-Za-z /]+)?\s*[：:]\s*(.*)$',
      ).firstMatch(t);
      final dimEn = RegExp(
        r'^[^\u4e00-\u9fa5\n]*(Focus|Shot Type|POV|Info|Intent|Transition|Length|Prose Style|Abstract|Voice|Ink)\s*[：:]\s*(.*)$',
        caseSensitive: false,
      ).firstMatch(t);
      final dimM = dimCn ?? dimEn;
      if (dimM != null) {
        // 值捕获组：中文正则group(4)（1标签/2括号/3斜杠/4值），英文group(2)
        final val = (dimCn?.group(4) ?? dimEn?.group(2) ?? '').trim();
        if (!dimValuePolluted(val) && !glued.containsKey(idx)) {
          continue; // 真维度行（v262行级+v266块级双判定）
        }
        // 污染/粘连行：剥标签留正文
        pure.add(val);
        continue;
      }
      // 孤立方括号行（镜头标记残留 [中景]）
      if (RegExp(r'^\[.+\]\s*$').hasMatch(t)) continue;
      pure.add(line);
    }
    while (pure.isNotEmpty && pure.first.trim().isEmpty) {
      pure.removeAt(0);
    }
    while (pure.isNotEmpty && pure.last.trim().isEmpty) {
      pure.removeLast();
    }
    return pure.join('\n');
  }
  // ==================== v254：AI输出格式归一化（创作/世界书共用）====================
  // 从adapt_page迁移+共享化：json/兼容混合输出（字面\n、JSON包装、伪JSON
  // 键值对、花括号连排、pair链、游离引号）统一归一为规范多行文本。
  // 创作正文入库此前只剥emoji没走归一化（用户实测23735字混合输出直接进正文）

  /// v592：精简分镜维度——剥离易搬运维度行（投放信息/转场/文笔节奏/语感锚/笔墨），
  /// 保留 焦点/镜头类型/视角/作者意图/篇幅/功能抽象
  static String stripShotDims(String text) {
    final re = RegExp(
      r'^[^\u4e00-\u9fa5\n]*(投放信息|转场手法|文笔节奏|语感锚|语感|笔墨配额|笔墨)(\s*[(（][A-Za-z /]+[)）])?(\s*/\s*[A-Za-z /]+)?\s*[：:].*$',
      multiLine: true,
    );
    var out = text.replaceAll(re, '');
    // v606：inline单行格式（分镜1｜焦点：…｜投放信息：…）——维度埋在行中间，
    // 行首正则剥不到；按全角｜切段剥掉精简5维度段（语感值内ASCII|不误切）
    final segRe = RegExp(
      r'｜\s*(投放信息|转场手法|文笔节奏|语感锚|语感|笔墨配额|笔墨)(\s*[(（][A-Za-z /]+[)）])?\s*[：:].*?(?=｜|$)',
    );
    out = out.replaceAll(segRe, '');
    return out.replaceAll(RegExp('\n{3,}'), '\n\n');
  }

  static const kLabelMap = {
    '焦点': '焦点(Focus)', '镜头类型': '镜头类型(Shot Type)', '视角': '视角(POV)',
    '投放信息': '投放信息(Info)', '作者意图': '作者意图(Intent)', '转场手法': '转场手法(Transition)',
    '篇幅': '篇幅(Length)', '文笔节奏': '文笔节奏(Prose Style)', '语感': '语感(Voice)',
    '笔墨': '笔墨(Ink)', '功能抽象': '功能抽象(Abstract)',
    '转场': '转场手法(Transition)', '镜头': '镜头类型(Shot Type)', '意图': '作者意图(Intent)',
    '节奏': '文笔节奏(Prose Style)', '投放': '投放信息(Info)', '信息': '投放信息(Info)',
  };

  /// v254→v256重构：按API模式分支归一化（用户架构裁决：不要用一个方法
  /// 混合兼容两种格式——formatMode是已知配置，猜格式是错误设计。此前
  /// 串联容错的实测教训：兼容模式纯正文偶然以{开头会被误解码丢内容、
  /// json模式的坏JSON被文本容错掩盖失去重试信号）
  /// · jsonMode=true：严格JSON路径——剥围栏→jsonDecode取content
  ///   （\n自动真换行）→截断JSON栈式修复→仍解不出返回原文（上层
  ///   hasError判定触发重试，不掩盖）
  /// · jsonMode=false：纯文本容错路径——字面\n解码/pair链拆解/花括号
  ///   连排拆块/键值对规范化（中转假流式残留）+重复结构行去重+续行合并
  /// 两路共用后续：stripDecorativeEmoji+stripShotHeaders在调用侧
  /// v369b：字面\n解码（AI在纯文本正文里写\n字面量——伪JSON剥壳路径
  /// 有解码但纯文本路径漏网=正文显示字面\n）。真换行不受影响
  static String decodeLiteralNewlines(String t) {
    if (!t.contains(r'\n')) return t;
    return t.replaceAll(r'\n', '\n').replaceAll(r'\"', '"');
  }

  static String normalizeAiOutput(String raw, {bool jsonMode = false}) {
    final out = jsonMode
        ? _normalizeJsonOutput(raw)
        : _normalizeTextOutput(raw);
    // v413：嵌入式JSON壳清除（两种模式统一过一遍）
    return stripJsonShells(out);
  }

  /// v413：嵌入式JSON壳清除——AI把某段正文包在{"content":"..."}里输出，
  /// 且因正文内含未转义英文引号导致jsonDecode失败时，壳原样嵌进拼接正文
  /// （截图实证：{ 换行 "content":"王二叔道：…" }嵌在两段正文之间）。
  /// 确定性正则提取：匹配完整的content壳→解转义→还原纯正文。
  /// 残余符号行（数组壳/对象壳解码失败留下的{ ] "独占行）一并清除
  static String stripJsonShells(String t) {
    // v551：键名泛化——改写链AI用rewritten_text等键包壳（截图实证），不只content
    final re = RegExp(
      r'\{\s*"(?:content|rewritten_\w+|text|body|正文|output|result)"\s*:\s*"((?:[^"\\]|\\.)*)"\s*\}',
      dotAll: true,
    );
    t = t.replaceAllMapped(re, (m) {
      var c = m.group(1)!;
      c = c
          .replaceAll(r'\n', '\n')
          .replaceAll(r'\"', '"')
          .replaceAll(r'\\', '\\');
      return c;
    });
    // 独占符号行清除 + 行尾ASCII引号残渣（正文引号是全角“”，行尾直引号必是壳残留）
    final kept = <String>[];
    for (final l in t.split('\n')) {
      final s = l.trim();
      if (s.isNotEmpty &&
          s.length <= 3 &&
          RegExp(r'^[\[\]{}",\s]+$').hasMatch(s)) {
        continue; // 数组壳/对象壳解码失败留下的独占符号行
      }
      // v510b：半JSON化键值行（中转剥外壳残留的裸键）——overview是
      // 元数据整行丢；content键剥前缀保正文（值跨行，后续行自然保留）
      if (RegExp(r'^"overview"\s*[:：]').hasMatch(s)) continue;
      // v551：rewritten_text等改写壳键——剥前缀保正文（值跨行自然保留）
      final contentKey = RegExp(
        r'^"(?:content|rewritten_\w+|text|body|正文|output|result)"\s*[:：]\s*(.*)$',
      ).firstMatch(s);
      if (contentKey != null) {
        kept.add(contentKey.group(1) ?? '');
        continue;
      }
      if (RegExp(r'[\u4e00-\u9fa5。！？…”]').hasMatch(s)) {
        kept.add(l.replaceFirst(RegExp(r'[\]"}]+,?\s*$'), ''));
      } else {
        kept.add(l);
      }
    }
    t = kept.join('\n');
    return t;
  }

  /// v263：JSON content字段提取（共享）。jsonDecode已成功的Map里，
  /// 字段名漂移容错（AI/中转偶发用text/body/正文等键名）——不是猜
  /// 格式（JSON已是合法解析结果），是字段名归一。单键Map且值为长
  /// 字符串=正文本体（无从判断键名时的确定性兜底）
  static String? extractJsonContent(Map json) {
    for (final k in ['content', 'text', 'body', '正文', 'output', 'result']) {
      final v = json[k];
      if (v is String && v.trim().isNotEmpty) return v.trim();
    }
    if (json.length == 1) {
      final v = json.values.first;
      if (v is String && v.trim().length > 50) return v.trim();
    }
    return null;
  }

  /// v266：块级粘连检测（兼容模式"摘要+正文"粘连的确定性判定）。
  /// 背景：兼容模式AI偶把正文直接接在维度值后同一行（"功能抽象：引入
  /// 冲突现场+正文流"），行级内容特征（长度/句读）在60-200字中间地带
  /// 与真维度值（语感例句同为叙事文本）原理上无法区分——v262阈值留下
  /// 的盲区=用户实测"正文提纯被剔除"。换块级位置信号（不依赖内容猜测）：
  /// 正常创作分镜块必有独立正文段；粘连块正文藏在维度行里=块内无正文
  /// 段。返回：行号→粘连正文（该行应剥标签留正文而非整行丢弃）
  static Map<int, String> detectGluedBody(String content) {
    final result = <int, String>{};
    final lines = content.split('\n');
    final shotHeadRe = RegExp(
      r'^[^\u4e00-\u9fa5\n]*#*[\[（(【]?分[镜景](头)?\s*\d*\s*[\]）)】]?\s*[：:]?',
    );
    final dimRe = RegExp(
      r'^[^\u4e00-\u9fa5\n]*\s*(投放信息|投放|作者意图|意图|转场手法|转场|篇幅|文笔节奏|功能抽象|焦点|镜头类型|视角|镜头子类型|叙述|语感|笔墨|语感锚|笔墨配额|叙事功能)(\s*[(（][A-Za-z /]+[)）])?\s*(/\s*[A-Za-z /]+)?\s*[：:]\s*(.*)$',
    );
    // 按分镜头行分块（行号列表）
    final blocks = <List<int>>[];
    var current = <int>[];
    for (var i = 0; i < lines.length; i++) {
      final t = lines[i].trim();
      if (shotHeadRe.hasMatch(t) && t.contains('分镜')) {
        if (current.isNotEmpty) blocks.add(current);
        current = <int>[i];
      } else {
        current.add(i);
      }
    }
    if (current.isNotEmpty) blocks.add(current);
    // 块级判定：无正文段的块=粘连嫌疑，其超60字维度值=藏身正文
    for (final block in blocks) {
      final dimLines = <int, String>{};
      var bodyLines = 0;
      for (final i in block) {
        final t = lines[i].trim();
        if (t.isEmpty) continue;
        final dm = dimRe.firstMatch(t);
        if (i == block.first && shotHeadRe.hasMatch(t)) continue; // 分镜头行
        if (dm != null) {
          dimLines[i] = (dm.group(4) ?? '').trim();
          continue;
        }
        bodyLines++;
      }
      if (bodyLines == 0) {
        for (final e in dimLines.entries) {
          if (e.value.length > 60) result[e.key] = e.value;
        }
      }
    }
    return result;
  }

  /// v273：剥外层包裹引号（共享——AI把整段正文当字符串值输出的包装
  /// 形态："废料堆中心，……"）。确定性变换：首尾是同一对引号（半角"或
  /// 全角""''）且剥后非空才剥；只剥一层（最外层包装），内部引号（对白
  /// 引号）不动。pairs校验防半个引号误剥
      static String stripWrapQuotes(String t) {
    var x = t.trim();
    if (x.length < 2) return x;
    final first = x[0];
    final last = x[x.length - 1];
    final samePair =
        (first == '"' && last == '"') ||
        (first == '\u201c' && last == '\u201d') ||
        (first == '\u2018' && last == '\u2019') ||
        (first == "'" && last == "'");
    // v609b：混合壳先判——半角"+全角“…+全角”+半角"（四端齐才剥，
    // 只剥外层半角壳，内层全角对白引号保留）
    if (x.length >= 4 &&
        first == '"' &&
        x[1] == '\u201c' &&
        x[x.length - 2] == '\u201d' &&
        last == '"') {
      return x.substring(1, x.length - 1).trim(); // 只剥两端半角壳，内层全角引号保留
    }
    if (samePair) {
      final inner = x.substring(1, x.length - 1).trim();
      // 剥后为空=整段就是俩引号（空正文包装），不返回空串
      if (inner.isNotEmpty) x = inner;
    }
    return x;
  }

  /// v276：拆"维度行…分镜N："粘连行（写回吃换行bug的历史数据修复）。
  /// 粘连形态=维度行值末尾直接拼着下一分镜的头（"功能抽象:…aaa分镜2:"）
  /// ——行锚定的分镜切分正则找不到边界→块合并错位→粘连复制进正文/再
  /// 被当维度行收集回写=循环放大。确定性判定：维度标签行+行尾恰好是
  /// 分镜N：头（数字必须存在）→拆两行。正常正文值不以"分镜N："收尾，
  /// 误伤面极小
  static String repairGluedShotEntry(String t) {
    if (!t.contains('分镜') && !t.contains('分景')) return t;
    final re = RegExp(
      r'^[^\u4e00-\u9fa5\n]*\s*(投放信息|投放|作者意图|意图|转场手法|转场|篇幅|文笔节奏|功能抽象|焦点|镜头类型|视角|镜头子类型|叙述|语感|笔墨|语感锚|笔墨配额|叙事功能)(\s*[(（][A-Za-z /]+[)）])?\s*[：:].*?[\[【]?分[镜景](头)?\s*\d+\s*[\]】]?\s*[：:]?\s*$',
    );
    final out = <String>[];
    for (final l in t.split('\n')) {
      final m = re.firstMatch(l.trim());
      if (m != null) {
        // 拆分点：最后一个"分镜N："头的起点
        final head = RegExp(r'[\[【]?分[镜景](头)?\s*\d+\s*[\]】]?\s*[：:]?\s*$').firstMatch(l.trim());
        if (head != null) {
          out.add(l.trim().substring(0, head.start).trim());
          out.add(head.group(0)!.trim());
          continue;
        }
      }
      out.add(l);
    }
    return out.join('\n');
  }

  /// v275：分镜块去重+中部JSON残渣清理。  /// v275：分镜块去重+中部JSON残渣清理。实测形态（用户40k字附件分
  /// 析）：整场景AI长输出重复退化——分镜1-8带正文→9-73纯结构→从分镜6
  /// 自我复读一遍6-73纯结构（世界书徽章73镜=条目干净，重复在输出自身）
  /// +两处"}伪JSON闭合碎片（salvage只剥头尾，中部残留）。确定性判定：
  /// 场景内分镜编号唯一，同编号块只保留首次出现（首次=带正文的那个）
  static String dedupeShotBlocks(String content) {
    // v276：粘连行拆分前置（写回吃换行的历史数据——全路径治）
    content = repairGluedShotEntry(content);
    if (!content.contains('分镜')) return _stripJsonDebris(content);
    final re = RegExp(
      r'^[^\u4e00-\u9fa5\n]*[\[（(【]*#*[^\S\n]*[\[（(【]?分[镜景](头)?[^\S\n]*\d+',
      multiLine: true,
    );
    final ms = re.allMatches(content).toList();
    if (ms.isEmpty) return _stripJsonDebris(content);
    final seen = <int>{};
    final out = StringBuffer();
    out.write(content.substring(0, ms.first.start));
    for (var i = 0; i < ms.length; i++) {
      final end = i + 1 < ms.length ? ms[i + 1].start : content.length;
      final block = content.substring(ms[i].start, end);
      final num = int.tryParse(
        RegExp(r'分[镜景](头)?[^\S\n]*(\d+)').firstMatch(block)?.group(2) ?? '',
      );
      if (num != null && seen.contains(num)) continue; // 重复块丢弃
      if (num != null) seen.add(num);
      out.write(block);
    }
    return _stripJsonDebris(out.toString());
  }

  /// v275：中部JSON残渣剥除——纯残渣行（"/}/[组合）删除+行尾"}碎片剥掉
  /// （伪JSON闭合在中部的残留。中文正文几乎不可能以半角"结尾+}收尾，
  /// quote+brace组合作为剥除锚点保守安全）
  static String _stripJsonDebris(String t) {
    final lines = t.split('\n');
    final out = <String>[];
    for (var l in lines) {
      final trim = l.trim();
      // 纯残渣行（引号/花括号/方括号/空白组合）
      if (trim.isNotEmpty && RegExp(r'^["\u201d}\[\s]+$').hasMatch(trim)) {
        continue;
      }
      // 行尾"}或"片段（quote+brace组合锚点）
      out.add(l.replaceFirst(RegExp(r'["\u201d]+\}[\s]*$'), ''));
    }
    return out.join('\n');
  }

  /// v262：维度值污染判定（共享——正文以维度值身份藏身的形态）。真维度
  /// 值（焦点/功能抽象/语感锚带例句/笔墨配额）实际≤150字且几乎无句读；
  /// 藏身正文=成段长文本。60字阈值过紧误伤真维度值（语感例句/笔墨配额
  /// 超60字被剥标签进正文=用户实测"功能抽象内容反过来混入正文"）
  static bool dimValuePolluted(String value) {
    final v = value.trim();
    if (v.isEmpty) return false;
    if (v.length > 200) return true;
    return RegExp(r'[。！？!?]').allMatches(v).length >= 3;
  }

  /// v259：json模式格式坏判定（上层重试用）——解开成功（jsonDecode或
  /// JsonRepair取到content）=好。解不开且含JSON痕迹（前导{或字面\n）
  /// =坏（伪JSON——中转剥response_format时模型无约束输出，jsonDecode必败
  /// 且JsonRepair只补闭合不加键引号救不了）。解不开但零JSON痕迹（纯正文
  /// 中转剥壳后模型老实输出）=不算坏（内容干净可直接用）
  static bool jsonFormatBad(String raw) {
    final t = raw.trim();
    var x = t;
    final fence = RegExp(r'^```[a-zA-Z]*\n?([\s\S]*?)\n?```$').firstMatch(x);
    if (fence != null) x = fence.group(1)!.trim();
    try {
      final json = jsonDecode(x);
      if (json is List) {
        // v271：数组壳可解（单元素/字符串数组）=好
        return !(json.length == 1 && json.first is String) &&
            !(json.isNotEmpty && json.every((e) => e is String));
      }
      if (json is Map) {
        if (extractJsonContent(json) != null) return false;
        return false; // 合法JSON但无可用字段（正常错误路径，走通用容错）
      }
      return false;
    } catch (_) {
      final json = JsonRepair.parseResponse(x);
      if (json != null && extractJsonContent(json) != null) return false;
    }
    // 解不出：看JSON痕迹（{或[开头/字面\n/尾}或]）
    return x.startsWith('{') ||
        x.startsWith('[') ||
        x.contains(r'\n') ||
        x.endsWith('}') ||
        x.endsWith(']');
  }

  /// v259：伪JSON剥壳抢救（重试后仍坏时的最后兜底+存量坏数据渲染）——
  /// 确定性变换非内容猜测：剥前导{尾}残壳+字面\n解码。已生成内容不丢弃
  /// （2.4万字生成等一分多钟，报错全丢成本太高），抢救入库+日志警告
  static String salvagePseudoJson(String raw) {
    var t = raw.trim();
    final fence = RegExp(r'^```[a-zA-Z]*\n?([\s\S]*?)\n?```$').firstMatch(t);
    if (fence != null) t = fence.group(1)!.trim();
    // 剥伪JSON壳：前导{（连带"content":"前缀残片）+尾}
    if (t.startsWith('{')) {
      t = t.replaceFirst(RegExp(r'^\s*\{\s*'), '');
      // 剥content键前缀残片（{"content":"… → …，键无引号变体{content:等）
      final lead = RegExp(
        r'^["\u201c]?content["\u201d]?\s*[：:]\s*["\u201c]?',
      ).firstMatch(t);
      if (lead != null) t = t.substring(lead.end);
    }
    if (t.endsWith('}')) t = t.replaceFirst(RegExp(r'["\u201d]?\s*\}\s*$'), '');
    // 字面\n解码（\n/\"转义残留→真换行/引号）
    if (t.contains(r'\n')) {
      t = t.replaceAll(r'\n', '\n').replaceAll(r'\"', '"');
    }
    return t.trim();
  }

  /// json模式：严格JSON解析（零文本兜底）
  static String _normalizeJsonOutput(String raw) {
    var t = raw.trim();
    // markdown围栏（中转加壳，json模式也会遇到）
    final fence = RegExp(r'^```[a-zA-Z]*\n?([\s\S]*?)\n?```$').firstMatch(t);
    if (fence != null) t = fence.group(1)!.trim();
    try {
      final json = jsonDecode(t);
      // v271：数组壳（AI输出["正文"]——jsonDecode成功但非Map，此前
      // 提取器不认→原文带["..."入库=用户实测'正文多一对方括号和引号'）
      if (json is List) {
        if (json.length == 1 && json.first is String) {
          return (json.first as String).trim();
        }
        // 多元素数组：join换行（碎片数组）。List<dynamic>不能强转
        // List<String>（cast抛错被catch吃掉返回原文）——用whereType
        final strs = json.whereType<String>().toList();
        if (strs.length == json.length && strs.isNotEmpty) {
          return strs.join('\n').trim();
        }
      }
      if (json is Map) {
        final c = extractJsonContent(json);
        if (c != null) return c;
      }
    } catch (_) {
      // 截断JSON→JsonRepair栈式修复再试
      final json = JsonRepair.parseResponse(t);
      if (json != null) {
        final c = extractJsonContent(json);
        if (c != null) return c;
      }
    }
    return t; // 解不出=格式坏，返回原文交上层判定（hasError触发重试）
  }

  /// v408：兼容模式JSON壳兜底——AI漂移输出{"content":"正文"}或["正文"]
  /// （json壳在text配置下原样入库=用户截图实证）。确定性判定：文本整体
  /// （剥围栏后）是合法JSON且能提取出长文本content才替换，解不出不动原文
  static String _normalizeTextOutput(String raw) {
    var t = raw.trim();
    final fence = RegExp(r'^```[a-zA-Z]*\n?([\s\S]*?)\n?```$').firstMatch(t);
    if (fence != null) t = fence.group(1)!.trim();
    if (t.startsWith('{') || t.startsWith('[')) {
      try {
        final json = jsonDecode(t);
        if (json is Map) {
          final c = extractJsonContent(json);
          if (c != null && c.length > 200) return c;
        }
        if (json is List) {
          if (json.length == 1 && json.first is String) {
            final c = (json.first as String).trim();
            if (c.length > 200) return c;
          }
          final strs = json.whereType<String>().toList();
          if (strs.length == json.length && strs.isNotEmpty) {
            final joined = strs.join('\n');
            if (joined.length > 200) return joined;
          }
        }
      } catch (_) {}
    }
    return _normalizeTextOutputInner(t);
  }

  static String _normalizeTextOutputInner(String raw) {
    var t = raw.trim();
    // markdown围栏（兼容模式下AI给纯文本加```壳也是常见漂移——换模型
    // 时高发。整段包裹才剥，正文中的行内代码不动）
    final fenceClosed = RegExp(
      r'^```[a-zA-Z]*\s*\n?([\s\S]*?)\n?```\s*$',
    ).firstMatch(t);
    if (fenceClosed != null) {
      t = fenceClosed.group(1)!.trim();
    } else {
      final fenceOpen = RegExp(r'^```[a-zA-Z]*\s*\n?').firstMatch(t);
      if (fenceOpen != null) t = t.substring(fenceOpen.end).trim();
      t = t.replaceFirst(RegExp(r'\n?```\s*$'), '').trim();
    }
    // 字面\n转义（中转假流式把JSON转义残留吐进纯文本——唯一允许的
    // "JSON痕迹"清理，因为它是纯文本损坏形态不是JSON包装）
    if (t.contains(r'\n')) {
      t = t.replaceAll(r'\n', '\n').replaceAll(r'\"', '"');
    }
    // 前导说明文字（换模型高发："好的，以下是正文：…"一行+空行+正文）
    // 剥离条件（三重收紧防误伤正文对白行）：①整行以冒号结尾②含AI说明话
    // 术特征词（好的/以下/根据/这是/为您）③后面隔空行接正文（对白行
    // 后面直接跟引号内容不隔行）
    final fn = t.indexOf('\n');
    if (fn > 0) {
      final fl = t.substring(0, fn).trim();
      final rest = t.substring(fn + 1).trimLeft();
      final isJunkLead =
          fl.isNotEmpty &&
          RegExp(r'[：:]\s*$').hasMatch(fl) &&
          RegExp(r'好的|以下|根据|这是|为您|如上|上述').hasMatch(fl) &&
          rest.isNotEmpty &&
          rest.startsWith('\n') == false &&
          RegExp(r'^[“"\u201c]').hasMatch(rest) == false;
      if (isJunkLead) {
        t = rest;
      }
    }
    // pair链/花括号连排拆解
    t = _splitPairChainLines(t);
    t = _preSplitBracedShots(t);
    t = _canonicalBareLabels(t);
    // 连续重复结构行去重
    t = _dedupeConsecutiveStructLines(t);
    // 维度续行合并
    t = _mergeDimContinuationLines(t);
    return t;
  }

  /// v255：连续重复结构行去重——同结构行（场景头/概述/分镜头/章节标题
  /// 等整行相同）紧邻出现（中间可隔空行）只保留首个
  static String _dedupeConsecutiveStructLines(String t) {
    final lines = t.split('\n');
    final out = <String>[];
    for (var i = 0; i < lines.length; i++) {
      final cur = lines[i].trim();
      // 向后看：跳过空行找下一非空行
      var j = i + 1;
      while (j < lines.length && lines[j].trim().isEmpty) {
        j++;
      }
      if (j < lines.length &&
          cur.isNotEmpty &&
          lines[j].trim() == cur &&
          _isStructLineForDedupe(cur)) {
        continue; // 跳过重复行（保留后面的——它会继续被判定）
      }
      out.add(lines[i]);
    }
    return out.join('\n');
  }

  static bool _isStructLineForDedupe(String t) {
    return RegExp(
      r'^[^\u4e00-\u9fa5\n]*(场景\s*\d+\s*[：:]|概[述说]\s*[：:]|分[镜头]?\s*\d+\s*[：:]|第.{1,8}章)',
    ).hasMatch(t);
  }

  /// v255：维度行续行合并——维度值的跨行后半句（AI把"作者意图：建立性格
  /// 反差\n通过主角视角定调"换行输出）渲染层会漏成裸正文行。判定信号=
  /// 前后文结构：维度行后紧跟**单行**裸行且裸行后又是维度/分镜头/场景头
  /// →裸行是维度续行并入；裸行后还是裸行→正文段（设计格式：维度行块后
  /// 是多行正文）。不用句末标点判定（实测续行前的维度行常无标点）
  static String _mergeDimContinuationLines(String t) {
    final lines = t.split('\n');
    final dimRe = RegExp(
      r'^[^\u4e00-\u9fa5\n]*\s*(投放信息|投放|作者意图|意图|转场手法|转场|篇幅|文笔节奏|功能抽象|焦点|镜头类型|视角|镜头子类型|语感|笔墨|语感锚|笔墨配额|叙事功能)(\s*[(（][A-Za-z /]+[)）])?\s*(/\s*[A-Za-z /]+)?\s*[：:].*',
    );
    final structRe = RegExp(
      r'^[^\u4e00-\u9fa5\n]*(场景\s*\d+\s*[：:]|分[镜头]头?\s*\d*\s*[：:]?|概[述说]\s*[：:]|第.{1,8}章|【|##)',
    );
    final out = <String>[];
    for (var i = 0; i < lines.length; i++) {
      final cur = lines[i].trim();
      out.add(lines[i]);
      if (cur.isEmpty) continue;
      // 当前是维度行→看后续：单裸行后接结构/维度行=续行合并
      if (!dimRe.hasMatch(cur)) continue;
      var j = i + 1;
      while (j < lines.length && lines[j].trim().isEmpty) {
        j++;
      }
      if (j >= lines.length || j != i + 1) continue; // 空行隔开≠续行
      final bare = lines[j].trim();
      if (bare.isEmpty || dimRe.hasMatch(bare) || structRe.hasMatch(bare)) {
        continue;
      }
      // v261/v262：污染形态裸行=正文段非维度续行（防创作正文被并进维度
      // 行——单段正文+紧邻下一结构行的形态恰好命中续行合并条件）。合并
      // 后超200字会被dimValuePolluted下游自纠（剥标签回正文），双保险
      if (dimValuePolluted(bare)) continue;
      // 裸行后再看一行：结构/维度行=续行；裸行=正文段
      var k = j + 1;
      while (k < lines.length && lines[k].trim().isEmpty) {
        k++;
      }
      if (k < lines.length &&
          (dimRe.hasMatch(lines[k].trim()) ||
              structRe.hasMatch(lines[k].trim()))) {
        // 续行：并回当前维度行
        out[out.length - 1] = '$cur$bare';
        i = j; // 跳过裸行
      }
    }
    return out.join('\n');
  }

  /// v246：残缺pair链行拆解（分镜1": "焦点(Focus)": "值）
  static String _splitPairChainLines(String t) {
    final out = <String>[];
    for (final raw in t.split('\n')) {
      final l = raw.trim();
      if (l.contains('": "') || l.contains('"："')) {
        final pieces = l
            .split(RegExp(r'"\s*[：:]\s*"'))
            .map((p) => p.trim())
            .where((p) => p.isNotEmpty)
            .toList();
        if (pieces.length >= 3) {
          final val = _stripWrapQ(pieces.sublist(2).join('：'));
          out.add('${_stripWrapQ(pieces.first)}：');
          out.add('${_stripWrapQ(pieces[1])}：$val');
          continue;
        } else if (pieces.length == 2) {
          out.add('${_stripWrapQ(pieces[0])}：${_stripWrapQ(pieces[1])}');
          continue;
        }
      }
      out.add(raw);
    }
    return out.join('\n');
  }

  /// v243：【分镜N】{逗号连排}拆块
  static String _preSplitBracedShots(String t) {
    var out = t.replaceAllMapped(
      RegExp(r'【\s*分[镜头]?\s*(\d+)\s*[】\]]'),
      (m) => '分镜${m.group(1)}：\n',
    );
    out = out.replaceAllMapped(RegExp(r'\{([^{}]*)\}'), (m) {
      final inner = m.group(1)!.trim();
      if (inner.isEmpty ||
          !RegExp('焦点|镜头|视角|投放|意图|转场|篇幅|文笔|语感|笔墨|功能抽象|概述')
              .hasMatch(inner)) {
        return m.group(0)!;
      }
      final parts = inner.split(
        RegExp(r',\s*(?=[\u4e00-\u9fa5A-Za-z()（）/、|\s]{1,28}[：:])'),
      );
      return parts.where((p) => p.trim().isNotEmpty).join('\n');
    });
    return out;
  }

  /// v247：裸键值对行规范化+行尾游离引号剥离
  static String _canonicalBareLabels(String t) {
    final out = <String>[];
    for (final raw in t.split('\n')) {
      var l = raw.trim();
      final m1 = RegExp(r'["\u201c\u201d]+\s*[,，]\s*$').firstMatch(l);
      if (m1 != null) l = l.substring(0, m1.start).trimRight();
      if ('"'.allMatches(l).length.isOdd && l.endsWith('"')) {
        l = l.substring(0, l.length - 1).trimRight();
      }
      final fw = '\u201c'.allMatches(l).length + '\u201d'.allMatches(l).length;
      if (fw.isOdd && (l.endsWith('\u201c') || l.endsWith('\u201d'))) {
        l = l.substring(0, l.length - 1).trimRight();
      }
      if (l.isEmpty) continue;
      final m = RegExp(
        r'^\s*([\u4e00-\u9fa5A-Za-z]+(?:\s*(?:\([^)]*\)|/\s*[A-Za-z ]+))?)\s*([：:])\s*(.+)$',
      ).firstMatch(l);
      if (m == null) {
        out.add(l);
        continue;
      }
      var key = m.group(1)!.trim();
      key = key.replaceFirst(RegExp(r'/\s*[A-Za-z ]+$'), '');
      final bare = key.replaceFirst(RegExp(r'\s*\([^)]*\)$'), '');
      final val = m.group(3)!.trim();
      final vm = RegExp(r'^分\s*镜\s*(\d+)\s*[：:]?\s*(.*)$').firstMatch(val);
      if (bare == '分镜' && vm != null) {
        out.add('分镜${vm.group(1)}：');
        if (vm.group(2)!.trim().isNotEmpty) out.add(vm.group(2)!.trim());
        continue;
      }
      final canonical = kLabelMap[bare];
      if (canonical != null) {
        out.add('$canonical：$val');
      } else {
        out.add('$key${m.group(2)}$val');
      }
    }
    return out.join('\n');
  }

  /// v241：剥包裹引号（v273改用共享stripWrapQuotes逻辑但保留
  /// 正则版行为——pair链场景需要贪婪剥多引号）
  static String _stripWrapQ(String s) {
    var t = s.trim();
    final lead = RegExp(r'^["\u201c\u201d]+');
    if (!lead.hasMatch(t)) return t;
    t = t.replaceFirst(lead, '');
    t = t.replaceFirst(RegExp(r'["\u201c\u201d]+[,，]?$'), '');
    return t.trim();
  }

}
