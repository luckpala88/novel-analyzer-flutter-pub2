import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fast_gbk/fast_gbk.dart';

import '../state/app_state.dart';

/// v1618：本地渲染代理——WebView加载localhost，内容由APP原生抓取、剥
/// 全部<script>、注入flexible等效根字号CSS后伺服（charset=utf-8头覆盖
/// gb2312 meta防乱码）。
///
/// 为什么不走loadHtmlString：连续渲染ANR实证（v1612-v1617四版死机，
/// Dart侧管线全通日志在手，死点=WebView Java主线程）；loadRequest
 /// (v1611)从不死。代理=loadRequest稳定路径+内容处理兼得。
///
/// 资源（CSS/图片）不代理直连原站（v1611实证WebView直连可过WAF），
/// 只重写页面链接进代理，保证每次"导航"都经过剥脚本管线。
class RenderProxy {
  static HttpServer? _srv;
  static int? _port;

  /// v1639：镜像模式源站（keepScripts站点，全局单值——浏览器页同时只开
  /// 一个，够用）
  static String? _mirrorOrigin;

  /// v1622：最近伺服页面的纯文本+标题——提取榜单键的原生通道
  /// （fetchRender页JS强制禁用，runJavaScript拿不到innerText=
  /// v1621提取全null实证）
  static String? lastText;
  static String lastTitle = '';

  /// 页面链接白名单后缀（其余视作资源不转代理）
  static final _resRe =
      RegExp(r'\.(css|png|jpe?g|gif|ico|js|svg|woff2?|ttf|mp4)(\?|$)',
          caseSensitive: false);

  static void _log(String m) => AppState.instance.apiLog('🌐 代理 $m');

  /// 启动（幂等），返回本地端口
  static Future<int> start() async {
    if (_port != null && _srv != null) return _port!;
    _srv = await HttpServer.bind('127.0.0.1', 0);
    _port = _srv!.port;
    _log('启动：127.0.0.1:$_port');
    _srv!.listen(_handle, onError: (e) => _log('listener错误：$e'));
    return _port!;
  }

  static Future<void> stop() async {
    try {
      await _srv?.close(force: true);
    } catch (_) {}
    _srv = null;
    _port = null;
    _mirrorOrigin = null;
  }

  /// 页面URL→代理渲染URL。
  /// 默认：/render?u=<完整URL>（剥脚本管线，飞卢用）。
  /// v1639：keepScripts=true走镜像模式——原路径伺服
  /// （http://127.0.0.1:port/rank/1）。为什么必须原路径：番茄是React
  /// Router SPA，/render路径匹配不到路由→mount时清空整个#app（沙盒
  /// 无头浏览器实证白屏）；原路径+剥secsdk防篡改脚本=与直连真站完全
  /// 同构渲染（沙盒实证书目20链接+侧栏分类XHR全通）
  static String renderUrl(String target, {bool keepScripts = false}) {
    if (keepScripts) {
      final u = Uri.parse(target);
      _mirrorOrigin = '${u.scheme}://${u.host}';
      return 'http://127.0.0.1:$_port$u.path${u.query.isEmpty ? '' : '?${u.query}'}';
    }
    return 'http://127.0.0.1:$_port/render?u=${Uri.encodeComponent(target)}';
  }

  /// v1639：镜像模式显示用源站（网址栏把本地路径拼回真实域名）
  static String mirrorOriginForDisplay(String target) {
    final u = Uri.parse(target);
    return '${u.scheme}://${u.host}';
  }

  /// 抓UA——桌面UA实机过WAF（v1614），wap双UA内容相同
  static const _ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36';

  static Future<void> _handle(HttpRequest req) async {
    try {
      final path = req.uri.path;
      if (path == '/render') {
        await _servePage(req);
      } else if (_mirrorOrigin != null) {
        // v1639：镜像模式——非/render路径全部映射到镜像源站
        await _serveMirror(req);
      } else {
        req.response.statusCode = 404;
        await req.response.close();
      }
    } catch (e) {
      _log('处理异常：$e');
      try {
        req.response.statusCode = 500;
        await req.response.close();
      } catch (_) {}
    }
  }

