import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
// v1604：Android专用控制器——setMixedContentMode放开http图片（飞卢书封
// img.faloo.com是http://老协议10张，https页面里被默认neverAllow拦掉）
import 'package:webview_flutter_android/webview_flutter_android.dart';

import '../services/market_rank.dart';
import '../services/render_proxy.dart';
import '../state/app_state.dart';

/// v1615：浏览器诊断日志——ANR死机连续三版无现场（apiLogs零记录实证），
/// 导航/渲染全链路埋点，复现后上传日志可定位断点
void _blog(String m) => AppState.instance.apiLog('🌐 $m');

/// v1593：内置浏览器——七猫/番茄榜单页。WAF按TLS指纹拦程序直连
/// （curl/python/无头浏览器三连405实证），手机WebView=真浏览器环境能过。
/// 「提取榜单」= JS读DOM innerText回填聊天楼层；番茄DOM文字被字体加密，
/// 提取出来是乱码（只能看），七猫DOM是干净文本（能提取）
class MarketBrowserPage extends StatefulWidget {
  final String url;
  final String title;
  final bool extractable; // 番茄=false（字体加密提取无意义）
  final bool autoExtract; // v1593：true=加载完自动提取并返回（无人值守）
  final bool desktopUa; // v1596：番茄给手机UA的是下载APP推广壳页（用户截图实锤），桌面UA才有真榜单
  // v1608：手机版/电脑版网址——实测各站双版本=不同URL不同DOM（只换UA看不到
  // 变化；起点www重JS壳崩溃,wap/m.版服务端直渲染）。null=同URL只切UA/视口。
  // url=初始加载的版本；desktopUrl=切电脑版用的URL（起点初始开m.版时用）
  final String? mobileUrl;
  final String? desktopUrl;
  // v1611：JS开关——飞卢wap版openApp2021.js死机(ANR实证)。v1612升级为
  // fetchRender接管渲染：原生抓HTML剥全部<script>再loadHtmlString(baseUrl)
  // ——页面脚本物理不存在(openApp零执行),注入flexible等效CSS(html font-size
  // =100vw/9)版式正常；JS开着只跑我们的代码,提取键可用。连URL导航仍走
  // v1609防线拦scheme/下载页
  final bool enableJs;
  final bool fetchRender;
  const MarketBrowserPage({
    super.key,
    required this.url,
    required this.title,
    this.extractable = true,
    this.autoExtract = false,
    this.desktopUa = false,
    this.mobileUrl,
    this.desktopUrl,
    this.enableJs = true,
    this.fetchRender = false,
  });

  @override
  State<MarketBrowserPage> createState() => _MarketBrowserPageState();
}

class _MarketBrowserPageState extends State<MarketBrowserPage> {
  late final WebViewController _ctl;
  bool _loading = true;
  bool _done = false; // v1595：已提取返回，轮询停止
  // v1603：手机/电脑版切换态（初始跟随入口配置）
  bool _desktop = false;
  // v1606：网址栏+前进后退
  final _urlCtl = TextEditingController();
  bool _canBack = false;
  bool _canFwd = false;

