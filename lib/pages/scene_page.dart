import 'dart:convert';

import 'dart:async';
import 'package:flutter/material.dart';

import '../widgets/slice_viewer_sheet.dart';
import 'package:provider/provider.dart';

import '../services/scene_stream.dart';
import '../widgets/scene_card_item.dart';
import '../state/app_state.dart';
import '../models/arc.dart';
import '../models/scene.dart';
import '../utils/prompt_builder.dart';
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
                        child: ListView.builder(
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
                          ),
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
        state.saveArcScenes();
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
  void _confirmCutResume(state, int index) {
    final cut = state.globalScenes[index];
    final keepCount = index;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('从场景${index + 1}剪断重扫'),
        content: Text(
          '将丢弃场景${index + 1}-${state.globalScenes.length}（共${state.globalScenes.length - index}个，含「${cut.name}」），'
          '从第${cut.startChapter}章重新扫描。前面${keepCount}个场景的成果保留。\n\n'
          '注意：若该场景跨章，起始章内属于前一场景的部分会被重新划分。剪断后弧线分组需重新生成。',
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
        // 分组断点回退：已分组场景数超出保留范围则回退到剪断点
        if (state.globalGroupedUpTo > effKeep) {
          state.globalGroupedUpTo = effKeep;
          // v537：超出保留范围的弧线级联清掉（分镜/拆解/正文切片连坐）
          final stale = state.arcScan?.arcs
                  .where((Arc a) => a.sceneFrom > effKeep)
                  .map((a) => '${a.number}')
                  .toSet() ??
              {};
          if (stale.isNotEmpty) {
            state.clearArcCascade(arcNumbers: stale);
            _addLog('ℹ 已级联清空场景$effKeep之后的${stale.length}条弧线及分镜/拆解');
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

  /// 划分单个弧线的场景
  Future<void> _divideScenes(
    AppState state,
    int arcIndex, {
    bool batch = false,
  }) async {
    final arcs = state.completedArcs;
    if (arcIndex >= arcs.length) return;
    final arc = arcs[arcIndex];

    if (!batch) {
      setState(() {
        _isDividing = true;
        _statusText = '正在划分弧线${arc.number}的场景...';
      });
    }
    _addLog('开始划分弧线${arc.number}：${arc.title}');
    state.api.clearAbort(); state.userAborted = false; // 清除上次abort残留

    try {
      // 构建chapterMap（和v318一致）——用章号做key
      final chapterMap = <int, dynamic>{};
      for (var i = 0; i < state.chapters.length; i++) {
        final ch = state.chapters[i];
        final num = ch.number > 0 ? ch.number : i + 1;
        if (!chapterMap.containsKey(num)) chapterMap[num] = ch;
        if (!chapterMap.containsKey(i + 1)) chapterMap[i + 1] = ch;
      }

      // 从chapter_range解析起始和结束章号——优先模型字段（fromJson时parseChapterRange已解析，
      // 支持中文数字"第一章-第八章"），为0时再现场解析；解析失败绝不能fallback到全书
      var startNum = arc.startChapter;
      var endNum = arc.endChapter;
      if (startNum <= 0 || endNum <= 0) {
        final parsed = parseChapterRange(arc.chapterRange);
        startNum = parsed.start;
        endNum = parsed.end;
      }
      if (startNum <= 0 || endNum <= 0 || endNum < startNum) {
        _addLog(
          '错误：弧线${arc.number}章节范围解析失败（range=${arc.chapterRange}），请在弧线页检查该弧线数据',
        );
        return;
      }
      if (endNum - startNum + 1 > 120) {
        _addLog(
          '⚠ 弧线${arc.number}范围过大（$startNum-$endNum，${endNum - startNum + 1}章），可能再次触发HTTP 413',
        );
      }

      // v430：划分输入按弧线章节范围从原始章数据现拼（不消费arc.text派生
      // 物）——applySelfTrim:false忽略自身旧tailTrim（重划永远基于干净输入，
      // 修剪错重算即可），prev.tailTrim继承保留（上一弧线的精度=本弧线干净
      // 起点）。arc.text仅在划分成功落库后随尾修剪重物化
      final prevArc = arcIndex > 0 ? arcs[arcIndex - 1] : null;
      final chapterText = ArcText.build(
        state.chapters,
        arcs,
        arcIndex,
        applySelfTrim: false,
      );
      if (chapterText.isEmpty) {
        _addLog('⛔ 弧线${arc.number}章节范围内无正文——请检查弧线章节范围');
        return;
      }

      _addLog(
        '章节文本：${chapterText.length}字，range=${arc.chapterRange} ($startNum-$endNum)',
      );


      // v282：章节边界上下文——共享章检测（全局映射，覆盖跨章/多弧线交织）
      final chapterOwners = <int, List<dynamic>>{};
      for (final other in state.completedArcs) {
        if (other.number == arc.number) continue;
        var os = other.startChapter, oe = other.endChapter;
        if (os <= 0 || oe <= 0) {
          final p = parseChapterRange(other.chapterRange);
          os = p.start;
          oe = p.end;
        }
        for (var n = os; n <= oe; n++) {
          chapterOwners.putIfAbsent(n, () => []).add(other);
        }
      }
      final sharedNotes = <String>[];
      final otherArcsMentioned = <dynamic>{};
      for (var n = startNum; n <= endNum; n++) {
        final others = chapterOwners[n];
        if (others == null) continue;
        // v317：失配已在上方终止（补定位成功或⛔），此处共享章必已锚定切分
        // ——对方内容物理不在文本里，不注入边界指令
        continue;
        for (final other in others) {
          final desc =
              '第$n章同时属于弧线${other.number}《${other.title}》（概述：${other.summary.isEmpty ? '无' : other.summary}）';
          if (!otherArcsMentioned.contains(other)) {
            sharedNotes.add('$desc——该章只提取属于本弧线的情节');
            otherArcsMentioned.add(other);
          } else {
            sharedNotes.add('第$n章同时属于弧线${other.number}《${other.title}》');
          }
        }
      }
      // v282：对方弧线已有场景清单（重划修正用——AI知道具体跳过哪些）
      final otherScenesBuf = StringBuffer();
      for (final other in otherArcsMentioned) {
        final existed = state.arcScenes[other.number.toString()] ?? const [];
        if (existed.isEmpty) continue;
        otherScenesBuf.write('弧线${other.number}《${other.title}》：');
        otherScenesBuf.writeln(
          existed.map((sc) => '${sc.name}(${sc.chapterRange})').join('、'),
        );
      }
      final otherScenes = otherScenesBuf.toString();
      if (sharedNotes.isNotEmpty) {
        _addLog('⚠ 检测到${sharedNotes.length}处章节边界共享，已注入边界指令');
      }
      // v315：能走到这里=共享章均已锚定切分，文本干净无需边界指令
      if (otherScenes.isNotEmpty) {
        _addLog('已附带相邻弧线场景清单供AI避让');
      }
      final unclosed = arc.status == 'incomplete';
      if (unclosed) {
        _addLog('弧线${arc.number}未闭合（incomplete）——已注入阶段性概述指令');
      }

      // 构建prompt
      final systemPrompt = PromptBuilder.buildSceneDivisionSystemPrompt();
      final userPrompt = PromptBuilder.buildSceneDivisionUserPrompt(
        arc,
        chapterText,
        sharedNotes: sharedNotes,
        unclosed: unclosed,
        otherScenes: otherScenes,
      );

      // v469对齐：预览开关持久化+统一预览组件
      final shouldContinue = await PromptPreview.maybePreview(
        context,
        sysPrompt: systemPrompt,
        userPrompt: userPrompt,
        title: '场景划分词链预览',
        enabled: state.scenePromptPreview,
      );
      if (!shouldContinue) {
        _addLog('用户在预览后终止');
        return;
      }

      // 调用API
      final config = state.getApiConfig('scene');
      final result = await state.api.callApi(
        systemPrompt: systemPrompt,
        userPrompt: userPrompt,
        apiConfig: config,
      );

      if (result.isSuccess) {
        _addLog('API返回：${result.content.length}字');

        // 解析JSON（JsonRepair栈式修复，弧线总结+场景）
        final parsed = JsonRepair.parseResponse(result.content);
        if (parsed != null) {
          final arcsJson = parsed['arcs'] as List?;
          final arcMap = (arcsJson != null && arcsJson.isNotEmpty)
              ? arcsJson[0] as Map<String, dynamic>
              : (parsed['scenes'] != null ? parsed : null);
          final scenesJson =
              arcMap?['scenes'] as List? ?? parsed['scenes'] as List? ?? [];
          final scenes = scenesJson
              .map((e) => Scene.fromJson(e as Map<String, dynamic>))
              .toList();

          if (scenes.isNotEmpty) {
            // v320：场景正文锚点物化——链式定位end_text切出每个场景精准切片
            // 失败→补定位重试2次→仍失败⛔终止不落库（用户裁决：不整章兜底）
            // v430：基准文本与划分输入同源（章级现拼，忽略自身旧tailTrim），
            // 偏移坐标系与AI看到的划分原文一致
            final arcText = ArcText.build(
              state.chapters,
              arcs,
              arcIndex,
              applySelfTrim: false,
            );
            var matFail = false;
            if (arcText.isNotEmpty) {
              var searchFrom = 0;
              for (var i = 0; i < scenes.length - 1 && !matFail; i++) {
                final et = scenes[i].endText;
                int? endPos;
                if (et.isNotEmpty) {
                  final idx = arcText.indexOf(et, searchFrom);
                  if (idx >= 0) {
                    endPos = idx + et.length;
                  } else {
                    final tail = arcText.substring(searchFrom);
                    final fz = ArcText.fuzzyLocate(tail, et);
                    if (fz != null) {
                      endPos = searchFrom + tail.indexOf(fz) + fz.length;
                    }
                  }
                }
                if (endPos == null) {
                  _addLog('🔧 场景${i + 1}→${i + 2}分界句定位失败，使用时补定位…');
                  final chNum =
                      parseChapterRange(scenes[i].chapterRange).end;
                  final ch = chapterMap[chNum];
                  String? anchor;
                  if (ch != null) {
                    anchor = await AnchorRepair.locateBoundary(
                      state,
                      config,
                      scenes[i].name,
                      scenes[i].summary,
                      scenes[i + 1].name,
                      scenes[i + 1].summary,
                      ch,
                    );
                  }
                  if (anchor != null) {
                    final idx = arcText.indexOf(anchor, searchFrom);
                    if (idx >= 0) {
                      endPos = idx + anchor.length;
                    } else {
                      final tail = arcText.substring(searchFrom);
                      final fz = ArcText.fuzzyLocate(tail, anchor);
                      if (fz != null) {
                        endPos =
                            searchFrom + tail.indexOf(fz) + fz.length;
                      }
                    }
                  }
                }
                if (endPos == null || endPos <= searchFrom) {
                  _addLog(
                    '⛔ 场景${i + 1}→${i + 2}分界句补定位2次均失败——终止划分不落库，请重试划分或重新扫描',
                  );
                  matFail = true;
                  break;
                }
                // v321：切分点吸附到句末（分镜token数值准确性依赖）
                endPos = ArcText.snapToSentenceEnd(arcText, endPos);
                scenes[i].text = arcText.substring(searchFrom, endPos);
                searchFrom = endPos;
              }
              if (!matFail) {
                scenes.last.text = arcText.substring(searchFrom);
                _addLog('✓ 场景正文切片物化完成（${scenes.length}片，共${arcText.length}字）');
              }
            } else {
              _addLog('⚠ 弧线无物化正文，场景切片跳过');
            }
            if (matFail) return;
            // 保存场景
            state.arcScenes[arc.number.toString()] = scenes;
            state.saveArcScenes();
            _addLog('✓ 识别到${scenes.length}个场景');
            // v388b：映射表增量抽取（场景名/概述里的名称）
            // v392：await串行防撞车
            await state.extractNameMapIncrement(
              scenes.map((sc) => '${sc.name}：${sc.summary}').join('\n'),
            );

            // v282：跨弧线场景重叠校验（兜底AI不听边界指令）——只告警不删
            // v284降噪：章级交叉是同章多弧线的预期形态，只对"疑似真重复"打⚠——
            // 范围完全相同+场景名相似（相似度≥0.5）才告警；其余归入信息级汇总
            final myRanges = scenes
                .map((sc) => parseChapterRange(sc.chapterRange))
                .toList();
            var crossCount = 0;
            var dupCount = 0;
            for (final other in otherArcsMentioned) {
              final existed =
                  state.arcScenes[other.number.toString()] ?? const [];
              for (final osc in existed) {
                final or = parseChapterRange(osc.chapterRange);
                if (or.start <= 0 || or.end <= 0) continue;
                for (var i = 0; i < myRanges.length; i++) {
                  final mr = myRanges[i];
                  if (mr.start <= 0 || mr.end <= 0) continue;
                  if (mr.start <= or.end && or.start <= mr.end) {
                    crossCount++;
                    final sameRange = mr.start == or.start && mr.end == or.end;
                    final sim = _nameSimilarity(
                      scenes[i].name,
                      osc.name,
                    );
                    if (sameRange && sim >= 0.5) {
                      dupCount++;
                      _addLog(
                        '⚠ 疑似重复场景：弧线${arc.number}「${scenes[i].name}」(${scenes[i].chapterRange}) ≈ 弧线${other.number}「${osc.name}」(${osc.chapterRange})，建议对其中一条单独重划',
                      );
                    }
                  }
                }
              }
            }
            if (crossCount > 0 && dupCount == 0) {
              _addLog(
                'ℹ 章级交叉${crossCount}处（同章多弧线预期形态，未发现同名同范围的疑似重复）',
              );
            }

            // v429：弧线尾修剪——AI给出叙事收束句(arc_tail_text)，在弧线text中
            // 定位（精确/归一/LCS三层），换算成闭合章内偏移落arc.tailTrim并重
            // 物化。下一弧线物化时从该偏移继承共享章文本（A剪掉的部分=B开头）
            if (arc.status == 'complete') {
              final tailText =
                  arcMap?['arc_tail_text']?.toString().trim() ?? '';
              if (tailText.isEmpty) {
                _addLog('ℹ 弧线${arc.number}末尾无转场杂质，无需尾修剪');
              } else {
                // v430：定位基准用章级现拼（完整文本，不受旧trim影响）
                final arcText = ArcText.build(
                  state.chapters,
                  arcs,
                  arcIndex,
                  applySelfTrim: false,
                );
                var pos = arcText.lastIndexOf(tailText);
                if (pos < 0) {
                  final fz = ArcText.fuzzyLocate(arcText, tailText);
                  if (fz != null) pos = arcText.lastIndexOf(fz);
                }
                if (pos >= 0) {
                  // 换算：arcText偏移 → 闭合章chFull内偏移
                  final eNum = arc.endChapter > 0
                      ? arc.endChapter
                      : parseChapterRange(arc.chapterRange).end;
                  final marker = '\n\n=== 第$eNum章 ===\n\n';
                  final chStart = arcText.lastIndexOf(marker, pos);
                  if (chStart >= 0) {
                    final chTextStart = chStart + marker.length;
                    // 句末（含闭合引号）之后的第一个字符=修剪点
                    var cut = pos + tailText.length;
                    final chFullLen = arcText.length - chTextStart;
                    var trim = cut - chTextStart;
                    if (trim > 0 && trim < chFullLen) {
                      arc.tailTrim = trim;
                      arc.text = ArcText.build(
                        state.chapters,
                        arcs,
                        arcs.indexOf(arc),
                      );
                      // 最后场景切片同步截尾（划分时切片到文末含杂质）
                      if (scenes.isNotEmpty) {
                        final st = scenes.last.text;
                        final tp = st.lastIndexOf(tailText);
                        if (tp >= 0) {
                          scenes.last.text =
                              st.substring(0, tp + tailText.length);
                        }
                      }
                      state.saveArcScan();
                      _addLog(
                        '✂ 弧线${arc.number}尾修剪生效（第$eNum章偏移$trim，转场段归下一弧线）',
                      );
                    }
                  } else {
                    _addLog('⚠ 弧线${arc.number}尾修剪跳过：闭合章文本标记未找到');
                  }
                } else {
                  _addLog(
                    '⚠ 弧线${arc.number}尾修剪跳过：收束句不在弧线正文中（${tailText.length > 30 ? "${tailText.substring(0, 30)}…" : tailText}）',
                  );
                }
              }
            }

            // 解析弧线总结+弧线零件 → arcAnalyses（v468：划分即提取）
            if (arcMap != null) {
              final summary = arcMap['summary']?.toString() ?? '';
              final old = state.arcAnalyses[arc.number.toString()];
              final analysis =
                  old ??
                  ArcAnalysis(
                    arcNumber: arc.number,
                    arcTitle: arcMap['title']?.toString() ?? arc.title,
                  );
              analysis.arcSummary = summary;
              analysis.scenes = scenes;
              analysis.metadata = {
                ...?analysis.metadata,
                'characters': arcMap['characters'],
                'conflicts': arcMap['conflicts'],
                'foreshadowing': arcMap['foreshadowing'],
                'arc_functions': arcMap['arc_functions'],
                'irreversible_changes': arcMap['irreversible_changes'],
                'emotional_curve': arcMap['emotional_curve'],
                'author_fantasy': arcMap['author_fantasy'],
                'ink_hobby': arcMap['ink_hobby'], // v219笔墨癖好
                'worldbuilding_facts': arcMap['worldbuilding_facts'],
              };
              state.arcAnalyses[arc.number.toString()] = analysis;
              state.saveArcAnalyses();
              // v201方案A：优质概述立即回写弧线页（只覆盖不清除）
              if (state.syncArcSummariesFromAnalyses() > 0) {
                state.saveArcScan();
                _addLog('✓ 弧线概述已同步到弧线页');
              }
              // facts存在metadata分析层；世界书体系在「生成世界书」时才创建
              _addLog(summary.isNotEmpty ? '✓ 弧线总结已提取' : '⚠ 弧线总结为空');
              // v223：AI漏字段的可见性（长输出砍尾老毛病——ink_hobby排schema后段易被砍）
              if (arcMap['ink_hobby'] == null) {
                _addLog('⚠ AI未输出笔墨癖好（长输出砍尾）——弧线零件不完整，建议对该弧线单独重新划分');
              }
            }
            state.refresh();
          } else {
            _addLog('错误：解析到0个场景');
          }
        } else {
          _addLog('错误：JSON解析失败');
        }
      } else {
        _addLog('API错误：${result.error}');
      }
    } catch (e) {
      if (state.api.isAborted || state.userAborted) {
        _addLog('⏹ 已终止');
      } else {
        _addLog('异常：$e');
      }
    } finally {
      if (!batch) {
        setState(() {
          _isDividing = false;
          _statusText = '';
        });
      }
    }
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

  /// v320：场景切片预览对话框（场景行"切片"按键）
  void _previewSceneSlice(
    BuildContext context,
    Scene scene,
    int si,
  ) {
    if (scene.text.isEmpty) {
      _addLog('场景${si + 1}无锚定切片（旧数据）——请重新划分场景');
      return;
    }
    // v352：统一切片查看底板（全宽+A-/A+字号记忆）
    showSliceViewerSheet(
      context,
      title: '场景${si + 1} 锚定切片（${scene.text.length}字）',
      text: scene.text,
    );
  }

  /// 批量划分所有未划分弧线
  Future<void> _batchDivide(AppState state) async {
    final arcs = state.completedArcs;
    final pending = <int>[];
    for (var i = 0; i < arcs.length; i++) {
      final arc = arcs[i];
      if ((state.arcScenes[arc.number.toString()] ?? []).isEmpty)
        pending.add(i);
    }
    if (pending.isEmpty) {
      _addLog('没有需要划分的弧线');
      return;
    }
    setState(() {
      _isDividing = true;
      _statusText = '批量划分：0/${pending.length}弧线';
    });
    _addLog('批量划分开始：${pending.length}条弧线');
    // 清除上次abort残留（v186修复：终止后_aborted=true残留，下次批量循环
    // 首轮isAborted即break——"批量划分被终止"零数据，与弧线页v181同款病）
    state.api.clearAbort(); state.userAborted = false;
    var done = 0;
    // v368：全程try/finally——异常逃逸进度条永久卡死（v285同款病）
    try {
      for (final i in pending) {
        if (state.api.isAborted || state.userAborted) {
          _addLog('⏹ 批量划分被终止');
          break;
        }
        done++;
        setState(() => _statusText = '批量划分：$done/${pending.length}弧线');
        await _divideScenes(state, i, batch: true);
        // v312：失败检测+重试+停机——JSON解析失败常是模型输出劣化的系统性信号，
        // 闷头继续纯烧token且失败弧线易被遗忘（弧线4跳过事故）。失败重试1次，
        // 仍失败停批；"批量划分"的pending按无场景筛选，天然从断点续跑
        final arcKey = arcs[i].number.toString();
        if ((state.arcScenes[arcKey] ?? []).isEmpty) {
          _addLog('⚠ 弧线${arcs[i].number}划分失败，自动重试1次…');
          await _divideScenes(state, i, batch: true);
          if ((state.arcScenes[arcKey] ?? []).isEmpty) {
            _addLog(
              '⛔ 弧线${arcs[i].number}重试仍失败，批量划分已暂停——排查API/模型后重新点"批量划分"从未划分弧线续跑',
            );
            return;
          }
          _addLog('✓ 弧线${arcs[i].number}重试成功');
        }
      }
      _addLog('批量划分完成');
    } finally {
      if (mounted) {
        setState(() {
          _isDividing = false;
          _statusText = '';
        });
      }
    }
  }

  /// 全部重新划分场景确认（v468：清掉对应分镜和世界书条目再重划分）
  Future<void> _confirmRedivideAll(AppState state) async {
    final divided = state.completedArcs
        .where((a) => (state.arcScenes[a.number.toString()] ?? []).isNotEmpty)
        .length;
    if (divided == 0) {
      _addLog('没有已划分的弧线');
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('全部重新划分场景'),
        content: Text('将清掉$divided条弧线的场景划分、对应分镜和世界书条目，然后逐条重新划分。已有拆解结果会被覆盖。确定？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('重新划分'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    // 清场景+分镜+世界书对应条目
    for (final arc in state.completedArcs) {
      final key = arc.number.toString();
      state.arcScenes.remove(key);
      state.arcAnalyses.remove(key);
    }
    state.saveArcScenes();
    state.saveArcAnalyses();
    if (state.worldBook != null) {
      state.worldBook!.entries.removeWhere(
        (_, e) => (e.arcKey ?? '').isNotEmpty,
      );
      state.saveWorldBook();
    }
    _addLog('已清空场景划分和分镜，开始批量重新划分');
    await _batchDivide(state);
  }
}