  /// v1639：镜像伺服——原路径转发源站。HTML剥secsdk防篡改脚本（沙盒
  /// 实证：字节sec SDK检测域名非fanqienovel.com即清空整个body）+
  /// 同站绝对链接转本地路径；资源类（js/css/图/字体）bytes原样透传
  /// （正确content-type）。根相对资源/相对API同源直达本镜像（Dart转发
  /// 无XWR头，API沙盒实证可用）
  static final _resRe2 =
      RegExp(r'\.(css|png|jpe?g|gif|ico|js|svg|woff2?|ttf|mp4)(\?|$)',
          caseSensitive: false);
  static final _secKill = [
    'security-secsdk/runtime',
    'rc-client-security',
    'goofy/secsdk',
    'captcha/index.js',
    'secsdk-lastest',
  ];

  static Future<void> _serveMirror(HttpRequest req) async {
    final origin = _mirrorOrigin!;
    final path = req.uri.path +
        (req.uri.query.isEmpty ? '' : '?${req.uri.query}');
    final target = '$origin$path';
    _log('镜像：$path');
    final c = HttpClient();
    c.userAgent = _ua;
    c.connectionTimeout = const Duration(seconds: 20);
    try {
      final r = await c.getUrl(Uri.parse(target));
      r.headers.set('Referer', '$origin/');
      final resp = await r.close();
      final bytes = await resp
          .fold<List<int>>(<int>[], (a, b) => a..addAll(b))
          .timeout(const Duration(seconds: 30));
      final ct = resp.headers.value('content-type') ?? 'text/html';
      var out = bytes;
      if (ct.contains('text/html')) {
        var html = utf8.decode(bytes, allowMalformed: true);
        html = html.replaceAll('="//', '="https://');
        // 剥secsdk整段script标签（src含关键词）
        html = html.replaceAllMapped(
            RegExp(r'<script[^>]*src="[^"]*"[^>]*>\s*</script>',
                caseSensitive: false),
            (m) {
          final tag = m.group(0)!;
          for (final k in _secKill) {
            if (tag.contains(k)) return '';
          }
          return tag;
        });
        // 同站绝对链接→本地镜像路径（资源直连原站CDN）
        html = html.replaceAllMapped(
            RegExp('="(https?://[^"]*)"', caseSensitive: false), (m) {
          final raw = m.group(1)!;
          final u2 = Uri.parse(raw);
          if (u2.host == Uri.parse(origin).host &&
              !_resRe2.hasMatch(raw)) {
            return '="${u2.path}${u2.query.isEmpty ? '' : '?${u2.query}'}"';
          }
          return '="$raw"';
        });
        out = utf8.encode(html);
        _log('镜像HTML：${out.length}B（原${bytes.length}B）');
      }
      req.response.headers.set('Content-Type', ct);
      req.response.headers.set('Content-Length', '${out.length}');
      req.response.add(out);
      await req.response.close();
    } finally {
      c.close();
    }
  }

