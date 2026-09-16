import 'dart:io' show Platform;

import 'package:flutter/material.dart';

/// v469视觉体系（照抄v318/v469的生成结果渲染样式）
/// 字段级图标+颜色映射、镜头类型8色、徽章样式统一从此处取
class V469Style {
  // ── 字体（v200统一入口：所有字体显式指定，不赌Theme继承链）──
  // Windows默认Segoe UI中文fallback宋体；Android默认Noto已是理想黑体不动
  static String? get uiFont =>
      Platform.isWindows ? 'Microsoft YaHei' : null;
  // 终端/日志等宽：Win用Consolas但必须给中文fallback雅黑
  //（纯monospace中文回落宋体=面板里两种字体的元凶）；Android保持monospace
  static String get monoFont =>
      Platform.isWindows ? 'Consolas' : 'monospace';
  static List<String>? get monoFallback =>
      Platform.isWindows ? const ['Microsoft YaHei'] : null;

  // ── 色板（v469 :root变量）──
  static const accent = Color(0xFF8B6914); // 金棕
  static const accentLight = Color(0xFFD4A84A);
  static const accentBg = Color(0xFFFDF6E8);
  static const complete = Color(0xFF2D6A4F); // 绿
  static const completeBg = Color(0xFFE8F5EE);
  static const incomplete = Color(0xFFC44536); // 红
  static const incompleteBg = Color(0xFFFBEAE8);
  static const surface = Color(0xFFFFFFFF);
  static const surfaceAlt = Color(0xFFF5F0E8); // 暖灰
  static const textMain = Color(0xFF2C1810);
  static const textSec = Color(0xFF6B5D54);
  static const textMuted = Color(0xFF9A8B80);
  static const border = Color(0xFFE8E0D5);

  // ── 分镜卡专用（v469 slate系）──
  static const shotBg = Color(0xFFF8FAFC);
  static const shotBorder = Color(0xFFE2E8F0);
  static const shotBadgeBg = Color(0xFFE2E8F0);
  static const shotBadgeFg = Color(0xFF0F172A);

  /// 镜头类型色（v469 shTypeColors，8类+默认）
  static Color shotTypeColor(String? type) {
    switch (type ?? '') {
      case '动作':
        return const Color(0xFF1E40AF);
      case '外貌':
        return const Color(0xFF6B21A8);
      case '信息投放':
        return const Color(0xFF92400E);
      case '对话':
        return const Color(0xFF0F766E);
      case '心理':
        return const Color(0xFFBE185D);
      case '评价':
        return const Color(0xFFB45309);
      case '环境':
        return const Color(0xFF0D9488);
      case '转场':
        return const Color(0xFF475569);
      default:
        return const Color(0xFF475569);
    }
  }

