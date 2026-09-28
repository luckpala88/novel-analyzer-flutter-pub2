import 'dart:convert';
import '../models/scene.dart';
import '../state/app_state.dart';

/// v840：聊天agent工具层——AI按约定JSON输出指令，本文件解析执行
/// 读类工具静默执行；写类工具（切书/启动批量任务）由调用方弹确认后执行

class AgentToolResult {
  final String tool;
  final bool ok;
  final String message; // 回喂AI的结果文本
  AgentToolResult(this.tool, this.ok, this.message);
}

/// 工具清单说明（注入聊天system）
const String agentToolDoc = '''
【你可以使用APP工具】需要执行操作时，单独输出一行JSON指令（不要同时输出其他正文）：
{"tool":"工具名","args":{参数}}
可用工具：
1. {"tool":"get_books"} —— 列出全部书目
2. {"tool":"switch_book","args":{"name":"书名"}} —— 切换当前书目（需用户确认）
3. {"tool":"get_progress"} —— 当前书进度（章数/场景数/弧线数/已拆分镜场景数/分组断点）
4. {"tool":"get_arcs"} —— 弧线列表（编号/标题/闭合状态/场景范围）
5. {"tool":"query_worldbook","args":{"keyword":"关键词"}} —— 世界书条目检索（返回命中条目名与摘要）
6. {"tool":"start_batch_shots"} —— 启动批量拆分镜（全部已划分未拆场景；需用户确认；长任务，去分镜页盯终端进度）
7. {"tool":"write_scene","args":{"arc":1,"scene":1}} —— 创作指定弧线第N个场景的续写正文（需用户确认；前提：世界书已有该场景条目；长任务，正文写到创作页）
8. {"tool":"verify_data","args":{"target":"choreo","arc":210}} —— 数据诊断（只读）：target=choreo查编排字段落库情况（弧线总纲+逐场景统计，可带arc过滤单条弧线）；target=trick查手法维度（已拆分镜中trick非空的镜数统计，可带arc过滤）——用于验证新版本功能是否落库。注意：choreo/trick分别是"生成弧线(分组)"和"拆分镜"步骤的产物，重扫场景不会产生它们；choreo缺失应重新分组，trick缺失应重拆分镜
规则：一次只发一个指令，发出后停止等待结果；任务完成后用自然语言汇报结果；用户闲聊/问功能时不要发指令。
''';

/// 解析AI回复中的工具指令（返回null=非指令）
({String tool, Map<String, dynamic> args})? parseToolCall(String text) {
  final m = RegExp(r'\{"tool"\s*:\s*"([a-z_]+)"[^{}]*(?:\{[^{}]*\}[^{}]*)*\}')
      .firstMatch(text.trim());
  if (m == null) return null;
  try {
    final obj = const JsonDecoder().convert(m.group(0)!)
        as Map<String, dynamic>;
    if (obj['tool'] is! String) return null;
    return (
      tool: obj['tool'] as String,
      args: (obj['args'] as Map<String, dynamic>?) ?? {},
    );
  } catch (_) {
    return null;
  }
}

/// 是否写类工具（需确认）
const List<String> writeTools = ['switch_book', 'start_batch_shots'];

