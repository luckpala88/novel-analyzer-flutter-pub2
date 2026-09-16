import 'dart:async';

import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/chapter.dart';
import '../state/app_state.dart';
import '../utils/v469_style.dart';

/// 章节阅读器 — 支持上下滑动浏览 + 翻页模式切换 + TTS朗读
class ChapterReaderPage extends StatefulWidget {
  final List<Chapter> chapters;
  final int initialIndex;
  final void Function(int index)? onChapterChanged;
  final void Function()? onShowList;

  const ChapterReaderPage({
    super.key,
    required this.chapters,
    this.initialIndex = 0,
    this.onChapterChanged,
    this.onShowList,
  });

  @override
  State<ChapterReaderPage> createState() => _ChapterReaderPageState();
}

class _ChapterReaderPageState extends State<ChapterReaderPage> {
  late int _currentIndex;
  double _fontSize = 18.0;
  double _lineHeight = 1.8;
  bool _pageMode = false;
  // v193：页码指示（AppBar信息行显示"当前页/总页数"）
  int _pageNo = 1;
  int _pageTotal = 1;
  String get _pageIndicatorText =>
      _pageMode ? '$_pageNo/$_pageTotal' : '';
  // TTS状态
  bool _ttsPlaying = false;
  int _ttsSentenceIdx = 0;
  String _currentSentence = '';
  // v417：滚动模式就地编辑+自动保存
  bool _scrollEditing = false;

  /// v417：编辑内容落盘——章对象原地改+全量chapters.json（v221原子写）
  void _saveChapterContent(int index, String text) {
    if (index < 0 || index >= widget.chapters.length) return;
    final ch = widget.chapters[index];
    if (ch.content == text) return;
    ch.content = text;
    ch.wordCount = text.length;
    try {
      context.read<AppState>().saveChapters();
    } catch (_) {}
  }
  // v351：待恢复的章内位置（一次性消费）——翻页=字符偏移；滚动=像素
  int _pendingOff = 0;
  double _pendingScrollPx = 0;

  /// v351：保存阅读样式（全局偏好）
  void _saveReaderStyle() {
    try {
      context.read<AppState>().storage.writeGlobalJson('reader_style', {
        'fs': _fontSize,
        'lh': _lineHeight,
        'pm': _pageMode,
      });
    } catch (_) {}
  }

  /// v351：保存阅读位置（按书reader_pos，与主页inline阅读共享键）
  void _saveReaderPos({required int off, double scrollPx = 0}) {
    try {
      context.read<AppState>().storage.writeBookData('reader_pos', {
        'chapter': _currentIndex,
        'off': off,
        'pm': _pageMode,
        'px': scrollPx,
      });
    } catch (_) {}
  }

  /// v351：待恢复偏移一次性消费（仅启动后首个分页视图生效）
  int _consumePendingOff() {
    final v = _pendingOff;
    _pendingOff = 0;
    return v;
  }

