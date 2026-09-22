import 'dart:convert';

import 'package:flutter/material.dart';

import '../widgets/slice_viewer_sheet.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../services/api_service.dart';
import '../state/app_state.dart';
import '../models/arc.dart';
import '../models/chapter.dart';
import '../models/scene.dart';
import '../utils/chinese_number.dart';
import '../services/scene_stream.dart';
import '../widgets/scene_card_item.dart';
import '../utils/anchor_repair.dart';
import '../utils/arc_text.dart';
import '../utils/prompt_builder.dart';
import '../utils/prompt_preview.dart';
import '../utils/json_repair.dart';
import '../widgets/content_font.dart';
import '../widgets/api_config_panel.dart';
import '../utils/v469_style.dart';
import '../widgets/api_log_panel.dart';
import '../widgets/v119_ui.dart';

class ScanPage extends StatefulWidget {
  const ScanPage({super.key});

  @override
  State<ScanPage> createState() => _ScanPageState();
}

class _ScanPageState extends State<ScanPage>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true; // 页面滑出PageView时保持State：生成任务不中断/表单不清空

  final _logController = ScrollController();
  final List<String> _logs = [];
  bool _isScanning = false;
  final _groupBatchController = TextEditingController(); // v441：每批场景数
  void _saveGroupBatch(state, {bool persist = false}) {
    final v = int.tryParse(_groupBatchController.text) ?? 0;
    if (v <= 0) return;
    state.groupBatchSize = v;
    if (persist) {
      state.saveGlobalScenes();
      _addLog('弧线分组步进已设为 $v 场景/批');
    }
  }
  String _statusText = '';
  int _scanProgress = 0;
  String _scanStatus = '';
  late TextEditingController _stepController;
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

  bool _previewPrompt = false;
  // v288：生成内容字号（本页独立，0.8~1.6）
  double _fontScale = 1.0;

  @override
  void initState() {
    ContentFont.load('arc').then((v) {
      if (mounted) setState(() => _fontScale = v);
    });
    super.initState();
    // v344教训：python替换曾误吞本行（late未初始化→灰屏四版）
    _stepController = TextEditingController(
        text: AppState.instance.scanStepSize.toString());
    _groupBatchController.text = AppState.instance.groupBatchSize.toString();
  }

  final ScrollController _listCtl = ScrollController(); // v656：列表垂直滚动条

  @override
  void dispose() {
    _listCtl.dispose();
    _logController.dispose();
    _stepController.dispose();
    super.dispose();
  }

  void _addLog(String msg) {
    setState(() {
      _logs.add(msg);
      if (_logs.length > 200) _logs.removeAt(0);
    });
    AppState.instance.apiLog(msg); // 页面日志同步全局终端（信息出口合一）
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_logController.hasClients) {
        _logController.jumpTo(_logController.position.maxScrollExtent);
      }
    });
  }


  /// 续扫（v185）：从某条弧线处截断——保留其之前的弧线，删除该弧线及其后所有
  /// 弧线（含场景/拆解结果），从该弧线起始章重新扫描
  Future<void> _rescanFromArc(AppState state, Arc arc) async {
    if (_isScanning) return;
    if (state.chapters.isEmpty) {
      _addLog('请先加载章节');
      return;
    }
    final prevArcs = state.arcScan?.arcs ?? [];
    // v538：一致性卫兵——弧线必须从场景1连续平铺且不超场景流。违反=两代流
    // 混血状态，按章号回退会误清整个场景流（v537前遗留状态实测89场景全灭），
    // ⛔拒绝剪断，先批量分组重建一致性
    if (prevArcs.isNotEmpty) {
      var tiled = state.globalGroupedUpTo > 0 &&
          state.globalGroupedUpTo <= state.globalScenes.length &&
          prevArcs.first.sceneFrom == 1;
      if (tiled) {
        var expect = 1;
        for (final a in prevArcs) {
          if (a.sceneFrom != expect) {
            tiled = false;
            break;
          }
          expect = a.sceneTo + 1;
        }
      }
      if (!tiled) {
        _addLog('⛔ 弧线与场景流状态不一致（场景流曾重建而旧弧线残留）——拒绝剪断。请先点批量分组重建一致性后再剪');
        return;
      }
    }
    final removedCount = prevArcs.where((a) => a.number >= arc.number).length;
    final range = parseChapterRange(arc.chapterRange);
    final arcStartNum = arc.startChapter > 0
        ? arc.startChapter
        : (range.start > 0
              ? range.start
              : getChapterNumber(arc.chapterRange, 0));

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('从弧线${arc.number}续扫'),
        content: Text(
          '将删除弧线${arc.number}及之后的$removedCount条弧线（含场景划分、拆解结果），'
          '保留前${arc.number - 1}条；场景流同步回退到第$arcStartNum章，之后请到场景页继续扫描。确定？',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('截断续扫'),
          ),
        ],
      ),
    );
    if (ok != true) return;

    // 1. 截断弧线列表：保留编号 < N 的
    final kept = prevArcs.where((a) => a.number < arc.number).toList();

    // 2. 续扫起点：该弧线起始章在章节列表中的index（前向搜索，与重叠区定位同法）
    final chapters = state.chapters;
    int resumeIdx = -1;
    if (arcStartNum > 0) {
      for (var i = 0; i < chapters.length; i++) {
        if (chapters[i].number == arcStartNum) {
          resumeIdx = i;
          break;
        }
      }
      if (resumeIdx < 0) {
        for (var i = 0; i < chapters.length; i++) {
          if (chapters[i].number >= arcStartNum) {
            resumeIdx = i;
            break;
          }
        }
      }
    }
    if (resumeIdx < 0) {
      resumeIdx = (arcStartNum - 1).clamp(0, chapters.length - 1);
    }

    // 3. 清理关联数据：编号 >= N 的场景/拆解（新扫描会重新生成，编号错位会串数据）
    state.arcScenes.removeWhere(
      (k, v) => (int.tryParse(k) ?? 0) >= arc.number,
    );
    state.arcAnalyses.removeWhere(
      (k, v) => (int.tryParse(k) ?? 0) >= arc.number,
    );
    final nums = (state.reportMeta['analyzedArcNumbers'] as List?) ?? [];
    nums.removeWhere(
      (n) => (n is int ? n : int.tryParse('$n') ?? 0) >= arc.number,
    );
    state.reportMeta['analyzedArcNumbers'] = nums;

    // 4. v538（v537前遗留状态清空89场景事故）：场景流按场景索引精确裁剪——
    // 剪弧线N=删除其sceneFrom起的所有场景；不再按章号removeWhere（重复章号/
    // 两代混血下会越过存量清空整个流）。卫兵已保证弧线平铺与流一致
    final before = state.globalScenes.length;
    final cutSceneIdx = (arc.sceneFrom - 1).clamp(0, state.globalScenes.length);
    if (arc.number > 1 && cutSceneIdx < state.globalScenes.length) {
      state.globalScenes.removeRange(cutSceneIdx, state.globalScenes.length);
    } else if (arc.number > 1) {
      _addLog('⚠ 弧线${arc.number}的场景范围超出场景流存量——场景流保持不变（只裁弧线）');
    }
    // v646：接力前置闭合验证——末场景未自然闭合则自动回退重切（正文随重扫
    // 窗口重新划分），最多回退3个防连环伪闭合
    final effKeep =
        await verifyLastSceneClosure(state, log: _addLog);
    if (effKeep != state.globalScenes.length) {
      _addLog('✂ 闭合回退：场景流裁到$effKeep个');
      state.globalGroupedUpTo = effKeep;
      final stale = state.arcScan?.arcs
              .where((Arc a) => a.sceneFrom > effKeep)
              .map((a) => '${a.number}')
              .toSet() ?? <String>{};
      if (stale.isNotEmpty) {
        state.clearArcCascade(arcNumbers: stale);
      }
    }
    state.globalGroupedUpTo = state.globalScenes.length;
    // v534b：字符级续切锚点同步重算（保留末场景切片→章索引+章内偏移）
    computeSceneResumeAnchor(state);
    if (state.globalScenes.isNotEmpty) {
      state.globalSceneScannedUpTo = state.globalScenes.last.endChapter;
    } else {
      state.globalSceneScannedUpTo = 0;
    }
    state.saveGlobalScenes();

    // 5. 保存截断后的进度
    state.arcScan = ArcScan(arcs: kept, scannedChapterCount: resumeIdx);
    state.saveArcScan();
    state.saveArcScenes();
    state.saveArcAnalyses();
    state.saveReportMeta();
    state.refresh();

    _addLog(
      '✂ 已截断：保留${kept.length}条弧线，删除$removedCount条（含场景/拆解），'
      '场景流回退${before - state.globalScenes.length}个场景（剩${state.globalScenes.length}，至第${state.globalScenes.isEmpty ? 0 : state.globalScenes.last.endChapter}章）',
    );
    _addLog('↩ 请到场景页继续扫描，扫完再到本页批量分组');
  }

  @override
  Widget build(BuildContext context) {
    super.build(context); // AutomaticKeepAlive必须
    final state = context.watch<AppState>();
    final arcs = state.allArcs;

    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            // 顶行：高频操作（v192横向单行：放不下时横滑不折行，省纵向空间）
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 2),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                  // v437：弧线页职责=分组+展示。场景扫描按键在场景页
                  // v445：生成弧线进批量菜单（第一行省空间）；步进改"场景/步"尾注
                  SizedBox(
                    width: 44,
                    child: TextField(
                      controller: _groupBatchController,
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
                      onChanged: (_) => _saveGroupBatch(state),
                      onSubmitted: (_) => _saveGroupBatch(state, persist: true),
                    ),
                  ),
                  Text(
                    '场景/步',
                    style: TextStyle(fontSize: 10, color: Colors.grey[600]),
                  ),
                  const SizedBox(width: 6),
                  PopupMenuButton<String>(
                    enabled: !state.sceneStreamBusy && state.globalScenes.isNotEmpty,
                    tooltip: '批量操作',
                    position: PopupMenuPosition.under,
                    onSelected: (v) {
                      if (v == 'gen_group' || v == 'resume_group') {
                        // v457：同上，busy翻转全归服务层
                        groupArcsFromScenes(
                          state: state,
                          log: _addLog,
                          previewHook: _previewPrompt
                              ? (sys, user) => PromptPreview.maybePreview(
                                    context,
                                    sysPrompt: sys,
                                    userPrompt: user,
                                    title: '弧线分组词链预览',
                                    enabled: true,
                                  )
                              : null,
                          resume: state.globalGroupedUpTo > 0,
                        );
                      }
                      if (v == 'regen_group') _confirmRegenArcs(state);
                    },
                    itemBuilder: (c) => [
                      PopupMenuItem(
                        value: state.globalGroupedUpTo > 0
                            ? 'resume_group'
                            : 'gen_group',
                        height: 40,
                        child: Text(
                          state.globalGroupedUpTo > 0
                              ? '生成弧线（从场景${state.globalGroupedUpTo + 1}继续）'
                              : '生成弧线',
                          style: const TextStyle(fontSize: 13),
                        ),
                      ),
                      const PopupMenuItem(
                        value: 'regen_group',
                        height: 40,
                        child: Text(
                          '重新生成全部弧线（清现有分组）',
                          style: TextStyle(fontSize: 13),
                        ),
                      ),
                    ],
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 6),
                      decoration: BoxDecoration(
                        color: V469Style.surfaceAlt,
                        borderRadius: BorderRadius.circular(15),
                        border: Border.all(color: V469Style.border),
                      ),
                      child: const Text(
                        '批量 ▾',
                        style: TextStyle(fontSize: 12.5),
                      ),
                    ),
                  ),
                  const SizedBox(width: 5),
                  const SizedBox(width: 8), // Wrap内Spacer失效，用定宽占位
                  const SizedBox(width: 4),
                  const SizedBox(width: 4),
                  ContentFontButtons(
                    pageKey: 'arc',
                    scale: _fontScale,
                    onChanged: (v) {
                      setState(() => _fontScale = v);
                      ContentFont.save('arc', v);
                    },
                  ),
                  const SizedBox(width: 4),
                  MiniButton(
                    label: '⚙ API',
                    onTap: () => showV119Sheet(
                      context,
                      title: 'API设置 · 弧线扫描',
                      child: ApiConfigPanel(
                        config: state.getApiConfig('arc'),
                        section: 'arc',
                      ),
                    ),
                  ),
                  ],
                ),
              ),
            ),
            // 第二行：状态（v441旧按章步进撤——场景/分组步进各自在对应页）
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 2),
              child: Row(
                children: [
                  if (state.arcScan != null)
                    Expanded(
                      child: Text(
                        '已扫 ${state.arcScan!.scannedChapterCount}/${state.chapters.length}章 · ${arcs.length}弧线${_isScanning ? " · $_scanStatus" : ""}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 10, color: Colors.grey[600]),
                      ),
                    ),
                ],
              ),
            ),
            if (_isScanning || state.sceneStreamBusy)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 8),
                child: LinearProgressIndicator(minHeight: 2),
              ),

            // 弧线列表
            Expanded(
              flex: 2,
              child: ContentFont.area(context, scale: _fontScale, child: arcs.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.timeline,
                            size: 64,
                            color: Colors.grey[400],
                          ),
                          const SizedBox(height: 16),
                          Text(
                            '暂无弧线',
                            style: TextStyle(color: Colors.grey[600]),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            state.chapters.isEmpty ? '请先上传章节' : '点击"开始扫描"识别弧线',
                            style: TextStyle(
                              color: Colors.grey[500],
                              fontSize: 13,
                            ),
                          ),
                        ],
                      ),
                    )
                  : SelectionArea(
                    child: Scrollbar(
                      controller: _listCtl,
                      thumbVisibility: true,
                      thickness: 14, // v657：默认8px手指点不到
                      radius: const Radius.circular(7),
                      child: ListView.builder(
                        controller: _listCtl,
                        itemCount: arcs.length,
                      itemBuilder: (ctx, i) {
                        final arc = arcs[i];
                        final isComplete = arc.status == 'complete';
                        // v469对齐：弧线卡带状态左边条+弧线N金棕徽章+状态徽章
                        return Container(
                          margin: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: V469Style.surface,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: V469Style.border),
                            boxShadow: const [
                              BoxShadow(
                                color: Color(0x142C1810),
                                blurRadius: 3,
                                offset: Offset(0, 1),
                              ),
                            ],
                          ),
                          child: Container(
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(8),
                              border: Border(
                                left: BorderSide(
                                  color: isComplete
                                      ? V469Style.complete
                                      : V469Style.incomplete,
                                  width: 3,
                                ),
                              ),
                            ),
                            child: ExpansionTile(
                              key: _tileKey('arc_${arc.number}'),
                              onExpansionChanged: (v) {
                                if (v) _scrollTileToTop('arc_${arc.number}');
                              },
                              leading: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 3,
                                ),
                                decoration: BoxDecoration(
                                  color: V469Style.accent,
                                  borderRadius: BorderRadius.circular(13),
                                ),
                                child: Text(
                                  '弧线${arc.number}',
                                  style: const TextStyle(
                                    fontSize: 10.5,
                                    fontWeight: FontWeight.w700,
                                    color: Colors.white,
                                  ),
                                ),
                              ),
                              title: Text(
                                arc.title,
                                style: const TextStyle(
                                  fontSize: 13.5,
                                  fontWeight: FontWeight.w600,
                                  color: V469Style.textMain,
                                ),
                              ),
                              subtitle: Padding(
                                padding: const EdgeInsets.only(top: 3),
                                // v498：分行布局（用户截图：单Row挤成瘦长条阅读困难）——
                                // 行1=范围+闭合badge，行2=统计+视角badge，Wrap自动换行
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Wrap(
                                      spacing: 6,
                                      runSpacing: 4,
                                      crossAxisAlignment: WrapCrossAlignment.center,
                                      children: [
                                        Text(
                                          arc.sceneFrom >= 0
                                              ? '场景${arc.sceneFrom}-${arc.sceneTo} · ${arc.chapterRange}'
                                              : arc.chapterRange,
                                          style: const TextStyle(
                                            fontSize: 11,
                                            color: V469Style.textMuted,
                                          ),
                                        ),
                                        if (isComplete)
                                          V469Style.badge(
                                            arc.closeType == 'pseudo'
                                                ? '🔗 伪闭合'
                                                : '✅ 完整',
                                            arc.closeType == 'pseudo'
                                                ? const Color(0xFF8B5CF6)
                                                : V469Style.complete,
                                            arc.closeType == 'pseudo'
                                                ? const Color(0x148B5CF6)
                                                : V469Style.completeBg,
                                          )
                                        else
                                          V469Style.badge(
                                            '⚠️ 不完整',
                                            V469Style.incomplete,
                                            V469Style.incompleteBg,
                                          ),
                                      ],
                                    ),
                                    const SizedBox(height: 4),
                                    Wrap(
                                      spacing: 6,
                                      runSpacing: 4,
                                      crossAxisAlignment: WrapCrossAlignment.center,
                                      children: [
                                        // v497：零件统计徽章
                                        if (state.arcAnalyses[arc.number.toString()]?.metadata?['characters'] is List)
                                          Builder(builder: (ctx) {
                                            final md = state.arcAnalyses[arc.number.toString()]!.metadata!;
                                            return V469Style.badge(
                                              '人设${(md['characters'] as List).length}'
                                              '·冲突${(md['conflicts'] as List? ?? []).length}'
                                              '·伏笔${(md['foreshadowing'] as List? ?? []).length}'
                                              '·脑洞${(md['author_fantasy'] as List? ?? []).length}',
                                              V469Style.accent,
                                              V469Style.accentBg,
                                            );
                                          }),
                                        // v283：视角主角徽章
                                        if (arc.focusCharacter.isNotEmpty)
                                          V469Style.badge(
                                            '👤 ${arc.focusCharacter}',
                                            const Color(0xFF0E7490),
                                            const Color(0x140E7490),
                                          ),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                              children: [
                                Container(
                                  width: double.infinity,
                                  padding: const EdgeInsets.all(12),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      if (arc.summary.isNotEmpty) ...[
                                        Text(
                                          '📝 概述',
                                          style: const TextStyle(
                                            fontSize: 11,
                                            fontWeight: FontWeight.w700,
                                            color: const Color(0xFF475569),
                                          ),
                                        ),
                                        Text(
                                          arc.summary,
                                          style: const TextStyle(
                                            fontSize: 12.5,
                                            height: 1.5,
                                            color: V469Style.textSec,
                                          ),
                                        ),
                                        const SizedBox(height: 8),
                                      ],
                                      if (arc.closureEvent != null &&
                                          arc.closureEvent!.isNotEmpty) ...[
                                        Text(
                                          '🔒 闭合变化',
                                          style: const TextStyle(
                                            fontSize: 11,
                                            fontWeight: FontWeight.w700,
                                            color: Color(0xFFB45309),
                                          ),
                                        ),
                                        Text(
                                          arc.closureEvent!,
                                          style: const TextStyle(
                                            fontSize: 12,
                                            height: 1.5,
                                            color: V469Style.textSec,
                                          ),
                                        ),
                                        const SizedBox(height: 8),
                                      ],
                                      Builder(builder: (_) {
                                        final analysis = state
                                            .arcAnalyses[arc.number.toString()];
                                        final scenes =
                                            analysis?.scenes ?? const [];
                                        if (scenes.isEmpty) {
                                          return const SizedBox.shrink();
                                        }
                                        return Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              '🎬 场景（${scenes.length}）',
                                              style: const TextStyle(
                                                fontSize: 11,
                                                fontWeight: FontWeight.w700,
                                                color: Color(0xFF0E7490),
                                              ),
                                            ),
                                            const SizedBox(height: 4),
                                            ...scenes.map(
                                                  (sc) => SceneCardItem(
                                                    scene: sc,
                                                    // v469：全局场景流编号（与场景页对账）
                                                    index: sc.globalIndex + 1,
                                                    onView: () =>
                                                        showSliceViewerSheet(
                                                      context,
                                                      title:
                                                          '场景${sc.globalIndex + 1}：${sc.name}',
                                                      text: sc.text,
                                                    ),
                                                  ),
                                                ),
                                            const SizedBox(height: 8),
                                          ],
                                        );
                                      }),
                                      if (arc.coreChange.isNotEmpty) ...[
                                        Text(
                                          '💎 不可逆变化',
                                          style: const TextStyle(
                                            fontSize: 11,
                                            fontWeight: FontWeight.w700,
                                            color: const Color(0xFF7C3AED),
                                          ),
                                        ),
                                        Text(
                                          arc.coreChange,
                                          style: const TextStyle(
                                            fontSize: 12.5,
                                            height: 1.5,
                                            color: V469Style.textSec,
                                          ),
                                        ),
                                        const SizedBox(height: 8),
                                      ],
                                      // 跳转按钮（v204：紧凑化——图标14字11
                                      // +compact密度+间距4，窄屏不超右缘不换行）
                                      Row(
                                        children: [
                                          // v474：剪断重分——从本弧线起始场景剪断，
                                          // 删本弧线及之后、断点回退，走分组通道增量重分
                                          const SizedBox(width: 4),
                                          FilledButton.tonalIcon(
                                            icon: const Icon(
                                              Icons.content_cut,
                                              size: 14,
                                            ),
                                            label: const Text('剪断重分'),
                                            style: FilledButton.styleFrom(
                                              backgroundColor: const Color(
                                                0xFFFEE2E2,
                                              ),
                                              foregroundColor: const Color(
                                                0xFFB91C1C,
                                              ),
                                              visualDensity:
                                                  VisualDensity.compact,
                                              textStyle: const TextStyle(
                                                fontSize: 11,
                                              ),
                                            ),
                                            onPressed: _isScanning ||
                                                    state.sceneStreamBusy
                                                ? null
                                                : () {
                                                  // v474：走分组通道——从本弧线
                                                  // 起始场景剪断（旧通道兜底）
                                                  final scenes = state
                                                      .arcScenes[
                                                          arc.number.toString()]
                                                      ?.where((s) =>
                                                          s.globalIndex >= 0)
                                                      .toList();
                                                  if (scenes != null &&
                                                      scenes.isNotEmpty) {
                                                    _confirmCutRegroup(
                                                      state,
                                                      scenes.first,
                                                    );
                                                  } else {
                                                    _rescanFromArc(state, arc);
                                                  }
                                                },
                                          ),
                                          // v296：浏览弧线精准正文（人工抽查分割）
                                          const SizedBox(width: 4),
                                          FilledButton.tonalIcon(
                                            icon: const Icon(
                                              Icons.article_outlined,
                                              size: 14,
                                            ),
                                            label: const Text('正文'),
                                            style: FilledButton.styleFrom(
                                              visualDensity:
                                                  VisualDensity.compact,
                                              textStyle: const TextStyle(
                                                fontSize: 11,
                                              ),
                                            ),
                                            onPressed: () =>
                                                _showArcText(state, arc),
                                          ),
                                        ],
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                      ),
                    ),
                  ),
            )),

            // 统一终端（日志+计时+终止）— v468 api-step-log
          ],
        ),
      ),
    );
  }

  /// v296：完备划分体检——全量已扫弧线对账（无丢失/无重叠），结果弹窗+终端
  void _runPartitionAudit() {
    final state = context.read<AppState>();
    final arcs = state.arcScan?.arcs ?? const <Arc>[];
    final report = ArcTextAudit.audit(state.chapters, arcs);
    for (final line in report) {
      _addLog(line);
    }
    showV119Sheet(
      context,
      title: '弧线划分体检',
      child: SelectionArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final line in report)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(
                  line,
                  style: const TextStyle(fontSize: 13),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// v296：浏览弧线精准正文（arc.text物化值；空则现场算兜底）
  void _showArcText(AppState state, Arc arc) {
    final text = arc.text.isNotEmpty ? arc.text : '';
    // v352：统一切片查看底板（全宽+A-/A+字号记忆）
    showSliceViewerSheet(
      context,
      title: '弧线${arc.number}正文 · ${arc.chapterRange}（${text.length}字）',
      text: text,
      emptyHint: '（正文未物化——旧数据请重扫或划一次场景后查看）',
    );
  }

  /// 步进式扫描（对照v318 doSteppedScan逻辑重写）
  /// v469：从某场景剪断重新生成弧线（走场景组合分组通道，非旧划分通道）
  /// ——删掉含该场景及之后的弧线，分组断点回退到该场景，增量重新生成
  void _confirmCutRegroup(state, Scene scene) {
    final cutIdx = scene.globalIndex; // 0-based
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('从场景${cutIdx + 1}剪断重分弧线'),
        content: Text(
          '将删掉覆盖场景${cutIdx + 1}及之后的弧线（前面的弧线和场景成果保留），'
          '分组断点回退到场景${cutIdx + 1}，然后点批量→"生成弧线（从场景${cutIdx + 1}继续）"增量重分。确定？',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('剪断重分'),
          ),
        ],
      ),
    ).then((ok) async {
      if (ok != true) return;
      try {
        final arcs = state.arcScan?.arcs ?? <Arc>[];
        // 删掉覆盖剪断场景及之后的弧线（sceneTo>=剪断场景即受影响）
        final kept = arcs
            .where((a) => a.sceneTo >= 0 && a.sceneTo < cutIdx)
            .toList();
        final removed = arcs.length - kept.length;
        state.arcScan = ArcScan(
          arcs: kept,
          scannedChapterCount: state.arcScan?.scannedChapterCount ?? 0,
        );
        // 清掉被删弧线的分析/场景容器
        final removedNums =
            arcs.where((a) => a.sceneTo < 0 || a.sceneTo >= cutIdx).map((a) => a.number.toString());
        for (final k in removedNums) {
          state.arcAnalyses.remove(k);
          state.arcScenes.remove(k);
        }
        state.globalGroupedUpTo = cutIdx;
        state.saveArcScan();
        state.saveArcAnalyses();
        state.saveArcScenes();
        state.saveGlobalScenes();
        _addLog(
          '✂ 已剪断重分点：删除$removed条弧线，保留${kept.length}条，分组断点=场景${cutIdx + 1}——点批量→"生成弧线（从场景${cutIdx + 1}继续）"',
        );
      } catch (e) {
        _addLog('⛔ 剪断重分异常：$e');
      }
      if (mounted) setState(() {});
    });
  }

  /// v439：重新生成全部弧线确认——清分组结果+断点归零
  void _confirmRegenArcs(state) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('重新生成全部弧线'),
        content: Text(
          '将清掉现有${state.arcScan?.arcs.length ?? 0}条弧线及其场景归属，从场景1重新分组。场景流本身不动。确定？',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('清空重分'),
          ),
        ],
      ),
    ).then((ok) async {
      _addLog('🔧 重新生成确认框返回：ok=$ok');
      if (ok != true) return;
      state.arcScan = null;
      state.arcAnalyses.clear();
      state.arcScenes.clear();
      state.globalGroupedUpTo = 0;
      state.saveArcScan();
      state.saveArcAnalyses();
      state.saveArcScenes();
      state.saveGlobalScenes();
      _addLog('分组已清空，自动从头重新生成弧线（含逐弧线零件提取）');
      try {
        await groupArcsFromScenes(state: state, log: _addLog);
      } catch (e) {
        _addLog('⛔ 重新生成异常：$e');
      }
      if (mounted) setState(() {});
    });
  }


  /// 末条弧线完整性检查：截断JSON栈修复后末弧字段畸形
  /// （range空/endChapter=0/status空——正常输出这三者必有），中段弧线正常
  bool _hasMalformedTailArc(List<Arc> arcs) {
    if (arcs.isEmpty) return true;
    final t = arcs.last;
    return t.chapterRange.trim().isEmpty ||
        t.endChapter <= 0 ||
        t.status.trim().isEmpty;
  }

  List<Arc>? _parseArcResponse(String content) {
    final json = JsonRepair.parseResponse(content);
    if (json == null) {
      _addLog('JSON解析失败');
      return null;
    }
    final arcsJson = json['arcs'] as List? ?? [];
    final arcs = arcsJson
        .map((e) => Arc.fromJson(e as Map<String, dynamic>))
        .toList();
    // v292：伪闭合回归（角色变化+叙事段收束可闭合），close_type按AI原样保留
    // 确保每个弧线有编号
    for (var i = 0; i < arcs.length; i++) {
      if (arcs[i].number == 0) arcs[i].number = i + 1;
    }
    // v310：AI输出'第41章-大结局'这类范围时，'大结局'被getChapterNumber沉底为
    // 100000——钳回实际章数并修正range显示（否则步进规划/日志/下游全部带出100000）
    final totalCh = AppState.instance.chapters.length;
    if (totalCh > 0) {
      for (var i = 0; i < arcs.length; i++) {
        final a = arcs[i];
        final sN = a.startChapter > 0
            ? a.startChapter
            : parseChapterRange(a.chapterRange).start;
        var eN = a.endChapter > 0
            ? a.endChapter
            : parseChapterRange(a.chapterRange).end;
        if (eN > totalCh) eN = totalCh;
        if (eN < sN) eN = sN;
        if (a.startChapter != sN || a.endChapter != eN) {
          arcs[i] = Arc(
            number: a.number,
            title: a.title,
            chapterRange: '第$sN-$eN章',
            startChapter: sN,
            endChapter: eN,
            status: a.status,
            summary: a.summary,
            coreChange: a.coreChange,
            focusCharacter: a.focusCharacter,
            closeType: a.closeType,
            boundaryAnchor: a.boundaryAnchor,
            boundaryOffset: a.boundaryOffset,
          );
        }
      }
    }
    return arcs;
  }

  Future<bool> _showPromptPreview(String sys, String user) async {
    // 委托公共PromptPreview（分块显示，无截断）
    return PromptPreview.show(
      context,
      sysPrompt: sys,
      userPrompt: user,
      title: '弧线扫描词链预览',
    );
  }

  /// 紧凑开关：Checkbox+文字（替代FilterChip，省面积）
  Widget _compactToggle(
    String label,
    bool value,
    ValueChanged<bool?> onChanged,
  ) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 20,
          height: 20,
          child: Checkbox(
            value: value,
            onChanged: onChanged,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            visualDensity: VisualDensity.compact,
          ),
        ),
        const SizedBox(width: 4),
        Text(
          label,
          style: TextStyle(fontSize: 11, color: value ? null : Colors.grey),
        ),
      ],
    );
  }
}
