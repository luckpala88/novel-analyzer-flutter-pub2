import 'dart:ui' show FontFeature;
import 'dart:io'; // v1477：导出图File/Directory

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../utils/v469_style.dart';

import 'dart:convert';
import 'package:http/http.dart' as http;
import '../state/app_state.dart';
import 'package:path_provider/path_provider.dart'; // v1477：导出图定位chat_images
import '../pages/home_page.dart' show diagTokenRef;

/// 全局API终端组件 — 顶部固定，可折叠
/// 显示API日志+计时器+生成状态，所有页面共享
class ApiTerminalWidget extends StatefulWidget {
  const ApiTerminalWidget({super.key});

  @override
  State<ApiTerminalWidget> createState() => _ApiTerminalWidgetState();
}

class _ApiTerminalWidgetState extends State<ApiTerminalWidget> {
  bool _expanded = false;
  final _scrollController = ScrollController();
  // v1476：日志与全局notify解耦——apiLog不再notifyListeners（08:12死机日志
  // 实证：notify→context.watch全页rebuild重走MJ楼层渲染链=主线程卡死）。
  // 终端自己监听logRevision+计时器Notifier精准刷新，不再watch AppState。
  AppState? _state;

  void _refresh() {
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    _state = AppState.instance
      ..logRevision.addListener(_refresh)
      ..apiTimerRunning.addListener(_refresh)
      ..apiTimerSeconds.addListener(_refresh)
      ..addListener(_refresh); // 生成状态generationMessage等仍走全局notify
  }

  @override
  void dispose() {
    _state?.logRevision.removeListener(_refresh);
    _state?.apiTimerRunning.removeListener(_refresh);
    _state?.apiTimerSeconds.removeListener(_refresh);
    _state?.removeListener(_refresh);
    _scrollController.dispose();
    super.dispose();
  }