  /// v351：待恢复滚动像素一次性消费
  double _consumePendingScrollPx() {
    final v = _pendingScrollPx;
    _pendingScrollPx = 0;
    return v;
  }

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialIndex;
    // v351：恢复阅读样式与位置——样式（字号/行距/翻页模式）=全局偏好；
    // 位置（章+章内偏移/滚动像素）=按书reader_pos（与主页inline阅读共享）
    try {
      final state = context.read<AppState>();
      final style = state.storage.readGlobalJson('reader_style');
      if (style is Map) {
        _fontSize = (style['fs'] as num?)?.toDouble() ?? _fontSize;
        _lineHeight = (style['lh'] as num?)?.toDouble() ?? _lineHeight;
        if (style['pm'] is bool) _pageMode = style['pm'] as bool;
      }
      final pos = state.storage.readBookData('reader_pos');
      if (pos is Map) {
        final savedCh = (pos['chapter'] as num?)?.toInt() ?? -1;
        if (savedCh == widget.initialIndex) {
          // 章节与入口章一致才恢复章内位置（目录指定章=从存档处继续）
          _pendingOff = (pos['off'] as num?)?.toInt() ?? 0;
          _pendingScrollPx = (pos['px'] as num?)?.toDouble() ?? 0;
        }
      }
    } catch (_) {}
  }

  @override
  void dispose() {
    _stopTTS();
    super.dispose();
  }

  void _goToChapter(int index, {bool silent = false, bool toLastPage = false}) {
    if (index < 0 || index >= widget.chapters.length) return;
    // v417：切章退出编辑态——_ScrollChapterView销毁时flush未落盘内容
    //（其onContentChanged闭包捕获旧章号，flush写回的是旧章，安全）
    _scrollEditing = false;
    setState(() {
      _currentIndex = index;
      // v189：左翻到章首→跳上一章时落到末页（一次性标志，帧末复位）
      _jumpToLastPage = toLastPage;
    });
    widget.onChapterChanged?.call(index);
    if (toLastPage) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _jumpToLastPage = false;
      });
    }
    if (!silent && _ttsPlaying) _stopTTS();
  }

  // v189：章首左翻跳上一章时，翻页视图定位到末页（一次性）
  bool _jumpToLastPage = false;

  /// 开始TTS朗读（从当前页/当前滚动位置开始，连续读到章末）
  /// v468行为：读完当前页自动翻下一页继续读
  Future<void> _startTTS() async {
    final chapter = widget.chapters[_currentIndex];
    _ttsSpans = _splitSentenceSpans(chapter.content);
    // 起始偏移：翻页模式从当前页开头开始
    _ttsReadOffset = 0;
    int startIdx = 0;
    if (_pageMode && _currentPagedViewStart > 0) {
      _ttsReadOffset = _currentPagedViewStart;
      // 找到第一个start>=offset的句子索引
      for (int i = 0; i < _ttsSpans.length; i++) {
        if (_ttsSpans[i][0] >= _currentPagedViewStart) {
          startIdx = i;
          break;
        }
      }
    }
    _ttsSentenceIdx = startIdx;
    _ttsPlaying = true;
    _ttsPaused = false;
    _ttsHlStart = -1;
    _ttsHlEnd = -1;
    // v550：蓝牙耳机播放/暂停键接管
    final st0 = context.read<AppState>();
    st0.tts.onMediaButton = _togglePauseTTS;
    st0.tts.setMediaSession(active: true, playing: true);
    setState(() {});
    if (_ttsSpans.isEmpty) {
      await _stopTTS();
      return;
    }
    await _playNextSentence();
  }

  // TTS状态（以整章为朗读单位，支持自动翻页）
  List<List<int>> _ttsSpans = []; // 每句 [start, end]（相对整章content）
  int _ttsReadOffset = 0;
  int _ttsHlStart = -1;
  int _ttsHlEnd = -1;
  // 翻页模式
  int _currentPagedViewStart = 0;
  List<String> _pagedPageTexts = [];
  String _currentPagedPageText = '';

  /// v468分句：保留标点和引号
  List<List<int>> _splitSentenceSpans(String text) {
    final spans = <List<int>>[];
    final re = RegExp(r'[^。！？!?.\n　]+[。！？!?.\n　]*[“”‘’「」『』]*');
    for (final m in re.allMatches(text)) {
      if (m.start < m.end && m.group(0)!.trim().isNotEmpty) {
        spans.add([m.start, m.end]);
      }
    }
    return spans;
  }

  Future<void> _playNextSentence() async {
    if (!_ttsPlaying || _ttsSentenceIdx >= _ttsSpans.length) {
      // 读完整章，自动切下一章继续读
      if (_currentIndex < widget.chapters.length - 1) {
        final nextIdx = _currentIndex + 1;
        _goToChapter(nextIdx, silent: true);
        // 等新章节渲染后重新开始朗读
        await Future.delayed(const Duration(milliseconds: 300));
        if (!_ttsPlaying) return;
        final chapter = widget.chapters[nextIdx];
        _ttsSpans = _splitSentenceSpans(chapter.content);
        _ttsSentenceIdx = 0;
        _ttsHlStart = -1;
        _ttsHlEnd = -1;
        setState(() {});
        await _playNextSentence();
        return;
      }
      await _stopTTS();
      return;
    }
    final span = _ttsSpans[_ttsSentenceIdx];
    _ttsHlStart = span[0];
    _ttsHlEnd = span[1];
    final sentence = widget.chapters[_currentIndex].content.substring(
      _ttsHlStart,
      _ttsHlEnd,
    );
    _currentSentence = sentence;
    setState(() {});
    final state = context.read<AppState>();
    // 预取下一句
    if (_ttsSentenceIdx + 1 < _ttsSpans.length) {
      final next = _ttsSpans[_ttsSentenceIdx + 1];
      state.tts.prefetch(
        widget.chapters[_currentIndex].content.substring(next[0], next[1]),
      );
    }
    await state.tts.speak(
      sentence,
      onDone: () {
        if (!_ttsPlaying) return;
        _ttsSentenceIdx++;
        _playNextSentence();
      },
      onError: () {
        _ttsPlaying = false;
        setState(() {});
      },
    );
  }

  Future<void> _stopTTS() async {
    _ttsPlaying = false;
    _ttsPaused = false;
    _ttsHlStart = -1;
    _ttsHlEnd = -1;
    final state = context.read<AppState>();
    // v550：停读释放媒体会话（蓝牙按键不再劫持）
    state.tts.onMediaButton = null;
    state.tts.setMediaSession(active: false);
    await state.tts.stop();
    setState(() {});
  }

  Future<void> _toggleTTS() async {
    if (_ttsPlaying) {
      await _stopTTS();
    } else {
      await _startTTS();
    }
  }

  // TTS暂停状态（暂停当前句，不重置进度）
  bool _ttsPaused = false;

  /// 暂停/继续朗读
  Future<void> _togglePauseTTS() async {
    final state = context.read<AppState>();
    if (!_ttsPlaying) return;
    if (_ttsPaused) {
      // 继续：从头播当前句
      _ttsPaused = false;
      setState(() {});
      state.tts.setMediaSession(active: true, playing: true); // v550
      final sentence = widget.chapters[_currentIndex].content.substring(
        _ttsHlStart,
        _ttsHlEnd,
      );
      await state.tts.speak(
        sentence,
        onDone: () {
          if (!_ttsPlaying || _ttsPaused) return;
          _ttsSentenceIdx++;
          _playNextSentence();
        },
        onError: () {
          _ttsPlaying = false;
          setState(() {});
        },
      );
    } else {
      // 暂停
      _ttsPaused = true;
      state.tts.setMediaSession(active: true, playing: false); // v550
      await state.tts.stop();
      setState(() {});
    }
  }

  ButtonStyle _btnStyle({Color? foreground}) {
    return TextButton.styleFrom(
      minimumSize: const Size(32, 36),
      padding: const EdgeInsets.symmetric(horizontal: 4),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      foregroundColor: foreground,
    );
  }

  @override
  Widget build(BuildContext context) {
    final curChapter = widget.chapters[_currentIndex];
    // v417：build时捕获章号——切章dispose的flush闭包用旧章号（防写错章）
    final idxForSave = _currentIndex;
    return Scaffold(
      // v193：AppBar工具行一行——按钮组+章节标题+页码（标题页码挪到目录右边，小字号）
      // v197：AppBar工具行——按钮区固定一行（横向滚动），标题页码行内省空间
      //（旧Wrap折行时标题长会把按钮挤成两行、压缩正文高度）
      appBar: AppBar(
        toolbarHeight: 36,
        titleSpacing: 0,
        title: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Align(
            alignment: Alignment.centerLeft,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                // 字体减小
                TextButton(
                  onPressed: () => setState(() {
                    _fontSize = (_fontSize - 2).clamp(12.0, 28.0);
                    _saveReaderStyle(); // v351
                  }),
                  style: _btnStyle(),
                  child: const Text('A-', style: TextStyle(fontSize: 13)),
                ),
                // 字体大小显示
                Text(
                  '${_fontSize.toStringAsFixed(0)}',
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                // 字体增大
                TextButton(
                  onPressed: () => setState(() {
                    _fontSize = (_fontSize + 2).clamp(12.0, 28.0);
                    _saveReaderStyle(); // v351
                  }),
                  style: _btnStyle(),
                  child: const Text('A+', style: TextStyle(fontSize: 13)),
                ),
                // TTS播放/暂停（独立按钮）
                if (_ttsPlaying)
                  TextButton(
                    onPressed: _togglePauseTTS,
                    style: _btnStyle(),
                    child: Text(
                      _ttsPaused ? '继续' : '暂停',
                      style: const TextStyle(fontSize: 13),
                    ),
                  ),
                // TTS朗读/停止
                TextButton(
                  onPressed: _toggleTTS,
                  style: _btnStyle(
                    foreground: _ttsPlaying ? const Color(0xFF8B6914) : null,
                  ),
                  child: Text(
                    _ttsPlaying ? '停止' : '朗读',
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
                // 设置（行距/TTS设置）
                PopupMenuButton<String>(
                  tooltip: '设置',
                  position: PopupMenuPosition.under,
                  onSelected: (v) {
                    if (v == 'tts')
                      _showTTSSettings();
                    else if (v == 'font')
                      _showFontSettings();
                  },
                  itemBuilder: (ctx) => [
                    const PopupMenuItem(value: 'font', child: Text('行距设置')),
                    const PopupMenuItem(value: 'tts', child: Text('TTS设置')),
                  ],
                  child: const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 6),
                    child: Text('设置', style: TextStyle(fontSize: 13)),
                  ),
                ),
                // v417：就地编辑开关（仅滚动模式；编辑中亮色+锁定模式切换）
                if (!_pageMode)
                  TextButton(
                    onPressed: () {
                      if (!_scrollEditing && _ttsPlaying) _stopTTS();
                      setState(() => _scrollEditing = !_scrollEditing);
                    },
                    style: _btnStyle(
                      foreground: _scrollEditing
                          ? const Color(0xFF8B6914)
                          : null,
                    ),
                    child: Text(
                      _scrollEditing ? '完成' : '编辑',
                      style: const TextStyle(fontSize: 13),
                    ),
                  ),
                // 翻页/滚动切换（编辑中锁定防丢内容，v95约定）
                TextButton(
                  onPressed: _scrollEditing
                      ? null
                      : () => setState(() {
                          _pageMode = !_pageMode;
                          _saveReaderStyle(); // v351
                        }),
                  style: _btnStyle(),
                  child: Text(
                    _pageMode ? '滚动' : '翻页',
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
                // 章节列表
                TextButton(
                  onPressed: () => _showChapterList(),
                  style: _btnStyle(),
                  child: const Text('目录', style: TextStyle(fontSize: 13)),
                ),
                // v193：章节标题+页码（目录右边，更小字号，信息行不占正文空间）
                const SizedBox(width: 4),
                Text(
                  '${curChapter.title}  ·  $_pageIndicatorText',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 10, color: Colors.grey[600]),
                ),
                ],
              ),
            ),
          ),
        ),
      ),
      body: _pageMode
          ? _PagedChapterView(
              // v198：Key只绑章节——字号变化时State存活，didUpdateWidget的
              // 保持位置逻辑才能生效（旧Key含fontSize，字号一变整个State销毁重建→回开头）
              key: ValueKey('page_${_currentIndex}'),
              chapter: widget.chapters[_currentIndex],
              fontSize: _fontSize,
              lineHeight: _lineHeight,
              onPrev: _currentIndex > 0
                  ? () => _goToChapter(_currentIndex - 1, toLastPage: true)
                  : null,
              onNext: _currentIndex < widget.chapters.length - 1
                  ? () => _goToChapter(_currentIndex + 1)
                  : null,
              startAtLastPage: _jumpToLastPage,
              // v351：启动恢复——仅首次消费
              startOffset: _consumePendingOff(),
              onPagesComputed: (pages, currentPage) {
                _pagedPageTexts = pages;
                // 计算当前页的起始字符偏移（各页文本连续拼接）
                int start = 0;
                for (int i = 0; i < currentPage && i < pages.length; i++) {
                  start += pages[i].length;
                }
                // v193：pages含标题前缀，TTS的_currentPagedViewStart用content偏移（减前缀）
                _currentPagedViewStart = (start -
                        (widget.chapters[_currentIndex].title.length + 2))
                    .clamp(0, start);
                _currentPagedPageText = currentPage < pages.length
                    ? pages[currentPage]
                    : '';
                // v351：翻页/进章即存位置（pages含标题前缀，与分页恢复同坐标系）
                _saveReaderPos(off: start);
                // v193：页码同步到AppBar信息行
                if (_pageNo != currentPage + 1 || _pageTotal != pages.length) {
                  setState(() {
                    _pageNo = currentPage + 1;
                    _pageTotal = pages.length;
                  });
                }
              },
              hlStart: _ttsPlaying ? _ttsHlStart : -1,
              hlEnd: _ttsPlaying ? _ttsHlEnd : -1,
            )
          : NotificationListener<ScrollEndNotification>(
              // v351：滚动停稳即存位置（像素），进章由章切换逻辑覆盖
              onNotification: (n) {
                _saveReaderPos(
                  off: _currentPagedViewStart,
                  scrollPx: n.metrics.pixels,
                );
                return false;
              },
              child: _ScrollChapterView(
              key: ValueKey('scroll_${_currentIndex}'),
              chapter: widget.chapters[_currentIndex],
              fontSize: _fontSize,
              lineHeight: _lineHeight,
              // v351：启动恢复滚动位置
              initialScrollPx: _consumePendingScrollPx(),
              onPrev: _currentIndex > 0
                  ? () => _goToChapter(_currentIndex - 1)
                  : null,
              onNext: _currentIndex < widget.chapters.length - 1
                  ? () => _goToChapter(_currentIndex + 1)
                  : null,
              hlStart: _ttsPlaying ? _ttsHlStart : -1,
              hlEnd: _ttsPlaying ? _ttsHlEnd : -1,
              // v417：就地编辑+自动保存——闭包捕获build时的章号（切章dispose时
              // flush用旧widget的闭包，若读this._currentIndex会写错章）
              editing: _scrollEditing,
              onContentChanged: (text) =>
                  _saveChapterContent(idxForSave, text),
            ),
            ),
    );
  }

  void _showFontSettings() {
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('行距设置'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('行距: ${_lineHeight.toStringAsFixed(1)}'),
              Slider(
                value: _lineHeight,
                min: 1.2,
                max: 3.0,
                divisions: 18,
                onChanged: (v) => setDialogState(() => _lineHeight = v),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.pop(ctx);
                _saveReaderStyle(); // v351：行距确认后存样式
                setState(() {}); // 关闭后刷新外层
              },
              child: const Text('确定'),
            ),
          ],
        ),
      ),
    );
  }

  void _showTTSSettings() {
    final state = context.read<AppState>();
    String engine = state.tts.engine;
    String key = state.tts.siliconKey;
    String voice = state.tts.siliconVoice;
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('TTS设置'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 引擎选择
              const Text(
                'TTS引擎',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              RadioGroup<String>(
                groupValue: engine,
                onChanged: (v) => setDialogState(() {
                  engine = v!;
                  state.tts.setEngine(v);
                  state.storage.writeGlobal('tts_engine', v);
                }),
                child: const Column(
                  children: [
                    ListTile(
                      dense: true,
                      leading: Radio<String>(value: 'silicon'),
                      title: Text('硅基流动TTS'),
                    ),
                    ListTile(
                      dense: true,
                      leading: Radio<String>(value: 'native'),
                      title: Text('系统TTS'),
                    ),
                  ],
                ),
              ),
              if (engine == 'silicon') ...[
                const SizedBox(height: 8),
                TextField(
                  decoration: const InputDecoration(
                    labelText: 'API Key',
                    border: OutlineInputBorder(),
                  ),
                  controller: TextEditingController(text: key),
                  onChanged: (v) {
                    key = v;
                    state.tts.siliconKey = v;
                    state.storage.writeGlobal('silicon_tts_key', v);
                  },
                ),
                const SizedBox(height: 8),
                DropdownButton<String>(
                  value: voice,
                  items: const [
                    DropdownMenuItem(value: 'alex', child: Text('Alex')),
                    DropdownMenuItem(value: 'anna', child: Text('Anna')),
                    DropdownMenuItem(value: 'bella', child: Text('Bella')),
                    DropdownMenuItem(
                      value: 'benjamin',
                      child: Text('Benjamin'),
                    ),
                  ],
                  onChanged: (v) {
                    if (v == null) return;
                    setDialogState(() => voice = v);
                    state.tts.siliconVoice = v;
                    state.storage.writeGlobal('silicon_voice', v);
                  },
                ),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('关闭'),
            ),
          ],
        ),
      ),
    );
  }

  void _showChapterList() {
    final state = context.read<AppState>();
    showModalBottomSheet(
      context: context,
      builder: (ctx) => Column(
        children: [
          AppBar(
            title: const Text('章节列表'),
            leading: IconButton(
              icon: const Icon(Icons.close),
              onPressed: () => Navigator.pop(ctx),
            ),
          ),
          Expanded(
            child: ListView.builder(
              itemCount: state.chapters.length,
              itemBuilder: (ctx, i) {
                final ch = state.chapters[i];
                return ListTile(
                  dense: true,
                  selected: i == _currentIndex,
                  title: Text(
                    ch.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 14),
                  ),
                  subtitle: Text(
                    '${ch.wordCount}字',
                    style: const TextStyle(fontSize: 12),
                  ),
                  onTap: () {
                    _goToChapter(i);
                    Navigator.pop(ctx);
                  },
                  // v208：目录内直接删单章（追加txt后清理广告章/重复章）
                  trailing: IconButton(
                    icon: Icon(
                      Icons.delete_outline,
                      size: 20,
                      color: Colors.red.shade400,
                    ),
                    tooltip: '删除本章',
                    onPressed: () => _confirmDeleteChapter(ctx, state, i),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  /// 删除单章确认（v208：目录列表内删除）
  void _confirmDeleteChapter(
    BuildContext sheetCtx,
    AppState state,
    int index,
  ) {
    final ch = state.chapters[index];
    showDialog(
      context: sheetCtx,
      builder: (dctx) => AlertDialog(
        title: const Text('删除章节'),
        content: Text('确定删除「${ch.title}」？不可恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dctx),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Colors.red.shade400,
            ),
            onPressed: () {
              final wasCurrent = index == _currentIndex;
              state.removeChapter(index);
              Navigator.pop(dctx); // 关确认框（目录sheet保持开，可继续删）
              // 删的是当前章或之前的章：校正阅读位置
              if (wasCurrent) {
                _goToChapter(
                  index < state.chapters.length ? index : state.chapters.length - 1,
                );
              } else if (index < _currentIndex) {
                setState(() => _currentIndex--);
              }
              // 删后面的章：位置不变
            },
            child: const Text('删除'),
          ),
        ],
      ),
    );
  }
}

/// 滑动浏览模式 — 整个章节可上下滚动 + TTS自动滚动跟随
class _ScrollChapterView extends StatefulWidget {
  final Chapter chapter;
  final double fontSize;
  final double lineHeight;
  final int hlStart; // TTS当前句起始偏移（相对整章，-1无高亮）
  final int hlEnd; // TTS当前句结束偏移
  final VoidCallback? onPrev; // v191：滚动模式悬浮按钮=切换章节
  final VoidCallback? onNext;
  final double initialScrollPx; // v351：启动恢复滚动位置
  // v417：就地编辑——editing=true时正文变TextField，onChange防抖后onContentChanged
  final bool editing;
  final void Function(String newText)? onContentChanged;

  const _ScrollChapterView({
    super.key,
    required this.chapter,
    required this.fontSize,
    required this.lineHeight,
    this.hlStart = -1,
    this.hlEnd = -1,
    this.onPrev,
    this.onNext,
    this.initialScrollPx = 0,
    this.editing = false,
    this.onContentChanged,
  });

  @override
  State<_ScrollChapterView> createState() => _ScrollChapterViewState();
}

class _ScrollChapterViewState extends State<_ScrollChapterView> {
  // v351：controller带初值（late field在声明处初始化可引用widget）
  late final ScrollController _scrollController =
      ScrollController(initialScrollOffset: widget.initialScrollPx);
  final GlobalKey _hlKey = GlobalKey();

  // v417：就地编辑——controller仅编辑态存在；输入防抖1.5s自动保存
  TextEditingController? _editController;
  Timer? _saveDebounce;
  bool _savedOnce = false; // 编辑态显示"已保存"标记

  void _ensureEditController() {
    if (_editController != null) return;
    _editController = TextEditingController(text: widget.chapter.content);
    _savedOnce = false;
  }

  void _disposeEditController() {
    // v417：退出编辑/切章/销毁时，未落盘的防抖内容立即保存（防丢字）
    if (_saveDebounce?.isActive ?? false) {
      _saveDebounce?.cancel();
      widget.onContentChanged?.call(_editController?.text ?? '');
    }
    _saveDebounce = null;
    _editController?.dispose();
    _editController = null;
  }

  void _onEdited(String text) {
    _savedOnce = false;
    if (mounted) setState(() {});
    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(milliseconds: 1500), () {
      widget.onContentChanged?.call(_editController?.text ?? text);
      if (mounted) setState(() => _savedOnce = true);
    });
  }

  @override
  void didUpdateWidget(_ScrollChapterView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 进入编辑态：建controller；退出：提交并销毁
    if (widget.editing && !oldWidget.editing) {
      _ensureEditController();
    } else if (!widget.editing && oldWidget.editing) {
      _disposeEditController();
    }
    // 高亮句变化时自动滚动到可见区域
    if (widget.hlStart != oldWidget.hlStart && widget.hlStart >= 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _scrollToHighlight();
      });
    }
  }

  void _scrollToHighlight() {
    if (!mounted) return;
    final ctx = _hlKey.currentContext;
    if (ctx == null) return;
    Scrollable.ensureVisible(
      ctx,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
      alignment: 0.33, // 高亮句显示在视口1/3处
    );
  }

  @override
  void dispose() {
    _disposeEditController();
    _scrollController.dispose();
    super.dispose();
  }

  /// 构建正文TextSpan，按偏移量高亮TTS当前句
  TextSpan _buildContentSpan(String content, TextStyle style) {
    if (widget.hlStart < 0 ||
        widget.hlEnd <= widget.hlStart ||
        widget.hlStart >= content.length) {
      return TextSpan(text: content, style: style);
    }
    final end = widget.hlEnd.clamp(0, content.length);
    final before = content.substring(0, widget.hlStart);
    final mid = content.substring(widget.hlStart, end);
    final after = content.substring(end);
    return TextSpan(
      style: style,
      children: [
        if (before.isNotEmpty) TextSpan(text: before),
        WidgetSpan(
          child: Container(
            key: _hlKey,
            color: const Color(0xFFFFE082),
            child: Text(mid, style: style),
          ),
        ),
        if (after.isNotEmpty) TextSpan(text: after),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(
      fontSize: widget.fontSize,
      height: widget.lineHeight,
      fontFamily: V469Style.uiFont, // v200显式指定：与翻页模式绝对一致
    );
    // v191：滚动模式悬浮按钮=上一章/下一章（翻页模式才是翻页）
    return Stack(
      children: [
        SingleChildScrollView(
          controller: _scrollController,
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.chapter.title,
                style: TextStyle(
                  fontSize: widget.fontSize + 4,
                  fontWeight: FontWeight.bold,
                  fontFamily: V469Style.uiFont, // v200
                ),
              ),
              const SizedBox(height: 16),
              if (widget.editing && _editController != null)
                TextField(
                  controller: _editController,
                  onChanged: _onEdited,
                  maxLines: null,
                  autofocus: true,
                  style: style,
                  decoration: const InputDecoration(
                    isDense: true,
                    border: InputBorder.none,
                  ),
                )
              else
                Text.rich(_buildContentSpan(widget.chapter.content, style)),
              const SizedBox(height: 32),
              Center(
                child: Text(
                  widget.editing && _editController != null
                      ? '${_editController!.text.length}字${_savedOnce ? " · ✓已保存" : " · 编辑中"}'
                      : '${widget.chapter.wordCount}字',
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.grey[400],
                    fontFamily: V469Style.uiFont, // v200
                  ),
                ),
              ),
            ],
          ),
        ),
        // 悬浮章节切换按钮（左下=上一章/右下=下一章，v191）
        if (widget.onPrev != null)
          Positioned(
            left: 8,
            bottom: 12,
            child: _floatBtn(
              icon: Icons.skip_previous,
              onTap: widget.onPrev,
            ),
          ),
        if (widget.onNext != null)
          Positioned(
            right: 8,
            bottom: 12,
            child: _floatBtn(
              icon: Icons.skip_next,
              onTap: widget.onNext,
            ),
          ),
      ],
    );
  }

  /// 悬浮按钮（与翻页模式同款样式）
  Widget _floatBtn({required IconData icon, VoidCallback? onTap}) {
    return Material(
      color: Colors.black.withOpacity(0.18),
      borderRadius: BorderRadius.circular(24),
      child: InkWell(
        borderRadius: BorderRadius.circular(24),
        onTap: onTap,
        child: SizedBox(
          width: 48,
          height: 48,
          child: Icon(icon, color: Colors.white70, size: 26),
        ),
      ),
    );
  }
}

