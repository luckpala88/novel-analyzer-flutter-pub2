import 'dart:convert';

import 'package:flutter/material.dart';
import '../widgets/v_scroll_bar.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';
import '../models/scene.dart';
import '../utils/prompt_builder.dart';
import '../utils/json_repair.dart';
import '../utils/chinese_number.dart';
import '../utils/prompt_preview.dart';
import '../utils/text_cleaner.dart';
import '../utils/arc_text.dart';
import '../utils/v469_style.dart';

import '../widgets/api_log_panel.dart';
import '../widgets/api_config_panel.dart';
import '../widgets/slice_viewer_sheet.dart';
import '../widgets/v119_ui.dart';
import '../widgets/content_font.dart';

class AnalysisPage extends StatefulWidget {
  const AnalysisPage({super.key});

  @override
  State<AnalysisPage> createState() => _AnalysisPageState();
}

class _AnalysisPageState extends State<AnalysisPage>
    with AutomaticKeepAliveClientMixin {
  final ScrollController _listCtl = ScrollController(); // v656：列表垂直滚动条
  @override
  bool get wantKeepAlive => true; // 页面滑出PageView时保持State：生成任务不中断/表单不清空

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

  bool _isAnalyzing = false;
  String _statusText = '';
  final List<String> _logs = [];
  int? _selectedArcIdx;
  bool _previewPrompt = false;
  // 展开的场景分镜 key: "arcKey_sceneIdx"（持久化到ui_state，重启恢复）
  Set<String> _expandedShots = {};
  bool _restoredUi = false;

  @override
  // v288：生成内容字号（本页独立，0.8~1.6）
  double _fontScale = 1.0;

  void initState() {
    super.initState();
    _restoreUiState();    ContentFont.load('shot').then((v) {
      if (mounted) setState(() => _fontScale = v);
    });

  }

  /// 恢复展开态（per-book ui_state.json）
  void _restoreUiState() {
    try {
      final saved = AppState.instance.uiGet('analysis', 'expandedShots');
      if (saved is List) {
        _expandedShots = saved.map((e) => e.toString()).toSet();
      }
      _restoredUi = true;
    } catch (_) {
      _restoredUi = true;
    }
  }

  void _saveUiState() {
    if (!_restoredUi) return;
    AppState.instance.uiSet(
      'analysis',
      'expandedShots',
      _expandedShots.toList(),
    );
  }

  void _addLog(String msg) {
    setState(() {
      _logs.add(msg);
      if (_logs.length > 100) _logs.removeAt(0);
    });
    AppState.instance.apiLog(msg); // 页面日志同步全局终端（信息出口合一）
  }

  /// 统计行：N弧线 · M场景 · K分镜
  String _buildStatsText(AppState state) {
    var arcCount = 0, sceneCount = 0, shotCount = 0;
    state.arcAnalyses.forEach((_, a) {
      if (a.scenes.isEmpty) return;
      arcCount++;
      for (final s in a.scenes) {
        sceneCount++;
        shotCount += s.shots.length;
      }
    });
    return '$arcCount弧线 · $sceneCount场景 · $shotCount分镜';
  }

  @override
  Widget build(BuildContext context) {
    super.build(context); // AutomaticKeepAlive必须
    final state = context.watch<AppState>();
    // v525b：列表含未闭合弧线（拆解一视同仁——completedArcs漏掉incomplete=统计7拆6）
    final arcs = state.allArcs;

    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            // 顶行：拆解+芯片+导出+⚙（v235两行Wrap紧凑排列不超宽）
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 2),
              child: Wrap(
                spacing: 5,
                runSpacing: 4,
                children: [
                  // 拆解菜单（v290：一步拆解已删——必须先划分场景才能拆分镜，
                  // 只保留两步；弧线页仍保留扫描+一步拆解）
                  PopupMenuButton<String>(
                    enabled: !_isAnalyzing && state.completedArcs.isNotEmpty,
                    position: PopupMenuPosition.under,
                    onSelected: (v) {
                      if (v == 'increment') _batchAnalyzeShots(state, false);
                      if (v == 'full') _confirmFullReshot(state);
                    },
                    itemBuilder: (c) => [
                      const PopupMenuItem(
                        value: 'increment',
                        height: 40,
                        child: Text(
                          '增量拆分镜（已划分的未拆场景）',
                          style: TextStyle(fontSize: 13),
                        ),
                      ),
                      const PopupMenuItem(
                        value: 'full',
                        height: 40,
                        child: Text(
                          '全部重拆分镜（覆盖已有分镜）…',
                          style: TextStyle(fontSize: 13),
                        ),
                      ),
                    ],
                    child: const MiniButton(label: '拆解 ▾'),
                  ),
                  const SizedBox(width: 5),
                  // v377：统一词链开关（MiniButton背景色=开，与创作页一致）
                  MiniButton(
                    label: '词链',
                    primary: state.shotPromptPreview,
                    onTap: () => state.setShotPromptPreview(
                      !state.shotPromptPreview,
                    ),
                  ),

                  if (state.arcAnalyses.isNotEmpty) ...[
                    MiniButton(
                      label: '导出原书酒馆世界书',
                      onTap: () => _exportOriginalST(state),
                    ),
                    const SizedBox(width: 5),
                    MiniButton(
                      label: '导出JSON',
                      onTap: () => _export(state, 'json'),
                    ),
                    const SizedBox(width: 5),
                    MiniButton(
                      label: '导出MD',
                      onTap: () => _export(state, 'md'),
                    ),
                  ],
                                    // v288：生成内容字号（本页独立）
                  ContentFontButtons(
                    pageKey: 'shot',
                    scale: _fontScale,
                    onChanged: (v) {
                      setState(() => _fontScale = v);
                      ContentFont.save('shot', v);
                    },
                  ),
                  const SizedBox(width: 5),
const SizedBox(width: 8),
                  MiniButton(
                    label: '⚙ API',
                    onTap: () => showV119Sheet(
                      context,
                      title: 'API设置 · 分镜拆解',
                      child: ApiConfigPanel(
                        config: state.analysisApi,
                        section: 'analysis',
                      ),
                    ),
                  ),
                ],
              ),
            ),
            // 紧凑统计行：N弧线·M场景·K分镜（两步拆解的结果）
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
              child: Row(
                children: [
                  Text(
                    _buildStatsText(state),
                    style: TextStyle(fontSize: 11, color: Colors.grey[600]),
                  ),
                  const SizedBox(width: 8), // Wrap内Spacer失效，用定宽占位
                  Text(
                    '拆分镜在本页 · 划分场景在场景页',
                    style: TextStyle(fontSize: 10, color: Colors.grey[400]),
                  ),
                ],
              ),
            ),
            // 进度条（细条，状态文字在终端里）
            if (_isAnalyzing)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 12),
                child: LinearProgressIndicator(minHeight: 2),
              ),
            Expanded(
              child: ContentFont.area(context, scale: _fontScale, child: arcs.isEmpty
                  ? _buildEmpty(context)
                  : SelectionArea(
                    child: Stack(
                      children: [
                        ListView.builder(
                        controller: _listCtl,
                        itemCount: arcs.length,
                        itemBuilder: (ctx, i) =>
                            _buildArcCard(context, state, arcs[i], i),
                        ),
                        Positioned(
                          right: 0, top: 0, bottom: 0,
                          child: VScrollBar(_listCtl),
                        ),
                      ],
                    ),
                  ),
            )),
            // 统一终端（日志+终止）— v468 api-step-log
          ],
        ),
      ),
    );
  }

  Widget _buildEmpty(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.list_alt, size: 64, color: Colors.grey[400]),
          const SizedBox(height: 16),
          Text('暂无拆解结果', style: TextStyle(color: Colors.grey[600])),
          const SizedBox(height: 8),
          Text(
            '去弧线页一步拆解，或去场景页先划分场景再来拆分镜',
            style: TextStyle(color: Colors.grey[500], fontSize: 13),
          ),
        ],
      ),
    );
  }

  Widget _buildArcCard(
    BuildContext context,
    AppState state,
    dynamic arc,
    int idx,
  ) {
    final arcKey = arc.number.toString();
    final analysis = state.arcAnalyses[arcKey];
    final scenes = state.arcScenes[arcKey] ?? [];
    final hasAnalysis = analysis != null;
    final analyzedScenes = hasAnalysis
        ? analysis.scenes.where((s) => s.shots.isNotEmpty).length
        : 0;
    final totalScenes = scenes.isNotEmpty
        ? scenes.length
        : (hasAnalysis ? analysis.scenes.length : 0);
    // v501：弧线总分镜数（拆解结果各场景shots求和）
    final totalShots = hasAnalysis
        ? analysis.scenes.fold<int>(0, (n, s) => n + s.shots.length)
        : 0;

    // v469：已拆解=complete绿左边条，未拆解=incomplete红左边条
    final cardColor = hasAnalysis ? V469Style.complete : V469Style.incomplete;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
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
        // 左边条3px（v469 .arc-card.complete/.incomplete）
        decoration: BoxDecoration(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          border: Border(left: BorderSide(color: cardColor, width: 3)),
        ),
        child: ExpansionTile(
          key: _tileKey('analysis_arc_${arc.number}'),
          onExpansionChanged: (v) {
            if (v) _scrollTileToTop('analysis_arc_${arc.number}');
          },
          tilePadding: const EdgeInsets.symmetric(horizontal: 12),
          leading: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
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
            arc.title ?? '',
            style: const TextStyle(
              fontSize: 13.5,
              fontWeight: FontWeight.w600,
              color: V469Style.textMain,
            ),
          ),
          subtitle: Padding(
            padding: const EdgeInsets.only(top: 3),
            // v498：分行布局（同弧线页——单Row把章范围挤成瘦长条）
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    // v500c：场景编号直接取弧线分组数据（analysis.arc只在一页拆解路径有值，场景页路径为空）
                    Text(
                      (arc.sceneFrom ?? -1) >= 0
                          ? '场景${arc.sceneFrom}-${arc.sceneTo} · ${arc.chapterRange ?? ''}'
                          : (arc.chapterRange ?? ''),
                      style: const TextStyle(
                        fontSize: 11,
                        color: V469Style.textMuted,
                        fontWeight: FontWeight.w400,
                      ),
                    ),
                    if (hasAnalysis)
                      V469Style.badge(
                        '✅ 已拆解($analyzedScenes/$totalScenes)',
                        V469Style.complete,
                        V469Style.completeBg,
                      ),
                  ],
                ),
                const SizedBox(height: 4),
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    // v501：总分镜数徽章（对齐弧线页统计风格）
                    if (totalShots > 0)
                      V469Style.badge(
                        '分镜$totalShots镜',
                        const Color(0xFF7C3AED),
                        const Color(0x147C3AED),
                      ),
                    // v497：零件统计
                    if (hasAnalysis &&
                        (analysis!.metadata?['characters'] as List? ?? []).isNotEmpty)
                      V469Style.badge(
                        '人设${(analysis.metadata!["characters"] as List).length}'
                        '·冲突${(analysis.metadata?["conflicts"] as List? ?? []).length}'
                        '·伏笔${(analysis.metadata?["foreshadowing"] as List? ?? []).length}'
                        '·脑洞${(analysis.metadata?["author_fantasy"] as List? ?? []).length}',
                        V469Style.accent,
                        V469Style.accentBg,
                      )
                    else if (totalScenes > 0)
                      V469Style.badge(
                        '已划分${totalScenes}场景',
                        V469Style.accent,
                        V469Style.accentBg,
                      )
                    else
                      V469Style.badge(
                        '未划分',
                        V469Style.textMuted,
                        V469Style.surfaceAlt,
                      ),
                    // v500c：视角主角直接取弧线分组数据（同上，场景页路径analysis.arc为空）
                    if (((arc.focusCharacter as String?) ?? '').isNotEmpty)
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
            // v234：拆分镜按钮（从场景页搬来——分镜页是拆解中心）
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              child: Row(
                children: [
                  FilledButton.tonalIcon(
                    icon: const Icon(Icons.analytics, size: 16),
                    style: FilledButton.styleFrom(
                      backgroundColor: Colors.green.shade600,
                      foregroundColor: Colors.white,
                      visualDensity: VisualDensity.compact,
                      textStyle: const TextStyle(fontSize: 12),
                    ),
                    label: Text(
                      hasAnalysis
                          ? '重拆分镜（智能分发）'
                          : (scenes.isNotEmpty ? '拆分镜（该弧线场景）' : '未划分场景'),
                    ),
                    onPressed: _isAnalyzing || scenes.isEmpty
                        ? null
                        : () => _analyzeSingleArc(state, idx),
                  ),
                ],
              ),
            ),
            // v488：弧线概述两次生成各归其位——分镜页优先展示零件提取详细版
            // （detailed），无则退回分组/场景划分概述（analysis.arcSummary）
            // ❌旧逻辑（v469，直读arcSummary与弧线页同一字段=两页概述一模一样，已废弃）：
            // if (hasAnalysis && analysis.arcSummary.isNotEmpty)
            if (hasAnalysis &&
                (analysis.metadata?['arc_summary_detailed']?.toString() ?? analysis.arcSummary).isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                child: ReadableWidth(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Text(
                          analysis.metadata?['arc_summary_detailed']?.toString() ?? analysis.arcSummary,
                          style: const TextStyle(
                            fontSize: 13,
                            height: 1.6,
                            color: V469Style.textSec,
                          ),
                        ),
                      ),
                      GestureDetector(
                        onTap: () {
                          Clipboard.setData(
                            ClipboardData(text: analysis.metadata?['arc_summary_detailed']?.toString() ?? analysis.arcSummary),
                          );
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: V469Style.accent,
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: const Text(
                            '复制',
                            style: TextStyle(
                              fontSize: 10,
                              color: Colors.white,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            if (hasAnalysis && analysis.scenes.isNotEmpty)
              ...analysis.scenes.asMap().entries.map((entry) {
                final si = entry.key;
                final scene = entry.value;
                return _buildSceneCard(
                  context,
                  state,
                  arcKey,
                  si,
                  scene,
                  scenes.isNotEmpty ? scenes[si] : null,
                );
              })
            else if (scenes.isNotEmpty)
              ...scenes.asMap().entries.map((entry) {
                final si = entry.key;
                final scene = entry.value;
                return _buildSceneCard(context, state, arcKey, si, null, scene);
              })
            else
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  '去弧线页一步拆解，或去场景页先划分场景再来拆分镜',
                  style: TextStyle(fontSize: 13, color: Colors.grey),
                ),
              ),
            // v469：弧线零件（人设/冲突/伏笔/弧线功能/不可逆变化/情绪曲线/脑洞）
            // v480：ExpansionTile children默认crossAxis=center——包全宽Column改左对齐
            SizedBox(
              width: double.infinity,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ..._buildArcParts(analysis),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ===== v469 renderArc弧线零件渲染（顺序同v469：场景→人设→冲突→伏笔→弧线功能→不可逆变化→情绪曲线→脑洞）=====

  String _asStr(dynamic v) => v == null ? '' : v.toString();

  List<dynamic> _asList(dynamic v) => v is List ? v : const [];

  Map<String, dynamic>? _asMap(dynamic v) =>
      v is Map<String, dynamic> ? v : null;

  Widget _metaTitle(String label) {
    return Padding(
      padding: const EdgeInsets.only(top: 12, bottom: 6),
      child: Text(
        label,
        style: const TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: V469Style.accent,
          letterSpacing: 0.3,
        ),
      ),
    );
  }

  /// 列表项（v469 .arc-meta-list li：▸前缀+textSec）
  Widget _metaItem(List<InlineSpan> spans) {
    return Padding(
      padding: const EdgeInsets.only(left: 14, top: 3, bottom: 3),
      child: Text.rich(
        TextSpan(
          children: [
            const TextSpan(
              text: '▸ ',
              style: TextStyle(fontSize: 12.5, color: V469Style.accentLight),
            ),
            ...spans,
          ],
        ),
      ),
    );
  }

  List<Widget> _buildArcParts(ArcAnalysis? analysis) {
    if (analysis == null || analysis.metadata == null) return const [];
    final md = analysis.metadata!;
    final widgets = <Widget>[];

    // v224：笔墨癖好（作者注意力画像——十件套成员，分镜页此前漏渲染）
    final hobby = md['ink_hobby'];
    if (hobby is Map && hobby.isNotEmpty) {
      widgets.add(_metaTitle('🖌 笔墨癖好'));
      hobby.forEach((k, v) {
        if (v != null && v.toString().isNotEmpty) {
          widgets.add(
            _metaItem([
              TextSpan(
                text: '$k：',
                style: const TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: V469Style.textMain,
                ),
              ),
              TextSpan(
                text: v.toString(),
                style: const TextStyle(
                  fontSize: 12.5,
                  color: V469Style.textSec,
                ),
              ),
            ]),
          );
        }
      });
    }

    // 3.5 世界观设定facts（原著分析结果，推演改编的参照依据）
    final wbFacts = md['worldbuilding_facts'];
    if (wbFacts is List && wbFacts.isNotEmpty) {
      widgets.add(_metaTitle('🌐 世界观设定'));
      for (final f in wbFacts) {
        if (f is! Map) continue;
        final sys = _asStr(f['system']);
        final rule = _asStr(f['rule']);
        final func = _asStr(f['function']);
        if (rule.isEmpty) continue;
        widgets.add(
          _metaItem([
            TextSpan(
              text: '[$sys] ',
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: Color(0xFF8B5CF6),
              ),
            ),
            TextSpan(
              text: rule,
              style: const TextStyle(
                fontSize: 12.5,
                color: V469Style.textSec,
                height: 1.5,
              ),
            ),
            if (func.isNotEmpty)
              TextSpan(
                text: '\n  功能：$func',
                style: const TextStyle(
                  fontSize: 11,
                  color: V469Style.textMuted,
                  height: 1.4,
                ),
              ),
          ]),
        );
      }
    }

    // 4. 人设（Wrap横向排列：name+role徽章+identity+traits）
    final characters = _asList(md['characters']);
    if (characters.isNotEmpty) {
      widgets.add(_metaTitle('👤 人设'));
      final charCards = <Widget>[];
      for (final c in characters) {
        final m = _asMap(c);
        final name = m != null ? _asStr(m['name']) : _asStr(c);
        final role = m != null ? _asStr(m['role']) : '';
        final identity = m != null ? _asStr(m['identity']) : '';
        final traits = m != null ? _asStr(m['traits']) : '';
        charCards.add(
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 400),
            child: Container(
              margin: const EdgeInsets.only(bottom: 6, right: 6),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
              decoration: BoxDecoration(
                color: V469Style.surfaceAlt,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text: name,
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: V469Style.textMain,
                          ),
                        ),
                        if (role.isNotEmpty) ...[
                          const WidgetSpan(child: SizedBox(width: 6)),
                          WidgetSpan(
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 7,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: V469Style.accentBg,
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                role,
                                style: const TextStyle(
                                  fontSize: 11,
                                  color: V469Style.accent,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (identity.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 3),
                      child: Text(
                        identity,
                        style: const TextStyle(
                          fontSize: 12,
                          color: V469Style.textSec,
                        ),
                      ),
                    ),
                  if (traits.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        traits,
                        style: const TextStyle(
                          fontSize: 11.5,
                          color: V469Style.textMuted,
                          fontStyle: FontStyle.italic,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      }
      widgets.add(Wrap(spacing: 4, runSpacing: 4, children: charCards));
    }

    // 5. 矛盾冲突（conflict-type红徽章+描述）
    final conflicts = _asList(md['conflicts']);
    if (conflicts.isNotEmpty) {
      widgets.add(_metaTitle('⚔️ 矛盾冲突'));
      for (final c in conflicts) {
        final m = _asMap(c);
        final type = m != null ? _asStr(m['type']) : '';
        final desc = m != null ? _asStr(m['description']) : _asStr(c);
        widgets.add(
          _metaItem([
            if (type.isNotEmpty) ...[
              WidgetSpan(
                child: Container(
                  margin: const EdgeInsets.only(right: 4),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 1,
                  ),
                  decoration: BoxDecoration(
                    color: V469Style.incompleteBg,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    type,
                    style: const TextStyle(
                      fontSize: 11,
                      color: V469Style.incomplete,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ),
            ],
            TextSpan(
              text: desc,
              style: const TextStyle(
                fontSize: 12.5,
                color: V469Style.textSec,
                height: 1.5,
              ),
            ),
          ]),
        );
      }
    }

    // 6. 伏笔（**内容**（第X章种下）→ 回收绿/待回收红）
    final foreshadowing = _asList(md['foreshadowing']);
    if (foreshadowing.isNotEmpty) {
      widgets.add(_metaTitle('🌱 伏笔'));
      for (final f in foreshadowing) {
        final m = _asMap(f);
        final content = m != null ? _asStr(m['content']) : _asStr(f);
        final plantedAt = m != null ? _asStr(m['planted_at']) : '';
        final payoffRaw = m != null ? _asStr(m['payoff']) : '';
        final payoff = payoffRaw.isEmpty ? '待回收' : payoffRaw;
        final done = payoff != '待回收';
        widgets.add(
          _metaItem([
            TextSpan(
              text: content,
              style: const TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w700,
                color: V469Style.textMain,
              ),
            ),
            if (plantedAt.isNotEmpty)
              TextSpan(
                text: ' ($plantedAt种下)',
                style: const TextStyle(
                  fontSize: 11,
                  color: V469Style.textMuted,
                ),
              ),
            TextSpan(
              text: ' → ',
              style: const TextStyle(fontSize: 12.5, color: V469Style.textSec),
            ),
            TextSpan(
              text: payoff,
              style: TextStyle(
                fontSize: 12.5,
                color: done ? V469Style.complete : V469Style.incomplete,
                fontWeight: FontWeight.w500,
              ),
            ),
          ]),
        );
      }
    }

    // 7. 弧线功能
    final functions = _asList(md['arc_functions']);
    if (functions.isNotEmpty) {
      widgets.add(_metaTitle('🧩 弧线功能'));
      for (final f in functions) {
        widgets.add(
          _metaItem([
            TextSpan(
              text: _asStr(f),
              style: const TextStyle(
                fontSize: 12.5,
                color: V469Style.textSec,
                height: 1.5,
              ),
            ),
          ]),
        );
      }
    }

    // 8. 不可逆变化
    final irreversible = _asStr(md['irreversible_changes']);
    if (irreversible.isNotEmpty) {
      widgets.add(_metaTitle('💎 不可逆变化'));
      widgets.add(
        Padding(
          padding: const EdgeInsets.only(right: 12),
          child: Text(
            irreversible,
            style: const TextStyle(
              fontSize: 12.5,
              height: 1.6,
              color: V469Style.textSec,
            ),
          ),
        ),
      );
    }

    // 9. 情绪曲线（serif斜体accent）
    final emotional = _asStr(md['emotional_curve']);
    if (emotional.isNotEmpty) {
      widgets.add(_metaTitle('📈 情绪曲线'));
      widgets.add(
        Padding(
          padding: const EdgeInsets.only(right: 12),
          child: Text(
            emotional,
            style: const TextStyle(
              fontSize: 12.5,
              height: 1.6,
              color: V469Style.accent,
              fontStyle: FontStyle.italic,
            ),
          ),
        ),
      );
    }

    // 10. 作者脑洞
    final fantasy = _asList(md['author_fantasy']);
    if (fantasy.isNotEmpty) {
      widgets.add(_metaTitle('💡 作者脑洞'));
      for (final f in fantasy) {
        widgets.add(
          _metaItem([
            TextSpan(
              text: _asStr(f),
              style: const TextStyle(
                fontSize: 12.5,
                color: V469Style.textSec,
                height: 1.5,
              ),
            ),
          ]),
        );
      }
    }

    // 11. 结构模式（per-arc，一步拆解时从pattern_summary提取）
    final structural = _asList(md['structural_patterns']);
    if (structural.isNotEmpty) {
      widgets.add(_metaTitle('🏗️ 结构模式'));
      for (final p in structural) {
        widgets.add(
          _metaItem([
            TextSpan(
              text: _asStr(p),
              style: const TextStyle(
                fontSize: 12.5,
                color: V469Style.textSec,
                height: 1.5,
              ),
            ),
          ]),
        );
      }
    }

    return widgets;
  }

  Widget _buildSceneCard(
    BuildContext context,
    AppState state,
    String arcKey,
    int sceneIdx,
    Scene? analyzedScene,
    dynamic rawScene,
  ) {
    final sceneName =
        analyzedScene?.name ?? rawScene?.name ?? '场景${sceneIdx + 1}';
    final chapterRange =
        analyzedScene?.chapterRange ?? rawScene?.chapterRange ?? '';
    final shots = analyzedScene?.shots ?? [];
    // v508c：统一场景对象（切片按键取text用；rawScene同为Scene时兜底）
    final Scene? scene = analyzedScene ??
        (rawScene is Scene ? rawScene : null);
    final hasShots = shots.isNotEmpty;
    final foldKey = '${arcKey}_$sceneIdx';
    final isExpanded = _expandedShots.contains(foldKey);

    return Container(
      margin: const EdgeInsets.only(left: 16, right: 8, bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              // 场景N徽章（v469：金棕底白字圆角）
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 7,
                  vertical: 1.5,
                ),
                decoration: BoxDecoration(
                  color: V469Style.accent,
                  borderRadius: BorderRadius.circular(11),
                ),
                child: Text(
                  '场景${sceneIdx + 1}',
                  style: const TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                  ),
                ),
              ),
              const SizedBox(width: 7),
              Expanded(
                child: Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: sceneName,
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: V469Style.textMain,
                        ),
                      ),
                      if (chapterRange.isNotEmpty)
                        TextSpan(
                          text: ' ($chapterRange)',
                          style: const TextStyle(
                            fontSize: 11,
                            color: V469Style.textMuted,
                            fontWeight: FontWeight.w400,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              // v508c：场景切片浏览（场景text优先，旧数据回退全局场景流）
              SizedBox(
                height: 26,
                child: TextButton(
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    textStyle: const TextStyle(fontSize: 11),
                    visualDensity: VisualDensity.compact,
                  ),
                  onPressed: () {
                    String slice = scene?.text ?? '';
                    if (slice.isEmpty) {
                      for (final a in state.completedArcs) {
                        if (a.number.toString() == arcKey && a.sceneFrom >= 0) {
                          final gi = a.sceneFrom - 1 + sceneIdx;
                          if (gi >= 0 &&
                              gi < state.globalScenes.length &&
                              state.globalScenes[gi].text.isNotEmpty) {
                            slice = state.globalScenes[gi].text;
                          }
                          break;
                        }
                      }
                    }
                    if (slice.isEmpty) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('场景无锚定切片（旧划分数据）——请重新划分场景')),
                      );
                      return;
                    }
                    showSliceViewerSheet(
                      context,
                      title: '场景${sceneIdx + 1} $sceneName 切片（${slice.length}字）',
                      text: slice,
                    );
                  },
                  child: const Text('切片'),
                ),
              ),
              const SizedBox(width: 6),
              // 单场景拆分镜（v236：从场景页搬来的就地拆解，v234搬迁时漏掉）
              SizedBox(
                height: 26,
                child: FilledButton.tonal(
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    textStyle: const TextStyle(fontSize: 11),
                    visualDensity: VisualDensity.compact,
                  ),
                  onPressed: _isAnalyzing
                      ? null
                      : () => _analyzeSceneShots(state, arcKey, sceneIdx),
                  child: Text(hasShots ? '重拆' : '拆分镜'),
                ),
              ),
              const SizedBox(width: 6),
              if (hasShots)
                GestureDetector(
                  onTap: () {
                    setState(() {
                      if (isExpanded) {
                        _expandedShots.remove(foldKey);
                      } else {
                        _expandedShots.add(foldKey);
                      }
                    });
                    _saveUiState();
                  },
                  child: Text(
                    '${isExpanded ? '▼' : '▶'} ${shots.length}分镜',
                    style: const TextStyle(
                      fontSize: 11,
                      color: V469Style.accent,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                )
              else
                V469Style.badge(
                  '未拆分镜',
                  V469Style.textMuted,
                  V469Style.surfaceAlt,
                ),
            ],
          ),
          // 场景概述
          if (analyzedScene?.summary.isNotEmpty == true)
            Padding(
              padding: const EdgeInsets.only(top: 4, right: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Text(
                      analyzedScene!.summary,
                      style: const TextStyle(
                        fontSize: 11.5,
                        height: 1.5,
                        color: V469Style.textSec,
                      ),
                    ),
                  ),
                  GestureDetector(
                    onTap: () {
                      Clipboard.setData(
                        ClipboardData(text: analyzedScene!.summary),
                      );
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: V469Style.accent,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: const Text(
                        '复制',
                        style: TextStyle(
                          fontSize: 10,
                          color: Colors.white,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          if (hasShots && isExpanded)
            ...shots.asMap().entries.map((entry) {
              final shi = entry.key;
              final shot = entry.value;
              return _buildShotTile(
                context,
                state,
                arcKey,
                sceneIdx,
                shi + 1,
                shot,
                scene?.text ?? '',
              );
            }),
        ],
      ),
    );
  }

  /// 分镜卡（v469对齐：slate底+分镜N徽章+头行内联三维度+分行维度带图标标签）
  /// v508c：+切片按键（镜级切片优先，回退场景切片）+sceneText回退文本
  Widget _buildShotTile(
    BuildContext context,
    AppState state,
    String arcKey,
    int si,
    int idx,
    Shot shot,
    String sceneText,
  ) {
    Widget dimLine(String icon, String label, String value, Color color) {
      if (value.isEmpty) return const SizedBox.shrink();
      return Padding(
        padding: const EdgeInsets.only(top: 1.5),
        child: Text.rich(
          TextSpan(
            children: [
              TextSpan(
                text: '$icon ',
                style: TextStyle(fontSize: 11, color: color),
              ),
              TextSpan(
                text: '$label：',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: color,
                ),
              ),
              TextSpan(
                text: value,
                style: const TextStyle(fontSize: 11, color: Color(0xFF475569)),
              ),
            ],
          ),
        ),
      );
    }

    final typeColor = V469Style.shotTypeColor(shot.shotType);
    return Container(
      margin: const EdgeInsets.only(left: 16, top: 4),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: V469Style.shotBg,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: V469Style.shotBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 头行：分镜N徽章 + 内容
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                decoration: BoxDecoration(
                  color: V469Style.shotBadgeBg,
                  borderRadius: BorderRadius.circular(3),
                ),
                child: Text(
                  '分镜$idx',
                  style: const TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    color: V469Style.shotBadgeFg,
                  ),
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  shot.content.isNotEmpty ? shot.content : shot.focus,
                  style: const TextStyle(
                    fontSize: 11.5,
                    color: Color(0xFF0F172A),
                    height: 1.4,
                  ),
                ),
              ),
            ],
          ),
          // 全部分行维度：9维度一行一个，与世界书推演条目格式对齐
          dimLine('🎯', '焦点/Focus', shot.focus, const Color(0xFF1E40AF)),
          dimLine('🎬', '镜头类型/Shot Type', shot.shotType, typeColor),
          dimLine('👁', '视角/POV', shot.pov, const Color(0xFF3730A3)),
          dimLine('📋', '投放信息/Info', shot.info, const Color(0xFF475569)),
          dimLine('💡', '作者意图/Intent', shot.intent, const Color(0xFF92400E)),
          dimLine(
            '✂️',
            '转场手法/Transition',
            shot.transition,
            const Color(0xFF0F766E),
          ),
          dimLine(
            '📏',
            '篇幅/Length',
            _fmtLength(shot.length),
            const Color(0xFF7C3AED),
          ),
          dimLine(
            '✍',
            '文笔节奏/Prose Style',
            shot.proseStyle,
            const Color(0xFFDB2777),
          ),
          if (shot.voice.isNotEmpty)
            dimLine(
              '🎙',
              '语感/Voice',
              shot.voice,
              const Color(0xFFB45309),
            ),
          if (shot.style.isNotEmpty)
            dimLine(
              '📐',
              '文风/Style',
              shot.style,
              const Color(0xFF7C3AED),
            ),
          if (shot.ink.isNotEmpty)
            dimLine(
              '🖌',
              '笔墨/Ink',
              shot.ink,
              const Color(0xFF0369A1),
            ),
          dimLine(
            '🧩',
            '功能抽象/Abstract',
            shot.abstraction,
            const Color(0xFF0F766E),
          ),
          // v508c：切片查看（镜级锚定优先，回退场景切片——随时对照原文）
          Align(
            alignment: Alignment.centerLeft,
            child: SizedBox(
              height: 24,
              child: TextButton(
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  textStyle: const TextStyle(fontSize: 10),
                  visualDensity: VisualDensity.compact,
                ),
                onPressed: () {
                  if (shot.text.isNotEmpty) {
                    showSliceViewerSheet(
                      context,
                      title: '分镜$idx 切片（镜级锚定，${shot.text.length}字）',
                      text: shot.text,
                    );
                    return;
                  }
                  if (sceneText.isNotEmpty) {
                    showSliceViewerSheet(
                      context,
                      title:
                          '分镜$idx（无镜级锚点，回退场景切片${sceneText.length}字）',
                      text: sceneText,
                    );
                    return;
                  }
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('无切片（旧数据）——请重新划分场景')),
                  );
                },
                child: Text(
                  shot.text.isNotEmpty
                      ? '🔍切片（镜级${shot.text.length}字）'
                      : '🔍切片（回退场景）',
                  style: TextStyle(
                    fontSize: 10,
                    color: shot.text.isNotEmpty
                        ? const Color(0xFF0E7490)
                        : V469Style.textMuted,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 导出
  /// v217：导出原书酒馆世界书——分镜页分析数据直接本地转ST条目（零AI调用）。
  /// 条目格式与世界书页导出完全一致：每弧线1条（总结+场景+分镜+九件套）
  void _exportOriginalST(AppState state) {
    if (state.arcAnalyses.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('暂无拆解数据')));
      return;
    }
    final entries = <String, dynamic>{};
    var uid = 0;

    // 世界概览条目（对齐生成路径：弧线1时AI也会生成总览）
    final arcs = state.completedArcs;
    if (arcs.length > 1) {
      final overview = StringBuffer();
      overview.writeln('弧线列表：');
      for (final a in arcs) {
        overview.writeln(
          '弧线${a.number}：${a.title}（${a.chapterRange}）${a.summary.isNotEmpty ? '——${a.summary}' : ''}',
        );
      }
      entries[uid.toString()] = _stEntry(
        uid++,
        keys: ['世界概览'],
        comment: '世界概览',
        content: overview.toString(),
        constant: true,
        order: 200,
      );
    }

    // 每弧线1条（content结构=弧线概述+场景及分镜+九件套，与分析结果对齐）
    final keys = state.arcAnalyses.keys.toList()
      ..sort((a, b) => (int.tryParse(a) ?? 0).compareTo(int.tryParse(b) ?? 0));
    for (final k in keys) {
      final an = state.arcAnalyses[k];
      if (an == null) continue;
      final arc = state.allArcs.firstWhere(
        (a) => a.number == an.arcNumber,
        orElse: () => arcs.isNotEmpty ? arcs.first : arcs.first,
      );
      final sb = StringBuffer();
      sb.writeln(
        '弧线${an.arcNumber}概述：${an.arcSummary.isNotEmpty ? an.arcSummary : arc.summary}',
      );
      sb.writeln();
      for (final sc in an.scenes) {
        sb.writeln(
          '场景${an.scenes.indexOf(sc) + 1}：${sc.name}（${sc.chapterRange}）',
        );
        if (sc.summary.isNotEmpty) sb.writeln('概述：${sc.summary}');
        for (var i = 0; i < sc.shots.length; i++) {
          final sh = sc.shots[i];
          sb.writeln('分镜${i + 1}：');
          sb.writeln('焦点(Focus)：${sh.focus}');
          sb.writeln('镜头类型(Shot Type)：${sh.shotType}');
          sb.writeln('视角(POV)：${sh.pov}');
          sb.writeln('投放信息(Info)：${sh.info}');
          sb.writeln('作者意图(Intent)：${sh.intent}');
          sb.writeln('转场手法(Transition)：${sh.transition}');
          sb.writeln('篇幅(Length)：${sh.length}');
          sb.writeln('文笔节奏(Prose Style)：${sh.proseStyle}');
          if (sh.voice.isNotEmpty)
            sb.writeln('语感(Voice)：${sh.voice}');
          if (sh.style.isNotEmpty) sb.writeln('文风(Style)：${sh.style}');
          if (sh.ink.isNotEmpty) sb.writeln('笔墨(Ink)：${sh.ink}');
          if (sh.abstraction.isNotEmpty)
            sb.writeln('功能抽象(Abstract)：${sh.abstraction}');
        }
        sb.writeln();
      }
      final md = an.metadata ?? {};
      void writeBlock(String label, dynamic v) {
        if (v == null || v.toString().isEmpty || v.toString() == '[]') return;
        sb.writeln('【$label】');
        if (v is List) {
          for (final item in v) {
            if (item is Map) {
              sb.writeln(
                '- ${item.entries.map((e) => '${e.value}').join('，')}',
              );
            } else {
              sb.writeln('- $item');
            }
          }
        } else {
          sb.writeln(v.toString());
        }
      }

      // v217补漏：世界观设定（10体系facts）——生成路径的content里有【世界观设定】区
      final wbFacts = md['worldbuilding_facts'];
      if (wbFacts is List && wbFacts.isNotEmpty) {
        sb.writeln('【世界观设定】');
        for (final f in wbFacts) {
          if (f is! Map) continue;
          final rule = f['rule']?.toString() ?? '';
          final func = f['function']?.toString() ?? '';
          final sysName = f['system']?.toString() ?? '其他';
          sb.writeln(
            '- ${rule.isNotEmpty ? rule : f['text']?.toString() ?? ''}'
            '${func.isNotEmpty ? '（$sysName：$func）' : sysName.isNotEmpty ? '（$sysName）' : ''}',
          );
        }
        sb.writeln();
      }
      // v219：笔墨癖好
      final hobby = md['ink_hobby'];
      if (hobby is Map && hobby.isNotEmpty) {
        sb.writeln('【笔墨癖好】');
        hobby.forEach((k, v) {
          if (v != null && v.toString().isNotEmpty) sb.writeln('$k：$v');
        });
        sb.writeln();
      }
      writeBlock('人设', md['characters']);
      writeBlock('矛盾冲突', md['conflicts']);
      writeBlock('伏笔', md['foreshadowing']);
      writeBlock('弧线功能', md['arc_functions']);
      writeBlock('不可逆变化', md['irreversible_changes']);
      writeBlock('情绪曲线', md['emotional_curve']);
      writeBlock('作者脑洞', md['author_fantasy']);

      entries[uid.toString()] = _stEntry(
        uid++,
        keys: ['弧线${an.arcNumber}', arc.title],
        comment: '弧线${an.arcNumber}：${arc.title}',
        content: sb.toString(),
        constant: false,
        order: 100,
      );
    }

    final data = {
      'entries': entries,
      'originalData': null,
      'name': '${state.currentBook}_原书世界书',
    };
    final now = DateTime.now();
    final date =
        '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    final filename = 'worldbook_${state.currentBook}_原书_$date.json';
    final path = state.storage.getExportPath(filename);
    state.storage.writeFile(
      path,
      const JsonEncoder.withIndent('  ').convert(data),
    );
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已导出原书酒馆世界书：$path（${entries.length}条）')),
    );
  }

  /// ST条目构造（字段与世界书页_exportSillyTavern完全一致）
  Map<String, dynamic> _stEntry(
    int uid, {
    required List<String> keys,
    required String comment,
    required String content,
    required bool constant,
    required int order,
  }) {
    return {
      'uid': uid,
      'key': keys,
      'keysecondary': null,
      'comment': comment,
      'content': TextCleaner.stripDecorativeEmoji(content),
      'constant': constant,
      'vectorized': false,
      'selective': constant ? false : true,
      'selectiveLogic': 0,
      'addMemo': null,
      'order': order,
      'position': 0,
      'disable': false,
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
  }

  void _export(AppState state, String format) {
    final data = state.buildAnalysisObject();
    if (format == 'json') {
      final json = jsonEncode(data);
      final path = state.storage.getExportPath(
        'novel_analysis_${DateTime.now().toIso8601String().substring(0, 10)}.json',
      );
      state.storage.writeFile(path, json);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('已导出到$path')));
    } else {
      // Markdown
      final sb = StringBuffer();
      sb.writeln('# 网文拆解报告\n');
      final arcs = data['arcs'] as List? ?? [];
      for (final arcJson in arcs) {
        final arc = arcJson as Map<String, dynamic>;
        sb.writeln('## 弧线${arc['number'] ?? ''}：${arc['title'] ?? ''}\n');
        sb.writeln('章节范围：${arc['chapter_range'] ?? ''}\n');
        if (arc['summary'] != null) sb.writeln('### 弧线总结\n${arc['summary']}\n');
        final scenes = arc['scenes'] as List? ?? [];
        for (final scJson in scenes) {
          final sc = scJson as Map<String, dynamic>;
          sb.writeln(
            '### 场景：${sc['name'] ?? ''} (${sc['chapter_range'] ?? ''})\n',
          );
          final shots = sc['shots'] as List? ?? [];
          for (final shJson in shots) {
            final sh = shJson as Map<String, dynamic>;
            sb.writeln('**分镜**：${sh['focus'] ?? ''} — ${sh['content'] ?? ''}');
            if (sh['shot_type'] != null) sb.writeln('- 镜头：${sh['shot_type']}');
            if (sh['pov'] != null) sb.writeln('- 视角：${sh['pov']}');
            if (sh['info'] != null) sb.writeln('- 信息：${sh['info']}');
            if (sh['intent'] != null) sb.writeln('- 意图：${sh['intent']}');
            if (sh['transition'] != null)
              sb.writeln('- 转场：${sh['transition']}');
            if (sh['length'] != null) sb.writeln('- 篇幅：${sh['length']}');
            sb.writeln();
          }
        }
      }
      final path = state.storage.getExportPath(
        'novel_report_${DateTime.now().toIso8601String().substring(0, 10)}.md',
      );
      state.storage.writeFile(path, sb.toString());
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('已导出到$path')));
    }
  }

  /// 拆解单个场景的分镜
  /// 批量拆解所有已划分场景
  /// 获取场景对应的章节文本（和v318的getSceneChapters一致）
  /// 解析分镜API响应
  /// v363：镜级切片物化——scene.text按每镜end_text链式切分落shot.text。
  /// 尽力而为：end_text缺失/定位失败→该镜text留空（回退场景切片），不告警不阻塞。
  /// 末镜默认到场景末尾；锚点句从上一切分点之后搜索防跨镜重句误命中
  void _materializeShotTexts(Scene scene, {AppState? state, String? arcKey, int? sceneIdx}) {
    var base = scene.text;
    if (base.isEmpty && state != null && arcKey != null && sceneIdx != null) {
      // v506b：旧划分场景无锚定切片——尝试全局场景流兜底（sceneFrom-1+sceneIdx定位）
      for (final a in state.completedArcs) {
        if (a.number.toString() == arcKey && a.sceneFrom >= 0) {
          final gi = a.sceneFrom - 1 + sceneIdx;
          if (gi >= 0 && gi < state.globalScenes.length &&
              state.globalScenes[gi].text.isNotEmpty) {
            base = state.globalScenes[gi].text;
            scene.text = base;
            _addLog('ℹ️ 场景无锚定切片，已从全局场景流取切片物化（${base.length}字）');
          }
          break;
        }
      }
    }
    if (base.isEmpty) {
      _addLog('⚠️ 场景无锚定切片（旧划分数据）——镜级切片跳过，创作时回退场景切片；建议重新划分场景');
      return;
    }
    if (scene.shots.isEmpty) return;
    // v363b：宽松索引——只保留汉字/字母/数字建映射（AI照抄时全角半角
    // 标点、空白、引号差异全免疫；切点靠映射回原文原始偏移，标点不参与）
    final _word = RegExp(r'[\u4e00-\u9fa5a-zA-Z0-9]');
    String norm(String t) {
      final sb = StringBuffer();
      for (var i = 0; i < t.length; i++) {
        if (_word.hasMatch(t[i])) sb.write(t[i]);
      }
      return sb.toString();
    }

    final nb = norm(base);
    // normIdx[k]=nb第k个字符在base里的原始偏移
    final normIdx = <int>[];
    for (var i = 0; i < base.length; i++) {
      if (_word.hasMatch(base[i])) normIdx.add(i);
    }
    // v364b：定位后一律句末吸附（对齐场景链式切分v321/v323做法）——
    // 直搜路径末字后可能还挂着标点/收尾引号；宽松路径切点落在最后一个
    // 汉字上（标点被归一化剥掉）。snap把切点推到真正句末（含吞后随引号）
    int? locate(String et, int fromOrig) {
      if (et.isEmpty) return null;
      int? raw;
      // 先原文直搜（从上一切点之后，防跨镜重句）
      var idx = base.indexOf(et, fromOrig);
      if (idx >= 0) {
        raw = idx + et.length;
      } else {
        idx = base.indexOf(et);
        if (idx >= 0) {
          raw = idx + et.length;
        } else {
          // 宽松：归一化后的needle在归一化haystack里搜，映射回原偏移
          final ne = norm(et);
          if (ne.length < 4) return null; // 太短易误命中
          var start = 0;
          if (fromOrig > 0) {
            // 上一切点的归一化位置
            var lo = 0;
            while (lo < normIdx.length && normIdx[lo] < fromOrig) {
              lo++;
            }
            start = lo;
          }
          final hit = nb.indexOf(ne, start);
          if (hit < 0) return null;
          raw = normIdx[hit + ne.length - 1] + 1;
        }
      }
      return ArcText.snapToSentenceEnd(base, raw!);
    }

    var from = 0;
    var okCount = 0;
    final missed = <String>[];
    for (var i = 0; i < scene.shots.length; i++) {
      final isLast = i == scene.shots.length - 1;
      final et = scene.shots[i].endText.trim();
      if (isLast) {
        scene.shots[i].text = base.substring(from);
        okCount++;
        break;
      }
      if (et.isEmpty) {
        missed.add('镜${i + 1}:AI未给end_text');
        continue;
      }
      final endPos = locate(et, from);
      if (endPos == null || endPos <= from) {
        missed.add('镜${i + 1}:"${et.length > 18 ? et.substring(0, 18) : et}…"');
        continue;
      }
      scene.shots[i].text = base.substring(from, endPos);
      from = endPos;
      okCount++;
    }
    if (okCount == scene.shots.length) {
      _addLog('✓ 镜级切片物化完成（${scene.shots.length}/${scene.shots.length}镜）');
    } else {
      _addLog('镜级切片：$okCount/${scene.shots.length}镜物化（未命中镜创作时回退场景切片）');
      for (final m in missed) {
        _addLog('  ✗ $m');
      }
    }
  }

  /// 就地拆解单个场景的分镜（v468 analyzeSingleScene）
  Future<bool> _analyzeSceneShots(
    AppState state,
    String arcKey,
    int sceneIdx, {
    bool batch = false,
  }) async {
    final arcNum = int.tryParse(arcKey) ?? 0;
    final arc = state.completedArcs
        .where((a) => a.number == arcNum)
        .firstOrNull;
    if (arc == null) {
      _addLog('错误：未找到弧线$arcKey');
      return false;
    }
    // v477：双容器兜底（卡片遍历的是analysis.scenes，拆解读arcScenes，
    // 长度不一致时越界——统一取并集来源）
    var scenes = state.arcScenes[arcKey] ?? [];
    if (sceneIdx >= scenes.length) {
      final alt = state.arcAnalyses[arcKey]?.scenes ?? [];
      if (sceneIdx < alt.length) {
        scenes = alt;
      } else {
        _addLog(
          '错误：场景索引越界（arcScenes=${scenes.length}个/analysis=${alt.length}个）',
        );
        return false;
      }
    }
    final scene = scenes[sceneIdx];

    // v692：函数内防重入（双击落在按钮重建完成前=绕过构建期_isAnalyzing判断，
    // 实测单场景拆解弹两次词链）——第二道保险，批量路径由调用方守卫
    if (_isAnalyzing) {
      _addLog('已有拆解任务进行中——忽略重复触发（防双击重入）');
      return false;
    }
    if (!batch) {
      setState(() {
        _isAnalyzing = true;
        _statusText = '正在拆解弧线$arcKey场景${sceneIdx + 1}的分镜...';
      });
    }
    _addLog('━━ 拆分镜：弧线$arcKey 场景${sceneIdx + 1} ${scene.name}');
    state.api.clearAbort(); state.userAborted = false; // 清除上次abort残留

    final oldShots = scene.shots; // 失败回滚
    try {
      final chapterText = _getSceneChapterText(state, scene);
      if (chapterText.trim().isEmpty) {
        _addLog('错误：未找到场景章节文本（${scene.chapterRange}）');
        return false;
      }
      _addLog('章节文本：${chapterText.length}字');

      // v659：token篇幅必选（开关已删）——篇幅维度恒精确
      final systemPrompt = PromptBuilder.buildShotSystemPrompt(
        true,
        state.funcAbstract,
      );
      // v694：删除旧单次预览块（v687分批改造时漏删——导致每批预览前先弹
      // 一次旧词链=用户实证连弹两次、标题不同）

      // v468对齐：分镜拆解用「拆解API」（analyzeSingleScene→getAnalysisAPIConfig），场景划分才用「场景API」
      final config = state.getApiConfig('analysis');
      // v695：撤销分批拆镜（用户定稿：中转API无缓存，各批缺上文上下文，
      // 批边界的转场/意图会与内容对不齐——错误形态不可接受；镜数合并问题
      // 已由v690密度绝对计数根治，长场景输出体量由拆解API的maxTokens承担）
      final userPrompt = PromptBuilder.buildShotUserPrompt(scene, chapterText);

      final ok = await PromptPreview.maybePreview(
        context,
        sysPrompt: systemPrompt,
        userPrompt: userPrompt,
        title: '分镜拆解词链预览',
        enabled: state.shotPromptPreview,
      );
      if (!ok) {
        _addLog('用户在预览后终止');
        return false;
      }

      var result = await state.api.callApi(
        systemPrompt: systemPrompt,
        userPrompt: userPrompt,
        apiConfig: config,
      );
      var parsed = JsonRepair.parseResponse(result.content);
      var shotsJson = parsed?['shots'] as List?;
      var retry = 0;
      while (result.isSuccess &&
          (shotsJson == null || shotsJson.isEmpty) &&
          result.content.length < 500 &&
          retry < 1 &&
          !state.api.isAborted) {
        retry++;
        _addLog('⚠️ 返回过短（${result.content.length}字）无分镜，重试1次...样本头200字：${result.content.length > 200 ? result.content.substring(0, 200) : result.content}');
        await Future.delayed(const Duration(seconds: 3));
        if (state.api.isAborted || state.userAborted) break;
        result = await state.api.callApi(
          systemPrompt: systemPrompt,
          userPrompt: userPrompt,
          apiConfig: config,
        );
        parsed = JsonRepair.parseResponse(result.content);
        shotsJson = parsed?['shots'] as List?;
      }
      if (shotsJson != null && shotsJson.isNotEmpty) {
        scene.shots = shotsJson
            .map((e) => Shot.fromJson(e as Map<String, dynamic>))
            .toList();
          // v363：镜级切片物化（尽力而为）——从scene.text链式定位每镜end_text。
          // 失败→该镜text留空，创作端回退场景切片，绝不影响拆解落库（与场景
          // 物化的严格模式相反：场景切片是拆解输入必须严，镜切片只是创作范文必须宽）
          _materializeShotTexts(scene, state: state, arcKey: arcKey, sceneIdx: sceneIdx);
          // v519：功能抽象质检——abstract含人名/焦点词=情节概括非功能抽象（拆解端
          // 常见偷懒形态），标⚠告警提示手动修正（不阻塞落库）
          for (final sh in scene.shots) {
            final ab = sh.abstraction;
            if (ab.isEmpty || sh.focus.isEmpty) continue;
            // 情节化判定：abstract与focus有≥4字连续重合=在复述情节而非抽象功能
            final hits = PromptBuilder.findCopiedPhrases(sh.focus, ab, maxReport: 2);
            if (hits.isNotEmpty) {
              _addLog('⚠️ 分镜${scene.shots.indexOf(sh) + 1}功能抽象疑非抽象'
                  '（与焦点重合"${hits.first}"）："$ab"——功能抽象应为'
                  '"暴露弱点/制造反差"类无专名功能语言，建议手动修正');
            }
          }
          // v507b：拆分镜走arcAnalyses场景（v500分组产出不写arcScenes）时，
          // 同步回写arcScenes——创作页镜级切片/范文读arcScenes，不回写=永远读空
          if ((state.arcScenes[arcKey] ?? const []).isEmpty && scenes.isNotEmpty) {
            state.arcScenes[arcKey] = scenes;
            _addLog('✓ 场景容器同步：arcScenes[弧线$arcKey]=${scenes.length}个场景（含镜级切片）');
          }
          state.saveArcScenes();
          // 同步到arcAnalyses（统一格式：分镜页优先读arcAnalyses，不同步则分镜页看不到两步拆解结果）
          var analysis = state.arcAnalyses[arcKey];
          if (analysis == null) {
            analysis = ArcAnalysis(arcNumber: arcNum, arcTitle: arc.title);
            state.arcAnalyses[arcKey] = analysis;
          }
          if (analysis.scenes.isEmpty) analysis.scenes = scenes;
          if (sceneIdx < analysis.scenes.length) {
            analysis.scenes[sceneIdx].shots = scene.shots; // 覆盖对应场景分镜（统一格式相互覆盖）
          }
          state.saveArcAnalyses();
          // v210：两步拆解补已拆解标记——此前只有一步拆解markArcAnalyzed，
          // v209严格化（isArcAnalyzed && hasShots）后两步拆解的弧线在改编页消失
          state.markArcAnalyzed(arcNum);
          _addLog('✓ 解析成功：${scene.shots.length}个分镜');
          if (scene.shots.isNotEmpty) {
            _addLog('分镜字段：${scene.shots.first.toJson().keys.join(', ')}');
          }
          state.refresh();
          return true;
      } else {
        scene.shots = oldShots;
        _addLog('❌ 未解析到分镜数据');
        return false;
      }
    } catch (e) {
      scene.shots = oldShots;
      if (state.api.isAborted || state.userAborted) {
        _addLog('⏹ 已终止，分镜已回滚');
      } else {
        _addLog('异常：$e');
      }
      return false;
    } finally {
      if (!batch) {
        setState(() {
          _isAnalyzing = false;
          _statusText = '';
        });
      }
    }
  }

  /// 智能分发拆解（v469 analyzeSingleArc语义）：
  /// · 弧线已划分场景 → 弹三选对话框（增量拆未拆场景/全部重拆/取消），走批量逐场景拆分镜
  /// · 弧线未划分场景 → 直接一体拆解（AI自己划场景+分镜）
  Future<void> _analyzeSingleArc(AppState state, int arcIdx) async {
    if (_isAnalyzing) return;
    final arcs = state.allArcs;
    if (arcIdx < 0 || arcIdx >= arcs.length) return;
    final arc = arcs[arcIdx];
    if (arc.status == 'incomplete') {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('⛔ 弧线${arc.number}未闭合——先继续扫描场景流/重新分组让它闭合，再拆分镜')));
      }
      _addLog('⛔ 弧线${arc.number}未闭合（incomplete）——拆解已阻止');
      return;
    }
    final scenes = state.arcScenes[arc.number.toString()] ?? [];

    if (scenes.isNotEmpty) {
      // 已划分场景：对场景独立拆分镜（三选对话框，v469同款）
      final withShots = scenes.where((s) => s.shots.isNotEmpty).length;
      final allHaveShots = withShots == scenes.length;
      final choice = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('拆分镜'),
          content: Text(
            allHaveShots
                ? '该弧线分镜已全部拆解完毕（${scenes.length}个场景），请选择：'
                : '已拆$withShots/${scenes.length}个场景的分镜，请选择：',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, 'cancel'),
              child: const Text('取消'),
            ),
            OutlinedButton(
              style: OutlinedButton.styleFrom(foregroundColor: Colors.red),
              onPressed: () => Navigator.pop(ctx, 'full'),
              child: const Text('全部重新拆分镜'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, 'increment'),
              child: const Text('增量拆未拆场景'),
            ),
          ],
        ),
      );
      if (choice == null || choice == 'cancel') return;
      if (choice == 'full') {
        await _batchAnalyzeShots(
          state,
          true,
          onlyArcNumber: arc.number,
        ); // 全部重拆（清已有分镜）
      } else {
        if (allHaveShots) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('所有场景已有分镜，如需重拆请选"全部重新拆分镜"')),
            );
          }
          return;
        }
        await _batchAnalyzeShots(
          state,
          false,
          onlyArcNumber: arc.number,
        ); // 增量：只拆未拆场景
      }
      return;
    }
  }

  /// 批量拆分镜（increment=true只拆未拆场景；false=全部重拆）
  /// [onlyArcNumber] 限定只拆这条弧线（场景页单弧线"去拆解分镜"入口）；null=全书批量
  Future<void> _batchAnalyzeShots(
    AppState state,
    bool clearExisting, {
    int? onlyArcNumber,
  }) async {
    // v526b：只收集已闭合弧线——遇到未闭合弧线停止收集并提示（未闭合弧线
    // 后续还会续场景，拆了白拆；用户裁决：停止+提示该弧线不完整）
    final arcs = state.allArcs;
    // 收集需要拆的弧线（有场景且有未拆场景，或全重拆）
    final toAnalyze = <String, List<int>>{};
    var stoppedByIncomplete = false;
    for (final arc in arcs) {
      if (onlyArcNumber != null && arc.number != onlyArcNumber) continue;
      if (arc.status == 'incomplete') {
        stoppedByIncomplete = true;
        _addLog('⛔ 弧线${arc.number}未闭合（incomplete）——停止拆解。'
            '请先继续扫描场景流/重新分组让该弧线闭合后再拆');
        break;
      }
      final key = arc.number.toString();
      // v477：双容器兜底（分组弧线两容器同步；旧数据可能只有其一）
      final scenes = (state.arcScenes[key]?.isNotEmpty ?? false)
          ? state.arcScenes[key]!
          : (state.arcAnalyses[key]?.scenes ?? []);
      if (scenes.isEmpty) {
        // v521b：幽灵弧线可见化（arcScan残留/分组产出缺段——静默跳过=统计对不上）
        _addLog('⚠️ 弧线$key 无场景数据，跳过拆解（建议重扫场景流+重新分组）');
        continue;
      }
      final pending = <int>[];
      for (var si = 0; si < scenes.length; si++) {
        if (clearExisting || scenes[si].shots.isEmpty) pending.add(si);
      }
      if (pending.isNotEmpty) toAnalyze[key] = pending;
    }
    if (toAnalyze.isEmpty) {
      _addLog(stoppedByIncomplete
          ? '⛔ 未闭合弧线之后的分镜未拆（先闭合该弧线）'
          : '没有需要拆解的场景（请先划分场景）');
      return;
    }
    // v520b：全部重拆前先清空旧分镜——中途断开时"有分镜=新拆的，无=还没拆"，
    // 新旧混杂再也无法区分（旧规则拆的结构层还带原著专名，混入更难辨）
    if (clearExisting) {
      _addLog('━━ 收到全部重拆指令：开始清空旧分镜…');
      try {
        var cleared = 0;
        for (final key in toAnalyze.keys) {
          for (final s in state.arcScenes[key] ?? const []) {
            if (s.shots.isNotEmpty) {
              s.shots = <Shot>[];
              cleared++;
            }
          }
          final an = state.arcAnalyses[key];
          if (an != null) {
            for (final s in an.scenes) {
              s.shots = <Shot>[];
            }
          }
        }
        if (cleared > 0) {
          state.saveArcScenes();
          state.saveArcAnalyses();
          _addLog('🧹 已清空${cleared}个场景的旧分镜（重拆开始——拆完的场景才显示有分镜）');
        } else {
          _addLog('旧分镜为空，直接开始重拆');
        }
      } catch (e) {
        _addLog('⛔ 清空旧分镜异常：$e——继续尝试重拆');
      }
    }

    var totalArcs = toAnalyze.length;
    var done = 0;
    setState(() {
      _isAnalyzing = true;
      _statusText = '批量拆分镜：0/$totalArcs弧线';
    });
    _addLog('批量拆分镜开始：$totalArcs条弧线');
    // 清除上次abort残留（v186修复：同_batchDivide，终止残留致下次批量秒退）
    state.api.clearAbort(); state.userAborted = false;
    // v368：全程try/finally——异常逃逸进度条永久卡死（v285同款病）
    try {
      for (final entry in toAnalyze.entries) {
        if (state.api.isAborted || state.userAborted) {
          _addLog('⏹ 批量拆分镜被终止');
          break;
        }
        done++;
        final arcKey = entry.key;
        final pending = entry.value;
        setState(() => _statusText = '批量拆分镜：$done/$totalArcs弧线');
        _addLog('━━ 弧线$arcKey（$done/$totalArcs）：${pending.length}个场景待拆');
        for (final si in pending) {
          if (state.api.isAborted || state.userAborted) {
            _addLog('⏹ 批量拆分镜被终止');
            break;
          }
          final ok = await _analyzeSceneShots(state, arcKey, si, batch: true);
          if (state.api.isAborted || state.userAborted) break; // 终止优先
          if (!ok) {
            _addLog('❌ 弧线$arcKey场景${si + 1}拆解失败，终止批量');
            break;
          }
        }
      }
      _addLog('批量拆分镜完成');
      state.saveArcScenes();
    } finally {
      if (mounted) {
        setState(() {
          _isAnalyzing = false;
          _statusText = '';
        });
      }
    }
  }

  /// 全部重拆分镜确认对话框（v468三选：增量/全部/取消）
  Future<void> _confirmFullReshot(AppState state) async {
    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('全部重拆分镜'),
        content: const Text('将清掉所有已拆解的分镜重新拆解，选择：'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'cancel'),
            child: const Text('取消'),
          ),
          OutlinedButton(
            onPressed: () => Navigator.pop(ctx, 'increment'),
            child: const Text('增量拆未拆场景'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, 'full'),
            child: const Text('全部重拆分镜'),
          ),
        ],
      ),
    );
    if (choice == null || choice == 'cancel') return;
    await _batchAnalyzeShots(state, choice == 'full');
  }

  /// 获取场景章节文本（和analysis_page一致）
  /// v320：分镜拆解直读场景锚定切片（划分时物化落库）——零污染零猜测
  String _getSceneChapterText(AppState state, Scene scene) {
    if (scene.text.isNotEmpty) return scene.text;
    _addLog('⛔ 场景无锚定切片（旧数据）——请重新划分场景');
    return '';
  }

  /// 解析场景划分API响应
  List<Scene>? _parseSceneResponse(String content) {
    try {
      var cleaned = content.trim();
      if (cleaned.startsWith('```')) {
        cleaned = cleaned.replaceAll(RegExp(r'^```(?:json)?\s*'), '');
        cleaned = cleaned.replaceAll(RegExp(r'\s*```$'), '');
      }
      cleaned = cleaned.replaceAll('，', ',').replaceAll('：', ':');
      final json = jsonDecode(cleaned) as Map<String, dynamic>;
      final scenesJson = json['scenes'] as List? ?? [];
      return scenesJson
          .map((e) => Scene.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (e) {
      _addLog('JSON解析失败: $e');
      return null;
    }
  }

  static String _fmtLength(String v) {
    final t = v.trim();
    if (t.isEmpty) return v;
    if (RegExp(r'^\d+$').hasMatch(t)) return '约${t}token';
    return v;
  }
}
