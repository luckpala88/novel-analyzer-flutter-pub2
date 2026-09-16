import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';
import '../models/arc.dart';
import '../models/scene.dart';
import '../models/world_book.dart';
import '../utils/v469_style.dart';
import '../utils/prompt_builder.dart';
import '../utils/json_repair.dart';
import '../utils/prompt_preview.dart';
import '../utils/text_cleaner.dart';
import '../widgets/api_config_panel.dart';
import '../widgets/api_log_panel.dart';
import '../widgets/v119_ui.dart';
import '../widgets/content_font.dart';

/// 改编页 — 照抄v468 adapt-card
/// 生成侧：全局改编要求 + 弧线列表（状态+要求+场景单独改编）+ 一键生成/直写/自定义条目
/// 上：⚙API设置 + 全局改编要求 + 一键生成（增量/全量）
/// 中：弧线列表（每弧线：状态徽标 + 独立改编要求 + 场景列表（可单独改编））
/// 下：自定义条目 + 条目预览（可折叠查看/编辑/删除）
class AdaptPage extends StatefulWidget {
  const AdaptPage({super.key});

  @override
  State<AdaptPage> createState() => _AdaptPageState();
}

class _AdaptPageState extends State<AdaptPage>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true; // 页面滑出PageView时保持State：生成任务不中断/表单不清空

  bool _isGenerating = false;
  bool _abort = false;
  String _statusText = '';
  final List<String> _logs = [];
  final _reqController = TextEditingController();
  final _bibleController = TextEditingController(); // v566：改编圣经
  // 展开的弧线 key（arc number string）
  final Set<String> _expandedArcs = {};
  // 就地编辑状态（替代弹窗）
  String? _editingUid;
  final _editContentCtrl = TextEditingController();
  final _editCommentCtrl = TextEditingController();
  final _editKeyCtrl = TextEditingController();

  @override
  void dispose() {
    _reqController.dispose();
    _bibleController.dispose();
    _editContentCtrl.dispose();
    _editCommentCtrl.dispose();
    _editKeyCtrl.dispose();
    super.dispose();
  }

  /// 从AI返回的JSON提取entries[0].content（场景框架/分镜填充用）
  /// 框架提取：v256按API模式分支（json严格解析/兼容纯文本容错，
  /// 不做混合兼容）。出口剥九件套夹带（v250：AI把arcContext里的
  /// 【世界观设定】等复制进输出=重复标记注入点）
  String _extractContentFromJson(String aiText, {bool jsonMode = false}) {
    final strip = (String s) => _stripStructBlocks(s);
    var t = aiText.trim();
    final fence = RegExp(r'^```(?:json)?\s*([\s\S]*?)\s*```$').firstMatch(t);
    if (fence != null) t = fence.group(1)!;

    if (jsonMode) {
      // json模式：严格JSON——entries[0].content或content字段
      try {
        final start = t.indexOf('{');
        final end = t.lastIndexOf('}');
        if (start >= 0 && end > start) {
          final json = jsonDecode(t.substring(start, end + 1));
          if (json is Map) {
            final entries = json['entries'];
            if (entries is List &&
                entries.isNotEmpty &&
                entries.first is Map) {
              return strip(
                (entries.first as Map)['content']?.toString() ?? '',
              );
            }
            final c = json['content'];
            if (c is String && c.trim().isNotEmpty) return strip(c.trim());
          }
        }
        // 截断JSON→JsonRepair栈式修复
        final json = JsonRepair.parseResponse(t);
        if (json != null) {
          final entries = json['entries'];
          if (entries is List &&
              entries.isNotEmpty &&
              entries.first is Map) {
            return strip(
              (entries.first as Map)['content']?.toString() ?? '',
            );
          }
          final c = json['content'];
          if (c is String && c.trim().isNotEmpty) return strip(c.trim());
        }
      } catch (_) {}
      // 解不出=格式坏，返回空交上层判定（框架解析失败日志+重试）
      return '';
    }

    // 兼容模式：纯文本容错（围栏在函数头已剥；前导说明行+字面\n+形态拆解）
    final fn = t.indexOf('\n');
    if (fn > 0) {
      final fl = t.substring(0, fn).trim();
      if (fl.isNotEmpty &&
          RegExp(r'[：:]\s*$').hasMatch(fl) &&
          !RegExp(r'场景\s*\d+|分[镜头]|概[述说]|【').hasMatch(fl)) {
        t = t.substring(fn + 1).trimLeft();
      }
    }
    if (t.contains(r'\n')) {
      t = t.replaceAll(r'\n', '\n').replaceAll(r'\"', '"');
    }
    t = _splitPairChainLines(t);
    t = _preSplitBracedShots(t);
    t = _canonicalBareLabels(t);
    // 伪JSON/数组/键值对行归一化兜底
    if (t.startsWith('[') ||
        t.startsWith('{') ||
        RegExp(r'^\s*"[^"\n]+"\s*[：:]', multiLine: true).hasMatch(t)) {
      final norm = _normalizeAiStructuredText(t);
      if (norm != null && norm.isNotEmpty) return strip(norm);
    }
    // 纯文本两行（框架的正常形态）
    return t.contains('场景')
        ? strip(t)
        : '';
  }

  /// 弧线条目定位（该弧线的第一条无sceneTag条目=弧线总结条目）
  String? _arcEntryKey(AppState state, String arcKey) {
    String? targetKey;
    state.worldBook?.entries.forEach((k, e) {
      if (e.arcKey == arcKey && (e.sceneTag == null || e.sceneTag!.isEmpty)) {
        targetKey ??= k;
      }
    });
    return targetKey;
  }

  /// v250：剥框架/填充输出夹带的九件套标记块——阶段B框架的user prompt带
  /// arcContext（总结全文含九件套）当参照，AI会顺手把【世界观设定】等
  /// 复制进框架输出（用户实测：总结条目刚生成时标记唯一，生成场景框架
  /// 时才多出来）。框架本该只有场景头+概述两行，标记行+块体整段删
  String _stripStructBlocks(String t) {
    if (!_kStructMarks.any((m) => t.contains(m))) return t;
    final lines = t.split('\n');
    final out = <String>[];
    var skipping = false;
    for (final raw in lines) {
      final lt = raw.trim();
      if (_kStructMarks.any((m) => lt.contains(m))) {
        skipping = true; // 标记行删，进入跳过态
        continue;
      }
      if (skipping) {
        if (RegExp(r'^场景\s*\d+\s*[：:]').hasMatch(lt)) {
          skipping = false; // 下个场景头终止跳过
          out.add(raw);
          continue;
        }
        continue; // 标记块体行跳过
      }
      out.add(raw);
    }
    return out.join('\n');
  }

  /// 弧线条目content追加场景框架（插到九件套【世界观设定】前）
  bool _appendSceneToArcEntry(
    AppState state,
    String arcKey,
    String sceneFrame,
  ) {
    final targetKey = _arcEntryKey(state, arcKey);
    if (targetKey == null) return false;
    final entry = state.worldBook!.entries[targetKey]!;
    // v250：先剥AI夹带的九件套标记块（框架插入=重复标记注入点）
    final sceneFrame2 = _stripStructBlocks(sceneFrame);
    if (sceneFrame2.trim().isEmpty) return false;
    final content = entry.content;
    final tailRe = RegExp(
      r'【世界观设定】|【人设】|【矛盾冲突】|【伏笔】|【弧线功能】|【不可逆变化】|【情绪曲线】|【作者脑洞】',
    );
    final tailMatch = tailRe.firstMatch(content);
    if (tailMatch != null) {
      final head = content.substring(0, tailMatch.start);
      final tail = content.substring(tailMatch.start);
      entry.content = TextCleaner.stripDecorativeEmoji(
        '$head$sceneFrame2\n$tail',
      );
    } else {
      entry.content = TextCleaner.stripDecorativeEmoji('$content\n$sceneFrame2');
    }
    return true;
  }

  /// 从弧线条目content取场景si的块（场景头到下一个场景头或九件套前）——阶段C的参照
  /// v215→v216：从弧线总结条目content提取"场景区之外的全部"——
  /// 弧线新概述+新世界观+新人设卡+新冲突+新伏笔+新功能+新变化+新情绪曲线。
  /// 这些是改编后的既成事实，阶段B（场景框架）与阶段C（分镜填充）都必须
  /// 在其上生长（自我投喂：总结→场景→分镜逐级继承）
  String _castFromArcEntry(AppState state, String arcKey) {
    final targetKey = _arcEntryKey(state, arcKey);
    if (targetKey == null) return '';
    final content = state.worldBook!.entries[targetKey]!.content;
    // 场景区=第一个"场景N："到最后一个"场景N："块；之前=弧线概述，之后=九件套
    final sceneRe = RegExp(r'场景\s*\d+\s*[：:]');
    final firstScene = sceneRe.firstMatch(content);
    String before = '', after = '';
    if (firstScene == null) {
      // 没有场景块（阶段A刚生成）：整条都是总结
      return content.trim();
    }
    before = content.substring(0, firstScene.start).trim();
    // 最后一个场景块结束位置=九件套首个【】标记
    final tailRe = RegExp(
      r'【世界观设定】|【人设】|【矛盾冲突】|【伏笔】|【弧线功能】|【不可逆变化】|【情绪曲线】|【作者脑洞】',
    );
    final tail = tailRe.firstMatch(content.substring(firstScene.start));
    if (tail != null) {
      after = content
          .substring(firstScene.start + tail.start)
          .trim();
    }
    return [before, after].where((x) => x.isNotEmpty).join('\n');
  }

  String _sceneBlockFromArcEntry(AppState state, String arcKey, int sceneIdx) {
    final targetKey = _arcEntryKey(state, arcKey);
    if (targetKey == null) return '';
    final content = state.worldBook!.entries[targetKey]!.content;
    final sceneRe = RegExp('场景\\s*${sceneIdx + 1}\\s*[：:]');
    final thisMatch = sceneRe.firstMatch(content);
    if (thisMatch == null) return '';
    final nextRe = RegExp(
      r'场景\s*\d+\s*[：:]|【世界观设定】|【人设】|【矛盾冲突】|【伏笔】|【弧线功能】|【不可逆变化】|【情绪曲线】|【作者脑洞】',
    );
    Iterable<RegExpMatch> _matchesAfter(RegExp re, String s, int from) =>
        re.allMatches(s).where((m) => m.start >= from);
    final nextMatch = _matchesAfter(nextRe, content, thisMatch.end).isEmpty
        ? null
        : _matchesAfter(nextRe, content, thisMatch.end).first;
    final end = nextMatch?.start ?? content.length;
    return content.substring(thisMatch.start, end).trim();
  }

  /// 分镜填充结果替换弧线条目里的场景si块
  bool _replaceSceneBlockInArcEntry(
    AppState state,
    String arcKey,
    int sceneIdx,
    String fillText, {
    String? fallbackSummary,
  }) {
    // v252：剥填充输出夹带的九件套标记块——填充prompt的cast带着九件套
    // 参照，AI会复制进输出（长输出砍尾→复制的份常截断在最后的【笔墨癖好】
    // 前→v250实测：前八件×2、笔墨癖好×1）。fillText必有分镜内容（上层
    // 已检查），strip只去夹带不会全空
    final fillText2 = _stripStructBlocks(fillText);
    final targetKey = _arcEntryKey(state, arcKey);
    if (targetKey == null) return false;
    final entry = state.worldBook!.entries[targetKey]!;
    final content = entry.content;
    final sceneRe = RegExp('场景\\s*${sceneIdx + 1}\\s*[：:]');
    final thisMatch = sceneRe.firstMatch(content);
    if (thisMatch == null) return false;
    final nextRe = RegExp(
      r'场景\s*\d+\s*[：:]|【世界观设定】|【人设】|【矛盾冲突】|【伏笔】|【弧线功能】|【不可逆变化】|【情绪曲线】|【作者脑洞】',
    );
    Iterable<RegExpMatch> _matchesAfter(RegExp re, String s, int from) =>
        re.allMatches(s).where((m) => m.start >= from);
    final nextMatch = _matchesAfter(nextRe, content, thisMatch.end).isEmpty
        ? null
        : _matchesAfter(nextRe, content, thisMatch.end).first;
    final end = nextMatch?.start ?? content.length;
    // v239：head尾JSON残渣清理——v237坏块的{"content":"前缀粘在场景头前
    // （场景头匹配点在残渣行内），替换后残渣留在head尾部污染前一场景块
    var head = content.substring(0, thisMatch.start).replaceFirst(
          RegExp(r'\{"[a-zA-Z_]+"\s*:\s*"\s*$'),
          '',
        );
    final tail = content.substring(end);
    // 保留旧场景块的概述行（阶段B框架产物；分镜填充输出不带概述）
    final oldBlock = content.substring(thisMatch.start, end);
    final oldSummary = RegExp(
      r'^概[述说][：:].*$',
      multiLine: true,
    ).firstMatch(oldBlock)?.group(0);
    // 保留旧场景头的章节范围后缀（阶段B标题带"（第X-Y章）"，分镜填充输出不带）
    // v241：旧头可能带包裹引号（"场景1：xxx"）——容忍引号前缀+剥引号
    final oldHeaderLine = _stripWrapQuotes(
          RegExp(
            // 引号/空白等非中文字符前缀均可容忍（渲染正则同款）
            r'^[^\u4e00-\u9fa5\n]*场景\s*\d+\s*[：:].*$',
            multiLine: true,
          ).firstMatch(oldBlock)?.group(0) ??
              '',
        );
    final chapterSuffix =
        RegExp(r'（[^（）]*第[^（）]*章[^（）]*）\s*$')
            .firstMatch(oldHeaderLine)
            ?.group(0) ??
        '';
    var newContent = fillText2.trim();
    // v239：场景头强制规范化——AI填充输出漂移（首行说明文字/无头直接分镜）
    // 时替换后无独立块头，世界书渲染切块把内容并进前一块尾部（v238实测
    // 场景6"已合并"却看不见）。规范：内容首行必须是"场景N："头
    final headerRe = RegExp(
      r'^[^\u4e00-\u9fa5\n]*场景\s*\d+\s*[：:].*$',
      multiLine: true,
    );
    final headerMatch = headerRe.firstMatch(newContent);
    if (headerMatch == null) {
      // 无规范头：剥首行说明文字（非概述/分镜标记行），重建头（旧头优先）
      var body = newContent;
      final firstNl = body.indexOf('\n');
      // v241：首行剥包裹引号后判定（"分镜1：…"不该被判成说明文字丢弃）
      final firstLine = _stripWrapQuotes(
        (firstNl < 0 ? body : body.substring(0, firstNl)).trim(),
      );
      final firstIsJunk =
          firstLine.isNotEmpty &&
          !RegExp(r'^概[述说][：:]').hasMatch(firstLine) &&
          !RegExp(r'^分[镜头]?\s*\d+').hasMatch(firstLine);
      if (firstIsJunk && firstNl > 0) body = body.substring(firstNl + 1);
      var header = oldHeaderLine.trim();
      if (header.isEmpty) {
        header = '场景${sceneIdx + 1}：';
      } else {
        // v237坏块整块单行（字面\n）时旧头截断到概述/分镜标记前
        final cut = RegExp(
          r'(概[述说][：:]|分[镜头]?\s*\d+)',
        ).firstMatch(header);
        if (cut != null) header = header.substring(0, cut.start).trimRight();
      }
      newContent = '$header\n$body';
    } else {
      // 有规范头：剥头行之前的杂质行（首行说明文字等）
      newContent = newContent.substring(headerMatch.start).trim();
    }
    if (chapterSuffix.isNotEmpty &&
        // v243：修章节范围丢失——旧条件!newContent.contains('第')过宽（万字
        // 填充内容几乎必含"第"字→范围永远不补）。只查场景头行本身
        !RegExp(r'^场景\s*\d+\s*[：:].*章', multiLine: true).hasMatch(newContent)) {
      // 补到新场景头行尾
      final firstNl = newContent.indexOf('\n');
      if (firstNl > 0) {
        final firstLine = newContent.substring(0, firstNl).trimRight();
        newContent =
            '$firstLine$chapterSuffix\n${newContent.substring(firstNl + 1)}';
      } else {
        newContent = '$newContent$chapterSuffix';
      }
    }
    final hasSummary = RegExp(
      r'^概[述说][：:]',
      multiLine: true,
    ).hasMatch(newContent);
    if (!hasSummary) {
      // 概述来源：旧块概述行优先，被吞掉时从分析数据scene.summary兜底
      final sumLine =
          oldSummary ??
          (fallbackSummary?.trim().isNotEmpty == true
              ? '概述：${fallbackSummary!.trim()}'
              : null);
      if (sumLine != null) {
        // 插到场景标题行后（填充结果首行=场景N：标题）
        final firstNl = newContent.indexOf('\n');
        newContent = firstNl < 0
            ? '$newContent\n$sumLine'
            : '${newContent.substring(0, firstNl + 1)}'
                  '$sumLine\n'
                  '${newContent.substring(firstNl + 1)}';
      }
    }
    entry.content = TextCleaner.stripDecorativeEmoji('$head$newContent\n$tail');
    return true;
  }

  /// v239：清扫v237/v238遗留污染——坏块的JSON残渣（{"content":）粘在
  /// 前一场景块尾部，其后跟着无头填充内容（无独立场景头，世界书渲染时
  /// 整段并入前一块，用户看到的"场景6消失"）。从残渣处截断到下一个
  /// 规范场景头/九件套标记，保留残渣前的正常内容
  /// v240：扩展识别——伪JSON键值对垃圾（"场景"："场景1：…"全角冒号格式，
  /// gemini中转漂移输出）+纯结构行（[ ] { } ,）。循环清理多处垃圾
  void _cleanLegacyDebris(AppState state, String arcKey) {
    final targetKey = _arcEntryKey(state, arcKey);
    if (targetKey == null) return;
    final entry = state.worldBook!.entries[targetKey]!;
    // 残渣形态：①{"任意key"：（含中文key全角冒号，inline/行首均可）
    // ②行首"key"：键值对行 ③纯结构行[ ] { } ,（至少一个括号字符——
    // 空白不算，防止空行误判删掉正常场景块）
    final debrisRe = RegExp(
      r'\{"[^"]*"\s*[：:]\s*"|^"[^"]*"\s*[：:]|^[\[\]{}(),\s]*[\[\]{}(),][\[\]{}(),\s]*$',
      multiLine: true,
    );
    final nextRe = RegExp(r'^场景\s*\d+\s*[：:]|^【', multiLine: true);
    var cleaned = 0;
    var guard = 0;
    while (guard++ < 20) {
      final content = entry.content;
      final d = debrisRe.firstMatch(content);
      if (d == null) break;
      final nm = nextRe
          .allMatches(content)
          .where((m) => m.start >= d.end)
          .toList();
      final end = nm.isEmpty ? content.length : nm.first.start;
      // 保护：一次清扫量超过全文90%=整条都是垃圾（异常，不删避免误杀）
      if (end - d.start > content.length * 0.9) break;
      final before = content.substring(0, d.start);
      final after = content.substring(end);
      entry.content = '${before.trimRight()}\n$after'.trim() + '\n';
      cleaned += end - d.start;
    }
    if (cleaned > 0) {
      _addLog('已清扫历史遗留污染数据（JSON残渣/伪JSON键值对，共$cleaned字）');
    }
    // v241：美容通道——场景头带包裹引号但内容完整（"场景1：xxx"有分镜）
    // 的行不删内容，只剥首尾引号（用户实测场景1头带""但48分镜完好）
    var stripped = 0;
    final outLines = <String>[];
    for (final raw in entry.content.split('\n')) {
      final t = raw.trim();
      if (RegExp(r'^["\u201c\u201d]+').hasMatch(t)) {
        final t2 = _stripWrapQuotes(t);
        final isStruct =
            RegExp(r'^场景\s*\d+\s*[：:]|^分[镜头]?\s*\d+|^概[述说][：:]')
                .hasMatch(t2);
        if (isStruct) {
          outLines.add(t2);
          stripped++;
          continue;
        }
      }
      outLines.add(raw);
    }
    if (stripped > 0) {
      entry.content = outLines.join('\n');
      _addLog('已剥除$stripped行场景头包裹引号');
    }
    // v243：格式修复——【分镜N】{…}块拆行/裸键值对规范化/场景头补章节
    // 范围（从arcScenes数据），就地自愈不删内容
    var repaired = 0;
    var fixedContent = entry.content;
    final pre = _preSplitBracedShots(fixedContent);
    if (pre != fixedContent) {
      fixedContent = pre;
      repaired++;
    }
    final canon = _canonicalBareLabels(fixedContent);
    if (canon != fixedContent) {
      fixedContent = canon;
      repaired++;
    }
    // 场景头缺章节范围→从场景数据补（第N场景→scenes[N-1].chapterRange）
    final scenes =
        state.arcScenes[arcKey] ?? state.arcAnalyses[arcKey]?.scenes ?? const <Scene>[];
    final fixedLines = <String>[];
    for (final raw in fixedContent.split('\n')) {
      final t = raw.trim();
      final m = RegExp(r'^[^\u4e00-\u9fa5\n]*场景\s*(\d+)\s*[：:](.*)$')
          .firstMatch(t);
      if (m != null && !RegExp(r'第[^（）]{0,8}章').hasMatch(t)) {
        final no = int.tryParse(m.group(1)!) ?? 0;
        final idx = no - 1;
        if (idx >= 0 && idx < scenes.length) {
          final cr = scenes[idx].chapterRange.trim();
          if (cr.isNotEmpty && RegExp(r'第.*章').hasMatch(cr)) {
            fixedLines.add('${t.trimRight()}（$cr）');
            repaired++;
            continue;
          }
        }
      }
      fixedLines.add(raw);
    }
    if (repaired > 0) {
      entry.content = fixedLines.join('\n');
      _addLog('已修复格式问题（分镜块拆行/标签规范化/章节范围补齐）');
    }
    // v245：九件套结构段去重（已入库数据的重复【世界观设定】标记自愈）
    // v246：变体标记归一（裸/emoji前缀标记行→【标准】）+pair链拆解
    var fixed2 = _splitPairChainLines(entry.content);
    final deduped = _dedupeStructSections(fixed2);
    if (deduped != entry.content) {
      entry.content = deduped;
      _addLog('已去重九件套重复标记块');
    }
    // v245：'功能: xxx'短写规范化（体系块功能行→'功能抽象：xxx'）
    entry.content = entry.content.replaceAllMapped(
      RegExp(r'^功能\s*[：:]\s*(.+)$', multiLine: true),
      (m) => '功能抽象：${m.group(1)!.trim()}',
    );
    // v249：空块检测——九件套标记块体为空（v246防重复指令被AI字面执行
    // 只输出标记行省内容）→删空标记行+日志提示（增量模式跳过阶段A，
    // 空块不会自愈，必须提示用户重新生成总结）
    final contentLines = entry.content.split('\n');
    final emptyMarkNames = <String>[];
    final emptyMarkLineIdx = <int>{};
    for (var i = 0; i < contentLines.length; i++) {
      final t = contentLines[i].trim();
      String? mk;
      for (final m in _kStructMarks) {
        if (t.startsWith(m)) {
          mk = m;
          break;
        }
      }
      if (mk == null) continue;
      // 块体=标记行到下个标记/场景头/文末
      var j = i + 1;
      while (j < contentLines.length) {
        final lt = contentLines[j].trim();
        if (_kStructMarks.any((m) => lt.startsWith(m)) ||
            RegExp(r'^场景\s*\d+\s*[：:]').hasMatch(lt)) {
          break;
        }
        j++;
      }
      final bodyEmpty = contentLines
          .sublist(i + 1, j)
          .join('')
          .trim()
          .isEmpty;
      if (bodyEmpty && !emptyMarkNames.contains(mk)) {
        emptyMarkNames.add(mk);
        emptyMarkLineIdx.add(i);
      }
    }
    if (emptyMarkLineIdx.isNotEmpty) {
      final kept = <String>[];
      for (var i = 0; i < contentLines.length; i++) {
        if (!emptyMarkLineIdx.contains(i)) kept.add(contentLines[i]);
      }
      entry.content = kept.join('\n');
      _addLog(
        '⚠️ 弧线总结缺${emptyMarkNames.length}个结构块内容'
        '（${emptyMarkNames.join('/')}）——建议对该弧线取消增量重新生成总结',
      );
    }
  }

  /// 日志预览：内容前80字（换行转空格）
  String _preview(String s) {
    final t = s.trim().replaceAll('\n', ' ');
    return t.length > 80 ? t.substring(0, 80) : t;
  }

  /// v245：九件套结构段去重——AI漂移输出重复【标记】行（用户实测【世界观
  /// 设定】出现两次，首块空/尾块有内容）。策略：标记行只保留"内容最完整
  /// 的那个块"，其余重复块（标记行+块体到下个标记）整段删除。块边界=同
  /// 一标记的下一个出现处或下一个不同标记处
  /// v246：标记识别扩展到变体形态——裸标记行（"矛盾冲突"/"伏笔"无括号）
  /// +emoji前缀标记行（"🗡️ 矛盾冲突"）+行内式（"矛盾冲突：内容"）。
  /// 先统一归一成【标记】标准形式再去重（用户实测⚔️/🗡️不同emoji重复）
  static const _kStructMarks = [
    '【世界观设定】', '【人设】', '【矛盾冲突】', '【伏笔】', '【弧线功能】',
    '【不可逆变化】', '【情绪曲线】', '【作者脑洞】', '【笔墨癖好】',
  ];

  static const _kStructNames = [
    '世界观设定', '人设', '矛盾冲突', '伏笔', '弧线功能', '不可逆变化',
    '情绪曲线', '作者脑洞', '笔墨癖好',
  ];

  /// 行→规范【标记】。识别：①【名称】标准式 ②任意非中文前缀（emoji/序号
  /// /▸/──等——渲染正则同款容忍度）+裸名称纯标记行（可带尾冒号）
  /// ③名称：内容 行内式——仅非场景态（场景体内的"人设：xxx"正文行不误转，
  /// 防【人设】标记截断场景块）
  /// v251：前缀剥离从"只剥emoji"升级为"剥所有非中文字符前缀"——AI输出的
  /// "▸ 矛盾冲突：/1. 伏笔/📖 弧线功能"等带前缀变体此前全部匹配失败，
  /// v245/v246/v249的去重+空块清理对此类行集体空转（用户v249实测）
  static List<String> _normalizeStructLine(String raw, {bool allowInline = true}) {
    final t = raw.trim();
    if (t.isEmpty) return [raw];
    for (final n in _kStructNames) {
      if (t.startsWith('【$n】')) return ['【$n】'];
    }
    // 剥行首任意非中文前缀（emoji/序号/符号——对齐渲染_isTailSection容忍度）
    final t2 = t.replaceFirst(RegExp(r'^[^\u4e00-\u9fa5\n]+'), '').trim();
    for (final n in _kStructNames) {
      // 纯标记行（可带尾冒号）——总是归一
      if (RegExp('^$n\\s*[：:]?\\s*\$').hasMatch(t2)) return ['【$n】'];
      // 行内式：名称：内容 → 拆成标记行+内容行（仅非场景态）
      if (allowInline) {
        final m = RegExp('^$n\\s*[：:]\\s*(.+)\$').firstMatch(t2);
        if (m != null && m.group(1)!.trim().isNotEmpty) {
          return ['【$n】', m.group(1)!.trim()];
        }
      }
    }
    return [raw];
  }

  String _dedupeStructSections(String content) {
    // v246.1：状态机归一——场景头进入场景态（行内式不转），【标记】行退出
    // 场景态进入尾部（emoji变体纯标记行总是归一，用户实测⚔️/🗡️重复形态）
    final rawLines = content.split('\n');
    var lines = <String>[];
    var inScene = false;
    for (final raw in rawLines) {
      final t = raw.trim();
      if (RegExp(r'^场景\s*\d+\s*[：:]').hasMatch(t)) {
        inScene = true;
        lines.add(raw);
        continue;
      }
      final norm = _normalizeStructLine(raw, allowInline: !inScene);
      lines.addAll(norm);
      final first = norm.first.trim();
      if (_kStructMarks.any((m) => first.startsWith(m))) {
        inScene = false;
      }
    }
    Map<String, List<int>> collect() {
      final m = <String, List<int>>{};
      for (var i = 0; i < lines.length; i++) {
        for (final mk in _kStructMarks) {
          if (lines[i].trim().startsWith(mk)) {
            m.putIfAbsent(mk, () => []).add(i);
          }
        }
      }
      return m;
    }

    final markLineIdx = collect();
    final dupMarks = markLineIdx.keys
        .where((k) => (markLineIdx[k] ?? []).length > 1)
        .toList();
    if (dupMarks.isEmpty) {
      // 无重复也要返回归一化结果（变体已转标准形式）
      return lines.join('\n');
    }

    var changed = false;
    // 逐标记处理，每处理一个标记就重控行号（防删除漂移错删）
    for (final mk in dupMarks) {
      final idxs = collect()[mk] ?? [];
      if (idxs.length < 2) continue;
      // 块范围=标记行到下一个任何标记行/场景头/文末
      final blocks = <List<int>>[];
      for (final s in idxs) {
        var e = lines.length;
        for (var j = s + 1; j < lines.length; j++) {
          final lt = lines[j].trim();
          final isMark = _kStructMarks.any((m) => lt.startsWith(m));
          final isScene = RegExp(r'^场景\s*\d+\s*[：:]').hasMatch(lt);
          if (isMark || isScene) {
            e = j;
            break;
          }
        }
        final bodyLen = lines.sublist(s + 1, e).join('').trim().length;
        blocks.add([s, e, bodyLen]);
      }
      // 保留内容最多的块，其余整段删除（标记行+块体）
      var keep = 0;
      for (var b = 1; b < blocks.length; b++) {
        if (blocks[b][2] > blocks[keep][2]) keep = b;
      }
      final toRemove = <int>[];
      for (var b = 0; b < blocks.length; b++) {
        if (b == keep) continue;
        toRemove.addAll(
          List<int>.generate(
            blocks[b][1] - blocks[b][0],
            (k) => blocks[b][0] + k,
          ),
        );
      }
      if (toRemove.isEmpty) continue;
      toRemove.sort((a, b) => b.compareTo(a)); // 倒序删，行号不漂移
      for (final i in toRemove) {
        lines.removeAt(i);
      }
      changed = true;
    }
    return lines.join('\n');
  }

  /// v246：残缺pair链行拆解——'分镜1": "焦点(Focus)": "值'（JSON双冒号
  /// 链被截断）→'分镜1：\n焦点(Focus)：值'。含'": "'或'"："'序列即处理
  static String _splitPairChainLines(String t) {
    final out = <String>[];
    for (final raw in t.split('\n')) {
      final l = raw.trim();
      if (l.contains('": "') || l.contains('"："')) {
        final pieces = l
            .split(RegExp(r'"\s*[：:]\s*"'))
            .map((p) => p.trim())
            .where((p) => p.isNotEmpty)
            .toList();
        if (pieces.length >= 3) {
          // 首段=标记头（分镜N等），中段=标签，尾段=值（剥残引号）
          out.add('${_stripWrapQuotes(pieces.first)}：');
          final val = _stripWrapQuotes(pieces.sublist(2).join('：'));
          out.add('${_stripWrapQuotes(pieces[1])}：$val');
          continue;
        } else if (pieces.length == 2) {
          out.add(
            '${_stripWrapQuotes(pieces[0])}：${_stripWrapQuotes(pieces[1])}',
          );
          continue;
        }
      }
      out.add(raw);
    }
    return out.join('\n');
  }

  /// 世界观10体系校验补齐：条目content的【世界观设定】块缺哪个体系补占位行
  /// （AI长输出砍尾部维度老毛病——代码兜底保证结构完整）
  void _ensureWorldbuildingSystems(AppState state, String arcKey) {
    const systems = [
      '经济体系',
      '修炼境界体系',
      '功法技能体系',
      '社会政治体系',
      '地理世界体系',
      '法宝物品体系',
      '丹药灵草体系',
      '种族生物体系',
      '组织势力体系',
      '历史传说体系',
    ];
    final wb = state.worldBook;
    if (wb == null) return;
    for (final e in wb.entries.values) {
      if (e.arcKey != arcKey) continue;
      if (e.sceneTag != null && e.sceneTag!.isNotEmpty) continue;
      final content = e.content;
      final wbMatch = RegExp('【世界观设定】').firstMatch(content);
      if (wbMatch == null) continue;
      // v245：先去重（重复【世界观设定】标记会让补齐位置算错叠加占位行）
      final deduped = _dedupeStructSections(content);
      final content2 = deduped == content ? content : deduped;
      if (deduped != content) {
        e.content = content2;
        state.saveWorldBook();
      }
      final wbMatch2 = RegExp('【世界观设定】').firstMatch(content2);
      if (wbMatch2 == null) continue;
      // 体系块边界：到下一个【xxx】标记或文末
      final nextRe = RegExp(r'【[^】]+】');
      final nm = nextRe
          .allMatches(content2)
          .where((m) => m.start > wbMatch2.end)
          .toList();
      final blockEnd = nm.isEmpty ? content2.length : nm.first.start;
      final block = content2.substring(wbMatch2.end, blockEnd);
      // 找缺失体系
      final missing = systems.where((s) => !block.contains(s)).toList();
      if (missing.isEmpty) continue;
      // 追加占位行到体系块尾
      final sb = StringBuffer(block.trimRight());
      for (final s in missing) {
        sb.writeln();
        sb.write('- $s：本弧线未涉及');
      }
      e.content =
          content2.substring(0, wbMatch2.end) +
          sb.toString() +
          content2.substring(blockEnd);
      state.saveWorldBook();
      _addLog('✓ 世界观体系补齐${missing.length}个（${missing.join('/')}）');
    }
  }

  /// 分镜填充结果预处理：剥markdown围栏/首尾说明，返回含"分镜"的有效内容（无则原样返回供诊断）
  /// v238：三层容错——①JSON包装（{"content":"…\n…"}）解码取content（\n自动变真换行）
  /// ②JSON截断用JsonRepair栈式修复后再解 ③纯文本但换行被字面量\n转义
  /// （整段无真换行却含\n字面量）→替换为真换行。v237实测AI返回格式波动
  /// （中转常见），字面\n直接透传导致世界书渲染成一行长串
  /// v240：④伪JSON/JSON数组/引号键值对行归一化（gemini中转实测：框架/分镜
  /// 返回"场景"："场景1：…"引号键值对格式，中文key+全角冒号jsonDecode解不了）
  String _extractFillContent(String raw, {bool jsonMode = false}) {
    var t = raw.trim();
    // ```...```围栏包裹
    final fence = RegExp(r'^```[a-zA-Z]*\n([\s\S]*?)\n?```$').firstMatch(t);
    if (fence != null) t = fence.group(1)!.trim();

    // v256：按API模式分支（不做混合兼容——json模式严格JSON解析，
    // 解不出返回原文交上层重试判定；兼容模式走纯文本容错路径）
    if (jsonMode) {
      final decoded = _contentFromJsonLike(t);
      if (decoded.isNotEmpty) return decoded;
      return t;
    }
    // 兼容模式：纯文本容错（围栏/前导说明/字面\n/pair链/花括号连排）
    final closedFence = RegExp(r'^```[a-zA-Z]*\s*\n?([\s\S]*?)\n?```\s*\$').firstMatch(t);
    if (closedFence != null) {
      t = closedFence.group(1)!.trim();
    } else {
      final openFence = RegExp(r'^```[a-zA-Z]*\s*\n?').firstMatch(t);
      if (openFence != null) t = t.substring(openFence.end).trim();
      t = t.replaceFirst(RegExp(r'\n?```\s*\$'), '').trim();
    }
    if (t.contains(r'\n')) {
      t = t.replaceAll(r'\n', '\n').replaceAll(r'\"', '"');
    }
    // 前导说明行（"好的，以下是…"整行冒号结尾且非结构行）
    final fn = t.indexOf('\n');
    if (fn > 0) {
      final fl = t.substring(0, fn).trim();
      if (fl.isNotEmpty &&
          RegExp(r'[：:]\s*\$').hasMatch(fl) &&
          !RegExp(r'场景\s*\d+|分[镜头]|概[述说]|【').hasMatch(fl)) {
        t = t.substring(fn + 1).trimLeft();
      }
    }
    t = _splitPairChainLines(t);
    t = _preSplitBracedShots(t);
    t = _canonicalBareLabels(t);
    // ④伪JSON/JSON数组/引号键值对行→归一化为规范纯文本行
    if (t.startsWith('[') ||
        t.startsWith('{') ||
        RegExp(r'^\s*"[^"\n]+"\s*[：:]', multiLine: true).hasMatch(t)) {
      final norm = _normalizeAiStructuredText(t);
      if (norm != null && norm.isNotEmpty) return norm;
    }
    return t;
  }

  /// v240：AI结构化输出归一化——伪JSON/JSON数组/引号键值对行→规范纯文本行。
  /// 实测漂移形态：[\n概述：xxx\n{\n"场景"："场景1：xxx",\n"分镜"："分镜1",
  /// "焦点"："陆志星",...},\n]（中文key+全角冒号=jsonDecode解不了的伪JSON）。
  /// 归一化输出：场景N：头/概述：/分镜M：/焦点(Focus)：…规范行。
  /// 返回null=不是结构化形态（调用方走原逻辑）
  static const _kLabelMap = {
    '焦点': '焦点(Focus)',
    '镜头类型': '镜头类型(Shot Type)',
    '视角': '视角(POV)',
    '投放信息': '投放信息(Info)',
    '作者意图': '作者意图(Intent)',
    '转场手法': '转场手法(Transition)',
    '篇幅': '篇幅(Length)',
    '文笔节奏': '文笔节奏(Prose Style)',
    '语感': '语感(Voice)',
    '笔墨': '笔墨(Ink)',
    '功能抽象': '功能抽象(Abstract)',
    // v244：AI短写变体（"转场:""投放:""焦点表述"等）
    '转场': '转场手法(Transition)',
    '镜头': '镜头类型(Shot Type)',
    '意图': '作者意图(Intent)',
    '节奏': '文笔节奏(Prose Style)',
    '投放': '投放信息(Info)',
    '信息': '投放信息(Info)',
    '分镜号': '分镜',
  };

  /// v241：剥行/值的包裹引号（直引号+弯引号，含尾逗号）——AI把整行
  /// 用引号包裹的漂移形态（"场景1：xxx"）。只剥首尾包裹层，行中间的
  /// 正常引号（语感例句等）不动
  static String _stripWrapQuotes(String s) {
    var t = s.trim();
    final lead = RegExp(r'^["\u201c\u201d]+');
    if (!lead.hasMatch(t)) return t;
    t = t.replaceFirst(lead, '');
    t = t.replaceFirst(RegExp(r'["\u201c\u201d]+[,，]?$'), '');
    return t.trim();
  }

  /// v243：拆【分镜N】{key: value, key: value}逗号连排块——AI把整个分镜
  /// 压成一行花括号（无引号裸键值对、半角冒号、逗号连排）。拆成：
  /// 分镜N：\n + 每维度一行。只在块内含已知维度标签时才拆（防误伤正文
  /// 花括号）；【分镜N】头同步转规范"分镜N："
  static const _kLabelHints =
      '焦点|镜头|视角|投放|意图|转场|篇幅|文笔|语感|笔墨|功能抽象|概述';

  static String _preSplitBracedShots(String t) {
    var out = t;
    // ①【分镜N】/【镜头N】头 → 规范"分镜N：\n"
    out = out.replaceAllMapped(
      RegExp(r'【\s*分[镜头]?\s*(\d+)\s*[】\]]'),
      (m) => '分镜${m.group(1)}：\n',
    );
    // ②{inner}块（无嵌套花括号且含维度标签）→ 按逗号拆行
    // （逗号后跟"key:"模式才拆，正文逗号不动）
    out = out.replaceAllMapped(RegExp(r'\{([^{}]*)\}'), (m) {
      final inner = m.group(1)!.trim();
      if (inner.isEmpty ||
          !RegExp(_kLabelHints).hasMatch(inner)) {
        return m.group(0)!; // 无维度标签=正常花括号内容，原样保留
      }
      final parts = inner.split(
        RegExp(r',\s*(?=[\u4e00-\u9fa5A-Za-z()（）/、|\s]{1,28}[：:])'),
      );
      return parts.where((p) => p.trim().isNotEmpty).join('\n');
    });
    return out;
  }

  /// v247：剥行尾游离引号——AI漂移给每行值尾带悬空引号（值内引号成对，
  /// 游离引号使计数为奇数）。奇数个且行尾→剥最后一个；尾“，/”，先剥。
  /// 成对引号（语感例句"哪里来的…"）不动
  static String _stripStrayTrailingQuotes(String line) {
    var t = line.trim();
    // 1) 尾部 引号+逗号 组合（“， ”， "，）
    final m1 = RegExp(r'["\u201c\u201d]+\s*[,，]\s*$').firstMatch(t);
    if (m1 != null) t = t.substring(0, m1.start).trimRight();
    // 2) ASCII引号奇数个且行尾是"→剥最后一个（游离）
    if ('"'.allMatches(t).length.isOdd && t.endsWith('"')) {
      t = t.substring(0, t.length - 1).trimRight();
    }
    // 3) 全角引号奇数个且行尾是“/”→剥最后一个
    final fw =
        '\u201c'.allMatches(t).length + '\u201d'.allMatches(t).length;
    if (fw.isOdd && (t.endsWith('\u201c') || t.endsWith('\u201d'))) {
      t = t.substring(0, t.length - 1).trimRight();
    }
    return t;
  }

  /// v243：裸键值对行规范化——"焦点(Focus): v"（半角冒号）→"焦点(Focus)：v"
  /// （标准标签+全角冒号）。只动已知维度标签行（幂等：已规范的行输出不变，
  /// 正文含冒号的行不动）
  /// v247升级：①行尾游离引号剥离 ②斜杠标签（焦点/Focus）③scene：场景N：
  /// 包装行解包 ④"shots"：[垃圾行丢弃 ⑤分镜：分镜N值包装→分镜N：
  static String _canonicalBareLabels(String t) {
    final out = <String>[];
    for (final raw in t.split('\n')) {
      final l = _stripStrayTrailingQuotes(raw);
      // 垃圾行：引号ascii key + [/{ 值（"shots"：[）
      if (RegExp(r'^"?[A-Za-z_]+"?\s*[：:]\s*[\[\{]?\s*$').hasMatch(l)) {
        continue;
      }
      // scene：场景N：xxx 包装行 → 内层规范头
      final sm = RegExp(
        r'^[A-Za-z]+\s*[：:]\s*(场景\s*\d+\s*[：:].*)$',
      ).firstMatch(l);
      if (sm != null) {
        out.add(sm.group(1)!.trim());
        continue;
      }
      final m = RegExp(
        r'^\s*([\u4e00-\u9fa5A-Za-z]+(?:\s*(?:\([^)]*\)|/\s*[A-Za-z ]+))?)\s*([：:])\s*(.+)$',
      ).firstMatch(l);
      if (m == null) {
        if (l.isNotEmpty) out.add(l);
        continue;
      }
      var key = m.group(1)!.trim();
      key = key.replaceFirst(RegExp(r'/\s*[A-Za-z ]+$'), ''); // 剥/English
      final bare = key.replaceFirst(RegExp(r'\s*\([^)]*\)$'), '');
      final val = m.group(3)!.trim();
      // 分镜：分镜N 值包装 → 分镜N：
      final vm = RegExp(r'^分\s*镜\s*(\d+)\s*[：:]?\s*(.*)$').firstMatch(val);
      if (bare == '分镜' && vm != null) {
        out.add('分镜${vm.group(1)}：');
        if (vm.group(2)!.trim().isNotEmpty) out.add(vm.group(2)!.trim());
        continue;
      }
      final canonical = _kLabelMap[bare];
      if (canonical != null) {
        out.add('$canonical：$val');
      } else {
        out.add('$key${m.group(2)}$val'); // 无映射（概述等）：保留原key原冒号
      }
    }
    return out.join('\n');
  }

  String? _normalizeAiStructuredText(String t) {
    // 合法JSON（数组根/entries包装）→重排为键值对行后走行级归一化
    if (t.startsWith('[') || t.startsWith('{')) {
      dynamic json;
      try {
        json = jsonDecode(t);
      } catch (_) {
        json = null;
      }
      if (json != null) {
        List? list;
        if (json is List) list = json;
        if (json is Map) {
          final e = json['entries'] ?? json['scenes'];
          if (e is List) list = e;
        }
        if (list != null && list.isNotEmpty) {
          final sb = StringBuffer();
          for (final item in list) {
            if (item is Map) {
              item.forEach((k, v) => sb.writeln('"$k"："${v.toString().replaceAll('\n', ' ')}"'));
            } else if (item.toString().trim().isNotEmpty) {
              sb.writeln(item);
            }
          }
          t = sb.toString();
        }
      }
    }
    // 行级归一化（伪JSON全角冒号/引号键值对行）
    final pairRe = RegExp(r'^"([^"]+)"\s*[：:]\s*"([^"]*)"\s*,?$');
    final structRe = RegExp(r'^[\[\]{}(),\s]*$');
    final lines = t.split('\n');
    final pairCount = lines.where((l) => pairRe.hasMatch(l.trim())).length;
    if (pairCount < 2) return null; // 不是键值对形态
    final sb = StringBuffer();
    var sceneNo = 0;
    var shotNo = 0;
    String? pendingSummary; // 概述出现在场景头前→挪到头后（规范顺序）
    void emitScene(String header) {
      sb.writeln(header);
      if (pendingSummary != null) {
        sb.writeln(pendingSummary);
        pendingSummary = null;
      }
    }

    for (final raw in lines) {
      final l = raw.trim();
      final m = pairRe.firstMatch(l);
      if (m != null) {
        final key = m.group(1)!.trim();
        // v241：值剥包裹引号（弯引号包裹的"“场景1：xxx”"形态）
        final val = _stripWrapQuotes(m.group(2)!);
        if (key == '场景' || key == '场景名' || key == 'name') {
          sceneNo++;
          shotNo = 0;
          if (RegExp(r'^场景\s*\d+').hasMatch(val)) {
            emitScene(val);
          } else {
            emitScene('场景$sceneNo：$val');
          }
        } else if (key == '概述' || key == 'summary') {
          final line = '概述：$val';
          if (sceneNo == 0) {
            pendingSummary = line;
          } else {
            sb.writeln(line);
          }
        } else if (key == '分镜' || key == 'shot') {
          shotNo++;
          if (RegExp(r'^分镜\s*\d+').hasMatch(val)) {
            sb.writeln(val.contains('：') || val.contains(':') ? val : '$val：');
          } else if (val.isEmpty) {
            sb.writeln('分镜$shotNo：');
          } else {
            sb.writeln('分镜$shotNo：');
            sb.writeln('焦点(Focus)：$val');
          }
        } else if (key == 'content') {
          // 条目壳字段：content内容照搬（多行已被压平），其余壳字段丢弃
          if (val.isNotEmpty) sb.writeln(val);
        } else if (key == 'comment' || key == 'key' || key == 'constant' || key == 'order' || key == 'uid') {
          continue;
        } else if (key.isNotEmpty && val.isNotEmpty) {
          sb.writeln('${_kLabelMap[key] ?? key}：$val');
        }
      } else if (structRe.hasMatch(l) || l.isEmpty) {
        continue; // [ ] { } , 结构行/空行丢弃
      } else {
        // v241：普通行剥包裹引号——剥后是结构行（场景/分镜/概述/维度标签）
        // 才采用剥后版本，防误伤正常内容行
        final l2 = _stripWrapQuotes(l);
        final isStructAfterStrip =
            RegExp(r'^场景\s*\d+\s*[：:]|^分[镜头]?\s*\d+|^概[述说][：:]')
                .hasMatch(l2) ||
            _kLabelMap.keys.any(
              (k) => RegExp('^$k[：:]').hasMatch(l2),
            );
        final line = isStructAfterStrip ? l2 : l;
        // 普通行照搬（场景头/概述/分镜行原文）；场景头计数重置分镜号
        if (RegExp(r'^场景\s*\d+\s*[：:]').hasMatch(line)) {
          sceneNo++;
          shotNo = 0;
          emitScene(line);
        } else if (RegExp(r'^概[述说][：:]').hasMatch(line) && sceneNo == 0) {
          pendingSummary = line;
        } else {
          sb.writeln(line);
        }
      }
    }
    if (pendingSummary != null) sb.writeln(pendingSummary);
    final out = sb.toString().trim();
    return out.isEmpty ? null : out;
  }

  /// JSON（或截断JSON修复后）里提取content字段/entries数组的content拼接
  String _contentFromJsonLike(String t) {
    dynamic json;
    try {
      json = jsonDecode(t);
    } catch (_) {
      json = JsonRepair.parseResponse(t); // 截断JSON栈式修复
    }
    if (json is! Map) return '';
    final c = json['content'] ?? json['entries'];
    if (c is String && c.trim().isNotEmpty) return c.trim();
    if (c is List) {
      final parts = c
          .whereType<Map>()
          .map((e) => e['content']?.toString() ?? '')
          .where((s) => s.trim().isNotEmpty);
      if (parts.isNotEmpty) return parts.join('\n');
    }
    return '';
  }

  /// 判断弧线条目是否已填充分镜（条目content里有"分镜1："行）

  /// v388：生成名称映射表（原著名→新名——二创页输出替换用，生成端保持原著名）
  Future<void> _generateNameMap(AppState state) async {
    if (state.wbApi.effectiveApiKey.isEmpty && !state.wbApi.useCustom) {
      if (state.mainApi.effectiveApiKey.isEmpty) {
        _addLog('❌ 请先在⚙设置API');
        return;
      }
    }
    final allArcs = _getAllArcs(state);
    if (allArcs.isEmpty) {
      _addLog('❌ 无弧线数据——请先在弧线页完成扫描');
      return;
    }
    final sysPrompt = PromptBuilder.buildNameMapSystemPrompt();
    final userPrompt = PromptBuilder.buildNameMapUserPrompt(
      state.worldBook?.requirements,
      allArcs,
      nameReq: state.worldBook?.nameMapReq ?? '',
    );
    if (mounted) {
      final confirmed = await PromptPreview.maybePreview(
        context,
        sysPrompt: sysPrompt,
        userPrompt: userPrompt,
        title: '映射表生成词链预览（${allArcs.length}条弧线）',
        enabled: state.wbPromptPreview,
      );
      if (!confirmed) {
        _addLog('已取消生成映射表');
        return;
      }
    }
    _addLog('━━ 生成名称映射表（${allArcs.length}条弧线骨架）…');
    state.api.clearAbort();
    state.userAborted = false;
    setState(() => _isGenerating = true);
    try {
      final apiConfig =
          state.wbApi.effectiveApiKey.isNotEmpty || state.wbApi.useCustom
          ? state.wbApi
          : state.mainApi;
      final response = await state.api.call(
        apiType: apiConfig.effectiveApiType,
        baseUrl: apiConfig.effectiveApiBase,
        apiKey: apiConfig.effectiveApiKey,
        model: apiConfig.effectiveModel,
        systemPrompt: sysPrompt,
        userPrompt: userPrompt,
        temperature: 0.4,
        maxTokens: 8000,
      );
      // 输出分支与声明同款：json模式的response_format包装要解码
      var raw = response.content.trim();
      if (apiConfig.formatMode == 'json') {
        raw = TextCleaner.normalizeAiOutput(raw, jsonMode: true);
      } else {
        raw = TextCleaner.normalizeAiOutput(raw);
      }
      final outline = raw.trim();
      if (outline.isEmpty) {
        _addLog('❌ 总纲生成为空');
        return;
      }
      if (state.worldBook == null) state.worldBook = WorldBook();
      state.worldBook!.nameMapping = outline;
      state.saveWorldBook();
      state.refresh();
      _addLog('✓ 名称映射表已生成（${outline.length}字）——二创页「换名」开启时输出替换');
    } catch (e) {
      _addLog('❌ 映射表生成失败：$e');
    } finally {
      if (mounted) setState(() => _isGenerating = false);
    }
  }

  /// v388：映射表弹窗（查看/编辑/重新生成）
  void _showMasterOutlineDialog(AppState state) {
    final ctrl = TextEditingController(
      text: state.worldBook?.nameMapping ?? '',
    );
    final reqCtrl = TextEditingController(
      text: state.worldBook?.nameMapReq ?? '',
    );
    // v406：手动添加映射（左原名/右新名）+搜索
    final addOrigCtrl = TextEditingController();
    final addNewCtrl = TextEditingController();
    final searchCtrl = TextEditingController();
    // v397：宽度吃满设备（insetPadding只留12边距）+字号A-/A++清空+内容自适应高度
    double mapFont = 13.0;
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlg) => AlertDialog(
          title: Row(
            children: [
              const Expanded(child: Text('名称映射表')),
              TextButton(
                onPressed: () =>
                    setDlg(() => mapFont = (mapFont - 1).clamp(10.0, 28.0)),
                child: const Text('A-'),
              ),
              TextButton(
                onPressed: () =>
                    setDlg(() => mapFont = (mapFont + 1).clamp(10.0, 28.0)),
                child: const Text('A+'),
              ),
              TextButton(
                onPressed: () {
                  setDlg(() {
                    ctrl.clear();
                    state.worldBook?.nameMapping = '';
                  });
                },
                child: const Text('清空', style: TextStyle(color: Colors.red)),
              ),
            ],
          ),
          insetPadding: const EdgeInsets.symmetric(
            horizontal: 12,
            vertical: 24,
          ),
          contentPadding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          content: SizedBox(
            // v397：宽度吃满可用显示宽度
            width: MediaQuery.of(ctx).size.width - 24,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '每行"原著名→新名（定位）"——生成端保持原著名，二创页「换名」开启时输出替换',
                  style: TextStyle(fontSize: 11.5, color: Colors.grey[600]),
                ),
                // v393：起名要求（指定主角新名/命名规范，生成与增量抽取共用）
                TextField(
                  controller: reqCtrl,
                  minLines: 2,
                  maxLines: 4,
                  style: TextStyle(fontSize: mapFont),
                  decoration: const InputDecoration(
                    isDense: true,
                    border: OutlineInputBorder(),
                    hintText: '起名要求（可选）：如"主角映射为林越，男名用单字，门派名保留原味"',
                  ),
                  onChanged: (v) => state.worldBook?.nameMapReq = v,
                ),
                const SizedBox(height: 6),
                // v406：手动添加映射行（原名→新名）——方便补缺，同名自动更新
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: addOrigCtrl,
                        style: TextStyle(fontSize: mapFont),
                        decoration: const InputDecoration(
                          isDense: true,
                          border: OutlineInputBorder(),
                          hintText: '原著名',
                        ),
                      ),
                    ),
                    const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 4),
                      child: Text('→', style: TextStyle(fontSize: 14)),
                    ),
                    Expanded(
                      child: TextField(
                        controller: addNewCtrl,
                        style: TextStyle(fontSize: mapFont),
                        decoration: const InputDecoration(
                          isDense: true,
                          border: OutlineInputBorder(),
                          hintText: '新名',
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    TextButton(
                      onPressed: () {
                        final orig = addOrigCtrl.text.trim();
                        final newName = addNewCtrl.text.trim();
                        if (orig.isEmpty ||
                            newName.isEmpty ||
                            orig.contains(RegExp(r'[→>]'))) {
                          ScaffoldMessenger.of(this.context).showSnackBar(
                            const SnackBar(
                              content: Text('两边都要填，原名不能含→'),
                            ),
                          );
                          return;
                        }
                        final line = '$orig→$newName';
                        final lines = ctrl.text.split('\n');
                        final idx = lines.indexWhere(
                          (l) =>
                              RegExp(
                                r'^\s*([^\s→>]+?)\s*[→>]',
                              ).firstMatch(l)
                              ?.group(1)
                              ?.trim() ==
                              orig,
                        );
                        final replaced = idx >= 0;
                        if (replaced) {
                          lines[idx] = line;
                        } else {
                          lines.add(line);
                        }
                        ctrl.text = lines
                            .where((l) => l.trim().isNotEmpty)
                            .join('\n');
                        state.worldBook?.nameMapping = ctrl.text;
                        addOrigCtrl.clear();
                        addNewCtrl.clear();
                        setDlg(() {});
                        ScaffoldMessenger.of(this.context).showSnackBar(
                          SnackBar(
                            content: Text(
                              replaced ? '✓ 已更新$orig的映射' : '✓ 已添加$orig→$newName',
                            ),
                          ),
                        );
                      },
                      child: const Text('添加'),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                // v406：搜索——实时列出匹配行（映射行含原名/新名/定位任一命中）
                TextField(
                  controller: searchCtrl,
                  style: TextStyle(fontSize: mapFont),
                  decoration: InputDecoration(
                    isDense: true,
                    border: const OutlineInputBorder(),
                    prefixIcon: const Icon(Icons.search, size: 18),
                    hintText: '搜索映射（原名/新名）',
                    suffixIcon: searchCtrl.text.isEmpty
                        ? null
                        : IconButton(
                            icon: const Icon(Icons.close, size: 16),
                            onPressed: () {
                              searchCtrl.clear();
                              setDlg(() {});
                            },
                          ),
                  ),
                  onChanged: (_) => setDlg(() {}),
                ),
                if (searchCtrl.text.trim().isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Builder(builder: (_) {
                    final q = searchCtrl.text.trim();
                    final matches = ctrl.text
                        .split('\n')
                        .where((l) => l.trim().isNotEmpty && l.contains(q))
                        .toList();
                    return Container(
                      padding: const EdgeInsets.all(6),
                      decoration: BoxDecoration(
                        color: const Color(0xFFFFFBF0),
                        border: Border.all(color: Colors.brown.shade200),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      constraints: const BoxConstraints(maxHeight: 120),
                      child: SingleChildScrollView(
                        child: matches.isEmpty
                            ? Text(
                                '无匹配行',
                                style: TextStyle(
                                  fontSize: 11.5,
                                  color: Colors.grey[600],
                                ),
                              )
                            : Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    '匹配${matches.length}行：',
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: Colors.brown.shade700,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  for (final m in matches)
                                    Text(
                                      m.trim(),
                                      style: TextStyle(
                                        fontSize: mapFont - 1,
                                      ),
                                    ),
                                ],
                              ),
                      ),
                    );
                  }),
                ],
                const SizedBox(height: 4),
                ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: MediaQuery.of(ctx).size.height * 0.45,
                  ),
                  child: SingleChildScrollView(
                    child: TextField(
                      controller: ctrl,
                      // v397：自适应高度——内容几行撑几行，超高才滚动
                      minLines: 4,
                      maxLines: null,
                      style: TextStyle(fontSize: mapFont),
                      decoration: const InputDecoration(
                        border: OutlineInputBorder(),
                        hintText: '空=未生成。点「AI生成」汇总全部弧线骨架产出，也可手填',
                      ),
                      onChanged: (v) =>
                          state.worldBook?.nameMapping = v,
                    ),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('关闭'),
            ),
            TextButton(
              onPressed: _isGenerating
                  ? null
                  : () {
                      Navigator.pop(ctx);
                      _generateNameMap(state);
                    },
              child: Text(
                (state.worldBook?.nameMapping.isNotEmpty ?? false)
                    ? 'AI重新生成'
                    : 'AI生成',
              ),
            ),
            FilledButton(
              onPressed: () {
                state.worldBook?.nameMapping = ctrl.text;
                state.worldBook?.nameMapReq = reqCtrl.text;
                state.saveWorldBook();
                state.refresh();
                Navigator.pop(ctx);
                ScaffoldMessenger.of(this.context).showSnackBar(
                  const SnackBar(content: Text('✓ 映射表已保存')),
                );
              },
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
  }

  /// 当前弧线的改编声明（空=未生成）
  String _declarationText(AppState state, dynamic arcNumber) =>
      state.worldBook?.arcDeclarations[arcNumber.toString()] ?? '';

  /// 声明展示区（就地编辑+自动保存）
  List<Widget> _buildDeclarationSection(AppState state, dynamic arcNumber) {
    final decl = _declarationText(state, arcNumber);
    if (decl.isEmpty) return [];
    return [
      const SizedBox(height: 6),
      ExpansionTile(
        dense: true,
        tilePadding: const EdgeInsets.symmetric(horizontal: 8),
        title: Row(
          children: [
            // v385：注入开关——不勾选=声明保留但不注入生成
            SizedBox(
              width: 22,
              height: 22,
              child: Checkbox(
                value:
                    state.worldBook?.arcDeclEnabled[arcNumber.toString()] ??
                    true,
                onChanged: (v) {
                  setState(
                    () => state.worldBook
                            ?.arcDeclEnabled[arcNumber.toString()] =
                        v ?? true,
                  );
                  state.saveWorldBook();
                },
              ),
            ),
            const SizedBox(width: 4),
            Expanded(
              child: Text(
                '📄 弧线改编声明（${decl.length}字·${state.worldBook?.arcDeclEnabled[arcNumber.toString()] ?? true ? "生成条目时注入" : "已停用不注入"}）',
                style: const TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF92400E),
                ),
              ),
            ),
          ],
        ),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
            child: TextField(
              controller: TextEditingController(text: decl)
                ..selection = TextSelection.collapsed(offset: decl.length),
              maxLines: null,
              minLines: 6,
              style: const TextStyle(fontSize: 11, height: 1.5),
              decoration: InputDecoration(
                isDense: true,
                border: const OutlineInputBorder(),
                fillColor: const Color(0xFFFFFBEB),
                filled: true,
                suffixIcon: IconButton(
                  icon: const Icon(Icons.delete, size: 14, color: Colors.red),
                  onPressed: () {
                    state.worldBook?.arcDeclarations.remove(
                      arcNumber.toString(),
                    );
                    state.saveWorldBook();
                    state.refresh();
                  },
                ),
              ),
              onChanged: (v) {
                state.worldBook?.arcDeclarations[arcNumber.toString()] = v;
              },
            ),
          ),
        ],
      ),
    ];
  }

  /// 生成弧线改编声明（场景功能声明/禁令/行为模式卡——正式改编的指导书）
  Future<void> _generateDeclaration(AppState state, Arc arc) async {
    if (state.wbApi.effectiveApiKey.isEmpty && !state.wbApi.useCustom) {
      // 回退主API也空时提示
      if (state.mainApi.effectiveApiKey.isEmpty) {
        _addLog('❌ 请先在⚙设置API');
        return;
      }
    }
    // 组合要求：全局+弧线
    final globalReq = state.worldBook?.requirements ?? '';
    final arcReq =
        state.worldBook?.arcRequirements[arc.number.toString()] ?? '';
    final combined = [globalReq, arcReq].where((s) => s.isNotEmpty).join('\n');
    // 弧线分析数据（含场景）
    final analysis = state.arcAnalyses[arc.number.toString()];
    final arcItem = {
      'title': arc.title,
      'summary': analysis?.arcSummary ?? arc.summary,
      'scenes':
          analysis?.scenes
              .map((s) => {'name': s.name, 'summary': s.summary})
              .toList() ??
          [],
    };

    final sysPrompt = PromptBuilder.buildArcDeclarationSystemPrompt();
    final userPrompt = PromptBuilder.buildArcDeclarationUserPrompt(
      arcItem,
      combined,
      sceneReqs: state.worldBook?.sceneRequirements,
      arcKey: arc.number.toString(),
    );

    // v130：声明生成前预览提示词（确认后才发送）
    if (mounted) {
      final confirmed = await PromptPreview.maybePreview(
        context,
        sysPrompt: sysPrompt,
        userPrompt: userPrompt,
        title: '声明生成词链预览（弧线${arc.number}）',
        enabled: state.wbPromptPreview,
      );
      if (!confirmed) {
        _addLog('已取消生成声明（弧线${arc.number}）');
        return;
      }
    }

    _addLog('━━ 生成弧线${arc.number}改编声明…');
    state.api.clearAbort(); state.userAborted = false;
    try {
      final apiConfig =
          state.wbApi.effectiveApiKey.isNotEmpty || state.wbApi.useCustom
          ? state.wbApi
          : state.mainApi;
      final response = await state.api.call(
        apiType: apiConfig.effectiveApiType,
        baseUrl: apiConfig.effectiveApiBase,
        apiKey: apiConfig.effectiveApiKey,
        model: apiConfig.effectiveModel,
        systemPrompt: sysPrompt,
        userPrompt: userPrompt,
        temperature: 0.4,
        maxTokens: 8000,
      );
      // v256：声明输出按API模式分支——声明prompt要求纯文本，但json模式
      // 的response_format会把输出包装成{"content":"…"}（且\n为转义），
      // 直接trim透传=整包JSON进声明编辑框。分支解码
      var declarationRaw = response.content.trim();
      if (apiConfig.formatMode == 'json') {
        declarationRaw = TextCleaner.normalizeAiOutput(
          declarationRaw,
          jsonMode: true,
        );
      } else {
        declarationRaw = TextCleaner.normalizeAiOutput(declarationRaw);
      }
      final declaration = declarationRaw.trim();
      if (declaration.isEmpty) {
        _addLog('❌ 声明生成为空');
        return;
      }
      if (state.worldBook == null) state.worldBook = WorldBook();
      state.worldBook!.arcDeclarations[arc.number.toString()] = declaration;
      state.saveWorldBook();
      state.refresh();
      _addLog('✓ 弧线${arc.number}改编声明已生成（${declaration.length}字），生成条目时自动注入');
    } catch (e) {
      _addLog('❌ 声明生成失败：$e');
    }
  }

  /// 从弧线分析metadata提取原著facts构建体系参照（v127：不再用worldBook.systems汇总，按弧线取）
  /// 体系参照：当前弧线facts优先，缺失的体系从全书其他弧线facts补齐（推演换皮继承结构）
  List<WorldbuildingSystem> _arcFacts(AppState state, dynamic arcNumber) {
    // 全书facts收集：当前弧线优先
    final grouped = <String, List<Map>>{};
    final primary = state.arcAnalyses[arcNumber.toString()]?.metadata;
    final primaryFacts = primary?['worldbuilding_facts'];
    if (primaryFacts is List) {
      for (final f in primaryFacts) {
        if (f is! Map) continue;
        final sys = AppState.normalizeSystemName(
          f['system']?.toString() ?? '其他',
        );
        grouped.putIfAbsent(sys, () => []).add(f);
      }
    }
    // 10体系清单（推演换皮必须继承的结构层）
    const kSystems = [
      '经济体系',
      '修炼境界体系',
      '功法/技能体系',
      '社会/政治体系',
      '地理/世界体系',
      '法宝物品体系',
      '丹药灵草体系',
      '种族生物体系',
      '组织势力体系',
      '历史传说体系',
    ];
    // 缺失体系从其他弧线facts借参照
    for (final sys in kSystems) {
      if (grouped.containsKey(sys)) continue;
      for (final a in state.arcAnalyses.values) {
        final facts = a.metadata?['worldbuilding_facts'];
        if (facts is! List) continue;
        for (final f in facts) {
          if (f is! Map) continue;
          final s = AppState.normalizeSystemName(
            f['system']?.toString() ?? '其他',
          );
          if (s == sys) {
            grouped.putIfAbsent(sys, () => []).add(f);
          }
        }
      }
    }
    return grouped.entries.map((e) {
      final rules = e.value.map((f) => '- ${f['rule'] ?? ''}').join('\n');
      final funcs = e.value.map((f) => '- ${f['function'] ?? ''}').join('\n');
      return WorldbuildingSystem(
        id: 'tmp_${e.key}',
        name: e.key,
        originalRules: rules,
        functions: funcs,
        arcKeys: [arcNumber.toString()],
      );
    }).toList();
  }

  void _startEdit(WBEntry entry) {
    _editContentCtrl.text = entry.content;
    _editCommentCtrl.text = entry.comment;
    _editKeyCtrl.text = entry.key;
    setState(() => _editingUid = entry.uid);
  }

  void _saveEdit(AppState state, WBEntry entry) {
    entry.content = TextCleaner.stripDecorativeEmoji(_editContentCtrl.text);
    entry.comment = _editCommentCtrl.text.trim();
    entry.key = _editKeyCtrl.text.trim();
    state.saveWorldBook();
    state.refresh();
    setState(() => _editingUid = null);
  }

  void _cancelEdit() {
    setState(() => _editingUid = null);
  }

  void _addLog(String msg) {
    debugPrint('[WB] $msg');
    setState(() {
      _logs.add(msg);
      if (_logs.length > 100) _logs.removeAt(0);
    });
    AppState.instance.apiLog(msg); // 页面日志同步全局终端（信息出口合一）
  }

  // v288：生成内容字号（本页独立，0.8~1.6）
  double _fontScale = 1.0;

  @override
  void initState() {
    super.initState();
    ContentFont.load('adapt').then((v) {
      if (mounted) setState(() => _fontScale = v);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final state = context.read<AppState>();
      if (state.worldBook != null) {
        _reqController.text = state.worldBook!.requirements;
        _bibleController.text = state.worldBook!.adaptBible;
      }
    });
  }

  /// 所有已拆解的弧线（v468 getWBAllArcs）
  List<Arc> _getAllArcs(AppState state) {
    final result = <Arc>[];
    final arcs = state.completedArcs;
    for (final arc in arcs) {
      // v212：恢复宽松列出（划分了场景就显示）——渐进工作流：可先看场景框架。
      // 是否有分镜用_hasShots判断，生成前单独警告（不再一刀切隐藏）
      if (state.isArcAnalyzed(arc.number) ||
          (state.arcScenes[arc.number.toString()]?.isNotEmpty ?? false) ||
          (state.arcAnalyses[arc.number.toString()]?.scenes.isNotEmpty ??
              false)) {
        result.add(arc);
      }
    }
    return result;
  }

  /// v212：该弧线的场景是否有分镜（无分镜时生成条目只含框架不含分镜详情）
  bool _hasShots(AppState state, Arc arc) {
    final analysis = state.arcAnalyses[arc.number.toString()];
    if (analysis != null && analysis.scenes.any((sc) => sc.shots.isNotEmpty)) {
      return true;
    }
    return state.arcScenes[arc.number.toString()]?.any(
          (sc) => sc.shots.isNotEmpty,
        ) ??
        false;
  }

  @override
  Widget build(BuildContext context) {
    super.build(context); // AutomaticKeepAlive必须
    final state = context.watch<AppState>();
    final allArcs = _getAllArcs(state);
    final entries = state.worldBook?.entries.values.toList() ?? [];
    final generatedCount = allArcs
        .where(
          (a) => state.worldBook?.arcStatus[a.number.toString()] == 'generated',
        )
        .length;

    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            // 顶行：生成+终止+⚙
            // v384：Wrap两行——窄屏自动折行（原横向滚动窄屏显示不全），宽屏仍一行
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 2),
              child: Wrap(
                spacing: 8,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  MiniButton(
                    label: _isGenerating ? '生成中…' : '批量',
                    primary: true,
                    onTap: _isGenerating || allArcs.isEmpty
                        ? null
                        : () => _showGenDialog(state, allArcs, generatedCount),
                  ),
                  MiniButton(
                    label: '↻ 刷新',
                    onTap: () {
                      // 手动刷新保险丝：重建本页并重新计算弧线/条目列表
                      setState(() {});
                      state.refresh();
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('已刷新'),
                          duration: Duration(milliseconds: 800),
                        ),
                      );
                    },
                  ),
                  // v288：生成内容字号（本页独立）
                  ContentFontButtons(
                    pageKey: 'adapt',
                    scale: _fontScale,
                    onChanged: (v) {
                      setState(() => _fontScale = v);
                      ContentFont.save('adapt', v);
                    },
                  ),
                  MiniButton(
                    label: '⚙ API',
                    onTap: () => showV119Sheet(
                      context,
                      title: 'API设置 · 改编',
                      child: ApiConfigPanel(config: state.wbApi, section: 'wb'),
                    ),
                  ),
                  // v379：词链+模式排上移顶栏（原独立Padding区删除）
                  MiniButton(
                    label: '词链',
                    primary: state.wbPromptPreview,
                    onTap: () => state.setWbPromptPreview(
                      !state.wbPromptPreview,
                    ),
                  ),
                  MiniButton(
                    label: (state.worldBook?.nameMapping.isNotEmpty ?? false)
                        ? '映射表✓'
                        : '映射表',
                    primary: state.worldBook?.nameMapping.isNotEmpty ?? false,
                    onTap: () => _showMasterOutlineDialog(state),
                  ),
                  Text(
                    state.worldBook?.adaptMode == 'auto' || state.worldBook == null ? '模式:自动' : '模式:',
                    style: const TextStyle(fontSize: 10, color: Colors.grey),
                  ),
                  _modeChip(state, '原样', 'original', '原样模式：分析数据原样整理为世界书（强制生效，忽略改编要求）'),
                  _modeChip(state, '换皮', 'reskin', '换皮模式：保留原著结构骨架按改编要求转换——冲突形式/背景设定转换，名称保持原著原名（改名走映射表），语感锚/笔墨配额全继承'),
                  _modeChip(state, '推演', 'deduce', '推演模式：只发送功能骨架，AI按新设定推演全新内容，杜绝原著内容层'),
                ],
              ),
            ),
            // v566：改编圣经面板（全书级一致性改编的生成依据）
            _buildBiblePanel(state),
            // 全局改编要求（v468 wb-req-input；v242折叠——1行/聚焦展开）
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
              child: _CollapseReqField(
                controller: _reqController,
                labelText: '全局改编要求（可选，对所有弧线生效）',
                hintText: '如：用更生动的语言描述场景和角色心理\n以第三人称全知视角改写\n把叙述改为设定手册风格',
                fontSize: 13,
                onChanged: (v) {
                  if (state.worldBook == null) state.worldBook = WorldBook();
                  state.worldBook!.requirements = v;
                  state.saveWorldBook();
                },
              ),
            ),
            // 进度条（细条，状态文字在终端里）
            if (_isGenerating)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 12),
                child: LinearProgressIndicator(minHeight: 2),
              ),
            // 弧线列表标题 + 统计
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: Row(
                children: [
                  Text('弧线列表', style: Theme.of(context).textTheme.titleSmall),
                  const SizedBox(width: 8),
                  Text(
                    '$generatedCount/${allArcs.length}已生成',
                    style: const TextStyle(fontSize: 11, color: Colors.grey),
                  ),
                  const SizedBox(width: 8), // Wrap内Spacer失效，用定宽占位
                  Text(
                    '${entries.length}条目',
                    style: const TextStyle(fontSize: 11, color: Colors.grey),
                  ),
                ],
              ),
            ),
            // 弧线列表 或 空提示
            Expanded(
              child: ContentFont.area(context, scale: _fontScale, child: allArcs.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.menu_book,
                            size: 64,
                            color: Colors.grey[400],
                          ),
                          const SizedBox(height: 16),
                          const Text(
                            '暂无已拆解的弧线',
                            style: TextStyle(color: Colors.grey),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            '请先完成弧线扫描和拆解，\n再来制作世界书条目。',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: Colors.grey[500],
                              fontSize: 13,
                              height: 1.6,
                            ),
                          ),
                        ],
                      ),
                    )
                  : SelectionArea(
                    child: ListView.builder(
                      itemCount: allArcs.length + 1, // +1 自定义条目区
                      itemBuilder: (ctx, i) {
                        if (i == allArcs.length) {
                          return _buildCustomEntrySection(state);
                        }
                        return _buildArcItem(state, allArcs[i], allArcs.length);
                      },
                    ),
                  ),
            )),
            // 统一终端（日志+终止）— v468 api-step-log
          ],
        ),
      ),
    );
  }

  /// 单条弧线卡片（v468 wb-arc-item）
  Widget _buildArcItem(AppState state, Arc arc, int totalArcs) {
    // v202：概述优先拆解结果（与分镜页同源arcAnalyses），无拆解回落扫描概述
    final _analysis = state.arcAnalyses[arc.number.toString()];
    final _arcSummary =
        (_analysis?.arcSummary.isNotEmpty == true)
            ? _analysis!.arcSummary
            : arc.summary;
    final arcKey = arc.number.toString();
    final status = state.worldBook?.arcStatus[arcKey] ?? '';
    final isExpanded = _expandedArcs.contains(arcKey);
    final arcReq = state.worldBook?.arcRequirements[arcKey] ?? '';

    // 状态颜色
    Color statusColor;
    String statusText;
    if (status == 'generated') {
      statusColor = Colors.green;
      statusText = '✓ 已生成';
    } else if (status == 'generating') {
      statusColor = Colors.orange;
      statusText = '⟳ 生成中';
    } else if (status == 'failed') {
      statusColor = Colors.red;
      statusText = '✗ 失败';
    } else {
      statusColor = Colors.grey;
      statusText = '未生成';
    }

    // 该弧线的场景列表
    final scenes =
        state.arcScenes[arcKey] ??
        state.arcAnalyses[arcKey]?.scenes ??
        <Scene>[];

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      child: Column(
        children: [
          // 弧线头部（点击折叠/展开）
          InkWell(
            onTap: () {
              setState(() {
                if (isExpanded) {
                  _expandedArcs.remove(arcKey);
                } else {
                  _expandedArcs.add(arcKey);
                }
              });
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  Text(
                    isExpanded ? '▼' : '▶',
                    style: const TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                  const SizedBox(width: 6),
                  CircleAvatar(
                    radius: 11,
                    backgroundColor: statusColor.withOpacity(0.15),
                    child: Text(
                      '${arc.number}',
                      style: TextStyle(
                        fontSize: 11,
                        color: statusColor,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      arc.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    statusText,
                    style: TextStyle(fontSize: 11, color: statusColor),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    arc.chapterRange,
                    style: const TextStyle(fontSize: 10, color: Colors.grey),
                  ),
                ],
              ),
            ),
          ),
          // 展开内容
          if (isExpanded) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (_arcSummary.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: Text(
                              _arcSummary,
                              // v193：概述完整显示（旧2行截断显示不完整）
                              style: const TextStyle(
                                fontSize: 11,
                                color: Colors.grey,
                                height: 1.4,
                              ),
                            ),
                          ),
                          // v195：弧线概述复制按钮
                          GestureDetector(
                            onTap: () {
                              Clipboard.setData(
                                ClipboardData(text: _arcSummary),
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
                  // 本弧线专属改编要求（v468 per-arc requirement；v242折叠）
                  _CollapseReqField(
                    controller: TextEditingController(text: arcReq),
                    labelText: '本弧线专属改编要求（可选，与全局要求综合生效）',
                    fontSize: 12,
                    expandLines: 5,
                    onChanged: (v) {
                      if (state.worldBook == null)
                        state.worldBook = WorldBook();
                      state.worldBook!.arcRequirements[arcKey] = v;
                      state.saveWorldBook();
                    },
                  ),
                  const SizedBox(height: 6),
                  // 生成按钮+声明按钮
                  Row(
                    children: [
                      FilledButton.tonalIcon(
                        icon: const Icon(Icons.auto_fix_high, size: 16),
                        label: Text(
                          status == 'generated' ? '重新生成本弧线' : '生成本弧线条目',
                          style: const TextStyle(fontSize: 12),
                        ),
                        onPressed: _isGenerating
                            ? null
                            : () => _generateForArc(state, arc, totalArcs),
                      ),
                      const SizedBox(width: 6),
                      MiniButton(
                        label: _declarationText(state, arc.number).isNotEmpty
                            ? '📄声明✓'
                            : '📄生成声明',
                        onTap: _isGenerating
                            ? null
                            : () => _generateDeclaration(state, arc),
                      ),
                      const SizedBox(width: 6),
                      const SizedBox(width: 8), // Wrap内Spacer失效，用定宽占位
                      if (scenes.isNotEmpty)
                        Text(
                          '${scenes.length}个场景',
                          style: const TextStyle(
                            fontSize: 11,
                            color: Colors.grey,
                          ),
                        ),
                    ],
                  ),
                  // 弧线改编声明（已生成时展示，可编辑，生成条目时自动注入）
                  ..._buildDeclarationSection(state, arc.number),

                  // 场景列表（可单独改编，v468 beat-list）
                  if (scenes.isNotEmpty) ...[
                    const Divider(height: 12),
                    ...scenes.asMap().entries.map((entry) {
                      final bi = entry.key;
                      final scene = entry.value;
                      final sceneReqKey = '${arcKey}_$bi';
                      final sceneReq =
                          state.worldBook?.sceneRequirements[sceneReqKey] ?? '';
                      // v237：该场景块是否已改编进弧线条目（有分镜=已完成）
                      // 旧判定（独立WBEntry的sceneTag）随独立条目路径一起废弃
                      final hasStandalone = _sceneBlockFromArcEntry(
                        state,
                        arcKey,
                        bi,
                      ).contains('分镜');
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '场景${bi + 1}：${scene.name}',
                              style: const TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                            if (scene.summary.isNotEmpty)
                              Padding(
                                padding: const EdgeInsets.only(top: 2),
                                child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Expanded(
                                      child: Text(
                                        scene.summary,
                                        style: const TextStyle(
                                          fontSize: 11,
                                          height: 1.4,
                                          color: V469Style.textSec,
                                        ),
                                      ),
                                    ),
                                    GestureDetector(
                                      onTap: () {
                                        Clipboard.setData(
                                          ClipboardData(text: scene.summary),
                                        );
                                      },
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 8,
                                          vertical: 3,
                                        ),
                                        decoration: BoxDecoration(
                                          color: V469Style.accent,
                                          borderRadius:
                                              BorderRadius.circular(6),
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
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    scene.chapterRange,
                                    style: const TextStyle(
                                      fontSize: 10,
                                      color: Colors.grey,
                                    ),
                                  ),
                                ),
                                if (hasStandalone)
                                  const Icon(
                                    Icons.check_circle,
                                    size: 12,
                                    color: Colors.green,
                                  ),
                                const SizedBox(width: 4),
                                TextButton(
                                  onPressed: _isGenerating
                                      ? null
                                      : () => _generateForScene(
                                          state,
                                          arc,
                                          bi,
                                          totalArcs,
                                        ),
                                  style: TextButton.styleFrom(
                                    minimumSize: const Size(0, 28),
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 8,
                                    ),
                                    tapTargetSize:
                                        MaterialTapTargetSize.shrinkWrap,
                                  ),
                                  child: Text(
                                    hasStandalone ? '重新生成' : '单独改编',
                                    style: const TextStyle(fontSize: 11),
                                  ),
                                ),
                              ],
                            ),
                            // 场景独立改编要求（v242折叠）
                            _CollapseReqField(
                              controller: TextEditingController(text: sceneReq),
                              labelText: '本场景改编要求（可选）...',
                              fontSize: 11,
                              expandLines: 4,
                              onChanged: (v) {
                                if (state.worldBook == null)
                                  state.worldBook = WorldBook();
                                state
                                        .worldBook!
                                        .sceneRequirements[sceneReqKey] =
                                    v;
                                state.saveWorldBook();
                              },
                            ),
                          ],
                        ),
                      );
                    }).toList(),
                  ],
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// 自定义条目区（v468 wb-custom-section）
  Widget _buildCustomEntrySection(AppState state) {
    final customEntries = (state.worldBook?.entries.values ?? <WBEntry>[])
        .where((e) => e.arcKey == null || e.arcKey!.isEmpty)
        .toList();

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('自定义条目', style: Theme.of(context).textTheme.titleSmall),
                const Spacer(),
                TextButton.icon(
                  icon: const Icon(Icons.add, size: 16),
                  label: const Text('添加', style: TextStyle(fontSize: 12)),
                  onPressed: () => _showAddCustomDialog(state),
                ),
              ],
            ),
            if (customEntries.isEmpty)
              Text(
                '暂无自定义条目',
                style: TextStyle(fontSize: 11, color: Colors.grey[500]),
              )
            else
              ...customEntries.map((e) {
                final isEditing = _editingUid == e.uid;
                if (isEditing) {
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        TextField(
                          controller: _editCommentCtrl,
                          decoration: const InputDecoration(
                            labelText: '名称',
                            isDense: true,
                          ),
                          style: const TextStyle(fontSize: 12),
                        ),
                        const SizedBox(height: 4),
                        TextField(
                          controller: _editKeyCtrl,
                          decoration: const InputDecoration(
                            labelText: '触发词（逗号分隔）',
                            isDense: true,
                          ),
                          style: const TextStyle(fontSize: 11),
                        ),
                        const SizedBox(height: 4),
                        TextField(
                          controller: _editContentCtrl,
                          decoration: const InputDecoration(
                            labelText: '内容',
                            isDense: true,
                          ),
                          maxLines: null,
                          minLines: 5,
                          style: const TextStyle(fontSize: 11, height: 1.5),
                        ),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            TextButton(
                              onPressed: _cancelEdit,
                              child: const Text(
                                '取消',
                                style: TextStyle(fontSize: 12),
                              ),
                            ),
                            FilledButton(
                              onPressed: () => _saveEdit(state, e),
                              child: const Text(
                                '保存',
                                style: TextStyle(fontSize: 12),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  );
                }
                return ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    e.constant ? Icons.star : Icons.bookmark,
                    size: 16,
                    color: e.constant ? Colors.amber : Colors.grey,
                  ),
                  title: Text(e.comment, style: const TextStyle(fontSize: 12)),
                  subtitle: Text(
                    'order:${e.order}',
                    style: const TextStyle(fontSize: 10),
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.edit, size: 14),
                        onPressed: () => _startEdit(e),
                      ),
                      IconButton(
                        icon: const Icon(
                          Icons.delete,
                          size: 14,
                          color: Colors.red,
                        ),
                        onPressed: () {
                          state.worldBook!.entries.remove(e.uid);
                          state.saveWorldBook();
                          state.refresh();
                        },
                      ),
                    ],
                  ),
                );
              }),
          ],
        ),
      ),
    );
  }

  /// 条目预览（v468 wb-entry-card）

  // ===== 生成对话框（增量/全量，v468 showWBGenChoiceDialog） =====
  Future<void> _showGenDialog(
    AppState state,
    List<Arc> allArcs,
    int generatedCount,
  ) async {
    if (allArcs.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            '暂无可用弧线——请先在弧线页扫描，再到场景页划分场景',
          ),
          duration: Duration(seconds: 3),
        ),
      );
      return;
    }


    if (generatedCount == 0) {
      // 全新生成，直接开始
      _generateAll(state, allArcs, 'full');
      return;
    }

    // 部分已生成，问增量还是全量
    showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('生成模式'),
        content: Text(
          '已生成 $generatedCount/${allArcs.length} 条弧线。\n\n'
          '增量：只生成剩余 ${allArcs.length - generatedCount} 条\n'
          '全量：全部重新生成（覆盖已有条目）',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'cancel'),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'incremental'),
            child: const Text('增量生成'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, 'full'),
            child: const Text('全量重新生成'),
          ),
        ],
      ),
    ).then((mode) {
      if (mode != null && mode != 'cancel') {
        _generateAll(state, allArcs, mode);
      }
    });
  }

  /// 批量生成（v468 generateAllWorldBookArcs）
  Future<void> _generateAll(
    AppState state,
    List<Arc> allArcs,
    String mode,
  ) async {
    // v212：无分镜的弧线先警告（继续=只生成场景框架，取消=跳场景页拆分镜）
    final noShotArcs = allArcs.where((a) => !_hasShots(state, a)).toList();
    if (noShotArcs.isNotEmpty) {
      final names = noShotArcs.map((a) => a.number.toString()).join('、');
      // v213：三选（继续生成/去拆分镜/关闭=什么都不做）；宽度占满对齐设置弹窗
      final go = await showDialog<bool>(
        context: context,
        builder: (ctx) => Dialog(
          insetPadding: const EdgeInsets.symmetric(
            horizontal: 8,
            vertical: 24,
          ),
          child: SizedBox(
            width: double.maxFinite,
            child: AlertDialog(
              title: const Text('部分弧线无分镜'),
              content: Text(
                '弧线 $names 未拆解分镜。\n\n'
                '继续生成：这些弧线只生成场景框架条目（不含分镜详情）\n'
                '去拆分镜：跳到场景页拆分镜，分镜齐全再生成\n'
                '关闭：什么都不做',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx), // 关闭=null
                  child: const Text('关闭'),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('去拆分镜'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text('继续生成'),
                ),
              ],
            ),
          ),
        ),
      );
      if (go != true) {
        if (go == false) state.switchTab('scene'); // false=去拆分镜；null=关闭不动
        return;
      }
    }
    // 世界观体系不再汇总（v127架构简化）：改编后的体系在每条弧线条目内容的弧线总结里
    if (state.worldBook == null) state.worldBook = WorldBook();
    // v213：清除上次abort残留（人为终止后_aborted保持true，二次生成秒回"用户中断"）
    state.api.clearAbort(); state.userAborted = false;
    setState(() {
      _isGenerating = true;
      _abort = false;
    });

    // v285：批量全程try/finally——异常逃逸会永久卡死_isGenerating（所有按钮
    // 置灰、进度条空转、再点无反应），且原实现无catch=终端连异常都看不到
    try {
      _addLog('⚡ 一键生成开始（$mode模式，${allArcs.length}条弧线）');
      // 全量模式：清空所有弧线条目和状态
      if (mode == 'full') {
        state.worldBook!.entries.removeWhere(
          (k, e) => e.arcKey != null && e.arcKey!.isNotEmpty,
        );
        state.worldBook!.arcStatus.clear();
        state.saveWorldBook();
      }
      var successCount = 0;
      for (final arc in allArcs) {
        // 终止检查：页面标志 或 全局API abort（终止按钮在全局终端，强断当前请求后这里停循环）
        if (_abort || state.api.isAborted || state.userAborted) {
          _addLog('已终止');
          break;
        }
        final arcKey = arc.number.toString();
        // 增量模式：跳过已生成
        if (mode == 'incremental' &&
            state.worldBook!.arcStatus[arcKey] == 'generated') {
          continue;
        }
        _addLog('━━ 弧线${arc.number}/${allArcs.length}：${arc.title}');
        try {
          // v214：批量增量=弧线内增量（半成品续传：跳过已完成场景只补缺，
          // 不再把断点弧线从头重跑）
          await _generateForArcInternal(
            state,
            arc,
            allArcs.length,
            incremental: mode == 'incremental',
          );
          if (state.worldBook!.arcStatus[arcKey] == 'generated') successCount++;
        } catch (e) {
          _addLog('❌ 弧线${arc.number}异常：$e');
          state.worldBook!.arcStatus[arcKey] = 'failed';
        }
      }

      state.saveWorldBook();
      _addLog('✓ 批量生成完成（$successCount/${allArcs.length}条成功）');
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('世界书生成完成')));
      }
    } catch (e, st) {
      _addLog('❌ 一键生成异常中断：$e');
      _addLog('堆栈：${st.toString().split('\n').take(6).join('\n')}');
    } finally {
      if (mounted) {
        setState(() {
          _isGenerating = false;
          _statusText = '';
        });
      }
    }
  }

  /// 单弧线生成（v468 generateWorldBookForArc）
  /// v214：该弧线已有条目时先问全量/增量——增量=弧线内补缺（跳过已完成场景）
  Future<void> _generateForArc(AppState state, Arc arc, int totalArcs) async {
    if (_isGenerating) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('正在生成中，请等待')));
      return;
    }
    if (state.worldBook == null) state.worldBook = WorldBook();

    // 有条目（哪怕半成品）→ 全量/增量二选；全新弧线直接全量
    // v549：判定扩展——散条目结构（无总结条目，只有场景散条目）也算
    // 已有条目，否则这类弧线永远不弹增量选择直接全量重跑烧API
    final arcKey = arc.number.toString();
    final hasEntry = _arcEntryKey(state, arcKey) != null ||
        (state.worldBook!.entries.values.any((e) => e.arcKey == arcKey));
    var incremental = false;
    if (hasEntry) {
      final mode = await showDialog<String>(
        context: context,
        builder: (ctx) => Dialog(
          insetPadding: const EdgeInsets.symmetric(
            horizontal: 8,
            vertical: 24,
          ),
          child: SizedBox(
            width: double.maxFinite,
            child: AlertDialog(
              title: Text('弧线${arc.number}生成方式'),
              content: const Text(
                '全量重新生成：删除本弧线全部条目从头生成\n'
                '增量补缺：保留已有内容，只补缺失的场景框架和分镜（省API）',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(ctx, 'full'),
                  child: const Text('全量重新生成'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(ctx, 'incremental'),
                  child: const Text('增量补缺'),
                ),
              ],
            ),
          ),
        ),
      );
      if (mode == null) return; // 取消
      incremental = mode == 'incremental';
    }

    state.api.clearAbort(); state.userAborted = false; // v213：清除上次abort残留
    setState(() {
      _isGenerating = true;
      _abort = false;
    });
    try {
      await _generateForArcInternal(
        state,
        arc,
        totalArcs,
        incremental: incremental,
      );
    } finally {
      state.saveWorldBook();
      setState(() {
        _isGenerating = false;
        _statusText = '';
      });
    }
  }

  /// 单弧线生成内部（v468 generateWorldBookForArcInternal）
  /// v214 incremental=true：弧线内增量——总结条目存在则跳过阶段A；
  /// 场景块已有分镜则整场景跳过；有框架无分镜只做填充（省API）
  Future<void> _generateForArcInternal(
    AppState state,
    Arc arc,
    int totalArcs, {
    bool incremental = false,
  }) async {
    final arcKey = arc.number.toString();
    // 标记生成中
    state.worldBook!.arcStatus[arcKey] = 'generating';
    setState(() => _statusText = '正在生成弧线${arc.number}：${arc.title}');
    _addLog('开始生成弧线${arc.number}：${arc.title}（逐场景分步模式）');

    try {
      // 备份旧条目（失败时恢复）
      final oldBackup = <String, WBEntry>{};
      state.worldBook!.entries.forEach((k, e) {
        if (e.arcKey == arcKey) oldBackup[k] = e;
      });
      // v239：清扫历史污染（JSON残渣+无头内容并入前块）
      _cleanLegacyDebris(state, arcKey);

      // 合并全局+本弧线要求
      final globalReq = _reqController.text.trim();
      final arcReq = state.worldBook!.arcRequirements[arcKey] ?? '';
      // v566：改编圣经注入——全书级映射最高优先级，A/B/C三阶段共用
      final bible = state.worldBook!.adaptBible.trim();
      var combinedReq = globalReq;
      if (bible.isNotEmpty) {
        combinedReq = (combinedReq.isNotEmpty ? '$combinedReq\n\n' : '') +
            '【改编圣经（全书级映射，最高优先级强制执行）】\n'
            '以下映射适用于本弧线全部产出（概述/场景/分镜）：所有人物/设定/规则'
            '必须按映射替换，禁止出现未替换的原著元素名。圣经与场景级要求冲突时以圣经为准。\n$bible';
      }
      if (arcReq.isNotEmpty) {
        combinedReq =
            (combinedReq.isNotEmpty ? '$combinedReq\n\n' : '') +
            '【本弧线专属要求】\n$arcReq';
      }

      // === 逐场景分步模式（v133）===
      // 阶段A：弧线总结条目（概述+九件套，一次生成）
      // 阶段B：逐场景框架（每个场景单独一次API）
      // 阶段C：逐场景分镜填充（每个场景单独一次API）

      // 构建弧线数据
      var arcItem = _buildArcItemData(state, arc);

      // 推演模式：v280起不再补全功能抽象——拆解已是必选维度（弧线页/场景页都产出），
      // 旧数据缺abstract直接走骨架生成由骨架侧容错
      // v225：三模式——adaptMode显式时覆盖deduceMode（UI联动已同步，
      // 这里防御旧数据/云恢复的不一致）
      if (state.worldBook!.adaptMode == 'deduce') state.worldBook!.deduceMode = true;
      if (state.worldBook!.adaptMode == 'reskin') state.worldBook!.deduceMode = false;
      final deduce = state.worldBook!.deduceMode;

      final config = state.getApiConfig('wb');
      final declaration =
          (state.worldBook?.arcDeclEnabled[arc.number.toString()] ?? true)
          ? _declarationText(state, arc.number)
          : ''; // v385：勾选框未勾选=不注入
      final scenes =
          state.arcScenes[arcKey] ??
          state.arcAnalyses[arcKey]?.scenes ??
          <Scene>[];

      // v217：无任何改编要求（全局/弧线/声明全空）=原样整理模式
      // v225：显式选择"原样"模式时强制原样（忽略一切改编要求）
      // v229：显式选换皮/推演=用户明确要改编（哪怕没填要求也执行换皮/推演，
      // 换皮至少换专有名词、推演至少按新设定推内容）；只有auto才按
      // "有没有要求"判断；original强制原样
      final mode = state.worldBook!.adaptMode;
      final hasReq = mode == 'original'
          ? false
          : mode == 'reskin' || mode == 'deduce'
          ? true
          : (combinedReq.trim().isNotEmpty ||
                declaration.trim().isNotEmpty);

      // ── 阶段A：弧线总结条目（v214：增量模式已有条目则跳过，不删不重建）──
      if (incremental && _arcEntryKey(state, arcKey) != null) {
        _addLog('弧线${arc.number}条目已存在（增量模式跳过弧线总结）');
      } else {
      final summarySys = PromptBuilder.buildArcSummaryEntrySystemPrompt(
        deduce,
        hasRequirements: hasReq,
      );
      final summaryUser = PromptBuilder.buildArcSummaryEntryUserPrompt(
        arcItem,
        combinedReq,
        declaration,
        scenes.length,
        arc.number,
      );
      if (mounted) {
        final confirmed = await PromptPreview.maybePreview(
          context,
          sysPrompt: summarySys,
          userPrompt: summaryUser,
          title: '弧线总结生成预览（弧线${arc.number}）',
          enabled: state.wbPromptPreview,
        );
        if (!confirmed) {
          state.worldBook!.arcStatus[arcKey] = 'failed';
          _addLog('已取消（弧线${arc.number}）');
          return;
        }
      }
      final sumResult = await state.api.callApi(
        systemPrompt: summarySys,
        userPrompt: summaryUser,
        apiConfig: config,
      );
      if (!sumResult.isSuccess) {
        state.worldBook!.arcStatus[arcKey] = 'failed';
        _addLog('弧线${arc.number} 弧线总结API错误：${sumResult.error}');
        state.worldBook!.entries.addAll(oldBackup);
        state.saveWorldBook();
        state.refresh();
        return;
      }
      // 删除旧条目，解析弧线总结条目
      state.worldBook!.entries.removeWhere((k, e) => e.arcKey == arcKey);
      var sumOk = _parseWBResponse(state, sumResult.content, arc.number);
      if (sumOk <= 0) {
        state.worldBook!.arcStatus[arcKey] = 'failed';
        _addLog('弧线${arc.number} 弧线总结解析失败');
        // v213：解析失败也恢复备份（旧条目已删，不恢复=这条弧线条目真丢失）
        state.worldBook!.entries.addAll(oldBackup);
        state.saveWorldBook();
        state.refresh();
        return;
      }
      _addLog('✓ 弧线${arc.number}总结条目已生成（${sumResult.content.length}字）');
      // 世界观10体系校验补齐（AI砍尾部兜底）
      _ensureWorldbuildingSystems(state, arcKey);
      state.saveWorldBook();
      // v388b：映射表增量抽取（不阻塞主流程）
      // v392：await串行——unawaited会与下一步请求撞车（API单任务守卫拒绝框架请求=停机）
      await state.extractNameMapIncrement(sumResult.content);
      } // 阶段A else结束（v214增量跳过分支）

      // ── 阶段B+C：逐场景（框架+分镜，每场景两次API）──
      // v215：改编后人设卡（弧线总结条目【人设】区）=角色名映射基准，优先级最高
      final arcSummaryText = _castFromArcEntry(state, arcKey);
      // v214→v215修正：原著九件套只在**无人设卡**时兜底（此时条目都没生成，
      // 增量首场景等场景）；有人设卡时原著characters反而误导（AI抄原著人名）
      final arcContextBuf = StringBuffer();
      if (arcSummaryText.isEmpty) {
        [
          'characters',
          'conflicts',
          'foreshadowing',
          'arc_functions',
          'irreversible_changes',
          'emotional_curve',
          'author_fantasy',
        ].forEach((k) {
          final v = (arcItem['analysis']?['arc'] ?? const {})[k];
          if (v != null && v.toString().isNotEmpty && v.toString() != '[]') {
            arcContextBuf.writeln('$k：$v');
          }
        });
      } else {
        arcContextBuf.writeln(arcSummaryText);
      }
      // v214：已改编场景框架（增量模式下已存在的块也算既成事实）
      // v214：收集弧线条目里已生成的全部场景块标题+概述（当前场景生成前
      // 条目里只有已完成的场景，全部都是既成事实）
      // v216：收集挪到循环内动态刷新——每生成一个新框架，后续场景立刻
      // 能看到（自我投喂闭环：存量+本轮新产出都回流）
      final adaptedFramesBuf = StringBuffer();
      for (var si = 0; si < scenes.length; si++) {
        adaptedFramesBuf.clear();
        for (var pi = 0; pi < scenes.length; pi++) {
          final blk = _sceneBlockFromArcEntry(state, arcKey, pi);
          if (blk.isEmpty) continue;
          // 只取标题+概述两行（不含分镜，控制token）
          final lines = blk
              .split('\n')
              .where((l) => l.trim().isNotEmpty)
              .toList();
          final head = lines.take(2).join('\n');
          adaptedFramesBuf.writeln(head);
        }
        if (_abort || state.api.isAborted || state.userAborted) {
          _addLog('已终止（已完成$si/${scenes.length}场景）');
          break;
        }
        final scene = scenes[si];
        final sceneReqKey = '${arcKey}_$si';
        final sceneReq = state.worldBook!.sceneRequirements[sceneReqKey] ?? '';
        var sceneReqAll = combinedReq;
        if (sceneReq.isNotEmpty) {
          sceneReqAll =
              (sceneReqAll.isNotEmpty ? '$sceneReqAll\n\n' : '') +
              '【本场景专属要求】\n$sceneReq';
        }

        // v214增量：检查本场景块现状——有分镜整场景跳过；有框架无分镜跳B只做C
        var skipFrame = false;
        if (incremental) {
          final block = _sceneBlockFromArcEntry(state, arcKey, si);
          // v226：分镜齐全=有分镜行+有语感(Voice)行——旧条目有分镜但无
          // voice/ink维度行的不算完成（数据升级场景），重新填充带上新维度
          if (block.contains('分镜') && block.contains('语感(Voice)')) {
            _addLog('场景${si + 1}已有分镜（增量跳过）');
            continue;
          }
          if (block.contains('分镜') && !block.contains('语感(Voice)')) {
            _addLog('场景${si + 1}分镜为旧版（无语感/笔墨维度）——重新填充升级');
          }
          if (block.isNotEmpty) skipFrame = true; // 有框架没分镜
        }

        // v258：原著角色定位表（推演骨架注意力抽象用——框架/填充共用）
        final castRoles = ((arcItem['analysis']?['arc'] ?? const {})['characters'] as List? ?? [])
            .whereType<Map>()
            .map((m) => Map<String, dynamic>.from(m))
            .toList();
        // B：场景框架条目
        if (skipFrame) {
          _addLog('场景${si + 1}框架已存在（增量只填分镜）');
        } else {
        final frameSys = PromptBuilder.buildSceneFrameSystemPrompt(
          deduce,
          hasRequirements: hasReq || sceneReqAll.trim().isNotEmpty,
          jsonMode: config.formatMode == 'json',
        );
        final frameUser = PromptBuilder.buildSceneFrameUserPrompt(
          arcItem,
          si,
          sceneReqAll,
          declaration,
          arcContext: arcContextBuf.toString(),
          adaptedFrames: adaptedFramesBuf.toString(),
          deduce: deduce,
          castRoles: castRoles,
        );
        if (mounted) {
          final confirmed = await PromptPreview.maybePreview(
            context,
            sysPrompt: frameSys,
            userPrompt: frameUser,
            title: '场景框架预览（弧线${arc.number}场景${si + 1}）',
            enabled: state.wbPromptPreview,
          );
          if (!confirmed) {
            _addLog('已取消（场景${si + 1}）');
            return;
          }
        }
        final frameResult = await state.api.callApi(
          systemPrompt: frameSys,
          userPrompt: frameUser,
          apiConfig: config,
        );
        if (!frameResult.isSuccess) {
          // v277：失败停机（用户实测场景4失败继续生成场景5→场景4后补
          // 追加到场景区尾部排到5后=顺序错乱，全部重新生成才能修——
          /// 失败/顺序问题必须在发生点停止，增量从断点继续）
          _addLog('❌ 场景${si + 1}框架失败：${frameResult.error}——停机（已完成${si}/${scenes.length}场景，补生成从此场景继续）');
          state.worldBook!.arcStatus[arcKey] = 'failed';
          state.saveWorldBook();
          state.refresh();
          return;
        }
        // 从AI返回提取content（JSON里的entries[0].content=场景框架两行）
        final frameContent = _extractContentFromJson(frameResult.content, jsonMode: config.formatMode == 'json');
        if (frameContent.isEmpty) {
          _addLog('❌ 场景${si + 1}框架解析失败——停机（补生成从此场景继续）');
          state.worldBook!.arcStatus[arcKey] = 'failed';
          state.saveWorldBook();
          state.refresh();
          return;
        }
        // 追加到弧线条目content的场景区尾部（【世界观设定】等九件套之前）
        final mergedFrame = _appendSceneToArcEntry(state, arcKey, frameContent);
        if (!mergedFrame) {
          _addLog('❌ 场景${si + 1}框架追加失败（弧线条目未找到）——停机');
          state.worldBook!.arcStatus[arcKey] = 'failed';
          state.saveWorldBook();
          state.refresh();
          return;
        }
        state.saveWorldBook();
        _addLog(
          '✓ 场景${si + 1}/${scenes.length}框架（${frameResult.content.length}字）',
        );
        // v388b：映射表增量抽取（不阻塞主流程）
        // v392：await串行防撞车
        await state.extractNameMapIncrement(frameResult.content);
        } // v214 skipFrame else结束

        // C：该场景分镜填充
        final fillSys = PromptBuilder.buildShotFillSystemPrompt(
          deduce,
          hasRequirements: hasReq || sceneReqAll.trim().isNotEmpty,
          jsonMode: config.formatMode == 'json',
        );
        final fillUser = PromptBuilder.buildSceneShotFillUserPrompt(
          entryContent: _sceneBlockFromArcEntry(state, arcKey, si),
          scene: scene.toJson(),
          sceneIdx: si,
          castRoles: castRoles,
          declaration: declaration,
          requirements: sceneReqAll,
          cast: arcSummaryText, // v216：改编后弧线总结全文（人设卡+世界观+伏笔等，分镜在其上生长）
          deduce: deduce, // v216：推演模式下分镜内容与原著零重叠
        );
        if (mounted) {
          final confirmed = await PromptPreview.maybePreview(
            context,
            sysPrompt: fillSys,
            userPrompt: fillUser,
            title: '分镜填充预览（弧线${arc.number}场景${si + 1}）',
            enabled: state.wbPromptPreview,
          );
          if (!confirmed) {
            _addLog('已取消分镜填充（场景${si + 1}）');
            return;
          }
        }
        var fillResult = await state.api.callApi(
          systemPrompt: fillSys,
          userPrompt: fillUser,
          apiConfig: config,
        );
        // 503重试（3次）+ 失败/无分镜内容重试1次（AI输出漂移或偶发空返回）
        var fillRetry = 0;
        while ((!fillResult.isSuccess ||
                !_extractFillContent(fillResult.content, jsonMode: config.formatMode == 'json').contains('分镜')) &&
            fillRetry < 2 &&
            !state.api.isAborted || state.userAborted) {
          fillRetry++;
          _addLog('场景${si + 1}填充结果异常，重试（第$fillRetry/2次）...');
          await Future.delayed(const Duration(seconds: 5));
          if (state.api.isAborted) break;
          fillResult = await state.api.callApi(
            systemPrompt: fillSys,
            userPrompt: fillUser,
            apiConfig: config,
          );
        }
        final fillContent = _extractFillContent(fillResult.content, jsonMode: config.formatMode == 'json');
        if (fillResult.isSuccess && fillContent.contains('分镜')) {
          // 分镜结果替换弧线条目里的该场景块
          final merged = _replaceSceneBlockInArcEntry(
            state,
            arcKey,
            si,
            fillContent,
            fallbackSummary: scene.summary,
          );
          if (merged) {
            _addLog('✓ 场景${si + 1}分镜已填充（${fillResult.content.length}字）');
          } else {
            _addLog('⚠️ 场景${si + 1}分镜合并失败（场景块未找到）');
          }
        } else {
          // v277：失败停机（同阶段B——继续会生成后续场景，本场景后补
          // 会追加到尾部=顺序错乱）
          final diag = fillResult.error != null
              ? fillResult.error
              : '返回无分镜标记，前80字：${_preview(fillResult.content)}';
          _addLog('❌ 场景${si + 1}分镜填充失败：$diag——停机（框架已存，重生成此弧线只填分镜）');
        }
        state.saveWorldBook();
        state.refresh();
        // v388b：分镜填充后映射表增量抽取
        // v392：await串行防撞车
        await state.extractNameMapIncrement(fillResult.content);
      }

      state.worldBook!.arcStatus[arcKey] = 'generated';
      _addLog('✓ 弧线${arc.number}完成（总结+${scenes.length}场景框架+分镜）');
    } catch (e) {
      state.worldBook!.arcStatus[arcKey] = 'failed';
      _addLog('弧线${arc.number} 异常：$e');
    }
    state.saveWorldBook();
    state.refresh();
    if (mounted) setState(() {});
  }


  /// 单场景生成（v468 generateWorldBookForBeat）
  Future<void> _generateForScene(
    AppState state,
    Arc arc,
    int sceneIdx,
    int totalArcs,
  ) async {
    if (_isGenerating) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('正在生成中，请等待')));
      return;
    }
    if (state.worldBook == null) state.worldBook = WorldBook();
    setState(() {
      _isGenerating = true;
      _abort = false;
    });

    final arcKey = arc.number.toString();
    setState(() => _statusText = '正在生成弧线${arc.number}场景${sceneIdx + 1}...');
    _addLog('单独改编：弧线${arc.number} 场景${sceneIdx + 1}');

    try {
      final scenes =
          state.arcScenes[arcKey] ??
          state.arcAnalyses[arcKey]?.scenes ??
          <Scene>[];
      if (sceneIdx >= scenes.length) {
        _addLog('场景不存在');
        return;
      }
      final scene = scenes[sceneIdx];
      final sceneReqKey = '${arcKey}_$sceneIdx';
      final sceneReq = state.worldBook!.sceneRequirements[sceneReqKey] ?? '';

      // v237：与批量路径合并——场景块写进弧线总结条目content，不再生成
      // 独立条目（旧版独立条目在世界书里单独分组，与批量结果割裂）
      // 前置：弧线总结条目必须存在（场景框架/分镜都往它content里追加）
      if (_arcEntryKey(state, arcKey) == null) {
        _addLog('❌ 弧线${arc.number} 总结条目不存在——先批量改编该弧线，再对缺失场景单独改编');
        return;
      }
      // 清理旧版独立条目残留（sceneTag=该场景的独立分组数据）
      state.worldBook!.entries.removeWhere(
        (k, e) => e.sceneTag == sceneReqKey,
      );
      // v239：清扫历史污染（JSON残渣+无头内容并入前块）——必须在阶段B
      // 判定前清（污染内容里的"场景N"字样会干扰框架存在判定）
      _cleanLegacyDebris(state, arcKey);

      // 合并要求：全局 + 弧线 + 场景（与批量一致）
      var sceneReqAll = _reqController.text.trim();
      { // v566：改编圣经注入（批量链路同权）
        final bible = state.worldBook?.adaptBible.trim() ?? '';
        if (bible.isNotEmpty) {
          sceneReqAll = (sceneReqAll.isNotEmpty ? '$sceneReqAll\n\n' : '') +
              '【改编圣经（全书级映射，最高优先级强制执行）】\n'
              '所有人物/设定/规则必须按映射替换，禁止出现未替换的原著元素名。\n$bible';
        }
      }
      final arcReq = state.worldBook!.arcRequirements[arcKey] ?? '';
      if (arcReq.isNotEmpty)
        sceneReqAll =
            (sceneReqAll.isNotEmpty ? '$sceneReqAll\n\n' : '') +
            '【本弧线专属要求】\n$arcReq';
      if (sceneReq.isNotEmpty)
        sceneReqAll =
            (sceneReqAll.isNotEmpty ? '$sceneReqAll\n\n' : '') +
            '【本场景专属要求】\n$sceneReq';

      // 全量弧线数据（框架prompt按si索引取场景，不能裁剪成单场景）
      var arcItem = _buildArcItemData(state, arc);
      if (state.worldBook!.adaptMode == 'deduce') state.worldBook!.deduceMode = true;
      if (state.worldBook!.adaptMode == 'reskin') state.worldBook!.deduceMode = false;
      final deduce = state.worldBook!.deduceMode;
      final config = state.getApiConfig('wb');
      // v385：勾选框未勾选=不注入声明
      final declaration =
          (state.worldBook?.arcDeclEnabled[arc.number.toString()] ?? true)
          ? _declarationText(state, arc.number)
          : '';

      // 上下文与批量一致：改编后人设卡优先，无人设卡时原著九件套兜底
      final arcSummaryText = _castFromArcEntry(state, arcKey);
      final arcContextBuf = StringBuffer();
      if (arcSummaryText.isEmpty) {
        ['characters', 'conflicts', 'foreshadowing', 'arc_functions',
         'irreversible_changes', 'emotional_curve', 'author_fantasy',
        ].forEach((k) {
          final v = (arcItem['analysis']?['arc'] ?? const {})[k];
          if (v != null && v.toString().isNotEmpty && v.toString() != '[]') {
            arcContextBuf.writeln('$k：$v');
          }
        });
      } else {
        arcContextBuf.writeln(arcSummaryText);
      }
      // 已改编框架（其它场景的块头两行——自我投喂，风格统一）
      final adaptedFramesBuf = StringBuffer();
      for (var pi = 0; pi < scenes.length; pi++) {
        final blk = _sceneBlockFromArcEntry(state, arcKey, pi);
        if (blk.isEmpty) continue;
        final lines = blk.split('\n').where((l) => l.trim().isNotEmpty).toList();
        adaptedFramesBuf.writeln(lines.take(2).join('\n'));
      }

      // v258：原著角色定位表（框架/填充两阶段共用）
      final castRoles = ((arcItem['analysis']?['arc'] ?? const {})['characters'] as List? ?? [])
          .whereType<Map>()
          .map((m) => Map<String, dynamic>.from(m))
          .toList();
      // 阶段B：场景框架（该场景块不存在时生成；有框架只填分镜）
      final oldBlock = _sceneBlockFromArcEntry(state, arcKey, sceneIdx);
      if (oldBlock.isEmpty) {
        final frameSys = PromptBuilder.buildSceneFrameSystemPrompt(
          deduce,
          hasRequirements: true, // 点了单独改编=明确要改编（v229语义）
          jsonMode: config.formatMode == 'json',
        );
        final frameUser = PromptBuilder.buildSceneFrameUserPrompt(
          arcItem,
          sceneIdx,
          sceneReqAll,
          declaration,
          arcContext: arcContextBuf.toString(),
          adaptedFrames: adaptedFramesBuf.toString(),
          deduce: deduce,
          castRoles: castRoles,
        );
        if (mounted) {
          final confirmed = await PromptPreview.maybePreview(
            context,
            sysPrompt: frameSys,
            userPrompt: frameUser,
            title: '场景框架预览（弧线${arc.number}场景${sceneIdx + 1}）',
            enabled: state.wbPromptPreview,
          );
          if (!confirmed) {
            _addLog('已取消（场景${sceneIdx + 1}）');
            return;
          }
        }
        final frameResult = await state.api.callApi(
          systemPrompt: frameSys,
          userPrompt: frameUser,
          apiConfig: config,
        );
        if (!frameResult.isSuccess) {
          _addLog('❌ 场景${sceneIdx + 1}框架失败：${frameResult.error}');
          return;
        }
        final frameContent = _extractContentFromJson(frameResult.content, jsonMode: config.formatMode == 'json');
        if (frameContent.isEmpty) {
          _addLog('❌ 场景${sceneIdx + 1}框架解析失败');
          return;
        }
        final mergedFrame = _appendSceneToArcEntry(state, arcKey, frameContent);
        if (!mergedFrame) {
          _addLog('❌ 场景${sceneIdx + 1}框架追加失败，终止');
          return;
        }
        state.saveWorldBook();
        _addLog('✓ 场景${sceneIdx + 1}框架已生成并合并进弧线条目');
      } else {
        _addLog('场景${sceneIdx + 1}框架已存在（直接填分镜）');
      }

      // 阶段C：分镜填充（总是执行——重新生成=重新改编该场景）
      final fillSys = PromptBuilder.buildShotFillSystemPrompt(
        deduce,
        hasRequirements: true,
        jsonMode: config.formatMode == 'json',
      );
      final fillUser = PromptBuilder.buildSceneShotFillUserPrompt(
        entryContent: _sceneBlockFromArcEntry(state, arcKey, sceneIdx),
        scene: scene.toJson(),
        sceneIdx: sceneIdx,
        castRoles: castRoles,
        declaration: declaration,
        requirements: sceneReqAll,
        cast: _castFromArcEntry(state, arcKey),
        deduce: deduce,
      );
      if (mounted) {
        final confirmed = await PromptPreview.maybePreview(
          context,
          sysPrompt: fillSys,
          userPrompt: fillUser,
          title: '分镜填充预览（弧线${arc.number}场景${sceneIdx + 1}）',
          enabled: state.wbPromptPreview,
        );
        if (!confirmed) {
          _addLog('已取消分镜填充（场景${sceneIdx + 1}）');
          return;
        }
      }
      var fillResult = await state.api.callApi(
        systemPrompt: fillSys,
        userPrompt: fillUser,
        apiConfig: config,
      );
      // v238：失败/无分镜标记重试1次（与批量对齐；AI输出格式漂移或偶发空返回）
      var fillRetry = 0;
      while ((!fillResult.isSuccess ||
              !_extractFillContent(fillResult.content, jsonMode: config.formatMode == 'json').contains('分镜')) &&
          fillRetry < 2 &&
          !state.api.isAborted &&
          !state.userAborted) {
        fillRetry++;
        _addLog('场景${sceneIdx + 1}填充结果异常，重试（第$fillRetry/2次）...');
        await Future.delayed(const Duration(seconds: 5));
        if (state.api.isAborted) break;
        fillResult = await state.api.callApi(
          systemPrompt: fillSys,
          userPrompt: fillUser,
          apiConfig: config,
        );
      }
      final fillContent = _extractFillContent(fillResult.content, jsonMode: config.formatMode == 'json');
      if (fillResult.isSuccess && fillContent.contains('分镜')) {
        final merged = _replaceSceneBlockInArcEntry(
          state,
          arcKey,
          sceneIdx,
          fillContent,
          fallbackSummary: scene.summary,
        );
        if (merged) {
          _addLog('✓ 场景${sceneIdx + 1}改编完成（已合并进弧线${arc.number}条目）');
        } else {
          _addLog('⚠️ 场景${sceneIdx + 1}分镜合并失败（场景块未找到）');
        }
      } else {
        final diag = fillResult.error != null
            ? fillResult.error
            : '返回无分镜标记，前80字：${_preview(fillResult.content)}';
        _addLog('⚠️ 场景${sceneIdx + 1}分镜填充失败：$diag');
      }
    } catch (e) {
      _addLog('异常：$e');
    } finally {
      state.saveWorldBook();
      state.refresh();
      setState(() {
        _isGenerating = false;
        _statusText = '';
      });
    }
  }

  /// 构建弧线数据（v468 getWBAllArcs的item结构）
  /// v566：改编圣经面板（折叠——编辑态自适应增高，点外收缩）
  Widget _buildBiblePanel(AppState state) {
    final bible = state.worldBook?.adaptBible ?? '';
    return ExpansionTile(
      tilePadding: const EdgeInsets.symmetric(horizontal: 12),
      title: Text(
        '📖 改编圣经（全书级映射，生成链路强制注入${bible.isEmpty ? '' : '·已定稿${bible.length}字'}）',
        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
      ),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '四段式：【全书基调】/【人物映射】原→新（定位·别称层次）/【设定映射】/【规则映射】。'
                '拿不准的行用"？原著名（疑似…）"标出。生成链路（概述/框架/分镜/创作）全部强制注入，禁止出现未替换的原著元素。',
                style: TextStyle(fontSize: 10.5, color: Colors.grey),
              ),
              const SizedBox(height: 6),
              _CollapseReqField(
                controller: _bibleController,
                labelText: '改编圣经',
                fontSize: 12,
                expandLines: 14,
                collapseLines: 3,
                onChanged: (v) {
                  if (state.worldBook == null) state.worldBook = WorldBook();
                  state.worldBook!.adaptBible = v;
                  state.saveWorldBook();
                },
              ),
              const SizedBox(height: 6),
              Row(children: [
                MiniButton(
                  label: 'AI生成初稿',
                  primary: false,
                  onTap: () => _generateBible(state, incremental: false),
                ),
                const SizedBox(width: 6),
                MiniButton(
                  label: '增量补充',
                  primary: false,
                  onTap: () => _generateBible(state, incremental: true),
                ),
              ]),
            ],
          ),
        ),
      ],
    );
  }

  /// v566：AI生成/增量补充改编圣经（素材=已拆解弧线的概述+人物）
  Future<void> _generateBible(
    AppState state, {
    required bool incremental,
  }) async {
    if (_isGenerating) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('正在生成中，请等待')));
      return;
    }
    final existing = state.worldBook?.adaptBible ?? '';
    if (incremental && existing.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('圣经为空，请先用"AI生成初稿"')));
      return;
    }
    final arcs = _getAllArcs(state);
    if (arcs.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('暂无已拆解弧线（先扫描/生成弧线）')));
      return;
    }
    final materials = StringBuffer();
    for (final arc in arcs.take(30)) {
      final item = _buildArcItemData(state, arc);
      final chars = (item['characters'] as List?)?.take(10).join('、') ?? '';
      materials.writeln('── 弧线${arc.number}《${item['title']}》'
          '（${item['chapter_range']}）');
      final summary = (item['summary'] ?? '').toString();
      materials.writeln(summary.length > 400
          ? '${summary.substring(0, 400)}…'
          : summary);
      if (chars.isNotEmpty) materials.writeln('主要人物：$chars');
    }
    final config = state.getApiConfig('wb');
    setState(() => _isGenerating = true);
    try {
      _addLog('📖 开始${incremental ? '增量补充' : '生成'}改编圣经'
          '（素材弧线${arcs.length}条）');
      final result = await state.api.callApi(
        systemPrompt: PromptBuilder.buildAdaptBibleSystemPrompt(
          incremental: incremental,
        ),
        userPrompt: PromptBuilder.buildAdaptBibleUserPrompt(
          existingBible: incremental ? existing : '',
          materials: materials.toString(),
        ),
        apiConfig: config,
      );
      if (!result.isSuccess) {
        _addLog('❌ 圣经生成失败：${result.error}');
        return;
      }
      var bible = TextCleaner.normalizeAiOutput(
        result.content,
        jsonMode: config.formatMode == 'json',
      ).trim();
      if (bible.isEmpty) {
        _addLog('⚠️ 圣经生成返回为空');
        return;
      }
      _bibleController.text = bible;
      if (state.worldBook == null) state.worldBook = WorldBook();
      state.worldBook!.adaptBible = bible;
      state.saveWorldBook();
      _addLog('✓ 改编圣经已保存（${bible.length}字）');
      if (mounted) setState(() {});
    } finally {
      if (mounted) setState(() => _isGenerating = false);
    }
  }

  Map<String, dynamic> _buildArcItemData(AppState state, Arc arc) {
    final arcKey = arc.number.toString();
    final analysis = state.arcAnalyses[arcKey];
    final scenes = state.arcScenes[arcKey] ?? analysis?.scenes ?? <Scene>[];

    final arcData = <String, dynamic>{
      'title': arc.title,
      'status': arc.status,
      'chapter_range': arc.chapterRange,
      // v202：概述优先拆解结果（阶段A弧线总结条目用优质概述生成）
      'summary': (analysis?.arcSummary.isNotEmpty == true)
          ? analysis!.arcSummary
          : arc.summary,
      'scenes': scenes.map((s) => s.toJson()).toList(),
      'characters': analysis?.metadata?['characters'] ?? [],
      'conflicts': analysis?.metadata?['conflicts'] ?? [],
      'foreshadowing': analysis?.metadata?['foreshadowing'] ?? [],
      'arc_functions': analysis?.metadata?['arc_functions'] ?? [],
      'irreversible_changes': analysis?.metadata?['irreversible_changes'] ?? '',
      'emotional_curve': analysis?.metadata?['emotional_curve'] ?? '',
      'author_fantasy': analysis?.metadata?['author_fantasy'] ?? [],
      'ink_hobby': analysis?.metadata?['ink_hobby'], // v219笔墨癖好
      // v227：世界观facts（阶段A生成【世界观设定】的数据源——
      // 此前漏传，AI手里没有facts只能全写"本弧线未涉及"）
      'worldbuilding_facts': analysis?.metadata?['worldbuilding_facts'] ?? [],
    };

    return {
      'scanArc': {'number': arc.number},
      'analysis': {'arc': arcData},
    };
  }

  /// 解析世界书API响应，返回添加的条目数
  int _parseWBResponse(AppState state, String content, int arcNumber) {
    final json = JsonRepair.parseResponse(content);
    if (json == null) {
      _addLog('世界书JSON解析失败');
      return 0;
    }
    // v468的prompt要求entries为JSON数组（"entries": [...]），逐元素回填条目；
    // 同时兼容AI偶发返回object格式（uid为key的map），双格式容错
    final rawEntries = json['entries'];
    final List entryList;
    if (rawEntries is List) {
      entryList = rawEntries;
    } else if (rawEntries is Map) {
      entryList = rawEntries.values.toList();
    } else {
      _addLog('弧线$arcNumber：AI返回格式异常，未找到entries数组');
      return 0;
    }

    int added = 0;
    for (final value in entryList) {
      if (value is! Map) continue; // 跳过残缺元素
      final entry = WBEntry.fromJson(Map<String, dynamic>.from(value));
      // 入库清洗：剥AI自加的行首装饰emoji——发送AI/ST导出零负担，浏览层图标由渲染另行添加
      entry.content = TextCleaner.stripDecorativeEmoji(entry.content);
      // v245：九件套结构段去重——AI漂移输出重复【标记】行（如【世界观设定】
      // 出现两次，第二次空块紧跟），只保留首次出现，后续重复行及其空块
      // （到下一个标记/文末）整段删除；若首块为空则保留内容完整的那个块
      entry.content = _dedupeStructSections(entry.content);
      entry.arcKey = arcNumber.toString();
      entry.uid =
          '${arcNumber}_${DateTime.now().millisecondsSinceEpoch}_$added';
      state.worldBook!.entries[entry.uid] = entry;
      added++;
    }

    _addLog('弧线$arcNumber：添加$added个条目');

    // v249：同弧线碎片合并——json严格模式下Gemini可能把弧线总结拆成
    // 多个entries元素（每个comment都是"弧线N"变体=条目名称重复；碎片
    // 条目各带一部分九件套内容）。全部合并进第一个（内容拼接+去重），
    // 其余删除，保证每个弧线恰好1个总结条目
    final arcKeyStr = arcNumber.toString();
    final fragments = <MapEntry<String, WBEntry>>[];
    state.worldBook!.entries.forEach((k, e) {
      if (e.arcKey == arcKeyStr &&
          (e.sceneTag == null || e.sceneTag!.isEmpty)) {
        fragments.add(MapEntry(k, e));
      }
    });
    if (fragments.length > 1) {
      final main = fragments.first;
      final buf = StringBuffer(main.value.content.trimRight());
      for (var i = 1; i < fragments.length; i++) {
        buf.write('\n');
        buf.write(fragments[i].value.content.trim());
      }
      main.value.content = _dedupeStructSections(buf.toString());
      for (var i = 1; i < fragments.length; i++) {
        state.worldBook!.entries.remove(fragments[i].key);
      }
      _addLog('弧线$arcNumber：已合并${fragments.length}个碎片条目为1个');
    }

    state.refresh();
    return added;
  }

  // ===== 自定义条目（v468 wb-custom-form） =====
  void _showAddCustomDialog(AppState state) {
    final commentCtrl = TextEditingController();
    final keyCtrl = TextEditingController();
    final contentCtrl = TextEditingController();
    final orderCtrl = TextEditingController(text: '100');
    bool constant = false;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('添加自定义条目'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: commentCtrl,
                  decoration: const InputDecoration(
                    labelText: '条目名称',
                    isDense: true,
                    hintText: '如：世界观设定',
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: keyCtrl,
                  decoration: const InputDecoration(
                    labelText: '触发关键词（逗号分隔）',
                    isDense: true,
                    hintText: '如：大陆,帝国,魔法',
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: contentCtrl,
                  decoration: const InputDecoration(
                    labelText: '条目内容',
                    isDense: true,
                  ),
                  maxLines: 6,
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    SizedBox(
                      width: 100,
                      child: TextField(
                        controller: orderCtrl,
                        decoration: const InputDecoration(
                          labelText: '优先级',
                          isDense: true,
                        ),
                        keyboardType: TextInputType.number,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: CheckboxListTile(
                        value: constant,
                        onChanged: (v) =>
                            setDialogState(() => constant = v ?? false),
                        title: const Text(
                          '常驻（不需触发）',
                          style: TextStyle(fontSize: 12),
                        ),
                        dense: true,
                        controlAffinity: ListTileControlAffinity.leading,
                        contentPadding: EdgeInsets.zero,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () {
                if (commentCtrl.text.trim().isEmpty) return;
                if (state.worldBook == null) state.worldBook = WorldBook();
                final uid = 'custom_${DateTime.now().millisecondsSinceEpoch}';
                state.worldBook!.entries[uid] = WBEntry(
                  uid: uid,
                  comment: commentCtrl.text.trim(),
                  key: keyCtrl.text.trim(),
                  // 入库清洗：与AI生成条目同规则
                  content: TextCleaner.stripDecorativeEmoji(contentCtrl.text),
                  order: int.tryParse(orderCtrl.text) ?? 100,
                  constant: constant,
                );
                state.saveWorldBook();
                state.refresh();
                Navigator.pop(ctx);
              },
              child: const Text('添加'),
            ),
          ],
        ),
      ),
    );
  }

  /// 紧凑开关：Checkbox+文字（替代FilterChip，省面积，Wrap里全显不用滑动）
  /// v225：模式芯片（三选一，选中高亮；再点取消回auto=按有无要求自动判断）
  Widget _modeChip(AppState state, String label, String mode, String tip) {
    if (state.worldBook == null) state.worldBook = WorldBook();
    final selected = state.worldBook!.adaptMode == mode;
    return GestureDetector(
      onTap: () {
        setState(() {
          state.worldBook!.adaptMode = selected ? 'auto' : mode;
          // 推演联动旧deduceMode（底层prompt分路读它）
          state.worldBook!.deduceMode = state.worldBook!.adaptMode == 'deduce';
        });
        state.saveWorldBook();
        if (!selected) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(tip), duration: const Duration(seconds: 3)),
          );
        }
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: selected ? V469Style.accent : Colors.transparent,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: selected ? V469Style.accent : Colors.grey.shade300,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11,
            color: selected ? Colors.white : V469Style.textSec,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
          ),
        ),
      ),
    );
  }

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

