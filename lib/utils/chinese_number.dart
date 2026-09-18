/// 中文数字解析工具

const String cnNums = '一二三四五六七八九十百千零两〇壹贰貳叁參肆伍陆陸柒捌玖拾佰仟万萬亿億';
const String diChars = '第地弟帝';

/// 提取章节编号
/// 支持: "第1章", "第三章", "第123回", "序章", "楔子", "番外", "终章" 等
int getChapterNumber(String title, [int fallbackIndex = 0]) {
  if (title.isEmpty) return fallbackIndex;

  // 前置标题: 序章/楔子/引子/前言/序幕/序/引 → 0
  // 使用正向前瞻匹配空格或行尾，防止"序列分析"等被误匹配
  final preRegex = RegExp(r'^[$cnNums]*[序楔引前言幕](?=[\s\u3000]|$)');
  if (preRegex.hasMatch(title) || _matchPrefixTitle(title)) {
    return 0;
  }

  // v281：带编号番外 "番外一/番外2/番外篇十二" → 100000+n（沉底且内部有序）
  final fanwaiMatch = RegExp('^番外篇?[\u3000\\s]*([$cnNums\\d]+)(?![\\u4e00-\\u9fff])')
      .firstMatch(title);
  if (fanwaiMatch != null) {
    final n = chineseToNumber(fanwaiMatch.group(1)!);
    if (n > 0) return 100000 + n;
  }

  // 后置标题: 终章/大结局/结局/尾声/后记/番外 → 100000
  if (_matchPostfixTitle(title)) {
    return 100000;
  }

  // 第N章 (数字)
  final diNumRegex = RegExp('[$diChars]\\s*(\\d+)\\s*[章回节卷]');
  final diMatch = diNumRegex.firstMatch(title);
  if (diMatch != null) {
    return int.parse(diMatch.group(1)!);
  }

  // 第N章 (中文数字)
  final diCnRegex = RegExp('[$diChars][$cnNums\\d]+[章回节卷]');
  final cnMatch = diCnRegex.firstMatch(title);
  if (cnMatch != null) {
    final cnStr = cnMatch.group(0)!;
    final numStr = cnStr.replaceAll(RegExp('[$diChars章回节卷]'), '');
    final n = chineseToNumber(numStr);
    if (n > 0) return n;
    // 尝试纯数字
    final pureNum = RegExp('(\\d+)').firstMatch(numStr);
    if (pureNum != null) return int.parse(pureNum.group(1)!);
  }

  // v281：裸数字标题 "一 灭门" / "十二 夜奔"（编号=前缀中文数字）
  final bareMatch = RegExp('^[$cnNums]{1,7}[\u3000\\s]+').firstMatch(title);
  if (bareMatch != null) {
    final n = chineseToNumber(title.substring(0, bareMatch.end).trim());
    if (n > 0) return n;
  }

  return fallbackIndex;
}

bool _matchPrefixTitle(String title) {
  final patterns = [
    RegExp('^序章(?![$cnNums])'),
    RegExp('^楔子(?![$cnNums])'),
    RegExp('^引子(?![$cnNums])'),
    RegExp('^前言(?![$cnNums])'),
    RegExp('^序幕(?![$cnNums])'),
    RegExp('^序(?=[\\s\\u3000]|\$)'),
    RegExp('^引(?=[\\s\\u3000]|\$)'),
  ];
  for (final p in patterns) {
    if (p.hasMatch(title)) return true;
  }
  return false;
}

bool _matchPostfixTitle(String title) {
  final patterns = [
    RegExp('^终章(?![$cnNums])'),
    RegExp('^大结局(?![$cnNums])'),
    RegExp('^结局(?![$cnNums])'),
    RegExp('^尾声(?![$cnNums])'),
    RegExp('^后记(?![$cnNums])'),
    RegExp('^番外篇?(?![$cnNums])'),
    RegExp('^番外(?=[\\s\\u3000]|\$)'),
    RegExp('^终(?=[\\s\\u3000]|\$)'),
  ];
  for (final p in patterns) {
    if (p.hasMatch(title)) return true;
  }
  return false;
}

/// 中文数字转阿拉伯数字
int chineseToNumber(String str) {
  if (str.isEmpty) return 0;

  const digitMap = <String, int>{
    '零': 0,
    '〇': 0,
    '一': 1,
    '壹': 1,
    '二': 2,
    '贰': 2,
    '貳': 2,
    '两': 2,
    '三': 3,
    '叁': 3,
    '參': 3,
    '四': 4,
    '肆': 4,
    '五': 5,
    '伍': 5,
    '六': 6,
    '陆': 6,
    '陸': 6,
    '七': 7,
    '柒': 7,
    '八': 8,
    '捌': 8,
    '九': 9,
    '玖': 9,
    '十': 10,
    '拾': 10,
    '百': 100,
    '佰': 100,
    '千': 1000,
    '仟': 1000,
    '万': 10000,
    '萬': 10000,
    '亿': 100000000,
    '億': 100000000,
  };

  // 纯数字直接返回
  final pureNum = int.tryParse(str);
  if (pureNum != null) return pureNum;

  int total = 0;
  int section = 0;
  int number = 0;

  for (int i = 0; i < str.length; i++) {
    final char = str[i];
    final val = digitMap[char];

    if (val == null) {
      // 非中文数字字符，尝试跳过
      if (int.tryParse(char) != null) {
        number = int.parse(char);
        continue;
      }
      continue;
    }

    if (val >= 10000) {
      // 万/亿: section乘以这个单位
      section = (section + number) * val;
      total += section;
      section = 0;
      number = 0;
    } else if (val >= 10) {
      // 十/百/千
      if (number == 0) number = 1; // "十" = 10, "百" = 100
      section += number * val;
      number = 0;
    } else {
      // 个位数
      number = val;
    }
  }

  return total + section + number;
}

/// 解析章节范围
/// "第1-20章" → {start: 1, end: 20}
/// "第1章-第20章" → {start: 1, end: 20}
/// "1-20" → {start: 1, end: 20}
class ChapterRange {
  final int start;
  final int end;
  ChapterRange(this.start, this.end);
}

ChapterRange parseChapterRange(String range) {
  final nums = RegExp(r'(\d+)')
      .allMatches(range)
      .map((m) => int.parse(m.group(1)!))
      .toList();
  // 阿拉伯数字齐全：'第1-20章'/'1-20'
  if (nums.length >= 2) return ChapterRange(nums.first, nums.last);
  // 无阿拉伯数字或不足一对 → 尝试中文数字：'第一章-第八章'/'第三章到第五章'
  final cnParsed = RegExp('[$diChars][$cnNums\\d]+[章回节卷]')
      .allMatches(range)
      .map((m) => getChapterNumber(m.group(0)!, 0))
      .where((n) => n > 0 && n < 100000)
      .toList();
  if (cnParsed.length >= 2) return ChapterRange(cnParsed.first, cnParsed.last);
  // 混合或单值
  if (nums.length == 1) {
    if (cnParsed.length == 1) return ChapterRange(nums.first, cnParsed.first);
    return ChapterRange(nums[0], nums[0]);
  }
  if (cnParsed.length == 1) return ChapterRange(cnParsed.first, cnParsed.first);
  return ChapterRange(0, 0);
}
