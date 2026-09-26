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
  final Widget? trailing; // 行1右侧自定义区（默认分镜状态徽章）

  const SceneCardItem({
    super.key,
    required this.scene,
    required this.index,
    this.onView,
    this.onCutResume,
    this.onRegenSummary,
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
              // 分镜状态徽章
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: hasShots
                      ? Colors.green.withOpacity(0.12)
                      : Colors.grey.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  hasShots ? '✓ ${scene.shots.length}分镜' : '未拆',
                  style: TextStyle(
                    fontSize: 10,
                    color: hasShots ? Colors.green.shade700 : Colors.grey,
                  ),
                ),
              ),
            ],
          ),
          // 行2：概述完整显示（不截断）
          if (scene.summary.isNotEmpty) ...[
            const SizedBox(height: 5),
            Text(
              scene.summary,
              style: const TextStyle(
                fontSize: 11.5,
                height: 1.5,
                color: V469Style.textSec,
              ),
            ),
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
