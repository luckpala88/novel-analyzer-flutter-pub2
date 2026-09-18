import '../models/chapter.dart';
import '../utils/chinese_number.dart';

/// 章节分割工具
/// 将大段文本按"第N章"等标记拆分为章节列表
class ChapterParser {
  static const String _cnNums = '一二三四五六七八九十百千零两〇壹贰貳叁參肆伍陆陸柒捌玖拾佰仟万萬亿億';
  static const String _diChars = '第地弟帝';
  // 特殊标题（多字）— 与v318对齐
  static const String _specialPre = '序章|序幕|楔子|引子|引言|前言';
  static const String _specialPost = '终章|大结局|结局|尾声|后记|番外篇|番外|篇外|外篇';
  // 特殊标题（单字）— 需要后随空格/行尾防止误匹配
  static const String _specialPreSingle = '序|引';
  static const String _specialPostSingle = '终';

  /// 从文本解析章节
  static List<Chapter> parseChapters(String content) {
    if (content.isEmpty) return [];

    // 构建章节标题正则 — 与v318对齐，支持三类标题：
    // 1. 第N章/第N回/第N节/第N卷（数字或中文数字）
    // 2. 序章/楔子/终章/大结局/番外等多字特殊标题（后不跟CJK字符）
    // 3. 序/引/终等单字特殊标题（后跟空格或行尾）
    // v207：行首序号前缀（"2、第2章 xxx"/"12.第三章 xxx"）——爬虫txt常见
    // v281：番外带编号（"番外一/番外2/番外篇十二"）单独放行——
    // 主分支的(?![中文数字])会拒绝它，这里允许后随编号
    final titleRegex = RegExp(
      r'^[\s]*(?:\d+[、.．]?\s*)?(?:[' +
          _diChars +
          r'][' +
          _cnNums +
          r'\d]+\s*[章回节卷]'
              r'|(?:' +
          _specialPre +
          r'|' +
          _specialPost +
          r')(?![\u4e00-\u9fff])'
              r'|(?:番外篇?|篇外|外篇)[\u3000\s]*[' +
          _cnNums +
          r'\d]+'
              r'|(?:' +
          _specialPreSingle +
          r'|' +
          _specialPostSingle +
          r')(?=[\s\u3000]|$)'
              r')[\s\u3000]*(.*)?$',
      multiLine: true,
    );

    final lines = content.split('\n');

    // v281：裸数字标题文件级检测（"一 灭门"式，无第/章标记）。
    // 单行判定不可分（正文也有"一 万年后"开头行），必须全局校验：
    // 候选行=中文数字前缀+空格+短标题（无句中/句末标点），
    // 编号须构成递增序列（允许缺章跳号），且覆盖率≥60%才整文件启用；
    // 不达标一行都不拆——宁可整本一章也不把正文拆碎。
    final bareTitleRe = RegExp(
        r'^[' + _cnNums + r']{1,7}[\u3000\s]+[^\u3000\s].{0,18}$');
    final bareBadPunctRe = RegExp('[。，！？…；、]');
    final bareCandidates = <int>[]; // 行号，有序
    final bareNums = <int, int>{}; // 行号 → 编号
    for (var li = 0; li < lines.length; li++) {
      final t = lines[li].trim();
      if (t.isEmpty || !bareTitleRe.hasMatch(t)) continue;
      if (bareBadPunctRe.hasMatch(t)) continue;
      final m = RegExp('^[$_cnNums]{1,7}').firstMatch(t)!;
      final n = chineseToNumber(m.group(0)!);
      if (n <= 0 || n > 20000) continue;
      bareCandidates.add(li);
      bareNums[li] = n;
    }
    final bareAccepted = <int>{}; // 启用后视为标题的行号
    var bareLast = 0;
    for (final li in bareCandidates) {
      final n = bareNums[li]!;
      if (n == bareLast + 1) {
        bareAccepted.add(li);
        bareLast = n;
      } else if (n > bareLast + 1 && n <= bareLast + 6) {
        // 缺章跳号（≤5）：接受
        bareAccepted.add(li);
        bareLast = n;
      }
      // 乱序/回退（含正文里的数字开头行）：拒绝
    }
    final bareEnabled = bareAccepted.length >= 10 &&
        bareAccepted.length * 10 >= bareLast * 6; // 覆盖率≥60%

    final chapters = <Chapter>[];
    var currentTitle = '';
    var currentContent = StringBuffer();

    // v206：分卷书支持——每卷章节从"第一章"重新计数，标题解析出的号全书重复。
    // 编号全局唯一化：冲突时改用"已用最大号+1"，保证下游（chapterMap/
    // 续扫回查/排序/阅读器）全部按唯一递增号工作；标题原样保留原卷内叫法
    final usedNums = <int>{};
    var maxUsed = 0;
    int uniqueNumber(String title) {
      var n = getChapterNumber(title, chapters.length + 1);
      if (n <= 0 || usedNums.contains(n)) {
        n = maxUsed + 1;
      }
      usedNums.add(n);
      if (n > maxUsed) maxUsed = n;
      return n;
    }

    // v206：纯卷标题行（"第一卷"/"第2卷 XXX"型且到下个标题无正文）不生成空章
    final volumeRegex = RegExp(
      '^[\s]*[' + _diChars + '][' + _cnNums + r'\d]+\s*卷.*$',
    );

    void saveChapter() {
      if (currentTitle.isEmpty) return;
      final text = currentContent.toString().trim();
      // 空内容的卷标题行：跳过（不产生零字章节污染编号）
      if (text.isEmpty && volumeRegex.hasMatch(currentTitle)) return;
      chapters.add(
        Chapter(
          title: currentTitle,
          content: text,
          wordCount: text.length,
          number: uniqueNumber(currentTitle),
        ),
      );
    }

    // v220：换行标题支持——"第1章"单独一行、真标题在下一行（爬虫txt常见）。
    // 合并判据：下一行≤30字 且 不含句中停顿标点（，。、；等正文特征——
    // "今日宜出行，不宜作弊"有逗号却仍要合并：标题允许逗号，正文必然长句，
    // 故主判据=长度，标点只排除句号感叹号问号等句末符）
    final sentenceEndRe = RegExp(r'[。！？…；]');

    for (var li = 0; li < lines.length; li++) {
      final line = lines[li];
      final trimmed = line.trim();
      if (trimmed.isEmpty) {
        currentContent.writeln(line);
        continue;
      }

      // v281：裸数字标题（文件级启用后）也视为章节标题
      final isBareTitle = bareEnabled && bareAccepted.contains(li);
      if (isBareTitle || titleRegex.hasMatch(trimmed)) {
        saveChapter();
        currentTitle = trimmed;
        currentContent = StringBuffer();
        // v220：尝试合并下一行为标题后缀
        if (li + 1 < lines.length) {
          final next = lines[li + 1].trim();
          final isTitleLike = next.isNotEmpty &&
              next.length <= 20 &&
              !sentenceEndRe.hasMatch(next) &&
              !titleRegex.hasMatch(next) &&
              !RegExp(r'^[　\s]*[「『（"]').hasMatch(next);
          // 下一行像标题：合并（跳过它，li+1）
          if (isTitleLike) {
            currentTitle = '$trimmed $next';
            li++; // 跳过已合并的行
          }
        }
      } else {
        currentContent.writeln(line);
      }
    }

    // 保存最后一个章节
    saveChapter();

    // 如果没有匹配到任何章节，整个文本作为一个章节
    if (chapters.isEmpty && content.trim().isNotEmpty) {
      chapters.add(
        Chapter(
          title: '全文',
          content: content.trim(),
          wordCount: content.trim().length,
          number: 1,
        ),
      );
    }

    // 按章节编号排序（v206唯一化后编号本就递增，此排序为无操作保险；
    // 分卷书若不唯一化，此处会把各卷同号章交错混排——已根治）

    return chapters;
  }