/// 作为翻页模式：测量与绘制共用同一个TextPainter实例（CustomPaint直接paint）
/// —— 同一个对象排版和绘制，任何字号/字体/缩放下分页与渲染绝对一致（v195核心）
class _PagedChapterView extends StatefulWidget {
  final Chapter chapter;
  final double fontSize;
  final double lineHeight;
  final VoidCallback? onPrev;
  final VoidCallback? onNext;
  final void Function(List<String> pages, int currentPage)? onPagesComputed;
  final int hlStart; // TTS当前句起始偏移（相对content，-1无高亮）
  final int hlEnd;
  final bool startAtLastPage; // 从上一章末页翻入时定位到末页
  final int startOffset; // v351：启动恢复的章内字符偏移（含标题前缀，一次性）

  const _PagedChapterView({
    super.key,
    required this.chapter,
    required this.fontSize,
    required this.lineHeight,
    this.onPrev,
    this.onNext,
    this.onPagesComputed,
    this.hlStart = -1,
    this.hlEnd = -1,
    this.startAtLastPage = false,
    this.startOffset = 0,
  });

  @override
  State<_PagedChapterView> createState() => _PagedChapterViewState();
}

class _PagedChapterViewState extends State<_PagedChapterView> {
  List<String> _pages = [];
  List<int> _pageStarts = []; // 每页在整章（含标题）中的起始偏移
  List<double> _pageTopOffsets = []; // 每页首行top（平移绘制用）
  List<double> _pageHeights = []; // v198：每页内容高（裁剪到下一页首行top，跨界行不可见）
  int _currentPage = 0;
  bool _isLoading = true;
  Size? _lastSize;
  TextPainter? _tp; // 分页测量与绘制共用实例
  int _tpVersion = 0; // tp重建版本（painter判断repaint用）
  int? _restoreOffset; // 字号/行距变化后保持阅读位置（页首偏移）
  // 分页几何（与渲染CustomPaint的size严格同参）
  static const double _padH = 16.0;
  static const double _padTop = 10.0;
  static const double _padBottom = 10.0;
  double _availW = 0;
  double _availH = 0;

