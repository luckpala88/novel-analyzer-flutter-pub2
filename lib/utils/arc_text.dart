import '../models/arc.dart';
import '../models/chapter.dart';
import 'chinese_number.dart';

/// v293：弧线精准正文抽取
/// 弧线闭合点常落在章中间——按章取文会让共享章的头/尾混进相邻弧线的剧情。
/// AI在扫描时输出boundary_text（闭合章内分界原句），本工具按原句在章内切分：
/// 锚点句（含）之前归本弧线、之后归下一弧线。锚点失配（AI引述不准/旧数据）
/// 自动退回整章归属，绝不错切。
class ArcText {
  /// 取第arcIndex条弧线的精准正文（标题+正文拼接）
  /// [debugNotes]传入时回填锚点命中情况（终端日志用）：
  /// 命中=「弧线N闭合_弧线N+1起始」共享切分点生效；失配=该边界整章兜底
  static String build(
    List<Chapter> chapters,
    List<Arc> arcs,
    int arcIndex, {
    List<String>? debugNotes,
    // v430：场景划分输入传false——忽略自身tailTrim（旧修剪是上次划分产物，
    // 重划必须基于干净输入，否则切错→修剪错→arc.text变形→污染放大只能重扫）。
    // prev.tailTrim继承不受影响（那是上一弧线的精度，属于本弧线的干净起点）
    bool applySelfTrim = true,
  }) {
    final arc = arcs[arcIndex];
    final tag = '弧线${arc.number}';
    final prevTag = arcIndex > 0 ? '弧线${arcs[arcIndex - 1].number}' : '';
    var s = arc.startChapter;
    var e = arc.endChapter;
    if (s <= 0 || e <= 0) {
      final p = parseChapterRange(arc.chapterRange);
      s = p.start;
      e = p.end;
    }
    if (s <= 0 || e <= 0 || e < s) return '';

    final prev = arcIndex > 0 ? arcs[arcIndex - 1] : null;

    final buf = StringBuffer();
    for (final ch in chapters) {
      final num = ch.number > 0 ? ch.number : chapters.indexOf(ch) + 1;
      if (num < s || num > e) continue;
      var text = '${ch.title}\n\n${ch.content}';

      // v429：纯章级物化——共享章整章两侧共有，句级切分退役（扫描层不再
      // 产锚点）。精度由场景层单向传递：
      // ①本弧线闭合章：tailTrim>=0时截尾（场景划分完成后反向修剪，
      //   最后场景end_text之后的转场杂质剪掉）
      // ②本弧线起始章=上一弧线闭合章：从prev.tailTrim起取（A剪掉的部分
      //   =B的开头，无丢失无重复）；prev未修剪时整章含杂质，A补划后自愈
      if (num == e && applySelfTrim && arc.tailTrim > 0 && arc.tailTrim < text.length) {
        text = text.substring(0, arc.tailTrim);
        debugNotes?.add('$tag闭合章尾修剪生效（第$num章，偏移${arc.tailTrim}）');
      }
      if (num == s &&
          prev != null &&
          prev.endChapter == num &&
          prev.tailTrim > 0 &&
          prev.tailTrim < text.length) {
        text = text.substring(prev.tailTrim);
        debugNotes?.add('$tag起始章继承$prevTag尾修剪（第$num章，从偏移${prev.tailTrim}起）');
      }
      buf.write('\n\n=== 第$num章 ===\n\n$text');
    }
    return buf.toString();
  }