  /// v1359：诊断日志上传——apiLogs全量+版本号→私有仓logs/目录（Contents API）
  Future<void> _uploadDiagLog(BuildContext context, AppState state) async {
    final ver = DateTime.now();
    // v1373：文件名精确到毫秒——分钟级stamp同分钟二传撞同名无sha=422
    final stamp =
        '${ver.year}${ver.month.toString().padLeft(2, '0')}${ver.day.toString().padLeft(2, '0')}_${ver.hour.toString().padLeft(2, '0')}${ver.minute.toString().padLeft(2, '0')}${ver.second.toString().padLeft(2, '0')}${ver.millisecond.toString().padLeft(3, '0')}';
    // v1360b：脱敏（pub2公开仓——key/token类串替换）
    String mask(String l) => l
        .replaceAll(RegExp(r'sk-[A-Za-z0-9_-]{8,}'), 'sk-***')
        .replaceAll(RegExp(r'cfut-[A-Za-z0-9_-]{8,}'), 'cfut-***')
        .replaceAll(RegExp(r'Bearer [A-Za-z0-9_.-]{8,}'), 'Bearer ***')
        .replaceAll(RegExp(r'token[=: ]+[A-Za-z0-9_.-]{12,}', caseSensitive: false), 'token=***');
    // v1362：单文件限150KB——从最新行往回取（先进先出，旧的丢）
    final buf = <String>['== 诊断日志 $stamp =='];
    var size = buf.first.length;
    for (final l in state.apiLogs) {
      final m = mask(l);
      size += m.length + 1;
      if (size > 150 * 1024) break; // 超限即停，保留最新
      buf.add(m);
    }
    final body = buf.join('\n');
    final content = base64Encode(utf8.encode(body));
    try {
      final token2 = _diagToken();
      if (token2 == null || token2.isEmpty) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('无上传凭证（token未注入）')),
          );
        }
        return;
      }
      final url = Uri.parse(
          'https://api.github.com/repos/luckpala88/novel-analyzer-flutter-pub2/contents/logs/diag_$stamp.txt');
      final req = await http.put(url,
        headers: {
          'Authorization': 'Bearer $token2',
          'Accept': 'application/vnd.github+json',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'message': 'diag log $stamp',
          'content': content,
        }),
      );
      if (req.statusCode >= 200 && req.statusCode < 300) {
        // v1362：目录先进先出——只留最近5个日志文件
        try {
          final dirUrl = Uri.parse(
              'https://api.github.com/repos/luckpala88/novel-analyzer-flutter-pub2/contents/logs');
          final lr = await http.get(dirUrl, headers: {
            'Authorization': 'Bearer $token2',
            'Accept': 'application/vnd.github+json',
          });
          if (lr.statusCode == 200) {
            final list = (jsonDecode(lr.body) as List)
                .map((e) => {'name': e['name'] as String, 'sha': e['sha'] as String})
                .where((e) => (e['name'] as String).startsWith('diag_'))
                .toList()
              ..sort((a, b) => (a['name'] as String).compareTo(b['name'] as String));
            for (final f in list.take(list.length > 5 ? list.length - 5 : 0)) {
              await http.delete(Uri.parse('$url'),
                  headers: {
                    'Authorization': 'Bearer $token2',
                    'Accept': 'application/vnd.github+json',
                    'Content-Type': 'application/json',
                  },
                  body: jsonEncode({'message': 'cleanup old', 'sha': f['sha']}));
            }
          }
        } catch (_) {} // 清理失败不影响上传结果
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('日志已上传（${buf.length - 1}行）'),
              duration: const Duration(milliseconds: 1500),
            ),
          );
        }
      } else {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('上传失败：HTTP ${req.statusCode}'),
              duration: const Duration(milliseconds: 1500),
            ),
          );
        }
      }
    } catch (ex) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('上传异常：$ex')),
        );
      }
    }
  }

  String? _diagToken() {
    // home_page.UpdatePanel.diagToken（public static const）——import获取
    return diagTokenRef;
  }

  /// v1477：导出聊天图缓存到公共目录——排查四格切分产物
  /// （APP私有目录/data/data下文件管理器进不去，拷到storage.baseDirPath人工看图）
  Future<void> _exportGridImages(AppState state) async {
    try {
      final docs = (await getApplicationDocumentsDirectory()).path;
      final src = Directory('$docs/chat_images');
      if (!src.existsSync()) {
        state.apiLog('导出图失败：chat_images目录不存在');
        return;
      }
      final base = state.storage.baseDirPath;
      if (base.isEmpty) {
        state.apiLog('导出图失败：公共目录未配置（先在存储模式选公共目录）');
        return;
      }
      final dst = Directory('$base/chat_images_export');
      if (!dst.existsSync()) dst.createSync(recursive: true);
      var n = 0;
      for (final f in src
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.png'))) {
        final name = f.uri.pathSegments.last;
        // 只导四格变体+正身相关的（_v0..v3及_composed），mj_tasks.json等不拷
        if (!name.contains('_v') && !name.contains('_composed')) continue;
        await f.copy('${dst.path}/$name');
        n++;
      }
      state.apiLog('✓ 已导出$n张图到：$base/chat_images_export');
    } catch (e) {
      state.apiLog('导出图异常: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = _state ?? context.read<AppState>(); // v1476：不再watch
    final hasActivity =
        state.apiLogs.isNotEmpty ||
        state.apiTimerRunning.value ||
        state.apiTimerSeconds.value > 0 ||
        state.terminalPinned; // 清理（清屏）后终端保持显示，不自动隐藏
    if (!hasActivity) return const SizedBox.shrink();

    // 最新日志行（折叠时显示；清屏后空终端提示）
    final lastLog = state.apiLogs.isNotEmpty
        ? state.apiLogs.last
        : '（已清屏，等待新日志...）';

    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      margin: const EdgeInsets.only(bottom: 4),
      decoration: BoxDecoration(
        color: const Color(0xF016162A),
        borderRadius: BorderRadius.circular(_expanded ? 10 : 14),
        border: Border.all(color: Colors.grey[800]!, width: 0.5),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.3),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      constraints: BoxConstraints(maxHeight: _expanded ? 160 : 28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 标题栏（始终显示）
          GestureDetector(
            onTap: () => setState(() => _expanded = !_expanded),
            child: Container(
              height: 28,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              color: const Color(0xFF16162A),
              child: ListenableBuilder(
                // v203：计时tick只重建这一行（原来全App每秒重建10次）
                listenable: Listenable.merge([
                  state.apiTimerRunning,
                  state.apiTimerSeconds,
                ]),
                builder: (context, _) => Row(
                  children: [
                  // 计时器
                  if (state.apiTimerRunning.value ||
                      state.apiTimerSeconds.value > 0)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: Text(
                        state.apiTimerRunning.value
                            ? '⏱ ${state.apiTimerSeconds.value.toStringAsFixed(1)}s'
                            : '⏱ ${state.apiTimerSeconds.value.toStringAsFixed(1)}s ✓',
                        style: TextStyle(
                          fontSize: 11,
                          color: state.apiTimerRunning.value
                              ? const Color(0xFFFFD700)
                              : const Color(0xFF00FF88),
                          fontFamily: V469Style.monoFont, fontFamilyFallback: V469Style.monoFallback, // v200等宽+中文雅黑,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ),
                  // 最新日志（折叠时）
                  Expanded(
                    child: Text(
                      _expanded ? 'API终端' : lastLog,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        color: const Color(0xFF00FF00),
                        fontFamily: V469Style.monoFont, fontFamilyFallback: V469Style.monoFallback, // v200等宽+中文雅黑,
                      ),
                    ),
                  ),
                  // 终止按钮（计时运行中随时可停）
                  if (state.apiTimerRunning.value)
                    Padding(
                      padding: const EdgeInsets.only(left: 6),
                      child: GestureDetector(
                        onTap: () {
                          state.api.abort();
                          state.apiLog('⏹ 用户按下终止，等待中断...');
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(0xFFDC2626),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: const Text(
                            '终止',
                            style: TextStyle(
                              fontSize: 10,
                              color: Colors.white,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                    ),
                  // 复制全部信息按钮（展开且有日志时显示）
                  if (_expanded && state.apiLogs.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(left: 6),
                      child: GestureDetector(
                        onTap: () async {
                          await Clipboard.setData(
                            ClipboardData(
                              text: state.apiLogs.reversed.join('\n'),
                            ),
                          );
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(
                                  '已复制 ${state.apiLogs.length} 行终端信息',
                                ),
                                duration: const Duration(milliseconds: 900),
                              ),
                            );
                          }
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(0xFF2563EB),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: const Text(
                            '复制全部',
                            style: TextStyle(
                              fontSize: 10,
                              color: Colors.white,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                    ),
                  // v1359：诊断日志上传键（一键传私有仓，云端助手拉取分析）
                  if (_expanded && state.apiLogs.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(left: 6),
                      child: GestureDetector(
                        onTap: () => _uploadDiagLog(context, state),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(0xFFB45309),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: const Text(
                            '传日志',
                            style: TextStyle(
                              fontSize: 10,
                              color: Colors.white,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                    ),
                  // v1477：导出四格图（排查切分产物——拷到公共目录人工看图）
                  if (_expanded)
                    Padding(
                      padding: const EdgeInsets.only(left: 6),
                      child: GestureDetector(
                        onTap: () => _exportGridImages(state),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(0xFF6B7280),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: const Text(
                            '导出图',
                            style: TextStyle(
                              fontSize: 10,
                              color: Colors.white,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                    ),
                  // 清理按钮（展开时显示，运行中禁用）
                  if (_expanded)
                    Padding(
                      padding: const EdgeInsets.only(left: 6),
                      child: GestureDetector(
                        onTap: state.apiTimerRunning.value
                            ? null
                            : () => state.clearApiLogs(),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: state.apiTimerRunning.value
                                ? const Color(0xFF374151)
                                : const Color(0xFF6B7280),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: const Text(
                            '清理',
                            style: TextStyle(
                              fontSize: 10,
                              color: Colors.white,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                    ),
                  // 日志条数
                  if (state.apiLogs.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(left: 4),
                      child: Text(
                        '${state.apiLogs.length}',
                        style: TextStyle(fontSize: 10, color: Colors.grey[500]),
                      ),
                    ),
                  // 展开/折叠图标
                  Icon(
                    _expanded
                        ? Icons.keyboard_arrow_up
                        : Icons.keyboard_arrow_down,
                    size: 16,
                    color: Colors.grey[500],
                  ),
                  ],
                ),
              ),
            ),
          ),
          // 展开时的日志列表
          if (_expanded)
            Expanded(
              child: ListView.builder(
                controller: _scrollController,
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                itemCount: state.apiLogs.length,
                itemBuilder: (ctx, i) {
                  final idx = state.apiLogs.length - 1 - i;
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 0.5),
                    child: SelectableText(
                      state.apiLogs[idx],
                      style: TextStyle(
                        fontSize: 11,
                        color: Color(0xFF00FF00),
                        fontFamily: V469Style.monoFont, fontFamilyFallback: V469Style.monoFallback, // v200等宽+中文雅黑,
                        height: 1.4,
                      ),
                    ),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}