  // v286：分页结果静态缓存（State每次切模式销毁重建，缓存必须挂在类级）
  // key=章节内容指纹|字号|行距|窗口尺寸；只保留最近4章防内存膨胀
  static final LinkedHashMap<String, List<Object>> _pageCache =
      LinkedHashMap<String, List<Object>>();
  static const int _pageCacheMax = 4;

  @override
  void initState() {
    super.initState();
    // v351：启动恢复章内位置（startOffset为含标题前缀的fullText偏移）
    if (widget.startOffset > 0) {
      _restoreOffset = widget.startOffset;
    }
  }

  @override
  void dispose() {
    _tp?.dispose();
    super.dispose();
  }

  /// 构建整章TextSpan（标题首行+正文+TTS高亮）
  TextSpan _buildSpan(TextStyle style) {
    final title = widget.chapter.title;
    final content = widget.chapter.content;
    final titleStyle = style.copyWith(
      fontWeight: FontWeight.bold,
      fontSize: style.fontSize! + 3,
    );
    final prefixLen = title.length + 2;
    if (widget.hlStart < 0 || widget.hlEnd <= widget.hlStart) {
      return TextSpan(
        style: style,
        children: [
          TextSpan(text: title, style: titleStyle),
          TextSpan(text: '\n\n$content'),
        ],
      );
    }
    final s = (widget.hlStart + prefixLen).clamp(0, prefixLen + content.length);
    final e = (widget.hlEnd + prefixLen).clamp(0, prefixLen + content.length);
    final full = '$title\n\n$content';
    return TextSpan(
      style: style,
      children: [
        if (s > 0) TextSpan(text: full.substring(0, s)),
        TextSpan(
          text: full.substring(s, e),
          style: style.copyWith(backgroundColor: const Color(0xFFFFE082)),
        ),
        if (e < full.length) TextSpan(text: full.substring(e)),
      ],
    );
  }