  /// 解析切分点：
  /// v339终态语义——boundary_text=后弧线B的起始句，切分点=B首句的起点
  /// （向前吸附：跳过空白回退到前一句句末标点之后，含闭合引号）。
  /// B首句有客观特征（B线人物开口/登场），窗口大小/模型波动不再影响切点。
  /// 落库offset与吸附结果一致则直取，否则用现场吸附结果。
  /// v339：向前吸附到句末——从B首句起点idx回退跳过空白，再吞掉前面
  /// 连续的闭合引号/括号，落点=前弧线最后一句的句末标点（含闭合符）之后。
  /// 例：…"（A末句）\n\n“薇薇…（B首句）→ idx指向“，回退后落在”…放光了。"之后
  static int snapToSentenceStart(String text, int idx) {
    if (idx <= 0 || idx > text.length) return idx;
    const openers = {'“', '‘', '《', '『', '「', '（', '【', '"'};
    const closers = {'”', '』', '」', '》', '）', '】', '"', "'", '〉', '＂'};
    const finalPunc = {'。', '！', '？', '…', '；', ';', '!', '?'};
    var j = idx;
    // 吞紧贴的悬空开引号（AI引述漏前引号，弧线1末尾孤“实证）
    while (j > 0 && openers.contains(text[j - 1])) {
      j--;
    }
    // v348：B首句引述可能从逗号后的子句开始（"蓄势待发之际，突然间"实证）
    // ——回退到最近一个句末标点之后，保证A侧句子完整
    while (j > 0 && !finalPunc.contains(text[j - 1])) {
      j--;
    }
    // v418：句末标点后紧跟的闭合引号归A（…放光了。”）——正向吞。
    // 原text[j-1]反向检查永远吞不到句号后的”（回退停在句号上=j指向”），
    // 且会抵消正向吞的结果（v349随后误把j清0/上移一段，1012章炸点实证）
    while (j < text.length && closers.contains(text[j])) {
      j++;
    }
    // v349：切口优先落在段落末尾——句末切点后若仍是同段文字（B首句前
    // 还有本段的完整句子），回退到上一个换行之后，该段整体随B走
    // v418：j=0时lastIndexOf(start:-1)抛RangeError（1012章B首句近章首、
    // 前方无句末标点实证，补定位+物化双炸）——j=0直接取0，段落起点=章首
    if (j < text.length && text[j] != '\n' && text[j] != '\r') {
      final nl = j > 0 ? text.lastIndexOf('\n', j - 1) : -1;
      j = nl < 0 ? 0 : nl + 1;
    }
    return j;
  }
  static int snapToSentenceEnd(String text, int offset) {
    if (offset <= 0 || offset > text.length) return offset;
    const finalPunc = {'。', '！', '？', '!', '?', '…'};
    const closers = {
      '”', '’', '』', '」', '》', '）', '】', '"', "'", '〉', '＂',
    };
    var j = offset;
    while (j > 0 && closers.contains(text[j - 1])) {
      j--;
    }
    if (j > 0 && finalPunc.contains(text[j - 1])) {
      // v323：已在句末也要吞掉后随闭合引号（”的情况此前直接返回漏吞）
      var k = offset;
      while (k < text.length && closers.contains(text[k])) {
        k++;
      }
      return k;
    }
    var i = offset;
    while (i < text.length && !finalPunc.contains(text[i])) {
      i++;
    }
    if (i >= text.length) return offset; // 无句末标点可吸附，原样
    i++;
    while (i < text.length && closers.contains(text[i])) {
      i++;
    }
    return i;
  }

  static int snapCutEnd(String text, int offset) {
    const closers = {'”', '』', '」', '》', '）', '】', '"', "'", '〉', '＂'};
    var o = offset;
    while (o < text.length && closers.contains(text[o])) {
      o++;
    }
    return o;
  }

  /// v305：空白不敏感定位——引述跨段/空格差异容错。
  /// 在hay中找needle（忽略所有空白+引号变体归一），命中则返回原文的精确子串
  /// （跨段时含真实换行），下游切分仍可用它做精确indexOf。未命中返回null。
  /// v426：诊断探针——最近一次fuzzyLocate的最长连续公共片段长度（-1=归一全中）
  static int lastFuzzyRun = -1;

