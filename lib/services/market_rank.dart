import 'dart:convert';
import 'dart:io';

import 'package:fast_gbk/fast_gbk.dart';

/// v1593：市场榜单抓取——飞卢静态gb2312页零反爬直抓（curl实证）；
/// 七猫/番茄走内置浏览器WebView（WAF只放行真浏览器，curl/python/
/// 无头浏览器三连405实证），见market_browser_page.dart
class MarketRank {
  static const _falooUrl = 'https://www.faloo.com/';
  // 桌面UA——桌面版HTML结构稳定（移动版另爬）
  static const _ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36';

  /// 抓飞卢首页三大榜：name=点击榜/月票榜/收藏榜
  /// 返回「书名|数值」列表（数值原始值，UI层格式化）
  static Future<List<({String title, int num})>> fetchFaloo(String name) async {
    final html = await _getFalooHtml();
    final board = _sliceBoard(html, name);
    final entries = <({String title, int num})>[];
    // 通用条目：<a href="//b.faloo.com/ID.html" title="书名"...>书名</a><em>数值</em>
    // top1(封面版)与row条目都是这个尾巴结构
    final re = RegExp(
        r'<a href="//b\.faloo\.com/\d+\.html" title="([^"]+)"[^>]*>[^<]*</a>\s*<em>(\d+)</em>');
    for (final m in re.allMatches(board)) {
      entries.add((title: m.group(1)!.trim(), num: int.parse(m.group(2)!)));
    }
    if (entries.isEmpty) {
      throw Exception('飞卢「$name」解析为空——页面结构可能变化');
    }
    return entries;
  }

  static Future<String> _getFalooHtml() async {
    final c = HttpClient();
    c.userAgent = _ua;
    c.connectionTimeout = const Duration(seconds: 20);
    try {
      final req = await c.getUrl(Uri.parse(_falooUrl));
      final resp = await req.close();
      if (resp.statusCode != 200) {
        throw Exception('飞卢HTTP ${resp.statusCode}');
      }
      final bytes = await resp
          .fold<List<int>>(<int>[], (a, b) => a..addAll(b))
          .timeout(const Duration(seconds: 20));
      // 飞卢gb2312编码（charset=gb2312实证），fast_gbk解码
      return gbk.decode(bytes);
    } finally {
      c.close();
    }
  }

  /// 截取某榜区块：从「<榜名>」标记到下一个榜标记（三大榜同页横排）
  static String _sliceBoard(String html, String name) {
    const order = ['点击榜', '月票榜', '收藏榜'];
    final i = html.indexOf('$name</div>');
    if (i < 0) throw Exception('飞卢页面找不到「$name」标记');
    var end = html.length;
    for (final other in order) {
      if (other == name) continue;
      final j = html.indexOf('$other</div>', i + name.length);
      if (j > 0 && j < end) end = j;
    }
    return html.substring(i, end);
  }

  /// 数值格式化：飞卢点击数/月票数（648063→64.8万）
  static String fmtNum(int v) {
    if (v >= 100000000) return '${(v / 100000000).toStringAsFixed(2)}亿';
    if (v >= 10000) return '${(v / 10000).toStringAsFixed(1)}万';
    return '$v';
  }

  /// 榜单→聊天楼层文本
  static String toFloorText(String site, String board, List<({String title, int num})> entries) {
    final now = DateTime.now();
    final t = '${now.month.toString().padLeft(2, '0')}-'
        '${now.day.toString().padLeft(2, '0')} '
        '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
    final sb = StringBuffer('$site·$board（$t抓取实时）\n');
    for (var i = 0; i < entries.length && i < 10; i++) {
      final e = entries[i];
      sb.writeln('${i + 1}. ${e.title}（${fmtNum(e.num)}）');
    }
    return sb.toString();
  }
}