  static Future<void> _servePage(HttpRequest req) async {
    final target = req.uri.queryParameters['u'] ?? '';
    if (!target.startsWith('http')) {
      req.response.statusCode = 400;
      await req.response.close();
      return;
    }
    _log('抓取：$target');
    final c = HttpClient();
    c.userAgent = _ua;
    c.connectionTimeout = const Duration(seconds: 20);
    String html;
    try {
      final r = await c.getUrl(Uri.parse(target));
      final resp = await r.close();
      if (resp.statusCode != 200) {
        throw Exception('HTTP ${resp.statusCode}');
      }
      final bytes = await resp
          .fold<List<int>>(<int>[], (a, b) => a..addAll(b))
          .timeout(const Duration(seconds: 20));
      try {
        html = utf8.decode(bytes);
      } catch (_) {
        html = gbk.decode(bytes);
      }
    } finally {
      c.close();
    }
    _log('抓取成功：${html.length}字符');
    // v1634：keepScripts模式（URL带s=1）跳过剥脚本+字号注入——番茄SSR
    // 数据在script里要留着让React hydrate；字号注入是飞卢rem版式专用，
    // 对番茄px版式反而有害
    final keepScripts = req.uri.queryParameters['s'] == '1';
    var out = html;
    if (!keepScripts) {
      out = out.replaceAll(
          RegExp(r'<script[\s\S]*?</script>', caseSensitive: false), '');
      out = out.replaceAll(
          RegExp(r'<script[^>]*/>', caseSensitive: false), '');
    }
    // v1619：双禁令——根字号flexible等效 + 全元素text-size-adjust禁
    // （Android WebView font boosting会无视根字号放大计算后字号=v1616
    // 字体很大实证；text-size-adjust:none是唯一关闭通道，全元素!important
    // 比站点html,body规则更强）
    // v1634：keepScripts模式跳过字号注入（番茄px版式自洽，注入反而有害）
    if (!keepScripts) {
      const inject =
          '<style>html{font-size:min(calc(100vw/9),71.1px)!important;}'
          '*{-webkit-text-size-adjust:none!important;text-size-adjust:none!important;}</style>'
          // v1622：飞卢错位补丁（手机Chromium仿真复现+flex修复沙盒验证）——
          // ①查看更多文字掉出按钮框②排名角标压书名。病根=无单位line-height
          // 的行盒装不下内容（手机端行盒计算与桌面不同），flex居中绕开行盒
          '<style>'
          '.divReadMore{display:flex!important;align-items:center!important;justify-content:center!important;}'
          '.readMore{line-height:normal!important;}'
          '.hot24DivIndex{display:flex!important;align-items:center!important;justify-content:center!important;overflow:visible!important;}'
          '.hot24Index{line-height:normal!important;display:block!important;}'
          '</style>';
      final i = out.toLowerCase().indexOf('<head>');
      out = i >= 0
          ? out.substring(0, i + 6) + inject + out.substring(i + 6)
          : inject + out;
    }
    // 协议相对资源补https（localhost源下//host会变成http://host明文）
    out = out.replaceAll('="//', '="https://');
    // 根相对链接补主机名（防落到localhost上404）
    final host = Uri.parse(target).host;
    out = out.replaceAllMapped(
        RegExp('="(?!https?:|/render|#|javascript:)(/[^"]*)"',
            caseSensitive: false), (m) {
      final raw = m.group(1)!;
      if (_resRe.hasMatch(raw)) {
        return '="https://$host$raw"'; // 资源直连原站
      }
      return '="/render?u=${Uri.encodeComponent('https://$host$raw')}"'; // 页面走代理
    });
    // 协议相对链接已在上面统一补https，此处只处理绝对链接转代理
    // 绝对页面链接转代理
    out = out.replaceAllMapped(
        RegExp('="(https?://[^"]*)"', caseSensitive: false), (m) {
      final raw = m.group(1)!;
      if (_resRe.hasMatch(raw)) return '="$raw"'; // 资源直连
      return '="/render?u=${Uri.encodeComponent(raw)}"';
    });
    _log('处理后：${out.length}字符，伺服');
    // v1622：缓存纯文本供提取榜单键（剥注释/标签→逐行去空）
    var plain = out.replaceAll(
        RegExp(r'<!--[\s\S]*?-->'), '');
    plain = plain.replaceAll(
        RegExp(r'<(style|script)[\s\S]*?</\1>', caseSensitive: false), '');
    plain = plain.replaceAll(RegExp(r'<[^>]+>'), '\n');
    const ents = {
      '&nbsp;': ' ', '&amp;': '&', '&lt;': '<', '&gt;': '>',
      '&quot;': '"', '&#39;': "'",
    };
    ents.forEach((k, v) => plain = plain.replaceAll(k, v));
    lastText = plain
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .join('\n');
    lastTitle = RegExp(r'<title[^>]*>([\s\S]*?)</title>', caseSensitive: false)
            .firstMatch(out)
            ?.group(1)
            ?.trim() ??
        target;
    req.response.headers.contentType =
        ContentType('text', 'html', charset: 'utf-8');
    req.response.write(out);
    await req.response.close();
  }
}
