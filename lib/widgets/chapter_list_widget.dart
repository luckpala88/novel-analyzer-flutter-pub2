import 'package:flutter/material.dart';

import '../models/chapter.dart';
import '../pages/chapter_reader_page.dart';

class ChapterListWidget extends StatefulWidget {
  final List<Chapter> chapters;
  final void Function(int index)? onDelete;

  const ChapterListWidget({super.key, required this.chapters, this.onDelete});

  @override
  State<ChapterListWidget> createState() => _ChapterListWidgetState();
}

class _ChapterListWidgetState extends State<ChapterListWidget> {
  final _scrollController = ScrollController();
  int? _expandedIndex;

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.chapters.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.menu_book, size: 64, color: Colors.grey[400]),
            const SizedBox(height: 16),
            Text('暂无章节', style: TextStyle(color: Colors.grey[600])),
            const SizedBox(height: 8),
            Text(
              '请上传TXT文件或粘贴文本',
              style: TextStyle(color: Colors.grey[500], fontSize: 13),
            ),
          ],
        ),
      );
    }

    return ListView.builder(
      controller: _scrollController,
      itemCount: widget.chapters.length,
      itemBuilder: (ctx, i) {
        final ch = widget.chapters[i];
        return Card(
          margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          child: ListTile(
            dense: true,
            leading: CircleAvatar(
              backgroundColor: Theme.of(context).colorScheme.primaryContainer,
              radius: 16,
              child: Text('${i + 1}', style: const TextStyle(fontSize: 11)),
            ),
            title: Text(
              ch.title,
              maxLines: 2,
              style: const TextStyle(fontSize: 14),
            ),
            subtitle: Text(
              '${ch.wordCount}字',
              style: const TextStyle(fontSize: 12),
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (widget.onDelete != null)
                  IconButton(
                    icon: const Icon(Icons.close, size: 18),
                    tooltip: '删除',
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                      minWidth: 32,
                      minHeight: 32,
                    ),
                    onPressed: () => _confirmDelete(i),
                  ),
                const Icon(Icons.chevron_right, size: 18),
              ],
            ),
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => ChapterReaderPage(
                    chapters: widget.chapters,
                    initialIndex: i,
                  ),
                ),
              );
            },
          ),
        );
      },
    );
  }

  void _confirmDelete(int index) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除章节'),
        content: Text('确定删除「${widget.chapters[index].title}」？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              widget.onDelete?.call(index);
            },
            child: const Text('删除', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }
}
