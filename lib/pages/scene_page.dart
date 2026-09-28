import 'dart:convert';

import 'dart:async';
import '../widgets/v_scroll_bar.dart';
import 'package:flutter/material.dart';

import '../widgets/slice_viewer_sheet.dart';
import 'package:provider/provider.dart';

import '../services/scene_stream.dart';
import '../widgets/scene_card_item.dart';
import '../state/app_state.dart';
import '../models/arc.dart';
import '../models/scene.dart';
import '../utils/prompt_builder.dart';
import '../models/world_book.dart';
import '../utils/text_cleaner.dart';
import '../utils/chinese_number.dart';
import '../utils/anchor_repair.dart';
import '../utils/arc_text.dart';
import '../utils/json_repair.dart';
import '../widgets/api_config_panel.dart';
import '../utils/v469_style.dart';
import '../utils/prompt_preview.dart';
import '../widgets/api_log_panel.dart';
import '../widgets/v119_ui.dart';
import '../widgets/content_font.dart';

class ScenePage extends StatefulWidget {
  const ScenePage({super.key});

  @override
  State<ScenePage> createState() => _ScenePageState();
}

class _ScenePageState extends State<ScenePage>
    with AutomaticKeepAliveClientMixin {
  final ScrollController _listCtl = ScrollController(); // v656：列表垂直滚动条
  @override
  bool get wantKeepAlive => true; // 页面滑出PageView时保持State：生成任务不中断/表单不清空

  bool _isDividing = false;
  final _sceneStepController = TextEditingController(); // v441：场景扫描步进
  void _saveSceneStep(AppState state, {bool persist = false}) {
    final v = int.tryParse(_sceneStepController.text) ?? 0;
    if (v <= 0) return;
    state.sceneStepSize = v;
    // v451：onChanged实时更新内存（原只在onSubmitted保存——改完数字直接点
    // 批量菜单不触发提交=值丢失，扫描仍用旧默认）
    if (persist) {
      state.saveGlobalScenes();
      _addLog('场景扫描步进已设为 $v 章/批');
    }
  }
  // v288：生成内容字号（本页独立，0.8~1.6）
  double _fontScale = 1.0;

  @override
  void initState() {
    super.initState();
    ContentFont.load('scene').then((v) {
      if (mounted) setState(() => _fontScale = v);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final st = context.read<AppState>();
      _sceneStepController.text = st.sceneStepSize.toString();
    });
  }

  String _statusText = '';
  // 折叠置顶：tile的GlobalKey注册表（展开时头部自动滚到可视区顶，便于随时折叠）
  final Map<String, GlobalKey> _tileKeys = {};
  GlobalKey _tileKey(String id) => _tileKeys.putIfAbsent(id, () => GlobalKey());
  @override
  void dispose() {
    _listCtl.dispose();
    super.dispose();
  }

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

  final List<String> _logs = [];
  // 展开的场景分镜详情 key: "arcNum_sceneIdx"

  bool _bibleRunning = false; // v782：圣经迭代进行中

  /// v782：故事圣经入口弹窗（增量迭代/重新构建）
  void _showBibleDialog(AppState state) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('📖 故事圣经'),
        content: const Text(
            '按弧线顺序逐个读取弧线总结，迭代世界书「故事圣经」条目（创作页全程注入的权威源）。\n\n'
            '📖增量迭代：保留现有圣经，逐弧线滚入新事实。\n'
            '🔄重新构建：清空圣经后从第一条弧线重建。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              _iterateBible(state, rebuild: true);
            },
            child: const Text('🔄重新构建'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              _iterateBible(state, rebuild: false);
            },
            child: const Text('📖增量迭代'),
          ),
        ],
      ),
    );
  }

  /// v782：逐弧线迭代故事圣经（增量或重建），写入世界书story_bible条目
  Future<void> _iterateBible(AppState state, {required bool rebuild}) async {
    if (_bibleRunning) return;
    final wb = state.worldBook;
    if (wb == null) {
      _addLog('❌ 世界书未初始化');
      return;
    }
    final arcs = state.completedArcs
        .where((a) => state.arcAnalyses[a.number.toString()] != null)
        .toList()
      ..sort((a, b) => a.number.compareTo(b.number));
    if (arcs.isEmpty) {
      _addLog('❌ 没有弧线拆解数据——先完成弧线扫描');
      return;
    }
    final config = state.getApiConfig('wb');
    state.api.clearAbort();
    state.userAborted = false;
    setState(() => _bibleRunning = true);
    try {
      if (rebuild) {
        wb.adaptBible = '';
        _addLog('📖 重新构建故事圣经（${arcs.length}条弧线，逐弧线迭代）…');
      } else {
        _addLog(
            '📖 增量迭代故事圣经（弧线${arcs.first.number}→${arcs.last.number}）…');
      }
      for (final a in arcs) {
        if (state.api.isAborted) {
          _addLog('⏸ 用户中止');
          break;
        }
        final an = state.arcAnalyses[a.number.toString()]!;
        final src = StringBuffer()
          ..writeln('弧线${a.number}：${a.title}')
          ..writeln(
              '概述：${(an.metadata?['arc_summary_detailed']?.toString() ?? an.arcSummary).trim()}');
        for (var si = 0; si < an.scenes.length; si++) {
          final sc = an.scenes[si];
          src.writeln('场景${si + 1}：${sc.name}｜${sc.summary.trim()}');
        }
        final bible = wb.adaptBible.trim();
        final r = await state.api.callApi(
          task: '世界书迭代',  // v824任务级反馈
          systemPrompt: PromptBuilder.buildBibleUpdateSystemPrompt(),
          userPrompt:
              '【现有圣经（为空=从本弧线起构建）】\n${bible.isEmpty ? '（无——从本弧线开始构建）' : bible}\n\n【弧线${a.number}总结（新事实来源）】\n$src',
          apiConfig: config,
        );
        if (!r.isSuccess) {
          _addLog('❌ 弧线${a.number}圣经迭代失败：${r.error}');
          break;
        }
        final out = TextCleaner.stripQuotedFragment(
            TextCleaner.normalizeAiOutput(r.content));
        if (out.isEmpty) {
          _addLog('⚠️ 弧线${a.number}输出为空，跳过');
          continue;
        }
        wb.adaptBible = out;
        const bibleUid = 'story_bible';
        final old = wb.entries[bibleUid];
        wb.entries[bibleUid] = WBEntry(
          uid: bibleUid,
          key: old?.key ?? '故事圣经',
          comment: '全书故事圣经',
          content: out,
          constant: true,
          selective: false,
          disable: false,
          order: 1,
        );
        state.saveWorldBook();
        _addLog('✓ 圣经已迭代到弧线${a.number}（${out.length}字）');
      }
      _addLog('📖 圣经迭代结束——世界书「故事圣经」条目已更新');
    } finally {
      if (mounted) setState(() => _bibleRunning = false);
    }
  }

  void _addLog(String msg) {
    setState(() {
      _logs.add(msg);
      if (_logs.length > 100) _logs.removeAt(0);
    });
    AppState.instance.apiLog(msg); // 页面日志同步全局终端（信息出口合一）
  }

  @override
  Widget build(BuildContext context) {
    super.build(context); // AutomaticKeepAlive必须
    final state = context.watch<AppState>();
    final arcs = state.completedArcs;

    // 统计
    int dividedCount = 0;
    for (final arc in arcs) {
      final scenes = state.arcScenes[arc.number.toString()] ?? [];
      if (scenes.isNotEmpty) dividedCount++;
    }

    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            // v210：单行工具栏（批量+四芯片+⚙API）——原两行占高且芯片被挤出屏
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
              child: Row(
                children: [
                  PopupMenuButton<String>(
                    // v434：新流程（场景流/分组）不依赖旧弧线存在，仅划分时禁用
                    enabled: !_isDividing,
                    tooltip: '批量操作',
                    position: PopupMenuPosition.under,
                    onSelected: (v) {
                      if (v == 'scan_now' || v == 'continue_scan') {
                        // v457：busy翻转由服务层开头+finally负责（调用方再翻
                        // 一次=三重翻转，终止后卡true=进度条走+按键灰）
                        runGlobalSceneScan(
                          state: state,
                          log: _addLog,
                          previewHook: state.scenePromptPreview
                              ? (sys, user) => PromptPreview.maybePreview(
                                    context,
                                    sysPrompt: sys,
                                    userPrompt: user,
                                    title: '场景扫描词链预览',
                                    enabled: true,
                                  )
                              : null,
                        );
                      }
                      if (v == 'rescan') {
                        _addLog('🔧 菜单触发：重新扫描场景');
                        _confirmRescanScenes(state);
                      }
                    },
                    itemBuilder: (c) => [
                      PopupMenuItem(
                        value: state.globalSceneScannedUpTo > 0
                            ? 'continue_scan'
                            : 'scan_now',
                        height: 40,
                        enabled: !state.sceneStreamBusy && state.chapters.isNotEmpty,
                        child: Text(
                          // v651：标签与实际续扫起点一致——字符级锚点有效时
                          // 续扫自锚点章半章起（不+1），此前固定scannedUpTo+1
                          // 与终端"从第N章起（字符级续切）"差一章
                          (state.sceneResumeChapIdx >= 0 &&
                                  state.sceneResumeChapIdx <
                                      state.chapters.length &&
                                  state.sceneResumeOffset > 0 &&
                                  state.sceneResumeOffset <
                                      state.chapters[state.sceneResumeChapIdx]
                                          .content.length)
                              ? '扫描场景（从第${state.chapters[state.sceneResumeChapIdx].number > 0 ? state.chapters[state.sceneResumeChapIdx].number : state.sceneResumeChapIdx + 1}章锚点处继续）'
                              : state.globalSceneScannedUpTo > 0
                                  ? '扫描场景（从第${state.globalSceneScannedUpTo + 1}章继续）'
                                  : '扫描场景（全书场景流）',
                          style: const TextStyle(fontSize: 13),
                        ),
                      ),
                      const PopupMenuItem(
                        value: 'rescan',
                        height: 40,
                        child: Text(
                          '重新扫描场景（清空场景流重来）',
                          style: TextStyle(fontSize: 13),
                        ),
                      ),
                    ],
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 7,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.primaryContainer,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        '批量▾',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w500,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  // v377：统一词链开关（v465：适配全局场景扫描预览）
                  MiniButton(
                    label: '词链',
                    primary: state.scenePromptPreview,
                    onTap: () => state.setScenePromptPreview(
                      !state.scenePromptPreview,
                    ),
                  ),
                  const SizedBox(width: 4),
                  // v288：生成内容字号（本页独立）
                  ContentFontButtons(
                    pageKey: 'scene',
                    scale: _fontScale,
                    onChanged: (v) {
                      setState(() => _fontScale = v);
                      ContentFont.save('scene', v);
                    },
                  ),
                  const SizedBox(width: 5),
                  // v464：步进胶囊改"章/步"文字尾注（v445此处replace静默失配）
                  SizedBox(
                    width: 44,
                    child: TextField(
                      controller: _sceneStepController,
                      keyboardType: TextInputType.number,
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 13),
                      decoration: const InputDecoration(
                        isDense: true,
                        contentPadding: EdgeInsets.symmetric(
                          horizontal: 4,
                          vertical: 8,
                        ),
                        border: OutlineInputBorder(),
                      ),
                      onChanged: (_) => _saveSceneStep(state),
                      onSubmitted: (_) => _saveSceneStep(state, persist: true),
                    ),
                  ),
                  Text(
                    '章/步',
                    style: TextStyle(fontSize: 10, color: Colors.grey[600]),
                  ),
                  const SizedBox(width: 6),
const Spacer(), // ⚙API推到最右
                  MiniButton(
                    label: '⚙ API',
                    onTap: () => showV119Sheet(
                      context,
                      title: 'API设置 · 场景页',
                      child: ApiConfigPanel(
                        config: state.sceneApi,
                        section: 'scene',
                      ),
                    ),
                  ),
                ],
              ),
            ),
            // v442：统计行——已扫章数/总章+N场景（对齐旧版信息密度）
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
              child: Row(
                children: [
                  Text(
                    '已扫 ${state.globalSceneScannedUpTo}/${state.chapters.length}章 · ${state.globalScenes.length}场景${state.sceneStreamBusy ? " · 扫描中" : ""}',
                    style: TextStyle(
                      fontSize: 11,
                      color: V469Style.textMuted,
                      fontFamily: V469Style.uiFont,
                    ),
                  ),
                ],
              ),
            ),
            if (state.sceneStreamBusy || _isDividing)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 12),
                child: LinearProgressIndicator(minHeight: 2),
              ),
            // v438：全局场景流列表（场景页唯一主体——弧线展示在弧线页）
            // v662：与弧线页同构——Stack[ListView, Positioned(VScrollBar)]，
            // 此前手补括号多了一层导致嵌套错位（红字布局异常）
            Expanded(
              child: ContentFont.area(
                context,
                scale: _fontScale,
                child: state.globalScenes.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              Icons.view_stream,
                              size: 64,
                              color: Colors.grey[400],
                            ),
                            const SizedBox(height: 16),
                            Text(
                              '场景流为空',
                              style: TextStyle(color: Colors.grey[600]),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              '点上方"▶ 扫描场景"开始（弧线在弧线页生成）',
                              style: TextStyle(
                                color: Colors.grey[500],
                                fontSize: 13,
                              ),
                            ),
                          ],
                        ),
                      )
                    : SelectionArea(
                        child: Stack(
                          children: [
                            ListView.builder(
                              controller: _listCtl,
                              itemCount: state.globalScenes.length,
                              itemBuilder: (ctx, i) => SceneCardItem(
                                scene: state.globalScenes[i],
                                index: i + 1,
                                onView: () => showSliceViewerSheet(
                                  context,
                                  title:
                                      '场景${i + 1}：${state.globalScenes[i].name}（${state.globalScenes[i].chapterRange}）',
                                  text: state.globalScenes[i].text,
                                ),
                                onCutResume: () =>
                                    _confirmCutResume(state, i),
                                onRegenSummary: () =>
                                    _regenSceneSummary(state, i),
                              ),
                            ),
                            Positioned(
                              right: 0,
                              top: 0,
                              bottom: 0,
                              child: VScrollBar(_listCtl),
                            ),
                          ],
                        ),
                      ),
              ),
            ),
            // 统一终端（日志+终止）— v468 api-step-log
          ],
        ),
      ),
    );
  }

  /// v439：重新扫描场景确认——清空场景流从第1章重来
  void _confirmRescanScenes(AppState state) {
    // v448：空场景流不再静默return（第一次重扫失败/中断后globalScenes已空，
    // 旧守卫指向已删按键静默返回=重扫永远点不动）——空流照样清空+启动
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('重新扫描场景'),
        content: Text(
          '将清空现有${state.globalScenes.length}个场景（第1-${state.globalSceneScannedUpTo}章），从第1章重新划分。弧线分组结果不受影响但需重新生成。确定？',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('清空重扫'),
          ),
        ],
      ),
    ).then((ok) async {
      _addLog('🔧 重扫确认框返回：ok=$ok');
      if (ok != true) return;
      try {
        state.globalScenes = [];
        state.globalSceneScannedUpTo = 0;
        // v505b：场景流重扫=旧场景划分作废——同步清两容器（旧shots.text残留
        // 会被分镜页/创作切片优先读到=用户看到的"切片内容不对"根因）
        state.arcScenes = {};
        state.arcAnalyses = {};
        // v521b：旧弧线分组结果同步作废（arcScan残留=幽灵弧线：统计7条只拆6条，
        // 那条在两容器无场景数据被静默跳过）
        state.arcScan = null;
        // v654b：分组断点同步清零——此前只清arcScan不清globalGroupedUpTo,
        // 重扫后菜单显示"生成弧线（从场景N继续）"而弧线列表为空(幽灵断点)
        state.globalGroupedUpTo = 0;
        state.saveArcScenes();
        state.saveArcScan(); // 断点与arcScan=null一并落盘（防重启幽灵恢复）
        state.saveGlobalScenes();
        _addLog('✅ 场景流+旧拆解容器+旧弧线分组已清空（${state.chapters.length}章），启动重扫：步进${state.sceneStepSize}章/批');
        // v450：await+catch——同步段异常此前被then吞掉（清空后扫描没启动、
        // UI没刷新=用户看到的"只有清除功能还要重启生效"）
        await runGlobalSceneScan(
          state: state,
          log: _addLog,
        );
      } catch (e) {
        _addLog('⛔ 重扫启动异常：$e');
        if (e is Error) _addLog('   堆栈：${e.stackTrace}');
      }
      if (mounted) setState(() {});
    });
  }

  /// v462：从此场景剪断重扫——丢弃该场景及之后的场景，进度锚回退到其
  /// 起始章前一章，前面的成果保留
  void _confirmCutResume(AppState state, int index) {
    final cut = state.globalScenes[index];
    final keepCount = index;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('从场景${index + 1}剪断重扫'),
        content: Text(
          '将丢弃场景${index + 1}-${state.globalScenes.length}（共${state.globalScenes.length - index}个，含「${cut.name}」），'
          '从第${cut.startChapter}章重新扫描。前面${keepCount}个场景的成果保留。\n\n'
          '注意：若该场景跨章，起始章内属于前一场景的部分会被重新划分。覆盖剪断点的弧线将自动剪除（含横跨弧），前面的弧线成果保留——重扫完成后点批量分组即从断点增量续分。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('剪断重扫'),
          ),
        ],
      ),
    ).then((ok) async {
      if (ok != true) return;
      try {
        // v463：衔接锚点校验——重扫窗口的衔接提示取保留末场景的endText，
        // 新场景从锚点句后划分=不重复保留切片的正文
        final anchorOk = keepCount > 0 &&
            state.globalScenes[keepCount - 1].endText.isNotEmpty;
        state.globalScenes.removeRange(index, state.globalScenes.length);
        // v646：接力前置闭合验证——末场景未自然闭合则自动回退（正文随重扫
        // 窗口重切，原文不丢边界重画），最多回退3个防连环伪闭合
        var effKeep = index;
        final effCount =
            await verifyLastSceneClosure(state, log: _addLog);
        if (effCount != effKeep) {
          _addLog('✂ 闭合回退：保留场景 $effKeep→$effCount');
          effKeep = effCount;
        }
        // v646：回退后的场景随重扫窗口重新划分（原文不丢，边界重画）
        // v534b：字符级续切锚点——从保留末场景切片精确算出章索引+章内偏移，
        // 重扫窗口自该偏移喂文本（不做短句搜索，防两更重头误配）
        final anchorOk2 = computeSceneResumeAnchor(state);
        // 进度锚=保留末场景的endChapter（与字符级锚点同章）
        state.globalSceneScannedUpTo =
            effKeep > 0 ? state.globalScenes[effKeep - 1].endChapter : 0;
        if (effKeep > 0 && !anchorOk2) {
          _addLog('⚠ 字符级锚点未建立（末场景收在章尾或定位失败）——将从整章续扫');
        }
        // v823：剪断后无条件重算弧线裁剪+断点（幂等自愈）——
        // v822前的条件"断点>剪断点才进入"漏掉"断点已被污染成-1但<剪断点"的状态
        // （用户实测：v819崩溃把断点-1持久化，重做剪断也修不回）；无条件重算对
        // 正常状态无副作用（幂等），对被污染状态自动修正
        {
          final stale = <String>{
            for (final a in (state.arcScan?.arcs ?? const <Arc>[]))
              if (a.sceneTo > effKeep) a.number.toString(),
          };
          final keptArcs = state.arcScan?.arcs
                  .where((Arc a) => a.sceneTo <= effKeep)
                  .toList() ?? <Arc>[];
          if (stale.isNotEmpty) {
            state.clearArcCascade(arcNumbers: stale);
            _addLog('ℹ 已级联清空剪断点影响的${stale.length}条弧线（含横跨弧）及分镜/拆解');
          }
          // v822：断点=保留弧线中最大的**有效**sceneTo（sceneTo>0）——
          // 续写规划弧线（sceneTo=-1，无场景映射）混入时会把断点拉成-1
          final tiledKept =
              keptArcs.where((Arc a) => a.sceneTo > 0).toList();
          final keptEnd = tiledKept.isEmpty
              ? 0
              : tiledKept.map((Arc a) => a.sceneTo).reduce((a, b) => a > b ? a : b);
          if (state.globalGroupedUpTo != keptEnd) {
            _addLog('ℹ 分组断点修正：${state.globalGroupedUpTo}→$keptEnd');
          }
          state.globalGroupedUpTo = keptEnd;
          final contCount = keptArcs.length - tiledKept.length;
          if (keptArcs.isNotEmpty) {
            _addLog('ℹ 保留${keptArcs.length}条弧线（场景映射平铺到场景$keptEnd${contCount > 0 ? '；另$contCount条续写规划弧线不受影响' : ''}）——重扫完成后点批量分组，从场景${keptEnd + 1}增量续分');
          }
        }
        state.saveGlobalScenes();
        _addLog(
          '✂ 已剪断：保留${effKeep}个场景，从第${cut.startChapter}章重扫${anchorOk ? "（衔接锚点：「${state.globalScenes[effKeep - 1].endText.length > 20 ? "${state.globalScenes[effKeep - 1].endText.substring(0, 20)}…" : state.globalScenes[effKeep - 1].endText}」）" : ""}（点批量→继续扫描场景）',
        );
      } catch (e) {
        _addLog('⛔ 剪断异常：$e');
      }
      if (mounted) setState(() {});
    });
  }

  /// v819：单场景概述重生成（切片重喂，边界/弧线/分组全不动）
  Future<void> _regenSceneSummary(AppState state, int index) async {
    if (state.sceneStreamBusy) return;
    _addLog('↻ 场景${index + 1}概述重生成中…');
    await regenSceneSummary(state: state, index: index, log: _addLog);
    if (mounted) setState(() {});
  }

  /// 构建单个分镜项
  Widget _shotTag(String icon, String text, Color color) {
    return Text(
      '$icon $text',
      style: TextStyle(fontSize: 11, color: color, fontWeight: FontWeight.w500),
    );
  }

  /// v284：场景名相似度——最长公共子序列长度/较短名长度
  /// 「祖师堂拜师与恪守七戒」vs「祖师堂前与面壁之罚」≈0.36 不告警；
  /// 「智退驼子」vs「智退驼子骗木高峰」=1.0 告警
  static double _nameSimilarity(String a, String b) {
    final s = a.replaceAll(RegExp(r'\s'), '');
    final t = b.replaceAll(RegExp(r'\s'), '');
    if (s.isEmpty || t.isEmpty) return 0;
    if (s == t) return 1;
    if (s.contains(t) || t.contains(s)) return 1;
    final dp = List.generate(
      s.length + 1,
      (_) => List.filled(t.length + 1, 0),
    );
    for (var i = 1; i <= s.length; i++) {
      for (var j = 1; j <= t.length; j++) {
        dp[i][j] = s[i - 1] == t[j - 1]
            ? dp[i - 1][j - 1] + 1
            : (dp[i - 1][j] > dp[i][j - 1] ? dp[i - 1][j] : dp[i][j - 1]);
      }
    }
    final shorter = s.length < t.length ? s.length : t.length;
    return dp[s.length][t.length] / shorter;
  }

  /// 紧凑开关：Checkbox+文字（替代FilterChip，更省面积，Wrap里能全部看见不用滑动）
  Widget _toggleChip(String label, bool value, ValueChanged<bool?> onChanged) {
    // v210：紧凑化——checkbox缩18+字10+间距2，四芯片一屏放得下
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 18,
          height: 18,
          child: Checkbox(
            value: value,
            onChanged: onChanged,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            visualDensity: VisualDensity.compact,
          ),
        ),
        const SizedBox(width: 2),
        Text(
          label,
          style: TextStyle(fontSize: 10, color: value ? null : Colors.grey),
        ),
      ],
    );
  }

  /// 零件徽章（v469语义图标+色）：👤人设N ⚔️冲突N 🌱伏笔N 💡脑洞N
  Widget _metaBadge(String label, dynamic listData, Color color) {
    var count = 0;
    if (listData is List) count = listData.length;
    if (count <= 0) return const SizedBox.shrink();
    const icons = {'人设': '👤', '冲突': '⚔️', '伏笔': '🌱', '脑洞': '💡'};
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        '${icons[label] ?? ''}$label$count',
        style: TextStyle(
          fontSize: 10,
          color: color,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }

}
