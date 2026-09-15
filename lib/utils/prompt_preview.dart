import 'package:flutter/material.dart';
import 'v469_style.dart';

/// v469 maybePreview/showPromptPreview 对齐：
/// 通用提示词预览（SYSTEM折叠+USER按##段落分块折叠，不再截断）
/// 场景划分/分镜拆解/世界书生成/AI味审核共用
class PromptPreview {
  /// v469 maybePreview：开关关闭直接放行，开启弹预览
  /// 返回true=确认发送（或未启用预览）
  static Future<bool> maybePreview(
    BuildContext context, {
    required String sysPrompt,
    required String userPrompt,
    required String title,
    required bool enabled,
  }) async {
    if (!enabled) return true;
    return show(context, sysPrompt: sysPrompt, userPrompt: userPrompt, title: title);
  }

  /// 按##标题切块（无标题前缀归入"开头部分"）
  static List<MapEntry<String, String>> _splitSections(String text) {
    final sections = <MapEntry<String, String>>[];
    final headerRe = RegExp(r'^#{1,3}\s+(.+)$', multiLine: true);
    var pos = 0;
    var header = '';
    for (final m in headerRe.allMatches(text)) {
      // 标题前的正文归上一节（第一段无标题归"开头部分"）
      final body = text.substring(pos, m.start).trim();
      if (body.isNotEmpty || sections.isNotEmpty) {
        sections.add(MapEntry(header, body));
      } else {
        // 开头就是标题：正文为空也开节
      }
      header = m.group(1)!.trim();
      pos = m.end;
    }
    sections.add(MapEntry(header, text.substring(pos).trim()));
    // 去掉头部空节
    sections.removeWhere((s) => s.key.isEmpty && s.value.isEmpty);
    return sections;
  }

  /// 单节正文按3000字分段（不截断，全部可见）
  static List<String> _chunkBody(String body, [int size = 3000]) {
    if (body.length <= size) return [body];
    final chunks = <String>[];
    for (var i = 0; i < body.length; i += size) {
      final end = (i + size < body.length) ? i + size : body.length;
      chunks.add(body.substring(i, end));
    }
    return chunks;
  }

  /// v469 showPromptPreview：SYSTEM折叠 + USER按段落分块折叠（无截断）
  static Future<bool> show(
    BuildContext context, {
    required String sysPrompt,
    required String userPrompt,
    required String title,
  }) async {
    final sections = _splitSections(userPrompt);
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: Text(title, style: const TextStyle(fontSize: 15)),
        contentPadding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
        content: SizedBox(
          width: double.maxFinite,
          height: MediaQuery.of(ctx).size.height * 0.7,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // SYSTEM PROMPT（折叠）
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                dense: true,
                title: const Text('SYSTEM PROMPT（点击展开/折叠）',
                    style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: V469Style.accent)),
                children: [
                  Container(
                    width: double.infinity,
                    constraints: const BoxConstraints(maxHeight: 200),
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: V469Style.surfaceAlt,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: SingleChildScrollView(
                      child: SelectableText(sysPrompt,
                          style: const TextStyle(fontSize: 10.5, height: 1.6, color: V469Style.textMuted)),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              // USER PROMPT 分块（##段落=检查清单，逐块折叠展开核对）
              Text('USER PROMPT（${userPrompt.length}字，${sections.length}块）',
                  style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: V469Style.accent)),
              const SizedBox(height: 6),
              Expanded(
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: V469Style.surfaceAlt,
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: V469Style.border),
                  ),
                  child: ListView.builder(
                    itemCount: sections.length,
                    itemBuilder: (c, i) {
                      final sec = sections[i];
                      final secTitle = sec.key.isEmpty ? '（开头部分）' : sec.key;
                      final chunks = _chunkBody(sec.value);
                      return ExpansionTile(
                        tilePadding: const EdgeInsets.symmetric(horizontal: 4),
                        dense: true,
                        initiallyExpanded: i == 0,
                        title: Text(
                          '第${i + 1}块：$secTitle（${sec.value.length}字）',
                          style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: V469Style.textSec),
                        ),
                        subtitle: chunks.length > 1
                            ? Text('${chunks.length}段×3000字', style: const TextStyle(fontSize: 9.5, color: V469Style.textMuted))
                            : null,
                        children: [
                          for (var ci = 0; ci < chunks.length; ci++)
                            Container(
                              width: double.infinity,
                              margin: const EdgeInsets.fromLTRB(4, 0, 4, 6),
                              padding: const EdgeInsets.all(10),
                              decoration: BoxDecoration(
                                color: V469Style.surface,
                                borderRadius: BorderRadius.circular(4),
                                border: Border.all(color: V469Style.border),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  if (chunks.length > 1)
                                    Padding(
                                      padding: const EdgeInsets.only(bottom: 4),
                                      child: Text('段${ci + 1}/${chunks.length}',
                                          style: const TextStyle(fontSize: 9.5, color: V469Style.textMuted)),
                                    ),
                                  SelectableText(
                                    chunks[ci],
                                    style: const TextStyle(fontSize: 10.5, height: 1.6, color: V469Style.textSec),
                                  ),
                                ],
                              ),
                            ),
                        ],
                      );
                    },
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('确认发送')),
        ],
      ),
    );
    return result ?? false;
  }
}
