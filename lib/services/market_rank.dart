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

  /// v1612：内置浏览器「接管渲染」用——抓任意URL原始HTML。
  /// UTF-8严格解码优先（七猫/起点），失败回退GBK（飞卢wap gb2312）
  static Future<String> fetchHtmlForBrowser(String url, String ua) async {
    final c = HttpClient();
    c.userAgent = ua;
    c.connectionTimeout = const Duration(seconds: 20);
    try {
      final req = await c.getUrl(Uri.parse(url));
      final resp = await req.close();
      if (resp.statusCode != 200) {
        throw Exception('HTTP ${resp.statusCode}');
      }
      final bytes = await resp
          .fold<List<int>>(<int>[], (a, b) => a..addAll(b))
          .timeout(const Duration(seconds: 20));
      try {
        return utf8.decode(bytes);
      } catch (_) {
        return gbk.decode(bytes);
      }
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
        if (d.author.isNotEmpty) sb.write('｜${d.author}');
        if (d.cat.isNotEmpty) sb.write('｜${d.cat}');
        if (d.words.isNotEmpty) sb.write('｜${d.words}');
        if (d.intro.isNotEmpty) sb.write('｜简介: ${d.intro}');
      }
      sb.writeln();
    }
    return sb.toString();
  }

  /// 详情页→(类别, 作者, 字数, 简介)。gbk解码；正则宽容——缺哪项丢哪项
  static Future<({String cat, String author, String words, String intro})?>
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
      // 作者+主分类：og:novel meta（v1600实测结构）
      var author = '';
      final am =
          RegExp(r'og:novel:author" content="([^"]+)"').firstMatch(html);
      if (am != null) author = am.group(1)!;
      var cat = '';
      final cm =
          RegExp(r'og:novel:category" content="([^"]+)"').firstMatch(html);
      if (cm != null) cat = cm.group(1)!;
      // 细分类别：类别： <a>武侠修真</a> 系列标签（去重取前3）
      final tags = <String>[];
      for (final m in RegExp(r'类别：\s*<a[^>]*>([^<]{2,12})</a>')
          .allMatches(html)) {
        final v = m.group(1)!;
        if (!tags.contains(v) && v != cat) tags.add(v);
        if (tags.length >= 3) break;
      }
      if (cat.isNotEmpty) tags.insert(0, cat);
      cat = tags.join('·');
      // 字数：<div class="zi2">151<span>(万)</span>
      var words = '';
      final wm = RegExp(r'字数</div><div[^>]*>([0-9.]+)<span>\(万\)')
          .firstMatch(html);
      if (wm != null) words = '${wm.group(1)!}万字';
      // 完整简介：正文区【签约前缀】之后到「点击阅读」，去免责声明。
      // 前缀在页头meta里也出现——取最后一处=正文版（v1600本地三处实证）
      var intro = '';
      final pms =
          RegExp(r'【飞卢小说网独家签约小说[^】]*】').allMatches(html).toList();
      if (pms.isNotEmpty) {
        final pm = pms.last;
        final endI = html.indexOf('点击阅读', pm.end);
        if (endI > pm.end) {
          intro = html
              .substring(pm.end, endI)
              .replaceAll(RegExp(r'<[^>]+>'), ' ')
              .replaceAll(RegExp(r'\s+'), ' ')
              .replaceAll('飞卢小说网提醒您：本小说及人物纯属虚构，如有雷同，纯属巧合，切勿模仿。', '')
              .trim();
          if (intro.length > 150) intro = '${intro.substring(0, 150)}…';
        }
      }
      if (intro.isEmpty) {
        // 兜底：meta description（自身截断版）
        final im = RegExp(r'<meta name="description" content="([^"]+)"')
            .firstMatch(html);
        if (im != null) {
          intro = im.group(1)!.replaceAll(RegExp(r'^【[^】]*】'), '');
          intro = intro.replaceAll(RegExp(r'\s+'), ' ').trim();
          if (intro.length > 150) intro = '${intro.substring(0, 150)}…';
        }
      }
      return (cat: cat, author: author, words: words, intro: intro);
    } catch (e) {
      return null;
    }
  }

  /// v1595：七猫全页innerText清洗——去导航两遍/页脚备案噪音，状态机组
  /// 紧凑条目。实测页面行序：名次(纯数字)/书名/作者/分类/连载状态/万字数/
  /// 简介/最近更新…/蝉联/榜首(可选)/N万热度/加入书架
  /// v1626：飞卢代理文本清洗（沙盒规则验证通过）——剥站点导航/tab/页脚
  /// 分类串，保留榜单节名+排名+书名+作者+题材+简介全文（简介是AI分析
  /// 主料不截断）。页脚从"女频阅读榜/榜单说明/统计时间"起整段切
  static String cleanFaloo(String raw) {
    const noise = {
      '小说排行榜_热门小说排行榜|小说大全_飞卢小说网',
      '|', '排行榜', '暂无', '标新榜', '总榜', '分类榜', '女生榜',
      '查看更多', '更多', '返回', '首页', '书库', '客户端', '搜索', '我的',
    };
    final lines = raw
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();
    final out = StringBuffer();
    for (final l in lines) {
      if (noise.contains(l)) continue;
      // 纯分隔符行（|·•—等）
      if (RegExp(r'^[|·•\s\-—]+$').hasMatch(l)) continue;
      // 页脚导航/说明起点——后面全切
      if (l.startsWith('女频阅读榜') ||
          l.startsWith('女频新书榜') ||
          l.startsWith('榜单说明') ||
          l.startsWith('统计时间')) {
        break;
      }
      out.writeln(l);
    }
    return out.toString().trim();
  }

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
