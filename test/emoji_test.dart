import 'package:flutter_test/flutter_test.dart';
import 'package:novel_analyzer/utils/text_cleaner.dart';

void main() {
  test('stripDecorativeEmoji', () {
    expect(TextCleaner.stripDecorativeEmoji('🎬 场景1：坊市纠纷脱身(第1章)'), '场景1：坊市纠纷脱身(第1章)');
    expect(TextCleaner.stripDecorativeEmoji('➤ 分镜1：吐槽 [心理(独白)]'), '分镜1：吐槽 [心理(独白)]');
    expect(TextCleaner.stripDecorativeEmoji('⚠️ 绝对重要伏笔'), '绝对重要伏笔');
    expect(TextCleaner.stripDecorativeEmoji('🕊️ 关键词：陆志星'), '关键词：陆志星');
    expect(TextCleaner.stripDecorativeEmoji('场景2：裸格式不受影响'), '场景2：裸格式不受影响');
    expect(TextCleaner.stripDecorativeEmoji('正文段落，普通小说内容。'), '正文段落，普通小说内容。');
    expect(TextCleaner.stripDecorativeEmoji('第1章 开篇'), '第1章 开篇');
    expect(TextCleaner.stripDecorativeEmoji('投放：没有前缀的字段行'), '投放：没有前缀的字段行');
    expect(TextCleaner.stripDecorativeEmoji('● 圆点装饰'), '圆点装饰');
    expect(TextCleaner.stripDecorativeEmoji('➡️➤ 双重装饰'), '双重装饰');
    expect(TextCleaner.stripDecorativeEmoji('👤 人物：陆志星'), '人物：陆志星');
    expect(TextCleaner.stripDecorativeEmoji('⚔️ 矛盾冲突：xxx'), '矛盾冲突：xxx');
    expect(TextCleaner.stripDecorativeEmoji('a🎬abc'), 'a🎬abc'); // 非行首不动
    expect(TextCleaner.stripDecorativeEmoji(''), '');
    // 多行整体
    expect(TextCleaner.stripDecorativeEmoji('🎬 场景1：xxx\n➤ 分镜1：yyy\n正文保持。'), '场景1：xxx\n分镜1：yyy\n正文保持。');
  });
}
