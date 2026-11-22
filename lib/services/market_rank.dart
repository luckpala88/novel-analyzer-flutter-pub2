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
  static Future<List<({String id, String title, int num})>> fetchFaloo(String name) async {
    final html = await _getFalooHtml();
    final board = _sliceBoard(html, name);
    final entries = <({String id, String title, int num})>[];
    // 通用条目：<a href="//b.faloo.com/ID.html" title="书名"...>书名</a><em>数值</em>
    // top1(封面版)与row条目都是这个尾巴结构；v1597加id组（详情页抓简介用）
    final re = RegExp(
        r'<a href="//b\.faloo\.com/(\d+)\.html" title="([^"]+)"[^>]*>[^<]*</a>\s*<em>(\d+)</em>');
    for (final m in re.allMatches(board)) {
      entries.add((
        id: m.group(1)!,
        title: m.group(2)!.trim(),
        num: int.parse(m.group(3)!),
      ));
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

  /// v1597：飞卢楼层一步到位——抓榜+并发抓前10详情页（类别/字数/简介），
  /// AI分析需要题材简介不只书名
  static Future<String> fetchFalooFloor(String board) async {
    final entries = await fetchFaloo(board);
    // 并发抓详情（单本失败只丢那本的详情，条目仍在）
    final details = await Future.wait(
        entries.take(10).map((e) => _fetchFalooDetail(e.id)));
    final now = DateTime.now();
    final t = '${now.month.toString().padLeft(2, '0')}-'
        '${now.day.toString().padLeft(2, '0')} '
        '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
    final sb = StringBuffer('飞卢·$board（$t抓取实时）\n');
    for (var i = 0; i < entries.length && i < 10; i++) {
      final e = entries[i];
      final d = details[i];
      sb.write('${i + 1}. ${e.title}（${fmtNum(e.num)}）');
      if (d != null) {
        if (d.cat.isNotEmpty) sb.write('｜${d.cat}');
        if (d.words.isNotEmpty) sb.write('｜${d.words}');
        if (d.intro.isNotEmpty) sb.write('｜简介: ${d.intro}');
      }
      sb.writeln();
    }
    return sb.toString();
  }

  /// 详情页→(类别, 字数, 简介)。gbk解码；正则宽容——缺哪项丢哪项
  static Future<({String cat, String words, String intro})?>
      _fetchFalooDetail(String id) async {
    try {
      final c = HttpClient();
      c.userAgent = _ua;
      c.connectionTimeout = const Duration(seconds: 12);
      final req = await c.getUrl(Uri.parse('https://b.faloo.com/$id.html'));
      final resp =
          await req.close().timeout(const Duration(seconds: 12));
      if (resp.statusCode != 200) return null;
      final bytes =
          await resp.fold<List<int>>(<int>[], (a, b) => a..addAll(b));
      final html = gbk.decode(bytes);
      // 类别
      var cat = '';
      final cm = RegExp(r'类别：\s*([^\s<]{2,12})').firstMatch(html);
      if (cm != null) cat = cm.group(1)!;
      // 字数（万）
      var words = '';
      final wm = RegExp(r'字数\s*([0-9.]+)\s*\(万\)').firstMatch(html);
      if (wm != null) words = '${wm.group(1)!}万字';
      // 简介：meta description，剥【飞卢小说网独家签约小说：书名】前缀
      var intro = '';
      final im =
          RegExp(r'<meta name="description" content="([^"]+)"').firstMatch(html);
      if (im != null) {
        intro = im.group(1)!.replaceAllMapped(
            RegExp(r'^【[^】]*】'), (m) => '');
        intro = intro.replaceAll(RegExp(r'\s+'), ' ').trim();
        if (intro.length > 80) intro = '${intro.substring(0, 80)}…';
      }
      return (cat: cat, words: words, intro: intro);
    } catch (e) {
      return null;
    }
  }

  /// v1595：七猫全页innerText清洗——去导航两遍/页脚备案噪音，状态机组
  /// 紧凑条目。实测页面行序：名次(纯数字)/书名/作者/分类/连载状态/万字数/
  /// 简介/最近更新…/蝉联/榜首(可选)/N万热度/加入书架
  static String cleanQimao(String raw) {
    final lines = raw
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();
    // 起点：榜单正文区（「基于昨日书籍热度排行」在当前tab的section头里）
    var start = lines.indexWhere((l) => l.contains('基于昨日'));
    if (start < 0) start = lines.indexWhere((l) => l.contains('热门作品排行'));
    if (start < 0) return raw; // 结构变了——原样返回（宽容优先）
    // 终点：页脚客服/备案
    var end = lines.indexWhere((l) => l.contains('客服电话'));
    if (end < 0) end = lines.indexWhere((l) => l.contains('沪ICP备'));
    if (end < 0 || end <= start) end = lines.length;
    final seg = lines.sublist(start, end);
    final out = StringBuffer();
    var rank = '';
    var cur = <String>[];
    void flush() {
      if (rank.isEmpty || cur.isEmpty) {
        cur = [];
        return;
      }
      final book = cur.first;
      final author = cur.length > 1 ? cur[1] : '';
      // v1597：题材=作者行之后到连载状态之间的短行（分类+子分类）
      final cats = <String>[];
      var wi = cur.indexWhere((l) => l.contains('万字'));
      for (var i = 2; i < cur.length; i++) {
        final l = cur[i];
        if (l.contains('万字')) break;
        if (l.contains('连载') || l.contains('完结')) break;
        cats.add(l);
      }
      final words = wi >= 0 ? cur[wi] : '';
      // v1597：简介=字数行后到最近更新行前（AI分析题材主料）
      var intro = '';
      if (wi >= 0) {
        final ui = cur.indexWhere((l) => l.contains('最近更新'));
        final endI = ui > wi ? ui : cur.length;
        if (endI > wi + 1) {
          intro = cur.sublist(wi + 1, endI).join(' ');
        }
      }
      if (intro.length > 60) intro = '${intro.substring(0, 60)}…';
      final heat = cur.where((l) => l.contains('热度')).toList();
      final upd = cur.where((l) => l.contains('最近更新')).toList();
      out.writeln('$rank. $book'
          '${author.isNotEmpty ? '｜$author' : ''}'
          '${cats.isNotEmpty ? '｜${cats.join('·')}' : ''}'
          '${words.isNotEmpty ? '｜$words' : ''}'
          '${heat.isNotEmpty ? '｜${heat.first.replaceAll(' ', '')}' : ''}'
          '${upd.isNotEmpty ? '｜${upd.first}' : ''}'
          '${intro.isNotEmpty ? '｜简介: $intro' : ''}');
      cur = [];
    }

    for (final l in seg) {
      if (RegExp(r'^\d{1,3}$').hasMatch(l)) {
        flush();
        rank = l;
      } else if (l == '加入书架' || l.startsWith('立即阅读')) {
        flush();
      } else if (rank.isNotEmpty) {
        if (l == '蝉联' || l == '榜首') continue;
        cur.add(l);
      }
    }
    flush();
    return out.toString();
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