  /// 字段级图标+颜色（v469 formatWBContent的label匹配表，全18项）
  /// 返回(icon, color)，未匹配返回(null, textSec)
  static (String, Color) fieldStyle(String label) {
    final l = label.trim();
    if (_m(l, ['焦点', 'focus'])) return ('🎯', const Color(0xFF1E40AF));
    if (_m(l, ['镜头', 'shot'])) return ('🎬', const Color(0xFF475569));
    if (_m(l, ['视角', 'pov'])) return ('👁', const Color(0xFF3730A3));
    if (_m(l, ['投放', 'info'])) return ('📋', const Color(0xFF475569));
    if (_m(l, ['意图', 'intent'])) return ('💡', const Color(0xFF92400E));
    if (_m(l, ['转场', 'transition'])) return ('✂️', const Color(0xFF0F766E));
    if (_m(l, ['篇幅', 'length'])) return ('📏', const Color(0xFF7C3AED));
    if (_m(l, ['文笔节奏', 'prose_style', '文笔']))
      return ('✍', const Color(0xFFDB2777));
    if (_m(l, ['语感', 'voice'])) return ('🎙', const Color(0xFFB45309));
    if (_m(l, ['笔墨', 'ink'])) return ('🖌', const Color(0xFF0369A1));
    if (_m(l, ['角色', '人物', 'char'])) return ('👤', const Color(0xFF6B21A8));
    if (_m(l, ['冲突', 'conflict'])) return ('⚔️', const Color(0xFFDC2626));
    if (_m(l, ['伏笔', 'foreshadow'])) return ('🌱', const Color(0xFF16A34A));
    if (_m(l, ['弧线', 'arc'])) return ('📖', const Color(0xFF3B82F6));
    if (_m(l, ['不可逆', 'irreversible'])) return ('💎', const Color(0xFF7C3AED));
    if (_m(l, ['情绪', 'emotion'])) return ('📈', const Color(0xFFF59E0B));
    if (_m(l, ['脑洞', 'fantasy'])) return ('🧠', const Color(0xFFF59E0B));
    if (_m(l, ['概述', 'summary'])) return ('📝', const Color(0xFF475569));
    if (_m(l, ['世界观设定', 'worldbuilding']))
      return ('🌐', const Color(0xFF8B5CF6));
    // 10体系（世界书弧线总结）：统一绿色系
    if (_m(l, ['经济', '货币', '物价'])) return ('💰', const Color(0xFF16A34A));
    if (_m(l, ['修炼', '境界'])) return ('⚔️', const Color(0xFF16A34A));
    if (_m(l, ['功法', '技能', '武学'])) return ('📖', const Color(0xFF16A34A));
    if (_m(l, ['社会', '政治', '阶层'])) return ('👥', const Color(0xFF16A34A));
    if (_m(l, ['地理', '地图'])) return ('🗺️', const Color(0xFF16A34A));
    if (_m(l, ['法宝', '物品', '装备', '炼器']))
      return ('🏷️', const Color(0xFF16A34A));
    if (_m(l, ['丹药', '灵草', '炼丹'])) return ('🧪', const Color(0xFF16A34A));
    if (_m(l, ['种族', '生物', '妖兽', '魔兽'])) return ('🧬', const Color(0xFF16A34A));
    if (_m(l, ['组织', '势力', '门派', '宗门']))
      return ('🏛️', const Color(0xFF16A34A));
    if (_m(l, ['历史', '传说', '预言', '禁忌'])) return ('📜', const Color(0xFF16A34A));
    if (_m(l, ['场景', 'scene'])) return ('🎬', const Color(0xFF3B82F6));
    if (_m(l, ['钩子', 'hook'])) return ('🪝', const Color(0xFF92400E));
    if (_m(l, ['爽点', 'satisfaction'])) return ('⚡', const Color(0xFF15803D));
    if (_m(l, ['期待', 'expectation'])) return ('🎯', const Color(0xFF6B21A8));
    if (_m(l, ['功能', 'abstract'])) return ('🧩', const Color(0xFF0F766E));
    if (_m(l, ['正文', 'content'])) return ('✍', const Color(0xFFB45309));
    return ('▸', textSec);
  }

  static bool _m(String label, List<String> keys) {
    final lower = label.toLowerCase();
    for (final k in keys) {
      if (label.contains(k) || lower.contains(k.toLowerCase())) return true;
    }
    return false;
  }

  /// 标签归一化：投放信息(Info) → 投放信息/Info（英文括号转斜杠规范格式）
  /// 英文以AI输出为准，不渲染层补
  static String _normLabel(String raw) {
    final l = raw.trim();
    final pm = RegExp(r'^(.{1,20}?)\s*[(（]([A-Za-z][A-Za-z /]{1,24})[)）]$')
        .firstMatch(l);
    if (pm == null) return l;
    return '${pm.group(1)}/${pm.group(2)}';
  }

