import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../utils/v469_style.dart';

/// 统一API终端面板 — 照抄v468每个功能卡片底部的api-step-log样式
/// 各页面共用：日志（可复制）+ 状态行 + 计时 + 终止按钮 + 清空 + 折叠
class ApiLogPanel extends StatefulWidget {
  final List<String> logs;
  final String statusText; // 状态行（正在xxx...）
  final bool isRunning; // 运行中→显示终止按钮+计时
  final VoidCallback? onAbort; // 终止回调
  final String title; // 面板标题

  const ApiLogPanel({
    super.key,
    required this.logs,
    this.statusText = '',
    this.isRunning = false,
    this.onAbort,
    this.title = '终端',
  });

  @override
  State<ApiLogPanel> createState() => _ApiLogPanelState();
}

class _ApiLogPanelState extends State<ApiLogPanel> {
  final ScrollController _scrollCtrl = ScrollController();
  // v289：初始状态按条数定（多行展开/单行折叠），后续由didUpdateWidget按新日志条数自动切换
  bool _expanded = false;
  Timer? _timer;
  int _elapsed = 0; // 任务耗时（秒），结束后保留显示
  // 日志签名：长度|末行内容（父页传同一可变List，长度比对恒false；
  // 封顶100条removeAt(0)后长度不变。签名才能捕获真实变化）
  String _logSig = '';

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollCtrl.hasClients) {
        _scrollCtrl.jumpTo(_scrollCtrl.position.maxScrollExtent);
      }
    });
  }

  @override
  void initState() {
    super.initState();
    // 初始已有日志：多行展开
    _expanded = widget.logs.length > 1;
    _logSig = widget.logs.isEmpty
        ? '0|'
        : '${widget.logs.length}|${widget.logs.last}';
  }

  @override
  void didUpdateWidget(covariant ApiLogPanel old) {
    super.didUpdateWidget(old);
    // 新日志进来自动滚到最新（v469：appendChild后scrollTop=scrollHeight）
    final sig = widget.logs.isEmpty
        ? '0|'
        : '${widget.logs.length}|${widget.logs.last}';
    if (sig != _logSig) {
      _logSig = sig;
      // v289：多行自动展开，只有一行时自动折叠（用户手动展开/折叠后仍以条数为准）
      final shouldExpand = widget.logs.length > 1;
      if (_expanded != shouldExpand) {
        _expanded = shouldExpand;
      }
      if (_expanded) _scrollToBottom();
    }
    // 任务开始→计时归零每秒跳；结束→停表保留最终耗时
    if (widget.isRunning && !old.isRunning) {
      _elapsed = 0;
      _timer?.cancel();
      _timer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() => _elapsed++);
      });
    } else if (!widget.isRunning && old.isRunning) {
      _timer?.cancel();
      _timer = null;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _scrollCtrl.dispose();
    super.dispose();
  }

  String get _elapsedLabel {
    if (_elapsed < 60) return '${_elapsed}s';
    final m = _elapsed ~/ 60;
    final s = _elapsed % 60;
    return '${m}m${s.toString().padLeft(2, '0')}s';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        // 标题行：终端 + 状态 + 计时 + 终止/清空/折叠
        Row(
          children: [
            InkWell(
              onTap: () {
                setState(() => _expanded = !_expanded);
                // 展开时滚到最新
                if (_expanded && widget.logs.isNotEmpty) _scrollToBottom();
              },
              child: Row(
                children: [
                  Text(
                    _expanded ? '${widget.title} ▾' : '${widget.title} ▸',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: theme.colorScheme.primary,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            if (widget.statusText.isNotEmpty)
              Expanded(
                child: Text(
                  widget.statusText,
                  style: TextStyle(
                    fontSize: 11,
                    color: Colors.orange,
                    fontWeight: FontWeight.w500,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            // 计时：运行中橙色跳动，结束保留最终耗时
            if (widget.isRunning)
              Padding(
                padding: const EdgeInsets.only(left: 6),
                child: Text(
                  '⏱ $_elapsedLabel',
                  style: TextStyle(
                    fontSize: 11,
                    color: Colors.orange,
                    fontWeight: FontWeight.w600,
                    fontFamily: V469Style.monoFont, fontFamilyFallback: V469Style.monoFallback, // v200等宽+中文雅黑,
                  ),
                ),
              )
            else if (_elapsed > 0)
              Padding(
                padding: const EdgeInsets.only(left: 6),
                child: Text(
                  '耗时 $_elapsedLabel',
                  style: TextStyle(
                    fontSize: 11,
                    color: Colors.grey,
                    fontFamily: V469Style.monoFont, fontFamilyFallback: V469Style.monoFallback, // v200等宽+中文雅黑,
                  ),
                ),
              ),
            const Spacer(),
            // 复制按钮：一键复制全部日志（多行选择仍可用SelectableText）
            if (widget.logs.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(left: 6),
                child: SizedBox(
                  height: 26,
                  child: TextButton.icon(
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    icon: const Icon(Icons.copy, size: 14),
                    label: const Text('复制', style: TextStyle(fontSize: 11)),
                    onPressed: () async {
                      await Clipboard.setData(
                        ClipboardData(text: widget.logs.join('\n')),
                      );
                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text('已复制 ${widget.logs.length} 行日志'),
                            duration: const Duration(milliseconds: 900),
                          ),
                        );
                      }
                    },
                  ),
                ),
              ),
            // 终止按钮（运行中才显示）
            if (widget.isRunning && widget.onAbort != null)
              Padding(
                padding: const EdgeInsets.only(left: 6),
                child: SizedBox(
                  height: 26,
                  child: FilledButton.tonalIcon(
                    style: FilledButton.styleFrom(
                      backgroundColor: Colors.red.shade50,
                      foregroundColor: Colors.red,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                    ),
                    icon: const Icon(Icons.stop, size: 14),
                    label: const Text('终止', style: TextStyle(fontSize: 11)),
                    onPressed: widget.onAbort,
                  ),
                ),
              ),
          ],
        ),
        if (_expanded)
          Container(
            width: double.infinity,
            margin: const EdgeInsets.only(top: 4),
            constraints: const BoxConstraints(maxHeight: 110),
            decoration: BoxDecoration(
              color: const Color(0xFF1E1E1E),
              borderRadius: BorderRadius.circular(6),
            ),
            child: widget.logs.isEmpty
                ? Padding(
                    padding: const EdgeInsets.all(8),
                    child: Text(
                      '等待操作...',
                      style: TextStyle(
                        fontSize: 11,
                        color: Color(0xFF6B7280),
                        fontFamily: V469Style.monoFont, fontFamilyFallback: V469Style.monoFallback, // v200等宽+中文雅黑,
                      ),
                    ),
                  )
                : Scrollbar(
                    controller: _scrollCtrl,
                    child: ListView.builder(
                      controller: _scrollCtrl,
                      padding: const EdgeInsets.all(8),
                      itemCount: widget.logs.length,
                      itemBuilder: (c, i) => SelectableText(
                        widget.logs[i],
                        style: TextStyle(
                          fontSize: 11,
                          height: 1.5,
                          color: Color(0xFF9CDCFE),
                          fontFamily: V469Style.monoFont, fontFamilyFallback: V469Style.monoFallback, // v200等宽+中文雅黑,
                        ),
                      ),
                    ),
                  ),
          ),
      ],
    );
  }
}
