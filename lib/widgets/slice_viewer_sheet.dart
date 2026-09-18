import 'package:flutter/material.dart';

import 'content_font.dart';

/// v352：切片/范文/弧线正文查看底板（全宽+A-/A+字号记忆）
/// 统一弧线页/场景页/创作页的文本查看弹窗：
/// - 宽度：底部弹出全宽（手机上尽量利用屏宽）
/// - 字号：ContentFont('slice')持久化，跨会话记住
/// - 文本：SelectableText可复制
void showSliceViewerSheet(
  BuildContext context, {
  required String title,
  required String text,
  String emptyHint = '（无内容）',
}) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => _SliceViewerBody(title: title, text: text, emptyHint: emptyHint),
  );
}

class _SliceViewerBody extends StatefulWidget {
  final String title;
  final String text;
  final String emptyHint;
  const _SliceViewerBody({
    required this.title,
    required this.text,
    required this.emptyHint,
  });

  @override
  State<_SliceViewerBody> createState() => _SliceViewerBodyState();
}

class _SliceViewerBodyState extends State<_SliceViewerBody> {
  double _scale = 1.0;

  @override
  void initState() {
    super.initState();
    ContentFont.load('slice').then((v) {
      if (mounted) setState(() => _scale = v);
    });
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    return SizedBox(
      height: media.size.height * 0.85,
      width: media.size.width, // 全宽
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 8, 4),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    widget.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w600),
                  ),
                ),
                // v352：字号调节（ContentFont('slice')持久化）
                ContentFontButtons(
                  pageKey: 'slice',
                  scale: _scale,
                  onChanged: (v) {
                    ContentFont.save('slice', v);
                    setState(() => _scale = v);
                  },
                ),
                IconButton(
                  icon: const Icon(Icons.close, size: 18),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            // v352：字号经ContentFont.area等比缩放（显式fontSize也生效）
            child: ContentFont.area(
              context,
              scale: _scale,
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
                child: SelectionArea(
                  child: Text(
                    widget.text.isEmpty ? widget.emptyHint : widget.text,
                    style: const TextStyle(fontSize: 13, height: 1.6),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