  /// 排版+分页（tp实例保留给绘制用）
  void _computePages(Size viewSize) {
    _availW = viewSize.width - _padH * 2;
    _availH = viewSize.height - _padTop - _padBottom;
    if (_availW <= 0 || _availH <= 0) return;

    // v196：CustomPaint直接canvas绘制不继承主题——颜色必须显式指定
    //（v195事故：无色→白字浅底看不见）
    final style = TextStyle(
      fontSize: widget.fontSize,
      height: widget.lineHeight,
      color: V469Style.textMain,
      fontFamily: V469Style.uiFont, // v200统一入口
    );
    _tp?.dispose();
    _tp = TextPainter(
      text: _buildSpan(style),
      textDirection: TextDirection.ltr,
      textAlign: TextAlign.start,
    );
    _tp!.layout(maxWidth: _availW);
    _tpVersion++;

    // v286：缓存命中——布局仍要跑（绘制需要），但跳过行度量+行首探测（十几秒卡顿的元凶）
    final fullText0 =
        '${widget.chapter.title}\n\n${widget.chapter.content}';
    final cacheKey = '${fullText0.length}|${fullText0.hashCode}'
        '|${widget.fontSize}|${widget.lineHeight}'
        '|${_availW.toStringAsFixed(1)}|${_availH.toStringAsFixed(1)}';
    final cached = _pageCache[cacheKey];
    if (cached != null) {
      // LRU：命中即提到最新
      _pageCache.remove(cacheKey);
      _pageCache[cacheKey] = cached;
      _applyPages(
        pages: cached[0] as List<String>,
        pageStarts: cached[1] as List<int>,
        pageTopOffsets: cached[2] as List<double>,
        pageHeights: cached[3] as List<double>,
        fullText: fullText0,
      );
      return;
    }

    _lineStartCache.clear();
    final lines = _tp!.computeLineMetrics();
    final fullText = fullText0;

    List<String> pages = [];
    List<int> pageStarts = [];
    List<double> pageTopOffsets = [];
    // v198：每页裁剪高度=本页内容到下一页首行的top（裁剪边界对齐行边界，
    // 跨界行整行不可见——窗口底边切进行中间导致的"切尾+下页重复"根治）
    List<double> pageHeights = [];

    if (lines.isEmpty) {
      pages = [fullText];
      pageStarts = [0];
      pageTopOffsets = [0.0];
      pageHeights = [_availH];
    } else {
      double lineTop(int i) => lines[i].baseline - lines[i].ascent;
      int lineStart = 0;
      for (int i = 0; i < lines.length; i++) {
        // 行i盘底：下一行的top（渲染器自己的几何，绝对精确）
        final double lineBottom = (i + 1 < lines.length)
            ? lineTop(i + 1)
            : lineTop(i) + lines[i].height;
        if (lineBottom - lineTop(lineStart) > _availH && i > lineStart) {
          final startOffset = _getLineStart(_tp!, lineStart, fullText);
          final endOffset = _getLineStart(_tp!, i, fullText);
          pages.add(fullText.substring(startOffset, endOffset));
          pageStarts.add(startOffset);
          pageTopOffsets.add(lineTop(lineStart));
          // 本页高度=本页首行top到下一页首行top（即行i的top）
          pageHeights.add(lineTop(i) - lineTop(lineStart));
          lineStart = i;
        }
      }
      if (lineStart < lines.length) {
        final startOffset = _getLineStart(_tp!, lineStart, fullText);
        pages.add(fullText.substring(startOffset));
        pageStarts.add(startOffset);
        pageTopOffsets.add(lineTop(lineStart));
        // 末页高度=剩余内容高（最后一行盘底-首行top）
        final lastLine = lines.length - 1;
        final lastBottom = lineTop(lastLine) + lines[lastLine].height;
        pageHeights.add((lastBottom - lineTop(lineStart)).clamp(1.0, _availH));
      }
    }

    if (pages.isEmpty) {
      pages = [''];
      pageStarts = [0];
      pageTopOffsets = [0.0];
      pageHeights = [_availH];
    }

    // v286：存缓存（LRU淘汰最旧）
    if (_pageCache.length >= _pageCacheMax) {
      _pageCache.remove(_pageCache.keys.first);
    }
    _pageCache[cacheKey] = [pages, pageStarts, pageTopOffsets, pageHeights];

    _applyPages(
      pages: pages,
      pageStarts: pageStarts,
      pageTopOffsets: pageTopOffsets,
      pageHeights: pageHeights,
      fullText: fullText,
    );
  }

