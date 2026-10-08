import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../state/app_state.dart';
import 'v119_ui.dart';

/// v1173：世界状态账本查看弹层（公共组件——弧线页/分镜页共用，原analysis_page
/// 私有方法提取）。每实体一行（类别/名称/状态/更新弧线），状态列是正文主体
/// （防复活/防易主复原的关键信息），支持复制全文
void showStateLedger(
  BuildContext context,
  AppState state, {
  List<Map<String, dynamic>>? snapshot,
  String? title,
}) {
  // v1155：弧线卡传本弧线快照，顶栏传最新全局账本
  final ledger = snapshot ?? state.stateLedger;
  if (ledger.isEmpty) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(title ?? '📊 世界状态账本'),
        content: const Text('账本为空——对已有弧线重新零件提取后，状态对账任务会自动建立账本（从弧线1开始按序跑）。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
    return;
  }
  // 按类别分组排序（角色/物品/势力/地点/其他），组内按名称
  final groups = <String, List<Map<String, dynamic>>>{};
  for (final e in ledger) {
    final cat = (e['category'] ?? '其他').toString();
    groups.putIfAbsent(cat, () => []).add(e);
  }
  final catOrder = ['角色', '物品', '势力', '地点', '其他'];
  final sortedCats = groups.keys.toList()
    ..sort((a, b) {
      final ia = catOrder.indexOf(a), ib = catOrder.indexOf(b);
      return (ia < 0 ? 99 : ia).compareTo(ib < 0 ? 99 : ib);
    });
  // 复制全文文本
  String ledgerText() {
    final sb = StringBuffer();
    sb.writeln('世界状态账本（${ledger.length}实体）：');
    for (final cat in sortedCats) {
      sb.writeln('【$cat】');
      for (final e in groups[cat]!) {
        sb.writeln('${e['name']}｜${e['state']}｜更新于弧线${e['lastArc']}');
      }
    }
    return sb.toString().trim();
  }

  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    builder: (_) => DraggableScrollableSheet(
      initialChildSize: 0.7,
      maxChildSize: 0.92,
      minChildSize: 0.4,
      expand: false,
      builder: (ctx, scrollCtrl) => Container(
        decoration: BoxDecoration(
          color: Theme.of(ctx).colorScheme.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
        ),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  Expanded(
                    child: Row(
                      children: [
                        Flexible(
                          child: Text(
                            title ?? '📊 世界状态账本',
                            style: const TextStyle(
                                fontSize: 15, fontWeight: FontWeight.bold),
                          ),
                        ),
                        const SizedBox(width: 4),
                        Text(
                          '（${ledger.length}实体）',
                          style: const TextStyle(fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                  MiniButton(
                    label: '复制',
                    onTap: () {
                      Clipboard.setData(ClipboardData(text: ledgerText()));
                      ScaffoldMessenger.of(ctx).showSnackBar(
                        const SnackBar(content: Text('账本全文已复制')),
                      );
                    },
                  ),
                  const SizedBox(width: 6),
                  MiniButton(
                    label: '关闭',
                    onTap: () => Navigator.pop(ctx),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: ListView.builder(
                controller: scrollCtrl,
                itemCount: ledger.length + sortedCats.length,
                itemBuilder: (ctx, i) {
                  // 分组渲染：顺序遍历分类头+组内实体
                  final rows = <Widget>[];
                  for (final cat in sortedCats) {
                    rows.add(Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 4),
                      color: Theme.of(ctx)
                          .colorScheme
                          .surfaceContainerHighest
                          .withValues(alpha: 0.5),
                      child: Text(cat,
                          style: const TextStyle(
                              fontSize: 13, fontWeight: FontWeight.bold)),
                    ));
                    for (final e in groups[cat]!) {
                      rows.add(Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 6),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Flexible(
                                  child: Text(
                                    '${e['name'] ?? ''}',
                                    style: const TextStyle(
                                        fontSize: 14,
                                        fontWeight: FontWeight.w600),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Text(
                                    '弧线${e['lastArc'] ?? '?'}更新',
                                    style: TextStyle(
                                        fontSize: 11,
                                        color: Theme.of(ctx)
                                            .colorScheme
                                            .primary)),
                              ],
                            ),
                            const SizedBox(height: 2),
                            Text('${e['state'] ?? ''}',
                                style: const TextStyle(fontSize: 13)),
                          ],
                        ),
                      ));
                    }
                  }
                  return rows[i];
                },
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