  @override
  void dispose() {
    _urlCtl.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _desktop = widget.desktopUa;
    _blog('浏览器打开：${widget.url}，fetchRender=${widget.fetchRender}，desktopUa=${widget.desktopUa}');
    // v1604：Android平台参数建WebView，再从platform调setMixedContentMode
    final ctl = WebViewController.fromPlatformCreationParams(
        AndroidWebViewControllerCreationParams());
    (ctl.platform as AndroidWebViewController)
        .setMixedContentMode(MixedContentMode.alwaysAllow);
    _ctl = ctl
      // v1611：enableJs=false时禁JS——openApp2021.js类页面脚本不执行。
      // v1615：fetchRender接管模式强制禁JS——脚本已物理剥除JS无显示作用
      // （v1611实证JS关=不死，v1612-14死机全在JS开状态）
      ..setJavaScriptMode((widget.enableJs && !widget.fetchRender)
          ? JavaScriptMode.unrestricted
          : JavaScriptMode.disabled)
      ..setNavigationDelegate(NavigationDelegate(
        // v1609：导航防线——飞卢wap版openApp2021.js死机实证：拉APP
        // scheme(flreader://)失败→兜底跳DownloadAPP2021.aspx→下载页又带
        // 同款脚本→无限导航循环。未知scheme+下载落地页一律拦
        onNavigationRequest: (req) {
          _blog('导航请求：${req.url.length > 90 ? req.url.substring(0, 90) : req.url}');
          // v1618：接管渲染模式——localhost代理页面放行（每次导航都经过
          // 剥脚本管线），其他http(s)一律不放行（openApp物理隔离）
          if (widget.fetchRender) {
            final u = Uri.tryParse(req.url);
            if (u?.host == '127.0.0.1' &&
                (u?.queryParameters['u']?.startsWith('http') ?? false)) {
              return NavigationDecision.navigate;
            }
            return NavigationDecision.prevent;
          }
          final scheme = Uri.tryParse(req.url)?.scheme ?? '';
          if (scheme != 'http' && scheme != 'https') {
            return NavigationDecision.prevent;
          }
          if (req.url.contains('DownloadAPP2021.aspx')) {
            return NavigationDecision.prevent;
          }
          return NavigationDecision.navigate;
        },
        onPageFinished: (url) {
          _blog('页面加载完：${url != null && url.length > 60 ? url.substring(0, 60) : (url ?? 'null')}');
          setState(() => _loading = false);
          // v1606：网址栏同步当前URL。v1618：代理模式下把/render?u=解码回
          // 真实网址显示；启动初未就绪的about:blank跳过
          if (mounted && url != null) {
            if (widget.fetchRender) {
              final u = Uri.tryParse(url);
              final real = u?.queryParameters['u'];
              if (real != null && real.startsWith('http')) {
                _urlCtl.text = real;
              }
            } else if (url.startsWith('http')) {
              _urlCtl.text = url;
            }
          }
          _ctl.canGoBack().then((v) {
            if (mounted) setState(() => _canBack = v);
          });
          _ctl.canGoForward().then((v) {
            if (mounted) setState(() => _canFwd = v);
          });
          // v1602：desktopUa不只骗服务器——番茄桌面站是响应式布局，窄视口
          // 仍排手机版；注入viewport width=1280强制桌面排布（请求桌面版网站
          // 的标准手段）。v1603：随切换态走，手机版还原device-width。
          // v1611：JS禁用页无法注入，跳过。v1612：接管渲染页自带等效CSS也跳过
          if (widget.enableJs && !widget.fetchRender) {
          final vp = _desktop
              ? "var mv=document.querySelector('meta[name=viewport]');"
                  "if(mv){mv.setAttribute('content','width=1280');}"
                  "else{var m=document.createElement('meta');m.name='viewport';"
                  "m.content='width=1280';document.head.appendChild(m);}"
              : "var mv=document.querySelector('meta[name=viewport]');"
                  "if(mv){mv.setAttribute('content','width=device-width, initial-scale=1.0');}";
          _ctl.runJavaScript(vp);
          }
          // v1595：自动提取模式——轮询提取（页面JS渲染榜单慢，固定2.5秒
          // 不可靠），每1.5秒试一次最多10次，出条目即返回；失败留本页手动兜底
          if (widget.autoExtract) {
            var tries = 0;
            Timer.periodic(const Duration(milliseconds: 1500), (t) {
              tries++;
              if (!mounted || _done) {
                t.cancel();
                return;
              }
              if (tries >= 10) {
                t.cancel();
                return;
              }
              _extract();
            });
          }
        },
      ))
      // v1612：接管渲染模式走原生抓取管线，其余直接加载。
      // v1618：loadHtmlString连续渲染ANR实证弃用——改本地代理伺服
      // （loadRequest=稳定路径），先起代理再loadRequest
      ..setUserAgent(widget.desktopUa ? _desktopUa : _mobileUa).then((_) async {
        if (widget.fetchRender) {
          final port = await RenderProxy.start();
          _blog('代理就绪：$port，加载${widget.url}');
          await _ctl.loadRequest(Uri.parse(RenderProxy.renderUrl(widget.url)));
        } else {
          _ctl.loadRequest(Uri.parse(widget.url));
        }
      });
  }

  static const _mobileUa =
      'Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Mobile Safari/537.36';
  // v1596：桌面UA——番茄手机UA=推广壳页
  static const _desktopUa =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36';

  /// v1603：换UA重载——切换手机/电脑版（UA骗服务器+viewport排布局，两道门都要换）。
  /// v1608：有mobileUrl时切换=换URL（各站手机版/电脑版是不同网址不同DOM）
  void _reload() {
    setState(() => _loading = true);
    _ctl.setUserAgent(_desktop ? _desktopUa : _mobileUa).then((_) async {
      // v1618：接管渲染模式切换=loadRequest代理渲染对应版本URL
      if (widget.fetchRender) {
        final target = _desktop
            ? (widget.desktopUrl ?? widget.url)
            : (widget.mobileUrl ?? widget.url);
        _blog('切换加载：$target');
        await _ctl.loadRequest(Uri.parse(RenderProxy.renderUrl(target)));
        return;
      }
      final u = _desktop
          ? (widget.desktopUrl ?? widget.url)
          : (widget.mobileUrl ?? widget.url);
      _ctl.loadRequest(Uri.parse(u));
    });
  }

