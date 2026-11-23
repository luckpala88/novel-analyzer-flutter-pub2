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
  }

  /// 页面URL→代理渲染URL
  static String renderUrl(String target) =>
      'http://127.0.0.1:$_port/render?u=${Uri.encodeComponent(target)}';

  /// 抓UA——桌面UA实机过WAF（v1614），wap双UA内容相同
  static const _ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36';

  static Future<void> _handle(HttpRequest req) async {
    try {
      final path = req.uri.path;
      if (path == '/render') {
        await _servePage(req);
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
    var out = html.replaceAll(
        RegExp(r'<script[\s\S]*?</script>', caseSensitive: false), '');
    out = out.replaceAll(
        RegExp(r'<script[^>]*/>', caseSensitive: false), '');
    // flexible.js等效根字号（手机UA设计：视口宽/9，上限640/9）
    const inject =
        '<style>html{font-size:min(calc(100vw/9),71.1px)!important;}</style>';
    final i = out.toLowerCase().indexOf('<head>');
    out = i >= 0
        ? out.substring(0, i + 6) + inject + out.substring(i + 6)
        : inject + out;
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
    req.response.headers.contentType =
        ContentType('text', 'html', charset: 'utf-8');
    req.response.write(out);
    await req.response.close();
  }
}
