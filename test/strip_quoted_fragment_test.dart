import 'package:flutter_test/flutter_test.dart';
import 'package:novel_analyzer/utils/text_cleaner.dart';

void main() {
  group('stripQuotedFragment v866引号配对剥壳', () {
    test('JSON字符串壳（英文引号成对）剥壳', () {
      final r = TextCleaner.stripQuotedFragment('"承接内容\\n第二行"');
      expect(r, '承接内容\n第二行');
    });
    test('中文引号壳成对剥壳', () {
      final r = TextCleaner.stripQuotedFragment('“承接内容”');
      expect(r, '承接内容');
    });
    test('对白开头正文（首字符中文引号）不剥对话引号', () {
      final body = '“堂堂玄晶宫太上大长老。”韦多宝冷笑。\n正文结束！”';
      final r = TextCleaner.stripQuotedFragment(body);
      expect(r.startsWith('“'), true); // 对话引号保留
    });
    test('以对话收尾的正文（尾字符中文引号）不剥', () {
      final body = '叙述开头。\n“谁还敢在东海翻起风浪！”';
      final r = TextCleaner.stripQuotedFragment(body);
      expect(r.endsWith('！”'), true);
    });
    test('正文内含多组对话引号时首尾引号不被当壳剥除', () {
      final body = '“第一句。”叙述。“第二句！”';
      final r = TextCleaner.stripQuotedFragment(body);
      expect(r, body); // 内部有引号=不是壳
    });
    test('用户实测案例：英文壳+内部中文引号对话', () {
      // AI输出整体包英文壳，内部有对话引号——壳剥一层，对话引号保留
      final body = '"黑蛟岛深处。\n“堂堂玄晶宫。”韦多宝冷笑。\n结束！”';
      final r = TextCleaner.stripQuotedFragment(body);
      expect(r.contains('“堂堂玄晶宫。”'), true);
    });
    test('尾部JSON残留逗号壳剥除', () {
      final r = TextCleaner.stripQuotedFragment('"承接内容",');
      expect(r, '承接内容');
    });
    test('英文/中文引号混用壳（AI常见错型）剥壳', () {
      final r = TextCleaner.stripQuotedFragment('"承接内容”');
      expect(r, '承接内容');
    });
    test('单边引号不动（正文以对话开头且无壳）', () {
      final body = '“对白开头。”正文继续。';
      expect(TextCleaner.stripQuotedFragment(body), body);
    });
    test('v869：stripWrapQuotes对话段（内部含引号）不剥', () {
      final body = '“回禀师尊，护岛大阵受损严重。”刘鸣快速禀报，“只是……恐需些时日休养。”';
      expect(TextCleaner.stripWrapQuotes(body), body);
    });
    test('v869：stripWrapQuotes纯壳段仍剥', () {
      expect(TextCleaner.stripWrapQuotes('“这是一段没有任何引号的普通叙述内容哦”'), '这是一段没有任何引号的普通叙述内容哦');
    });
    test('v870：孤儿英文开引号剥掉（无配对）', () {
      final t = '"韦多宝收回目光，身形化作一道清风。\n密室厚重的断龙石门轰然落下。';
      expect(TextCleaner.stripQuotedFragment(t), '韦多宝收回目光，身形化作一道清风。\n密室厚重的断龙石门轰然落下。');
    });
    test('v870：段内有配对引号=正常对白绝不动', () {
      final t = '“玄晶宫倾巢而出。”韦多宝双眼微眯。';
      expect(TextCleaner.stripQuotedFragment(t), t);
    });
    test('v874：indentParagraphs段落缩进两全角空格', () {
      expect(TextCleaner.indentParagraphs('第一段。\n\n第二段。'), '　　第一段。\n\n　　第二段。');
    });
    test('v874：indentParagraphs幂等+备注行不动', () {
      expect(TextCleaner.indentParagraphs('　　已缩进。'), '　　已缩进。');
      expect(TextCleaner.indentParagraphs('[模型：xx · v874]'), '[模型：xx · v874]');
    });
  });
}