  /// 分页结果落盘（新算/缓存命中共用）：定位初始页+setState
  void _applyPages({
    required List<String> pages,
    required List<int> pageStarts,
    required List<double> pageTopOffsets,
    required List<double> pageHeights,
    required String fullText,
  }) {
    // 定位初始页：末页翻入 / 字号变化保持位置 / 默认第1页
    int initPage = 0;
    if (_restoreOffset != null) {
      // 找包含保持偏移的页
      for (int i = 0; i < pageStarts.length; i++) {
        final end = i + 1 < pageStarts.length
            ? pageStarts[i + 1]
            : fullText.length + 1;
        if (_restoreOffset! >= pageStarts[i] && _restoreOffset! < end) {
          initPage = i;
          break;
        }
      }
      _restoreOffset = null;
    } else if (widget.startAtLastPage && pages.length > 1) {
      initPage = pages.length - 1;
    }

    setState(() {
      _pages = pages;
      _pageStarts = pageStarts;
      _pageTopOffsets = pageTopOffsets;
      _pageHeights = pageHeights;
      _currentPage = initPage;
      _isLoading = false;
    });
    widget.onPagesComputed?.call(pages, initPage);
  }

  @override
  void didUpdateWidget(_PagedChapterView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // v195：字号/行距变化→保持位置重分页（不再跳回开头）
    if (oldWidget.fontSize != widget.fontSize ||
        oldWidget.lineHeight != widget.lineHeight) {
      final keep = _pageStarts.isNotEmpty &&
              _currentPage < _pageStarts.length
          ? _pageStarts[_currentPage]
          : 0;
      _restoreOffset = keep;
      _isLoading = true;
      _lastSize = null;
      setState(() {});
    } else if (oldWidget.hlStart != widget.hlStart ||
        oldWidget.hlEnd != widget.hlEnd) {
      // 仅高亮变化：重建 tp（背景色不影响布局，分页不变）
      final style = TextStyle(
        fontSize: widget.fontSize,
        height: widget.lineHeight,
        color: V469Style.textMain, // v196：CustomPaint不继承主题，显式黑色
        fontFamily: V469Style.uiFont, // v200统一入口
      );
      _tp?.dispose();
      _tp = TextPainter(
        text: _buildSpan(style),
        textDirection: TextDirection.ltr,
        textAlign: TextAlign.start,
      );
      _tp!.layout(maxWidth: _availW);
      _tpVersion++;
      setState(() {});
    }
  }