/// 执行工具（已过确认环节）
Future<AgentToolResult> runTool(AppState state, String tool,
    Map<String, dynamic> args) async {
  switch (tool) {
    case 'get_books':
      final names = state.bookList;
      return AgentToolResult(tool, true,
          '共${names.length}本书：${names.join('、')}。当前：${state.currentBook}');
    case 'switch_book':
      final name = (args['name'] ?? '').toString();
      if (name.isEmpty) return AgentToolResult(tool, false, '缺少name参数');
      if (name == state.currentBook) {
        return AgentToolResult(tool, true, '当前已是《$name》，无需切换');
      }
      final ok = await state.selectBook(name);
      return AgentToolResult(
          tool,
          ok,
          ok
              ? '已切换到《$name》（共${state.chapters.length}章）'
              : '切换失败：书目列表中找不到《$name》（可先get_books核对名称）');
    case 'get_progress':
      final arcs = state.allArcs;
      final analyzed = state.arcAnalyses.values
          .where((a) => a.scenes.any((sc) => sc.shots.isNotEmpty))
          .length;
      return AgentToolResult(
          tool,
          true,
          '《${state.currentBook}》：${state.chapters.length}章，'
          '${state.globalScenes.length}个场景，${arcs.length}条弧线，'
          '已拆分镜弧线$analyzed条，分组断点场景${state.globalGroupedUpTo}');
    case 'get_arcs':
      final arcs = state.allArcs;
      if (arcs.isEmpty) {
        return AgentToolResult(tool, true, '当前书尚无弧线（先在弧线页批量分组）');
      }
      final lines = <String>[];
      for (final a in arcs.take(60)) {
        lines.add(
            '弧线${a.number}「${a.title}」场景${a.sceneFrom}-${a.sceneTo} ${a.status}');
      }
      return AgentToolResult(tool, true, lines.join('\n'));
    case 'query_worldbook':
      var kw = (args['keyword'] ?? '').toString();
      // v868：符号清洗——去残留引号、全角数字转半角（AI输出符号污染导致检索不中）
      kw = kw.replaceAll('"', '').replaceAll('“', '').replaceAll('”', '').trim();
      kw = kw.replaceAllMapped(RegExp(r'[０-９]'),
          (m) => String.fromCharCode(m[0]!.runes.first - 0xFEE0));
      if (kw.isEmpty) return AgentToolResult(tool, false, '缺少keyword参数');
      final wb = state.worldBook;
      if (wb == null || wb.entries.isEmpty) {
        return AgentToolResult(tool, true, '当前书世界书为空');
      }
      final hits = <String>[];
      wb.entries.forEach((uid, e) {
        final hay = '${e.key} ${e.comment} ${e.content}';
        if (kw.isEmpty || hay.contains(kw)) {
          // v868：附带条目内场景清单行——此前brief只取前120字=只有概述，
          // 场景清单在条目后半段，agent"查不到已有场景"的根因
          final sceneLines = RegExp(r'^场景\d+.*$', multiLine: true)
              .allMatches(e.content)
              .map((m2) => m2.group(0)!)
              .take(30)
              .join('\n');
          final brief = e.content.length > 150
              ? e.content.substring(0, 150)
              : e.content;
          hits.add('【${e.key}】${e.comment}\n$brief…'
              '${sceneLines.isNotEmpty ? '\n已有场景：\n$sceneLines' : '\n（条目内暂无场景清单）'}');
        }
      });
      if (hits.isEmpty) {
        return AgentToolResult(tool, true, '世界书无「$kw」命中条目');
      }
      return AgentToolResult(tool, true,
          '命中${hits.length}条（取前10）：\n${hits.take(10).join('\n\n')}');
    case 'verify_data':
      // v883b：数据诊断（只读）——验证类测试交给agent：字段是否落库一查便知
      final target = (args['target'] ?? '').toString();
      final arcFilter = (args['arc'] as num?)?.toInt();
      if (target == 'choreo') {
        final lines = <String>[];
        var withChoreo = 0, totalScenes = 0;
        for (final a in state.allArcs) {
          if (arcFilter != null && a.number != arcFilter) continue;
          lines.add(
              '弧线${a.number}「${a.title}」总纲: ${a.arcChoreo.isEmpty ? "（空）" : a.arcChoreo}');
          final an = state.arcAnalyses[a.number.toString()];
          final scenes = an?.scenes ?? const [];
          for (final sc in scenes) {
            totalScenes++;
            if (sc.choreo.isNotEmpty) withChoreo++;
          }
          lines.add('  场景编排: ${scenes.where((s2) => s2.choreo.isNotEmpty).length}/${scenes.length}个场景有');
        }
        if (lines.isEmpty) {
          return AgentToolResult(tool, true,
              '未找到弧线${arcFilter ?? ""}（get_arcs核对编号）');
        }
        return AgentToolResult(tool, true,
            '编排落库诊断：$totalScenes个场景中$withChoreo个有choreo\n${lines.join('\n')}');
      }
      if (target == 'trick') {
        var withTrick = 0, totalShots = 0;
        final perArc = <String>[];
        for (final a in state.allArcs) {
          if (arcFilter != null && a.number != arcFilter) continue;
          final an = state.arcAnalyses[a.number.toString()];
          var t = 0, tot = 0;
          for (final sc in an?.scenes ?? <Scene>[]) {
            for (final sh in sc.shots) {
              tot++;
              if (sh.trick.isNotEmpty) t++;
            }
          }
          totalShots += tot;
          withTrick += t;
          if (tot > 0) perArc.add('弧线${a.number}: $t/$tot镜有trick');
        }
        return AgentToolResult(tool, true,
            'trick落库诊断：$totalShots镜中$withTrick镜有\n${perArc.join('\n')}');
      }
      return AgentToolResult(
          tool, false, '未知target：$target（可选choreo/trick）');
    case 'write_scene':
      final arc = (args['arc'] as num?)?.toInt() ?? 0;
      final sc = ((args['scene'] as num?)?.toInt() ?? 1) - 1; // UI场景号1基→0基
      if (state.continueWriteStarter == null) {
        return AgentToolResult(
            tool, false, '创作页尚未打开过——请用户先切到创作页一次，再重试');
      }
      final ok = await state.continueWriteStarter!('$arc', sc);
      return AgentToolResult(tool, ok,
          ok ? '弧线$arc场景${sc + 1}续写正文已完成（结果在创作页）' : '创作失败（场景不存在或生成报错，详情见终端）');
    case 'start_batch_shots':
      if (state.batchShotStarter == null) {
        return AgentToolResult(tool, false,
            '分镜页尚未打开过——请用户先切到分镜页一次，再重试');
      }
      await state.batchShotStarter!();
      return AgentToolResult(tool, true, '批量拆分镜已执行完毕（结果见分镜页/终端）');
    default:
      return AgentToolResult(tool, false, '未知工具：$tool');
  }
}
