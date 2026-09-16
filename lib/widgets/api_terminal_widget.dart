import 'dart:ui' show FontFeature;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../utils/v469_style.dart';

import '../state/app_state.dart';

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

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
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
