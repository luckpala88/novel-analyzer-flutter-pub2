import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';

import '../services/screen_capture.dart';
import '../state/app_state.dart';

/// v1594：屏捕取榜页——授权录屏→跳番茄APP→用户手动翻榜单页（后台每5秒
/// 自动截帧，画面没变跳过）→回来点停止→逐帧喂GLM-4V提取榜单文字→
/// 去重合并返回聊天楼层。番茄字体反爬下OCR读像素是唯一明文通道
class ScreenCapturePage extends StatefulWidget {
  const ScreenCapturePage({super.key});

  @override
  State<ScreenCapturePage> createState() => _ScreenCapturePageState();
}

class _ScreenCapturePageState extends State<ScreenCapturePage> {
  bool _running = false;
  int _frames = 0;
  bool _extracting = false;
  String _progress = '';
  Timer? _poll;
  final _keyCtl = TextEditingController();

  @override
  void initState() {
    super.initState();
    // v1637：预填历史key——屏捕key持久化（zhipu_vision.key），只填一次
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final k = context.read<AppState>().zhipuVisionKey;
      if (k.isNotEmpty && _keyCtl.text.isEmpty) _keyCtl.text = k;
    });
  }

  @override
  void dispose() {
    _poll?.cancel();
    _keyCtl.dispose();
    super.dispose();
  }

  void _startPolling() {
    _poll?.cancel();
    _poll = Timer.periodic(const Duration(seconds: 1), (_) async {
      final st = await ScreenCapture.status();
      if (!mounted) return;
      setState(() {
        _running = st['running'] == true;
        _frames = (st['frames'] as num?)?.toInt() ?? 0;
      });
      if (!_running) _poll?.cancel();
    });
  }

  /// v1638：屏捕链路日志——整链此前零埋点，统一走apiLog（📷前缀）
  void _slog(String m) => context.read<AppState>().apiLog('📷 $m');

  Future<void> _start() async {
    _slog('授权请求中…');
    final ok = await ScreenCapture.startCapture();
    if (!mounted) return;
    _slog(ok ? '授权通过，跳番茄APP' : '⛔ 未授权录屏/启动失败');
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('⛔ 未授权录屏，无法屏捕')));
      return;
    }
    setState(() => _running = true);
    _startPolling();
    // 跳番茄APP（com.dragon.read）；未装则留在本页提示
    final opened = await ScreenCapture.openApp('com.dragon.read');
    if (!mounted) return;
    if (!opened) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('⚠️ 番茄小说APP未安装——请手动打开目标页面，翻完回来点停止')));
    }
  }

  Future<void> _stopAndExtract() async {
    _poll?.cancel();
    final frames = await ScreenCapture.stopCapture();
    // v1638：屏捕链路日志——埋点走apiLog（📷前缀）
    _slog('停止采集：${frames.length}帧');
    if (!mounted) return;
    setState(() {
      _running = false;
      if (frames.isEmpty) _progress = '未采集到任何帧';
    });
    if (frames.isEmpty) {
      _slog('⚠️ 帧0——服务没跑起来或授权没给（看启动日志）');
      return;
    }
    // GLM-4V逐帧提取
    final state = context.read<AppState>();
    final cfg = state.getApiConfig('chat');
    var key = cfg.apiKey;
    if (cfg.providerId != 'zhipu') {
      // v1637：key持久化——TextField预填上次存的值，非空即存回（下次免填）
      key = _keyCtl.text.trim();
      if (key.isNotEmpty) state.setZhipuVisionKey(key);
      if (key.isEmpty) {
        key = state.zhipuVisionKey; // 本页空输入时回退用历史存的
        _keyCtl.text = key;
      }
      if (key.isEmpty) {
        setState(() =>
            _progress = '需要智谱Key——当前聊天API非智谱，请在下方粘贴（只需一次，之后自动记住）');
        return;
      }
    }
    setState(() => _extracting = true);
    final lines = <String>[];
    var i = 0;
    for (final b64 in frames) {
      i++;
      setState(() => _progress = 'GLM-4V提取中 $i/${frames.length}...');
      final sw = Stopwatch()..start();
      try {
        final text = await _ocrFrame(key, b64, slog);
        final got = text.split('\n')
            .map((l) => l.trim())
            .where((l) => l.isNotEmpty)
            .toList();
        _slog('第$i帧：${sw.elapsedMilliseconds}ms，${got.length}行，'
            '首行=${got.isEmpty ? '空' : got.first.substring(0, got.first.length > 24 ? 24 : got.first.length)}');
        lines.addAll(got);
      } catch (e) {
        _slog('⛔ 第$i帧失败：$e');
        // v1598：首帧失败即中止——参数级错误逐帧复现毫无意义（v1594实证
        // 一屏错误），用户裁决语义：失败一次就停
        if (!mounted) return;
        setState(() {
          _extracting = false;
          _progress = '⛔ 第$i帧提取失败即中止：$e';
        });
        return;
      }
    }
    if (!mounted) return;
    // 按行去重保序（不同帧同一条目只留一次）
    final seen = <String>{};
    final merged = lines.where((l) {
      final k = l.replaceAll(RegExp(r'\s+'), '');
      if (k.isEmpty || seen.contains(k)) return false;
      seen.add(k);
      return true;
    }).join('\n');
    _slog('汇总：${lines.length}行→去重${merged.isEmpty ? 0 : merged.split('\n').length}行');
    setState(() {
      _extracting = false;
      _progress = '';
    });
    if (merged.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('⚠️ 未提取到榜单内容——翻页时请停在榜单页')));
      return;
    }
    Navigator.pop(context, merged);
  }

  static const _ocrPrompt =
      '这是手机屏幕截图（番茄小说APP榜单页）。提取图中榜单的每一条：名次、书名、'
      '以及图中数据（在读/热度/收藏/字数等）。输出纯文本行，每行格式'
      '「N. 书名（数据）」，按图中顺序。只输出提取结果不要解释；'
      '图中没有榜单就只输出「无榜单」。';

  Future<String> _ocrFrame(
      String key, String b64, void Function(String) slog) async {
    final resp = await http.post(
      Uri.parse('https://open.bigmodel.cn/api/paas/v4/chat/completions'),
      headers: {
        'Authorization': 'Bearer $key',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({
        'model': 'glm-4v-flash',
        'temperature': 0.2,
        'max_tokens': 1024, // v1598：glm-4v-flash上限1024（2000参数非法实证）
        'messages': [
          {
            'role': 'user',
            'content': [
              {
                'type': 'image_url',
                'image_url': {'url': 'data:image/jpeg;base64,$b64'}
              },
              {'type': 'text', 'text': _ocrPrompt},
            ],
          }
        ],
      }),
    ).timeout(const Duration(seconds: 90));
    // v1638：HTTP层日志——非200直接带响应体前150字符（key无效/欠费/参数错
    // 都能从body定位，不再只有干巴巴的异常）
    if (resp.statusCode != 200) {
      final body = utf8.decode(resp.bodyBytes, allowMalformed: true);
      _slog('HTTP ${resp.statusCode}：${body.length > 150 ? body.substring(0, 150) : body}');
      throw Exception('HTTP ${resp.statusCode}');
    }
    final data = jsonDecode(utf8.decode(resp.bodyBytes)) as Map;
    if (data['error'] != null) {
      throw Exception(data['error']['message'] ?? data['error'].toString());
    }
    final choices = data['choices'] as List?;
    if (choices == null || choices.isEmpty) {
      _slog('⚠️ choices空（响应keys=${data.keys.toList()}）');
      return '';
    }
    return ((choices[0]['message']['content'] ?? '')).toString();
  }

  @override
  Widget build(BuildContext context) {
    final cfg = context.watch<AppState>().getApiConfig('chat');
    final needKey = cfg.providerId != 'zhipu';
    return Scaffold(
      appBar: AppBar(
        title: const Text('📷 屏捕取榜（番茄APP）'),
        actions: [
          if (_running || _extracting)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 12),
              child: Center(
                child: SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2)),
              ),
            ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(12),
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: const Color(0xFFEFE9DB),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Text(
                '流程：①点「开始屏捕」授权录屏 → 自动跳番茄APP → '
                '②你手动翻到榜单页，慢慢滚动（每5秒自动截1帧，画面没变不重复存，'
                '最多30帧）→ ③回到本APP点「停止并提取」→ GLM-4V逐帧识别入聊天。',
                style: TextStyle(fontSize: 12.5, height: 1.5),
              ),
            ),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(
                child: _running
                    ? ElevatedButton(
                        onPressed: _extracting ? null : _stopAndExtract,
                        child: Text('⏹ 停止并提取（已采$_frames帧）'))
                    : ElevatedButton(
                        onPressed: _extracting ? null : _start,
                        child: const Text('▶ 开始屏捕')),
              ),
            ]),
            if (_progress.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(_progress,
                    style: const TextStyle(fontSize: 12.5, color: Colors.brown)),
              ),
            if (needKey)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('⚠️ 当前聊天API非智谱——GLM-4V提取需要智谱Key（glm-4v-flash免费）：',
                        style: TextStyle(
                            fontSize: 12.5, color: Color(0xFFB06000))),
                    const SizedBox(height: 6),
                    TextField(
                      controller: _keyCtl,
                      obscureText: true,
                      decoration: const InputDecoration(
                        hintText: '粘贴智谱API Key',
                        isDense: true,
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
