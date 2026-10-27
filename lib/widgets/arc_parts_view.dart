import 'dart:convert';

import 'package:flutter/material.dart';

import '../models/scene.dart';
import '../utils/v469_style.dart';

/// v1167：弧线零件公共渲染（v469顺序：人设→冲突→伏笔→弧线功能→不可逆→情绪→脑洞）
/// 从analysis_page._buildArcParts迁出——分镜页/弧线页（scan_page弧线卡）复用
class ArcParts {
  static String _asStr(dynamic v) => v == null ? '' : v.toString();

  static List<dynamic> _asList(dynamic v) => v is List ? v : const [];

  static Map<String, dynamic>? _asMap(dynamic v) =>
      v is Map<String, dynamic> ? v : null;

  static Widget _metaTitle(String label) {
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
  static Widget _metaItem(List<InlineSpan> spans) {
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

  static List<Widget> build(ArcAnalysis? analysis) {
    if (analysis == null || analysis.metadata == null) return const [];
    final md = analysis.metadata!;
    final widgets = <Widget>[];


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
        // v1159：traits兜底中文键（旧数据/AI键名漂移兼容）+渲染关系/状态字段
        final traits = m != null
            ? (_asStr(m['traits']).isNotEmpty
                ? _asStr(m['traits'])
                : _asStr(m['性格特征']))
            : '';
        final relation = m != null
            ? (_asStr(m['relation']).isNotEmpty
                ? _asStr(m['relation'])
                : _asStr(m['与主角的关系']) ?? _asStr(m['与主角关系']))
            : '';
        final arcState = m != null
            ? (_asStr(m['arcState']).isNotEmpty
                ? _asStr(m['arcState'])
                : _asStr(m['本弧线状态变化']) ?? _asStr(m['本弧线状态']))
            : '';
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
                  // v1159：与主角的关系（含本弧线关系变化）
                  if (relation.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        '🔗 $relation',
                        style: const TextStyle(
                          fontSize: 11.5,
                          color: V469Style.textSec,
                        ),
                      ),
                    ),
                  // v1159：本弧线状态变化（登场→变化→最终状态含生死）
                  if (arcState.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        '📍 $arcState',
                        style: const TextStyle(
                          fontSize: 11.5,
                          color: Color(0xFFB45309),
                        ),
                      ),
                    ),
                  // v1217：主角三观与理想人格（v1210加values时漏了此渲染端——
                  // 仅主角有此键，世界观/人生观/价值观+作者的理想人格）
                  if (m != null && _asStr(m['values']).isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 3),
                      child: Text(
                        '🎯 三观与理想人格：${_asStr(m['values'])}',
                        style: const TextStyle(
                          fontSize: 11.5,
                          height: 1.5,
                          color: Color(0xFF7C3AED),
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
        var desc = m != null ? _asStr(m['description']) : _asStr(c);
        // v1244：键名漂移兜底——type/description都取不到时显示原始形态
        // （不再静默空白条目63084截图实证；写侧_normalizeConflicts已归一化）
        if (m != null && type.isEmpty && desc.isEmpty) {
          desc = jsonEncode(c);
          if (desc.length > 120) desc = desc.substring(0, 120);
        }
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

    // 7. 伏笔账本（v1245：全局滚动账本快照——未回收红/已回收绿+回收位置）
    // v1253：本弧线新种的条目折叠成一行计数（与上方伏笔块重复显示，纯显示去重，
    // 数据不动）——只平铺前弧线遗留条目；plantedArc缺失的条目保守平铺不隐藏
    final foreSnap = _asList(md['foreshadow_ledger_snapshot']);
    if (foreSnap.isNotEmpty) {
      final openCnt = foreSnap
          .where((e) => e is Map && ((e['status'] ?? 'open').toString() != 'paid'))
          .length;
      final ownCnt = foreSnap.where((e) {
        if (e is! Map) return false;
        return (int.tryParse('${e['plantedArc']}') ?? -1) == analysis!.arcNumber;
      }).length;
      widgets.add(_metaTitle('📒 伏笔账本（未回收$openCnt/共${foreSnap.length}）'));
      if (ownCnt > 0) {
        widgets.add(
          _metaItem([
            TextSpan(
              text: '⋯ 本弧线新种$ownCnt条见上方🌱伏笔块（已折叠）',
              style: const TextStyle(
                fontSize: 11,
                color: V469Style.textMuted,
                fontStyle: FontStyle.italic,
              ),
            ),
          ]),
        );
      }
      for (final f in foreSnap) {
        final m = _asMap(f);
        if (m == null) continue;
        final content = _asStr(m['content']);
        if (content.isEmpty) continue;
        final plantedArc = int.tryParse('${m['plantedArc']}') ?? -1;
        if (plantedArc == analysis!.arcNumber) continue; // v1253：本弧线新种不重复平铺
        final plantedAt = _asStr(m['plantedAt']);
        final paid = (m['status'] ?? 'open').toString() == 'paid';
        final payoff = _asStr(m['payoff']);
        widgets.add(
          _metaItem([
            TextSpan(
              text: paid ? '✅ ' : '🔍 ',
              style: const TextStyle(fontSize: 11),
            ),
            TextSpan(
              text: content,
              style: TextStyle(
                fontSize: 12,
                color: paid ? V469Style.textSec : V469Style.textMain,
                decoration: paid ? TextDecoration.lineThrough : null,
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
            if (paid && payoff.isNotEmpty) ...[
              const TextSpan(
                text: ' → ',
                style: TextStyle(fontSize: 12, color: V469Style.textSec),
              ),
              TextSpan(
                text: payoff, // 回收位置+情况（第X章回收：…）
                style: const TextStyle(
                  fontSize: 12,
                  color: V469Style.complete,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ]),
        );
      }
    }

    // 8. 弧线功能
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
}
