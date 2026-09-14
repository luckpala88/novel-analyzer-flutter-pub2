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
  bool _scanAborted = false;
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

  @override
  void dispose() {
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
          '保留前${arc.number - 1}条，并从第$arcStartNum章开始重新扫描识别。确定？',
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

    // 4. 保存截断后的进度（kept为空=从弧线1续扫，_startScan自动走全量）
    state.arcScan = ArcScan(arcs: kept, scannedChapterCount: resumeIdx);
    state.saveArcScan();
    state.saveArcScenes();
    state.saveArcAnalyses();
    state.saveReportMeta();
    state.refresh();

    _addLog(
      '✂ 已截断：保留${kept.length}条弧线，删除$removedCount条（含场景/拆解），'
      '从第${arcStartNum > 0 ? arcStartNum : resumeIdx + 1}章续扫',
    );

    // 5. 立即从断点开始扫描
    await _startScan(state, false);
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
                    child: ListView.builder(
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

  Future<void> _startScan(AppState state, bool fullRescan) async {
    setState(() {
      _isScanning = true;
      _scanAborted = false;
      _logs.clear();
    });
    // 清除上次abort残留（v181修复：上次终止后_aborted=true残留，
    // 本次每步callApi进rpmGuard即被秒拒'用户中断'——65步瞬间全"已终止"但零数据）
    state.api.clearAbort();
    state.userAborted = false; // v224

    try {
      final chapters = state.chapters;
      final totalChapters = chapters.length;
      // 从输入框读取最新的步进值，而不是依赖state里可能过期的值
      final stepSize = int.tryParse(_stepController.text) ?? state.scanStepSize;
      state.scanStepSize = stepSize;
      state.storage.writeGlobal('scan_step_size', stepSize.toString());

      // 确定起始状态
      List<Arc> confirmedArcs = [];
      Arc? lastIncArc;
      int scannedUpTo = 0;

      if (!fullRescan &&
          state.arcScan != null &&
          state.arcScan!.arcs.isNotEmpty) {
        final prevArcs = state.arcScan!.arcs;
        // v283：群像书可能多条线同时未闭合——从"最早起始的未闭合弧线"处切断，
        // 它之后的所有未闭合弧线（并行的其他线）一并送重判，不再冻结中间的开弧线
        Arc? earliestOpen;
        for (final a in prevArcs) {
          if (a.status != 'incomplete') continue;
          final s = a.startChapter > 0
              ? a.startChapter
              : parseChapterRange(a.chapterRange).start;
          if (earliestOpen == null ||
              s < (earliestOpen.startChapter > 0
                  ? earliestOpen.startChapter
                  : parseChapterRange(earliestOpen.chapterRange).start)) {
            earliestOpen = a;
          }
        }
        if (earliestOpen != null) {
          final cutIdx = prevArcs.indexOf(earliestOpen);
          confirmedArcs = prevArcs.sublist(0, cutIdx);
          lastIncArc = earliestOpen;
        } else {
          confirmedArcs = prevArcs.sublist(0);
        }
        scannedUpTo = state.arcScan!.scannedChapterCount;
      } else {
        // 全量扫描：清除旧结果
        state.arcScan = null;
        state.arcScenes = {};
        state.arcAnalyses = {};
        state.saveArcScan();
        state.saveArcScenes();
        state.saveArcAnalyses();
      }

      if (scannedUpTo >= totalChapters) {
        _addLog('所有章节已扫描完毕，如需重新扫描请选择"全量重新扫描"');
        return;
      }

      final remainingChapters = totalChapters - scannedUpTo;
      final totalSteps = (remainingChapters / stepSize).ceil();
      int currentStep = 0;

      _addLog('开始扫描：$totalChapters章，剩余$remainingChapters章，共$totalSteps步');
      // 诊断：显示前20章编号分布
      if (totalChapters >= 20) {
        final first20 = chapters
            .take(20)
            .map(
              (c) =>
                  '${c.number}:${c.title.substring(0, c.title.length > 15 ? 15 : c.title.length)}',
            )
            .join(' | ');
        _addLog('前20章编号: $first20');
      }

      while (scannedUpTo < totalChapters) {
        // v224：终端abort按钮的广播标志（_scanAborted只由本页停止键设置）
        if (_scanAborted || state.userAborted) {
          state.userAborted = false; // 消费即清（防影响下任务）
          _addLog('已终止（已完成$currentStep/$totalSteps步）');
          break;
        }

        currentStep++;

        // 计算重叠区：从lastIncArc的起始章开始（最多15章重叠）
        const maxOverlap = 15;
        int overlapStart = scannedUpTo;
        bool overlapCapped = false;

        if (lastIncArc != null) {
          // 解析弧线起始章号——用parseChapterRange而非split
          final range = parseChapterRange(lastIncArc.chapterRange);
          final arcStartNum = range.start > 0
              ? range.start
              : getChapterNumber(lastIncArc.chapterRange, 0);
          if (arcStartNum > 0) {
            // 向前搜索弧线起始章
            bool found = false;
            for (var ci = 0; ci < scannedUpTo; ci++) {
              if (chapters[ci].number == arcStartNum) {
                overlapStart = ci;
                found = true;
                break;
              }
            }
            if (!found) {
              for (var ci = 0; ci < scannedUpTo; ci++) {
                if (chapters[ci].number >= arcStartNum) {
                  overlapStart = ci;
                  found = true;
                  break;
                }
              }
            }
            if (found && scannedUpTo - overlapStart > maxOverlap) {
              overlapStart = scannedUpTo - maxOverlap;
              overlapCapped = true;
            }
            if (!found) {
              overlapStart = (scannedUpTo - maxOverlap).clamp(0, scannedUpTo);
              overlapCapped = true;
            }
          }
        }

        final endIdx = (scannedUpTo + stepSize).clamp(0, totalChapters);
        final chaptersToScan = chapters.sublist(overlapStart, endIdx);

        // 构建上下文摘要
        final contextBuf = StringBuffer();
        if (confirmedArcs.isNotEmpty) {
          contextBuf.writeln('已确认的弧线（不需要重新分析，仅供上下文参考）：');
          for (final a in confirmedArcs) {
            // 完整摘要（标题+摘要）：给下一步弧线边界判断提供剧情语义参考
            // （v180曾脱敏防Google拦截——后证实拦截真凶是病毒txt，恢复保精度）
            contextBuf.writeln(
              '- 弧线${a.number}：${a.title}（${a.chapterRange}）— ${a.summary} [状态：${a.status == 'complete' ? '闭合' : '未闭合'}]',
            );
          }
          contextBuf.writeln();
          contextBuf.writeln(
            '以下是最早一条未闭合弧线及新增章节的内容，请继续扫描（弧线编号从${confirmedArcs.length + 1}开始）：',
          );
          if (lastIncArc != null) {
            contextBuf.writeln(
              // v283：群像书——重判范围覆盖最早开弧线及其后所有并行开弧线
              '注意：未闭合弧线可能有多条（群像书多线并行）。最早一条未闭合弧线是（${lastIncArc.title}，${lastIncArc.chapterRange}），其后与它并行推进的其他未闭合弧线也一并重新判断完整范围，后续新增弧线照常识别。不同线的弧线范围允许重叠。',
            );
            if (overlapCapped) {
              contextBuf.writeln('（注：由于弧线较长，下方仅给出该弧线最后部分章节，请结合上方概述判断）');
            }
          }
        }

        final sys = PromptBuilder.buildScanSystemPrompt(
          confirmedArcs.isNotEmpty,
          confirmedArcs.length,
        );
        // v176：章节标记只发序号不发标题——标题是Google内容政策拦截的主要触发源
        // （如"青楼开张/摸女修士的手"）；"第N章"保留章节边界识别能力
        final chapterText = chaptersToScan
            .map((ch) => '\n\n=== 第${ch.number}章 ===\n\n${ch.content}')
            .join();
        final user = '$contextBuf\n请扫描以下网文章节，识别弧线边界：\n$chapterText';

        // 进度显示
        final newChapters = endIdx - scannedUpTo;
        final overlapChapters = scannedUpTo - overlapStart;
        final totalScanChapters = endIdx - overlapStart; // 本步总扫描章数
        final stepStartCh = overlapStart < chapters.length
            ? chapters[overlapStart].number
            : 0;
        final stepEndCh = endIdx > 0 ? chapters[endIdx - 1].number : 0;
        final estTokens = ((sys.length + user.length) / 1.5).round();
        final tokenStr = estTokens > 1000
            ? '${(estTokens / 1000).round()}K'
            : '$estTokens';

        setState(() {
          _scanProgress = endIdx;
          _scanStatus =
              '第$currentStep/$totalSteps步（第${stepStartCh}-${stepEndCh}章 共$totalScanChapters章'
              '${overlapChapters > 0 ? '，新$newChapters章+重叠$overlapChapters章' : ''}'
              '，约$tokenStr tokens）...';
        });

        _addLog(
          '第$currentStep/$totalSteps步：第${stepStartCh}-${stepEndCh}章（共$totalScanChapters章，约$tokenStr tokens）'
          '${overlapChapters > 0 ? '（新$newChapters+重叠$overlapChapters）' : ''}',
        );

        // 提示词预览
        if (_previewPrompt) {
          final shouldContinue = await _showPromptPreview(sys, user);
          if (!shouldContinue) {
            _addLog('用户在预览后终止扫描');
            break;
          }
        }

        // 调用API（残缺输出自动重试一次：中转偶发截断/思考文本污染JSON，
        // 单步重发比重跑整场扫描便宜得多）
        final config = state.getApiConfig('scene');
        ApiResult result;
        try {
          result = await state.api.callApi(
            systemPrompt: sys,
            userPrompt: user,
            apiConfig: config,
          );
        } catch (e) {
          // 断连等网络异常：5秒重试一次，仍失败跳过该窗口（不再终止整场扫描）
          _addLog('⚠️ 网络异常：$e，5秒后重试本步...');
          await Future.delayed(const Duration(seconds: 5));
          try {
            result = await state.api.callApi(
              systemPrompt: sys,
              userPrompt: user,
              apiConfig: config,
            );
          } catch (e2) {
            _addLog('⛔ 重试仍失败（网络异常）。已暂停：稍后点"继续扫描"从本段续扫');
            break;
          }
        }
        // 内容政策拦截识别：Google对敏感章节直接拒答。
        // 不跳过（数据要完整）：暂停扫描，提示用户换DeepSeek/GLM等非Google模型，
        // 在⚙里改配置后点"继续扫描"从断点续扫同一段（scannedUpTo未推进）
        if (result.isSuccess &&
            result.content.contains('Prohibited Use policy')) {
          _addLog(
            '⛔ 第${chapters[overlapStart].number}-${chapters[endIdx - 1].number}章触发Google内容政策拦截（敏感内容）。已暂停：请到⚙API设置换成DeepSeek/GLM等模型，再点"继续扫描"从本段续扫',
          );
          break;
        }
        // 成功但解析不出弧线→等5秒重发一次
        // 末弧完整性防御：截断JSON栈修复后末条弧线字段畸形（range空/endChapter=0/
        // status空——正常输出必有），据此识别"解析通过但弧线不全"的静默丢弧线。
        // 不用字数判断：短窗口（重叠区几章）正常输出也可以只有几百字
        var parseFail = false;
        var badTail = false;
        if (result.isSuccess) {
          final arcs0 = _parseArcResponse(result.content);
          parseFail = arcs0 == null || arcs0.isEmpty;
          badTail = !parseFail && _hasMalformedTailArc(arcs0!);
          if (parseFail) {
            _addLog('⚠️ 返回${result.content.length}字但解析失败（疑似截断），5秒后重发本步...');
            // 重试前dump返回前500字（排查中转截断/思考污染的证据）
            final dumpHead = result.content.length > 500
                ? result.content.substring(0, 500)
                : result.content;
            _addLog('首步返回内容：$dumpHead');
          } else if (badTail) {
            _addLog('⚠️ 末条弧线字段畸形（${arcs0.length}条弧线，疑似截断），5秒后重发本步...');
          }
        }
        if (parseFail || badTail) {
          await Future.delayed(const Duration(seconds: 5));
          final retry = await state.api.callApi(
            systemPrompt: sys,
            userPrompt: user,
            apiConfig: config,
          );
          final rArcs = retry.isSuccess
              ? _parseArcResponse(retry.content)
              : null;
          final rOk = rArcs != null && rArcs.isNotEmpty;
          // 重试成功且末弧健康→采用；否则暂停（弧线数据完整优先，绝不带病推进）
          if (rOk && !_hasMalformedTailArc(rArcs!)) {
            result = retry;
          } else {
            final why = rOk ? '重试末条弧线仍畸形' : '重试仍解析失败';
            _addLog('⛔ $why。已暂停：请检查网络/换模型后点"继续扫描"从本段续扫（不会跳过任何章节）');
            break;
          }
        }

        if (result.isSuccess) {
          _addLog('API返回：${result.content.length}字');

          final newArcs = _parseArcResponse(result.content);
          if (newArcs != null && newArcs.isNotEmpty) {

            // 合并弧线：confirmedArcs + newArcs，编号从1递增
            final mergedArcs = <Arc>[];
            for (var i = 0; i < confirmedArcs.length; i++) {
              final a = confirmedArcs[i];
              mergedArcs.add(
                Arc(
                  number: i + 1,
                  title: a.title,
                  chapterRange: a.chapterRange,
                  startChapter: a.startChapter,
                  endChapter: a.endChapter,
                  status: a.status,
                  summary: a.summary,
                  coreChange: a.coreChange,
                  focusCharacter: a.focusCharacter,
                  closeType: a.closeType,
                  // v304修复：此处原为a.closeType（复制粘贴bug）——每次合并把锚点覆盖成
                  // '伪闭合'等类型串，AI给的boundary_text全部销毁→切分永远失配整章兜底
                  boundaryAnchor: a.boundaryAnchor,
                  boundaryOffset: a.boundaryOffset,
                ),
              );
            }
            for (final a in newArcs) {
              mergedArcs.add(
                Arc(
                  number: mergedArcs.length + 1,
                  title: a.title,
                  chapterRange: a.chapterRange,
                  startChapter: a.startChapter,
                  endChapter: a.endChapter,
                  status: a.status,
                  summary: a.summary,
                  coreChange: a.coreChange,
                  focusCharacter: a.focusCharacter,
                  closeType: a.closeType,
                  // v304修复：同上，newArcs侧锚点+偏移保留（偏移已在上方解析落库）
                  boundaryAnchor: a.boundaryAnchor,
                  boundaryOffset: a.boundaryOffset,
                ),
              );
            }

            _addLog('合并后共${mergedArcs.length}条弧线（新增${newArcs.length}条）');

            // v291/v297：闭合点缓冲确认——闭合点后没有足够后续内容佐证"变化落定"时
            // 暂降级为未闭合，留到下一步重判（重判时前沿已推进，有落定佐证）。
            // v297改字数制：章回字数差异巨大（金庸单章上万/短章书2千），
            // 按章数判定失真——改为闭合点之后的累计字数<5000字才降级。
            // 全书扫完不降级。
            if (endIdx < chapters.length) {
              // v334b：佐证需求降为500字（用户实测3000+太多，频繁暂缓确认拖慢推进；
              // 500字≈1-2句的后续发展足以佐证"变化落定"）
              const lookaheadChars = 500;
              var demoted = 0;
              for (var i = 0; i < mergedArcs.length; i++) {
                final a = mergedArcs[i];
                if (a.status != 'complete') continue;
                final end = a.endChapter > 0
                    ? a.endChapter
                    : parseChapterRange(a.chapterRange).end;
                if (end <= 0) continue;
                // 闭合点之后的后续内容字数（end+1章~前沿章的正文累计）
                var afterChars = 0;
                for (var ci = 0; ci < chapters.length; ci++) {
                  final ch = chapters[ci];
                  final num = ch.number > 0 ? ch.number : ci + 1;
                  if (num > end && num <= endIdx) {
                    afterChars += ch.content.length;
                  } else if (num == end && a.boundaryOffset > 0) {
                    // v306：闭合章内、闭合点之后的剩余也计入佐证——
                    // 伪闭合点常在章中，步进1时闭合章=前沿章，原逻辑只数
                    // 完整的后继章导致每步都"不足5000字"白跑一轮重判
                    final fullLen =
                        ch.title.length + 2 + ch.content.length;
                    final remain = fullLen - a.boundaryOffset;
                    if (remain > 0) afterChars += remain;
                  }
                }
                if (afterChars < lookaheadChars) {
                  mergedArcs[i] = Arc(
                    number: a.number,
                    title: a.title,
                    chapterRange: a.chapterRange,
                    startChapter: a.startChapter,
                    endChapter: a.endChapter,
                    status: 'incomplete',
                    summary: a.summary,
                    coreChange: a.coreChange,
                    focusCharacter: a.focusCharacter,
                    closeType: a.closeType,
                    boundaryAnchor: a.boundaryAnchor,
                    boundaryOffset: a.boundaryOffset,
                  );
                  demoted++;
                }
              }
              if (demoted > 0) {
                _addLog(
                  '⏳ $demoted条弧线闭合点后不足${lookaheadChars}字佐证，暂缓确认（等后续内容重判）',
                );
              }
            }

            // v291：边界复核步——大步进时闭合点易被近因效应吸到批末。
            // 对本步内新闭合的弧线，用闭合点±2章小窗口复核"最早落定章"，
            // 只允许往前修（最多2章），修正后同步下一条弧线起始章。每步最多复核3条控成本。
            if (endIdx > scannedUpTo && scannedUpTo < chapters.length) {
              final frontierNum = chapters[endIdx - 1].number;
              final stepStartNum = chapters[scannedUpTo].number;
              var refined = 0;
              for (var i = 0; i < mergedArcs.length && refined < 3; i++) {
                final a = mergedArcs[i];
                if (a.status != 'complete') continue;
                final end = a.endChapter > 0
                    ? a.endChapter
                    : parseChapterRange(a.chapterRange).end;
                final start = a.startChapter > 0
                    ? a.startChapter
                    : parseChapterRange(a.chapterRange).start;
                if (end < stepStartNum || end > frontierNum || end <= start) {
                  continue; // 非本步闭合/边界异常
                }
                final wStart = end - 2 > start ? end - 2 : start;
                final wEnd = end + 1 < frontierNum ? end + 1 : frontierNum;
                if (wEnd < wStart) continue;
                final buf = StringBuffer();
                for (final ch in chapters) {
                  if (ch.number >= wStart && ch.number <= wEnd) {
                    buf.write('\n\n=== 第${ch.number}章 ===\n\n${ch.content}');
                  }
                }
                _addLog(
                  '🔍 边界复核：弧线${a.number}闭合点第$end章（窗口第$wStart-${wEnd}章）',
                );
                try {
                  final rr = await state.api.callApi(
                    systemPrompt:
                        '你是网文编辑，负责校准弧线闭合点。弧线闭合的标志是主角的处境发生了确定的、不可逆的变化（变化落定，不是变化开始）。只输出纯JSON，不要markdown。',
                    userPrompt:
                        '弧线「${a.title}」从第$start章开始，初判在第$end章闭合（闭合依据：${a.coreChange}）。以下是第$wStart-${wEnd}章原文。\n\n请判断：该弧线的不可逆变化最早在哪一章已经落定？只能在第$wStart-${wEnd}章范围内选择，且不能晚于第$end章。如果初判正确，返回$end。\n\n输出格式：{"closed_at": 章号数字, "reason": "20字内依据"}\n$buf',
                    apiConfig: config,
                  );
                  if (!rr.isSuccess) {
                    _addLog('⚠️ 边界复核请求失败，跳过（弧线${a.number}）');
                    continue;
                  }
                  final rj = JsonRepair.parseResponse(rr.content);
                  final rNum = rj == null
                      ? null
                      : (rj['closed_at'] is int
                            ? rj['closed_at'] as int
                            : int.tryParse('${rj?['closed_at']}'));
                  if (rNum == null || rNum >= end || rNum < wStart) {
                    _addLog('复核维持第$end章');
                    continue;
                  }
                  final reason = '${rj?['reason'] ?? ''}';
                  _addLog('✂ 弧线${a.number}闭合点修正：第$end章→第$rNum章（$reason）');
                  // 修正该弧线end+范围，并同步下一条弧线起始章
                  final newRange =
                      '${a.startChapter > 0 ? a.startChapter : start}-$rNum';
                  mergedArcs[i] = Arc(
                    number: a.number,
                    title: a.title,
                    chapterRange: '第$newRange章',
                    startChapter: a.startChapter > 0
                        ? a.startChapter
                        : start,
                    endChapter: rNum,
                    status: a.status,
                    summary: a.summary,
                    coreChange: a.coreChange,
                    focusCharacter: a.focusCharacter,
                    closeType: a.closeType,
                    boundaryAnchor: a.boundaryAnchor,
                    boundaryOffset: a.boundaryOffset,
                  );
                  if (i + 1 < mergedArcs.length) {
                    final nxt = mergedArcs[i + 1];
                    final nStart = nxt.startChapter > 0
                        ? nxt.startChapter
                        : parseChapterRange(nxt.chapterRange).start;
                    if (nStart == end + 1) {
                      final nEnd = nxt.endChapter > 0
                          ? nxt.endChapter
                          : parseChapterRange(nxt.chapterRange).end;
                      mergedArcs[i + 1] = Arc(
                        number: nxt.number,
                        title: nxt.title,
                        chapterRange: '第${rNum + 1}-$nEnd章',
                        startChapter: rNum + 1,
                        endChapter: nEnd,
                        status: nxt.status,
                        summary: nxt.summary,
                        coreChange: nxt.coreChange,
                        focusCharacter: nxt.focusCharacter,
                        closeType: nxt.closeType,
                            boundaryAnchor: nxt.boundaryAnchor,
                            boundaryOffset: nxt.boundaryOffset,
                      );
                    }
                  }
                  refined++;
                } catch (e) {
                  _addLog('⚠️ 边界复核异常：$e，跳过');
                }
              }
            }

// v307：插叙拆分前置准备（chNumMap/补定位计数上移到约束循环之前）
            final chNumMap = <int, Chapter>{};
            for (var ci = 0; ci < chapters.length; ci++) {
              final ch = chapters[ci];
              chNumMap[ch.number > 0 ? ch.number : ci + 1] = ch;
            }
            // v309：陈旧重复弧线清除——模型每步重发历史弧线，完全落在已闭合
            // 弧线内部（curEnd<prevEnd）的是陈旧副本，保留=同一章被两条弧线重复
            // 处理（违反无重叠）。反复清除到稳定。
            var removedDup = 0;
            var cleaned = true;
            int cStart(Arc x) => x.startChapter > 0
                ? x.startChapter
                : parseChapterRange(x.chapterRange).start;
            int cEnd(Arc x) => x.endChapter > 0
                ? x.endChapter
                : parseChapterRange(x.chapterRange).end;
            while (cleaned) {
              cleaned = false;
              for (var i = 1; i < mergedArcs.length; i++) {
                final cur = mergedArcs[i];
                final cS = cStart(cur), cE = cEnd(cur);
                for (var j = 0; j < i; j++) {
                  final p = mergedArcs[j];
                  if (p.status != 'complete') continue;
                  final pS = cStart(p), pE = cEnd(p);
                  if (cE < pE && cS >= pS) {
                    _addLog(
                      '🗑 弧线${cur.number}($cS-$cE)是已闭合弧线${p.number}($pS-$pE)的陈旧副本，移除',
                    );
                    mergedArcs.removeAt(i);
                    removedDup++;
                    cleaned = true;
                    break;
                  }
                }
                if (cleaned) break;
              }
            }
            if (removedDup > 0) _addLog('🗑 清除陈旧重复弧线 $removedDup 条');
            // v307：插叙违规自动拆分——新弧线插入未闭合弧线内部（模型违规输出）时，
            // 强制"弧线连续不交叉"：未闭合弧线在插入点伪闭合（补定位锚点），
            // 生成『·续』弧线接在插入段之后。结构：prevA(pS..b锚点) + cur + prevB(cE+1..pE)
            Future<void> splitInsertedArc(int idx) async {
              final prevA = mergedArcs[idx - 1];
              final curA = mergedArcs[idx];
              int stOf(Arc x) => x.startChapter > 0
                  ? x.startChapter
                  : parseChapterRange(x.chapterRange).start;
              int enOf(Arc x) => x.endChapter > 0
                  ? x.endChapter
                  : parseChapterRange(x.chapterRange).end;
              final pS = stOf(prevA), pE = enOf(prevA);
              final cS = stOf(curA), cE = enOf(curA);
              final b = cS > pS ? cS : pS;
              if (b < pS || b > pE) return;
              _addLog(
                '⚠ 弧线${curA.number}($cS-$cE)插入未闭合的弧线${prevA.number}($pS-$pE)，自动伪闭合拆分',
              );
              // v429：纯章级——插入点伪闭合不再发锚点请求，第$b章整章共享
              mergedArcs[idx - 1] = Arc(
                number: prevA.number,
                title: prevA.title,
                chapterRange: '第$pS-$b章',
                startChapter: pS,
                endChapter: b,
                status: 'complete',
                summary: prevA.summary,
                coreChange: prevA.coreChange,
                focusCharacter: prevA.focusCharacter,
                closeType: 'pseudo',
                boundaryAnchor: '',
                boundaryOffset: -1,
              );
              final nbS = cE + 1;
              if (nbS <= pE) {
                var maxNum = 0;
                for (final x in mergedArcs) {
                  if (x.number > maxNum) maxNum = x.number;
                }
                mergedArcs.insert(idx + 1, Arc(
                  number: maxNum + 1,
                  title: '${prevA.title}·续',
                  chapterRange: '第$nbS-$pE章',
                  startChapter: nbS,
                  endChapter: pE,
                  status: 'incomplete',
                  summary: prevA.summary,
                  coreChange: prevA.coreChange,
                  focusCharacter: prevA.focusCharacter,
                  closeType: prevA.closeType,
                  boundaryAnchor: '',
                  boundaryOffset: -1,
                ));
                _addLog(
                  '➕ 生成续弧线「${prevA.title}·续」（第$nbS-$pE章），接在插入段之后',
                );
              }
            }

            // v292/v294：完备划分约束——AI输出与"无重叠+无丢失"的偏差硬性修正：
            // ①重叠：起始章<上条闭合章+1 → 钳到prevEnd+1
            // ②空洞：起始章>上条闭合章+1 → 上条弧线end扩到curStart-1（跳章不丢内容）
            // 修正后由下方物化步骤按最终范围重算arc.text
            for (var i = 1; i < mergedArcs.length; i++) {
              final prev = mergedArcs[i - 1];
              final cur = mergedArcs[i];
              final prevEnd = prev.endChapter > 0
                  ? prev.endChapter
                  : parseChapterRange(prev.chapterRange).end;
              final curStart = cur.startChapter > 0
                  ? cur.startChapter
                  : parseChapterRange(cur.chapterRange).start;
              final curEnd = cur.endChapter > 0
                  ? cur.endChapter
                  : parseChapterRange(cur.chapterRange).end;
              if (curEnd <= prevEnd) {
                // v307：完全包含——上条未闭合=插叙违规自动拆分
                final prevStart = prev.startChapter > 0
                    ? prev.startChapter
                    : parseChapterRange(prev.chapterRange).start;
                if (prev.status == 'incomplete' && curStart >= prevStart) {
                  await splitInsertedArc(i);
                } else if (curEnd < prevEnd) {
                  // v309：真包含（curEnd<prevEnd）是陈旧副本，前置清扫已移除，
                  // 这里只剩兜底告警
                  _addLog(
                    '⚠ 弧线${cur.number}($curStart-$curEnd)完全包含于弧线${prev.number}($prevStart-$prevEnd)，原样保留（疑似重复输出）',
                  );
                }
                // v309：curEnd==prevEnd=合法共享边界章形态（锚点由物化段补定位），不打扰
                continue;
              }
              // v298：允许相邻弧线共享一个边界章（章内伪闭合）——文本级由锚点切分不重叠；
              // 多章重叠（curStart<prevEnd）仍钳制
              if (curStart < prevEnd) {
                if (prev.status == 'incomplete') {
                  // v307：部分重叠且上条未闭合 → 插叙拆分（不钳制，保留cur完整范围）
                  await splitInsertedArc(i);
                  continue;
                }
                // ①多章重叠钳制（上条已闭合）
                mergedArcs[i] = Arc(
                  number: cur.number,
                  title: cur.title,
                  chapterRange: '第${prevEnd}-$curEnd章',
                  startChapter: prevEnd,
                  endChapter: curEnd,
                  status: cur.status,
                  summary: cur.summary,
                  coreChange: cur.coreChange,
                  focusCharacter: cur.focusCharacter,
                  closeType: cur.closeType,
                  boundaryAnchor: cur.boundaryAnchor,
                  boundaryOffset: cur.boundaryOffset,
                );
              } else if (curStart > prevEnd + 1) {
                // ②空洞填充：跳过的章并入上一条弧线（不丢内容）
                final prevStart = prev.startChapter > 0
                    ? prev.startChapter
                    : parseChapterRange(prev.chapterRange).start;
                mergedArcs[i - 1] = Arc(
                  number: prev.number,
                  title: prev.title,
                  chapterRange: '第$prevStart-${curStart - 1}章',
                  startChapter: prevStart,
                  endChapter: curStart - 1,
                  status: prev.status,
                  summary: prev.summary,
                  coreChange: prev.coreChange,
                  focusCharacter: prev.focusCharacter,
                  closeType: prev.closeType,
                  boundaryAnchor: prev.boundaryAnchor,
                  boundaryOffset: prev.boundaryOffset,
                );
              }
            }

            // v429：纯章级物化——弧线text=章级原样（共享章两侧整章共有），
            // 句级精度退役到场景层（场景划分后tailTrim反向修剪）。扫描层
            // 不再产boundary锚点，v301-v425的定位/补定位/自救/钳制链全退役
            for (var i = 0; i < mergedArcs.length; i++) {
              mergedArcs[i].text = ArcText.build(
                chapters,
                mergedArcs,
                i,
                debugNotes: null,
              );

            }



            // v283：找"最早起始的未闭合弧线"（群像书可能多条并行）
            lastIncArc = null;
            for (final a in mergedArcs) {
              if (a.status != 'incomplete') continue;
              final s = a.startChapter > 0
                  ? a.startChapter
                  : parseChapterRange(a.chapterRange).start;
              if (lastIncArc == null ||
                  s <
                      (lastIncArc!.startChapter > 0
                          ? lastIncArc!.startChapter
                          : parseChapterRange(lastIncArc!.chapterRange)
                              .start)) {
                lastIncArc = a;
              }
            }

            // 更新confirmedArcs
            if (lastIncArc != null) {
              final newCutIdx = mergedArcs.indexOf(lastIncArc);
              confirmedArcs = mergedArcs.sublist(0, newCutIdx);
            } else {
              confirmedArcs = mergedArcs.sublist(0);
            }

            // 保存进度
            state.arcScan = ArcScan(
              arcs: mergedArcs,
              scannedChapterCount: endIdx,
            );
            state.saveArcScan();
            state.refresh();
          } else {
            _addLog('警告：JSON解析失败或无弧线返回，终止扫描');
            break;
          }
        } else {
          if (result.error == '用户中断') {
            _addLog('已终止（已完成$currentStep/$totalSteps步）');
          } else {
            // v427：网络错误不再自动重试（用户裁决：拥堵时不磨蹭）
            // ——直接告警暂停（scannedUpTo未推进，点继续扫描从本段续扫）
            _addLog('⛔ 请求失败：${result.error}——已暂停，稍后点"继续扫描"从本段续扫');
            break;
          }
        }

        scannedUpTo = endIdx;
      }

      if (_scanAborted) {
        _addLog('已终止扫描，已保存结果');
      } else {
        _addLog('=== 扫描完成 ===');
      }
      state.saveArcScan();
    } catch (e) {
      _addLog('异常：$e');
    }

    if (mounted) {
      setState(() {
        _isScanning = false;
        _scanStatus = '';
      });
    }
  }

  void _stopScan() {
    setState(() {
      _scanAborted = true;
      _scanStatus = '正在终止...';
    });
    _addLog('用户终止扫描');
    // 中断当前API请求 + 广播终止标志（分组/零件提取分步循环每轮检查）
    final state = context.read<AppState>();
    state.userAborted = true; // v485：分步循环靠这个停
    state.api.abort();
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
