import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/services.dart';

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../utils/text_cleaner.dart';

import '../state/app_state.dart';
import '../services/file_picker_service.dart';
import 'package:share_plus/share_plus.dart';
import '../utils/encoding_detector.dart';
import '../utils/name_map.dart';
import '../utils/text_cleaner.dart';
import '../utils/prompt_preview.dart';
import '../utils/v469_style.dart';
import '../widgets/api_config_panel.dart';
import '../widgets/api_log_panel.dart';
import '../widgets/v119_ui.dart';

/// 二创页（原审核页改造）：
/// · 列出一创正文（books/{book}/writings/）+ 二创正文（books/{book}/二创/）
/// · 找问题审核：AI审读正文找逻辑/人设/节奏/文笔问题（替代AI浓度检测）
/// · 二创：AI按修改意见+文风/内容素材重写正文，保存到二创目录
class DetectionPage extends StatefulWidget {
  const DetectionPage({super.key});

  @override
  State<DetectionPage> createState() => _DetectionPageState();
}

class _DetectionPageState extends State<DetectionPage>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true; // 页面滑出PageView时保持State：生成任务不中断/表单不清空

  bool _isProcessing = false;
  String _statusText = '';
  String _resultText = ''; // 找问题结果
  List<Map<String, dynamic>> _nameCheckIssues = const []; // v407体检建议
  final List<Map<String, dynamic>> _files =
      []; // {name, path, content, wordCount, isWritings, isRewrite}
  final List<String> _logs = [];
  int _currentIndex = -1;
  double _fontSize = 14.0;
  bool _pageMode = false;
  int _filterMode = 0; // 0=全部 1=一创 2=二创
  bool _savedFlash = false; // 保存按钮反馈（✓已保存1.5s）
  bool _filesExpanded = true; // v379b：文件列表默认展开（点文件后自动折叠）
  // TTS朗读（复用chapter_reader模式：分句+逐句+高亮+暂停）
  bool _ttsPlaying = false;
  bool _ttsPaused = false;
  List<List<int>> _ttsSpans = []; // 每句[start,end]
  int _ttsSentenceIdx = 0;
  int _ttsHlStart = -1;
  int _ttsHlEnd = -1;
  final TextEditingController _reviewController =
      TextEditingController(); // 修改意见
  Map<String, String> _reviewResults = {}; // 文件path → 问题摘要（找问题结果持久化）
  final Map<String, String> _reviewFull = {}; // v383：文件path → 审核结果全文（重启恢复用）
  // v356：修改意见按文件隔离（path → 意见全文，持久化detect_reviews）
  final Map<String, String> _reviewByFile = {};
  Timer? _reviewSaveDebounce;

  /// v356：当前打开文件的path（无选中返回null）
  String? get _currentFilePath {
    if (_currentIndex < 0 || _currentIndex >= _visibleFiles.length) return null;
    return _visibleFiles[_currentIndex]['path'] as String?;
  }

  /// v356：意见持久化（500ms防抖）
  void _persistReviews() {
    _reviewSaveDebounce?.cancel();
    _reviewSaveDebounce = Timer(const Duration(milliseconds: 500), () {
      try {
        AppState.instance.storage.writeBookData(
          'detect_reviews',
          _reviewByFile,
        );
      } catch (_) {}
    });
  }

  String? _filesSignature;

  /// 按筛选模式过滤的可见文件
  List<Map<String, dynamic>> get _visibleFiles => switch (_filterMode) {
    1 => _files.where((f) => f['isRewrite'] != true).toList(),
    2 => _files.where((f) => f['isRewrite'] == true).toList(),
    _ => _files,
  };
  VoidCallback? _stateListener;
  AppState? _listenedState;

  // 签名含length+内容长度+版本和：同场景重创（v1→v2，length不变）也能触发刷新
  String _sig(AppState s) =>
      '${s.currentBook}|${s.writings.length}|${s.writings.values.fold<int>(0, (a, w) => a + w.content.length)}|${s.writings.values.fold<int>(0, (a, w) => a + w.version)}';

  @override
  /// 恢复浏览状态（筛选模式；当前文件需等文件列表加载后按名匹配）
  void _restoreUiState() {
    try {
      final fm = AppState.instance.uiGet('detect', 'filterMode');
      if (fm is int && fm >= 0 && fm <= 2) _filterMode = fm;
    } catch (_) {}
  }

  /// 文件列表加载后恢复当前文件（按文件名匹配，per-book）
  void _restoreCurrentFile() {
    try {
      final name = AppState.instance.uiGet('detect', 'currentFile');
      if (name is String && name.isNotEmpty && _files.isNotEmpty) {
        final idx = _files.indexWhere((f) => f['name'] == name);
        if (idx >= 0) {
          _currentIndex = idx;
          _openFile(idx);
        }
      }
    } catch (_) {}
    if (mounted) setState(() {});
  }

  void _saveUiState() {
    final f = _currentIndex >= 0 && _currentIndex < _files.length
        ? _files[_currentIndex]
        : null;
    AppState.instance.uiSet('detect', 'filterMode', _filterMode);
    AppState.instance.uiSet('detect', 'currentFile', f?['name'] ?? '');
  }

  void initState() {
    super.initState();
    _restoreUiState();
    // v356：载入按文件隔离的修改意见
    try {
      final saved = AppState.instance.storage.readBookData('detect_reviews');
      if (saved is Map) {
        saved.forEach((k, v) => _reviewByFile[k.toString()] = v.toString());
      }
    } catch (_) {}
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final state = context.read<AppState>();
      _listenedState = state;
      _loadReviewResults();
      _loadWritings();
      _restoreCurrentFile();
      _filesSignature = _sig(state);
      // v469对齐：切书/新创作后重读文件列表（v469在switchToSection每次renderDetectFiles）
      _stateListener = () {
        if (!mounted) return;
        final sig = _sig(_listenedState!);
        if (sig != _filesSignature) {
          _filesSignature = sig;
          // v264：防抖800ms——保存流程saveWritings先于txt落盘触发重扫，
          // 瞬时空文件夹误报"正文文件夹为空"（用户实测06:45:52竞态日志）
          _rescanDebounce?.cancel();
          _rescanDebounce = Timer(const Duration(milliseconds: 800), () {
            if (mounted) _loadWritings();
          });
        }
      };
      state.addListener(_stateListener!);
    });
  }

  @override
  void dispose() {
    _rescanDebounce?.cancel(); // v264防抖句柄
    // v356：退出前把意见落盘（防抖中的也要立即写）
    _reviewSaveDebounce?.cancel();
    try {
      if (_reviewByFile.isNotEmpty) {
        AppState.instance.storage.writeBookData(
          'detect_reviews',
          _reviewByFile,
        );
      }
    } catch (_) {}
    if (_stateListener != null && _listenedState != null) {
      _listenedState!.removeListener(_stateListener!);
    }
    // 退出页面停朗读
    if (_ttsPlaying) {
      AppState.instance.tts.stop();
    }
    _reviewController.dispose();
    super.dispose();
  }

  void _addLog(String msg) {
    setState(() {
      _logs.add(msg);
      if (_logs.length > 100) _logs.removeAt(0);
    });
    AppState.instance.apiLog(msg); // 页面日志同步全局终端（信息出口合一）
  }

  /// 找问题结果持久化（文件path → 问题摘要）
  void _loadReviewResults() {
    try {
      final state = context.read<AppState>();
      final raw = state.storage.readGlobalJson('review_results');
      if (raw is Map) {
        _reviewResults = raw.map(
          (k, v) => MapEntry(k.toString(), v.toString()),
        );
      }
      final rawFull = state.storage.readGlobalJson('review_results_full');
      if (rawFull is Map) {
        _reviewFull.clear();
        rawFull.forEach(
          (k, v) => _reviewFull[k.toString()] = v.toString(),
        );
      }
    } catch (_) {}
  }

  void _saveReviewResults() {
    try {
      final state = context.read<AppState>();
      state.storage.writeGlobal('review_results', jsonEncode(_reviewResults));
    state.storage.writeGlobal('review_results_full', jsonEncode(_reviewFull));
    } catch (_) {}
  }

  /// 默认指向书目的正文文件夹（v469 renderDetectFiles：列writings下全部非空txt，排序）
  void _loadWritings() {
    final state = context.read<AppState>();
    final List<Map<String, dynamic>> files = [];
    // 一创正文（writings/）
    try {
      final wdir = '${state.storage.bookPath}writings';
      final names = state.storage.listFiles(wdir)..sort();
      for (final name in names) {
        if (!name.endsWith('.txt')) continue;
        try {
          final path = '$wdir/$name';
          final content = state.storage.readFile(path);
          if (content == null || content.trim().isEmpty) continue;
          files.add({
            'name': name,
            'path': path,
            'content': content,
            'wordCount': content.length,
            'isWritings': true,
            'isRewrite': false,
          });
        } catch (_) {}
      }
    } catch (_) {}
    // 二创正文（二创/）
    try {
      final rdir = '${state.storage.bookPath}二创';
      final names = state.storage.listFiles(rdir)..sort();
      for (final name in names) {
        if (!name.endsWith('.txt')) continue;
        try {
          final path = '$rdir/$name';
          final content = state.storage.readFile(path);
          if (content == null || content.trim().isEmpty) continue;
          files.add({
            'name': '$name（二创）',
            'path': path,
            'content': content,
            'wordCount': content.length,
            'isWritings': true,
            'isRewrite': true,
          });
        } catch (_) {}
      }
    } catch (_) {}

    final external = _files.where((f) => f['isWritings'] != true).toList();
    setState(() {
      _files
        ..clear()
        ..addAll(files)
        ..addAll(external);
      if (_currentIndex >= _files.length) _currentIndex = _files.length - 1;
    });
    if (files.isEmpty && external.isEmpty) {
      _addLog('正文文件夹为空——请先在"创作"页面创作正文');
    }
  }

  /// v264：重扫防抖句柄
  Timer? _rescanDebounce;

  void _openFile(int i) {
    // v356：守卫对齐可见列表（调用方传的都是可见索引）
    if (i < 0 || i >= _visibleFiles.length) return;
    setState(() {
      _currentIndex = i;
      // v356：结果与意见跟随文件——切文件即载入该文件自己的记录
      final path = _visibleFiles[i]['path'] as String?;
      _resultText =
          (path != null ? _reviewFull[path] : null) ??
          (path != null ? _reviewResults[path] : null) ??
          '';
      _reviewController.text =
          (path != null ? _reviewByFile[path] : null) ?? '';
      // v638：列表保持展开（原v379b点文件自动折叠取消——用户要求默认展开列表）
    });
    _saveUiState(); // 记住当前文件（重启恢复）
  }

  /// v382：就地编辑保存——更新内存内容+写回txt（滚动模式点击正文进入编辑）
  void _saveEditedContent(String text) {
    if (_currentIndex < 0 || _currentIndex >= _visibleFiles.length) return;
    final f = _visibleFiles[_currentIndex];
    final path = f['path'] as String?;
    if (path == null) return;
    f['content'] = text;
    f['wordCount'] = text.length;
    // 同步 _files 里的同 path 项（筛选 getter 引用同一map则无需，双保险）
    for (final g in _files) {
      if (g['path'] == path) {
        g['content'] = text;
        g['wordCount'] = text.length;
      }
    }
    context.read<AppState>().storage.writeFile(path, text);
    setState(() {});
  }

  /// 外部选文件（次要入口，v469无此功能但保留不冲突）
  Future<void> _pickFile(AppState state) async {
    final result = await FilePickerService.pickTextFile();
    if (result == null) return;

    try {
      final bytes = await result.readAsBytes();
      final text = EncodingDetector.decode(Uint8List.fromList(bytes));
      final fileName = result.name;
      setState(() {
        _files.add({
          'name': fileName,
          'path': result.path,
          'content': text,
          'wordCount': text.length,
          'isWritings': false,
        });
        _currentIndex = _files.length - 1;
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('读取失败: $e')));
      }
    }
  }

  /// v468分句：保留标点和引号
  List<List<int>> _splitSentenceSpans(String text) {
    final spans = <List<int>>[];
    final re = RegExp(r'[^。！？!?.\n\u3000]+[。！？!?.\n\u3000]*[“”‘’「」『』]*');
    for (final m in re.allMatches(text)) {
      if (m.start < m.end && m.group(0)!.trim().isNotEmpty) {
        spans.add([m.start, m.end]);
      }
    }
    return spans;
  }

  Future<void> _playNextSentence(AppState state) async {
    if (!_ttsPlaying || _ttsPaused) return;
    final f = _files.isNotEmpty
        ? _files[_currentIndex.clamp(0, _files.length - 1)]
        : null;
    final content = (f?['content'] as String?) ?? '';
    if (_ttsSentenceIdx >= _ttsSpans.length) {
      // 读完当前文件，自动下一个文件
      if (_currentIndex < _visibleFiles.length - 1) {
        _openFile(_currentIndex + 1);
        await Future.delayed(const Duration(milliseconds: 300));
        if (!_ttsPlaying) return;
        await _startTTS(state);
      } else {
        await _stopTTS(state);
      }
      return;
    }
    final span = _ttsSpans[_ttsSentenceIdx];
    _ttsHlStart = span[0];
    _ttsHlEnd = span[1];
    if (mounted) setState(() {});
    // 滚动跟随/翻页联动由_DtScrollView/_DtPagedView组件内部处理（didUpdateWidget监听hlStart）
    // 预缓存下一句（对齐主页阅读器：播放当前句时提前合成下一句）
    if (_ttsSentenceIdx + 1 < _ttsSpans.length) {
      final next = _ttsSpans[_ttsSentenceIdx + 1];
      state.tts.prefetch(content.substring(next[0], next[1]));
    }
    await state.tts.speak(
      content.substring(span[0], span[1]),
      onDone: () {
        if (!_ttsPlaying || _ttsPaused) return;
        _ttsSentenceIdx++;
        _playNextSentence(state);
      },
      onError: () {
        if (!_ttsPlaying || _ttsPaused) return;
        _ttsSentenceIdx++;
        _playNextSentence(state);
      },
    );
  }

  Future<void> _startTTS(AppState state) async {
    final f = _files.isNotEmpty
        ? _files[_currentIndex.clamp(0, _files.length - 1)]
        : null;
    final content = _applyNameMap(
      state,
      (f?['content'] as String?) ?? '',
    );
    if (content.isEmpty) return;
    _ttsSpans = _splitSentenceSpans(content);
    _ttsSentenceIdx = 0;
    _ttsPlaying = true;
    _ttsPaused = false;
    _ttsHlStart = -1;
    _ttsHlEnd = -1;
    if (mounted) setState(() {});
    await _playNextSentence(state);
  }

  Future<void> _stopTTS(AppState state) async {
    _ttsPlaying = false;
    _ttsPaused = false;
    _ttsHlStart = -1;
    _ttsHlEnd = -1;
    await state.tts.stop();
    if (mounted) setState(() {});
  }

  Future<void> _toggleTTS(AppState state) async {
    if (_ttsPlaying) {
      await _stopTTS(state);
    } else {
      await _startTTS(state);
    }
  }

  /// 暂停/继续朗读
  Future<void> _togglePauseTTS(AppState state) async {
    final f = _files.isNotEmpty
        ? _files[_currentIndex.clamp(0, _files.length - 1)]
        : null;
    final content = (f?['content'] as String?) ?? '';
    if (!_ttsPlaying) return;
    if (_ttsPaused) {
      _ttsPaused = false;
      if (mounted) setState(() {});
      final span = _ttsSpans[_ttsSentenceIdx.clamp(0, _ttsSpans.length - 1)];
      await state.tts.speak(
        content.substring(span[0], span[1]),
        onDone: () {
          if (!_ttsPlaying || _ttsPaused) return;
          _ttsSentenceIdx++;
          _playNextSentence(state);
        },
      );
    } else {
      _ttsPaused = true;
      await state.tts.stop();
      if (mounted) setState(() {});
    }
  }

  /// 模式切换（📑翻页↔📜滚动）
  void _switchMode() {
    setState(() => _pageMode = !_pageMode);
  }

  /// 页边界换文件（组件onPrev/onNext在页边界触发）
  void _turnPage(int delta, AppState state) {
    final next = _currentIndex + delta;
    if (next >= 0 && next < _visibleFiles.length) {
      _openFile(next);
    }
  }

  /// 删除文件（v469 deleteDetectFile，仅writings内文件）
  void _deleteFile(AppState state) {
    if (_currentIndex < 0) return;
    final file = _visibleFiles[_currentIndex];
    if (file['isWritings'] != true) return;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除文件'),
        content: Text('确定删除 ${file['name']}？不可恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () {
              Navigator.pop(ctx);
              try {
                state.storage.deleteFile(file['path']);
                _reviewResults.remove(file['path']);
                _saveReviewResults();
                setState(() {
                  _files.removeAt(_currentIndex);
                  _currentIndex = _files.isEmpty
                      ? -1
                      : _currentIndex.clamp(0, _files.length - 1);
                  _resultText = '';
                });
                _addLog('已删除：${file['name']}');
              } catch (e) {
                _addLog('删除失败：$e');
              }
            },
            child: const Text('删除'),
          ),
        ],
      ),
    );
  }

  /// v388：名称映射表替换——v702改调共用NameMap工具（与浏览层换名预览同逻辑）
  static Map<String, List<(String, String)>>? _nameMapCache;
  static String? _nameMapCacheSrc;

  String _applyNameMap(AppState state, String text) {
    if (!state.nameReplaceEnabled) return text;
    final src = state.worldBook?.nameMapping ?? '';
    if (src.isEmpty || text.isEmpty) return text;
    if (_nameMapCacheSrc != src || _nameMapCache == null) {
      _nameMapCache = {'pairs': NameMap.parse(src)};
      _nameMapCacheSrc = src;
    }
    final pairs = _nameMapCache!['pairs'] as List<(String, String)>;
    return NameMap.apply(text, pairs);
  }

  /// v407：换名体检——AI审读替换后正文，对照映射表找残留/漏映射/违和，建议具体新名
  Future<void> _nameCheck(AppState state, String text) async {
    if (text.trim().isEmpty) return;
    final mapping = state.worldBook?.nameMapping ?? '';
    if (mapping.isEmpty) {
      _addLog('⚠ 映射表为空——先在改编页生成映射表再体检');
      return;
    }
    setState(() {
      _isProcessing = true;
      _statusText = '正在换名体检...';
      _resultText = '';
    });
    try {
      final systemPrompt =
          '你是换名质检员。用户把小说正文按名称映射表做了字符串替换，你要检查替换质量。\n\n'
          '## 检查维度\n'
          '1. 残留原名：映射表里"原著名"仍出现在正文中未被替换\n'
          '2. 漏映射：正文出现但映射表里没有的人名/称谓变体（如"X镖头""X老头"这类姓+称谓形式）\n'
          '3. 替换违和：替换后新旧混杂不通顺（如"新名镖头"其实新名是执事身份、性别不符的称谓）\n\n'
          '## 建议必须具体\n'
          '- 漏映射行：给出建议映射"原著名→新名（定位）"，新名要参考映射表已有新名的命名风格（性别/朝代/身份一致），不能写"需要补充映射"这种空话\n'
          '- 违和处：给出具体修改建议（改成什么称谓/怎么改写）\n'
          '- 合称缩略（如"史、郑二位镖头"两人姓压缩合写）：字符串替换无法处理，标注"合称缩略，建议手改正文"，不要给映射行\n\n'
          '## 名称映射表\n' +
          mapping +
          '\n\n## 输出\n'
          'JSON：\n'
          '{\n'
          '  "issues": [\n'
          '    {"type": "残留原名|漏映射|替换违和|合称缩略", "evidence": "正文原句片段（20字内）", "suggestion_line": "建议映射行，格式如 史镖头→新名（定位）；不适用的填空字符串", "advice": "具体修改建议（怎么改、改成什么）"}\n'
          '  ],\n'
          '  "overall": "总体结论（50字内）"\n'
          '}\n'
          '没有问题的维度不要编造。issues最多20条，按重要性排序。';

      final userPrompt =
          '请对以下替换后的正文做换名体检：\n\n$text';

      state.api.clearAbort();
      state.userAborted = false;
      _addLog('开始换名体检：${text.length}字');
      final ok = await PromptPreview.maybePreview(
        context,
        sysPrompt: systemPrompt,
        userPrompt: userPrompt,
        title: '换名体检词链预览',
        enabled: state.detectPromptPreview,
      );
      if (!ok) {
        _addLog('用户在预览后终止');
        setState(() => _isProcessing = false);
        return;
      }
      final config = state.getApiConfig('detect');
      final result = await state.api.callApi(
        systemPrompt: systemPrompt,
        userPrompt: userPrompt,
        apiConfig: config,
      );
      if (result.isSuccess) {
        var content = result.content.trim();
        if (content.startsWith('\`\`\`')) {
          content = content.replaceAll(RegExp(r'^\`\`\`(?:json)?\s*'), '');
          content = content.replaceAll(RegExp(r'\s*\`\`\`$'), '');
        }
        try {
          final json =
              (jsonDecode(content) as Map).cast<String, dynamic>();
          final issues =
              (json['issues'] as List?)?.cast<Map<String, dynamic>>() ?? [];
          final overall = (json['overall'] ?? '').toString();
          _nameCheckIssues = issues;
          final sb = StringBuffer();
          sb.writeln('换名体检：${issues.length}项发现');
          for (final i in issues) {
            sb.writeln('【${i['type']}】${i['evidence']}');
            final line = (i['suggestion_line'] ?? '').toString().trim();
            if (line.isNotEmpty) sb.writeln('  建议映射：$line');
            sb.writeln('  建议：${i['advice']}');
          }
          sb.writeln(overall);
          setState(() => _resultText = sb.toString());
          _addLog('✓ 体检完成：${issues.length}项发现');
        } catch (e) {
          setState(() => _resultText = content);
          _addLog('⚠ JSON解析失败，显示原始文本');
        }
      } else {
        setState(() => _resultText = '体检失败：${result.error}');
        _addLog('❌ API错误：${result.error}');
      }
    } catch (e) {
      setState(() => _resultText = '异常：$e');
      _addLog('❌ 异常：$e');
    } finally {
      if (mounted) setState(() => _isProcessing = false);
    }
  }

  /// v407：把体检建议行并入映射表（同名不覆盖）
  void _mergeCheckLines(AppState state) {
    final lines = <(String, String)>[];
    for (final i in _nameCheckIssues) {
      final line = (i['suggestion_line'] ?? '').toString().trim();
      final m = RegExp(
        r'^([^\s→>]+?)\s*[→>]\s*([^\s（(]+)',
      ).firstMatch(line);
      if (m != null) lines.add((m.group(1)!, m.group(2)!));
    }
    if (lines.isEmpty) {
      ScaffoldMessenger.of(this.context).showSnackBar(
        const SnackBar(content: Text('没有可并入的映射行')),
      );
      return;
    }
    final wb = state.worldBook!;
    final existing = wb.nameMapping;
    final existingNames = existing
        .split('\n')
        .map(
          (l) => RegExp(
            r'^\s*([^\s→>]+?)\s*[→>]',
          ).firstMatch(l)?.group(1)?.trim(),
        )
        .whereType<String>()
        .toSet();
    var added = 0;
    final buf = StringBuffer(
      existing.isEmpty ? '' : existing.replaceAll(RegExp(r'\n+$'), '\n'),
    );
    for (final (orig, newName) in lines) {
      if (existingNames.contains(orig)) continue;
      buf.writeln('$orig→$newName');
      existingNames.add(orig);
      added++;
    }
    wb.nameMapping = buf.toString();
    state.saveWorldBook();
    state.refresh();
    ScaffoldMessenger.of(this.context).showSnackBar(
      SnackBar(content: Text('✓ 已并入$added行映射（已存在的跳过）')),
    );
    _addLog('✓ 并入$added行映射建议');
  }

  /// 找问题审核：AI审读正文找逻辑/人设/节奏/文笔问题（替代AI浓度检测）
  Future<void> _findProblems(AppState state, String text) async {
    if (text.trim().isEmpty) return;
    setState(() {
      _isProcessing = true;
      _statusText = '正在找问题...';
      _resultText = '';
    });

    try {
      final systemPrompt =
          '你是一位资深网文编辑和审稿人。你的任务是审读给定的小说正文，找出其中的问题。\n\n' +
          '## 审查维度\n' +
          '1. 情节逻辑：逻辑漏洞、因果不通、前后矛盾\n' +
          '2. 人设一致性：角色行为是否符合性格设定，有无OOC\n' +
          '3. 节奏问题：拖沓、跳跃、高潮不足、分镜比例失调\n' +
          '4. 文笔质量：病句、用词不当、描写空洞、AI味（如"宛如""仿佛""映入眼帘"等AI常用词）\n' +
          '5. 读者体验：毒点、出戏、无聊段落、不合理之处\n' +
          '6. 结构完整：遗漏的分镜、未交代的伏笔、断裂的过渡\n\n' +
          '## 输出格式\n' +
          'JSON：\n' +
          '{\n' +
          '  "problem_count": 数字,\n' +
          '  "problems": [\n' +
          '    {"type": "类型", "location": "大致位置（引用原文片段或行号）", "description": "问题描述", "suggestion": "修改建议"}\n' +
          '  ],\n' +
          '  "overall": "总体评价（100字内）"\n' +
          '}';

      final userPrompt = '请审读以下正文并找出问题：\n\n$text';

      state.api.clearAbort(); state.userAborted = false; // 清除上次abort残留（v187）
      _addLog('开始找问题：${text.length}字');
      final ok = await PromptPreview.maybePreview(
        context,
        sysPrompt: systemPrompt,
        userPrompt: userPrompt,
        title: '找问题审核词链预览',
        enabled: state.detectPromptPreview,
      );
      if (!ok) {
        _addLog('用户在预览后终止');
        return;
      }
      final config = state.getApiConfig('detect');
      final result = await state.api.callApi(
        systemPrompt: systemPrompt,
        userPrompt: userPrompt,
        apiConfig: config,
      );

      if (result.isSuccess) {
        _addLog('API返回：${result.content.length}字');
        var content = result.content.trim();
        if (content.startsWith('```')) {
          content = content.replaceAll(RegExp(r'^```(?:json)?\s*'), '');
          content = content.replaceAll(RegExp(r'\s*```$'), '');
        }
        try {
          final json = jsonDecode(content) as Map<String, dynamic>;
          final count = json['problem_count'] ?? 0;
          final problems =
              (json['problems'] as List?)?.cast<Map<String, dynamic>>() ?? [];
          final overall = json['overall'] ?? '';

          if (_currentIndex >= 0) {
            final path = _currentIndex < _visibleFiles.length
                ? _visibleFiles[_currentIndex]['path'] as String
                : '';
            _reviewResults[path] = '$count个问题';
            _saveReviewResults();
            // v356：意见覆盖式填入该文件自己的记录（per-file）
            if (problems.isNotEmpty) {
              final suggestions = problems
                  .map(
                    (p) =>
                        '- ${(p['suggestion'] ?? p['description'] ?? '').toString()}',
                  )
                  .join('\n');
              _reviewByFile[path] = suggestions;
              _persistReviews();
              if (_currentFilePath == path) {
                _reviewController.text = suggestions;
              }
            }
          }

          final sb = StringBuffer();
          sb.writeln('找到 $count 个问题\n');
          for (var i = 0; i < problems.length; i++) {
            final p = problems[i];
            sb.writeln(
              '${i + 1}. 【${p['type'] ?? ''}】${p['description'] ?? ''}',
            );
            if ((p['location'] ?? '').toString().isNotEmpty)
              sb.writeln('   位置：${p['location']}');
            if ((p['suggestion'] ?? '').toString().isNotEmpty)
              sb.writeln('   建议：${p['suggestion']}');
            sb.writeln();
          }
          sb.writeln('总体评价：$overall');

          final fullText = sb.toString();
          if (_currentIndex >= 0 &&
              _currentIndex < _visibleFiles.length) {
            _reviewFull[_visibleFiles[_currentIndex]['path'] as String] =
                fullText;
            _saveReviewResults();
          }
          setState(() => _resultText = fullText);
          _addLog('✓ 找到 $count 个问题');
        } catch (e) {
          setState(() => _resultText = content);
          _addLog('⚠ JSON解析失败，显示原始文本');
        }
      } else {
        setState(() => _resultText = '审核失败：${result.error}');
        _addLog('❌ API错误：${result.error}');
      }
    } catch (e) {
      setState(() => _resultText = '异常：$e');
      _addLog('❌ 异常：$e');
    } finally {
      setState(() {
        _isProcessing = false;
        _statusText = '';
      });
    }
  }

  /// v358：转发当前正文txt——系统分享面板（QQ/微信/蓝牙等任选）。
  /// 一创/二创文件本来就在磁盘上，直接share文件本体，接收方拿到真txt
  Future<void> _shareCurrentFile() async {
    final path = _currentFilePath;
    if (path == null) {
      _addLog('⚠ 没有打开的文件——先在列表里选一个正文');
      return;
    }
    try {
      // v359b：列表里的path是相对basePath的相对路径（如 books/书/writings/x.txt），
      // share_plus要求绝对路径——非'/'开头则拼上存储根目录
      var abs = path;
      if (!abs.startsWith('/')) {
        final base = AppState.instance.storage.basePath;
        abs = base.endsWith('/') ? '$base$abs' : '$base/$abs';
      }
      final f = File(abs);
      if (!f.existsSync()) {
        _addLog('❌ 文件不存在：$abs');
        return;
      }
      var name = abs.split('/').last;
      var sharePath = abs;
      // v405：换名开启且映射表非空=转发替换后副本（磁盘原文件不动）
      final state3 = AppState.instance;
      final swapped = _applyNameMap(state3, f.readAsStringSync());
      if (swapped != f.readAsStringSync()) {
        final base = state3.storage.basePath;
        final tmpDir = Directory(
          base.endsWith('/') ? '${base}tmp' : '$base/tmp',
        );
        if (!tmpDir.existsSync()) tmpDir.createSync(recursive: true);
        sharePath = '${tmpDir.path}/换名_$name';
        File(sharePath).writeAsStringSync(swapped);
        name = '换名_$name';
      }
      await Share.shareXFiles([XFile(sharePath)], text: name);
      _addLog('✓ 已调起系统分享：$name');
    } catch (e) {
      _addLog('❌ 分享失败：$e');
    }
  }

  /// v356：当前文件对应的场景切片范文（前1000字，与创作页同源）。
  /// 仅一创文件名"弧线N_场景M_…"能映射；返回''=无范文
  String _sceneSampleForCurrentFile() {
    final path = _currentFilePath;
    if (path == null) return '';
    final name = path.split('/').last;
    final m = RegExp(r'弧线(\d+)_场景(\d+)').firstMatch(name);
    if (m == null) return '';
    final scenes = AppState.instance.arcScenes[m.group(1)!] ?? const [];
    final si = (int.parse(m.group(2)!) - 1);
    if (si < 0 || si >= scenes.length) return '';
    final st = scenes[si].text;
    if (st.isEmpty) return '';
    final end = 1000 > st.length ? st.length : 1000;
    return st.substring(0, end);
  }

  /// 二创：AI按修改意见+文风/内容素材重写正文，保存到二创目录
  Future<void> _rewrite(AppState state, String text) async {
    if (text.trim().isEmpty) return;
    final review = _reviewController.text.trim();
    setState(() {
      _isProcessing = true;
      _statusText = '正在二创...';
    });

    try {
      final systemPrompt =
          '你是一位网文创作助手。你的任务是根据一创正文、修改意见和素材，进行二次创作（二创），产出一个改进后的版本。\n\n' +
          '## 二创原则\n' +
          '1. 以一创正文为基础，不推翻重写，而是改进润色\n' +
          '2. 修改意见优先级最高——逐条落实修改意见中的要求\n' +
          '3. 文风素材：学习笔触腔调遣词造句，提升文风质感，不抄袭具体内容\n' +
          '4. 内容素材：根据设定恰当巧妙融入正文，不可突兀\n' +
          '5. 保持原文的分镜结构和场景划分不变，只改写文字内容\n' +
          '6. 保持原文的篇幅比例和叙事节奏\n\n' +
          '## 输出格式\n' +
          '直接输出二创正文（纯文本，含章节标题和分镜标记，和一创格式一致）。不要输出任何说明文字。';

      final sb = StringBuffer();
      sb.writeln('## 一创正文');
      sb.writeln(text);
      sb.writeln();
      if (review.isNotEmpty) {
        sb.writeln('## 修改意见');
        sb.writeln(review);
        sb.writeln();
      }
      // v356：模仿作者——范文取自本文件对应场景的锚定切片前1000字（与创作页同源）
      // 仅一创文件（文件名=弧线N_场景M_…）能映射到场景切片；二创/外部文件跳过
      if (state.writingImitateAuthor) {
        final sample = _sceneSampleForCurrentFile();
        if (sample.isNotEmpty) {
          sb.writeln('## 文风范文（学习其叙事文风笔触腔调，禁止搬运情节与措辞）');
          sb.writeln(sample);
          sb.writeln();
          _addLog('✓ 注入文风范文${sample.length}字（场景切片前1000字）');
        } else {
          _addLog('⚠ 模仿作者已开，但当前文件无法映射到场景切片——未注入范文');
        }
      }
      final styleAtts = state.writingAttachments
          .where((a) => a['type'] == 'style')
          .toList();
      final contentAtts = state.writingAttachments
          .where((a) => a['type'] != 'style')
          .toList();
      if (styleAtts.isNotEmpty) {
        sb.writeln('## 文风素材（学习其笔触腔调遣词造句，不引用具体内容）');
        for (final a in styleAtts) {
          sb.writeln('### ${a['name']}');
          sb.writeln(a['content']);
          sb.writeln();
        }
      }
      if (contentAtts.isNotEmpty) {
        sb.writeln('## 内容素材（根据设定和剧情恰当巧妙融入正文）');
        for (final a in contentAtts) {
          sb.writeln('### ${a['name']}');
          sb.writeln(a['content']);
          sb.writeln();
        }
      }

      state.api.clearAbort(); state.userAborted = false; // 清除上次abort残留（v187）
      _addLog(
        '开始二创：一创${text.length}字${review.isNotEmpty ? "+修改意见${review.length}字" : ""}+素材${state.writingAttachments.length}个，formatMode=${state.getApiConfig('detect').formatMode}',
      );
      final ok = await PromptPreview.maybePreview(
        context,
        sysPrompt: systemPrompt,
        userPrompt: sb.toString(),
        title: '二创词链预览',
        enabled: state.detectPromptPreview,
      );
      if (!ok) {
        _addLog('用户在预览后终止');
        return;
      }
      final config = state.getApiConfig('detect');
      final result = await state.api.callApi(
        systemPrompt: systemPrompt,
        userPrompt: sb.toString(),
        apiConfig: config,
      );
      // config声明保持原位（下方），此日志用延迟读取
      void logMode() {
        _addLog('formatMode=${config.formatMode}');
      }
      logMode();

      if (result.isSuccess) {
        _addLog('二创返回：${result.content.length}字');
        // v256：二创正文按API模式分支归一化——json模式{"content":…}
        // 包装解码（\n转义），兼容模式文本容错（字面\n/结构漂移）
        final rewrite = TextCleaner.normalizeAiOutput(
          result.content,
          jsonMode: config.formatMode == 'json',
        );
        final state2 = context.read<AppState>();
        final rdir = '${state2.storage.bookPath}二创';
        // v354：越界守卫——_currentIndex=-1（未选中/列表空）或过滤后越界时
        // _visibleFiles[-1]抛RangeError致保存中断（2652字白生成实证）
        if (_currentIndex < 0 || _currentIndex >= _visibleFiles.length) {
          _addLog('❌ 保存失败：当前未选中素材文件（索引$_currentIndex无效），请先在列表选中一项再二创');
          return;
        }
        var saveName = _visibleFiles[_currentIndex]['name'] as String;
        if (saveName.endsWith('（二创）'))
          saveName = saveName.substring(0, saveName.length - 4);
        saveName = saveName.replaceAll('.txt', '_二创.txt');
        final savePath = '$rdir/$saveName';
        state2.storage.writeFile(savePath, rewrite);
        _addLog('✓ 二创已保存：$saveName（${rewrite.length}字）');
        _loadWritings();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('✓ 二创已保存到 二创/$saveName'),
              duration: const Duration(seconds: 2),
            ),
          );
        }
      } else {
        _addLog('❌ 二创API错误：${result.error}');
        if (mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text('二创失败：${result.error}')));
        }
      }
    } catch (e) {
      _addLog('❌ 异常：$e');
    } finally {
      setState(() {
        _isProcessing = false;
        _statusText = '';
      });
    }
  }

  /// 选素材文件（文风/内容，复用state.writingAttachments）
  Future<void> _pickAttachment(String type) async {
    final result = await FilePickerService.pickTextFile();
    if (result == null) return;
    try {
      final bytes = await result.readAsBytes();
      final text = EncodingDetector.decode(Uint8List.fromList(bytes));
      if (text.trim().isEmpty) {
        if (mounted)
          ScaffoldMessenger.of(context)
              .showSnackBar(const SnackBar(content: Text('文件内容为空')));
        return;
      }
      final state = context.read<AppState>();
      state.addWritingAttachment({
        'name': result.name,
        'content': text,
        'type': type,
      });
      if (mounted) {
        setState(() {});
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '已添加${type == 'style' ? '文风' : '内容'}素材：${result.name}（${text.length}字）',
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted)
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('读取失败: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context); // AutomaticKeepAlive必须
    final state = context.watch<AppState>();
    final file = _currentIndex >= 0 && _currentIndex < _visibleFiles.length
        ? _visibleFiles[_currentIndex]
        : null;
    // v388：换名——映射表开启时，显示/复制/朗读统一用替换后文本（偏移量一致）
    final state0 = context.read<AppState>();
    // v547：显示层纯正文修复——先解码字面\n再剥分镜结构（存量创作txt
    // 结构行+\n残留的二创显示兜底，与磁盘纯正文约定对齐）
    final content =
        file != null
        ? TextCleaner.stripShotHeaders(
            TextCleaner.decodeLiteralNewlines(
              _applyNameMap(state0, file['content'] as String? ?? ''),
            ),
            keepModelNote: true, // v609：显示不剥备注行（文件里有就该显示）
          )
        : '';

    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: SingleChildScrollView(
          child: Column(
            children: [
              // 顶行：高频操作（v210单行紧凑：找问题/二创/预览/刷新/选文件/⚙）
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 2, 8, 1),
                child: Row(
                  children: [
                    // 预览开关（轻量文字按钮，省 FilterChip 的宽 padding）
                    // v377：统一词链开关（MiniButton背景色=开，与创作页一致）
                    MiniButton(
                      label: '词链',
                      primary: state.detectPromptPreview,
                      onTap: () => state.setDetectPromptPreview(
                        !state.detectPromptPreview,
                      ),
                    ),
                    const Spacer(),
                    // v638：刷新按钮移除（initState+_stateListener签名防抖已自动刷新）
                    MiniButton(label: '选文件', onTap: () => _pickFile(state)),
                    const SizedBox(width: 4),
                    MiniButton(
                      label: '⚙ API',
                      onTap: () => showV119Sheet(
                        context,
                        title: 'API设置 · 二创',
                        child: ApiConfigPanel(
                          config: state.detectApi,
                          section: 'detect',
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              // 文件列表（可折叠，默认展开；一创/二创筛选）
              // v379b：手动折叠行（替代ExpansionTile——紧凑+点文件自动收起）
              InkWell(
                onTap: () => setState(() => _filesExpanded = !_filesExpanded),
                child: Row(
                  children: [
                    // 一创/二创筛选（左移，v469风格文字按钮）
                    SegmentedButton<int>(
                      segments: const [
                        ButtonSegment(
                          value: 0,
                          label: Text('全部', style: TextStyle(fontSize: 10)),
                        ),
                        ButtonSegment(
                          value: 1,
                          label: Text('一创', style: TextStyle(fontSize: 10)),
                        ),
                        ButtonSegment(
                          value: 2,
                          label: Text('二创', style: TextStyle(fontSize: 10)),
                        ),
                      ],
                      selected: {_filterMode},
                      showSelectedIcon: false,
                      style: const ButtonStyle(
                        visualDensity: VisualDensity.compact,
                      ),
                      onSelectionChanged: (s) => setState(() {
                        _filterMode = s.first;
                        _currentIndex = -1; // 切筛选收起正文
                        _saveUiState();
                      }),
                    ),
                    const SizedBox(width: 8), // Wrap内Spacer失效，用定宽占位
                    // 标题+折叠箭头
                    Text(
                      '文件列表 (${_visibleFiles.length})',
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Icon(
                      _filesExpanded
                          ? Icons.expand_less
                          : Icons.expand_more,
                      size: 18,
                      color: Colors.grey,
                    ),
                  ],
                ),
              ),
              // 列表体（折叠开关：默认展开，点文件自动收起）
              if (_filesExpanded)
                Container(
                  margin: const EdgeInsets.symmetric(horizontal: 8),
                    constraints: const BoxConstraints(
                      maxHeight: 240, // v638：120→240（高度翻倍，默认展开列表）
                    ), // 列表限高滚动，缩小给正文腾空间
                    decoration: BoxDecoration(
                      color: V469Style.surface,
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: V469Style.border),
                    ),
                    child: _files.isEmpty
                        ? Padding(
                            padding: const EdgeInsets.all(20),
                            child: Center(
                              child: Text(
                                '暂无作品文件。\n请先在「创作」页面创作正文。',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  fontSize: 12.5,
                                  color: V469Style.textMuted,
                                  height: 1.6,
                                ),
                              ),
                            ),
                          )
                        : ListView.builder(
                            shrinkWrap: true,
                            padding: const EdgeInsets.all(8),
                            itemCount: _visibleFiles.length,
                            itemBuilder: (ctx, i) {
                              final f = _visibleFiles[i];
                              final fname = f['name'] as String? ?? '';
                              return Container(
                                margin: const EdgeInsets.only(bottom: 6),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 6,
                                ),
                                decoration: BoxDecoration(
                                  color: i == _currentIndex
                                      ? V469Style.accentBg
                                      : V469Style.surfaceAlt,
                                  borderRadius: BorderRadius.circular(4),
                                  border: Border.all(
                                    color: i == _currentIndex
                                        ? V469Style.accentLight
                                        : Colors.transparent,
                                  ),
                                ),
                                child: Column(
                                  children: [
                                    Row(
                                      children: [
                                        // 📄 文件名（点击打开）
                                        Expanded(
                                          child: InkWell(
                                            onTap: () => _openFile(i),
                                            child: Text(
                                              '📄 $fname', // 完整显示：不限行数不截断
                                              style: TextStyle(
                                                fontSize: 12.5,
                                                height: 1.3,
                                                color: V469Style.textMain,
                                                fontWeight: i == _currentIndex
                                                    ? FontWeight.w600
                                                    : FontWeight.w400,
                                              ),
                                            ),
                                          ),
                                        ),
                                        if (f['isWritings'] == true)
                                          Padding(
                                            padding: const EdgeInsets.only(
                                              left: 6,
                                            ),
                                            child: Text(
                                              '${f['wordCount']}字',
                                              style: const TextStyle(
                                                fontSize: 11,
                                                color: V469Style.textMuted,
                                              ),
                                            ),
                                          ),
                                        const SizedBox(width: 6),
                                        // 问题徽章：有审核结果=橙底/无=灰底
                                        Builder(
                                          builder: (ctx) {
                                            final rResult =
                                                _reviewResults[f['path']
                                                        as String? ??
                                                    ''];
                                            return Container(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                    horizontal: 6,
                                                    vertical: 1,
                                                  ),
                                              decoration: BoxDecoration(
                                                color: rResult == null
                                                    ? V469Style.border
                                                    : const Color(0xFFF59E0B),
                                                borderRadius:
                                                    BorderRadius.circular(3),
                                              ),
                                              child: Text(
                                                rResult == null
                                                    ? '未审'
                                                    : rResult,
                                                style: const TextStyle(
                                                  fontSize: 10.5,
                                                  color: Colors.white,
                                                ),
                                              ),
                                            );
                                          },
                                        ),
                                      ],
                                    ),
                                    // ✕ 删除（右对齐，仅writings内文件，v469 deleteDetectFile确认框）
                                    if (f['isWritings'] == true)
                                      Align(
                                        alignment: Alignment.centerRight,
                                        child: GestureDetector(
                                          onTap: () {
                                            setState(() => _currentIndex = i);
                                            _deleteFile(
                                              context.read<AppState>(),
                                            );
                                          },
                                          child: Padding(
                                            padding: const EdgeInsets.only(
                                              top: 3,
                                            ),
                                            child: Text(
                                              '✕ 删除',
                                              style: TextStyle(
                                                fontSize: 11,
                                                color: V469Style.incomplete,
                                                fontWeight: FontWeight.w500,
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                              );
                            },
                          ),
                  ),
              // 进度
              if (_isProcessing)
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: Row(
                    children: [
                      const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                      const SizedBox(width: 8),
                      Text(_statusText, style: const TextStyle(fontSize: 12)),
                    ],
                  ),
                ),
              // 阅读器工具栏 + 正文（自适应高度，整体页面滚动）
              if (file != null)
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 2,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // 工具栏（文字按钮，v469风格；标题全显不截断）
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // 标题行：完整显示（wrap换行，v469对齐"章节标题要全部显示"）
                            Text(
                              '${file['name']} · ${file['wordCount']}字'
                              '${_reviewResults[file['path']] != null ? " · ${_reviewResults[file['path']]}" : ""}',
                              style: const TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                height: 1.3,
                              ),
                            ),
                            const SizedBox(height: 2),
                          ],
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        child: Wrap(
                          spacing: 0,
                          runSpacing: 0,
                          children: [
                            // TTS控制（对齐主页阅读器：朗读/停止+暂停/继续，播放中棕色）
                            if (_ttsPlaying)
                              TextButton(
                                onPressed: () => _togglePauseTTS(state),
                                style: TextButton.styleFrom(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                  ),
                                  minimumSize: const Size(44, 30),
                                ),
                                child: Text(
                                  _ttsPaused ? '继续' : '暂停',
                                  style: const TextStyle(fontSize: 13),
                                ),
                              ),
                            TextButton(
                              onPressed: _isProcessing
                                  ? null
                                  : () => _ttsPlaying
                                        ? _stopTTS(state)
                                        : _startTTS(state),
                              style: TextButton.styleFrom(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                ),
                                minimumSize: const Size(44, 30),
                                foregroundColor: _ttsPlaying
                                    ? const Color(0xFF8B6914)
                                    : null,
                              ),
                              child: Text(
                                _ttsPlaying ? '停止' : '朗读',
                                style: const TextStyle(fontSize: 13),
                              ),
                            ),
                            // v388：换名开关——按映射表替换原著名后显示/复制/朗读
                            TextButton(
                              onPressed: () => context
                                  .read<AppState>()
                                  .setNameReplaceEnabled(
                                    !state.nameReplaceEnabled,
                                  ),
                              style: TextButton.styleFrom(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                ),
                                minimumSize: const Size(44, 30),
                                foregroundColor: state.nameReplaceEnabled
                                    ? const Color(0xFF8B6914)
                                    : Colors.grey,
                              ),
                              child: Text(
                                state.nameReplaceEnabled ? '换名✓' : '换名',
                                style: const TextStyle(fontSize: 13),
                              ),
                            ),
                            // v382：复制按钮——复制当前文件全文（剥[模型/温度]头），点击正文可就地编辑
                            TextButton(
                              onPressed: () {
                                final f = _files.isNotEmpty
                                    ? _visibleFiles[_currentIndex.clamp(
                                        0,
                                        _visibleFiles.length - 1,
                                      )]
                                    : null;
                                if (f == null) return;
                                var txt = _applyNameMap(
                                  context.read<AppState>(),
                                  (f['content'] as String?) ?? '',
                                );
                                // 剥模型/温度备注头（可能多行头）
                                txt = txt.replaceFirst(
                                  RegExp(
                                    r'^\s*\[模型[：:].*?\]\s*\n?',
                                  ),
                                  '',
                                );
                                Clipboard.setData(
                                  ClipboardData(text: txt),
                                );
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text(
                                      '✓ 已复制全文（${txt.length}字，不含模型/温度头）',
                                    ),
                                    duration: const Duration(seconds: 2),
                                  ),
                                );
                              },
                              style: TextButton.styleFrom(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                ),
                                minimumSize: const Size(44, 30),
                              ),
                              child: const Text(
                                '复制',
                                style: TextStyle(fontSize: 13),
                              ),
                            ),
                            TextButton(
                              onPressed: () => setState(
                                () => _fontSize = (_fontSize - 1).clamp(
                                  10.0,
                                  28.0,
                                ),
                              ),
                              style: TextButton.styleFrom(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                ),
                                minimumSize: const Size(36, 30),
                              ),
                              child: const Text(
                                'A-',
                                style: TextStyle(fontSize: 13),
                              ),
                            ),
                            TextButton(
                              onPressed: () => setState(
                                () => _fontSize = (_fontSize + 1).clamp(
                                  10.0,
                                  28.0,
                                ),
                              ),
                              style: TextButton.styleFrom(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                ),
                                minimumSize: const Size(36, 30),
                              ),
                              child: const Text(
                                'A+',
                                style: TextStyle(fontSize: 13),
                              ),
                            ),
                            // 模式切换（v469 dt-mode-btn：📑翻页↔📜滚动）
                            TextButton(
                              onPressed: _switchMode,
                              style: TextButton.styleFrom(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                ),
                                minimumSize: const Size(44, 30),
                                foregroundColor: _pageMode
                                    ? Colors.green.shade700
                                    : null,
                              ),
                              child: Text(
                                _pageMode ? '📜滚动' : '📑翻页',
                                style: const TextStyle(fontSize: 13),
                              ),
                            ),
                            TextButton(
                              onPressed: _isProcessing
                                  ? null
                                  : () => _findProblems(state, content),
                              style: TextButton.styleFrom(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                ),
                                minimumSize: const Size(50, 30),
                              ),
                              child: const Text(
                                '找问题',
                                style: TextStyle(fontSize: 13),
                              ),
                            ),
                            TextButton(
                              onPressed: _isProcessing
                                  ? null
                                  : state.nameReplaceEnabled
                                  ? () => _nameCheck(state, content)
                                  : null,
                              style: TextButton.styleFrom(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                ),
                                minimumSize: const Size(50, 30),
                              ),
                              child: const Text(
                                '换名体检',
                                style: TextStyle(fontSize: 13),
                              ),
                            ),
                            TextButton(
                              onPressed: _isProcessing
                                  ? null
                                  : () => _rewrite(state, content),
                              style: TextButton.styleFrom(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                ),
                                minimumSize: const Size(44, 30),
                                foregroundColor: V469Style.accent,
                              ),
                              child: const Text(
                                '二创',
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),

                            // v358b：转发（系统分享面板直发txt到QQ/微信等）
                            TextButton(
                              onPressed: () => _shareCurrentFile(),
                              style: TextButton.styleFrom(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                ),
                                minimumSize: const Size(44, 30),
                                foregroundColor: V469Style.accent,
                              ),
                              child: const Text(
                                '转发',
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),

                            // v638：转发行删除按钮移除——外层列表删除已带确认框
                          ],
                        ),
                      ),
                      // 正文（限高55%视口：翻页/编辑/滚动三模式统一，无界高度都会堆叠/撑爆）
                      ConstrainedBox(
                        constraints: BoxConstraints(
                          minHeight: 200,
                          maxHeight: MediaQuery.of(context).size.height * 0.55,
                          maxWidth: 620,
                        ),
                        child: Container(
                          width: double.infinity,
                          margin: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                          decoration: BoxDecoration(
                            border: Border.all(color: Colors.grey.shade300),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: _pageMode
                              ? SizedBox(
                                  height:
                                      MediaQuery.of(context).size.height * 0.55,
                                  child: _DtPagedView(
                                    title: (file['name'] as String? ?? ''),
                                    content: content,
                                    fontSize: _fontSize,
                                    lineHeight: 1.8,
                                    hlStart: _ttsPlaying ? _ttsHlStart : -1,
                                    hlEnd: _ttsPlaying ? _ttsHlEnd : -1,
                                    onPrev: () => _turnPage(-1, state),
                                    onNext: () => _turnPage(1, state),
                                  ),
                                )
                              : _DtScrollView(
                                  key: ValueKey(
                                    'dt_${_currentIndex}_$_fontSize',
                                  ),
                                  title: (file['name'] as String? ?? ''),
                                  content: content,
                                  fontSize: _fontSize,
                                  lineHeight: 1.8,
                                  hlStart: _ttsPlaying ? _ttsHlStart : -1,
                                  hlEnd: _ttsPlaying ? _ttsHlEnd : -1,
                                  // v382：就地编辑——点击正文进入编辑态，改动即存盘
                                  onContentEdited: (t) =>
                                      _saveEditedContent(t),
                                  editDisabled: state.nameReplaceEnabled,
                                ),
                        ),
                      ),
                      // 分析结果（可折叠，默认展开）
                      if (_resultText.isNotEmpty)
                        ExpansionTile(
                          initiallyExpanded: true,
                          dense: true,
                          tilePadding: const EdgeInsets.symmetric(
                            horizontal: 8,
                          ),
                          title: const Text(
                            '审核结果',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          children: [
                            // v407：体检建议并入映射表（有建议行时显示）
                            if (_nameCheckIssues.isNotEmpty)
                              Align(
                                alignment: Alignment.centerRight,
                                child: TextButton(
                                  onPressed: () => _mergeCheckLines(
                                    context.read<AppState>(),
                                  ),
                                  child: const Text(
                                    '⤓ 并入映射表（同名跳过）',
                                    style: TextStyle(fontSize: 12),
                                  ),
                                ),
                              ),
                            Container(
                              width: double.infinity,
                              margin: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                              padding: const EdgeInsets.all(10),
                              constraints: const BoxConstraints(maxHeight: 300),
                              decoration: BoxDecoration(
                                color: Colors.amber.shade50,
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: SingleChildScrollView(
                                child: SelectableText(
                                  _resultText,
                                  style: const TextStyle(
                                    fontSize: 12,
                                    height: 1.5,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                    ],
                  ),
                ),
              // 修改意见 + 素材区（可折叠，默认展开当有内容时）
              ExpansionTile(
                initiallyExpanded: false,
                dense: true,
                tilePadding: const EdgeInsets.symmetric(horizontal: 8),
                title: Text(
                  '修改意见与素材${_reviewController.text.isNotEmpty ? "（${_reviewController.text.length}字）" : ""}',
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // 素材行（紧凑）
                        if (state.writingAttachments.isNotEmpty)
                          ConstrainedBox(
                            constraints: const BoxConstraints(maxHeight: 50),
                            child: ListView.builder(
                              scrollDirection: Axis.horizontal,
                              itemCount: state.writingAttachments.length,
                              itemBuilder: (ctx, i) {
                                final a = state.writingAttachments[i];
                                final isStyle = a['type'] == 'style';
                                return Container(
                                  margin: const EdgeInsets.only(right: 4),
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 6,
                                    vertical: 2,
                                  ),
                                  decoration: BoxDecoration(
                                    color: isStyle
                                        ? V469Style.accentBg
                                        : const Color(0xFFF0FDF4),
                                    borderRadius: BorderRadius.circular(3),
                                    border: Border.all(
                                      color: isStyle
                                          ? V469Style.accentLight
                                          : const Color(0xFFBBF7D0),
                                    ),
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Text(
                                        isStyle ? '文风' : '内容',
                                        style: TextStyle(
                                          fontSize: 10,
                                          color: isStyle
                                              ? V469Style.accent
                                              : const Color(0xFF16A34A),
                                        ),
                                      ),
                                      const SizedBox(width: 4),
                                      Text(
                                        '${a['name']}',
                                        style: const TextStyle(
                                          fontSize: 10,
                                          color: V469Style.textMain,
                                        ),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      const SizedBox(width: 4),
                                      GestureDetector(
                                        onTap: () {
                                          state.removeWritingAttachment(i);
                                          setState(() {});
                                        },
                                        child: const Text(
                                          '✕',
                                          style: TextStyle(
                                            fontSize: 10,
                                            color: Colors.red,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                );
                              },
                            ),
                          ),
                        // 素材按钮行
                        Row(
                          children: [
                            TextButton.icon(
                              icon: const Icon(Icons.attach_file, size: 14),
                              label: const Text(
                                '文风素材',
                                style: TextStyle(fontSize: 11),
                              ),
                              style: TextButton.styleFrom(
                                minimumSize: const Size(0, 28),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                ),
                              ),
                              onPressed: () => _pickAttachment('style'),
                            ),
                            TextButton.icon(
                              icon: const Icon(Icons.attach_file, size: 14),
                              label: const Text(
                                '内容素材',
                                style: TextStyle(fontSize: 11),
                              ),
                              style: TextButton.styleFrom(
                                minimumSize: const Size(0, 28),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                ),
                              ),
                              onPressed: () => _pickAttachment('content'),
                            ),
                          ],
                        ),
                        // v356：模仿作者开关（与创作页共享全局开关；范文=场景切片前1000字）
                        SwitchListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          visualDensity: VisualDensity.compact,
                          title: const Text(
                            '原范文（场景切片前1000字）',
                            style: TextStyle(fontSize: 12),
                          ),
                          value: state.writingImitateAuthor,
                          onChanged: (v) {
                            state.setWritingImitateAuthor(v);
                            setState(() {});
                          },
                        ),
                        // 修改意见输入框（maxLines加大+自动换行）
                        TextField(
                          controller: _reviewController,
                          // v356：意见跟随当前文件（per-file内存+防抖持久化）
                          onChanged: (v) {
                            final path = _currentFilePath;
                            if (path == null) return;
                            _reviewByFile[path] = v;
                            _persistReviews();
                          },
                          decoration: const InputDecoration(
                            labelText: '修改意见（找问题后自动填入，可编辑）',
                            hintText: '对一创正文的审核意见和修改方向...\n如：1. 开头太慢热，加快节奏\n2. 美女出场太突兀，加铺垫',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                          maxLines: 5,
                          minLines: 2,
                          style: const TextStyle(fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              // 终端日志已合并到全局底部悬浮胶囊（信息出口合一）
            ],
          ),
        ),
      ),
    );
  }
}

/// 审核页翻页模式视图（v469 dtDoPaginate/dtShowPage/dtTurnPage对齐）
/// LayoutBuilder+TextPainter按行分页；FAB↑↓翻页；页边界自动换文件（onPrev/onNext由父级处理）

class _DtScrollView extends StatefulWidget {
  final String title;
  final String content;
  final double fontSize;
  final double lineHeight;
  final int hlStart; // TTS当前句起始偏移（相对整章，-1无高亮）
  final int hlEnd; // TTS当前句结束偏移
  final ValueChanged<String>? onContentEdited; // v382：就地编辑回调（null=只读）
  final bool editDisabled; // v388：换名开启时禁就地编辑（防替换文本写回污染原文）

  const _DtScrollView({
    super.key,
    required this.title,
    required this.content,
    required this.fontSize,
    required this.lineHeight,
    this.hlStart = -1,
    this.hlEnd = -1,
    this.onContentEdited,
    this.editDisabled = false,
  });

  @override
  State<_DtScrollView> createState() => _DtScrollViewState();
}

class _DtScrollViewState extends State<_DtScrollView> {
  final ScrollController _scrollController = ScrollController();
  final GlobalKey _hlKey = GlobalKey();
  bool _editing = false; // v382：就地编辑态
  TextEditingController? _editController;

  @override
  void dispose() {
    _editController?.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  /// 进入编辑态（点击正文触发）
  void _startEdit() {
    if (widget.onContentEdited == null || _editing) return;
    if (widget.editDisabled) return; // v388：换名态禁止编辑
    setState(() {
      _editController?.dispose();
      _editController = TextEditingController(text: widget.content);
      _editing = true;
    });
  }

  /// 退出编辑态（点编辑区外触发）
  void _stopEdit() {
    if (!_editing) return;
    setState(() {
      _editing = false;
      _editController?.dispose();
      _editController = null;
    });
  }

  @override
  void didUpdateWidget(_DtScrollView oldWidget) {
    super.didUpdateWidget(oldWidget);
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
    );
    return SingleChildScrollView(
      controller: _scrollController,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            widget.title,
            style: TextStyle(
              fontSize: widget.fontSize + 4,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 16),
          // v382：点击正文进入就地编辑（滚动模式）；编辑中=TextField即改即存，点区外退出
          if (_editing && _editController != null)
            TextField(
              controller: _editController,
              maxLines: null,
              keyboardType: TextInputType.multiline,
              autofocus: true,
              style: style,
              decoration: const InputDecoration(
                border: InputBorder.none,
                isDense: true,
              ),
              onChanged: (t) => widget.onContentEdited?.call(t),
              onTapOutside: (_) => _stopEdit(),
            )
          else
            GestureDetector(
              onTap: _startEdit,
              child: Text.rich(_buildContentSpan(widget.content, style)),
            ),
          const SizedBox(height: 32),
          Center(
            child: Text(
              '${widget.content.length}字${_editing ? " · 编辑中，点区外退出" : ""}',
              style: TextStyle(fontSize: 12, color: Colors.grey[400]),
            ),
          ),
        ],
      ),
    );
  }
}

/// 翻页模式 — 用LayoutBuilder获取精确高度 + TextPainter按行分页
class _DtPagedView extends StatefulWidget {
  final String title;
  final String content;
  final double fontSize;
  final double lineHeight;
  final VoidCallback? onPrev;
  final VoidCallback? onNext;
  final void Function(List<String> pages, int currentPage)? onPagesComputed;
  final int hlStart; // TTS当前句起始偏移（相对整章，-1无高亮）
  final int hlEnd;

  const _DtPagedView({
    super.key,
    required this.title,
    required this.content,
    required this.fontSize,
    required this.lineHeight,
    this.onPrev,
    this.onNext,
    this.onPagesComputed,
    this.hlStart = -1,
    this.hlEnd = -1,
  });

  @override
  State<_DtPagedView> createState() => _DtPagedViewState();
}

class _DtPagedViewState extends State<_DtPagedView> {
  List<String> _pages = [];
  List<int> _pageStarts = []; // 每页在整章中的起始偏移
  int _currentPage = 0;
  bool _isLoading = true;
  Size? _lastSize;
  // v370b：行首缓存（主页chapter_reader三段式探测配套）
  final Map<int, int> _lineStartCache = {};

  void _computePages(Size viewSize) {
    final padding = 16.0;
    final bottomBarHeight = 20.0; // 底部页码小字（悬浮按钮不占正文空间）
    final availableHeight = viewSize.height - padding * 2 - bottomBarHeight;
    final availableWidth = viewSize.width - padding * 2;

    if (availableHeight <= 0 || availableWidth <= 0) return;

    final fullText = widget.content;
    final style = TextStyle(
      fontSize: widget.fontSize,
      height: widget.lineHeight,
      fontFamily: V469Style.uiFont, // v200：TextPainter直构不继承主题
    );

    // 标题高度（仅第一页）
    final titleStyle = TextStyle(
      fontSize: widget.fontSize + 4,
      fontWeight: FontWeight.bold,
      fontFamily: V469Style.uiFont, // v200
    );
    final titleTp = TextPainter(
      text: TextSpan(text: widget.title, style: titleStyle),
      textDirection: TextDirection.ltr,
    );
    titleTp.layout(maxWidth: availableWidth);
    final titleHeight = titleTp.height + 16; // 标题 + 间距
    titleTp.dispose();

    // 对整个文本layout
    final tp = TextPainter(
      text: TextSpan(text: fullText, style: style),
      textDirection: TextDirection.ltr,
      textAlign: TextAlign.start,
    );
    tp.layout(maxWidth: availableWidth);

    final lines = tp.computeLineMetrics();
    if (lines.isEmpty) {
      tp.dispose();
      setState(() {
        _pages = [fullText];
        _pageStarts = [0];
        _isLoading = false;
      });
      return;
    }

    // 按行分页：从页面第一行的top（baseline-ascent）算起，
    // 到当前行的bottom（baseline+descent）必须 <= 可用高度。
    // 之前漏算了第一行的ascent导致底部切字。
    List<String> pages = [];
    List<int> pageStarts = [];
    int lineStart = 0;
    // 第一页可用高度减去标题
    double pageAvailHeight = availableHeight - titleHeight;

    for (int i = 0; i < lines.length; i++) {
      final pageTop = lines[lineStart].baseline - lines[lineStart].ascent;
      final lineBottom = lines[i].baseline + lines[i].descent;
      if (lineBottom - pageTop > pageAvailHeight && i > lineStart) {
        // 切分：从lineStart到i（不含i）
        final startOffset = _getLineStart(tp, lineStart, fullText);
        final endOffset = _getLineStart(tp, i, fullText);
        pages.add(fullText.substring(startOffset, endOffset));
        pageStarts.add(startOffset);
        lineStart = i;
        // 后续页面不需要减标题
        pageAvailHeight = availableHeight;
      }
    }
    // 最后一页
    if (lineStart < lines.length) {
      final startOffset = _getLineStart(tp, lineStart, fullText);
      pages.add(fullText.substring(startOffset));
      pageStarts.add(startOffset);
    }

    tp.dispose();

    if (pages.isEmpty) {
      pages.add('');
      pageStarts.add(0);
    }
    _lineStartCache.clear(); // v370b：新分页新缓存
    setState(() {
      _pages = pages;
      _pageStarts = pageStarts;
      _currentPage = 0;
      _isLoading = false;
    });
    widget.onPagesComputed?.call(pages, 0);
  }

  /// 构建页面TextSpan，按偏移量高亮TTS当前句（与当前页求交集）
  TextSpan _buildPageSpan(int pageIdx, TextStyle style) {
    final content = _pages[pageIdx];
    final pageStart = _pageStarts[pageIdx];
    if (widget.hlStart < 0 || widget.hlEnd <= widget.hlStart) {
      return TextSpan(text: content, style: style);
    }
    // 计算高亮与当前页的交集
    final localStart = widget.hlStart - pageStart;
    final localEnd = widget.hlEnd - pageStart;
    if (localEnd <= 0 || localStart >= content.length) {
      return TextSpan(text: content, style: style);
    }
    final s = localStart.clamp(0, content.length);
    final e = localEnd.clamp(0, content.length);
    final before = content.substring(0, s);
    final mid = content.substring(s, e);
    final after = content.substring(e);
    return TextSpan(
      style: style,
      children: [
        if (before.isNotEmpty) TextSpan(text: before),
        TextSpan(
          text: mid,
          style: style.copyWith(backgroundColor: const Color(0xFFFFE082)),
        ),
        if (after.isNotEmpty) TextSpan(text: after),
      ],
    );
  }

  /// 获取第lineIdx行的起始字符偏移
  /// v370b：行内字符探测法（对齐主页chapter_reader v286三段式）——
  /// 旧二分搜索依赖单调性，换行符/emoji/生僻字处caret跳变→分页错位丢字
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
      // 静默降级到步进探测
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
        // 尺寸或字体变化时重新计算
        if (_lastSize != size || _isLoading) {
          _lastSize = size;
          _isLoading = true;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _computePages(size);
          });
        }
        if (_isLoading || _pages.isEmpty) {
          return const Center(child: CircularProgressIndicator());
        }
        // TTS朗读时自动翻到高亮句所在页（用addPostFrameCallback避免build中setState）
        if (widget.hlStart >= 0 && _pageStarts.isNotEmpty) {
          for (int i = 0; i < _pageStarts.length; i++) {
            final ps = _pageStarts[i];
            final pe = ps + _pages[i].length;
            if (widget.hlStart >= ps && widget.hlStart < pe) {
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
        return Stack(
          children: [
            // 正文
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (_currentPage == 0) ...[
                    Text(
                      widget.title,
                      style: TextStyle(
                        fontSize: widget.fontSize + 4,
                        fontWeight: FontWeight.bold,
                        fontFamily: V469Style.uiFont, // v200
                      ),
                    ),
                    const SizedBox(height: 16),
                  ],
                  Expanded(
                    child: Text.rich(
                      _buildPageSpan(
                        _currentPage,
                        TextStyle(
                          fontSize: widget.fontSize,
                          height: widget.lineHeight,
                          fontFamily: V469Style.uiFont, // v200
                        ),
                      ),
                      // v371b：钉死noScaling——测量端TextPainter不吃系统字体
                      // 缩放，显示端Text.rich默认会吃，系统大字号手机上漂移
                      textScaler: TextScaler.noScaling,
                    ),
                  ),
                  // 底部页码（小字居中）
                  Padding(
                    padding: const EdgeInsets.only(bottom: 2),
                    child: Center(
                      child: Text(
                        '${_currentPage + 1}/${_pages.length}',
                        style: TextStyle(fontSize: 11, color: Colors.grey[500]),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            // 半透明悬浮翻页按钮（左下/右下）
            Positioned(
              left: 8,
              bottom: 12,
              child: _floatingPageBtn(
                icon: Icons.chevron_left,
                onTap: _currentPage > 0
                    ? () {
                        setState(() => _currentPage--);
                        widget.onPagesComputed?.call(_pages, _currentPage);
                      }
                    : widget.onPrev,
              ),
            ),
            Positioned(
              right: 8,
              bottom: 12,
              child: _floatingPageBtn(
                icon: Icons.chevron_right,
                onTap: _currentPage < _pages.length - 1
                    ? () {
                        setState(() => _currentPage++);
                        widget.onPagesComputed?.call(_pages, _currentPage);
                      }
                    : widget.onNext,
              ),
            ),
          ],
        );
      },
    );
  }

  /// 半透明悬浮翻页按钮
  Widget _floatingPageBtn({required IconData icon, VoidCallback? onTap}) {
    return Material(
      color: Colors.black.withOpacity(0.18),
      borderRadius: BorderRadius.circular(24),
      child: InkWell(
        borderRadius: BorderRadius.circular(24),
        onTap: onTap,
        child: SizedBox(
          width: 48,
          height: 48,
          child: Icon(icon, color: Colors.white70, size: 28),
        ),
      ),
    );
  }
}
