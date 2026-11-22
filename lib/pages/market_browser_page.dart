import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

/// v1593：内置浏览器——七猫/番茄榜单页。WAF按TLS指纹拦程序直连
/// （curl/python/无头浏览器三连405实证），手机WebView=真浏览器环境能过。
/// 「提取榜单」= JS读DOM innerText回填聊天楼层；番茄DOM文字被字体加密，
/// 提取出来是乱码（只能看），七猫DOM是干净文本（能提取）
class MarketBrowserPage extends StatefulWidget {
  final String url;
  final String title;
  final bool extractable; // 番茄=false（字体加密提取无意义）
  final bool autoExtract; // v1593：true=加载完自动提取并返回（无人值守）
  const MarketBrowserPage({
    super.key,
    required this.url,
    required this.title,
    this.extractable = true,
    this.autoExtract = false,
  });

  @override
  State<MarketBrowserPage> createState() => _MarketBrowserPageState();
}

class _MarketBrowserPageState extends State<MarketBrowserPage> {
  late final WebViewController _ctl;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _ctl = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setUserAgent(_mobileUa)
      ..setNavigationDelegate(NavigationDelegate(
        onPageFinished: (_) {
          setState(() => _loading = false);
          // v1593：自动提取模式——加载完等2.5秒（JS列表渲染）自动提取返回，
          // 失败留在本页可手动「提取榜单」兜底
          if (widget.autoExtract) {
            Future.delayed(const Duration(milliseconds: 2500), () {
              if (mounted) _extract();
            });
          }
        },
      ))
      ..loadRequest(Uri.parse(widget.url));
  }

  static const _mobileUa =
      'Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Mobile Safari/537.36';

  Future<void> _extract() async {
    try {
      // 全页innerText——榜单页导航杂讯可接受，宽容优先（结构变了也不空转）
      final r = await _ctl.runJavaScriptReturningResult(
          'document.body.innerText');
      var text = r is String ? r : r.toString();
      // WebView返回JSON编码串（带首尾引号与转义），解一层
      if (text.startsWith('"')) {
        text = jsonDecode(text) as String;
      }
      text = text.trim();
      if (text.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('页面内容为空——还没加载完，稍等再试')));
        }
        return;
      }
      if (text.length > 6000) text = text.substring(0, 6000);
      if (mounted) Navigator.pop(context, text);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('提取失败：$e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title, overflow: TextOverflow.ellipsis),
        actions: [
          // v1593：只看_loading——autoExtract失败后要露出「提取榜单」手动兜底
          if (_loading)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 12),
              child: Center(
                child: SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2)),
              ),
            )
          else ...[
            // 刷新（重载页面）
            TextButton(
              onPressed: () {
                setState(() => _loading = true);
                _ctl.reload();
              },
              child: const Text('刷新'),
            ),
            if (widget.extractable)
              TextButton(
                onPressed: _extract,
                child: const Text('提取榜单'),
              ),
          ],
        ],
      ),
      body: WebViewWidget(controller: _ctl),
    );
  }
}
