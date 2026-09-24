import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:typed_data';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;

import 'package:flutter/material.dart';

import '../widgets/slice_viewer_sheet.dart';
import 'package:provider/provider.dart';

import '../services/file_picker_service.dart';
import '../utils/encoding_detector.dart';
import '../state/app_state.dart';
import '../models/writing.dart';
import '../models/api_config.dart';
import '../utils/prompt_builder.dart';
import '../utils/prompt_preview.dart';
import '../utils/text_cleaner.dart';
import '../widgets/api_config_panel.dart';
import '../utils/v469_style.dart';
import '../widgets/api_log_panel.dart';
import '../widgets/v119_ui.dart';
import '../widgets/req_field.dart';
import '../widgets/content_font.dart';

class WritingPage extends StatefulWidget {
  const WritingPage({super.key});

  @override
  State<WritingPage> createState() => _WritingPageState();
}

class _WritingPageState extends State<WritingPage>
    with AutomaticKeepAliveClientMixin {
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

  /// inline浏览当前正文（v469单页样式：不跳页，创作页内展开）
  String? _viewerKey;
  WritingItem? _viewerOverride; // v377b：历史版本只读查看（不在writings列表里，key查不到）
  double _viewerFontSize = 15;
  bool _viewerEditing = false;
  final TextEditingController _viewerCtrl = TextEditingController();

  // 单分镜操作：编辑中的分镜key（wkey_shotIdx）+生成中标志
  String? _shotEditKey;
  bool _shotGenBusy = false;
  final TextEditingController _shotEditCtrl = TextEditingController();
  // 保存按钮反馈：true=显示"✓已保存"（1.5s后自动还原）
  bool _viewerSavedFlash = false;
  bool _shotSavedFlash = false;

  /// 按分镜头切块（分镜N：独立行+9维度行+正文段，到下一分镜头）
  List<({int idx, String header, int start, int end})> _splitShots(
    String content,
  ) {
    // v256：分镜头形态容忍+括号/【】/#装饰（（分镜1：/【分镜1】/分镜1：）
    // v265：\s*→[^\S\n]*——\s*吃换行符导致块头匹配吞掉分镜头前的空行
    // （^锚到空行+\s*吞\n落到"分镜"上），块从空行开始→structEnd行0=空行
    // 行1=真分镜头（非维度行→break）→keptStruct空→单分镜生成把整块
    // 结构删光只留新正文（用户v264实测症状）
    final re = RegExp(
      r'^[^\u4e00-\u9fa5\n]*[\[（(【]*#*[^\S\n]*[\[（(【]?分[镜景](头)?[^\S\n]*(\d+[^\S\n]*[\]）)】]?[^\S\n]*[：:]?|[\]）)】]?[^\S\n]*[：:])',
      multiLine: true,
    );
    final ms = re.allMatches(content).toList();
    final out = <({int idx, String header, int start, int end})>[];
    for (var i = 0; i < ms.length; i++) {
      final m = ms[i];
      final end = i + 1 < ms.length ? ms[i + 1].start : content.length;
      final headerLine = content.substring(m.start, m.end);
      out.add((idx: i, header: headerLine, start: m.start, end: end));
    }
    return out;
  }

  /// 分镜结构行（header+维度行）从块里提取
  /// 规则：跳过空行后，从首行（分镜头）起连续收集结构行（分镜头/维度行），遇正文段停
  /// 写回世界书用——零正文内容（正文不进世界书）
  /// v369fix：按标签提取维度行值（标签容错对齐_shotStructLines——
  /// emoji前缀/中文/英文/中英括号包装全兼容；v369首版正则要求英文标签
  /// 必现导致全空转，前置分镜节整个不出现的根因）
  String _dimValue(String block, List<String> labels) {
    final labelAlt = labels.join('|');
    final re = RegExp(
      '^[^一-鿿\\n]*($labelAlt)(\\s*[(（][A-Za-z /]+[)）])?\\s*[：:]\\s*(.+)\$',
    );
    for (final line in block.split('\n')) {
      final m = re.firstMatch(line.trim());
      if (m != null) return m.group(3)!.trim();
    }
    return '';
  }

  String _shotStructLines(String block) {
    final lines = block.split('\n');
    final struct = <String>[];
    var started = false;
    final structRe = RegExp(
      r'^[^\u4e00-\u9fa5\n]*(投放信息|投放|作者意图|意图|转场手法|转场|篇幅|文笔节奏|功能抽象|焦点|镜头类型|视角|镜头子类型|叙述|语感|笔墨|语感锚|笔墨配额|叙事功能)(\s*[(（][A-Za-z /]+[)）])?\s*(/\s*[A-Za-z /]+)?\s*[：:]',
    );
    final enRe = RegExp(
      r'^[^\u4e00-\u9fa5\n]*(Focus|Shot Type|POV|Info|Intent|Transition|Length|Prose Style|Abstract|Voice|Ink)\s*[：:]',
      caseSensitive: false,
    );
    for (var i = 0; i < lines.length; i++) {
      final t = lines[i].trim();
      if (t.isEmpty && !started) continue; // 头部空行跳过
      if (!started) {
        // 首个非空行必须是分镜头行（分镜N：/【分镜N】/（分镜1：…）
        /// 括号形态——v256：AI把结构行括号包装（(分镜1：xxx)），此前
        /// 匹配失败→struct空→保存后不写回世界书）
        if (t.contains('分镜') &&
            RegExp(
              r'^[^\u4e00-\u9fa5\n]*[\[（(【]?分[镜景](头)?\s*\d*\s*[\]）)】]?\s*[：:]?',
            ).hasMatch(t)) {
          // 剥外层括号包装（（分镜1：xxx）→分镜1：xxx）
          var headLine = lines[i];
          if (RegExp(r'^[（(]').hasMatch(t) && RegExp(r'[）)]\s*$').hasMatch(t)) {
            headLine = t.substring(1, t.length - 1).trim();
          }
          struct.add(headLine);
          started = true;
        } else {
          break; // 块头不是分镜头行（异常结构），放弃提取
        }
        continue;
      }
      // 已开始：维度行继续收，空行跳过，正文段停
      // v259/v262：污染"维度行"=正文以维度值身份藏身，视为正文段停止收
      // 集——防止污染结构写回世界书（污染闭环源头）。阈值=共享判定
      var dimVal = '';
      final dm = structRe.firstMatch(t) ?? enRe.firstMatch(t);
      if (dm != null) {
        dimVal = t.substring(dm.end).trim();
      }
      if ((structRe.hasMatch(t) || enRe.hasMatch(t)) &&
          !TextCleaner.dimValuePolluted(dimVal)) {
        struct.add(lines[i]);
      } else if (t.isNotEmpty) {
        break; // 首个正文段后停（含污染行）
      }
    }
    return struct.join('\n');
  }

  /// 分镜结构写回世界书（整块替换：分镜N：+9维度行，边界到下一分镜行）
  bool _writeShotBackToWB(
    AppState state,
    WritingItem w,
    int shotIdx,
    String newStruct,
  ) {
    final wb = state.worldBook;
    if (wb == null) {
      _addLog('⚠️ 世界书为空，写回跳过');
      return false;
    }
    // v259/v262：写回防火墙终检（共享判定）——newStruct任何行的维度值
    // 污染（正文以维度值身份藏身），拒绝写回防污染世界书（闭环源头堵断）
    for (final line in newStruct.split('\n')) {
      final t = line.trim();
      final dm = RegExp(
        r'^[^\u4e00-\u9fa5\n]*(投放信息|投放|作者意图|意图|转场手法|转场|篇幅|文笔节奏|功能抽象|焦点|镜头类型|视角|镜头子类型|叙述|语感|笔墨|语感锚|笔墨配额|叙事功能|Focus|Shot Type|POV|Info|Intent|Transition|Length|Prose Style|Abstract|Voice|Ink)(\s*[(（][A-Za-z /]+[)）])?\s*[：:]\s*(.*)$',
      ).firstMatch(t);
      if (dm != null && TextCleaner.dimValuePolluted(dm.group(3) ?? '')) {
        _addLog('⚠️ 分镜${shotIdx + 1}结构维度值疑似正文混入（${(dm.group(1) ?? '')}），拒绝写回世界书');
        return false;
      }
    }
    final arcKey = w.arcKey;
    final sceneTag = '${w.arcKey}_${w.sceneIdx}';
    // 匹配条目数诊断
    var arcMatched = 0;
    for (final e in wb.entries.values) {
      if (e.arcKey != arcKey) continue;
      arcMatched++;
      // 单条目结构（v135+）或旧场景散条目
      final isArcEntry = e.sceneTag == null || e.sceneTag!.isEmpty;
      if (!isArcEntry && e.sceneTag != sceneTag) continue;
      // v276：读侧拆粘连（历史bug写入的"维度行…分镜N："粘连形态——
      // 拆行修复偏移计算，修复后的内容随本次saveWorldBook持久化）
      final content = TextCleaner.repairGluedShotEntry(e.content);
      // 定位场景块（旧散条目=整个content）
      int searchFrom = 0, searchTo = content.length;
      if (isArcEntry) {
        final sm = RegExp('场景\\s*${w.sceneIdx + 1}\\s*[：:]')
            .firstMatch(content);
        if (sm == null) {
          _addLog('⚠️ 条目里定位不到场景${w.sceneIdx + 1}头（场景块丢失？）');
          continue;
        }
        final nextRe = RegExp(
          r'场景\s*\d+\s*[：:]|【世界观设定】|【人设】|【矛盾冲突】|【伏笔】|【弧线功能】|【不可逆变化】|【情绪曲线】|【作者脑洞】',
        );
        final nm = nextRe
            .allMatches(content)
            .where((m) => m.start >= sm.end)
            .toList();
        searchFrom = sm.end;
        searchTo = nm.isEmpty ? content.length : nm.first.start;
      }
      final block = content.substring(searchFrom, searchTo);
      final shotRe = RegExp(
        // v265：\s*→[^\S\n]*与_splitShots同步（不吃换行，定位一致）
        r'^[^\u4e00-\u9fa5\n【】\[\]#*]*#*[^\S\n]*[\[【]?分[镜景](头)?[^\S\n]*(\d+[^\S\n]*[\]】]?[^\S\n]*[：:]?|[\]】]?[^\S\n]*[：:])',
        multiLine: true,
      );
      final allShots = shotRe.allMatches(block).toList();
      // 分镜定位：编号优先，超界按出现顺序（group(2)=编号/冒号段，从中剥数字）
      RegExpMatch? target;
      for (final m in allShots) {
        final numStr = RegExp(r'\d+').firstMatch(m.group(2) ?? '')?.group(0);
        if (int.tryParse(numStr ?? '') == shotIdx + 1) {
          target = m;
          break;
        }
      }
      target ??= shotIdx < allShots.length ? allShots[shotIdx] : null;
      if (target == null) {
        _addLog(
          '⚠️ 场景${w.sceneIdx + 1}块内定位不到分镜${shotIdx + 1}（块内${allShots.length}个分镜）',
        );
        continue;
      }
      // 目标分镜块边界：该分镜行起点→下一分镜行/场景块尾（v153多行结构整块替换）
      final tStart = target.start;
      final nexts = shotRe
          .allMatches(block)
          .where((m) => m.start > tStart)
          .toList();
      final endAbs = nexts.isEmpty ? searchTo : searchFrom + nexts.first.start;
      // 编辑框结构行原样写回（多行：分镜头行+维度行，无转换）
      final structLines = newStruct
          .split('\n')
          .map((l) => l.trim())
          .where((l) => l.isNotEmpty)
          .toList();
      if (structLines.isEmpty) {
        _addLog('⚠️ 编辑框结构为空，写回跳过');
        return false;
      }
      final edited = structLines.join('\n');
      // v261：维度数降级守卫——新结构维度行数少于世界书原分镜块的维度
      // 行数=写回会让世界书丢维度（粘行内容被_shotStructLines提前截断
      // 的形态：正文粘维度行→收集停→结构缺尾部维度），拒绝写回防降级
      final dimLineRe = RegExp(
        r'^[^\u4e00-\u9fa5\n]*(投放信息|投放|作者意图|意图|转场手法|转场|篇幅|文笔节奏|功能抽象|焦点|镜头类型|视角|镜头子类型|叙述|语感|笔墨|语感锚|笔墨配额|叙事功能|Focus|Shot Type|POV|Info|Intent|Transition|Length|Prose Style|Abstract|Voice|Ink)(\s*[(（][A-Za-z /]+[)）])?\s*[：:]',
      );
      int dimCount(List<String> ls) =>
          ls.where((l) => dimLineRe.hasMatch(l.trim())).length;
      final origBlock = content.substring(searchFrom + tStart, endAbs);
      final origDims = dimCount(origBlock.split('\n'));
      final newDims = dimCount(structLines);
      if (newDims < origDims) {
        _addLog('⚠️ 分镜${shotIdx + 1}新结构${newDims}条维度<世界书原有${origDims}条（疑似正文粘行截断），拒绝写回防丢维度');
        return false;
      }
      // v276：尾部换行修复——替换区间[分镜N行→分镜N+1行start)包含分镜
      // N+1行前的换行符，join不带尾换行=换行被吃掉→下一分镜头粘到末条
      // 维度行（用户实测'分镜2的字跟到了分镜1的内容末尾'+编辑框
      /// '功能抽象:…aaa分镜2:'粘连形态）。补'\n'恢复分隔
      e.content =
          content.substring(0, searchFrom + target.start) +
          edited +
          '\n' +
          content.substring(endAbs);
      state.saveWorldBook();
      _addLog('✓ 分镜${shotIdx + 1}结构已写回世界书');
      return true;
    }
    _addLog(
      arcMatched == 0
          ? '⚠️ 世界书里没有arcKey=$arcKey的条目（写回失败）'
          : '⚠️ 分镜${shotIdx + 1}未在世界书条目中找到',
    );
    return false;
  }

  /// 全文保存：分镜结构行变化写回世界书+全文写json+纯正文写txt
  /// 返回写回世界书的分镜数
  int _saveFullWriting(AppState state, WritingItem w, String oldContent) {
    var written = 0;
    // diff每个分镜块：编辑前后的结构行不同→写回世界书
    final oldShots = _splitShots(oldContent);
    final newShots = _splitShots(w.content);
    final n = newShots.length < oldShots.length
        ? newShots.length
        : oldShots.length;
    for (var i = 0; i < n; i++) {
      final oldStruct = _shotStructLines(
        oldContent.substring(oldShots[i].start, oldShots[i].end),
      );
      final newStruct = _shotStructLines(
        w.content.substring(newShots[i].start, newShots[i].end),
      );
      if (oldStruct.trim() != newStruct.trim() && newStruct.trim().isNotEmpty) {
        if (_writeShotBackToWB(state, w, i, newStruct)) written++;
      }
    }
    // 正文+全文持久化：json（完整对象）+txt（纯正文）
    state.saveWritings();
    var txt = TextCleaner.stripShotHeaders(w.content);
    final note = _txtNote(state, model: w.model, temp: w.temperature);
    if (note != null) txt = '$note\n\n$txt';
    final path = state.storage.getWritingPath(
      w.arcKey,
      w.sceneIdx,
      w.sceneName,
      w.chapterRange,
      w.version,
    );
    state.storage.writeFile(path, txt);
    return written;
  }

  /// 单分镜正文生成（分镜卡✨按钮）：只生成该分镜的正文段落，替换块内正文部分
  /// v269：弧线概述提取（逐镜上下文）——弧线条目content里的概述段
  /// （首个"场景N："前的概要文本，500字内）或独立概述条目
  String _arcSummaryForShot(AppState state, String arcKey) {
    final wb = state.worldBook;
    if (wb == null) return '';
    // 优先：弧线主条目首个场景块之前的内容（概述+九件套开头的概要）
    final arcEntry = wb.entries.values
        .where(
          (e) => e.arcKey == arcKey && (e.sceneTag == null || e.sceneTag!.isEmpty),
        )
        .toList();
    if (arcEntry.isNotEmpty) {
      final c = arcEntry.first.content;
      final sm = RegExp(r'场景\s*\d+\s*[：:]').firstMatch(c);
      final head = sm == null ? c : c.substring(0, sm.start);
      // 剥九件套标记段（标记+其后内容整段删——只要首个【标记】前的
      // 叙述性概述；split只删标记不删内容会把癖好/世界观并进概述）
      final firstMark = RegExp('【[^】]{2,12}】').firstMatch(head);
      final summary = (firstMark == null ? head : head.substring(0, firstMark.start)).trim();
      return summary;
    }
    // 兜底：独立概述条目（"弧线N概述"）
    final ov = wb.entries.values
        .where(
          (e) =>
              (e.arcKey ?? '').isEmpty &&
              (e.comment?.contains('概述') ?? false) &&
              ((e.key.contains('弧线$arcKey')) ||
                  (e.comment.contains('弧线$arcKey'))),
        )
        .toList();
    return ov.isEmpty ? '' : ov.first.content.trim();
  }

  /// v269：笔墨癖好提取（逐镜上下文）——弧线条目content里【笔墨癖好】
  /// 标记行后的内容（痴迷点/快进点/啰嗦点，300字内）
  String _inkHabitForShot(AppState state, String arcKey) {
    final wb = state.worldBook;
    if (wb == null) return '';
    final arcEntry = wb.entries.values
        .where(
          (e) => e.arcKey == arcKey && (e.sceneTag == null || e.sceneTag!.isEmpty),
        )
        .toList();
    if (arcEntry.isEmpty) return '';
    final c = arcEntry.first.content;
    final m = RegExp('【笔墨癖好】').firstMatch(c);
    if (m == null) return '';
    // 到下一个【标记】或文末
    final nm = RegExp('【[^】]{2,12}】').allMatches(c).where((x) => x.start > m.end).toList();
    final seg = c.substring(m.end, nm.isEmpty ? c.length : nm.first.start).trim();
    return seg;
  }

  /// v640：文风指纹提取（逐镜上下文）——弧线条目content里【文风指纹】
  /// 标记行后的量化指标（平均句长/短句占比/动词密度/对话占比…），200字内
  String _styleDnaForShot(AppState state, String arcKey) {
    final wb = state.worldBook;
    if (wb == null) return '';
    final arcEntry = wb.entries.values
        .where(
          (e) => e.arcKey == arcKey && (e.sceneTag == null || e.sceneTag!.isEmpty),
        )
        .toList();
    if (arcEntry.isEmpty) return '';
    final c = arcEntry.first.content;
    final m = RegExp('【文风指纹】').firstMatch(c);
    if (m == null) return '';
    final nm = RegExp('【[^】]{2,12}】').allMatches(c).where((x) => x.start > m.end).toList();
    final seg = c.substring(m.end, nm.isEmpty ? c.length : nm.first.start).trim();
    return seg.length > 200 ? seg.substring(0, 200) : seg;
  }

  /// v642：步进分块结果切分——按"分镜N："标记切段，逐段剥结构行取正文
  List<String> _splitChunkProse(String resp, int expect) {
    final t = resp.trim();
    if (t.isEmpty) return const [''];
    final segRe = RegExp(r'(?=分[镜景]\s*\d+\s*[：:])');
    final segs = t.split(segRe).where((x) => x.trim().isNotEmpty).toList();
    if (segs.length <= 1) {
      // AI没按结构输出——整段当单镜正文处理
      final whole = TextCleaner.stripShotHeaders(
        TextCleaner.stripDecorativeEmoji(
          TextCleaner.stripWrapQuotes(t),
        ),
      ).trim();
      return [whole];
    }
    final out = <String>[];
    for (final seg in segs) {
      final prose = TextCleaner.stripShotHeaders(
        TextCleaner.stripDecorativeEmoji(
          TextCleaner.stripWrapQuotes(
            TextCleaner.normalizeAiOutput(seg),
          ),
        ),
      ).trim();
      if (prose.isNotEmpty) out.add(prose);
    }
    if (out.length != expect) {
      _addLog('⚠️ 切分${out.length}段≠预期$expect镜——按序对应，缺口当空镜（可补缺失）');
    }
    return out;
  }

  /// v268→v271：补缺失分镜（增量生成）——逐镜生成失败停机/中止后，
  /// 已保存的创作里结构在正文空的分镜逐个补齐。v271改循环扫描式：
  /// 此前一次性预计算missing索引，但每镜生成后w.content被替换（长度/
  /// 块边界变化），后续镜_genSingleShot里shotIdx>=shots.length静默
  /// return无日志=用户实测'补分镜实际没工作，终端就显示补完了'。
  /// 改为每镜后重新扫描找下一个缺失镜（索引永远对当前content），
  /// 连续2镜无进展（生成失败/替换无效）自动停止防死循环
  Future<void> _fillMissingShots(AppState state, WritingItem w) async {
    if (_shotGenBusy || _isGenerating) return;
    state.api.clearAbort();
    state.userAborted = false;
    // 当前content的缺失镜定位（每次重扫）
    int? findMissing() {
      final shots = _splitShots(w.content);
      for (var i = 0; i < shots.length; i++) {
        final block = w.content.substring(shots[i].start, shots[i].end);
        final struct = _shotStructLines(block).trim();
        if (struct.isNotEmpty && block.trim() == struct) return i;
      }
      return null;
    }

    final total = _splitShots(w.content).length;
    if (findMissing() == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('没有缺失正文的分镜'), duration: Duration(seconds: 1)),
      );
      return;
    }
    _addLog('补缺失开始（共$total镜，逐镜扫描增量生成）');
    setState(() => _shotGenBusy = true);
    var done = 0;
    // v274：跳过表——失败镜不再卡死整轮（findMissing返回第一个缺失，
    // 某镜反复失败=循环原地空转2次全停=用户实测'前面有的分镜没生成，
    // 后面有的先生成'的中部空洞+乱序观感）。无进展镜进跳过表，补后面的，
    /// 结束时报告哪些镜没补上（可重进补缺失再试或单镜补）
    final skipped = <int>[];
    int? findMissingNotSkipped() {
      final shots = _splitShots(w.content);
      for (var i = 0; i < shots.length; i++) {
        if (skipped.contains(i)) continue;
        final block = w.content.substring(shots[i].start, shots[i].end);
        final struct = _shotStructLines(block).trim();
        if (struct.isNotEmpty && block.trim() == struct) return i;
      }
      return null;
    }

    try {
      while (true) {
        if (state.api.isAborted || state.userAborted) {
          _addLog('⏹ 补缺失中止（已补$done镜）');
          break;
        }
        final target = findMissingNotSkipped();
        if (target == null) {
          if (skipped.isEmpty) {
            _addLog('✅ 补缺失全部完成（共补$done镜）');
          } else {
            _addLog('✅ 补缺失结束：成功$done镜，失败${skipped.length}镜（分镜${skipped.map((x) => x + 1).join('/')}——可再点补缺失重试或单镜生成）');
          }
          break;
        }
        final beforeLen = w.content.length;
        setState(() => _shotGenBusy = true); // 单镜finally会清，每镜重置
        await _genSingleShot(state, w, target, skipBusyCheck: true);
        final changed = w.content.length != beforeLen;
        if (changed) {
          done++;
        } else {
          // 无进展=该镜失败（API错误/定位失败）——跳过补后面的，不再卡死
          skipped.add(target);
          _addLog('⚠️ 分镜${target + 1}补生成失败，跳过（已补$done镜，剩余继续）');
        }
      }
    } finally {
      if (mounted) setState(() => _shotGenBusy = false);
    }
  }

  Future<void> _genSingleShot(
    AppState state,
    WritingItem w,
    int shotIdx, {
    bool skipBusyCheck = false,
  }) async {
    if (!skipBusyCheck && (_shotGenBusy || _isGenerating)) return;
    final shots = _splitShots(w.content);
    if (shotIdx >= shots.length) {
      _addLog('⚠️ 分镜${shotIdx + 1}定位不到（正文切出${shots.length}镜）——跳过');
      return;
    }
    final sh = shots[shotIdx];
    final block = w.content.substring(sh.start, sh.end);
    // v592：精简分镜——单镜生成同样剥离易搬运维度
    final structText =
        state.writingLeanShots
            ? TextCleaner.stripShotDims(_shotStructLines(block))
            : _shotStructLines(block);
    // 前文衔接：本镜之前的场景内已生成正文全量注入（v375用户裁决：
    // 连戏完整优于token节省；v376撤4000上限）
    final prevTail = w.content.substring(0, sh.start);
    // v369：前置分镜概要——本镜之前各镜的focus+镜头类型（结构连戏），
    // 开头不够数有多少列多少
    final prevShots = <String>[];
    for (var pi = 0; pi < shotIdx; pi++) {
      final pBlock = w.content.substring(shots[pi].start, shots[pi].end);
      final pFocus = _dimValue(pBlock, ['焦点', 'Focus']);
      final pShot = _dimValue(pBlock, ['镜头类型', 'Shot Type']);
      if (pFocus.isNotEmpty || pShot.isNotEmpty) {
        prevShots.add('分镜${pi + 1}：${pFocus.isNotEmpty ? pFocus : '（无focus）'}｜$pShot');
      }
    }
    // 场景头（条目里的场景框架做背景）
    String sceneHeader = '弧线${w.arcKey} 场景${w.sceneIdx + 1} ${w.sceneName}';
    final wbEntry = state.worldBook?.entries.values
        .where(
          (e) =>
              e.arcKey == w.arcKey &&
              (e.sceneTag == null || e.sceneTag!.isEmpty),
        )
        .toList();
    if (wbEntry != null && wbEntry.isNotEmpty) {
      final m = RegExp('场景\\s*${w.sceneIdx + 1}\\s*[：:].*')
          .firstMatch(wbEntry.first.content);
      if (m != null) sceneHeader = m.group(0)!;
    }
    setState(() => _shotGenBusy = true);
    state.api.clearAbort(); state.userAborted = false; // 清除上次abort残留（v187：终止残留会让callApi秒回"用户中断"）
    _addLog('━━ 单独生成分镜${shotIdx + 1}正文（${w.sceneName}）');
    try {
      // v362：单镜也注入范文（此前遗漏——逐镜有单镜没有）。
      // 镜级均分已否决（无镜级锚点，均分错位不如全场景）——统一用场景切片前1000字
      final styleSample = state.writingImitateAuthor
          ? _buildShotLevelSample(state, w.arcKey, w.sceneIdx, shotIdx)
          : '';
      if (styleSample.isNotEmpty) {
        _addLog('✓ 注入范文${styleSample.length}字（镜级切片）');
      }
      final sys = PromptBuilder.buildSingleShotWriteSystemPrompt();
      final user = PromptBuilder.buildSingleShotWriteUserPrompt(
        sceneHeader: sceneHeader,
        shotInfo: structText,
        prevTail: TextCleaner.stripShotHeaders(prevTail),
        extraPrompt: state.writingPrompt,
        arcSummary: _arcSummaryForShot(state, w.arcKey),
        inkHabit: _inkHabitForShot(state, w.arcKey),
        styleDna: _styleDnaForShot(state, w.arcKey), // v640
        styleSample: styleSample,
        prevShots: prevShots,
        arcDeclaration: _arcDeclForWriting(state, w.arcKey),
      );
      if (state.writingPromptPreview && mounted) {
        final ok = await PromptPreview.maybePreview(
          context,
          sysPrompt: sys,
          userPrompt: user,
          title: '单分镜正文生成词链预览 — 分镜${shotIdx + 1}',
          enabled: true,
        );
        if (!ok) {
          _addLog('已取消发送');
          return;
        }
      }
      final config = state.getApiConfig('writing');
      var result = await state.api.callApi(
        systemPrompt: sys,
        userPrompt: user,
        apiConfig: config,
      );
      var retry = 0;
      while (result.statusCode == 503 && retry < 3 && !state.api.isAborted || state.userAborted) {
        retry++;
        _addLog('503模型过载，${20 * retry}s后自动重试（第$retry/3次）...');
        await Future.delayed(Duration(seconds: 20 * retry));
        if (state.api.isAborted) break;
        result = await state.api.callApi(
          systemPrompt: sys,
          userPrompt: user,
          apiConfig: config,
        );
      }
      if (!result.isSuccess) {
        _addLog('❌ 分镜${shotIdx + 1}生成失败：${result.error}');
        return;
      }
      // v259：json模式格式坏重试+剥壳抢救（同批量创作链路——上层判定接线）
      var fmtRetry = 0;
      while (config.formatMode == 'json' &&
          TextCleaner.jsonFormatBad(result.content) &&
          fmtRetry < 2 &&
          !state.api.isAborted) {
        fmtRetry++;
        _addLog('⚠️ 分镜${shotIdx + 1}输出伪JSON格式坏，10s后重试（第$fmtRetry/2次）...');
        await Future.delayed(const Duration(seconds: 10));
        if (state.api.isAborted) break;
        result = await state.api.callApi(
          systemPrompt: sys,
          userPrompt: user,
          apiConfig: config,
        );
        if (!result.isSuccess) {
          _addLog('❌ 分镜${shotIdx + 1}重试失败：${result.error}');
          return;
        }
      }
      // v539：篇幅硬约束——超原文目标20%自动返工一次（啰嗦治理机制层兜底）
      final lenTarget = PromptBuilder.shotLengthTarget(structText);
      if (lenTarget != null &&
          lenTarget > 0 &&
          result.content.length > (lenTarget * 1.2).round() &&
          !state.api.isAborted) {
        _addLog('📏 分镜${shotIdx + 1}输出${result.content.length}字符，超原文约$lenTarget的20%——返工压缩一次');
        final user2 = PromptBuilder.buildSingleShotWriteUserPrompt(
          sceneHeader: sceneHeader,
          shotInfo: structText,
          prevTail: TextCleaner.stripShotHeaders(prevTail),
          extraPrompt:
              '${state.writingPrompt}\n\n${PromptBuilder.lengthRetakeExtra(lenTarget, result.content.length)}',
          styleSample: styleSample,
          prevShots: prevShots,
          arcDeclaration: _arcDeclForWriting(state, w.arcKey),
        );
        final r2 = await state.api.callApi(
          systemPrompt: sys,
          userPrompt: user2,
          apiConfig: config,
        );
        if (r2.isSuccess &&
            r2.content.trim().isNotEmpty &&
            r2.content.length < result.content.length) {
          result = r2;
          _addLog('✓ 返工后${r2.content.length}字符');
        } else {
          _addLog('返工未改善，保留原稿');
        }
      }
      var normalizedShot = TextCleaner.normalizeAiOutput(
        result.content,
        jsonMode: config.formatMode == 'json',
      );
      if (config.formatMode == 'json' &&
          TextCleaner.jsonFormatBad(result.content)) {
        normalizedShot = TextCleaner.salvagePseudoJson(result.content);
        _addLog('⚠️ 分镜${shotIdx + 1}格式仍坏，已剥壳抢救（内容建议抽查）');
      }
      // 替换块：header+维度行保留，正文部分换新生成（v254归一化+emoji清洗）
      // v256：①AI无视"只输出正文"时自带结构（分镜N：/维度行/括号头）——
      // 用stripShotHeaders剥干净只留纯正文（此前结构行混进body=内容膨胀
      // 重复+括号残留）②structEnd维度正则补语感/笔墨/语感锚/笔墨配额
      ///（此前缺这4项→语感笔墨行被判成正文边界→原结构行从keptStruct
      /// 截断丢失=分镜内容消失的根因）
      var body = TextCleaner.stripWrapQuotes(
        TextCleaner.decodeLiteralNewlines(
          TextCleaner.stripShotHeaders(
            TextCleaner.stripDecorativeEmoji(normalizedShot),
          ),
        ),
      );
      body = body.trim();
      final nl = block.indexOf('\n');
      // 找结构行结束位置
      var structEnd = 0;
      final lines = block.split('\n');
      // v265：前导空行跳过（结构行判定从首个非空行起——空行计入
      // structEnd保留位置，防御块头带空行的边缘形态）
      var firstContent = 0;
      while (firstContent < lines.length && lines[firstContent].trim().isEmpty) {
        firstContent++;
      }
      for (var i = 0; i < lines.length; i++) {
        final t = lines[i].trim();
        if (i < firstContent) {
          structEnd += lines[i].length + 1; // 前导空行保留
          continue;
        }
        // v259/v262：维度行isStruct加污染守卫（共享判定）——污染行
        // （正文藏身）不算结构边界，让正文保留在body里
        final dimM = RegExp(
          r'^[^\u4e00-\u9fa5\n]*(投放信息|投放|作者意图|意图|转场手法|转场|篇幅|文笔节奏|功能抽象|焦点|镜头类型|视角|镜头子类型|叙述|语感|笔墨|语感锚|笔墨配额|叙事功能)(\s*[(（][A-Za-z /]+[)）])?\s*(/\s*[A-Za-z /]+)?\s*[：:]\s*(.*)$',
        ).firstMatch(t);
        final dimValOk = dimM != null &&
            !TextCleaner.dimValuePolluted(dimM.group(4) ?? '');
        final isStruct = i == 0 || dimValOk;
        if (isStruct) {
          structEnd += lines[i].length + 1;
        } else {
          break;
        }
      }
      final keptStruct = structEnd > 0
          ? block.substring(0, structEnd).trimRight()
          : '';
      final newBlock = '$keptStruct\n\n$body\n\n';
      w.content =
          w.content.substring(0, sh.start) +
          newBlock +
          w.content.substring(sh.end);
      state.saveWritings();
      var txt = TextCleaner.stripShotHeaders(w.content);
      final note = _txtNote(state, model: w.model, temp: w.temperature);
      if (note != null) txt = '$note\n\n$txt';
      final path = state.storage.getWritingPath(
        w.arcKey,
        w.sceneIdx,
        w.sceneName,
        w.chapterRange,
        w.version,
      );
      state.storage.writeFile(path, txt);
      _addLog('✓ 分镜${shotIdx + 1}正文已生成（${body.length}字）');
      if (mounted) setState(() {});
    } catch (e) {
      _addLog('分镜${shotIdx + 1}生成异常：$e');
    } finally {
      setState(() => _shotGenBusy = false);
    }
  }

  /// 单分镜块就地保存（✎编辑💾）：结构行写回世界书+正文更新写作txt
  /// 定位：编辑框首行的分镜编号优先（数据块数与渲染序错位时兜底），fallback位置索引
  void _saveShotEdit(AppState state, WritingItem w, int shotIdx) {
    final shots = _splitShots(w.content);
    if (shots.isEmpty) {
      _addLog('⚠️ 保存失败：正文里定位不到分镜块');
      setState(() => _shotEditKey = null);
      return;
    }
    // 编辑框首行分镜编号提取（"分镜N："或"【分镜N】"）
    final headNum = RegExp(r'分[镜景](头)?\s*(\d+)')
        .firstMatch(_shotEditCtrl.text.trim())
        ?.group(2);
    var targetIdx = shotIdx;
    if (headNum != null) {
      final n = int.tryParse(headNum) ?? 0;
      for (var i = 0; i < shots.length; i++) {
        final blk = w.content.substring(shots[i].start, shots[i].end);
        final blkNum = RegExp(r'分[镜景](头)?\s*(\d+)').firstMatch(blk)?.group(2);
        if (blkNum != null && int.tryParse(blkNum) == n) {
          targetIdx = i;
          break;
        }
      }
    }
    if (targetIdx >= shots.length) targetIdx = shots.length - 1;
    final sh = shots[targetIdx];
    final edited = _shotEditCtrl.text.trim();
    if (edited.isNotEmpty) {
      w.content =
          w.content.substring(0, sh.start) +
          edited +
          '\n\n' +
          w.content.substring(sh.end);
      state.saveWritings();
      var txt = TextCleaner.stripShotHeaders(w.content);
      final note3 = _txtNote(state, model: w.model, temp: w.temperature);
      if (note3 != null) txt = '$note3\n\n$txt';
      final path = state.storage.getWritingPath(
        w.arcKey,
        w.sceneIdx,
        w.sceneName,
        w.chapterRange,
        w.version,
      );
      state.storage.writeFile(path, txt);
      // 结构行写回世界书（编辑框首行=分镜头，随后维度行）
      final structText = _shotStructLines(edited);
      final wbOk = structText.trim().isEmpty
          ? false
          : _writeShotBackToWB(state, w, targetIdx, structText);
      _addLog(
        '✓ 分镜${targetIdx + 1}已保存（正文txt${wbOk ? '+结构写回世界书' : '（结构无变化或定位失败）'}）',
      );
      if (mounted) {
        setState(() => _shotSavedFlash = true);
        Future.delayed(const Duration(milliseconds: 1500), () {
          if (mounted) setState(() => _shotSavedFlash = false);
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('分镜${targetIdx + 1}已保存${wbOk ? '（结构已写回世界书）' : ''}'),
            duration: const Duration(milliseconds: 1200),
          ),
        );
      }
    }
    setState(() => _shotEditKey = null);
  }

  @override
  bool get wantKeepAlive => true; // 页面滑出PageView时保持State：生成任务不中断/表单不清空

  bool _isGenerating = false;
  String _statusText = '';
  final List<String> _logs = [];
  int _viewMode = 0; // 0=场景创作 1=草稿（原已创作，v644改名）
  // 正在创作的场景key（arcKey_si），显示行内进度
  final Set<String> _activeKeys = {};
  // 展开的弧线
  final Set<String> _expandedArcs = {};
  // v288：场景创作字号（本页独立；已创作查看器有自己的_viewerFontSize不动）
  double _fontScale = 1.0;

  @override
  void initState() {
    super.initState();
    ContentFont.load('writing_scene').then((v) {
      if (mounted) setState(() => _fontScale = v);
    });
  }

  void _addLog(String msg) {
    setState(() {
      _logs.add(msg);
      if (_logs.length > 100) _logs.removeAt(0);
    });
    AppState.instance.apiLog(msg); // 页面日志同步全局终端（信息出口合一）
  }

  @override
  Widget build(BuildContext context) {
    super.build(context); // AutomaticKeepAlive必须
    final state = context.watch<AppState>();
    final writings = state.writings.values.toList()
      ..sort((a, b) {
        final arcCmp = (int.tryParse(a.arcKey) ?? 0).compareTo(
          int.tryParse(b.arcKey) ?? 0,
        );
        if (arcCmp != 0) return arcCmp;
        return a.sceneIdx.compareTo(b.sceneIdx);
      });
    final arcs = _writingArcs(state);

    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            // v357：顶栏两行——第一行操作键，第二行四个开关（颜色表开关态）
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                  MiniButton(
                    label: '⚡ 批量',
                    primary: true,
                    onTap: _isGenerating || arcs.isEmpty
                        ? null
                        : () => _showBatchDialog(state),
                  ),
                  // v288：场景创作字号（已创作查看器有自己的A-/A+不受影响）
                  ContentFontButtons(
                    pageKey: 'writing_scene',
                    scale: _fontScale,
                    onChanged: (v) {
                      setState(() => _fontScale = v);
                      ContentFont.save('writing_scene', v);
                    },
                  ),
                  const SizedBox(width: 5),
                  SegmentedButton<int>(
                    style: const ButtonStyle(
                      visualDensity: VisualDensity.compact,
                      textStyle: WidgetStatePropertyAll(
                        TextStyle(fontSize: 11),
                      ),
                    ),
                    segments: const [
                      ButtonSegment(value: 0, label: Text('场景')),
                      ButtonSegment(value: 1, label: Text('草稿')),
                    ],
                    selected: {_viewMode},
                    showSelectedIcon: false,
                    onSelectionChanged: (s) => setState(() {
                      _viewMode = s.first;
                      _viewerKey = null; // 切视图收起viewer
                      _viewerEditing = false;
                      _viewerOverride = null;
                    }),
                  ),
                  const SizedBox(width: 5),
                  MiniButton(
                    label: '⚙ API',
                    onTap: () => showV119Sheet(
                      context,
                      title: 'API设置 · 创作',
                      child: ApiConfigPanel(
                        config: state.writingApi,
                        section: 'writing',
                      ),
                    ),
                  ),
                  ],
                ),
                ),
            ),
            // v357：第二行开关——颜色表开关态（亮=开/灰=关），紧凑单行
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 2),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                  MiniButton(
                    label: '逐镜',
                    primary: state.writingShotByShot,
                    onTap: () => state.setWritingShotByShot(
                      !state.writingShotByShot,
                    ),
                  ),
                  const SizedBox(width: 5),
                  // v642：逐镜批量步进（每步N镜一次API）
                  MiniButton(
                    label: '步进${state.writingShotStep}',
                    primary: state.writingShotStep > 1,
                    onTap: () {
                      const steps = [1, 2, 3, 5, 8];
                      final idx = steps.indexOf(state.writingShotStep);
                      state.setWritingShotStep(
                        steps[(idx + 1) % steps.length],
                      );
                    },
                  ),
                  const SizedBox(width: 5),
                  MiniButton(
                    label: '原范文',
                    primary: state.writingImitateAuthor,
                    onTap: () => state.setWritingImitateAuthor(
                      !state.writingImitateAuthor,
                    ),
                  ),
                  const SizedBox(width: 5),
                  MiniButton(
                    label: '自由',
                    primary: state.writingFreeMode,
                    onTap: () => state.setWritingFreeMode(
                      !state.writingFreeMode,
                    ),
                  ),
                  const SizedBox(width: 5),
                  MiniButton(
                    label: '精简',
                    primary: state.writingLeanShots,
                    onTap: () => state.setWritingLeanShots(
                      !state.writingLeanShots,
                    ),
                  ),
                  const SizedBox(width: 5),
                  MiniButton(
                    label: '词链',
                    primary: state.writingPromptPreview,
                    onTap: () => state.setWritingPromptPreview(
                      !state.writingPromptPreview,
                    ),
                  ),
                  const SizedBox(width: 5),
                  MiniButton(
                    label: '备注模型',
                    primary: state.writingModelNote,
                    onTap: () => state.setWritingModelNote(
                      !state.writingModelNote,
                    ),
                  ),
                  const SizedBox(width: 5),
                  // v415：清残渣移到第二行（第一行API键被挤出）
                  MiniButton(
                    label: '🧹 清残渣',
                    onTap: _isGenerating
                        ? null
                        : () => _cleanAllWritings(state),
                  ),

                  ],
                ),
              ),
            ),
            // 进度条（细条，状态文字在终端里）
            if (_isGenerating)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 12, vertical: 2),
                child: LinearProgressIndicator(minHeight: 2),
              ),
            Expanded(
              // v288：只缩放场景创作分支；已创作查看器有自己的字号不动
              child: _viewMode == 0
                  ? ContentFont.area(
                      context,
                      scale: _fontScale,
                      child: _buildSceneList(context, state, arcs, writings),
                    )
                  : writings.isEmpty
                  ? _buildEmpty(context, state)
                  : Builder(
                    // v264：已创作视图滚动定版——与创作页（场景ListView，
                    // 实测可滚）完全同款结构。viewer关=全局面板+文件卡全
                    // 在一个ListView流里整页滚动（v258同款）；viewer开=
                    // 正文独占整个视图区（阅读器式，✕关闭回列表）。不再用
                    // 嵌套滚动窗（v259/v262双窗结构实测滚不动——同页场景
                    // ListView可滚而Column+SingleChildScrollView组合不滚，
                    // 悬疑在手势/父约束，直接换已验证模式最稳）
                    builder: (ctx) {
                      final sel = writings
                          .where(
                            (w) =>
                                '${w.arcKey}_${w.sceneIdx}_${w.version}' ==
                                _viewerKey,
                          )
                          .toList();
                      // v377b：历史版本只读旁路（快照不在writings里）
                      final item = sel.isNotEmpty
                          ? sel.first
                          : (_viewerOverride != null &&
                                    '${_viewerOverride!.arcKey}_${_viewerOverride!.sceneIdx}_${_viewerOverride!.version}' ==
                                        _viewerKey
                                ? _viewerOverride
                                : null);
                      return SelectionArea(
                        child: item != null
                            ? _buildInlineViewer(state, item)
                            // v379：已创作列表独立滚动窗（全局要求固定顶部，
                            // 文件多时列表内部滚，不再整页搅动）
                            : Column(
                                children: [
                                  _buildGlobalReqPanel(state),
                                  Expanded(
                                    child: ListView(
                                      children: [
                                        for (final w in writings)
                                          _buildWritingCard(context, state, w),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                      );
                    },
                  ),
            ),
            // 统一终端（日志+计时+终止）— v468 api-step-log
          ],
        ),
      ),
    );
  }

  /// 全局创作要求面板（ListView头部：展开超高也能滚动，修复页面不能上划）
  /// v414：批量清洗已创作正文——stripJsonShells清嵌入式JSON壳/符号残渣。
  /// 内存+磁盘+历史版本同步（磁盘按getWritingPath重写当前版本）
  Future<void> _cleanAllWritings(AppState state) async {
    var changed = 0;
    final keys = state.writings.keys.toList();
    for (final k in keys) {
      final w = state.writings[k]!;
      var cleaned = TextCleaner.stripJsonShells(w.content);
      // v609：分镜顺序修复——首个分镜块前的孤立正文段挪回块后（先正文后分镜的存量自愈）
      final ordered = TextCleaner.fixShotBodyOrder(cleaned);
      if (ordered != cleaned) {
        changed++;
        cleaned = ordered;
        _addLog('🔧 ${w.sceneName}: 分镜1前孤立正文已挪回分镜块后');
      }
      if (cleaned != w.content) {
        changed++;
        w.content = cleaned;
      }
      // 磁盘txt无条件按纯正文管线重写（存量坏txt自愈：维度行/JSON壳全剥）
      // v608：重写时补回备注行——此前无条件纯正文重写=备注消失的真凶
      var fixedTxt = TextCleaner.stripShotHeaders(cleaned);
      final note4 = _txtNote(state, model: w.model, temp: w.temperature);
      if (note4 != null) fixedTxt = '$note4\n\n$fixedTxt';
      state.storage.writeFile(
        state.storage.getWritingPath(
          w.arcKey,
          w.sceneIdx,
          w.sceneName,
          w.chapterRange,
          w.version,
        ),
        fixedTxt,
      );
      for (final v in w.versions) {
        final cv = TextCleaner.stripJsonShells(v.content);
        if (cv != v.content) {
          v.content = cv;
          state.storage.writeFile(
            state.storage.getWritingPath(
              v.arcKey,
              v.sceneIdx,
              v.sceneName,
              v.chapterRange,
              v.version,
            ),
            TextCleaner.stripShotHeaders(cv),
          );
        }
      }
    }
    if (changed > 0) {
      state.saveWritings();
      state.refresh();
    }
    _addLog('✓ 清残渣完成：$changed/${keys.length} 篇有残留已清理');
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('✓ 已清理$changed篇（共${keys.length}篇）')),
      );
    }
  }

  Widget _buildGlobalReqPanel(AppState state) {
    // v379：不再折叠——ReqField（改编页同款紧凑输入框）+素材按钮平铺
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: ReqField(
            controller: TextEditingController(text: state.writingPrompt)
              ..selection = TextSelection.collapsed(
                offset: state.writingPrompt.length,
              ),
            labelText: '全局创作要求（可选，对所有场景生效；留空AI自由创作）',
            hintText: '如：以第一人称视角改写\n文风偏向热血爽文\n每个场景不少于2000字',
            fontSize: 13,
            onChanged: (v) => state.setWritingPrompt(v),
          ),
        ),
        // v469对齐：文风素材+内容素材（文风学笔触不抄内容/内容素材自然融入正文）
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: Row(
            children: [
              OutlinedButton.icon(
                onPressed: () => _pickAttachment('style'),
                icon: const Icon(Icons.brush, size: 14),
                label: const Text('添加文风素材', style: TextStyle(fontSize: 12)),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  minimumSize: const Size(0, 30),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
            ],
          ),
        ),
        // 素材列表（类型徽章+文件名+字数+删除，限高滚动v469对齐）
        if (state.writingAttachments.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 170),
              child: SingleChildScrollView(
                child: Column(
                  children: [
                    for (
                      var ai = 0;
                      ai < state.writingAttachments.length;
                      ai++
                    )
                      _buildAttachmentRow(state, ai),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }

  /// 场景创作列表：每弧线折叠 → 场景行（状态+per-scene要求+创作按钮）
  /// 选择素材文件（v469对齐：文风学笔触/内容素材融入正文，读取后入库全局使用）
  Future<void> _pickAttachment(String type, {String? wkey}) async {
    final result = await FilePickerService.pickTextFile();
    if (result == null) return;
    try {
      final bytes = await result.readAsBytes();
      final text = EncodingDetector.decode(Uint8List.fromList(bytes));
      if (text.trim().isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(const SnackBar(content: Text('文件内容为空')));
        }
        return;
      }
      final name = result.name;
      // v357：内容素材=per-scene（wkey必传）；文风素材=全局
      if (type != 'style' && wkey != null) {
        context.read<AppState>().addSceneAttachment(wkey, {
          'name': name,
          'content': text,
          'type': type,
        });
      } else {
        context.read<AppState>().addWritingAttachment({
          'name': name,
          'content': text,
          'type': type,
        });
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '已添加${type == 'style' ? '文风' : '内容'}素材：$name（${text.length}字）',
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('读取失败: $e')));
      }
    }
  }

  /// 素材行：类型徽章+文件名+字数+删除（v469 renderWritingAttachments对齐）
  Widget _buildAttachmentRow(AppState state, int index) {
    final att = state.writingAttachments[index];
    final isStyle = att['type'] == 'style';
    final name = att['name']?.toString() ?? '';
    final len = att['content']?.toString().length ?? 0;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: V469Style.surfaceAlt,
          border: Border.all(color: V469Style.border),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
              decoration: BoxDecoration(
                color: isStyle ? V469Style.accentBg : const Color(0xFFF0FDF4),
                borderRadius: BorderRadius.circular(3),
              ),
              child: Text(
                isStyle ? '文风' : '内容',
                style: TextStyle(
                  fontSize: 10,
                  color: isStyle ? V469Style.accent : const Color(0xFF16A34A),
                ),
              ),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                '$name（$len字）',
                style: const TextStyle(fontSize: 11, color: V469Style.textMain),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            GestureDetector(
              onTap: () => state.removeWritingAttachment(index),
              child: const Icon(
                Icons.close,
                size: 14,
                color: V469Style.textMuted,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// v582：创作声明（创作页独立生成，替代改编声明——开关开启才注入，空=未生成）
  String _arcDeclForWriting(AppState state, String arcKey) {
    if (state.worldBook?.creationDeclEnabled[arcKey] ?? true) {
      return state.worldBook?.creationDeclarations[arcKey] ?? '';
    }
    return '';
  }

  /// v582：AI生成本弧线创作声明（依据世界书条目的改编后弧线概述+映射表）
  Future<void> _generateCreationDecl(AppState state, String arcKey) async {
    final entryKey = state.worldBook?.entries.keys
        .where((k) =>
            state.worldBook!.entries[k]!.arcKey == arcKey &&
            (state.worldBook!.entries[k]!.sceneTag == null ||
                state.worldBook!.entries[k]!.sceneTag!.isEmpty))
        .toList();
    String arcContext = '';
    if (entryKey != null && entryKey.isNotEmpty) {
      final content = state.worldBook!.entries[entryKey.first]!.content;
      final m = RegExp('场景\\s*1\\s*[：:]').firstMatch(content);
      arcContext = m == null ? content : content.substring(0, m.start).trim();
    }
    if (arcContext.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('世界书中没有该弧线条目，先去改编页生成')));
      return;
    }
    final config = state.getApiConfig('wb');
    setState(() => _shotGenBusy = true);
    try {
      _addLog('📄 生成分弧线$arcKey创作声明…');
      final result = await state.api.callApi(
        systemPrompt: PromptBuilder.buildCreationDeclSystemPrompt(),
        userPrompt: PromptBuilder.buildCreationDeclUserPrompt(
          arcContext: arcContext,
          mapTable: state.worldBook?.nameMapping.trim() ?? '',
        ),
        apiConfig: config,
      );
      if (!result.isSuccess) {
        _addLog('❌ 创作声明生成失败：${result.error}');
        return;
      }
      final decl = TextCleaner.normalizeAiOutput(
        result.content,
        jsonMode: config.formatMode == 'json',
      ).trim();
      if (decl.isEmpty) {
        _addLog('⚠️ 创作声明的生成结果为空');
        return;
      }
      state.worldBook!.creationDeclarations[arcKey] = decl;
      state.worldBook!.creationDeclEnabled[arcKey] = true;
      state.saveWorldBook();
      _addLog('✓ 弧线$arcKey创作声明已生成（${decl.length}字）');
      if (mounted) setState(() {});
    } finally {
      if (mounted) setState(() => _shotGenBusy = false);
    }
  }

  /// 创作弧线列表（四级数据源，v469 getWBAllArcs对齐+世界书兜底）：
  /// ①arcScan中有拆解的弧线 ②arcAnalyses直接 ③世界书条目arcKey集合
  /// ——删章节/重扫清掉扫描数据后，只要世界书还在就能继续创作
  List<dynamic> _writingArcs(AppState state) {
    // v404：世界书空=列表空（创作的依据是世界书——世界书清空后①②级fallback
    // 还在显示旧扫描列表，造成"还能创作"假象，点进去worldBookEntries为空）
    if (state.worldBook == null || state.worldBook!.entries.isEmpty) {
      return [];
    }
    final result = <dynamic>[];
    final seen = <String>{};
    // ① 扫描弧线+有拆解（Primary，v469同款）
    for (final a in state.completedArcs) {
      final k = a.number.toString();
      if (state.arcAnalyses.containsKey(k)) {
        result.add(a);
        seen.add(k);
      }
    }
    // ② arcAnalyses直接（扫描数据被清但拆解还在）
    if (result.isEmpty && state.arcAnalyses.isNotEmpty) {
      final keys = state.arcAnalyses.keys.toList()
        ..sort(
          (a, b) => (int.tryParse(a) ?? 0).compareTo(int.tryParse(b) ?? 0),
        );
      for (final k in keys) {
        if (seen.contains(k)) continue;
        result.add(_PseudoArc(int.tryParse(k) ?? 0, '弧线$k', ''));
        seen.add(k);
      }
    }
    // ③ 世界书条目arcKey集合（最终兜底：有世界书就能列）
    if (result.isEmpty &&
        state.worldBook != null &&
        state.worldBook!.entries.isNotEmpty) {
      final keys = <String>{};
      for (final e in state.worldBook!.entries.values) {
        final ak = (e.arcKey ?? '').trim();
        if (ak.isNotEmpty) keys.add(ak);
      }
      final sorted = keys.toList()
        ..sort(
          (a, b) => (int.tryParse(a) ?? 0).compareTo(int.tryParse(b) ?? 0),
        );
      for (final k in sorted) {
        result.add(_PseudoArc(int.tryParse(k) ?? 0, '弧线$k', ''));
        seen.add(k);
      }
    }
    return result;
  }

  /// 场景列表（世界书解析优先，v469 useAdapted）：
  /// 从该弧线全部世界书条目content解析改编后场景名+章节范围，fallback到arcScenes
  List<(String, String)> _writingScenes(AppState state, String arcKey) {
    // ① 世界书条目content解析（改编后场景）
    if (state.worldBook != null) {
      final buf = StringBuffer();
      for (final e in state.worldBook!.entries.values) {
        if ((e.arcKey ?? '').trim() == arcKey) buf.writeln(e.content);
      }
      final adapted = PromptBuilder.parseScenesFromWBContent(buf.toString());
      if (adapted.isNotEmpty) return adapted;
    }
    // ② 场景划分数据（未改编或解析失败）
    final scenes = state.arcScenes[arcKey] ?? [];
    return scenes.map((s) => (s.name, s.chapterRange)).toList();
  }

  Widget _buildSceneList(
    BuildContext context,
    AppState state,
    dynamic arcs,
    List<WritingItem> writings,
  ) {
    if (arcs.isEmpty) {
      return Center(
        child: Text(
          '请先完成弧线扫描并在改编页生成世界书',
          style: TextStyle(color: Colors.grey[600]),
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 8),
      itemCount: arcs.length + 1,
      itemBuilder: (ctx, i) {
        if (i == 0) return _buildGlobalReqPanel(state);
        i -= 1;
        final arc = arcs[i];
        final arcKey = arc.number.toString();
        // 场景列表：世界书解析优先（改编后场景名），fallback场景划分（v469 useAdapted）
        final scenes = _writingScenes(state, arcKey);
        final createdCount = scenes
            .asMap()
            .entries
            .where((en) => state.writings.containsKey('${arcKey}_${en.key}'))
            .length;
        final expanded = _expandedArcs.contains(arcKey);
        return Column(
          children: [
            ListTile(
              dense: true,
              contentPadding: const EdgeInsets.symmetric(horizontal: 12),
              leading: const Icon(
                Icons.book,
                size: 18,
                color: Color(0xFF3B82F6),
              ),
              title: Text(
                '弧线${arc.number} ${arc.title}',
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                '$createdCount/${scenes.length}已创作',
                style: const TextStyle(fontSize: 11, color: Colors.grey),
              ),
              trailing: Icon(expanded ? Icons.expand_less : Icons.expand_more),
              onTap: () => setState(() {
                expanded
                    ? _expandedArcs.remove(arcKey)
                    : _expandedArcs.add(arcKey);
              }),
            ),
            if (expanded) ...[
              _buildArcDeclSection(state, arcKey),
              for (var si = 0; si < scenes.length; si++)
                _buildSceneRow(state, arcKey, si, scenes[si]),
            ],
            const Divider(height: 1),
          ],
        );
      },
    );
  }

  /// v313：模仿原文作者——弧线物化正文按场景序号确定性取样
  /// 写场景n(si=n-1)时从弧线原文第1+(n-1)*1000字处截1000字；越界取尾部1000字。
  /// 优先读arcScan全量弧线（含未闭合），fallback completedArcs
  String _buildStyleSample(AppState state, String arcKey, int si) {
    // v353：范文=本场景锚定切片前1000字（与创作内容同段同源）。
    // ①si*1000旧公式是弧线正文顺序排布时代的产物，对独立切片会跳过前段/取到末尾
    // ②弧线正文兜底移除（用户裁决）——无切片=旧数据，提示重新划分而非瞎取
    final scenes = state.arcScenes[arcKey] ?? const [];
    if (si < scenes.length && scenes[si].text.isNotEmpty) {
      final st = scenes[si].text;
      final end = 1000 > st.length ? st.length : 1000;
      return st.substring(0, end);
    }
    // v502：老路径无切片→fallback全局场景流（v500架构的物化切片按sceneFrom-1+si定位）
    final slice = _sceneSlice(state, arcKey, si);
    if (slice.isNotEmpty) {
      final end = 1000 > slice.length ? slice.length : 1000;
      return slice.substring(0, end);
    }
    return '';
  }

  /// v502：场景原文切片——优先arcScenes（划分物化），fallback全局场景流
  /// （弧线sceneFrom为1-based全局场景序号，si为弧线内0-based序号）
  String _sceneSlice(AppState state, String arcKey, int si) {
    final scenes = state.arcScenes[arcKey] ?? const [];
    if (si < scenes.length && scenes[si].text.isNotEmpty) {
      return scenes[si].text;
    }
    final arcs = state.completedArcs;
    for (final a in arcs) {
      if (a.number.toString() == arcKey && a.sceneFrom >= 0) {
        final gi = a.sceneFrom - 1 + si;
        if (gi >= 0 && gi < state.globalScenes.length) {
          return state.globalScenes[gi].text;
        }
        break;
      }
    }
    return '';
  }

  /// v363：镜级范文——优先本镜锚定切片（拆解物化的shot.text），
  /// 旧数据无镜级锚点→回退场景切片前1000字（与v353行为一致）
  /// v642：步进分块范文——本步N镜的原文切片按序组装（文风连续参考）
  String _buildChunkSample(
    AppState state,
    String arcKey,
    int si,
    int cStart,
    int cEnd,
  ) {
    final scenes = state.arcScenes[arcKey] ?? const [];
    final parts = <String>[];
    if (si < scenes.length) {
      for (var j = cStart; j < cEnd; j++) {
        if (j < scenes[si].shots.length &&
            scenes[si].shots[j].text.isNotEmpty) {
          parts.add(scenes[si].shots[j].text);
        }
      }
    }
    if (parts.isNotEmpty) return parts.join('\n');
    // v650：镜级切片缺失——回退场景切片并说明原因（用户实测"范文不是按
    // 分镜切片组装"就是静默走了这里：该场景未拆分镜/扫描数据未加载）
    _addLog('ℹ️ 镜级切片缺失（场景${si + 1}未拆分镜或扫描数据未加载）——范文回退场景切片');
    return _buildStyleSample(state, arcKey, si);
  }

  String _buildShotLevelSample(AppState state, String arcKey, int si, int shotIdx) {
    final scenes = state.arcScenes[arcKey] ?? const [];
    if (si < scenes.length &&
        shotIdx < scenes[si].shots.length &&
        scenes[si].shots[shotIdx].text.isNotEmpty) {
      return scenes[si].shots[shotIdx].text;
    }
    return _buildStyleSample(state, arcKey, si);
  }

  /// v363：分镜切片预览——优先镜级切片（shot.text），无锚点回退场景切片
  void _previewShotSlice(
    BuildContext context,
    AppState state,
    String arcKey,
    int si,
    int shotIdx,
  ) {
    final scenes = state.arcScenes[arcKey] ?? const [];
    final hasShot = si < scenes.length &&
        shotIdx < scenes[si].shots.length &&
        scenes[si].shots[shotIdx].text.isNotEmpty;
    if (hasShot) {
      showSliceViewerSheet(
        context,
        title: '分镜${shotIdx + 1} 切片（镜级锚定）— 弧线$arcKey 场景${si + 1}',
        text: scenes[si].shots[shotIdx].text,
      );
      return;
    }
    // v505b：回退用完整场景切片（v503c的_sceneSlice含全局场景流fallback）——
    // 旧回退_buildStyleSample只取前1000字=内容"不对"的主因
    final sceneSample = _sceneSlice(state, arcKey, si);
    if (sceneSample.isEmpty) {
      // v541：失效可见化——切片数据被级联清空/场景未划分时按钮不再"没反应"
      AppState.instance.apiLog('分镜${shotIdx + 1}无切片（arcScenes与全局场景流均无）——请重新划分场景');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('分镜${shotIdx + 1}无切片数据——场景划分已被清空或未划分，请到场景页重新划分并重生成弧线')),
      );
      return;
    }
    showSliceViewerSheet(
      context,
      title: '分镜${shotIdx + 1}（无镜级锚点，回退场景切片${sceneSample.length}字）— 弧线$arcKey 场景${si + 1}',
      text: sceneSample,
    );
  }

  /// v363：范文预览对话框（场景行"范文"按键）
  void _previewStyleSample(
    BuildContext context,
    AppState state,
    String arcKey,
    int si,
  ) {
    final sample = _buildStyleSample(state, arcKey, si);
    if (sample.isEmpty) {
      // v541：失效可见化（同切片按钮）
      AppState.instance.apiLog('场景${si + 1}无切片（arcScenes与全局场景流均无）——范文不可预览');
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('无范文切片——场景划分已被清空或未划分，请到场景页重新划分')),
      );
      return;
    }
    // v502：预览显示完整场景切片（含全局场景流fallback），注入AI仍取前1000字
    final fullSlice = _sceneSlice(state, arcKey, si);
    final preview = fullSlice.isNotEmpty ? fullSlice : sample;
    // v352：统一切片查看底板（全宽+A-/A+字号记忆）
    showSliceViewerSheet(
      context,
      title: fullSlice.isNotEmpty
          ? '场景${si + 1} 文风范文（场景切片全文${preview.length}字）'
          : '场景${si + 1} 文风范文（场景切片前${sample.length}字）',
      text: preview,
      emptyHint: '（范文为空）',
    );
  }

  /// v548：生成时间显示（本地时区=北京时间，yyyy-MM-dd HH:mm）
  String _fmtDateTime(DateTime t) {
    String p(int n) => n.toString().padLeft(2, '0');
    return '${t.year}-${p(t.month)}-${p(t.day)} ${p(t.hour)}:${p(t.minute)}';
  }

  /// 单场景行（v468：场景名+✓+章节范围+本场景要求+创作按钮）
  /// scene兼容三种：Scene对象/(String name, String range)元组/Map
  /// v410：弧线改编声明区（样式对齐改编页：开关+就地编辑+自动保存）
  Widget _buildArcDeclSection(AppState state, String arcKey) {
    final decl = state.worldBook?.creationDeclarations[arcKey] ?? '';
    return ExpansionTile(
      dense: true,
      tilePadding: const EdgeInsets.symmetric(horizontal: 8),
      title: Row(
        children: [
          if (decl.isNotEmpty) ...[
            SizedBox(
              width: 22,
              height: 22,
              child: Checkbox(
                value: state.worldBook?.creationDeclEnabled[arcKey] ?? true,
                onChanged: (v) {
                  setState(() =>
                      state.worldBook?.creationDeclEnabled[arcKey] = v ?? true);
                  state.saveWorldBook();
                },
              ),
            ),
            const SizedBox(width: 4),
          ],
          Expanded(
            child: Text(
              decl.isEmpty
                  ? '📝 创作声明（未生成——创作方向指导，替代改编声明）'
                  : '📝 创作声明（${decl.length}字·${state.worldBook?.creationDeclEnabled[arcKey] ?? true ? "创作正文时注入" : "已停用不注入"}）',
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
                color: decl.isEmpty ? Colors.grey : const Color(0xFF92400E),
              ),
            ),
          ),
          TextButton(
            onPressed: _shotGenBusy
                ? null
                : () => _generateCreationDecl(state, arcKey),
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              minimumSize: const Size(0, 30),
              textStyle:
                  const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
            ),
            child: Text(decl.isEmpty ? '生成' : '重新生成'),
          ),
          if (decl.isNotEmpty)
            TextButton(
              onPressed: () {
                state.worldBook?.creationDeclarations.remove(arcKey);
                state.saveWorldBook();
                setState(() {});
                _addLog('已删除弧线$arcKey创作声明');
              },
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                minimumSize: const Size(0, 30),
                textStyle: const TextStyle(fontSize: 11),
              ),
              child: const Text('删除',
                  style: TextStyle(color: Colors.red)),
            ),
        ],
      ),
      children: [
        if (decl.isEmpty)
          const Padding(
            padding: EdgeInsets.fromLTRB(8, 0, 8, 8),
            child: Text('点"生成"由AI依据本弧线世界书条目生成创作方向声明（冲突形式/禁止项/人物行为），创作正文时注入',
                style: TextStyle(fontSize: 10.5, color: Colors.grey)),
          )
        else
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
            child: _AutoExpandField(
              controller: TextEditingController(text: decl)
                ..selection = TextSelection.collapsed(offset: decl.length),
              style: const TextStyle(fontSize: 12, height: 1.5),
              contentPadding: const EdgeInsets.all(8),
              onChanged: (v) =>
                  state.worldBook?.creationDeclarations[arcKey] = v,
            ),
          ),
      ],
    );
  }

  Widget _buildSceneRow(AppState state, String arcKey, int si, dynamic scene) {
    final wkey = '${arcKey}_$si';
    final existing = state.writings[wkey];
    final hasCreated = existing != null;
    final isActive = _activeKeys.contains(wkey);
    final scenePrompt = state.writingScenePrompts[wkey] ?? '';
    var sceneName = '';
    var chapterRange = '';
    if (scene is (String, String)) {
      sceneName = scene.$1;
      chapterRange = scene.$2;
    } else if (scene is Map) {
      sceneName = scene['name']?.toString() ?? '';
      chapterRange = scene['chapterRange']?.toString() ?? '';
    }
    // v545：场景概述（拆解场景摘要——展示+注入双用途的数据源）
    var sceneSummary = '';
    final arcAnalysis = state.arcAnalyses[arcKey.toString()];
    if (arcAnalysis != null && si < arcAnalysis.scenes.length) {
      sceneSummary = arcAnalysis.scenes[si].summary;
    }

    return Container(
      margin: const EdgeInsets.fromLTRB(12, 4, 12, 4),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        // v469对齐：已创作=complete绿左边条，未创作=incomplete红左边条
        color: V469Style.surface,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: V469Style.border),
      ),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(6),
          border: Border(
            left: BorderSide(
              color: hasCreated ? V469Style.complete : V469Style.incomplete,
              width: 3,
            ),
          ),
        ),
        padding: const EdgeInsets.only(left: 5),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
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
                    '场景${si + 1}',
                    style: const TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                    ),
                  ),
                ),
                const SizedBox(width: 7),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        sceneName,
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: V469Style.textMain,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      // v545：场景概述（两行折叠，与创作注入同源）
                      if (sceneSummary.trim().isNotEmpty)
                        Text(
                          sceneSummary.trim(),
                          style: const TextStyle(
                            fontSize: 10,
                            color: V469Style.textMuted,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                    ],
                  ),
                ),
                if (hasCreated)
                  V469Style.badge(
                    '✅ 已创作',
                    V469Style.complete,
                    V469Style.completeBg,
                  )
                else
                  V469Style.badge(
                    '未创作',
                    V469Style.textMuted,
                    V469Style.surfaceAlt,
                  ),
                const SizedBox(width: 4),
                Text(
                  chapterRange,
                  style: const TextStyle(
                    fontSize: 10,
                    color: V469Style.textMuted,
                  ),
                ),
              ],
            ),
            // per-scene创作要求（与全局综合生效）
            _AutoExpandField(
              controller: TextEditingController(text: scenePrompt)
                ..selection = TextSelection.collapsed(
                  offset: scenePrompt.length,
                ),
              style: const TextStyle(fontSize: 11),
              hintText: '本场景创作要求（与全局综合生效）...',
              hintStyle: const TextStyle(fontSize: 10),
              borderSide: const BorderSide(width: 0.5),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 6,
                vertical: 6,
              ),
              onChanged: (v) => state.setScenePrompt(wkey, v),
            ),
            // v357：内容素材移到场景行（per-scene，仅本场景创作注入）
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  InkWell(
                    onTap: () => _pickAttachment('content', wkey: wkey),
                    borderRadius: BorderRadius.circular(4),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        border: Border.all(color: V469Style.border),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.menu_book, size: 12, color: V469Style.textMuted),
                          const SizedBox(width: 3),
                          Text(
                            '内容素材${(state.sceneAttachments[wkey] ?? []).isNotEmpty ? "(${(state.sceneAttachments[wkey] ?? []).length})" : ""}',
                            style: const TextStyle(
                              fontSize: 10,
                              color: V469Style.textSec,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  for (
                    var mi = 0;
                    mi < (state.sceneAttachments[wkey] ?? []).length;
                    mi++
                  )
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              '· ${(state.sceneAttachments[wkey] ?? [])[mi]['name']}（${((state.sceneAttachments[wkey] ?? [])[mi]['content'] ?? '').toString().length}字）',
                              style: const TextStyle(
                                fontSize: 10,
                                color: V469Style.textMuted,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          GestureDetector(
                            onTap: () =>
                                state.removeSceneAttachment(wkey, mi),
                            child: const Icon(
                              Icons.close,
                              size: 12,
                              color: V469Style.textMuted,
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 4),
            SizedBox(
              width: double.infinity,
              height: 30,
              child: hasCreated
                  ? Row(
                      children: [
                        // v352：已创作后保留范文按键（创作一次就消失=没法对照原文）
                        Expanded(
                          child: OutlinedButton(
                            style: OutlinedButton.styleFrom(
                              padding: EdgeInsets.zero,
                              textStyle: const TextStyle(fontSize: 11),
                            ),
                            onPressed: () => _previewStyleSample(
                              context,
                              state,
                              arcKey,
                              si,
                            ),
                            child: Text(
                              state.writingImitateAuthor ? '范文' : '范文(未开)',
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: OutlinedButton(
                            style: OutlinedButton.styleFrom(
                              padding: EdgeInsets.zero,
                              textStyle: const TextStyle(fontSize: 11),
                            ),
                            onPressed: _isGenerating
                                ? null
                                : () => _viewWriting(context, existing),
                            child: Text('查看${existing.content.length}字'),
                          ),
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: FilledButton.tonal(
                            style: FilledButton.styleFrom(
                              padding: EdgeInsets.zero,
                              textStyle: const TextStyle(fontSize: 11),
                            ),
                            onPressed: _isGenerating
                                ? null
                                : () => _createSceneWriting(state, arcKey, si),
                            child: Text('重新创作(v${existing.version})'),
                          ),
                        ),
                      ],
                    )
                  : Row(
                      children: [
                        Expanded(
                          child: FilledButton.icon(
                            style: FilledButton.styleFrom(
                              padding: EdgeInsets.zero,
                              textStyle: const TextStyle(fontSize: 11),
                            ),
                            icon: isActive
                                ? const SizedBox(
                                    width: 12,
                                    height: 12,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Icon(Icons.edit, size: 14),
                            label: Text(isActive ? '创作中...' : '创作正文'),
                            onPressed: _isGenerating
                                ? null
                                : () => _createSceneWriting(state, arcKey, si),
                          ),
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: OutlinedButton(
                            style: OutlinedButton.styleFrom(
                              padding: EdgeInsets.zero,
                              textStyle: const TextStyle(fontSize: 11),
                            ),
                            onPressed: () => _previewStyleSample(
                              context,
                              state,
                              arcKey,
                              si,
                            ),
                            child: Text(
                              state.writingImitateAuthor ? '范文' : '范文(未开)',
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmpty(BuildContext context, AppState state) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.edit_note, size: 64, color: Colors.grey[400]),
          const SizedBox(height: 16),
          Text('暂无创作内容', style: TextStyle(color: Colors.grey[600])),
          const SizedBox(height: 8),
          Text(
            '在"场景创作"视图点击创作按钮',
            style: TextStyle(color: Colors.grey[500], fontSize: 13),
          ),
        ],
      ),
    );
  }

  Widget _buildWritingCard(
    BuildContext context,
    AppState state,
    WritingItem w,
  ) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      child: ListTile(
        dense: true,
        leading: const Icon(Icons.article, size: 20),
        title: Text(
          // v259：文件名全显不截断（v95规则：章节/文件标题必须全显）——
          // maxLines 1→2，长场景名换行显示
          '弧线${w.arcKey} · ${w.sceneName.isNotEmpty ? w.sceneName : '场景${w.sceneIdx + 1}'}',
          style: const TextStyle(fontSize: 13),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text(
          '${w.chapterRange} · ${w.content.length}字 · v${w.version}'
          '${w.createdAt != null ? ' · ${_fmtDateTime(w.createdAt!)}' : ''}'
          // v639：显示模型@温度（老条目model为空则不显示，不编造）
          '${w.model.isNotEmpty ? ' · ${w.model}@${w.temperature}' : ''}'
          '${w.draft ? ' · 草稿' : ''}',
          style: const TextStyle(fontSize: 11),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (w.versions.isNotEmpty)
              IconButton(
                icon: const Icon(Icons.history, size: 18, color: Colors.amber),
                tooltip: '历史版本(${w.versions.length})',
                onPressed: () => _showVersions(state, w),
              ),
            IconButton(
              icon: const Icon(Icons.delete, size: 18, color: Colors.red),
              onPressed: () {
                state.writings.remove(w.key);
                state.saveWritings();
              },
            ),
          ],
        ),
        onTap: () => _viewWriting(context, w),
      ),
    );
  }

  /// 历史版本查看
  void _showVersions(AppState state, WritingItem w) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('历史版本（${w.versions.length}）'),
        content: SizedBox(
          width: double.maxFinite,
          height: 300,
          child: ListView.builder(
            itemCount: w.versions.length,
            itemBuilder: (c, i) {
              final v = w.versions[i];
              return ListTile(
                dense: true,
                title: Text(
                  'v${v.version} · ${v.content.length}字',
                  style: const TextStyle(fontSize: 13),
                ),
                subtitle: Text(
                  v.createdAt?.toString().substring(0, 16) ?? '',
                  style: const TextStyle(fontSize: 11),
                ),
                onTap: () {
                  Navigator.pop(ctx);
                  _viewWriting(context, v);
                },
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  /// 批量创作对话框（v468三选：仅未创作/全部重创/取消）
  void _showBatchDialog(AppState state) {
    if (state.worldBook == null || state.worldBook!.entries.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('请先生成世界书条目')));
      return;
    }
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('批量创作'),
        content: const Text('逐场景调用API创作正文，选择范围：'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          OutlinedButton(
            onPressed: () {
              Navigator.pop(ctx);
              _generateAll(state, skipCreated: true);
            },
            child: const Text('仅未创作场景'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              _generateAll(state, skipCreated: false);
            },
            child: const Text('全部重新创作'),
          ),
        ],
      ),
    );
  }

  /// v266：逐镜分步生成（用户架构方案：每镜单独API调用）——分镜结构
  /// 行由代码从世界书确定性插入（不进AI输出=粘连/伪JSON/长输出衰减的
  /// 源头全部消失），AI只输出该镜纯正文（300-600字短输出，格式纪律
  /// 天然好）。前文衔接用已生成正文尾部。失败重试2次→该镜正文空缺
  /// （结构保留，可单镜补生成）。返回组装好的场景正文；世界书结构
  /// 解析不出（无分镜）返回null→调用方fallback整场景模式
  Future<String?> _generateShotByShot(
    AppState state,
    ApiConfig config,
    String arcKey,
    int si,
    String sceneName, {
    String styleSample = '',
    bool batch = false, // v366b：批量时不弹词链预览（与整场景路径统一）
    String sceneChapterRange = '', // v548：草稿元数据
  }) async {
    final wb = state.worldBook;
    if (wb == null) {
      _addLog('逐镜转整场景：世界书为空');
      return null;
    }
    // v268：两种条目结构支持——单弧线条目（sceneTag空，场景块从
    // "场景N："定位切出）+场景散条目（sceneTag=arcKey_si，整条即场景
    // 块——新生成的世界书可能是散结构，此前只认弧线条目→静默fallback
    // 整场景模式=用户实测"json模式没分步"的根因，散条目+原因日志补齐）
    final arcEntries = wb.entries.values
        .where(
          (e) =>
              e.arcKey == arcKey &&
              (e.sceneTag == null || e.sceneTag!.isEmpty),
        )
        .toList();
    final sceneEntries = wb.entries.values
        .where((e) => e.arcKey == arcKey && e.sceneTag == '${arcKey}_$si')
        .toList();
    String sceneBlock;
    if (arcEntries.isNotEmpty) {
      final content = arcEntries.first.content;
      // 场景块定位（场景si+1：到下一场景/九件套标记——与写回定位同款）
      final sm = RegExp('场景\\s*${si + 1}\\s*[：:]').firstMatch(content);
      if (sm == null) {
        if (sceneEntries.isEmpty) {
          _addLog('逐镜转整场景：弧线条目里定位不到场景${si + 1}头');
          return null;
        }
        sceneBlock = sceneEntries.first.content; // 散条目兜底
      } else {
        final nextRe = RegExp(
          r'场景\s*\d+\s*[：:]|【世界观设定】|【人设】|【矛盾冲突】|【伏笔】|【弧线功能】|【不可逆变化】|【情绪曲线】|【作者脑洞】',
        );
        final nm = nextRe
            .allMatches(content)
            .where((m) => m.start >= sm.end)
            .toList();
        sceneBlock = content.substring(
          sm.start,
          nm.isEmpty ? content.length : nm.first.start,
        );
      }
    } else if (sceneEntries.isNotEmpty) {
      sceneBlock = sceneEntries.first.content; // 散条目：整条即场景块
    } else {
      _addLog('逐镜转整场景：世界书没有arcKey=$arcKey的条目');
      return null;
    }
    // v276：读侧拆粘连（世界书里的"维度行…分镜N："粘连行——不拆则
    // shotRe行锚定找不到分镜边界→块合并错位→粘连复制进正文）
    sceneBlock = TextCleaner.repairGluedShotEntry(sceneBlock);
    // v703：JSON壳维度行修复（世界书条目里"焦点(Focus)":"xxx",壳化行
    // 照抄进草稿=大量符号残渣——组装前先规范化）
    sceneBlock = TextCleaner.repairJsonDimLines(sceneBlock);
    // 分镜块切分（v265修复版：不吃换行，块从分镜行开始）
    final shotRe = RegExp(
      r'^[^\u4e00-\u9fa5\n]*[\[（(【]*#*[^\S\n]*[\[（(【]?分[镜景](头)?[^\S\n]*(\d+[^\S\n]*[\]）)】]?[^\S\n]*[：:]?|[\]）)】]?[^\S\n]*[：:])',
      multiLine: true,
    );
    final shotMatches = shotRe.allMatches(sceneBlock).toList();
    if (shotMatches.isEmpty) {
      _addLog('世界书场景${si + 1}无分镜块，fallback整场景模式');
      return null;
    }
    _addLog('逐镜生成模式：${shotMatches.length}个分镜，结构由世界书插入');
    // 场景头+概述区（首个分镜前的内容原样保留）
    final sb = StringBuffer();
    sb.writeln(sceneBlock.substring(0, shotMatches.first.start).trimRight());
    // v548：逐镜实时保存——每镜完成即更新草稿WritingItem（含中止/停机
    // 路径），中断后部分成果不再丢失。finalize时caller复用该草稿（draft
    // 置false），不重复抬版本号
    final wkey0 = '${arcKey}_$si';
    WritingItem? draftItem;
    Future<void> savePartial() async {
      final content = TextCleaner.decodeLiteralNewlines(
        TextCleaner.stripDecorativeEmoji(sb.toString()),
      );
      if (draftItem == null) {
        final old = state.writings[wkey0];
        var version = 1;
        final versions = <WritingItem>[];
        if (old != null) {
          version = old.version + 1;
          versions.addAll(old.versions);
          versions.add(old);
        }
        draftItem = WritingItem(
          key: wkey0,
          arcKey: arcKey,
          sceneIdx: si,
          sceneName: sceneName,
          chapterRange: sceneChapterRange,
          content: content,
          createdAt: DateTime.now(),
          version: version,
          versions: versions,
          model: config.effectiveModel,
          temperature: config.temperature,
          draft: true,
        );
      } else {
        draftItem!.content = content;
        draftItem!.createdAt = DateTime.now();
      }
      state.writings[wkey0] = draftItem!;
      state.saveWritings();
      _addLog('💾 实时保存（${content.length}字，草稿）');
    }
    // 场景头行（衔接prompt用，v268：从sceneBlock首行取——散条目/弧线
    // 条目统一，场景N：头或首行）
    final lineEnd = sceneBlock.indexOf('\n');
    final sceneHead = sceneBlock
        .substring(0, lineEnd < 0 ? sceneBlock.length : lineEnd)
        .trim();
    var failed = 0;
    var stopped = false; // v268失败停机标记
    // v642：逐镜批量步进——每步一次API生成N镜（缓存切分，逐镜组装/质检/返工不变）
    final shotStep = state.writingShotStep.clamp(1, 10);
    if (shotStep > 1) _addLog('⚡ 逐镜步进=$shotStep（每次API生成$shotStep镜，省额度）');
    List<String> chunkBodies = const [];
    var chunkEnd = -1; // 本chunk覆盖 shotMatches[i..chunkEnd-1]（exclusive）
    var chunkStart = -1; // v650：chunk起点显式记录——此前从chunkBodies.length反推,切分段数≠预期时算出负索引(RangeError -4)
    for (var i = 0; i < shotMatches.length; i++) {
      if (state.api.isAborted || state.userAborted) {
        // 中止：剩余分镜结构照抄（正文空缺可后补），返回已生成部分
        for (var j = i; j < shotMatches.length; j++) {
          final be = j + 1 < shotMatches.length
              ? shotMatches[j + 1].start
              : sceneBlock.length;
          sb.writeln(sceneBlock.substring(shotMatches[j].start, be).trimRight());
        }
        _addLog('⏹ 逐镜生成中止：分镜${i + 1}起正文空缺（结构已保留）');
        await savePartial(); // v548：中止也保住已生成部分
        return sb.toString();
      }
      final blockEnd = i + 1 < shotMatches.length
          ? shotMatches[i + 1].start
          : sceneBlock.length;
      final shotBlock = sceneBlock
          .substring(shotMatches[i].start, blockEnd)
          .trimRight();
      // 前文衔接：已组装正文全量注入（v376用户裁决，与单镜统一——
      // 每镜一次API请求，本镜看到之前所有镜的完整正文）
      final prevTail = sb.toString();
      // v369：前置分镜概要（本镜之前各镜的focus+镜头类型，连戏）
      final prevShots = <String>[];
      for (var pi = 0; pi < i; pi++) {
        final psBlock = sceneBlock
            .substring(shotMatches[pi].start, shotMatches[pi].end)
            .trimRight();
        final pFocus = _dimValue(psBlock, ['焦点', 'Focus']);
        final pShot = _dimValue(psBlock, ['镜头类型', 'Shot Type']);
        if (pFocus.isNotEmpty || pShot.isNotEmpty) {
          prevShots.add('分镜${pi + 1}：${pFocus.isNotEmpty ? pFocus : '（无focus）'}｜$pShot');
        }
      }
      // v642：到达chunk边界——一次API生成本步N镜并切分缓存
      var chunkRetried = false;
      if (i >= chunkEnd) {
        final cStart = i;
        chunkEnd = (i + shotStep < shotMatches.length) ? i + shotStep : shotMatches.length;
        final cBlocks = <String>[];
        for (var j = cStart; j < chunkEnd; j++) {
          final be = j + 1 < shotMatches.length
              ? shotMatches[j + 1].start
              : sceneBlock.length;
          cBlocks.add(sceneBlock.substring(shotMatches[j].start, be).trimRight());
        }
        final combined =
            '（⚠️ 本批共${chunkEnd - cStart}镜连写：按顺序输出每一镜的完整结构块（照抄下方原块，维度行一行不落）+ 该镜正文；镜与镜直接连续，禁止省略结构块、禁止合并各镜正文）\n\n${cBlocks.join('\n\n')}';
        final cUser = PromptBuilder.buildSingleShotWriteUserPrompt(
          sceneHeader: sceneHead,
          shotInfo: combined,
          prevTail: TextCleaner.stripShotHeaders(sb.toString()),
          extraPrompt: state.writingPrompt,
          arcSummary: _arcSummaryForShot(state, arcKey),
          inkHabit: _inkHabitForShot(state, arcKey),
          styleDna: _styleDnaForShot(state, arcKey),
          arcDeclaration: _arcDeclForWriting(state, arcKey.toString()),
          styleSample: state.writingImitateAuthor
              ? _buildChunkSample(state, arcKey, si, cStart, chunkEnd)
              : '',
          styleAtts: state.writingAttachments,
          contentAtts: state.sceneAttachments['${arcKey}_$si'] ?? const [],
          prevShots: prevShots,
        );
        if (state.writingPromptPreview && mounted) {
          final ok = await PromptPreview.maybePreview(
            context,
            sysPrompt: PromptBuilder.buildSingleShotWriteSystemPrompt(),
            userPrompt: cUser,
            title: '步进分块词链预览 — 场景${si + 1} 分镜${cStart + 1}-${chunkEnd}',
            enabled: true,
          );
          if (!ok) {
            state.userAborted = true;
            _addLog('⏹ 已取消发送，批量终止');
            return null;
          }
        }
        final cResult = await state.api.callApi(
          systemPrompt: PromptBuilder.buildSingleShotWriteSystemPrompt(),
          userPrompt: cUser,
          apiConfig: config,
        );
        if (!cResult.isSuccess) {
          // v649：524家族退避重试一次（连写请求更长更易被中转CDN掐）
          final cdn = cResult.statusCode != null &&
              [520, 522, 524, 525, 527].contains(cResult.statusCode);
          if (cdn && !chunkRetried) {
            chunkRetried = true;
            _addLog('⚡ 分块HTTP ${cResult.statusCode}（中转CDN），45s后重试一次...');
            await Future.delayed(const Duration(seconds: 45));
            i = cStart - 1; // 回退到本chunk起点重走（continue后i++回到cStart）
            continue;
          }
          _addLog('⛔ 步进分块生成失败：${cResult.error ?? cResult.statusCode}——停机');
          for (var j = i; j < shotMatches.length; j++) {
            final be = j + 1 < shotMatches.length
                ? shotMatches[j + 1].start
                : sceneBlock.length;
            sb.writeln(sceneBlock.substring(shotMatches[j].start, be).trimRight());
          }
          await savePartial();
          stopped = true;
          break;
        }
        chunkBodies = _splitChunkProse(cResult.content, chunkEnd - cStart);
        _addLog('⚡ 本步${chunkEnd - cStart}镜一次生成（切分${chunkBodies.length}段）');
        if (chunkBodies.length != chunkEnd - cStart) {
          // v650：AI没按结构逐镜输出（如全并成1段）——缓存作废回退逐镜API。
          // 此前"按序对应"会把整段并文错归属到第1镜+缺口算负索引崩溃
          _addLog('⚠️ 切分段数≠${chunkEnd - cStart}镜——本批缓存作废，回退逐镜生成');
          chunkBodies = const [];
        }
        chunkStart = cStart;
      }
      final sys = PromptBuilder.buildSingleShotWriteSystemPrompt();
      final user = PromptBuilder.buildSingleShotWriteUserPrompt(
        sceneHeader: sceneHead,
        shotInfo: shotBlock, // 整镜结构块（分镜头行+维度行）作生成依据
        prevTail: TextCleaner.stripShotHeaders(prevTail),
        extraPrompt: state.writingPrompt,
        // v269：弧线级上下文（用户确认补——此前逐镜只有场景块+单镜
        // 结构+前文，弧线概述/笔墨癖好/文风素材真空）
        arcSummary: _arcSummaryForShot(state, arcKey),
        inkHabit: _inkHabitForShot(state, arcKey),
        styleDna: _styleDnaForShot(state, arcKey), // v640
        arcDeclaration: _arcDeclForWriting(state, arcKey.toString()),
        // v363：镜级范文优先（有镜级锚点时注入本镜原文段落，无→回退场景切片）
        styleSample: state.writingImitateAuthor
            ? _buildShotLevelSample(state, arcKey, si, i)
            : '',
        styleAtts: state.writingAttachments,
        // v357：本场景内容素材
        contentAtts: state.sceneAttachments['${arcKey}_$si'] ?? const [],
        prevShots: prevShots,
      );
      // v368：批量也弹词链（用户裁决：连弹可以接受，能终止就行）；
      // 取消=置userAborted让批量循环干净停（返回null上层判失败即停）
      if (state.writingPromptPreview && mounted) {
        final ok = await PromptPreview.maybePreview(
          context,
          sysPrompt: sys,
          userPrompt: user,
          title: '逐镜生成词链预览 — 弧线$arcKey 场景${si + 1} 分镜${i + 1}',
          enabled: true,
        );
        if (!ok) {
          state.userAborted = true;
          _addLog('⏹ 已取消发送，批量终止');
          return null;
        }
      }
      var body = '';
      var shotRetry = 0;
      final cached = (chunkBodies.isNotEmpty && i >= chunkStart && i < chunkEnd)
          ? chunkBodies[i - chunkStart]
          : null;
      if (cached != null) {
        body = cached; // v642：步进缓存直接取本镜正文（跳过API）
      } else
      while (true) {
        final result = await state.api.callApi(
          systemPrompt: sys,
          userPrompt: user,
          apiConfig: config,
        );
        if (!result.isSuccess) {
          // v649：524家族（中转CDN掐Gemini思考期）与503同列自动重试
          final cdnErr = result.statusCode != null &&
              [520, 522, 524, 525, 527].contains(result.statusCode);
          if ((result.statusCode == 503 || cdnErr) && shotRetry < 2) {
            shotRetry++;
            _addLog('分镜${i + 1}：HTTP ${result.statusCode}${cdnErr ? "（中转CDN）" : "过载"}，${20 * shotRetry}s后重试...');
            await Future.delayed(Duration(seconds: 20 * shotRetry));
            continue;
          }
          _addLog('❌ 分镜${i + 1}生成失败：${result.error}');
          // v268：失败停机（用户要求"某一步失败应该停下来，后面增量
          // 生成"）——不再继续烧后续分镜的API，剩余分镜结构照抄保留
          // （渲染显示结构+空正文），点"补缺失"按钮增量生成
          _addLog('⏹ 已停机：前${i}镜完成，剩余${shotMatches.length - i}镜结构保留待补');
          await savePartial(); // v548：停机保住已生成部分
          for (var j = i; j < shotMatches.length; j++) {
            final be = j + 1 < shotMatches.length
                ? shotMatches[j + 1].start
                : sceneBlock.length;
            sb.writeln(sceneBlock.substring(shotMatches[j].start, be).trimRight());
            sb.writeln();
          }
          stopped = true;
          break;
        }
        // v539：篇幅硬约束——超原文目标20%自动返工一次（啰嗦治理机制层兜底）
        var shotContent = result.content;
        final lenTarget = PromptBuilder.shotLengthTarget(shotBlock);
        if (lenTarget != null &&
            lenTarget > 0 &&
            shotContent.length > (lenTarget * 1.2).round() &&
            !state.api.isAborted) {
          _addLog('📏 分镜${i + 1}输出${shotContent.length}字符，超原文约$lenTarget的20%——返工压缩一次');
          final user2 = PromptBuilder.buildSingleShotWriteUserPrompt(
            sceneHeader: sceneHead,
            shotInfo: shotBlock,
            prevTail: TextCleaner.stripShotHeaders(prevTail),
            extraPrompt:
                '${state.writingPrompt}\n\n${PromptBuilder.lengthRetakeExtra(lenTarget, shotContent.length)}',
            arcSummary: _arcSummaryForShot(state, arcKey),
            inkHabit: _inkHabitForShot(state, arcKey),
        styleDna: _styleDnaForShot(state, arcKey), // v640
            arcDeclaration: _arcDeclForWriting(state, arcKey.toString()),
            styleSample: state.writingImitateAuthor
                ? _buildShotLevelSample(state, arcKey, si, i)
                : '',
            styleAtts: state.writingAttachments,
            contentAtts: state.sceneAttachments['${arcKey}_$si'] ?? const [],
            prevShots: prevShots,
          );
          final r2 = await state.api.callApi(
            systemPrompt: sys,
            userPrompt: user2,
            apiConfig: config,
          );
          if (r2.isSuccess &&
              r2.content.trim().isNotEmpty &&
              r2.content.length < shotContent.length) {
            shotContent = r2.content;
            _addLog('✓ 返工后${shotContent.length}字符');
          } else {
            _addLog('返工未改善，保留原稿');
          }
        }
        var normalized = TextCleaner.normalizeAiOutput(
          shotContent,
          jsonMode: config.formatMode == 'json',
        );
        if (config.formatMode == 'json' &&
            TextCleaner.jsonFormatBad(shotContent)) {
          normalized = TextCleaner.salvagePseudoJson(shotContent);
        }
        // 单镜短输出：剥emoji+结构残留（AI无视指令带结构行时）+外层
        // 包裹引号（v273：AI把整段正文当字符串值输出"……"的包装形态）
        body = TextCleaner.stripWrapQuotes(
          TextCleaner.stripShotHeaders(
            TextCleaner.stripDecorativeEmoji(normalized),
          ),
        ).trim();
        break;
      }
      // 组装：结构照抄（世界书原样）+空行+正文+空行
      sb.writeln(shotBlock);
      sb.writeln();
      if (body.isNotEmpty) {
        // v513：原文相似度检测——镜级切片对照（名称外抄袭率>10%自动改写一轮）
        final originSlice = _buildShotLevelSample(state, arcKey, si, i);
        if (originSlice.isNotEmpty) {
          final legitVocabBuf =
              StringBuffer(state.worldBook?.requirements ?? '');
          for (final e in state.worldBook!.entries.values) {
            legitVocabBuf.write(e.content);
          }
          final (ratio, hits) = PromptBuilder.copiedRatio(
            originSlice,
            body,
            legitVocab: legitVocabBuf.toString(),
          );
          _addLog(
            '📊 分镜${i + 1}原文相似度：${(ratio * 100).toStringAsFixed(1)}%（阈值10%）',
          );
          if (ratio > 0.10) {
            _addLog('⚠️ 抄袭片段：${hits.take(5).join(' / ')}');
            _addLog('🔄 自动改写中（要求：保持情节，名称外全部换说法）…');
            final rwSys =
                '你是网文改写助手。任务：把给定正文改写为原创表达——保持全部情节信息/人物/因果不变，但除人名/地名/专有名词外，与原文片段相同的句子必须换句式、换措辞重新表达。直接输出改写后的完整正文，不要任何说明。';
            final rwUser =
                '【需要改写的正文】\n$body\n\n【与原文雷同的片段（必须全部换说法）】\n${hits.take(8).join('\n')}';
            final rwResult = await state.api.callApi(
              systemPrompt: rwSys,
              userPrompt: rwUser,
              apiConfig: config,
            );
            if (rwResult.isSuccess) {
              // v551：改写输出先过归一化+JSON壳剥离（AI把改写结果包成
              // {"rewritten_text":"..."}回来，截图实证残渣进正文）
              final newBody = TextCleaner.stripWrapQuotes(
                TextCleaner.stripShotHeaders(
                  TextCleaner.stripDecorativeEmoji(
                    TextCleaner.normalizeAiOutput(
                      rwResult.content,
                      jsonMode: config.formatMode == 'json',
                    ),
                  ),
                ),
              ).trim();
              if (newBody.length >= body.length ~/ 2) {
                final (r2, _) = PromptBuilder.copiedRatio(
                  originSlice,
                  newBody,
                  legitVocab: legitVocabBuf.toString(),
                );
                _addLog(
                  '📊 改写后相似度：${(r2 * 100).toStringAsFixed(1)}%'
                  '${r2 <= 0.10 ? '（✓达标）' : '（⚠️仍超阈值，建议手动调整）'}',
                );
                body = newBody;
              } else {
                _addLog('⚠️ 改写返回过短（${newBody.length}字），保留原稿');
              }
            } else {
              _addLog('⚠️ 改写请求失败（${rwResult.statusCode}），保留原稿');
            }
          }
        }
        sb.writeln(body);
        sb.writeln();
      } else {
        failed++;
      }
      _addLog('✓ 分镜${i + 1}/${shotMatches.length}完成（正文${body.length}字）');
      await savePartial(); // v548：每镜实时保存
    }
    if (failed > 0) {
      _addLog('⚠️ 本场景${failed}个分镜正文空缺（结构保留，可"补缺失"增量生成）');
    }
    if (stopped) {
      _addLog('💡 已保存部分创作，打开后点"补缺失分镜"继续增量生成');
    }
    // v275：去重兜底（世界书条目自身带重复分镜时防止复制进正文）
    return TextCleaner.dedupeShotBlocks(sb.toString());
  }

  /// 单场景创作（v468 createSceneWriting：版本管理+保存txt）
  Future<bool> _createSceneWriting(
    AppState state,
    String arcKey,
    int si, {
    bool batch = false,
  }) async {
    state.api.clearAbort(); state.userAborted = false; // 清除上次abort残留（v187：含batch调用，防止批量中途终止残留传染）
    // 场景数据源同列表：世界书解析优先（保证列表与创作一致）
    final scenes = _writingScenes(state, arcKey);
    if (si >= scenes.length) return false;
    final scene = scenes[si];
    final sceneName = scene.$1;
    final wkey = '${arcKey}_$si';

    if (!batch) {
      setState(() => _isGenerating = true);
    }
    setState(() => _activeKeys.add(wkey));
    setState(() => _statusText = '正在创作：弧线$arcKey 场景${si + 1} $sceneName');
    _addLog('━━ 创作弧线$arcKey场景${si + 1}：$sceneName');

    try {
      // v313：模仿原文作者——按场景序号取样弧线原文范文
      String styleSample = '';
      if (state.writingImitateAuthor) {
        styleSample = _buildStyleSample(state, arcKey, si);
        if (styleSample.isNotEmpty) {
          _addLog('✓ 注入文风范文${styleSample.length}字（场景切片前${styleSample.length}字）');
        } else {
          _addLog('⚠ 场景${si + 1}无锚定切片（旧数据）——未注入文风范文，请重新划分场景');
        }
      }
      // v313：范文搬运检测——合法词汇=世界书条目+创作要求（改编沿用的原著专名豁免）
      final legitVocabBuf = StringBuffer(state.worldBook?.requirements ?? '');
      state.worldBook?.entries.values.forEach((e) {
        legitVocabBuf.write(e.content);
      });
      final legitVocab = legitVocabBuf.toString();
      void checkSampleCopy(String content) {
        if (styleSample.isEmpty) return;
        final hits = PromptBuilder.findCopiedPhrases(
          styleSample,
          content,
          legitVocab: legitVocab,
        );
        if (hits.isNotEmpty) {
          _addLog(
            '⚠ 范文搬运检测：正文与范文疑似雷同${hits.length}处——${hits.take(5).join('、')}（非设定词汇请手动改写）',
          );
        } else {
          _addLog('✓ 范文搬运检测通过');
        }
      }
      // v570：映射表注入创作端（改编分镜为依据+映射兜底一致性）
      final mapTable = state.worldBook!.nameMapping.trim();
      final creationReq = mapTable.isEmpty
          ? state.worldBook!.requirements.trim()
          : '【改编映射表（全书级，最高优先级强制执行）】\n'
              '⚠️ 人物名一律保留原著名（换名由输出层映射表统一处理），禁止使用新名或自行改名；'
              '设定/规则类映射是语义替换，必须执行。'
              '映射表未收录的原著名同样保留原名照抄。\n$mapTable'
              '${state.worldBook!.requirements.trim().isEmpty ? '' : '\n\n${state.worldBook!.requirements.trim()}'}';
      final hasAdaptation = creationReq.isNotEmpty;
      // v582：条目无分镜结构（只改编到弧线层）自动转自由模式——
      // 免得prompt硬要求"按分镜逐一创作"而条目里没有分镜，AI要么拒写要么照抄范文
      final sceneEntryContent = state.worldBook!.entries.values
          .where((e) =>
              e.arcKey == arcKey.toString() &&
              (e.sceneTag == null || e.sceneTag!.isEmpty))
          .map((e) => e.content)
          .join('\n');
      final hasShotStruct =
          RegExp('分镜\\s*0*[1-9]').hasMatch(sceneEntryContent);
      final effectiveFree = state.writingFreeMode || !hasShotStruct;
      if (!state.writingFreeMode && !hasShotStruct) {
        _addLog('ℹ️ 条目无分镜结构（只改编到弧线层）——自动自由创作模式');
      }
      // v545：自由创作——系统prompt末尾追加覆盖令
      var systemPrompt = PromptBuilder.buildWritingSystemPrompt(
        hasAdaptation: hasAdaptation,
      );
      if (effectiveFree) {
        systemPrompt += PromptBuilder.freeModeOverride();
      }
      // v469对齐：前一场景正文结尾300字（衔接用）
      var prevEnding = '';
      if (si > 0) {
        final prev = state.writings['${arcKey}_${si - 1}'];
        if (prev != null && prev.content.isNotEmpty) {
          prevEnding = prev.content;
        }
      }
      // v469对齐：弧线标题（从扫描结果找）
      var arcTitle = '';
      for (final a in state.completedArcs) {
        if (a.number.toString() == arcKey.toString()) {
          arcTitle = a.title;
          break;
        }
      }
      // v545：场景概述——从弧线拆解的场景摘要取（无则空，跳过注入）
      var sceneSummary = '';
      final arcNum = int.tryParse(arcKey.toString());
      final arcAnalysis =
          arcNum != null ? state.arcAnalyses[arcNum.toString()] : null;
      if (arcAnalysis != null && si < arcAnalysis.scenes.length) {
        sceneSummary = arcAnalysis.scenes[si].summary;
      }
      final userPrompt = PromptBuilder.buildWritingUserPrompt(
        arcKey,
        si,
        worldBookEntries: state.worldBook!.entries,
        freeShotMode: effectiveFree,
        leanShots: state.writingLeanShots,
        sceneSummary: sceneSummary,
        requirements: creationReq,
        writingPrompt: state.writingPrompt,
        scenePrompt: state.writingScenePrompts[wkey] ?? '',
        arcTitle: arcTitle,
        arcDeclaration: _arcDeclForWriting(state, arcKey.toString()),
        prevEnding: prevEnding,
        sceneName: scene.$1,
        sceneChapterRange: scene.$2,
        // v357：attachments=全局文风素材+本场景内容素材
        attachments: [
          ...state.writingAttachments,
          ...(state.sceneAttachments[wkey] ?? const []),
        ],
        worldbuildingSystems: state.worldBook?.systems,
        styleSample: styleSample,
      );

      final config = state.getApiConfig('writing');
      // v469对齐：提示词预览开关开启时，先弹预览确认后才发送（批量模式跳过——无人值守）
      // v368：批量也弹词链；取消=置userAborted让批量循环干净停
      // v511b：逐镜模式跳过场景级预览（那是整场景fallback路的prompt，
      // 逐镜不消费它=死预览误导"发的是这套"；逐镜每镜在内部自己弹）
      if (!state.writingShotByShot &&
          state.writingPromptPreview &&
          mounted) {
        final confirmed = await _showWritingPromptPreview(
          systemPrompt,
          userPrompt,
          '创作词链预览 — ${sceneName.isNotEmpty ? sceneName : '弧线$arcKey 场景${si + 1}'}',
        );
        if (!confirmed) {
          state.userAborted = true;
          _addLog('⏹ 已取消发送，批量终止');
          return false;
        }
      }
      _addLog('模型：${config.effectiveModel}');
      // v266：逐镜分步生成优先（结构由代码插入+AI只出纯正文——格式
      // 问题源头消失）；失败/无分镜自动fallback整场景老路
      if (state.writingShotByShot) {
        final shotByShotContent = await _generateShotByShot(
          state,
          config,
          arcKey,
          si,
          sceneName,
          styleSample: styleSample,
          batch: batch,
          sceneChapterRange: scene.$2,
        );
        if (shotByShotContent != null) {
        // v503c：内存content保留结构态（穿插渲染靠分镜头/场景头行）——
        // v415误剥回归修正：磁盘txt在下方txtContent单独剥，结构不进磁盘
        final cleanContent = TextCleaner.decodeLiteralNewlines(
          TextCleaner.stripDecorativeEmoji(shotByShotContent),
        );
          _addLog('逐镜生成完成：${cleanContent.length}字');
          // v548：逐镜草稿复用——实时保存已建draft时就地finalize
          // （内容更新+draft置false），不重复抬版本号
          final old = state.writings[wkey];
          WritingItem writing;
          if (old != null && old.draft) {
            writing = old;
            writing.content = cleanContent;
            writing.draft = false;
            writing.createdAt = DateTime.now();
          } else {
            var version = 1;
            final versions = <WritingItem>[];
            if (old != null) {
              version = old.version + 1;
              versions.addAll(old.versions);
              versions.add(old);
            }
            writing = WritingItem(
              key: wkey,
              arcKey: arcKey,
              sceneIdx: si,
              sceneName: sceneName,
              chapterRange: scene.$2,
              content: TextCleaner.fixShotBodyOrder(cleanContent),
              createdAt: DateTime.now(),
              version: version,
              versions: versions,
              model: config.effectiveModel,
              temperature: config.temperature,
            );
          }
          state.writings[wkey] = writing;
          state.saveWritings();
          checkSampleCopy(cleanContent);
          var txtContent = TextCleaner.stripShotHeaders(cleanContent);
          if (state.writingModelNote && config.effectiveModel.isNotEmpty) {
            txtContent = '[模型：${config.effectiveModel} · 温度${config.temperature}]\n\n$txtContent';
          }
          final path = state.storage.getWritingPath(
            arcKey,
            si,
            sceneName,
            scene.$2,
            writing.version,
          );
          state.storage.writeFile(path, txtContent);
          _addLog('✓ 已保存 v${writing.version}（${txtContent.length}字 → $path）');
          state.refresh();
          return true;
        }
      }
      var result = await state.api.callApi(
        systemPrompt: systemPrompt,
        userPrompt: userPrompt,
        apiConfig: config,
      );
      // 503模型过载自动重试（临时高负载，最多3次，间隔20s）；429配额问题重试无用直接报
      var retryCount = 0;
      while (result.statusCode == 503 &&
          retryCount < 3 &&
          !state.api.isAborted || state.userAborted) {
        retryCount++;
        _addLog('503模型过载，${20 * retryCount}s后自动重试（第$retryCount/3次）...');
        await Future.delayed(Duration(seconds: 20 * retryCount));
        if (state.api.isAborted) break;
        result = await state.api.callApi(
          systemPrompt: systemPrompt,
          userPrompt: userPrompt,
          apiConfig: config,
        );
      }

      // v264：连击计数——同会话伪JSON连续≥2次=中转稳定剥壳（gcli实测
      // 3/3全坏），重试纯属烧时间，跳过直接抢救；好输出归零计数
      if (result.isSuccess && config.formatMode == 'json') {
        state.pseudoJsonStreak = TextCleaner.jsonFormatBad(result.content)
            ? state.pseudoJsonStreak + 1
            : 0;
      }
      if (result.isSuccess &&
          config.formatMode == 'json' &&
          TextCleaner.jsonFormatBad(result.content) &&
          state.pseudoJsonStreak >= 2) {
        _addLog('同会话伪JSON已连击${state.pseudoJsonStreak}次（中转稳定剥壳），跳过重试直接抢救');
      }
      // v259：json模式格式坏重试（v256留的"上层hasError判定"钩子接线——
      // 伪JSON解不出时normalize返回原文，此前isSuccess只判HTTP成功，坏输出
      // 带着{和字面\n直接入库→提纯正则按真换行分行全部空转=提纯不了的根因）
      var fmtRetry = 0;
      while (result.isSuccess &&
          config.formatMode == 'json' &&
          TextCleaner.jsonFormatBad(result.content) &&
          fmtRetry < 2 &&
          state.pseudoJsonStreak < 2 &&
          !state.api.isAborted) {
        fmtRetry++;
        _addLog('⚠️ AI输出伪JSON格式坏（中转可能剥了response_format），10s后重试（第$fmtRetry/2次）...');
        await Future.delayed(const Duration(seconds: 10));
        if (state.api.isAborted) break;
        result = await state.api.callApi(
          systemPrompt: systemPrompt,
          userPrompt: userPrompt,
          apiConfig: config,
        );
      }
      if (result.isSuccess) {
        // 入库清洗：v254先归一化（json/兼容混合输出：字面\n、JSON包装、
        // pair链、游离引号——23735字混合输出直接进正文的实测修复）再剥emoji
        var normalized = TextCleaner.normalizeAiOutput(
          result.content,
          jsonMode: config.formatMode == 'json',
        );
        // v259：重试后仍坏→伪JSON剥壳抢救（确定性变换：剥{壳+content前缀残片
        // +字面\n解码——不丢弃已生成内容，2.4万字白等一分多钟成本太高）
        if (config.formatMode == 'json' &&
            TextCleaner.jsonFormatBad(result.content)) {
          normalized = TextCleaner.salvagePseudoJson(result.content);
          _addLog('⚠️ 格式重试后仍坏，已剥壳抢救入库（${normalized.length}字）——内容建议抽查');
        }
        // v275：分镜块去重（整场景AI长输出重复退化——4万字输出实测
        /// 分镜9-73后从6复读一遍，去重保留首次）
        // v503c：同上，内存content保留结构态（穿插渲染依赖），磁盘txt单独剥
        var cleanContent = TextCleaner.decodeLiteralNewlines(
          TextCleaner.stripDecorativeEmoji(
            TextCleaner.dedupeShotBlocks(normalized),
          ),
        );
        _addLog('API返回：${result.content.length}字');
        // v513b：整场景原文相似度检测——场景切片对照
        // v613：自动改写停用（全场景重写效果差，语气/衔接易打断）——只报相似度，
        // 抄袭严重的镜用分镜卡"✨重写"单镜修复；逐镜模式的单镜自动改写保留
        const autoRewriteScene = false;
        final originSlice = _sceneSlice(state, arcKey, si);
        if (originSlice.isNotEmpty) {
          final legitVocabBuf =
              StringBuffer(state.worldBook?.requirements ?? '');
          for (final e in state.worldBook!.entries.values) {
            legitVocabBuf.write(e.content);
          }
          final (ratio, hits) = PromptBuilder.copiedRatio(
            originSlice,
            cleanContent,
            legitVocab: legitVocabBuf.toString(),
          );
          _addLog(
            '📊 整场景原文相似度：${(ratio * 100).toStringAsFixed(1)}%（阈值10%）',
          );
          if (ratio > 0.10) {
            _addLog('⚠️ 抄袭片段：${hits.take(5).join(' / ')}');
            // v613：整场景自动改写屏蔽（改写全场景效果差，整体语气/衔接易被打断）
            // ——只报相似度，抄袭严重的镜留待手动单镜重写（分镜卡✨改写保留）
            _addLog('💡 整场景自动改写已停用——请用分镜卡"✨重写"单镜修复抄袭片段');
          }
          if (autoRewriteScene && ratio > 0.10) {
            final rwSys =
                '你是网文改写助手。任务：把给定创作正文改写为原创表达——保持全部情节信息/人物/因果/场景结构不变；以"场景N："或"分镜N"开头的结构行原样保留；其余正文段落中，除人名/地名/专有名词外，与原文片段相同的句子必须换句式、换措辞重新表达。直接输出改写后的完整内容，不要任何说明。';
            final rwUser =
                '【需要改写的正文】\n$cleanContent\n\n【与原文雷同的片段（必须全部换说法）】\n${hits.take(8).join('\n')}';
            final rwResult = await state.api.callApi(
              systemPrompt: rwSys,
              userPrompt: rwUser,
              apiConfig: config,
            );
            if (rwResult.isSuccess) {
              final newContent = TextCleaner.stripWrapQuotes(
                TextCleaner.stripDecorativeEmoji(rwResult.content),
              ).trim();
              if (newContent.length >= cleanContent.length ~/ 2) {
                final (r2, _) = PromptBuilder.copiedRatio(
                  originSlice,
                  newContent,
                  legitVocab: legitVocabBuf.toString(),
                );
                _addLog(
                  '📊 改写后相似度：${(r2 * 100).toStringAsFixed(1)}%'
                  '${r2 <= 0.10 ? '（✓达标）' : '（⚠️仍超阈值，建议手动调整）'}',
                );
                cleanContent = newContent;
              } else {
                _addLog('⚠️ 改写返回过短（${newContent.length}字），保留原稿');
              }
            } else {
              _addLog('⚠️ 改写请求失败（${rwResult.statusCode}），保留原稿');
            }
          }
        }
        final old = state.writings[wkey];
        var version = 1;
        final versions = <WritingItem>[];
        if (old != null) {
          versions.addAll(old.versions);
          versions.add(
            WritingItem(
              key: old.key,
              arcKey: old.arcKey,
              sceneIdx: old.sceneIdx,
              sceneName: old.sceneName,
              chapterRange: old.chapterRange,
              content: old.content,
              createdAt: old.createdAt,
              version: old.version,
              model: old.model,
              temperature: old.temperature,
            ),
          );
          version = old.version + 1;
        }
        final writing = WritingItem(
          key: wkey,
          arcKey: arcKey,
          sceneIdx: si,
          sceneName: sceneName,
          chapterRange: scene.$2,
          content: cleanContent,
          createdAt: DateTime.now(),
          version: version,
          versions: versions,
          model: config.effectiveModel,
          temperature: config.temperature,
        );
        state.writings[wkey] = writing;
        state.saveWritings();
        checkSampleCopy(cleanContent);

        // 保存txt（纯正文，可选模型备注）
        // v259：导出前存量伪JSON剥壳（坏格式导出=提纯失败另一半）
        var txtContent = TextCleaner.stripShotHeaders(
          (config.formatMode == 'json' && TextCleaner.jsonFormatBad(cleanContent))
              ? TextCleaner.salvagePseudoJson(cleanContent)
              : cleanContent,
        );
        final note = _txtNote(
          state,
          model: config.effectiveModel,
          temp: config.temperature,
        );
        if (note != null) txtContent = '$note\n\n$txtContent';
        final path = state.storage.getWritingPath(
          arcKey,
          si,
          sceneName,
          scene.$2,
          version,
        );
        state.storage.writeFile(path, txtContent);
        _addLog('✓ 已保存 v$version（${txtContent.length}字 → $path）');
        state.refresh();
        return true;
      } else {
        _addLog('API错误：${result.error}');
        return false;
      }
    } catch (e) {
      if (state.api.isAborted || state.userAborted) {
        _addLog('⏹ 已终止');
      } else {
        _addLog('异常：$e');
      }
      return false;
    } finally {
      setState(() => _activeKeys.remove(wkey));
      if (!batch) {
        setState(() {
          _isGenerating = false;
          _statusText = '';
        });
      }
    }
  }

  /// 批量创作（v468：逐场景串行，可终止，失败即停）
  Future<void> _generateAll(AppState state, {required bool skipCreated}) async {
    state.api.clearAbort(); state.userAborted = false; // 清除上次abort残留（v187）
    final arcs = _writingArcs(state);
    if (state.worldBook == null) return;

    // 收集待创作场景
    final pending = <String, List<int>>{};
    for (final arc in arcs) {
      final arcKey = arc.number.toString();
      final scenes = _writingScenes(state, arcKey);
      if (scenes.isEmpty) continue;
      final list = <int>[];
      for (var si = 0; si < scenes.length; si++) {
        if (skipCreated && state.writings.containsKey('${arcKey}_$si'))
          continue;
        list.add(si);
      }
      if (list.isNotEmpty) pending[arcKey] = list;
    }
    if (pending.isEmpty) {
      _addLog('没有需要创作的场景');
      return;
    }
    final totalScenes = pending.values.fold<int>(0, (a, b) => a + b.length);
    setState(() => _isGenerating = true);
    _addLog(
      '批量创作开始：${pending.length}条弧线 $totalScenes个场景${skipCreated ? '（跳过已创作）' : '（全部重创）'}',
    );

    var done = 0;
    var failed = 0;
    // v368：全程try/finally——异常逃逸进度条永久卡死（v285同款病）
    try {
      for (final entry in pending.entries) {
        if (state.api.isAborted || state.userAborted) {
          _addLog('⏹ 批量创作被终止');
          break;
        }
        for (final si in entry.value) {
          if (state.api.isAborted || state.userAborted) {
            _addLog('⏹ 批量创作被终止');
            break;
          }
          done++;
          setState(() => _statusText = '批量创作：$done/$totalScenes');
          final ok = await _createSceneWriting(state, entry.key, si, batch: true);
          if (state.api.isAborted || state.userAborted) break; // 终止优先
          if (!ok) {
            failed++;
            _addLog('❌ 终止批量（连续失败）');
            break;
          }
        }
        if (failed > 0) break;
      }
      _addLog('批量创作完成：成功${done - failed} 失败$failed');
    } finally {
      if (!mounted) return;
      setState(() {
        _isGenerating = false;
        _statusText = '';
      });
    }
  }

  /// v469对齐：创作提示词预览对话框（SYSTEM PROMPT折叠+USER PROMPT格式化高亮）
  /// 返回true=确认发送
  Future<bool> _showWritingPromptPreview(
    String sysPrompt,
    String userPrompt,
    String title,
  ) async {
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
                title: const Text(
                  'SYSTEM PROMPT（点击展开/折叠）',
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: V469Style.accent,
                  ),
                ),
                children: [
                  Container(
                    width: double.infinity,
                    constraints: const BoxConstraints(maxHeight: 200),
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: V469Style.surfaceAlt,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: SingleChildScrollView(
                      child: SelectableText(
                        sysPrompt,
                        style: const TextStyle(
                          fontSize: 10.5,
                          height: 1.5,
                          color: V469Style.textMuted,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              // USER PROMPT（格式化）
              const Text(
                'USER PROMPT',
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: V469Style.accent,
                ),
              ),
              const SizedBox(height: 6),
              Expanded(
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: V469Style.surfaceAlt,
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: V469Style.border),
                  ),
                  child: SingleChildScrollView(
                    child: _formatUserPromptForPreview(userPrompt),
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确认发送'),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  /// v469 formatUserPromptForPreview：USER PROMPT逐行格式化
  /// 场景头红、##标题金棕、分镜头slate卡（含[维度]解析）、字段行图标+色、普通行灰
  Widget _formatUserPromptForPreview(String text) {
    final lines = text.split('\n');
    final widgets = <Widget>[];
    var shotCount = 0;
    for (final raw in lines) {
      var t = raw.trim();
      // markdown头剥离
      final md = RegExp(r'^(#{1,4})\s+(.+)').firstMatch(t);
      if (md != null) t = md.group(2)!.trim();
      if (t.isEmpty) {
        widgets.add(const SizedBox(height: 6));
        continue;
      }
      // 场景头：场景N：名称（范围）
      final sc = RegExp(r'^[^\u4e00-\u9fa5\n]*场[景面]\s*(\d+)\s*[：:]\s*(.+)')
          .firstMatch(t);
      if (sc != null) {
        widgets.add(
          Padding(
            padding: const EdgeInsets.only(top: 6, bottom: 3),
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: '场景${sc.group(1)}：',
                    style: const TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF7F1D1D),
                    ),
                  ),
                  TextSpan(
                    text: sc.group(2),
                    style: const TextStyle(
                      fontSize: 11.5,
                      color: Color(0xFF991B1B),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
        shotCount = 0;
        continue;
      }
      // 分镜头：分镜N：内容 [维度] ...
      // AI输出格式漂移容错（v91实测：后半段分镜编号/冒号漂移）：编号可选fallback序号，容忍分镜头
      // v606：容忍｜分隔（inline格式"分镜1｜焦点…"）
      final sh = RegExp(r'^[^\u4e00-\u9fa5\n]*分[镜头]头?\s*(\d+)?\s*[：:｜]\s*(.*)')
          .firstMatch(t);
      if (sh != null) {
        shotCount++;
        widgets.add(
          Container(
            margin: const EdgeInsets.symmetric(vertical: 2),
            padding: const EdgeInsets.all(5),
            decoration: BoxDecoration(
              color: V469Style.shotBg,
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: V469Style.shotBorder),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: '分镜${sh.group(1) ?? shotCount} ',
                        style: const TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          color: V469Style.shotBadgeFg,
                        ),
                      ),
                      TextSpan(
                        text: sh.group(2) ?? '',
                        style: const TextStyle(
                          fontSize: 10.5,
                          color: V469Style.shotBadgeFg,
                          height: 1.4,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
        continue;
      }
      // 字段行：标签：值（焦点/镜头/视角/投放/意图/转场/篇幅/文笔节奏）
      final fld = RegExp(
        r'^(焦点|镜头类型|镜头子类型|视角|投放信息?|意图|转场|篇幅|文笔节奏|语感|笔墨|语感锚|笔墨配额|功能抽象|叙事功能|内容|关键词|条目)\s*[：:]\s*(.*)',
      ).firstMatch(t);
      if (fld != null) {
        final label = fld.group(1)!;
        final value = fld.group(2) ?? '';
        final (icon, color) = switch (label) {
          '焦点' => ('🎯', const Color(0xFF1E40AF)),
          '镜头类型' || '镜头子类型' => ('🎬', const Color(0xFF475569)),
          '视角' => ('👁', const Color(0xFF3730A3)),
          '投放信息' || '投放' => ('📋', const Color(0xFF475569)),
          '意图' => ('💡', const Color(0xFF92400E)),
          '转场' => ('✂️', const Color(0xFF0F766E)),
          '篇幅' => ('📏', const Color(0xFF7C3AED)),
          '文笔节奏' => ('✍', const Color(0xFFDB2777)),
          '语感' => ('🎙', const Color(0xFFB45309)),
          '笔墨' => ('🖌', const Color(0xFF0369A1)),
          '功能抽象' || '叙事功能' => ('🧩', const Color(0xFF0F766E)),
          '条目' => ('📖', const Color(0xFF8B6914)),
          '关键词' => ('🔑', const Color(0xFF6B5D54)),
          _ => ('▸', const Color(0xFF475569)),
        };
        widgets.add(
          Container(
            margin: const EdgeInsets.only(top: 2),
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
            decoration: BoxDecoration(
              color: color.withOpacity(0.08),
              borderRadius: BorderRadius.circular(3),
            ),
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: '$icon ${fld.group(1)}：',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: color,
                    ),
                  ),
                  TextSpan(
                    text: value,
                    style: const TextStyle(
                      fontSize: 11,
                      color: V469Style.textSec,
                      height: 1.4,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
        continue;
      }
      // ## 标题行（章节范围参考/创作要求等）
      if (md != null) {
        widgets.add(
          Padding(
            padding: const EdgeInsets.only(top: 6, bottom: 2),
            child: Text(
              t,
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: V469Style.accent,
              ),
            ),
          ),
        );
        continue;
      }
      // 普通行（含⚠️警示行）
      final isWarn =
          t.startsWith('⚠') || t.startsWith('这是该弧线') || t.startsWith('该场景');
      widgets.add(
        Padding(
          padding: const EdgeInsets.only(top: 1.5),
          child: Text(
            t,
            style: TextStyle(
              fontSize: 10.5,
              height: 1.5,
              color: isWarn ? const Color(0xFFB45309) : V469Style.textSec,
              fontWeight: isWarn ? FontWeight.w500 : FontWeight.w400,
            ),
          ),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: widgets,
    );
  }

  /// inline正文浏览卡（v469单页样式）：标题全显+A-/A+/✎编辑/✕关闭+穿插渲染+编辑保存同步txt
  Widget _buildInlineViewer(AppState state, WritingItem w) {
    // v379：历史版本快照=严格只读——禁止编辑/写回世界书（只有当前版可回写）
    final readOnly = identical(w, _viewerOverride);
    final title =
        '弧线${w.arcKey} · 场景${w.sceneIdx + 1}'
        '${w.chapterRange.isNotEmpty ? " · ${w.chapterRange.replaceAll("第", "").replaceAll("章", "")}" : ""}';
    return Container(
      height: MediaQuery.of(context).size.height * 0.78,
      margin: const EdgeInsets.fromLTRB(8, 4, 8, 4),
      decoration: BoxDecoration(
        color: const Color(0xFFFAF7F2),
        border: Border.all(color: V469Style.border),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        children: [
          // 标题行（全显wrap）+工具栏
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 6, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  w.sceneName.isNotEmpty ? w.sceneName : title,
                  style: const TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w700,
                    height: 1.3,
                  ),
                ),
                // 元信息+工具按钮单行（元信息左对齐+按钮紧凑右排，v469阅读器样式）
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${w.chapterRange} · ${w.content.length}字 · v${w.version}'
                        '${w.createdAt != null ? " · ${_fmtDateTime(w.createdAt!)}" : ""}'
                        // v639：查看器同步显示模型@温度
                        '${w.model.isNotEmpty ? " · ${w.model}@${w.temperature}" : ""}'
                        '${w.draft ? " · 草稿" : ""}',
                        style: const TextStyle(
                          fontSize: 10.5,
                          color: V469Style.textMuted,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    TextButton(
                      onPressed: () => setState(
                        () => _viewerFontSize = (_viewerFontSize - 1).clamp(
                          10,
                          28,
                        ),
                      ),
                      style: TextButton.styleFrom(
                        minimumSize: const Size(30, 26),
                        padding: const EdgeInsets.symmetric(horizontal: 5),
                      ),
                      child: const Text('A-', style: TextStyle(fontSize: 12)),
                    ),
                    TextButton(
                      onPressed: () => setState(
                        () => _viewerFontSize = (_viewerFontSize + 1).clamp(
                          10,
                          28,
                        ),
                      ),
                      style: TextButton.styleFrom(
                        minimumSize: const Size(30, 26),
                        padding: const EdgeInsets.symmetric(horizontal: 5),
                      ),
                      child: const Text('A+', style: TextStyle(fontSize: 12)),
                    ),
                    readOnly
                        ? const SizedBox.shrink()
                        : TextButton(
                      onPressed: () {
                        if (_viewerEditing) {
                          // 💾保存：分镜结构变化写回世界书+全文写json+纯正文写txt
                          final oldContent = w.content;
                          w.content = _viewerCtrl.text;
                          final written = _saveFullWriting(
                            state,
                            w,
                            oldContent,
                          );
                          setState(() {
                            _viewerEditing = false;
                            _viewerSavedFlash = true;
                          });
                          Future.delayed(
                            const Duration(milliseconds: 1500),
                            () {
                              if (mounted) {
                                setState(() => _viewerSavedFlash = false);
                              }
                            },
                          );
                          _addLog(
                            '✓ 已保存（分镜${written > 0 ? "结构变化已写回世界书$written条，" : "结构无变化，"}正文已覆盖txt）',
                          );
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(
                                written > 0
                                    ? '已保存（$written条分镜结构写回世界书+正文覆盖txt）'
                                    : '已保存（正文已覆盖txt）',
                              ),
                              duration: const Duration(seconds: 1),
                            ),
                          );
                        } else {
                          _viewerCtrl.text = w.content;
                          setState(() => _viewerEditing = true);
                        }
                      },
                      style: TextButton.styleFrom(
                        minimumSize: const Size(40, 28),
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                      ),
                      child: Text(
                        _viewerSavedFlash
                            ? '✓已保存'
                            : _viewerEditing
                            ? '💾保存'
                            : '✎编辑',
                        style: TextStyle(
                          fontSize: 12.5,
                          color: _viewerSavedFlash
                              ? const Color(0xFF16A34A)
                              : null,
                          fontWeight: _viewerSavedFlash
                              ? FontWeight.w700
                              : null,
                        ),
                      ),
                    ),
                    // v608：复制纯正文（不含备注行/分镜结构行）
                    TextButton(
                      onPressed: () async {
                        final pure = TextCleaner.stripShotHeaders(
                          _viewContent(w, state),
                        ).trim();
                        await Clipboard.setData(ClipboardData(text: pure));
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text('已复制纯正文（${pure.length}字，不含备注/结构行）'),
                              duration: const Duration(seconds: 1),
                            ),
                          );
                        }
                      },
                      style: TextButton.styleFrom(
                        minimumSize: const Size(40, 28),
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                      ),
                      child: const Text(
                        '📋复制',
                        style: TextStyle(fontSize: 12.5),
                      ),
                    ),
                    // v268：补缺失分镜按钮（结构在正文空的分镜逐个
                    // 增量生成——逐镜停机/中止后续写入口）
                    Builder(
                      builder: (ctx) {
                        final ws = _splitShots(w.content);
                        var miss = 0;
                        for (var i = 0; i < ws.length; i++) {
                          final blk = w.content.substring(ws[i].start, ws[i].end);
                          final st = _shotStructLines(blk).trim();
                          if (st.isNotEmpty && blk.trim() == st) miss++;
                        }
                        if (miss == 0 || _viewerEditing || readOnly) {
                          return const SizedBox.shrink();
                        }
                        return TextButton(
                          onPressed: (_shotGenBusy || _isGenerating)
                              ? null
                              : () => _fillMissingShots(state, w),
                          style: TextButton.styleFrom(
                            minimumSize: const Size(40, 28),
                            padding: const EdgeInsets.symmetric(horizontal: 6),
                          ),
                          child: Text(
                            _shotGenBusy ? '⏳补缺失' : '补缺失$miss镜',
                            style: const TextStyle(
                              fontSize: 12,
                              color: Color(0xFFB45309),
                            ),
                          ),
                        );
                      },
                    ),
                    IconButton(
                      icon: const Icon(Icons.close, size: 16),
                      tooltip: '关闭浏览',
                      onPressed: () => setState(() {
                        _viewerKey = null;
                        _viewerEditing = false;
                        _viewerOverride = null;
                      }),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          // 正文：编辑态=TextField；浏览态=穿插渲染滚动
          Expanded(
            child: _viewerEditing
                ? Padding(
                    padding: const EdgeInsets.all(10),
                    child: TextField(
                      controller: _viewerCtrl,
                      maxLines: null,
                      expands: true,
                      textAlign: TextAlign.start,
                      style: TextStyle(
                        fontSize: _viewerFontSize.clamp(10, 16),
                        height: 1.7,
                      ),
                      decoration: const InputDecoration(
                        border: OutlineInputBorder(),
                        filled: true,
                        fillColor: Colors.white,
                      ),
                    ),
                  )
                : Builder(builder: (ctx) {
                    // v601b：残留修复前置——字面\n/伪JSON在数据层解码归位
                    // （此前只在显示层解码，编辑/保存还用原始文本=偏移错位
                    // +编辑框里全是字面\n符号）。修复一次后raw==view全链路一致
                    final fixed = _viewContent(w, state);
                    if (fixed != w.content) {
                      w.content = fixed;
                      state.saveWritings();
                    }
                    return ListView(
                      padding: const EdgeInsets.all(14),
                      children: _buildInterleavedView(
                        w.content,
                        _viewerFontSize,
                        item: w,
                        appState: state,
                      ),
                    );
                  }),
          ),
        ],
      ),
    );
  }

  /// v608：txt备注行（模型·温度·逐镜/整场景·自由/标准·精简/全维）
  /// writingModelNote开关控制；model空=不备注。复制功能不复制此行
  String? _txtNote(AppState state, {String model = '', Object? temp}) {
    if (!state.writingModelNote || model.isEmpty) return null;
    final mode = [
      state.writingShotByShot ? '逐镜' : '整场景',
      state.writingFreeMode ? '自由' : '标准',
      state.writingLeanShots ? '精简' : '全维',
    ].join('·');
    return '[模型：$model · 温度$temp · $mode]';
  }

  /// v597：查看层内容归一化（渲染与分镜编辑定位必须同源）——
  /// 此前编辑按钮用原始item.content定位分镜，字面\n/伪JSON残留时
  /// 正则匹配不到→"实际0镜"误报，而渲染层归一化后显示正常
  String _viewContent(WritingItem? item, AppState? appState) {
    if (item == null) return '';
    final text = item.content;
    final jsonMode =
        appState?.getApiConfig('writing').formatMode == 'json';
    if (jsonMode && TextCleaner.jsonFormatBad(text)) {
      return TextCleaner.salvagePseudoJson(text); // 存量伪JSON剥壳+解码
    } else if (text.contains(r'\n')) {
      // 兼容模式存量字面\n（中转假流式残留）——仅解码不做其它变换
      return text.replaceAll(r'\n', '\n').replaceAll(r'\"', '"');
    }
    return text;
  }

  /// 穿插渲染（从_WritingViewerPage抽出共用：v469 formatWritingContent对齐）
  List<Widget> _buildInterleavedView(
    String text,
    double fontSize, {
    WritingItem? item,
    AppState? appState,
  }) {
    // v267：渲染层归一化降级为显示级修复——v256把全量语义归一化放进
    // 渲染层是分层错误：续行合并会撤销用户编辑加的换行（用户手动拆
    // 粘连行保存→渲染归一化把它合并回去=编辑白做"还是属于分镜内容"，
    // 合并后超长行再触发污染判定→维度行从分镜卡消失="分镜丢失"）。
    // 渲染=忠实显示：只做①存量伪JSON剥壳②字面\n解码（纯格式修复，
    // 零语义变换——续行合并/去重/canonical只在AI输出入库时跑）
    var text2 = text;
    // v275：重复分镜块去重+残渣剥除（存量整场景重复退化输出——显示
    // 层治，重复块丢弃+"}碎片清理）
    text2 = TextCleaner.dedupeShotBlocks(text2);
    // v703：JSON壳维度行修复（存量数据渲染兜底——引号壳行归位维度行）
    text2 = TextCleaner.repairJsonDimLines(text2);
    // v606：inline单行分镜预切行——改编输出把分镜1｜焦点…全并一行时，
    // 渲染按行识别分镜头会整段退化纯文本；在分镜N｜前插换行还原分行
    text2 = text2.replaceAll(
      RegExp('([^\\n])\\s*(分[镜景]\\s*\\d+\\s*｜)'),
      '\$1\n\$2',
    );
    final widgets = <Widget>[];
    var shotCount = 0;
    // 分镜块收集器：分镜头行+维度行收进同一浅蓝容器（等正文段/下一分镜时打包输出+按钮）
    List<Widget>? pendingShotBox;
    int pendingShotIdx = -1;

    // 挂按钮widget（生成分镜正文+编辑，放在分镜信息下面）
    // si=渲染序号（0基，与pendingShotIdx一致）；编辑key与渲染判断key同源（shotCount+1）
    Widget shotButtons(int si) => Row(
      children: [
        TextButton(
          style: TextButton.styleFrom(
            visualDensity: VisualDensity.compact,
            padding: const EdgeInsets.symmetric(horizontal: 6),
            minimumSize: const Size(0, 26),
          ),
          onPressed: (_shotGenBusy || appState == null || item == null)
              ? null
              : () {
                  // v541：失效可见化——busy卡死不再静默
                  if (_shotGenBusy || _isGenerating) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('有分镜正文正在生成，请等完成或终止后再试')),
                    );
                    return;
                  }
                  _genSingleShot(appState, item, si);
                },
          child: Text(
            _shotGenBusy ? '⏳生成中' : '✨生成分镜正文',
            style: const TextStyle(fontSize: 11),
          ),
        ),
        TextButton(
          style: TextButton.styleFrom(
            visualDensity: VisualDensity.compact,
            padding: const EdgeInsets.symmetric(horizontal: 6),
            minimumSize: const Size(0, 26),
          ),
          onPressed: item == null
              ? null
              : () {
                  // 初始化编辑框=该分镜块全文（v601b：残留已在数据层修复，raw==view）
                  final shots = _splitShots(item.content);
                  if (si < shots.length) {
                    final blk = item.content.substring(
                      shots[si].start,
                      shots[si].end,
                    );
                    _shotEditCtrl.text = blk.trimRight();
                    setState(() => _shotEditKey = '${item.key}_${si + 1}');
                  } else {
                    // v541：失效可见化——渲染序号与实际块数不一致要说话
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('定位不到分镜${si + 1}（实际${shots.length}镜）——文档分镜块可能残缺，用上方编辑全文排查')),
                    );
                  }
                },
          child: const Text('✎编辑', style: TextStyle(fontSize: 11)),
        ),
        // v363：分镜切片预览（本镜锚定切片=真实原文段落；旧数据回退场景切片）
        TextButton(
          style: TextButton.styleFrom(
            visualDensity: VisualDensity.compact,
            padding: const EdgeInsets.symmetric(horizontal: 6),
            minimumSize: const Size(0, 26),
          ),
          onPressed: (appState == null || item == null)
              ? null
              : () => _previewShotSlice(
                    context,
                    appState,
                    item.arcKey,
                    item.sceneIdx,
                    si,
                  ),
          child: const Text('切片', style: TextStyle(fontSize: 11)),
        ),
      ],
    );

    for (final raw in text2.split('\n')) {
      final t = raw.trim();
      if (t.isEmpty) {
        widgets.add(const SizedBox(height: 8));
        continue;
      }
      // 章节标题：第X章 → 蓝横幅（左边条）
      if (RegExp(r'^第[一二三四五六七八九十百千零\d]+章(\s|$)').hasMatch(t)) {
        widgets.add(
          Container(
            width: double.infinity,
            margin: const EdgeInsets.only(top: 10, bottom: 6),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: const Color(0xFFEFF6FF),
              borderRadius: BorderRadius.circular(4),
              border: const Border(
                left: BorderSide(color: Color(0xFF1E40AF), width: 4),
              ),
            ),
            child: Text(
              t,
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: Color(0xFF1E3A5F),
              ),
            ),
          ),
        );
        continue;
      }
      // 场景头：场景N：名称（范围）→ 红
      final sc = RegExp(r'^[^\u4e00-\u9fa5\n]*场[景面]\s*(\d+)\s*[：:]\s*(.+)')
          .firstMatch(t);
      if (sc != null) {
        var name = sc.group(2) ?? '';
        var range = '';
        final cm = RegExp(r'[（(]([^）)]+)[）)]\s*$').firstMatch(name);
        if (cm != null) {
          range = cm.group(1) ?? '';
          name = name.replaceAll(RegExp(r'[（(][^）)]+[）)]\s*$'), '');
        }
        widgets.add(
          Padding(
            padding: const EdgeInsets.only(top: 8, bottom: 4),
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: '场景${sc.group(1)}：',
                    style: const TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF7F1D1D),
                    ),
                  ),
                  TextSpan(
                    text: name,
                    style: const TextStyle(
                      fontSize: 13.5,
                      color: Color(0xFF991B1B),
                    ),
                  ),
                  if (range.isNotEmpty)
                    TextSpan(
                      text: ' ($range)',
                      style: const TextStyle(
                        fontSize: 12,
                        color: V469Style.textMuted,
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
        shotCount = 0;
        continue;
      }
      // 分镜头行：分镜N：（v153独立行，sRest空=正常）
      final sh = RegExp(r'^[^\u4e00-\u9fa5\n]*分[镜头]头?\s*(\d+)?\s*[：:]\s*(.*)')
          .firstMatch(t);
      if (sh != null) {
        // 上一镜打包输出（下一分镜紧跟无正文段的情况）
        if (pendingShotBox != null) {
          widgets.add(
            _shotBlockCard([...pendingShotBox!, shotButtons(pendingShotIdx)]),
          );
          pendingShotBox = null;
          pendingShotIdx = -1;
        }
        shotCount++;
        if (shotCount == 1) {
          widgets.add(
            const Padding(
              padding: EdgeInsets.only(top: 6, bottom: 3),
              child: Text(
                '📷 叙事分镜',
                style: TextStyle(fontSize: 11, color: Color(0xFF64748B)),
              ),
            ),
          );
        }
        final rest = sh.group(2) ?? '';
        // v153新格式：分镜N：独立行（rest空）；有内容=AI没按格式，纯文本展示
        final inline = <InlineSpan>[
          TextSpan(
            text: '【分镜${sh.group(1) ?? shotCount}】',
            style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: V469Style.shotBadgeFg,
            ),
          ),
        ];
        if (rest.trim().isNotEmpty) {
          inline.add(
            TextSpan(text: ' $rest', style: const TextStyle(fontSize: 11.5)),
          );
        }
        // 单分镜操作区：编辑态=整块TextField；浏览态=分镜卡+按钮行
        final shotKey = item == null ? '' : '${item.key}_$shotCount';
        final isEditing = shotKey.isNotEmpty && _shotEditKey == shotKey;
        if (isEditing && item != null) {
          widgets.add(
            Container(
              margin: const EdgeInsets.symmetric(vertical: 3),
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: V469Style.accent),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '编辑分镜（首行=分镜头，随后维度行；保存时结构写回世界书）',
                    style: TextStyle(fontSize: 10, color: V469Style.textMuted),
                  ),
                  const SizedBox(height: 4),
                  TextField(
                    controller: _shotEditCtrl,
                    maxLines: null,
                    minLines: 4,
                    style: const TextStyle(fontSize: 12, height: 1.5),
                    decoration: const InputDecoration(
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      TextButton(
                        onPressed: appState == null
                            ? null
                            : () =>
                                  _saveShotEdit(appState, item, shotCount - 1),
                        child: Text(
                          _shotSavedFlash ? '✓已保存' : '💾保存',
                          style: TextStyle(
                            fontSize: 12,
                            color: _shotSavedFlash
                                ? const Color(0xFF16A34A)
                                : null,
                            fontWeight: _shotSavedFlash
                                ? FontWeight.w700
                                : null,
                          ),
                        ),
                      ),
                      TextButton(
                        onPressed: () => setState(() => _shotEditKey = null),
                        child: const Text(
                          '✕取消',
                          style: TextStyle(fontSize: 12),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          );
          continue;
        }
        // flush上一镜（下一分镜紧跟无正文段的情况）
        if (pendingShotBox != null) {
          widgets.add(
            _shotBlockCard([...pendingShotBox!, shotButtons(pendingShotIdx)]),
          );
          pendingShotBox = null;
        }
        // 新收集器：分镜头行开块
        pendingShotBox = [
          Padding(
            padding: const EdgeInsets.only(bottom: 2),
            child: Text.rich(TextSpan(children: inline)),
          ),
        ];
        pendingShotIdx = shotCount - 1;
        continue;
      }
      // 维度行：图标+色+缩进（AI漂移容错v91）
      // v259/v262：污染形态=正文以维度值身份藏身（截图实证'正文被解析
      // 到分镜的功能抽象里面'）——按正文段渲染不进维度卡片。v262阈值
      // 换共享判定dimValuePolluted（>200字或≥3句读），60字误伤语感例句
      // /笔墨配额等真长维度值=用户实测'功能抽象内容反过来混入正文'
      final fld = RegExp(
        r'^[^\u4e00-\u9fa5\n]*(投放信息|投放|作者意图|意图|转场手法|转场|篇幅|文笔节奏|功能抽象|焦点|镜头类型|视角|语感|笔墨|语感锚|笔墨配额|叙事功能|文风)(\s*[(（][A-Za-z /]+[)）])?\s*[：:]\s*(.*)',
      ).firstMatch(t);
      if (fld != null && TextCleaner.dimValuePolluted(fld.group(3) ?? '')) {
        // 污染行：flush维度卡，剥标签的正文按正文段渲染（正文不再被吞）
        if (pendingShotBox != null) {
          widgets.add(
            _shotBlockCard([...pendingShotBox!, shotButtons(pendingShotIdx)]),
          );
          pendingShotBox = null;
        }
        widgets.add(
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
            child: Text(
              (fld.group(3) ?? '').trim(),
              style: TextStyle(
                fontSize: fontSize,
                height: 1.8,
                color: const Color(0xFF2C1810),
                textBaseline: TextBaseline.ideographic,
              ),
              textAlign: TextAlign.justify,
            ),
          ),
        );
        continue;
      }
      if (fld != null) {
        final label = fld.group(1)!;
        final val = fld.group(3) ?? '';
        // 中英标签（对齐世界书维度名规范）
        final enLabel = switch (label) {
          '焦点' => '焦点/Focus',
          '镜头类型' => '镜头类型/Shot Type',
          '视角' => '视角/POV',
          '投放信息' || '投放' => '投放信息/Info',
          '作者意图' || '意图' => '作者意图/Intent',
          '转场手法' || '转场' => '转场手法/Transition',
          '篇幅' => '篇幅/Length',
          '文笔节奏' => '文笔节奏/Prose Style',
          '文风' => '文风/Style', // v680：量化标尺维度行进分镜卡
          '语感' || '语感锚' => '语感/Voice',
          '笔墨' || '笔墨配额' => '笔墨/Ink',
          '功能抽象' || '叙事功能' => '功能抽象/Abstract',
          _ => label,
        };
        final (icon, color) = switch (label) {
          '焦点' => ('🎯', const Color(0xFF1E40AF)),
          '镜头类型' => ('🎬', const Color(0xFF475569)),
          '视角' => ('👁', const Color(0xFF3730A3)),
          '投放信息' || '投放' => ('📋', const Color(0xFF475569)),
          '作者意图' || '意图' => ('💡', const Color(0xFF92400E)),
          '转场手法' || '转场' => ('✂️', const Color(0xFF0F766E)),
          '篇幅' => ('📏', const Color(0xFF7C3AED)),
          '文笔节奏' => ('✍', const Color(0xFFDB2777)),
          '文风' => ('📊', const Color(0xFF6D28D9)), // v680
          '语感' || '语感锚' => ('🎙', const Color(0xFFB45309)),
          '笔墨' || '笔墨配额' => ('🖌', const Color(0xFF0369A1)),
          '功能抽象' => ('🧩', const Color(0xFF0F766E)),
          _ => ('▸', V469Style.textSec),
        };
        (pendingShotBox ??= []).add(
          Padding(
            padding: const EdgeInsets.only(left: 8, top: 1, bottom: 1),
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: '$icon ',
                    style: TextStyle(
                      fontSize: 12,
                      color: color,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  TextSpan(
                    text: '$enLabel：',
                    style: TextStyle(
                      fontSize: 12,
                      color: color,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  TextSpan(
                    text: val,
                    style: const TextStyle(
                      fontSize: 12,
                      color: V469Style.textSec,
                      fontWeight: FontWeight.w400,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
        continue;
      }
      // 默认正文段落：缩进（v469 text-indent:2em）
      // v273：存量外层引号壳渲染时剥（首尾同一对引号才剥，内部对白不动）
      {
        final raw2 = TextCleaner.stripWrapQuotes(raw);
        if (!identical(raw2, raw) && raw2 != raw) {
          widgets.add(
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
              child: Text(
                raw2,
                style: TextStyle(
                  fontSize: fontSize,
                  height: 1.8,
                  color: const Color(0xFF2C1810),
                  textBaseline: TextBaseline.ideographic,
                ),
                textAlign: TextAlign.justify,
              ),
            ),
          );
          continue;
        }
      }
      if (pendingShotBox != null) {
        widgets.add(
          _shotBlockCard([...pendingShotBox!, shotButtons(pendingShotIdx)]),
        );
        pendingShotBox = null;
        pendingShotIdx = -1;
      }
      widgets.add(
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          child: Text(
            raw,
            style: TextStyle(
              fontSize: fontSize,
              height: 1.8,
              color: const Color(0xFF2C1810),
              textBaseline: TextBaseline.ideographic,
            ),
            textAlign: TextAlign.justify,
          ),
        ),
      );
    }
    // 尾部分镜没有后续正文段：打包输出
    if (pendingShotBox != null) {
      widgets.add(
        _shotBlockCard([...pendingShotBox!, shotButtons(pendingShotIdx)]),
      );
      pendingShotBox = null;
    }
    return widgets;
  }

  /// 分镜块卡片：全部信息（分镜头行+维度行）合成一个浅蓝容器（按钮由收集器内联）
  Widget _shotBlockCard(List<Widget> children) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 3),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: const Color(0xFFEFF6FF), // 浅蓝背景整块区分正文
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: V469Style.shotBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: children,
      ),
    );
  }

  void _viewWriting(BuildContext context, WritingItem w) {
    // v469单页样式：创作页内inline展开浏览（不跳页，列表可继续切换）
    final key = '${w.arcKey}_${w.sceneIdx}_${w.version}';
    setState(() {
      // v352：查看器只挂在"已创作"视图——场景视图点查看要切过去，否则按键无响应
      _viewMode = 1;
      _viewerKey = _viewerKey == key ? null : key; // 再点同一篇=收起
      _viewerEditing = false;
      // v377b：历史版本快照不在writings列表里，走只读旁路
      _viewerOverride = state_writings_contains(w) ? null : w;
    });
  }

  bool state_writings_contains(WritingItem w) {
    return (AppState.instance.writings[w.key]?.version ?? -1) == w.version;
  }

  void _editWriting(AppState state, WritingItem w) {
    // 就地编辑：打开inline阅读器并直接进入编辑态（替代弹窗）
    final key = '${w.arcKey}_${w.sceneIdx}_${w.version}';
    setState(() {
      _viewerKey = key;
      _viewerEditing = true;
    });
  }
}

/// 兜底弧线对象（扫描数据被清但世界书/拆解还在时，用编号构造）
class _PseudoArc {
  final int number;
  final String title;
  final String chapterRange;
  const _PseudoArc(this.number, this.title, this.chapterRange);
}

/// v564：创作页自动增高输入框——编辑态撑开显示全部文字(maxLines=null)，
/// 点框外收缩单行；框内拖动不收缩（对齐改编页_CollapseReqField逻辑）
class _AutoExpandField extends StatefulWidget {
  const _AutoExpandField({
    required this.controller,
    this.style,
    this.hintText,
    this.hintStyle,
    this.borderSide,
    this.contentPadding,
    this.onChanged,
  });
  final TextEditingController controller;
  final TextStyle? style;
  final String? hintText;
  final TextStyle? hintStyle;
  final BorderSide? borderSide;
  final EdgeInsetsGeometry? contentPadding;
  final ValueChanged<String>? onChanged;

  @override
  State<_AutoExpandField> createState() => _AutoExpandFieldState();
}

class _AutoExpandFieldState extends State<_AutoExpandField> {
  final _focus = FocusNode();
  bool _expanded = false;

  @override
  void initState() {
    super.initState();
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
    return TextField(
      controller: widget.controller,
      focusNode: _focus,
      style: widget.style,
      maxLines: _expanded ? null : 1,
      minLines: 1,
      keyboardType: TextInputType.multiline,
      onTapOutside: (_) {
        if (mounted) setState(() => _expanded = false); // 点框外才缩回
      },
      decoration: InputDecoration(
        isDense: true,
        hintText: widget.hintText,
        hintStyle: widget.hintStyle,
        border: OutlineInputBorder(borderSide: widget.borderSide ?? const BorderSide()),
        contentPadding: widget.contentPadding ?? const EdgeInsets.all(8),
      ),
      onChanged: widget.onChanged,
    );
  }
}
