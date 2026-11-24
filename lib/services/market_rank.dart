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
      return gbk.decode(bytes, allowMalformed: true);
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
        return gbk.decode(bytes, allowMalformed: true);
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
  /// v1630：晋江榜单原生直抓——jjwxc.net/topten.php静态gbk表无反爬（沙盒
  /// python实证可拿全表200行8列）。行结构：排名/作者(oneauthor锚)/
  /// 书名+简介(onebook锚，title属性=书名，锚文本=简介全文)/题材
  /// (原创-言情-…)/状态/字数/积分/时间
  static Future<String> fetchJinjiangFloor(String query, String board) async {
    final c = HttpClient();
    c.userAgent = _ua;
    c.connectionTimeout = const Duration(seconds: 12);
    final req =
        await c.getUrl(Uri.parse('https://www.jjwxc.net/topten.php?$query'));
    final resp = await req.close().timeout(const Duration(seconds: 15));
    final bytes = await resp.fold<List<int>>(<int>[], (a, b) => a..addAll(b));
    final html = gbk.decode(bytes, allowMalformed: true);
    String txt(String s) => s
        .replaceAll('&nbsp;', ' ')
        .replaceAll(RegExp(r'<[^>]+>'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    // 含onebook锚的行=书目行（页头导航等不含），取前10
    final rows = <String>[];
    for (final m in RegExp(r'<tr[^>]*>([\s\S]*?)</tr>').allMatches(html)) {
      final r = m.group(1)!;
      if (r.contains('onebook.php')) rows.add(r);
      if (rows.length >= 10) break;
    }
    final now = DateTime.now();
    final t = '${now.month.toString().padLeft(2, '0')}-'
        '${now.day.toString().padLeft(2, '0')} '
        '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
    final sb = StringBuffer('晋江·$board（$t抓取实时）\n');
    for (var i = 0; i < rows.length; i++) {
      final row = rows[i];
      // 书名：onebook锚的title属性（总分榜/字数榜等——锚文本是简介，
      // 书名只存title里）。官推/新晋榜无title属性且锚文本=书名（v1633
      // 沙盒实证），书名回退取锚文本、简介置空
      var title = '';
      final tagM = RegExp(r'<a\s[^>]*onebook[^>]*>').firstMatch(row);
      if (tagM != null) {
        final tm = RegExp(r'title="([^"]+)"').firstMatch(tagM.group(0)!);
        if (tm != null) title = tm.group(1)!;
      }
      // 作者：oneauthor锚文本
      var author = '';
      final aum = RegExp(r'<a[^>]*oneauthor[^>]*>([^<]+)</a>').firstMatch(row);
      if (aum != null) author = aum.group(1)!.trim();
      // 锚文本：title属性存在时=简介全文（不截断）；无title属性的榜
      // （官推/新晋）锚文本=书名本身，简介置空防书名简介重复
      var intro = '';
      final im =
          RegExp(r'<a[^>]*onebook[^>]*>([\s\S]*?)</a>').firstMatch(row);
      if (im != null) intro = txt(im.group(1)!);
      if (title.isEmpty && intro.isNotEmpty) {
        title = intro;
        intro = '';
      }
      // 后四列：题材/状态/字数/积分
      final tds = row.split('</td>');
      String cell(int i) => i < tds.length ? txt(tds[i]) : '';
      final genre = cell(3);
      final status = cell(4);
      final words = cell(5);
      final score = cell(6);
      sb.write('${i + 1}. 《$title》');
      if (author.isNotEmpty) sb.write('｜$author');
      if (genre.isNotEmpty) sb.write('｜$genre');
      if (status.isNotEmpty) sb.write('｜$status');
      if (words.isNotEmpty) sb.write('｜${words}字');
      if (score.isNotEmpty) sb.write('｜积分$score');
      if (intro.isNotEmpty) sb.write('\n简介: $intro');
      sb.writeln();
    }
    return sb.toString();
  }

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
      final html = gbk.decode(bytes, allowMalformed: true);
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

  // ==================== 番茄分类榜（v1643原生直抓） ====================
  // v1643：分类榜API零反爬直抓（沙盒curl实证code:0全明文）——书名/作者/
  // 简介/在读/字数/状态全字段，一页limit=100。总榜SSR密文走屏捕（另有通道）
  // 参数定案（沙盒枚举实证）：rank_list_type=3固定；gender 1男0女；
  // rankMold 1新书2阅读（mold2在读高完结多=阅读榜，mold1连载多=新书榜）；
  // 无category_id必报"分类类型错误"（总榜API前端参数本身就是坏的）
  static const _fqMaleCats = [
    ('1141', '西方奇幻'), ('1140', '东方仙侠'), ('8', '科幻末世'),
    ('261', '都市日常'), ('124', '都市修真'), ('1014', '都市高武'),
    ('273', '历史古代'), ('27', '战神赘婿'), ('263', '都市种田'),
    ('258', '传统玄幻'), ('272', '历史脑洞'), ('539', '悬疑脑洞'),
    ('262', '都市脑洞'), ('257', '玄幻脑洞'), ('751', '悬疑灵异'),
    ('504', '抗战谍战'), ('746', '游戏体育'), ('718', '动漫衍生'),
    ('1016', '男频衍生'),
  ];
  static const _fqFemaleCats = [
    ('1139', '古风世情'), ('8', '科幻末世'), ('746', '游戏体育'),
    ('1015', '女频衍生'), ('248', '玄幻言情'), ('23', '种田'),
    ('79', '年代'), ('267', '现言脑洞'), ('246', '宫斗宅斗'),
    ('539', '悬疑脑洞'), ('253', '古言脑洞'), ('24', '快穿'),
    ('749', '青春甜宠'), ('745', '星光璀璨'), ('747', '女频悬疑'),
    ('750', '职场婚恋'), ('748', '豪门总裁'), ('1017', '民国言情'),
  ];

  /// v1643b：番茄字体解密——API文本字段约半数字符为PUA私用区密文
  /// （页面用加密字体渲染明文），映射表362条=加密字体字形逐一读图识别
  /// （沙盒freetype渲染+pua_p0-8拼图人工判字，全表无算法猜测）
  static const Map<int, String> _fqPuaMap = {
    0xE3E8: 'D', 0xE3E9: '在', 0xE3EA: '主', 0xE3EB: '特', 0xE3EC: '家', 0xE3ED: '军',
    0xE3EE: '然', 0xE3EF: '表', 0xE3F0: '场', 0xE3F1: '4', 0xE3F2: '要', 0xE3F3: '只',
    0xE3F4: 'V', 0xE3F5: '和', 0xE3F7: '6', 0xE3F8: '别', 0xE3F9: '还', 0xE3FA: 'g',
    0xE3FB: '现', 0xE3FC: '儿', 0xE3FD: '岁', 0xE400: '此', 0xE401: '象', 0xE402: '月',
    0xE403: '3', 0xE404: '出', 0xE405: '战', 0xE406: '工', 0xE407: '相', 0xE408: 'O',
    0xE409: '男', 0xE40A: '直', 0xE40B: '失', 0xE40C: '世', 0xE40D: 'F', 0xE40E: '都',
    0xE40F: '平', 0xE410: '文', 0xE411: '什', 0xE412: 'V', 0xE413: 'O', 0xE414: '将',
    0xE415: '真', 0xE416: 'T', 0xE417: '那', 0xE418: '当', 0xE41A: '会', 0xE41B: '立',
    0xE41C: '些', 0xE41D: 'U', 0xE41E: '是', 0xE41F: '十', 0xE420: '张', 0xE421: '学',
    0xE422: '气', 0xE423: '大', 0xE424: '爱', 0xE425: '两', 0xE426: '命', 0xE427: '全',
    0xE428: '后', 0xE429: '东', 0xE42A: '性', 0xE42B: '通', 0xE42C: '被', 0xE42D: '1',
    0xE42E: '它', 0xE42F: '乐', 0xE430: '接', 0xE431: '而', 0xE432: '感', 0xE433: '车',
    0xE434: '山', 0xE435: '公', 0xE436: '了', 0xE437: '常', 0xE438: '以', 0xE439: '何',
    0xE43A: '可', 0xE43B: '话', 0xE43C: '先', 0xE43D: 'p', 0xE43E: 'i', 0xE43F: '叫',
    0xE440: '轻', 0xE441: 'M', 0xE442: '士', 0xE443: 'W', 0xE444: '着', 0xE445: '变',
    0xE446: '尔', 0xE447: '快', 0xE448: 'l', 0xE449: '个', 0xE44A: '说', 0xE44B: '少',
    0xE44C: '色', 0xE44D: '里', 0xE44E: '安', 0xE44F: '花', 0xE450: '远', 0xE451: '7',
    0xE452: '难', 0xE453: '师', 0xE454: '放', 0xE455: 't', 0xE456: '报', 0xE457: '认',
    0xE458: '面', 0xE459: '道', 0xE45A: 'S', 0xE45C: '克', 0xE45D: '地', 0xE45E: '度',
    0xE45F: 'I', 0xE460: '好', 0xE461: '机', 0xE462: 'U', 0xE463: '民', 0xE464: '写',
    0xE465: '把', 0xE466: '万', 0xE467: '同', 0xE468: '水', 0xE469: '新', 0xE46A: '没',
    0xE46B: '书', 0xE46C: '电', 0xE46D: '吃', 0xE46E: '像', 0xE46F: '斯', 0xE470: '5',
    0xE471: '为', 0xE472: 'Y', 0xE473: '白', 0xE474: '几', 0xE475: '日', 0xE476: '教',
    0xE477: '看', 0xE478: '但', 0xE479: '第', 0xE47A: '加', 0xE47B: '候', 0xE47C: '作',
    0xE47D: '上', 0xE47E: '拉', 0xE47F: '住', 0xE480: '有', 0xE481: '法', 0xE482: 'r',
    0xE483: '事', 0xE484: '应', 0xE485: '位', 0xE486: '利', 0xE487: '你', 0xE488: '声',
    0xE489: '身', 0xE48A: '国', 0xE48B: '问', 0xE48C: '马', 0xE48D: '女', 0xE48E: '他',
    0xE48F: 'Y', 0xE490: '比', 0xE491: '父', 0xE492: 'X', 0xE493: 'A', 0xE494: 'H',
    0xE495: 'N', 0xE496: 'S', 0xE497: 'X', 0xE498: '边', 0xE499: '美', 0xE49A: '对',
    0xE49B: '所', 0xE49C: '金', 0xE49D: '活', 0xE49E: '回', 0xE49F: '意', 0xE4A0: '到',
    0xE4A1: 'Z', 0xE4A2: '从', 0xE4A3: 'j', 0xE4A4: '知', 0xE4A5: '又', 0xE4A6: '内',
    0xE4A7: '因', 0xE4A8: '点', 0xE4A9: 'Q', 0xE4AA: '三', 0xE4AB: '定', 0xE4AC: '8',
    0xE4AD: 'R', 0xE4AE: 'b', 0xE4AF: '正', 0xE4B0: '或', 0xE4B1: '夫', 0xE4B2: '向',
    0xE4B3: '德', 0xE4B4: '听', 0xE4B5: '更', 0xE4B7: '得', 0xE4B8: '告', 0xE4B9: '并',
    0xE4BA: '本', 0xE4BB: 'q', 0xE4BC: '过', 0xE4BD: '记', 0xE4BE: 'L', 0xE4BF: '让',
    0xE4C0: '打', 0xE4C1: 'f', 0xE4C2: '人', 0xE4C3: '就', 0xE4C4: '者', 0xE4C5: '去',
    0xE4C6: '原', 0xE4C7: '满', 0xE4C8: '体', 0xE4C9: '做', 0xE4CA: '经', 0xE4CB: 'K',
    0xE4CC: '走', 0xE4CD: '如', 0xE4CE: '孩', 0xE4CF: 'C', 0xE4D0: 'G', 0xE4D1: '给',
    0xE4D2: '使', 0xE4D3: '物', 0xE4D5: '最', 0xE4D6: '笑', 0xE4D7: '部', 0xE4D9: '员',
    0xE4DA: '等', 0xE4DB: '受', 0xE4DC: 'k', 0xE4DD: '行', 0xE4DE: '一', 0xE4DF: '条',
    0xE4E0: '果', 0xE4E1: '动', 0xE4E2: '光', 0xE4E3: '门', 0xE4E4: '头', 0xE4E5: '见',
    0xE4E6: '往', 0xE4E7: '自', 0xE4E8: '解', 0xE4E9: '成', 0xE4EA: '处', 0xE4EB: '天',
    0xE4EC: '能', 0xE4ED: '于', 0xE4EE: '名', 0xE4EF: '其', 0xE4F0: '发', 0xE4F1: '总',
    0xE4F2: '母', 0xE4F3: '的', 0xE4F4: '死', 0xE4F5: '手', 0xE4F6: '入', 0xE4F7: '路',
    0xE4F8: '进', 0xE4F9: '心', 0xE4FA: '来', 0xE4FB: 'h', 0xE4FC: '时', 0xE4FD: '力',
    0xE4FE: '多', 0xE4FF: '开', 0xE500: '已', 0xE501: '许', 0xE502: 'd', 0xE503: '至',
    0xE504: '由', 0xE505: '很', 0xE506: '界', 0xE507: 'n', 0xE508: '小', 0xE509: '与',
    0xE50A: 'Z', 0xE50B: '想', 0xE50C: '代', 0xE50D: '么', 0xE50E: '分', 0xE50F: '生',
    0xE510: '口', 0xE511: '再', 0xE512: '妈', 0xE513: '望', 0xE514: '次', 0xE515: '西',
    0xE516: '风', 0xE517: '种', 0xE518: '带', 0xE519: 'J', 0xE51B: '实', 0xE51C: '情',
    0xE51D: '才', 0xE51E: '这', 0xE520: 'E', 0xE521: '我', 0xE522: '神', 0xE523: '格',
    0xE524: '长', 0xE525: '觉', 0xE526: '间', 0xE527: '年', 0xE528: '眼', 0xE529: '无',
    0xE52A: '不', 0xE52B: '亲', 0xE52C: '关', 0xE52D: '结', 0xE52E: '0', 0xE52F: '友',
    0xE530: '信', 0xE531: '下', 0xE532: '却', 0xE533: '重', 0xE534: '已', 0xE535: '老',
    0xE536: '2', 0xE537: '音', 0xE538: '字', 0xE539: 'm', 0xE53A: '呢', 0xE53B: '明',
    0xE53C: '之', 0xE53D: '前', 0xE53E: '高', 0xE53F: 'P', 0xE540: 'B', 0xE541: '目',
    0xE542: '太', 0xE543: 'e', 0xE544: '9', 0xE545: '起', 0xE546: '棱', 0xE547: '她',
    0xE548: '也', 0xE549: 'W', 0xE54A: '用', 0xE54B: '方', 0xE54C: '子', 0xE54D: '英',
    0xE54E: '每', 0xE54F: '理', 0xE550: '便', 0xE551: '四', 0xE552: '数', 0xE553: '期',
    0xE554: '中', 0xE555: 'C', 0xE556: '外', 0xE557: '样', 0xE558: 'a', 0xE559: '海',
    0xE55A: '们', 0xE55B: '任',
  };

  // v1645：改runes手写——v1644安卓Build APK挂（win成功，唯一差异=362条
  // map+本函数），嫌疑RegExp\u区间在AOT环境问题；改纯整型判断绕开
  static String _fqDec(String s) {
    final sb = StringBuffer();
    for (final ch in s.runes) {
      if (ch >= 0xE000 && ch <= 0xF8FF) {
        sb.write(_fqPuaMap[ch] ?? '');
      } else {
        sb.writeCharCode(ch);
      }
    }
    return sb.toString();
  }


  /// 抓番茄一个频道榜：gender(1男0女)+mold(1新书2阅读)→全分类×前10本
  static Future<String> fetchFanqieFloor(int gender, int mold) async {
    final cats = gender == 1 ? _fqMaleCats : _fqFemaleCats;
    final gname = gender == 1 ? '男频' : '女频';
    final bname = mold == 1 ? '新书榜' : '阅读榜';
    final c = HttpClient();
    c.userAgent = _ua;
    c.connectionTimeout = const Duration(seconds: 12);
    final now = DateTime.now();
    final t = '${now.month.toString().padLeft(2, '0')}-'
        '${now.day.toString().padLeft(2, '0')} '
        '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
    final sb = StringBuffer('$gname·$bname（$t抓取实时，全分类前10，API直抓明文）\n');
    var fail = 0;
    for (final (cid, cname) in cats) {
      try {
        final url = 'https://fanqienovel.com/api/rank/category/list'
            '?app_id=2503&rank_list_type=3&offset=0&limit=10'
            '&category_id=$cid&rank_version=&gender=$gender&rankMold=$mold';
        final req = await c.getUrl(Uri.parse(url));
        req.headers.set('Referer', 'https://fanqienovel.com/');
        final resp = await req.close().timeout(const Duration(seconds: 15));
        final bytes =
            await resp.fold<List<int>>(<int>[], (a, b) => a..addAll(b));
        final d = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
        final data = d['data'] as Map<String, dynamic>? ?? {};
        final bl = (data['book_list'] as List?) ?? [];
        sb.writeln('\n—— $cname（${data['total_num'] ?? bl.length}本）——');
        for (var i = 0; i < bl.length && i < 10; i++) {
          final b = bl[i] as Map<String, dynamic>;
          // v1643b：PUA密文解密（书名/作者/简介/最新章节全是密文混排）
          final name = _fqDec('${b['bookName'] ?? ''}');
          final author = _fqDec('${b['author'] ?? ''}');
          final read = int.tryParse('${b['read_count'] ?? 0}') ?? 0;
          final words = int.tryParse('${b['wordNumber'] ?? 0}') ?? 0;
          final done = '${b['creationStatus'] ?? ''}' == '0' ? '完结' : '连载';
          sb.write('${i + 1}. $name');
          if (author.isNotEmpty) sb.write('｜$author');
          sb.write('｜在读${fmtNum(read)}｜${fmtNum(words)}字｜$done');
          final lc = _fqDec('${b['lastChapterTitle'] ?? ''}');
          if (lc.isNotEmpty) sb.write('｜最新:$lc');
          sb.writeln();
          // 分类Top1带简介（头部作品调研价值最高；全带楼层过长）
          if (i == 0) {
            final ab = _fqDec('${b['abstract'] ?? ''}').trim();
            if (ab.isNotEmpty) {
              var intro = ab.replaceAll(RegExp(r'\s+'), ' ');
              if (intro.length > 120) intro = '${intro.substring(0, 120)}…';
              sb.writeln('简介: $intro');
            }
          }
        }
      } catch (_) {
        fail++;
        sb.writeln('\n—— $cname（抓取失败）——');
      }
    }
    c.close();
    if (fail > 0) sb.writeln('\n（$fail个分类抓取失败）');
    return sb.toString();
  }
}
