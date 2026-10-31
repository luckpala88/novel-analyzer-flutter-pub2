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
  final bool compact; // v990：更紧凑（聊天页气泡操作行用）
  final bool? enabled; // v993：强制可用外观（PopupMenu包裹的键onTap=null但可用）

  const MiniButton({
    super.key,
    required this.label,
    this.onTap,
    this.primary = false,
    this.danger = false,
    this.compact = false,
    this.enabled,
  });

  /// v993：可用外观判断——enabled显式指定优先，否则由onTap推断
  bool get _looksEnabled => enabled ?? (onTap != null);

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    if (primary) {
      return Material(
        color: _looksEnabled ? cs.primaryContainer : cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            child: Text(
              label,
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w500,
                color: _looksEnabled ? cs.primary : Colors.grey,
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
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              border: Border.all(color: Colors.red.withOpacity(0.6)),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              label,
              style: const TextStyle(fontSize: 10, color: Colors.red),
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
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            border: Border.all(
              color: _looksEnabled
                  ? cs.outline.withOpacity(0.5)
                  : Colors.grey.withOpacity(0.3),
            ),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 10,
              color: _looksEnabled ? cs.onSurface : Colors.grey,
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


/// v952：作家风格选择按钮（三页复用：创作/改编/二创）——MiniButton显示当前
/// 作家名（未选="🎭作家"），点击弹底部档案清单（含"不启用"），选定即全局
/// 生效（state.setWriterStyle持久化，四链sys注入writerStyleBlock）
Widget writerStyleButton(BuildContext context, dynamic state) {
  final sel = state.selectedWriterStyle as String;
  return MiniButton(
    label: sel.isEmpty ? '作家' : sel,
    primary: sel.isNotEmpty,
    onTap: () async {
      final styles = state.styleProfiles as List<Map<String, String>>;
      final picked = await showModalBottomSheet<String>(
        context: context,
        builder: (ctx) => SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              const Padding(
                padding: EdgeInsets.all(12),
                child: Text('选择作家风格（全局生效：创作/改编/二创）',
                    style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
              ),
              for (final s in styles)
                ListTile(
                  dense: true,
                  title: Text('🎭 ${s['name']}'),
                  subtitle: Text(
                      '${s['content']?.length ?? 0}字 · ${s['updatedAt']}',
                      style: const TextStyle(fontSize: 11)),
                  trailing: sel == s['name']
                      ? const Icon(Icons.check, size: 18)
                      : null,
                  onTap: () => Navigator.pop(ctx, s['name']),
                  // v1197：长按删除档案（确认框防误删；删除后提示）
                  onLongPress: () async {
                    Navigator.pop(ctx);
                    final ok = await showDialog<bool>(
                      context: context,
                      builder: (dctx) => AlertDialog(
                        title: Text('删除作家档案「${s['name']}」？',
                            style: const TextStyle(fontSize: 15)),
                        actions: [
                          TextButton(
                              onPressed: () => Navigator.pop(dctx, false),
                              child: const Text('取消')),
                          TextButton(
                              onPressed: () => Navigator.pop(dctx, true),
                              child: const Text('删除',
                                  style: TextStyle(color: Colors.red))),
                        ],
                      ),
                    );
                    if (ok == true) {
                      state.deleteStyleProfile(s['name']);
                    }
                  },
                ),
              const Divider(height: 1),
              ListTile(
                dense: true,
                leading: const Icon(Icons.block, size: 18),
                title: const Text('不启用', style: TextStyle(fontSize: 13)),
                onTap: () => Navigator.pop(ctx, ''),
              ),
            ],
          ),
        ),
      );
      if (picked != null) state.setWriterStyle(picked);
    },
  );
}

/// v1279：七字段彩色渲染——【字段头】按字段语义配色加粗，字段内容正文色
/// 数据层纯文本零emoji原则不变：颜色只在浏览层渲染，不进数据
class FieldColoredText extends StatelessWidget {
  final String text;
  final double fontSize;
  final double height;
  final Color baseColor;
  /// v1287：渲染变体——'scene'=场景概述字段统一金棕 / 'arc'=弧线概述字段统一靛蓝
  final String variant;

  const FieldColoredText({
    super.key,
    required this.text,
    required this.fontSize,
    required this.height,
    required this.baseColor,
    this.variant = 'scene',
  });

  /// v1287：字段头色按变体统一——弧线级靛蓝/场景级金棕（用户裁决：弧线八字段一色、场景八字段另一色）
  static Color fieldColor(String variant) {
    return variant == 'arc'
        ? const Color(0xFF1D4ED8) // 靛蓝：弧线级编排字段
        : const Color(0xFFB45309); // 金棕：场景级字段（暖主题）
  }

  @override
  Widget build(BuildContext context) {
    final spans = <TextSpan>[];
    // v1304：换行兜底——AI输出字段头前无换行（【期望演进】粘在上行尾部）
    // 组件级统一修复：所有页面（分镜/场景/世界书/改编）一次生效
    final fixedText = text
        .replaceAll(RegExp('([^\\n])【'), '\$1\n【')
        .replaceAll(RegExp('(弧线\\d+概述[：:])(?=[^\\n])'), '\$1\n');
    // v1302：按行预处理——行首[体系名]紫标签/行首「功能：」灰字（世界书
    // head区facts样式对齐分镜页），行内再跑【】字段逻辑
    final lineReg = RegExp(r'^\[([^\]\n]{1,10})\]\s*');
    for (final line in fixedText.split('\n')) {
      final lm = lineReg.firstMatch(line);
      if (lm != null) {
        spans.add(TextSpan(
          text: '[${lm.group(1)}] ',
          style: TextStyle(
            fontSize: fontSize,
            fontWeight: FontWeight.w700,
            color: const Color(0xFF8B5CF6), // 紫：体系标签（分镜页同款）
          ),
        ));
        spans.add(TextSpan(
          text: line.substring(lm.end),
          style: TextStyle(
              fontSize: fontSize, height: height, color: baseColor),
        ));
        spans.add(const TextSpan(text: '\n'));
        continue;
      }
      if (line.startsWith('功能：') || line.startsWith('功能:')) {
        spans.add(TextSpan(
          text: '　$line',
          style: TextStyle(
            fontSize: fontSize - 0.5,
            height: height,
            color: baseColor.withOpacity(0.75), // 灰：功能说明行
          ),
        ));
        spans.add(const TextSpan(text: '\n'));
        continue;
      }
      _buildLineSpans(line, spans, fontSize, height, baseColor, variant);
    }
    return RichText(
      textScaler: MediaQuery.textScalerOf(context),
      text: TextSpan(children: spans),
    );
  }

  /// 单行内【字段】标签切分（v1279逻辑抽出）
  void _buildLineSpans(String text, List<TextSpan> spans, double fontSize,
      double height, Color baseColor, String variant) {
    // v1291：弧线N概述：标签行也按variant色渲染（世界书head区）
    final reg = RegExp(r'弧线\d+概述：|【[^】]{1,12}】');
    int last = 0;
    for (final m in reg.allMatches(text)) {
      if (m.start > last) {
        spans.add(TextSpan(
          text: text.substring(last, m.start),
          style: TextStyle(fontSize: fontSize, height: height, color: baseColor),
        ));
      }
      final tag = m.group(0)!;
      spans.add(TextSpan(
        text: tag,
        style: TextStyle(
          fontSize: fontSize,
          height: height,
          color: fieldColor(variant),
          fontWeight: FontWeight.w700,
        ),
      ));
      last = m.end;
    }
    if (last < text.length) {
      spans.add(TextSpan(
        text: text.substring(last),
        style: TextStyle(fontSize: fontSize, height: height, color: baseColor),
      ));
    }
  }
}