  // 行首缓存（同一次分页内复用）
  final Map<int, int> _lineStartCache = {};

  /// 行内字符探测法定位行首（v171，不依赖单调性）
  /// v286：先走O(1)快速路径——getPositionForOffset在行垂直中点x≈0处
  /// 一次命中行首候选，getOffsetForCaret验证一次；不过才退回逐字符探测
  /// （大章节十几秒卡顿的元凶=每个页断点逐字符探测上万次caret查询）
  int _getLineStart(TextPainter tp, int lineIdx, String text) {
    if (lineIdx == 0) return 0;
    final lines = tp.computeLineMetrics();
    if (lineIdx >= lines.length) return text.length;

    final lineTop = lines[lineIdx].baseline - lines[lineIdx].ascent;
    final lineBottom = lines[lineIdx].baseline + lines[lineIdx].descent;

    // 快速路径：行左边缘(x=1)的命中点=行首字符（x小于任何字形起点）
    try {
      final mid = tp.getPositionForOffset(
        Offset(1, (lineTop + lineBottom) / 2),
      );
      final dy = tp.getOffsetForCaret(mid, Rect.zero).dy;
      if (dy >= lineTop - 0.5 && dy <= lineBottom && mid.offset >= 0) {
        final prevStart = _lineStartCache[lineIdx - 1] ?? 0;
        if (mid.offset >= prevStart) {
          _lineStartCache[lineIdx] = mid.offset;
          return mid.offset;
        }
      }
    } catch (_) {
      // 静默降级到逐字符探测
    }

    final prevStart = _lineStartCache[lineIdx - 1] ?? 0;
    var probe = prevStart;
    while (probe < text.length) {
      final pos = tp.getOffsetForCaret(TextPosition(offset: probe), Rect.zero);
      if (pos.dy >= lineTop - 0.5 && pos.dy <= lineBottom) {
        _lineStartCache[lineIdx] = probe;
        return probe;
      }
      if (pos.dy < lineTop - 0.5) {
        probe += 20;
        continue;
      }
      break;
    }
    for (var i = prevStart; i < text.length; i++) {
      final pos = tp.getOffsetForCaret(TextPosition(offset: i), Rect.zero);
      if (pos.dy >= lineTop - 0.5) {
        _lineStartCache[lineIdx] = i;
        return i;
      }
    }
    return text.length;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        if (_lastSize != size || _isLoading) {
          _lastSize = size;
          _isLoading = true;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _computePages(size);
          });
        }
        if (_isLoading || _pages.isEmpty || _tp == null) {
          return const Center(child: CircularProgressIndicator());
        }
        // TTS朗读时自动翻到高亮句所在页
        if (widget.hlStart >= 0 && _pageStarts.isNotEmpty) {
          final prefixLen = widget.chapter.title.length + 2;
          final absHl = widget.hlStart + prefixLen;
          for (int i = 0; i < _pageStarts.length; i++) {
            final ps = _pageStarts[i];
            final pe = ps + _pages[i].length;
            if (absHl >= ps && absHl < pe) {
              if (_currentPage != i) {
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted && _currentPage != i) {
                    setState(() => _currentPage = i);
                    widget.onPagesComputed?.call(_pages, i);
                  }
                });
              }
              break;
            }
          }
        }
        final pageTop = _pageTopOffsets[_currentPage];
        // v195：Listener原始指针监听偒页翻页（不参与手势竞技场，
        // 无法被PageView抢——修复末页翻不动；位移>touchSlop忽略，不与滑动冲突）
        var downX = 0.0;
        var downY = 0.0;
        return Listener(
          onPointerDown: (e) {
            downX = e.localPosition.dx;
            downY = e.localPosition.dy;
          },
          onPointerUp: (e) {
            final dx = (e.localPosition.dx - downX).abs();
            final dy = (e.localPosition.dy - downY).abs();
            if (dx > 24 || dy > 24) return; // 滑动不算点击
            final tapX = e.localPosition.dx;
            if (tapX < constraints.maxWidth / 2) {
              // 左半屏：上一页（页首则上一章）
              if (_currentPage > 0) {
                setState(() => _currentPage--);
                widget.onPagesComputed?.call(_pages, _currentPage);
              } else {
                widget.onPrev?.call();
              }
            } else {
              // 右半屏：下一页（页尾则下一章）
              if (_currentPage < _pages.length - 1) {
                setState(() => _currentPage++);
                widget.onPagesComputed?.call(_pages, _currentPage);
              } else {
                widget.onNext?.call();
              }
            }
          },
          child: Stack(
            children: [
              // 正文窗口：v198 CustomPaint尺寸=本页内容高（裁剪边界对齐行边界，
              // 窗口小于页高时ClipRect兜底，但绘制高度本身不再把跨界行画进来）
              Positioned(
                left: _padH,
                right: _padH,
                top: _padTop,
                bottom: _padBottom,
                child: ClipRect(
                  child: CustomPaint(
                    // v199：size仅供参考——真实裁剪高在painter.pageHeight字段
                    //（Positioned全约束会覆盖这里的size）
                    size: Size(
                      _availW,
                      _pageHeights.isNotEmpty &&
                              _currentPage < _pageHeights.length
                          ? _pageHeights[_currentPage]
                          : _availH,
                    ),
                    painter: _PagePainter(
                      tp: _tp!,
                      pageTop: pageTop,
                      pageHeight:
                          _pageHeights.isNotEmpty &&
                                  _currentPage < _pageHeights.length
                              ? _pageHeights[_currentPage]
                              : _availH,
                      version: _tpVersion,
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// v195：共用TextPainter的页面绘制器（分页测量与屏幕绘制是同一个实例）
class _PagePainter extends CustomPainter {
  final TextPainter tp;
  final double pageTop;
  // v199：页高必须自带字段——CustomPaint被Positioned四边全约束时
  // size参数被强制覆盖为窗口高，v198的修复实际没进paint（字号整除才完美的真凶）
  final double pageHeight;
  final int version;

  _PagePainter({
    required this.tp,
    required this.pageTop,
    required this.pageHeight,
    required this.version,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // v198/v199：canvas裁剪到本页内容高（行边界），越界的下一页首行整行被裁掉
    canvas.save();
    canvas.clipRect(Rect.fromLTWH(0, 0, size.width, pageHeight));
    tp.paint(canvas, Offset(0, -pageTop));
    canvas.restore();
  }

  @override
  bool shouldRepaint(_PagePainter old) =>
      old.pageTop != pageTop ||
      old.version != version ||
      old.pageHeight != pageHeight;
}