  /// 徽章widget（v469 pill样式：小圆角+浅底+深字）
  static Widget badge(
    String text,
    Color fg,
    Color bg, {
    double fontSize = 10.5,
    EdgeInsets? padding,
  }) {
    return Container(
      padding:
          padding ?? const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: fontSize,
          fontWeight: FontWeight.w500,
          color: fg,
        ),
      ),
    );
  }

  /// 小节标题（v469 arc-meta-title：加粗小字+分隔线）
  static Widget sectionTitle(String text) {
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 4),
      child: Row(
        children: [
          Text(
            text,
            style: const TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w700,
              color: accent,
              letterSpacing: 0.5,
            ),
          ),
          const SizedBox(width: 6),
          const Expanded(child: Divider(height: 1, color: Color(0x338B6914))),
        ],
      ),
    );
  }

  /// 把多行文本渲染成字段级着色的Span列表（v469 formatWBContent的Flutter版）
  /// 识别"标签：值"行（含##前缀/-前缀/**粗体**），标签部分套图标+颜色
  static List<InlineSpan> contentSpans(String text, {double fontSize = 12.5}) {
    final spans = <InlineSpan>[];
    final lines = text.split('\n');
    for (var i = 0; i < lines.length; i++) {
      if (i > 0) spans.add(const TextSpan(text: '\n'));
      var line = lines[i];
      var t = line.trimLeft();
      // 剥离markdown前缀：## 标题 / - 列表 / **粗体标签**
      var isHeader = false;
      final hdr = RegExp(r'^#{1,4}\s+(.+)').firstMatch(t);
      if (hdr != null) {
        t = hdr.group(1)!.trim();
        isHeader = true;
      }
      t = t.replaceFirst(RegExp(r'^[-*]\s+'), '');
      final bold = RegExp(r'^\*\*(.+?)\*\*\s*[：:]?\s*(.*)$').firstMatch(t);
      if (bold != null) {
        final label = bold.group(1)!.trim();
        final rest = bold.group(2) ?? '';
        final (icon, color) = fieldStyle(label);
        spans.add(
          TextSpan(
            text: '$icon ',
            style: TextStyle(fontSize: fontSize, color: color),
          ),
        );
        spans.add(
          TextSpan(
            text: '$label${rest.isEmpty ? '' : '：'}',
            style: TextStyle(
              fontSize: fontSize,
              fontWeight: FontWeight.w700,
              color: color,
            ),
          ),
        );
        if (rest.isNotEmpty) {
          spans.add(_restSpans(rest, fontSize, isHeader));
        }
        continue;
      }
      // 【分镜N】维度串行（推演模式世界书格式）：拆成一行一维度，带图标色标方便对照取舍
      final shotLine = RegExp(r'^【?分[镜头]?\s*(\d+)\s*[：:】]\]?\s*(.*)$')
          .firstMatch(t);
      if (shotLine != null) {
        final sNum = shotLine.group(1)!;
        final sRest = (shotLine.group(2) ?? '').trim();
        spans.add(
          TextSpan(
            text: '【分镜$sNum】',
            style: TextStyle(
              fontSize: fontSize,
              fontWeight: FontWeight.w700,
              color: accent,
            ),
          ),
        );
        if (sRest.isNotEmpty) {
          // 分镜行内文本（v153新格式sRest为空；有内容=AI没按格式，纯文本展示）
          spans.add(
            TextSpan(
              text: ' $sRest',
              style: TextStyle(fontSize: fontSize - 1),
            ),
          );
        }
        continue;
      }
      // 体系行（AI输出格式）："图标 [体系名] 描述（功能：xxx）:展开说明"
      // 渲染：图标+体系名+描述（含展开）=体系绿同色；功能另起一行弱化色
      final sysLine = RegExp(
        r'^[^\u4e00-\u9fa5]{0,8}?\s*\[?\s*(经济体系|修炼境界体系|功法[/·]?技能体系|社会[/·]?政治体系|地理[/·]?世界体系|法宝物品体系|丹药灵草体系|种族生物体系|组织势力体系|历史传说体系)\s*\]?\s*(.*)$',
      ).firstMatch(t);
      if (sysLine != null) {
        final sysName = sysLine.group(1)!;
        var rest = sysLine.group(2)!.trim();
        final (icon, color) = fieldStyle(sysName);
        // 提取功能（括号内"功能：xxx"，行中任意位置）
        var func = '';
        final fm2 = RegExp(r'[（(]\s*功能[：:]\s*([^（()）]{1,60}?)[)）]')
            .firstMatch(rest);
        if (fm2 != null) {
          func = fm2.group(1)!.trim();
          rest = (rest.substring(0, fm2.start) + ' ' + rest.substring(fm2.end))
              .trim();
        }
        rest = rest
            .replaceFirst(RegExp(r'^[：:]\s*'), '')
            .replaceFirst(RegExp(r'\s*[：:]\s*$'), '')
            .replaceAll(RegExp(r'\s{2,}'), ' ')
            .trim();
        spans.add(
          TextSpan(
            text: '$icon ',
            style: TextStyle(fontSize: fontSize, color: color),
          ),
        );
        spans.add(
          TextSpan(
            text: '[$sysName] ',
            style: TextStyle(
              fontSize: fontSize,
              fontWeight: FontWeight.w700,
              color: color,
            ),
          ),
        );
        spans.add(
          TextSpan(
            text: rest,
            style: TextStyle(fontSize: fontSize, color: textMain),
          ),
        );
        if (func.isNotEmpty) {
          spans.add(
            TextSpan(
              text: '\n功能：$func',
              style: TextStyle(
                fontSize: fontSize - 1,
                color: textSec,
                fontStyle: FontStyle.italic,
              ),
            ),
          );
        }
        continue;
      }
      // "标签：值"普通行（标签可带英文如"镜头类型/Shot Type"，放宽到25字符）
      final fm = RegExp(r'^([^：:\n]{1,25})[：:]\s*(.+)').firstMatch(t);
      if (fm != null) {
        final label = _normLabel(fm.group(1)!.trim());
        final rest = fm.group(2)!.trim();
        final (icon, color) = fieldStyle(label);
        // 概述行美化（弧线N概述/场景概述）：标签浅蓝底+正文主色
        final isSummary = RegExp(r'概[述说]').hasMatch(label);
        spans.add(
          TextSpan(
            text: '$icon ',
            style: TextStyle(fontSize: fontSize, color: color),
          ),
        );
        spans.add(
          TextSpan(
            text: '$label：',
            style: TextStyle(
              fontSize: fontSize,
              fontWeight: FontWeight.w700,
              color: color,
              backgroundColor: isSummary
                  ? const Color(0xFFDBEAFE).withOpacity(0.6)
                  : null,
            ),
          ),
        );
        if (isSummary) {
          spans.add(
            TextSpan(
              text: rest,
              style: TextStyle(
                fontSize: fontSize,
                color: textMain,
                height: 1.5,
              ),
            ),
          );
        } else if (rest.contains('本弧线未涉及')) {
          // 体系占位行：值也用体系绿（整体绿色观感统一）
          spans.add(
            TextSpan(
              text: rest,
              style: TextStyle(fontSize: fontSize, color: color),
            ),
          );
        } else {
          spans.add(_restSpans(rest, fontSize, isHeader));
        }
        continue;
      }
      // 【xxx】标记头行（九件套标题）：图标+绿色粗体（世界观体系头行同色）
      final headMark = RegExp(r'^【([^】]+)】\s*$').firstMatch(t);
      if (headMark != null) {
        final (icon, hColor) = fieldStyle(headMark.group(1)!);
        spans.add(
          TextSpan(
            text: '$icon ${headMark.group(1)}',
            style: TextStyle(
              fontSize: fontSize,
              fontWeight: FontWeight.w700,
              color: hColor,
            ),
          ),
        );
        continue;
      }
      // 纯文本行（行内**粗体**解析）
      spans.add(_restSpans(t.isEmpty ? ' ' : t, fontSize, isHeader));
    }
    return spans;
  }

  /// 剩余值部分：行内**粗体**转span
  static InlineSpan _restSpans(String s, double fontSize, bool isHeader) {
    final parts = s.split(RegExp(r'\*\*(.+?)\*\*'));
    if (parts.length == 1) {
      return TextSpan(
        text: s,
        style: TextStyle(
          fontSize: fontSize,
          color: isHeader ? textMain : textSec,
          fontWeight: isHeader ? FontWeight.w600 : FontWeight.w400,
        ),
      );
    }
    final children = <InlineSpan>[];
    // split交替：偶数位普通、奇数位粗体
    for (var i = 0; i < parts.length; i++) {
      if (parts[i].isEmpty) continue;
      children.add(
        TextSpan(
          text: parts[i],
          style: TextStyle(
            fontSize: fontSize,
            color: isHeader ? textMain : textSec,
            fontWeight: (i.isOdd || isHeader)
                ? FontWeight.w600
                : FontWeight.w400,
          ),
        ),
      );
    }
    return TextSpan(children: children);
  }
}
