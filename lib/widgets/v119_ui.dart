import 'package:flutter/material.dart';

/// v119新UI公共组件库
/// 设计原则：内容为王，控件让路。
/// - 顶行：唯一一行高频操作按钮（小描边样式）
/// - API设置：收进底部抽屉（不占布局空间）
/// - 长文本：限定高度框内滚动

/// 小描边按钮（文字描个边，紧凑）
class MiniButton extends StatelessWidget {
  final String label;
  final VoidCallback? onTap;
  final bool primary;
  final bool danger;

  const MiniButton({
    super.key,
    required this.label,
    this.onTap,
    this.primary = false,
    this.danger = false,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    if (primary) {
      return Material(
        color: onTap == null ? cs.surfaceContainerHighest : cs.primaryContainer,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            child: Text(
              label,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w500,
                color: onTap == null ? Colors.grey : cs.primary,
              ),
            ),
          ),
        ),
      );
    }
    if (danger) {
      return Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              border: Border.all(color: Colors.red.withOpacity(0.6)),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              label,
              style: const TextStyle(fontSize: 11, color: Colors.red),
            ),
          ),
        ),
      );
    }
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            border: Border.all(
              color: onTap == null
                  ? Colors.grey.withOpacity(0.3)
                  : cs.outline.withOpacity(0.5),
            ),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 11,
              color: onTap == null ? Colors.grey : cs.onSurface,
            ),
          ),
        ),
      ),
    );
  }
}

/// 底部抽屉（API设置等收纳，不占布局空间）
void showV119Sheet(
  BuildContext context, {
  required String title,
  required Widget child,
}) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    constraints: const BoxConstraints(maxWidth: 640),
    builder: (ctx) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.75,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      builder: (ctx, scrollController) => Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close, size: 18),
                  onPressed: () => Navigator.pop(ctx),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: SingleChildScrollView(
              controller: scrollController,
              child: child,
            ),
          ),
        ],
      ),
    ),
  );
}

/// 长文本面板（限定高度框内滚动，类似电子书高度）
class TextPanel extends StatelessWidget {
  final String text;
  final double maxHeight;
  final double minHeight;
  final Color? background;
  final bool selectable;

  const TextPanel({
    super.key,
    required this.text,
    this.maxHeight = 320,
    this.minHeight = 100,
    this.background,
    this.selectable = true,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      constraints: BoxConstraints(maxHeight: maxHeight, minHeight: minHeight),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color:
            background ??
            Theme.of(context).colorScheme.surfaceContainerHighest
                .withOpacity(0.4),
        borderRadius: BorderRadius.circular(8),
      ),
      child: SingleChildScrollView(
        child: selectable
            ? SelectableText(
                text,
                style: const TextStyle(fontSize: 13, height: 1.7),
              )
            : Text(text, style: const TextStyle(fontSize: 13, height: 1.7)),
      ),
    );
  }
}

/// 可读宽度容器：宽屏时限宽居中（防文字拉成超长单行），窄屏全宽
class ReadableWidth extends StatelessWidget {
  final Widget child;
  final double maxWidth;

  const ReadableWidth({super.key, required this.child, this.maxWidth = 620});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: child,
      ),
    );
  }
}

/// 自动置顶展开瓦片：展开时折叠键行滚到可视区顶部，内容区高度自适应可滚动
/// 用于替代普通ExpansionTile（长内容场景）
class AutoExpansionTile extends StatefulWidget {
  final String title;
  final Widget? leading;
  final List<Widget> children;
  final bool initiallyExpanded;
  final bool dense;

  const AutoExpansionTile({
    super.key,
    required this.title,
    required this.children,
    this.leading,
    this.initiallyExpanded = false,
    this.dense = true,
  });

  @override
  State<AutoExpansionTile> createState() => _AutoExpansionTileState();
}

class _AutoExpansionTileState extends State<AutoExpansionTile> {
  bool _expanded = false;
  final GlobalKey _headerKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    _expanded = widget.initiallyExpanded;
  }

  void _toggle() async {
    setState(() => _expanded = !_expanded);
    if (_expanded) {
      // 展开后下一帧：把折叠键行滚动到可视区顶部（便于随时折叠）
      await Future.delayed(const Duration(milliseconds: 60));
      if (!mounted) return;
      final ctx = _headerKey.currentContext;
      if (ctx != null) {
        await Scrollable.ensureVisible(
          ctx,
          alignment: 0.0,
          duration: const Duration(milliseconds: 250),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      key: _headerKey,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: _toggle,
          child: Container(
            width: double.infinity,
            padding: EdgeInsets.symmetric(
              horizontal: 12,
              vertical: widget.dense ? 6 : 10,
            ),
            child: Row(
              children: [
                if (widget.leading != null) ...[
                  widget.leading!,
                  const SizedBox(width: 6),
                ],
                Expanded(
                  child: Text(
                    widget.title,
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                Icon(
                  _expanded ? Icons.expand_less : Icons.expand_more,
                  size: 18,
                  color: Colors.grey[600],
                ),
              ],
            ),
          ),
        ),
        if (_expanded) Column(children: widget.children),
      ],
    );
  }
}