  static String? fuzzyLocate(String hay, String needle) {
    // v308：模型经中转输出JSON时标点常转半角（他喝了杯茶,咬着瓜子...）——
    // 半角映射回全角；引号/省略号/句点直接跳过（命中后取原文精确子串，匹配可宽容）
    const skipChars = {
      ' ', '\u3000', '\n', '\r', '\t',
      '\u2026', '.', '"', "'", '\u201c', '\u201d', '\u2018', '\u2019',
    };
    String normChar(String c) {
      const map = {
        ',': '，', ':': '：', ';': '；', '!': '！', '?': '？',
        '(': '（', ')': '）',
      };
      return map[c] ?? c;
    }

    final nb = StringBuffer();
    final map = <int>[]; // 归一化位置→原文位置
    for (var i = 0; i < hay.length; i++) {
      final c = hay[i];
      if (skipChars.contains(c)) continue;
      nb.write(normChar(c));
      map.add(i);
    }
    final nn = StringBuffer();
    for (var i = 0; i < needle.length; i++) {
      final c = needle[i];
      if (skipChars.contains(c)) continue;
      nn.write(normChar(c));
    }
    if (nn.isEmpty) return null;
    final nbs = nb.toString();
    final nns = nn.toString();
    final idx = nbs.indexOf(nns);
    if (idx >= 0) {
      lastFuzzyRun = -1; // 归一全中，无需LCS
      final startOrig = map[idx];
      final endOrig = map[idx + nns.length - 1];
      return hay.substring(startOrig, endOrig + 1);
    }
    // v421：归一后仍找不到=引述改字/漏字（flash语义复述实证）——
    // 取最长连续公共片段（≥8字）定位，改字几个字不影响连续片段
    // v423：门槛10→8（flash改字把10字片段压断实证，中文8字连串单章内偶然重复率极低）
    const minRun = 8;
    if (nns.length >= minRun && nbs.length >= minRun) {
      var best = 0;
      var bestH = -1;
      for (var s = 0; s + minRun <= nns.length; s++) {
        for (var h = 0; h + minRun <= nbs.length; h++) {
          var k = 0;
          while (s + k < nns.length &&
              h + k < nbs.length &&
              nns[s + k] == nbs[h + k]) {
            k++;
          }
          if (k > best) {
            best = k;
            bestH = h;
            if (best >= nns.length) break;
          }
        }
      }
      lastFuzzyRun = best; // v426：诊断透出
      if (best >= minRun && bestH >= 0) {
        return hay.substring(map[bestH], map[bestH + best - 1] + 1);
      }
    }
    return null;
  }
}

extension ArcTextAudit on ArcText {
  /// v296：完备划分体检——全量弧线对账（纯字符串运算，毫秒级）
  /// 检查：①章级覆盖（无丢失）②共享章锚点切分（无重叠）③失配清单
  static List<String> audit(List<Chapter> chapters, List<Arc> arcs) {
    final report = <String>[];
    if (arcs.isEmpty) return ['无弧线数据'];

    final covered = <int>{};
    var anchorHits = 0;
    var sharedFallback = 0;

    // 章号→章文本
    final chMap = <int, Chapter>{};
    for (var i = 0; i < chapters.length; i++) {
      final ch = chapters[i];
      chMap[ch.number > 0 ? ch.number : i + 1] = ch;
    }

    for (var i = 0; i < arcs.length; i++) {
      final arc = arcs[i];
      var s = arc.startChapter;
      var e = arc.endChapter;
      if (s <= 0 || e <= 0) {
        final p = parseChapterRange(arc.chapterRange);
        s = p.start;
        e = p.end;
      }
      if (s <= 0 || e <= 0) {
        report.add('⚠ 弧线${arc.number}范围解析失败（${arc.chapterRange}）');
        continue;
      }
      for (var n = s; n <= e; n++) {
        covered.add(n);
      }

      // v429：共享章整章共有=合法形态，句级锚点检查退役。
      // 只统计尾修剪覆盖情况
      final prev = i > 0 ? arcs[i - 1] : null;
      if (prev != null && prev.endChapter == s && prev.status == 'complete') {
        sharedFallback++;
        if (prev.tailTrim >= 0) {
          anchorHits++; // 已尾修剪（转场段已归后弧线）
        }
      }
    }

    // 覆盖对账：首弧线起点~末弧线终点之间的章必须全被覆盖
    final first = arcs.first;
    final last = arcs.last;
    final fs = first.startChapter > 0
        ? first.startChapter
        : parseChapterRange(first.chapterRange).start;
    final le = last.endChapter > 0
        ? last.endChapter
        : parseChapterRange(last.chapterRange).end;
    final missing = <int>[];
    if (fs > 0 && le > 0 && le >= fs) {
      for (var n = fs; n <= le; n++) {
        if (!covered.contains(n)) missing.add(n);
      }
    }

    report.add(
      '✅ 共享章边界：$sharedFallback 处（其中$anchorHits 处已尾修剪，转场段归后弧线）',
    );
    if (sharedFallback > 0 && anchorHits < sharedFallback) {
      report.add(
        'ℹ 未尾修剪的共享章：${sharedFallback - anchorHits} 处（对相应弧线执行场景划分后自动修剪）',
      );
    }
    if (missing.isNotEmpty) {
      report.add('❌ 内容丢失：${missing.length}章未被任何弧线覆盖');
      report.add('   · ${missing.take(20).join('、')}${missing.length > 20 ? '…' : ''}');
    } else {
      report.add('✅ 无丢失：第$fs-$le章全覆盖');
    }
    if (sharedFallback == 0 && missing.isEmpty) {
      report.add('🎉 完备划分通过：无重叠、无丢失');
    }
    return report;
  }
}
