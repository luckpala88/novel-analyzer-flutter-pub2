import 'dart:convert';
import 'dart:io';
import 'package:share_plus/share_plus.dart';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';
import '../models/world_book.dart';
import '../utils/text_cleaner.dart';
import '../utils/name_map.dart';
import '../utils/v469_style.dart';
import '../widgets/api_config_panel.dart';
import '../widgets/v119_ui.dart';
import '../widgets/content_font.dart';

/// 世界书页 — 照抄v468 worldbook-card
/// 浏览侧：条目预览（可编辑/删除）+ 导出（JSON/MD/SillyTavern）
class WorldBookPage extends StatefulWidget {
  const WorldBookPage({super.key});

  @override
  State<WorldBookPage> createState() => _WorldBookPageState();
}

class _WorldBookPageState extends State<WorldBookPage>
    with AutomaticKeepAliveClientMixin {
  // 折叠置顶：tile的GlobalKey注册表（展开时头部自动滚到可视区顶，便于随时折叠）
  final Map<String, GlobalKey> _tileKeys = {};
  GlobalKey _tileKey(String id) => _tileKeys.putIfAbsent(id, () => GlobalKey());
  void _scrollTileToTop(String id) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _tileKeys[id]?.currentContext;
      if (ctx != null) {
        Scrollable.ensureVisible(
          ctx,
          alignment: 0.0,
          duration: const Duration(milliseconds: 250),
        );
      }
    });
  }

  // 按场景/弧线折叠分组（纯显示层，不影响ST导出——导出走entries原数据）
  // 持久化到ui_state（重启恢复浏览状态）
  Set<String> _collapsedGroups = {};
  // 条目内容按场景折叠分镜明细（默认折叠，点击展开；纯显示层，ST导出走content原文零影响）
  Set<String> _expandedScenes = {};
  bool _restoredUi = false;

  @override
  // v288：生成内容字号（本页独立，0.8~1.6）
  double _fontScale = 1.0;

  void initState() {
    super.initState();
    ContentFont.load('wb').then((v) {
      if (mounted) setState(() => _fontScale = v);
    });
    _restoreUiState();
  }

  void _restoreUiState() {
    try {
      final saved = AppState.instance.uiGet('worldbook', 'uiFold');
      if (saved is Map) {
        final cg = saved['collapsedGroups'];
        if (cg is List) {
          _collapsedGroups = cg.map((e) => e.toString()).toSet();
        }
        final es = saved['expandedScenes'];
        if (es is List) {
          _expandedScenes = es.map((e) => e.toString()).toSet();
        }
      }
      _restoredUi = true;
    } catch (_) {
      _restoredUi = true;
    }
  }

  void _saveUiState() {
    if (!_restoredUi) return;
    AppState.instance.uiSet('worldbook', 'uiFold', {
      'collapsedGroups': _collapsedGroups.toList(),
      'expandedScenes': _expandedScenes.toList(),
    });
  }

  // 就地编辑状态（替代弹窗）：_editingUid为null=浏览态，非null=该条目进入编辑
  String? _editingUid;
  bool _mapPreview = false; // v702：浏览层换名预览（纯显示层套映射表，数据/ST导出仍原文）
  final _editContentCtrl = TextEditingController();
  final _editCommentCtrl = TextEditingController();
  final _editKeyCtrl = TextEditingController();

  @override
  bool get wantKeepAlive => true; // 页面滑出PageView时保持State：生成任务不中断/表单不清空

  @override
  void dispose() {
    _editContentCtrl.dispose();
    _editCommentCtrl.dispose();
    _editKeyCtrl.dispose();
    super.dispose();
  }

  /// 进入就地编辑模式（替代弹窗_editEntry）
  void _startEdit(WBEntry entry) {
    _editContentCtrl.text = entry.content;
    _editCommentCtrl.text = entry.comment;
    _editKeyCtrl.text = entry.key;
    setState(() => _editingUid = entry.uid);
  }

  /// 保存编辑
  void _saveEdit(AppState state, WBEntry entry) {
    entry.content = TextCleaner.stripDecorativeEmoji(_editContentCtrl.text);
    entry.comment = _editCommentCtrl.text.trim();
    entry.key = _editKeyCtrl.text.trim();
    state.saveWorldBook();
    state.refresh();
    setState(() => _editingUid = null);
  }

  /// 取消编辑
  void _cancelEdit() {
    setState(() => _editingUid = null);
  }

  /// v630b：添加自定义条目（从改编页撤回世界书页——本页本来就是条目管理入口）
  void _addCustomEntry(AppState state) {
    final uid = 'custom_${DateTime.now().millisecondsSinceEpoch}';
    state.worldBook!.entries[uid] = WBEntry(
      uid: uid,
      key: '自定义条目',
      comment: '自定义条目',
      content: '',
      constant: false,
      selective: false,
      disable: false,
      order: 9,
    );
    state.saveWorldBook();
    state.refresh();
    // 建完直接进就地编辑，省一次点击
    final entry = state.worldBook!.entries[uid]!;
    _startEdit(entry);
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    super.build(context); // AutomaticKeepAlive必须
    final state = context.watch<AppState>();
    final entries = state.worldBook?.entries.values.toList() ?? [];

    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            // 顶行：清空+导出+⚙
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 2),
              child: Wrap(
                spacing: 4,
                runSpacing: 2,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  MiniButton(
                    label: '换名预览',
                    primary: _mapPreview,
                    onTap: () => setState(() => _mapPreview = !_mapPreview),
                  ),
                  MiniButton(
                    label: '清空',
                    danger: true,
                    onTap: () {
                      showDialog(
                        context: context,
                        builder: (ctx) => AlertDialog(
                          title: const Text('清空世界书'),
                          content: const Text('确定删除所有条目？'),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(ctx),
                              child: const Text('取消'),
                            ),
                            TextButton(
                              style: TextButton.styleFrom(
                                foregroundColor: Colors.red,
                              ),
                              onPressed: () {
                                state.worldBook?.entries.clear();
                                state.worldBook?.arcStatus.clear();
                                // v628b：圣经字段同步清空——否则adaptBible残留会让下次生成误走回流分支，原著圣经永不触发
                                state.worldBook?.adaptBible = '';
                                state.worldBook?.originalBible = '';
                                state.saveWorldBook();
                                state.refresh();
                                Navigator.pop(ctx);
                              },
                              child: const Text('清空'),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                  const SizedBox(width: 5),
                  MiniButton(
                    label: '添加条目',
                    onTap: () => _addCustomEntry(state),
                  ),
                  const SizedBox(width: 5),
                  MiniButton(
                    label: '导出',
                    onTap: () => _exportSillyTavern(state),
                  ),
                                    // v288：生成内容字号（本页独立）
                  ContentFontButtons(
                    pageKey: 'wb',
                    scale: _fontScale,
                    onChanged: (v) {
                      setState(() => _fontScale = v);
                      ContentFont.save('wb', v);
                    },
                  ),
                  const SizedBox(width: 5),
const SizedBox(width: 8), // Wrap内Spacer失效，用定宽占位
                ],
              ),
            ),
            // 条目列表
            Expanded(
              child: ContentFont.area(context, scale: _fontScale, child: entries.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.menu_book,
                            size: 64,
                            color: Colors.grey[400],
                          ),
                          const SizedBox(height: 16),
                          const Text(
                            '暂无世界书条目',
                            style: TextStyle(color: Colors.grey),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            '请到「改编」页生成世界书条目。',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: Colors.grey[500],
                              fontSize: 13,
                              height: 1.6,
                            ),
                          ),
                        ],
                      ),
                    )
                  : Builder(
                      builder: (ctx) {
                        // 只分组一次，builder复用（每行重复分组是O(n²)）
                        final items = _groupedItems(state, entries);
                        return ListView.builder(
                          // 底部留白=底部导航(80)+终端胶囊(40)+安全区——
                          // v225：120→200（用户反馈仍被遮挡）
                          // v239：160→240（用户反馈展开长条目后底部内容
                          // 仍被底部导航+终端胶囊叠加遮挡，宁多勿遮）
                          padding: EdgeInsets.only(
                            bottom:
                                240 + MediaQuery.of(context).padding.bottom,
                          ),
                          itemCount: items.length,
                          itemBuilder: (c, i) => items[i],
                        );
                      },
                    ),
            )),
          ],
        ),
      ),
    );
  }

  /// v468对齐：按 场景组→弧线组→全局 分组渲染
  List<Widget> _groupedItems(AppState state, List<WBEntry> entries) {
    final widgets = <Widget>[];

    // 分桶：sceneTag有值=场景组；否则arcKey有值=弧线组；都没有=全局
    final sceneGroups = <String, List<WBEntry>>{};
    final arcGroups = <String, List<WBEntry>>{};
    final globals = <WBEntry>[];
    for (final e in entries) {
      final st = e.sceneTag ?? '';
      final ak = e.arcKey ?? '';
      if (st.isNotEmpty) {
        sceneGroups.putIfAbsent(st, () => []).add(e);
      } else if (ak.isNotEmpty) {
        arcGroups.putIfAbsent(ak, () => []).add(e);
      } else {
        globals.add(e);
      }
    }

    // 场景组排序：arcKey数字→sceneIdx数字（sceneTag格式"arcKey_sceneIdx"）
    int arcOf(String tag) => int.tryParse(tag.split('_').first) ?? 0;
    int idxOf(String tag) =>
        tag.split('_').length > 1 ? int.tryParse(tag.split('_').last) ?? 0 : 0;
    final sortedScenes = sceneGroups.keys.toList()
      ..sort(
        (a, b) => arcOf(a) != arcOf(b)
            ? arcOf(a).compareTo(arcOf(b))
            : idxOf(a).compareTo(idxOf(b)),
      );
    final sortedArcs = arcGroups.keys.toList()
      ..sort((a, b) => (int.tryParse(a) ?? 0).compareTo(int.tryParse(b) ?? 0));

    // 场景组（🎬）
    for (final tag in sortedScenes) {
      final list = sceneGroups[tag]!;
      final arcKey = tag.split('_').first;
      final sceneIdx = idxOf(tag);
      // 从场景名映射取场景名+章节范围（arcScenes里有真名）
      var sceneName = '场景${sceneIdx + 1}';
      var chapterRange = '';
      final scenes = state.arcScenes[arcKey] ?? [];
      if (sceneIdx < scenes.length) {
        sceneName = scenes[sceneIdx].name;
        chapterRange = scenes[sceneIdx].chapterRange;
      }
      widgets.add(
        _groupHeader(
          '🎬 弧线$arcKey · $sceneName',
          chapterRange,
          Colors.green.shade700,
          tag,
          list.length,
        ),
      );
      if (!_collapsedGroups.contains(tag)) {
        for (final e in list) {
          widgets.add(_buildEntryCard(state, e));
        }
      }
    }

    // 弧线组（📖）
    for (final ak in sortedArcs) {
      final list = arcGroups[ak]!;
      // 弧线章节范围
      var chapterRange = '';
      final arc = state.completedArcs
          .where((a) => a.number.toString() == ak)
          .firstOrNull;
      if (arc != null) chapterRange = arc.chapterRange;
      widgets.add(
        _groupHeader(
          '📖 弧线$ak',
          chapterRange,
          Colors.blue.shade700,
          'arc_$ak',
          list.length,
        ),
      );
      if (!_collapsedGroups.contains('arc_$ak')) {
        for (final e in list) {
          widgets.add(_buildEntryCard(state, e));
        }
      }
    }

    // 全局（🌐）
    if (globals.isNotEmpty) {
      widgets.add(
        _groupHeader(
          '🌐 全局条目',
          '',
          Colors.grey.shade700,
          '__global',
          globals.length,
        ),
      );
      if (!_collapsedGroups.contains('__global')) {
        for (final e in globals) {
          widgets.add(_buildEntryCard(state, e));
        }
      }
    }

    return widgets;
  }

  /// 条目内容按场景折叠渲染：
  /// 解析content文本按"场景N："行切块，每块=场景头（常显可点击）+分镜明细（可折叠）
  /// 纯显示层——ST导出用entry.content原文，此处仅渲染拆分
  Widget _sceneFoldableContent(WBEntry entry) {
    // v702：换名预览开启时显示层套映射表（数据/ST导出仍entry.content原文）
    final displayText = _mapPreview
        ? NameMap.applyMapping(
            entry.content,
            context.read<AppState>().worldBook?.nameMapping ?? '',
          )
        : TextCleaner.decodeLiteralNewlines(
            TextCleaner.repairJsonDimLines(entry.content),
          ); // v703：JSON壳维度行修复 + v725：字面\n解码（存量圣经显示兜底）
    final lines = displayText.split('\n');
    // 切块：头块 / 场景块s / 尾块
    final head = <String>[];
    final scenes = <Map<String, dynamic>>[]; // {header, overview, lines:[]}
    final tail = <String>[];
    final sceneRe = RegExp(r'^[^\u4e00-\u9fa5\n]*场[景面]?\s*(\d+)\s*[：:】\]]');
    final overviewRe = RegExp(r'^[^\u4e00-\u9fa5\n]*概[述说][：:]');
    for (final raw in lines) {
      final t = raw.trim();
      if (sceneRe.hasMatch(t)) {
        scenes.add({'header': t, 'overview': '', 'lines': <String>[]});
      } else if (scenes.isEmpty) {
        // 场景前的概述/改编说明进head（条目头部常显）
        head.add(raw);
      } else if (scenes.isNotEmpty) {
        // 概述行单独提取常显（不折进分镜明细）
        if (overviewRe.hasMatch(t) && scenes.last['inTail'] != true) {
          scenes.last['overview'] = t.replaceFirst(overviewRe, '').trim();
        } else if (_isTailSection(t)) {
          tail.add(raw);
          scenes.last['inTail'] = true;
        } else if (scenes.last['inTail'] == true) {
          tail.add(raw);
        } else {
          scenes.last['lines'].add(raw);
        }
      }
    }
    final entryId = identityHashCode(entry).toString();
    final widgets = <Widget>[];
    // 头部（弧线概述等）
    if (head.any((l) => l.trim().isNotEmpty)) {
      widgets.add(
        SelectableText.rich(
          TextSpan(
            children: V469Style.contentSpans(head.join('\n'), fontSize: 11),
          ),
        ),
      );
    }
    // 场景块
    for (var si = 0; si < scenes.length; si++) {
      final sc = scenes[si];
      final sKey = '$entryId\|$si';
      final collapsed = !_expandedScenes.contains(sKey);
      // v509b：分镜N后分隔符可选（逐镜组装的"分镜1"独立行无冒号=此前恒0）
      final shotCount = (sc['lines'] as List<String>)
          .where(
            (l) =>
                RegExp(r'^[^\u4e00-\u9fa5\n]*分[镜景](头)?\s*\d+\s*[：:】\]]?')
                    .hasMatch(l.trim()),
          )
          .length;
      // 场景头（红字+折叠箭头+分镜数徽章，点击切换）
      widgets.add(
        GestureDetector(
          onTap: () => setState(() {
            collapsed
                ? _expandedScenes.add(sKey)
                : _expandedScenes.remove(sKey);
            _saveUiState();
          }),
          child: Container(
            margin: const EdgeInsets.only(top: 4),
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
            decoration: BoxDecoration(
              color: V469Style.incompleteBg.withOpacity(0.4),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Row(
              children: [
                Text(
                  collapsed ? '▶' : '▾',
                  style: const TextStyle(
                    fontSize: 10,
                    color: V469Style.incomplete,
                  ),
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    (sc['header'] as String)
                        .replaceFirst('【', '')
                        .replaceFirst(RegExp(r'】$'), ''),
                    style: const TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF991B1B),
                    ),
                  ),
                ),
                Text(
                  '$shotCount分镜',
                  style: const TextStyle(
                    fontSize: 10,
                    color: V469Style.textMuted,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      // 场景概述（常显，不折叠——对齐分析页：场景头下紧跟概述）
      final overview = (sc['overview'] as String?) ?? '';
      if (overview.isNotEmpty) {
        widgets.add(
          Padding(
            padding: const EdgeInsets.only(left: 8, top: 2),
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: '📝 概述/Summary：',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: const Color(0xFF475569),
                      backgroundColor: const Color(0xFFDBEAFE).withOpacity(0.5),
                    ),
                  ),
                  TextSpan(
                    text: overview.replaceFirst(RegExp(r'^概[述说][：:]\s*'), ''),
                    style: const TextStyle(
                      fontSize: 11,
                      height: 1.4,
                      color: V469Style.textMain,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      }
      // 分镜明细（展开时）
      if (!collapsed && (sc['lines'] as List<String>).isNotEmpty) {
        widgets.add(
          Padding(
            padding: const EdgeInsets.only(left: 8, top: 2),
            child: SelectableText.rich(
              TextSpan(
                children: V469Style.contentSpans(
                  (sc['lines'] as List<String>).join('\n'),
                  fontSize: 11,
                ),
              ),
            ),
          ),
        );
      }
    }
    // 尾部（弧线总结：世界观设定/人设/矛盾冲突/伏笔等，标记行加粗着色对齐分析页样式）
    if (tail.any((l) => l.trim().isNotEmpty)) {
      final tailWidgets = <Widget>[];
      // 按标记行分段渲染
      final titleRe = RegExp(
        r'^[^\u4e00-\u9fa5\n]*(弧线概述|概述|世界观设定|改编事项|人[物设]|角色|矛盾冲突|冲突|伏笔|弧线功能|不可逆|情绪曲线|作者脑洞|脑洞)[：:】\]]',
      );
      final iconMap = {
        '弧线概述': '📋',
        '世界观设定': '🌐',
        '改编事项': '✏️',
        '人设': '👤',
        '人物': '👤',
        '角色': '👤',
        '矛盾冲突': '⚔️',
        '冲突': '⚔️',
        '伏笔': '🌱',
        '弧线功能': '🧩',
        '不可逆': '💎',
        '情绪曲线': '📈',
        '作者脑洞': '💡',
        '脑洞': '💡',
      };
      String? currentTitle;
      final buf = <String>[];
      void flush() {
        if (buf.isEmpty) return;
        if (currentTitle != null) {
          final icon =
              iconMap.entries
                  .where((e) => currentTitle!.contains(e.key))
                  .map((e) => e.value)
                  .firstOrNull ??
              '📌';
          tailWidgets.add(
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                '$icon $currentTitle',
                style: const TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w700,
                  color: V469Style.textMain,
                ),
              ),
            ),
          );
        }
        tailWidgets.add(
          Padding(
            padding: const EdgeInsets.only(left: 4, top: 2),
            child: SelectableText.rich(
              TextSpan(
                children: V469Style.contentSpans(buf.join('\n'), fontSize: 11),
              ),
            ),
          ),
        );
        buf.clear();
      }

      for (final l in tail) {
        final m = titleRe.firstMatch(l.trim());
        if (m != null) {
          flush();
          currentTitle = m.group(1);
          // v253：标记行只当标题不进buf——此前标记行既生成标题又留在
          // 内容buf里原样渲染=每个标记双显（标题🧩弧线功能+原文📖弧线
          // 功能两行）。行内式"名称：内容"只把内容部分进buf
          final rest = l.trim().substring(m.end).trim();
          if (rest.isNotEmpty) buf.add(rest);
        } else {
          buf.add(l);
        }
      }
      flush();
      widgets.add(
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: tailWidgets,
          ),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: widgets,
    );
  }

  /// 尾部段落标记（场景块结束后的弧线总结：世界观/人设/冲突/伏笔等）
  bool _isTailSection(String t) {
    return RegExp(
      r'^[^\u4e00-\u9fa5\n]*(弧线概述|概述|世界观设定|改编事项|人[物设]|角色|矛盾冲突|冲突|伏笔|弧线功能|不可逆|情绪曲线|作者脑洞|脑洞)[：:】\]]',
    ).hasMatch(t);
  }

  /// 分组头（可点击折叠/展开组内条目，▶/▾指示+条目数）
  Widget _groupHeader(
    String title,
    String chapterRange,
    Color color,
    String groupKey,
    int count,
  ) {
    final collapsed = _collapsedGroups.contains(groupKey);
    return Container(
      margin: const EdgeInsets.fromLTRB(8, 10, 8, 2),
      decoration: BoxDecoration(
        color: color.withOpacity(0.06),
        borderRadius: BorderRadius.circular(5),
        border: Border(bottom: BorderSide(color: color.withOpacity(0.3))),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(5),
        onTap: () => setState(() {
          collapsed
              ? _collapsedGroups.remove(groupKey)
              : _collapsedGroups.add(groupKey);
          _saveUiState();
        }),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Row(
            children: [
              Text(
                collapsed ? '▶' : '▾',
                style: TextStyle(fontSize: 10, color: color),
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: color,
                  ),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(
                  color: color.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  '$count条',
                  style: TextStyle(fontSize: 10, color: color),
                ),
              ),
              if (chapterRange.isNotEmpty) ...[
                const SizedBox(width: 6),
                Text(
                  '📍 $chapterRange',
                  style: const TextStyle(fontSize: 10, color: Colors.grey),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// 条目卡片（可展开查看/就地编辑/删除）
  Widget _buildEntryCard(AppState state, WBEntry entry) {
    final isEditing = _editingUid == entry.uid;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      child: ExpansionTile(
        key: _tileKey('wb_entry_${entry.uid}'),
        onExpansionChanged: (v) {
          if (v) _scrollTileToTop('wb_entry_${entry.uid}');
        },
        dense: true,
        tilePadding: const EdgeInsets.symmetric(horizontal: 12),
        // v469语义图标：🎬场景条目/📖弧线条目/⭐常驻/🔖普通
        leading: Text(
          entry.beatTag != null && entry.beatTag!.isNotEmpty
              ? '🎬'
              : (entry.arcKey ?? '').isNotEmpty
              ? '📖'
              : (entry.constant ? '⭐' : '🔖'),
          style: const TextStyle(fontSize: 16),
        ),
        title: isEditing
            ? TextField(
                controller: _editCommentCtrl,
                decoration: const InputDecoration(
                  labelText: '名称',
                  isDense: true,
                ),
                style: const TextStyle(fontSize: 13),
              )
            : Text(entry.comment, style: const TextStyle(fontSize: 13)),
        subtitle: isEditing
            ? TextField(
                controller: _editKeyCtrl,
                decoration: const InputDecoration(
                  labelText: '触发词（逗号分隔）',
                  isDense: true,
                ),
                style: const TextStyle(fontSize: 10),
              )
            : Text(
                'order:${entry.order}'
                '${entry.arcKey != null && entry.arcKey!.isNotEmpty ? " · 弧线${entry.arcKey}" : ""}'
                '${entry.sceneTag != null ? " · ${entry.sceneTag}" : ""}',
                style: const TextStyle(fontSize: 10),
              ),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (!isEditing && entry.key.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text(
                      '触发词: ${entry.key}',
                      style: const TextStyle(fontSize: 10, color: Colors.grey),
                    ),
                  ),
                // 内容区：编辑态=TextField可写；浏览态=整体展开随外层滚动
                // v249：去maxHeight嵌套滚动（0.7屏+内层SingleChildScrollView
                // 嵌套滚动——内层滚到底手势不接力外层，条目尾部内容永远
                // 够不着=用户"上划程度不够下面看不到"的根因；整体展开后
                // 长条目随外层ListView自然滚动）
                Container(
                  width: double.infinity,
                  constraints: const BoxConstraints(maxWidth: 620),
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: V469Style.shotBg,
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: V469Style.shotBorder),
                  ),
                  child: isEditing
                      ? TextField(
                          controller: _editContentCtrl,
                          maxLines: null,
                          minLines: 8,
                          style: const TextStyle(fontSize: 11, height: 1.5),
                          decoration: const InputDecoration.collapsed(
                            hintText: '',
                          ),
                        )
                      : _sceneFoldableContent(entry),
                ),
                // 操作按钮行
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    if (isEditing) ...[
                      TextButton.icon(
                        icon: const Icon(Icons.close, size: 14),
                        label: const Text('取消', style: TextStyle(fontSize: 12)),
                        onPressed: _cancelEdit,
                      ),
                      FilledButton.icon(
                        icon: const Icon(Icons.check, size: 14),
                        label: const Text('保存', style: TextStyle(fontSize: 12)),
                        onPressed: () => _saveEdit(state, entry),
                      ),
                    ] else ...[
                      TextButton.icon(
                        icon: const Icon(Icons.edit, size: 14),
                        label: const Text('编辑', style: TextStyle(fontSize: 12)),
                        onPressed: () => _startEdit(entry),
                      ),
                      TextButton.icon(
                        icon: const Icon(
                          Icons.delete,
                          size: 14,
                          color: Colors.red,
                        ),
                        label: const Text(
                          '删除',
                          style: TextStyle(fontSize: 12, color: Colors.red),
                        ),
                        onPressed: () {
                          state.worldBook!.entries.remove(entry.uid);
                          // v628b：删圣经条目时同步清字段（条目与字段是两份存储，只删条目会让初始化判断失效）
                          if (entry.uid == 'story_bible') state.worldBook!.adaptBible = '';
                          if (entry.uid == 'original_bible') state.worldBook!.originalBible = '';
                          state.saveWorldBook();
                          state.refresh();
                        },
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ===== 导出 =====
  /// SillyTavern格式导出（v469 exportWorldBookJSON对齐：
  /// 完整字段集vectorized/addMemo/preventRecursion/delayUntilRecursion/canToggle/canToggleOff/characterUUID/extensions、
  /// selective=constant?false:true、keysecondary数组或null、uid数字重排、文件名worldbook_书名_日期.json）
  void _exportSillyTavern(AppState state) {
    final wb = state.worldBook;
    if (wb == null || wb.entries.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('暂无条目，请先生成')));
      return;
    }
    final entries = <String, dynamic>{};
    var uid = 0;
    for (final e in wb.entries.values) {
      final keys = e.key
          .split(',')
          .map((k) => k.trim())
          .where((k) => k.isNotEmpty)
          .toList();
      final ksec = (e.keySecondary == null || e.keySecondary!.trim().isEmpty)
          ? null
          : e.keySecondary!
                .split(',')
                .map((k) => k.trim())
                .where((k) => k.isNotEmpty)
                .toList();
      entries[uid.toString()] = {
        'uid': uid,
        'key': keys,
        'keysecondary': ksec,
        'comment': e.comment,
        // 导出兜底清洗：剥AI自加装饰emoji（入库已清洗，旧数据兜底）
        'content': TextCleaner.stripDecorativeEmoji(e.content),
        'constant': e.constant,
        'vectorized': false,
        'selective': e.constant ? false : true,
        'selectiveLogic': 0,
        'addMemo': null,
        'order': e.order,
        'position': e.position,
        'disable': e.disable,
        'excludeRecursion': false,
        'preventRecursion': false,
        'delayUntilRecursion': false,
        'probability': 100,
        'useProbability': true,
        'canToggle': true,
        'canToggleOff': true,
        'characterUUID': null,
        'extensions': <String, dynamic>{},
      };
      uid++;
    }
    final data = {
      'entries': entries,
      'originalData': null,
      'name': '${state.currentBook}_世界书',
    };
    final now = DateTime.now();
    final date =
        '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    final filename = 'worldbook_${state.currentBook}_$date.json';
    final path = state.storage.getExportPath(filename);
    state.storage.writeFile(
      path,
      const JsonEncoder.withIndent('  ').convert(data),
    );
    // v385：专属目录模式下Android/data文件管理器进不去——加分享出口+全路径提示
    final file = File('${state.storage.baseDirPath}/$path');
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 6),
        content: Text(
          '已导出 $uid 条条目\n$path\nSillyTavern：World Info → Import 导入',
        ),
        action: SnackBarAction(
          label: '分享',
          onPressed: () {
            try {
              Share.shareXFiles(
                [XFile(file.path)],
                subject: filename,
                text: 'SillyTavern世界书（World Info → Import 导入）',
              );
            } catch (e) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('分享失败：$e')),
              );
            }
          },
        ),
      ),
    );
  }
}
