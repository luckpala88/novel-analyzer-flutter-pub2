import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/chapter.dart';
import '../pages/chapter_reader_page.dart';
import '../state/app_state.dart';

/// 内联章节阅读器 — 直接嵌入主页
/// 左侧章节列表 + 右侧阅读器（或手机端上下布局）
class ChapterReaderInline extends StatefulWidget {
  final List<Chapter> chapters;

  const ChapterReaderInline({super.key, required this.chapters});

  @override
  State<ChapterReaderInline> createState() => _ChapterReaderInlineState();
}

class _ChapterReaderInlineState extends State<ChapterReaderInline> {
  int _currentIndex = 0;
  final _listScrollController = ScrollController();
  bool _showList = false; // 手机端控制是否显示列表

  @override
  void initState() {
    super.initState();
    _loadSavedPos();
  }

  /// 加载本书阅读位置（per-book：books/{书}/reader_pos.json）
  void _loadSavedPos() {
    try {
      final state = context.read<AppState>();
      final raw = state.storage.readBookData('reader_pos');
      if (raw is Map && raw['chapter'] is int) {
        final idx = raw['chapter'] as int;
        if (idx >= 0 && idx < widget.chapters.length) {
          _currentIndex = idx;
        }
      }
    } catch (_) {}
  }

  /// 保存阅读位置（翻章即存，文件小写入快）
  void _savePos(int idx) {
    try {
      final state = context.read<AppState>();
      state.storage.writeBookData('reader_pos', {'chapter': idx});
    } catch (_) {}
  }

  @override
  void dispose() {
    _listScrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 统一用overlay列表模式（不分横竖屏，侧栏占空间太大）
    return Stack(
      children: [
        _buildReader(),
        if (_showList)
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            bottom: 0,
            child: Material(
              color: Theme.of(context).scaffoldBackgroundColor
                  .withOpacity(0.95),
              child: Column(
                children: [
                  AppBar(
                    title: Text('${widget.chapters.length}章'),
                    leading: IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () => setState(() => _showList = false),
                    ),
                  ),
                  Expanded(child: _buildChapterList()),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildChapterList() {
    return ListView.builder(
      controller: _listScrollController,
      itemCount: widget.chapters.length,
      itemBuilder: (ctx, i) {
        final ch = widget.chapters[i];
        final isCurrent = i == _currentIndex;
        return ListTile(
          dense: true,
          selected: isCurrent,
          leading: Text(
            '${ch.number}',
            style: TextStyle(
              fontSize: 11,
              color: isCurrent
                  ? Theme.of(context).colorScheme.primary
                  : Colors.grey,
            ),
          ),
          title: Text(
            ch.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 13,
              fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal,
              color: isCurrent ? Theme.of(context).colorScheme.primary : null,
            ),
          ),
          subtitle: Text(
            '${ch.wordCount}字',
            style: const TextStyle(fontSize: 10),
          ),
          onTap: () {
            setState(() {
              _currentIndex = i;
              _savePos(i);
              _showList = false;
            });
          },
          onLongPress: () => _confirmDeleteChapter(ctx, i),
        );
      },
    );
  }

  Widget _buildReader() {
    if (widget.chapters.isEmpty) return const SizedBox.shrink();
    return ChapterReaderPage(
      chapters: widget.chapters,
      initialIndex: _currentIndex,
      onChapterChanged: (i) {
        setState(() => _currentIndex = i);
        _savePos(i); // 记住阅读位置（重启回原章）
      },
      onShowList: () {
        setState(() => _showList = true);
      },
    );
  }

  /// 长按删除单章（确认弹窗）
  void _confirmDeleteChapter(BuildContext ctx, int idx) {
    final ch = widget.chapters[idx];
    showDialog<bool>(
      context: ctx,
      builder: (dctx) => AlertDialog(
        title: const Text('删除章节'),
        content: Text('确定删除「${ch.title}」（${ch.wordCount}字）？不可恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(dctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    ).then((ok) {
      if (ok != true) return;
      final state = ctx.read<AppState>();
      final wasCurrent = idx == _currentIndex;
      final beforeCurrent = idx < _currentIndex;
      state.removeChapter(idx);
      if (!mounted) return;
      setState(() {
        if (beforeCurrent) _currentIndex--; // 删了前面的章，索引前移
        if (_currentIndex >= state.chapters.length) {
          _currentIndex = state.chapters.isEmpty
              ? 0
              : state.chapters.length - 1;
        }
        if (wasCurrent) _showList = true; // 删的当前章：列表保持打开防跳错
        _savePos(_currentIndex);
      });
    });
  }
}