  /// 将文本按章节数量分割
  /// 用于将大文件分割成小片段
  static List<List<Chapter>> splitIntoChunks(
    List<Chapter> chapters,
    int chunkSize,
  ) {
    final chunks = <List<Chapter>>[];
    for (var i = 0; i < chapters.length; i += chunkSize) {
      chunks.add(
        chapters.sublist(
          i,
          i + chunkSize > chapters.length ? chapters.length : i + chunkSize,
        ),
      );
    }
    return chunks;
  }

  /// 拼接章节文本
  static String joinChapterText(List<Chapter> chapters) {
    final buffer = StringBuffer();
    for (final ch in chapters) {
      buffer.writeln(ch.title);
      buffer.writeln(ch.content);
      buffer.writeln();
    }
    return buffer.toString();
  }

  /// 合并章节（去重）
  /// 新章节追加到已有列表，按章号去重
  static List<Chapter> mergeChapters(
    List<Chapter> existing,
    List<Chapter> newChapters,
  ) {
    final map = <int, Chapter>{};
    for (final ch in existing) {
      map[ch.number] = ch;
    }
    for (final ch in newChapters) {
      if (!map.containsKey(ch.number)) {
        map[ch.number] = ch;
      }
    }
    final result = map.values.toList();
    result.sort((a, b) => a.number.compareTo(b.number));
    return result;
  }
}