/// v242：可折叠要求输入框——平时1行高，点击聚焦展开多行方便编辑，失焦收回。
/// 非弹窗（就地展开），AnimatedSize平滑过渡（v468/A-/A+等按钮同款就地编辑理念）
class _CollapseReqField extends StatefulWidget {
  const _CollapseReqField({
    required this.controller,
    required this.labelText,
    this.hintText,
    this.fontSize = 12,
    this.expandLines = 6,
    this.collapseLines = 1, // v566：非编辑态显示行数（圣经等大字段用3）
    this.onChanged,
  });

  final TextEditingController controller;
  final String labelText;
  final String? hintText;
  final double fontSize;
  final int expandLines;
  final int collapseLines;
  final ValueChanged<String>? onChanged;

  @override
  State<_CollapseReqField> createState() => _CollapseReqFieldState();
}

class _CollapseReqFieldState extends State<_CollapseReqField> {
  final _focus = FocusNode();
  bool _expanded = false;

  @override
  void initState() {
    super.initState();
    // v564：展开后只在点框外才收缩（onTapOutside）——框内拖动选区时
    // 焦点抖动不再误触发收缩
    _focus.addListener(() {
      if (mounted && _focus.hasFocus) setState(() => _expanded = true);
    });
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // v563：去掉AnimatedSize动画——展开动画期间控件位移导致点选光标
    // 位置映射到旧布局（点不准、只能拖动定位），改为即时展开收起
    return TextField(
        controller: widget.controller,
        focusNode: _focus,
        style: TextStyle(fontSize: widget.fontSize),
        // v562：编辑态自适应增高到显示全部文字（maxLines=null），失焦缩回单行
        maxLines: _expanded ? widget.expandLines : widget.collapseLines,
        minLines: 1,
        keyboardType: TextInputType.multiline,
        onTapOutside: (_) {
          if (mounted) setState(() => _expanded = false); // v564：点框外才缩回
        },
        decoration: InputDecoration(
          labelText: widget.labelText,
          hintText: _expanded ? widget.hintText : null,
          border: const OutlineInputBorder(),
          isDense: true,
        ),
        onChanged: widget.onChanged,
    );
  }
}
