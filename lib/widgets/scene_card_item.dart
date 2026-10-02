import 'package:flutter/material.dart';

import '../models/scene.dart';
import '../utils/v469_style.dart';

/// v441：老版场景卡片行（v193分行布局——徽章+名称/概述完整/章范围+操作区）
/// 场景页场景流与弧线页弧线卡片共用，保证视觉一致
class SceneCardItem extends StatelessWidget {
  final Scene scene;
  final int index; // 显示序号（1-based）
  final VoidCallback? onView; // 切片查看
  final VoidCallback? onCutResume; // v462：从此场景剪断重扫
  final VoidCallback? onRegenSummary; // v819：单场景概述重生成（切片重喂，边界/弧线不动）
  final VoidCallback? onAnalyzeChoreo; // v901：场景内分镜编排策略分析（拆分镜后可用）
  final VoidCallback? onShots; // v981：点分镜徽章查看该场景全部分镜完整内容
  final Widget? trailing; // 行1右侧自定义区（默认分镜状态徽章）

  const SceneCardItem({
    super.key,
    required this.scene,
    required this.index,
    this.onView,
    this.onCutResume,
    this.onRegenSummary,
    this.onAnalyzeChoreo,
    this.onShots,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final hasShots = scene.shots.isNotEmpty;
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 6, 12, 0),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: V469Style.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: V469Style.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 行1：场景徽章+名称（完整换行显示）
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
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
                  '${index}',
                  style: const TextStyle(
                    fontSize: 10,
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  scene.name,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: V469Style.textMain,
                  ),
                ),
              ),
              if (trailing != null) ...[
                trailing!,
                const SizedBox(width: 2),
              ] else if (onView != null) ...[
                GestureDetector(
                  onTap: onView,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 5),
                    child: Text(
                      scene.text.isNotEmpty ? '切片' : '切片(无)',
                      style: TextStyle(
                        fontSize: 10,
                        color: scene.text.isNotEmpty
                            ? V469Style.accent
                            : V469Style.textMuted,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 2),
              ],
              // 分镜状态徽章（v981：已拆→可点开看全部分镜完整内容）
              GestureDetector(
                onTap: hasShots ? onShots : null,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: hasShots
                        ? Colors.green.withOpacity(0.12)
                        : Colors.grey.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    hasShots ? '✓ ${scene.shots.length}分镜 ›' : '未拆',
                    style: TextStyle(
                      fontSize: 10,
                      color: hasShots ? Colors.green.shade700 : Colors.grey,
                    ),
                  ),
                ),
              ),
            ],
          ),
          // 行2：概述完整显示（不截断）
          if (scene.summary.isNotEmpty) ...[
            const SizedBox(height: 5),
            const Text(
              '📋 场景概述',
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w700,
                color: Color(0xFF475569),
              ),
            ),
            const SizedBox(height: 2),
            Text(
              scene.summary,
              style: const TextStyle(
                fontSize: 11.5,
                height: 1.5,
                color: V469Style.textSec,
              ),
            ),
          // v882：编排标注（分组产出，逐场景功能+蓄力）
          // v1017：默认折叠——点标题展开+底部收起键（对齐分镜页v1006）
          if (scene.choreo.isNotEmpty) ...[
            _ChoreoFoldSection(choreo: scene.choreo),
          ],
          ],
          // 行3：章节范围+剪断重扫键
          const SizedBox(height: 6),
          Row(
            children: [
              Text(
                scene.chapterRange,
                style: const TextStyle(
                    fontSize: 10, color: V469Style.textMuted),
              ),
              const Spacer(),
              // v901：编排策略分析（拆分镜后可用）
              if (onAnalyzeChoreo != null && hasShots)
                GestureDetector(
                  onTap: onAnalyzeChoreo,
                  child: const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 5),
                    child: Text(
                      '🧠 编排',
                      style: TextStyle(
                        fontSize: 10,
                        color: Color(0xFFB45309),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              // v819：单场景概述重生成（切片重喂，边界/弧线不动）
              if (onRegenSummary != null)
                GestureDetector(
                  onTap: onRegenSummary,
                  child: const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 5),
                    child: Text(
                      '↻ 重概述',
                      style: TextStyle(
                        fontSize: 10,
                        color: Color(0xFF0E7490),
                      ),
                    ),
                  ),
                ),
              if (onCutResume != null)
                GestureDetector(
                  onTap: onCutResume,
                  child: const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 5),
                    child: Text(
                      '✂ 剪断重扫',
                      style: TextStyle(
                        fontSize: 10,
                        color: Color(0xFFB45309),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}


/// v1017：场景卡编排折叠区——默认折叠，点标题行展开，底部'▲收起'
/// （场景页+弧线页共用，本地内存态；卡多时默认收起=浏览清爽）
class _ChoreoFoldSection extends StatefulWidget {
  final String choreo;
  const _ChoreoFoldSection({required this.choreo});
  @override
  State<_ChoreoFoldSection> createState() => _ChoreoFoldSectionState();
}

class _ChoreoFoldSectionState extends State<_ChoreoFoldSection> {
  bool _open = false;
  @override
  Widget build(BuildContext context) {
    final paras = widget.choreo
        .split('\n')
        .map((p) => p.trim())
        .where((p) => p.isNotEmpty)
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 5),
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => setState(() => _open = !_open),
          child: Row(
            children: [
              Text(_open ? '▾' : '▸',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    color: Colors.brown.shade600,
                  )),
              const SizedBox(width: 4),
              const Expanded(
                child: Text('🎞 分镜编排（场景内分镜编排策略）',
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFFB45309),
                    )),
              ),
            ],
          ),
        ),
        if (_open) ...[
          const SizedBox(height: 3),
          for (var i = 0; i < paras.length; i++) ...[
            if (i > 0) const SizedBox(height: 3),
            Text(paras[i],
                style: TextStyle(
                  fontSize: 11,
                  height: 1.4,
                  color: Colors.brown.shade600,
                )),
          ],
          // v1008同款：长内容底部收起键——浏览到尾不用滚回顶部
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => setState(() => _open = false),
            child: Padding(
              padding: const EdgeInsets.only(top: 5),
              child: Text('▲ 收起',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    color: Colors.brown.shade600,
                  )),
            ),
          ),
        ],
      ],
    );
  }
}