  /// v1604b：ai=true时回传AI_READ::前缀——聊天页转交AI提取（读什么内容由AI判断，
  /// 不依赖各站DOM结构）；ai=false走原路：原始innerText直接回填楼层
  Future<void> _extract({bool ai = false}) async {
    if (_done) return;
    // v1611：JS禁用页提取不可用（innerText要走runJavaScript）
    if (!widget.enableJs) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('该页面已禁JS防死机，提取不可用——飞卢请用「飞卢·三榜」原生直抓')));
      }
      return;
    }
    try {
      // 全页innerText——榜单页导航杂讯Dart侧清洗，宽容优先（结构变了也不空转）
      final r = await _ctl.runJavaScriptReturningResult(
          'document.body.innerText');
      var text = r is String ? r : r.toString();
      // WebView返回JSON编码串（带首尾引号与转义），解一层
      if (text.startsWith('"')) {
        text = jsonDecode(text) as String;
      }
      text = text.trim();
      // v1595：七猫页面desktop布局黑屏不碍事——后台提取+清洗成紧凑条目
      if (widget.url.contains('qimao')) {
        text = MarketRank.cleanQimao(text);
        // 清洗后不足3条=榜单还没渲染出来，继续轮询
        final hits = RegExp(r'^\d+\. ', multiLine: true).allMatches(text);
        if (hits.length < 3) return;
      }
      if (text.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('页面内容为空——还没加载完，稍等再试')));
        }
        return;
      }
      if (text.length > 6000) text = text.substring(0, 6000);
      _done = true;
      if (mounted) {
        Navigator.pop(context, ai ? 'AI_READ::$text' : text);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('提取失败：$e')));
      }
    }
  }

  /// v1606：地址栏跳转——无scheme补https://，非法输入不动作
  void _goUrl(String v) {
    final u = v.trim();
    if (u.isEmpty) return;
    final url = u.startsWith('http') ? u : 'https://$u';
    setState(() => _loading = true);
    _ctl.loadRequest(Uri.parse(url));
    FocusScope.of(context).unfocus();
  }

  @override
  Widget build(BuildContext context) {
    // v1606：系统返回键接管——网页能退就退网页，退不动才退出浏览器
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (await _ctl.canGoBack()) {
          _ctl.goBack();
        } else if (mounted) {
          Navigator.pop(context);
        }
      },
      child: Scaffold(
        appBar: AppBar(
          // v1607：显式关闭键——直接退出浏览器回APP（左上角默认箭头被
          // 返回键接管逻辑影响=先退网页历史，语义混淆）
          leading: IconButton(
            icon: const Text('✕', style: TextStyle(fontSize: 18)),
            onPressed: () => Navigator.pop(context),
          ),
          title: Text(widget.title, overflow: TextOverflow.ellipsis),
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(44),
            child: Row(children: [
              TextButton(
                onPressed: _canBack ? () => _ctl.goBack() : null,
                child: const Text('←'),
              ),
              TextButton(
                onPressed: _canFwd ? () => _ctl.goForward() : null,
                child: const Text('→'),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 4, vertical: 6),
                  child: TextField(
                    controller: _urlCtl,
                    keyboardType: TextInputType.url,
                    textInputAction: TextInputAction.go,
                    onSubmitted: _goUrl,
                    style: const TextStyle(fontSize: 12),
                    decoration: const InputDecoration(
                      hintText: '输入网址',
                      isDense: true,
                      border: OutlineInputBorder(),
                      contentPadding:
                          EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                    ),
                  ),
                ),
              ),
            ]),
          ),
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
            // v1603：手机/电脑版切换——换UA重载+对应viewport注入
            TextButton(
              onPressed: () {
                _desktop = !_desktop;
                _reload();
              },
              child: Text(_desktop ? '切手机版' : '切电脑版'),
            ),
            // 刷新（重载页面）——v1618：接管渲染模式重走代理加载当前目标
            TextButton(
              onPressed: () {
                setState(() => _loading = true);
                if (widget.fetchRender) {
                  _ctl.loadRequest(Uri.parse(RenderProxy.renderUrl(
                      _urlCtl.text.startsWith('http')
                          ? _urlCtl.text
                          : widget.url)));
                } else {
                  _ctl.reload();
                }
              },
              child: const Text('刷新'),
            ),
            // v1611：JS禁用页提取不可用（innerText要走JS），键直接隐藏
            if (widget.enableJs) ...[
              // v1604b：AI读页——innerText交聊天页AI自行提取需要的内容
              TextButton(
                onPressed: () => _extract(ai: true),
                child: const Text('AI读页'),
              ),
              if (widget.extractable)
                TextButton(
                  onPressed: _extract,
                  child: const Text('提取榜单'),
                ),
            ],
          ],
        ],
        ),
        body: WebViewWidget(controller: _ctl),
      ),
    );
  }
}
