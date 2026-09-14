import 'package:flutter/material.dart';

import '../models/arc.dart';
import '../models/scene.dart';
import '../state/app_state.dart';
import '../utils/arc_text.dart';
import '../utils/json_repair.dart';
import '../utils/prompt_builder.dart';
import '../utils/v469_style.dart';
import '../widgets/slice_viewer_sheet.dart';

/// v437：全局场景流服务——扫描/分组/查看器的共享实现，
/// 场景页（扫描+查看）与弧线页（分组）各自调起

  // ===== v431：全书场景流扫描（场景先于弧线）=====

  /// 按窗口扫描全书场景——场景脱离弧线独立划分，句级切片(end_text链式)
  /// 失败停机续跑：globalSceneScannedUpTo锚点，点继续从断点继续
Future<void> runGlobalSceneScan({
  required AppState state,
  required void Function(String msg) log,
  Future<bool> Function(String sys, String user)? previewHook,
}) async {
    final chapters = state.chapters;
    if (chapters.isEmpty) {
      log('⛔ 无章节——先在主页导入书籍');
      return;
    }
    state.setSceneStreamBusy(true);
    // v181同款：清除上次abort残留——否则本次callApi进rpmGuard被秒拒"用户中断"
    state.api.clearAbort();
    state.userAborted = false;
    final bookGuard = state.currentBook;
    // v447：修复——v441的replace目标写错文件静默未生效，步进一直读旧scanStepSize
    final stepSize = state.sceneStepSize > 0 ? state.sceneStepSize : 10;
    final totalChapters = chapters.length;
    var from = state.globalSceneScannedUpTo + 1;
    log(
      from == 1
          ? '开始全书场景扫描：$totalChapters章，窗口$stepSize章'
          : '继续场景扫描：从第$from章起（已完成${state.globalScenes.length}场景）',
    );
    try {
      int chNumOf(int i) =>
          chapters[i].number > 0 ? chapters[i].number : i + 1;
      while (from <= totalChapters) {
        if (state.userAborted) {
          log('已终止场景扫描（已保留${state.globalScenes.length}场景）');
          break;
        }
        // 窗口：章号 from..to（跳号书按章号取）
        final fromIdx = chapters.indexWhere((c) => chNumOf(chapters.indexOf(c)) >= from);
        if (fromIdx < 0) break;
        var toIdx = fromIdx;
        while (toIdx + 1 < chapters.length &&
            chNumOf(toIdx + 1) < from + stepSize) {
          toIdx++;
        }
        final wFrom = chNumOf(fromIdx);
        final wTo = chNumOf(toIdx);

        // 窗口文本
        final buf = StringBuffer();
        for (var i = fromIdx; i <= toIdx; i++) {
          final ch = chapters[i];
          final n = ch.number > 0 ? ch.number : i + 1;
          buf.write('\n\n=== 第$n章 ===\n\n${ch.title}\n\n${ch.content}');
        }

        final systemPrompt = PromptBuilder.buildGlobalSceneSystemPrompt();
        final userPrompt = PromptBuilder.buildGlobalSceneUserPrompt(
          windowText: buf.toString(),
          fromChapter: wFrom,
          toChapter: wTo,
          prevTail: state.globalScenes.isNotEmpty
              ? state.globalScenes.last.endText
              : null,
        );

        // v465：词链预览（仅首批走——后续窗口内容重复预览意义小）
        if (previewHook != null &&
            from == wFrom &&
            state.globalSceneScannedUpTo == 0) {
          final shouldContinue = await previewHook(systemPrompt, userPrompt);
          if (!shouldContinue) {
            log('用户在预览后终止');
            state.setSceneStreamBusy(false);
            return;
          }
        }

        final config = state.getApiConfig('scene');
        final result = await state.api.callApi(
          systemPrompt: systemPrompt,
          userPrompt: userPrompt,
          apiConfig: config,
        );
        if (!result.isSuccess) {
          log(
            '⛔ 场景扫描请求失败：${result.error}——已暂停（已完成${state.globalScenes.length}场景，进度第$wFrom章），稍后点"扫描场景"续跑',
          );
          break;
        }
        final parsed = JsonRepair.parseResponse(result.content);
        final scenesJson =
            parsed?['scenes'] as List? ?? const [];
        if (scenesJson.isEmpty) {
          log(
            '⛔ 场景扫描解析失败（无场景返回）——已暂停，点"扫描场景"重试本窗口',
          );
          break;
        }
        final winScenes = scenesJson
            .map((e) => Scene.fromJson(e as Map<String, dynamic>))
            .toList();

        // end_text 链式切片（v320机制，对窗口文本）——失败补定位2次→⛔停机
        final windowText = buf.toString();
        var matFail = false;
        var searchFrom = 0;
        for (var i = 0; i < winScenes.length; i++) {
          final et = winScenes[i].endText;
          if (i == winScenes.length - 1) {
            // 末场景切片到窗口文末（end_text已作为衔接锚点存着）
            winScenes[i].text = windowText.substring(searchFrom);
            break;
          }
          if (et.isEmpty) {
            matFail = true;
            log('⚠ 场景${i + 1}未返回end_text');
            break;
          }
          int? endPos;
          final idx0 = windowText.indexOf(et, searchFrom);
          if (idx0 >= 0) {
            endPos = idx0 + et.length;
          } else {
            final tail = windowText.substring(searchFrom);
            final fz = ArcText.fuzzyLocate(tail, et);
            if (fz != null) {
              endPos = searchFrom + tail.indexOf(fz) + fz.length;
            }
          }
          if (endPos == null) {
            log(
              '⛔ 场景${i + 1}分界句定位失败——本窗口不落库，点"扫描场景"重试（${et.length > 20 ? "${et.substring(0, 20)}…" : et}）',
            );
            matFail = true;
            break;
          }
          // v455：切分点吸附到句末（对齐老场景页v321——AI引述漏抄尾引号
          // 时！”只到！，引号漏给下一场景）
          endPos = ArcText.snapToSentenceEnd(windowText, endPos);
          winScenes[i].text = windowText.substring(searchFrom, endPos);
          searchFrom = endPos;
        }
        if (matFail) break;

        // 落库：globalIndex连续递增；continuation=true的首场景与全局流
        // 最后场景合并（跨窗口同一场景不拆两条，v437）
        for (final sc in winScenes) {
          final last = state.globalScenes.isNotEmpty
              ? state.globalScenes.last
              : null;
          if (sc.continuation && last != null) {
            last.text = last.text.endsWith(sc.text)
                ? last.text
                : last.text + sc.text;
            if (sc.endChapter > last.endChapter) {
              last.endChapter = sc.endChapter;
              last.chapterRange = '第${last.startChapter}-${sc.endChapter}章';
            }
            last.summary = '${last.summary}；${sc.summary}';
            last.endText = sc.endText;
            log('✂ 跨窗口场景合并：「${sc.name}」并入全局场景${state.globalScenes.length}');
          } else {
            sc.globalIndex = state.globalScenes.length;
            state.globalScenes.add(sc);
          }
        }
        state.globalSceneScannedUpTo = wTo;
        state.saveGlobalScenes();
        log(
          '✓ 第$wFrom-$wTo章：${winScenes.length}场景（累计${state.globalScenes.length}）',
        );
        from = wTo + 1;
      }
      {
        log(
          state.globalSceneScannedUpTo >= totalChapters
              ? '=== 全书场景扫描完成：${state.globalScenes.length}场景 ==='
              : '=== 场景扫描暂停：进度第${state.globalSceneScannedUpTo}章/$totalChapters章 ===',
        );
      }
      state.saveGlobalScenes();
    } catch (err) {
      log('异常：$err');
      if (err is Error) log('   堆栈：${err.stackTrace}');
    } finally {
      state.setSceneStreamBusy(false);
    }
  }

  /// v432：全局场景流查看器——列表行（序号/章范围/名称/字数），点击看切片全文
void showGlobalScenesViewer(BuildContext context, AppState state) {
    final gs = state.globalScenes;
    if (gs.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('场景流为空——先执行"扫描场景"')));
      return;
    }
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.7,
        maxChildSize: 0.95,
        builder: (ctx, ctrl) => Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  Text(
                    '全局场景流（${gs.length}个，进度第${state.globalSceneScannedUpTo}章）',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.bold,
                      fontFamily: V469Style.uiFont,
                    ),
                  ),
                  const Spacer(),
                  TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text('关闭'),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: ListView.builder(
                controller: ctrl,
                itemCount: gs.length,
                itemBuilder: (ctx, i) {
                  final sc = gs[i];
                  return ListTile(
                    dense: true,
                    title: Text(
                      '${i + 1}. [${sc.chapterRange}] ${sc.name}',
                      style: TextStyle(
                        fontSize: 13,
                        fontFamily: V469Style.uiFont,
                      ),
                    ),
                    subtitle: Text(
                      sc.summary,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        color: Colors.grey[600],
                        fontFamily: V469Style.uiFont,
                      ),
                    ),
                    trailing: Text(
                      '${sc.text.length}字',
                      style: TextStyle(
                        fontSize: 11,
                        color: Colors.grey[500],
                        fontFamily: V469Style.uiFont,
                      ),
                    ),
                    onTap: () {
                      showSliceViewerSheet(
                        context,
                        title: '场景${i + 1}：${sc.name}（${sc.chapterRange}）',
                        text: sc.text,
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ===== v431：弧线分组扫描（第二步：读场景序列划弧线）=====

  /// 闭合判定规则（用户裁决）：弧线处理到场景M时，看场景M+1——
  /// 仍是本弧线主角/叙事延续→继续；切到别的角色/线→伪闭合；
  /// 主角不可逆变化→真闭合。判定单位=场景，不再啃原文
Future<void> groupArcsFromScenes({
  required AppState state,
  required void Function(String msg) log,
  bool resume = false, // v439：增量=从globalGroupedUpTo断点继续
  Future<bool> Function(String sys, String user)? previewHook, // v466：词链预览
}) async {
    final gs = state.globalScenes;
    if (gs.isEmpty) {
      log('⛔ 无全局场景——先执行"扫描场景"');
      return;
    }
    state.setSceneStreamBusy(true);
    state.api.clearAbort(); // v432：同上，abort残留清除
    state.userAborted = false;
    log('开始弧线分组：${gs.length}个场景');
    try {
      final batch = state.groupBatchSize > 0 ? state.groupBatchSize : 30;
      final arcs = <Arc>[]; // 组装中的弧线
      final extractedArcs = <int>{}; // v495已提取零件的弧线号
      var cursor = 0; // 已分组到的场景序号
      var arcNum = 0;
      // 未闭合弧线上文（跨批传递）
      Arc? openArc;
      // v496：增量续跑——恢复上次已保存的弧线成果，从断点继续
      if (resume && state.arcScan != null && state.arcScan!.arcs.isNotEmpty) {
        arcs.addAll(state.arcScan!.arcs);
        arcNum = arcs.length;
        cursor = arcs.last.sceneTo.clamp(0, gs.length);
        // v532（用户裁决）：末条未闭合弧线直接抛弃重做——不完整成果不留尾巴，
        // 回退到它的起始场景整条重新分组（丢弃其场景分析与零件）
        Arc? dropped;
        if (arcs.isNotEmpty && arcs.last.status == 'incomplete') {
          dropped = arcs.removeLast();
          arcNum = arcs.length;
          cursor = (dropped.sceneFrom - 1).clamp(0, gs.length);
          state.arcAnalyses.remove(dropped.number.toString());
          extractedArcs.remove(dropped.number);
        }
        state.globalGroupedUpTo = cursor;
        for (final a in arcs) {
          if (state.arcAnalyses[a.number.toString()]?.metadata?['arc_summary_detailed'] != null) {
            extractedArcs.add(a.number);
          }
        }
        if (dropped != null) {
          log('↻ 增量续跑：保留${arcs.length}条完整弧线，抛弃未闭合弧线${dropped.number}「${dropped.title}」（场景${dropped.sceneFrom}-${dropped.sceneTo}），从场景${cursor + 1}重分');
        } else {
          log('↻ 增量续跑：已恢复${arcs.length}条弧线，从场景${cursor + 1}继续');
        }
      }

      while (cursor < gs.length) {
        if (state.userAborted) {
          log('⛔ 用户终止——分组已停止（已完成${arcs.length}条弧线）');
          break;
        }
        final to = (cursor + batch).clamp(0, gs.length);
        final openDesc = openArc == null
            ? '无'
            : '弧线${openArc.number}「${openArc.title}」（视角：${openArc.focusCharacter}，该弧线此前场景已在上批归组、本次列表不含，概述：${openArc.summary}）';
        final sb = StringBuffer();
        for (var i = cursor; i < to; i++) {
          final sc = gs[i];
          final ch = sc.changes.isEmpty ? '' : '｜变化：${sc.changes}';
          sb.writeln(
              '场景${i + 1}（${sc.chapterRange}）[${sc.name}] ${sc.summary}$ch');
        }
        // v489/v490：分组prompt完整版——v489发现v483/484/488强化全改在无人调用的
        // buildScanSystemPrompt；v490按用户提供的旧版弧线扫描prompt全文融合：
        // 闭合判断宁可往后不往前+过早/过晚闭合误判清单+complete前4条检查+自检步骤
        final systemPrompt =
            '你是资深网文编辑。给定网文场景序列（按原文顺序），将其归组为弧线。\n\n'
            '## 弧线定义\n'
            '弧线是网文中一个阶段性的小故事。每条弧线围绕一个核心目标或事件展开。闭合的标志：主角的处境发生了重大的、不可逆的变化，人生进入新阶段，之前的状态结束了。\n'
            '判断核心标准：主角的人生阶段是否发生了确定性的转换？不是看主角"得到了什么"，而是看处境和状态是否确定性地跟之前不一样了。\n\n'
            '**关键区分：变化开始 ≠ 变化确定。**\n'
            '- 主角发现了器灵→只是变化开始，双方还在互相试探→不是闭合点。达成稳固的合作约定→变化确定→才是闭合点\n'
            '- 主角听说了赚钱机会→不是闭合点。真正赚到钱、收入来源稳定→变化确定→才是闭合点\n'
            '- 主角遇到潜在队友→不是闭合点。正式组队一起行动→变化确定→才是闭合点\n\n'
            '**判断方法：**问自己——如果故事在这里停下来，主角的处境是否已经和弧线开始时根本不同了？还在过渡中就不是闭合点。\n\n'
            '**⚠ 闭合判断宁可往后，不要往前——但也不能太往后。**犹豫某处是否闭合=变化还没完全确定，继续往后看。但核心目标已有结果就立即闭合，不要拖——过晚闭合把两个阶段的故事合并成一条，看不出阶段结构。\n\n'
            '**标记complete之前的检查（前3条全"是"才能标complete，第4条防过晚闭合）：**\n'
            '1. 变化已经发生完毕了吗？（已落定，不是"刚开始"）\n'
            '2. 变化是不可逆的吗？（后续不会反转、被打回去）\n'
            '3. 主角的处境和弧线开始时根本不同了吗？（人生阶段变了，不只是"多了一件东西"）\n'
            '4. 但也不要等太久——核心目标已有结果就闭合。如获得金手指并建立稳固合作（目标达成）→闭合，不需要等到用金手指赚到钱——那是下一条弧线的事\n\n'
            '**常见的过早闭合误判（这些都不是闭合点）：**\n'
            '- 刚获得某能力/物品，还没真正用起来、没经过实战验证\n'
            '- 刚到达新环境，还没站稳脚跟\n'
            '- 刚认识重要角色，关系还没明确（敌友未定）\n'
            '- 刚开启新任务，任务还没完成\n'
            '- 变化看起来发生了，紧接着又出现波折或反转\n'
            '- 刚得到机会，还没获得实质性成果\n\n'
            '**常见的过晚闭合误判（这些应该拆成两条弧线，不要合并）：**\n'
            '- 获得金手指并建立稳固合作（闭合），然后开始赚钱→赚钱是下一条弧线\n'
            '- 赚到第一桶金收入稳定（闭合），然后去比武→比武是下一条弧线\n'
            '- 修为突破到新境界（闭合），然后去新环境探索→探索是下一条弧线\n'
            '判断标准：前一段核心目标已有结果，主角开始追求新目标→两条弧线\n\n'
            '**典型的真闭合（变化已确定不可逆）：**\n'
            '- 从"没有金手指"变成"有金手指且已建立稳固关系"\n'
            '- 从"穷困弱小"变成"有稳定收入/修为提升到新层次"\n'
            '- 从"独来独往"变成"有了固定团队"\n'
            '- 从"在一个地方"变成"到了全新环境且不会短期回来"\n'
            '- 完成一个完整的恩怨了结\n'
            '- 修为突破完成（不是正在突破中）\n\n'
            '**不应该作为弧线边界的：**\n'
            '- 变化刚开始还没确定；获得普通法宝/灵石（量变）；赢一场普通战斗；小挫折小损失；完成一件事但只是更大目标的一步；场景转换但目标未变\n\n'
            '**伪闭合（pseudo）=被迫选项，必须同时满足：**①叙事真切走（视角切到其它主要角色，主角线暂时退场）②切换前叙事段有收束。只有"小事件收束但主角还在场"绝不是伪闭合——并入当前弧线。单场景弧线原则上不允许独立成弧线（除非该场景确有跨线事件）。\n\n'
            '## title=可移植的功能名（最高优先级）\n'
            '- title必须是套路名，体现主角从什么状态到了什么状态，改编到另一本书照样能用\n'
            '- 硬性禁令：title禁止出现原著人名/地名/物品名/具体事件名\n'
            '- 反面例子（内容总结，错误）："灵岳城集市风波""韩薇薇的怨念""矿道横财与卖符大计""传送阵甩尾战"\n'
            '- 正面例子（功能名，正确）："金手指觉醒与结盟""第一桶金与修为突破""组队猎妖与反杀暴富""单打独斗改组队打怪"\n'
            '- 打断链：主角弧线被打断title加"（待续）"；接续弧线title="原名·续"（完整闭合用"·终"）\n\n'
            '## summary=落定式概述\n'
            '不是剧情复述——写主角处境变化：这条弧线开始时主角是什么状态、经过哪些关键变化、最终落定在一个明确的不可逆变化上结束（"达成约定"不是"发现机会"）。\n\n'
            '## 规则\n'
            '- 场景必须全部归入弧线，按顺序连续，不得跳过/重叠\n'
            '- **闭合判定看下一场景**：处理到场景M时，场景M+1仍是本弧线主角/叙事延续→继续；切到别的角色/线→本场景收束（伪闭合）；主角发生不可逆变化（真闭合）→也可在此收束\n'
            '- focus=视角主角\n'
            '- 最后一条弧线若叙事未收束（书未读完的中间态），status=incomplete\n\n'
            '只输出纯JSON：{"arcs": [{"title": "...", "summary": "...", "focus": "...", "close_type": "real/pseudo", "status": "complete/incomplete", "scene_from": 起始场景序号, "scene_to": 结束场景序号, "closure_reason": "闭合依据(a)落定在哪个场景(b)为什么不是前一场景(c)提前闭合会怎样"}]}';
        final userPrompt =
            '${openArc == null ? '上文弧线均已闭合，请从本批第一个场景开始新弧线' : '已分组上文的未闭合弧线：$openDesc（延续它时title保持一致，必要时加"·续"）'}\n\n'
            '以下是场景$cursor+1-$to的序列：\n\n$sb\n\n'
            '请将场景${cursor + 1}-$to归组。scene_from/scene_to用全局场景序号（1-based）';
        final config = state.getApiConfig('arc');
        final result = await state.api.callApi(
          systemPrompt: systemPrompt,
          userPrompt: userPrompt,
          apiConfig: config,
        );
        if (!result.isSuccess) {
          log('⛔ 分组请求失败：${result.error}——已暂停，稍后重试');
          break;
        }
        if (state.userAborted) {
          log('⛔ 用户终止——分组已停止');
          break;
        }
        // v493：解析失败真重试（此前话术"重试本批"实际是break，从未重试）
        var parsed = JsonRepair.parseResponse(result.content);
        var arcsJson = parsed?['arcs'] as List?;
        var retryN = 0;
        while ((arcsJson == null || arcsJson.isEmpty) && retryN < 2 && !state.userAborted) {
          retryN++;
          log('⚠ 分组解析失败（无弧线返回，原始返回前200字：${result.content.length > 200 ? result.content.substring(0, 200) : result.content}）');
          log('↻ 重试本批（第$retryN/2次）…');
          final r2 = await state.api.callApi(
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            apiConfig: config,
          );
          if (!r2.isSuccess) {
            log('⛔ 重试请求失败：${r2.error}');
            break;
          }
          parsed = JsonRepair.parseResponse(r2.content);
          arcsJson = parsed?['arcs'] as List?;
        }
        if (arcsJson == null || arcsJson.isEmpty) {
          log('⛔ 分组解析失败（重试${retryN}次仍无弧线返回）——中断，请用"重来"重新分组');
          break;
        }
        // v470：未闭合弧线自动收口——上一批遗留的openArc若本批AI没有延续
        // （直接另起新弧线），自动转为伪闭合complete（否则永久遗incomplete，
        // 弧线5"不完整"实证）
        if (openArc != null && arcsJson.isNotEmpty) {
          final firstTitle =
              ((arcsJson.first as Map<String, dynamic>)['title'] ?? '')
                  .toString();
          if (!firstTitle.contains(openArc.title)) {
            openArc.status = 'complete';
            openArc.closeType = 'pseudo';
            log(
              'ℹ 未闭合弧线${openArc.number}「${openArc.title}」后续已另起新弧线——自动转为伪闭合',
            );
            openArc = null;
          }
        }
        // v491：覆盖完整性——AI返回的scene范围若有缺口（跳场景/没覆盖批尾），
        // 缺口场景并入相邻弧线，绝不丢弃（用户截图实证丢章）
        var prevTo = cursor; // 上一条弧线结束场景(0-based exclusive)
        for (final aj in arcsJson) {
          final m = aj as Map<String, dynamic>;
          final sf = ((m['scene_from'] as num?)?.toInt() ?? cursor + 1) - 1;
          final st2 = ((m['scene_to'] as num?)?.toInt() ?? sf) - 1;
          var from2 = sf.clamp(cursor, gs.length - 1);
          final to2 = st2.clamp(from2, gs.length - 1);
          if (from2 > prevTo) {
            log('⛔ AI归组跳过场景${prevTo + 1}-${from2}（弧线「${m['title']}」从场景${from2 + 1}开始）——中断退出，请用"重来"重新分组');
            state.setSceneStreamBusy(false);
            return;
          }
          final seg = gs.sublist(from2, to2 + 1);
          if (seg.isEmpty) continue;
          prevTo = to2 + 1;
          final isContinuation = openArc != null &&
              (m['title']?.toString() ?? '').contains(openArc.title);
          arcNum = isContinuation ? openArc!.number : arcNum + 1;
          // v492b：前段场景分析层——必须在分支处理前抓取（处理后openArc可能被置null）
          final prevAnalysis = isContinuation
              ? state.arcAnalyses[openArc!.number.toString()]
              : null;
          final sCh = seg.first.startChapter;
          final eCh = seg.last.endChapter;
          final arc = Arc(
            number: arcNum,
            title: m['title']?.toString() ?? '弧线$arcNum',
            chapterRange: '第$sCh-$eCh章',
            startChapter: sCh,
            endChapter: eCh,
            sceneFrom: from2 + 1,
            sceneTo: to2 + 1,
            status: m['status']?.toString() ?? 'complete',
            summary: m['summary']?.toString() ?? '',
            focusCharacter: m['focus']?.toString() ?? '',
            closeType: m['close_type']?.toString() ?? 'pseudo',
            boundaryAnchor: '',
            boundaryOffset: -1,
            text: seg.map((s2) => s2.text).where((t) => t.isNotEmpty).join('\n\n'),
          );
          // 未闭合弧线闭合了→替换原弧线（范围延伸）；否则追加
          if (isContinuation) {
            final oi = arcs.indexOf(openArc!);
            final merged = Arc(
              number: openArc.number,
              title: arc.title,
              chapterRange: arc.chapterRange,
              startChapter: openArc.startChapter,
              endChapter: arc.endChapter,
              status: arc.status,
              summary: openArc.summary.isEmpty ? arc.summary : openArc.summary,
              focusCharacter: openArc.focusCharacter,
              closeType: arc.closeType,
              boundaryAnchor: '',
              boundaryOffset: -1,
              text: '${openArc.text}\n\n${arc.text}',
            );
            merged.sceneFrom = openArc.sceneFrom >= 0 ? openArc.sceneFrom : from2 + 1;
            merged.sceneTo = to2 + 1;
            arcs[oi] = merged;
            openArc = arc.status == 'incomplete' ? merged : null;
          } else {
            arcs.add(arc);
            openArc = arc.status == 'incomplete' ? arc : null;
          }
          // 场景装回arcAnalyses（下游分镜/创作零改动）
          // v495：续弧线/重批不重建analysis——保留已提取的零件metadata
          final existedAnalysis = state.arcAnalyses[arcNum.toString()];
          final analysis = existedAnalysis ??
              ArcAnalysis(
                arcNumber: arc.number,
                arcTitle: arc.title,
              );
          analysis.arcTitle = arc.title;
          analysis.arcSummary = arc.summary;
          analysis.scenes = [...?prevAnalysis?.scenes, ...seg];
          state.arcAnalyses[arc.number.toString()] = analysis;
        }
        // v491批尾检查：AI最后一条弧线没覆盖到批尾→中断告警（不静默兜底）
        if (prevTo < to) {
          log('⛔ AI归组未覆盖批尾场景${prevTo + 1}-$to——中断退出，请用"重来"重新分组');
          state.setSceneStreamBusy(false);
          return;
        }
        // v495滚动分步提取（用户裁决：生成弧线1全部内容再生成弧线2）——
        // 本批新闭合的弧线立即提取零件，不用等全部组完
        for (final a in arcs) {
          if (a.status == 'complete' && !extractedArcs.contains(a.number)) {
            await extractArcParts(state: state, arc: a, log: log);
            extractedArcs.add(a.number);
            // v496：一条弧线内容完整即保存（前面成果永不丢）
            if (state.arcScan == null || state.arcScan!.arcs.length < arcs.length) {
              state.arcScan = ArcScan(
                arcs: List.of(arcs),
                scannedChapterCount: (gs.last.endChapter as num).toInt(),
                overallSummary: '',
              );
            } else {
              state.arcScan!.arcs = List.of(arcs);
            }
            state.saveArcScan();
            state.saveArcAnalyses();
            log('💾 弧线${a.number}成果已保存（${arcs.length}条弧线落盘）');
          }
        }
        cursor = to;
        state.globalGroupedUpTo = cursor;
        state.saveGlobalScenes();
        log('分组进度：$cursor/${gs.length}场景，共${arcs.length}弧线');
      }
      if (arcs.isNotEmpty) {
        // v492最终对账（用户裁决：章节序号不连贯=中断告警）——保存前校验场景+章并集覆盖
        final auditFail = auditArcCoverage(
          arcs,
          gs.length,
          (gs.last.endChapter as num).toInt(),
        );
        if (auditFail != null) {
          log('⛔ 弧线覆盖对账失败：$auditFail');
          // v496：保存已覆盖的部分成果，断点回退到缺口前（增量续跑补分组）
          if (arcs.isNotEmpty) {
            final rollback = arcs.last.sceneTo.clamp(0, gs.length);
            state.arcScan = ArcScan(
              arcs: List.of(arcs),
              scannedChapterCount: (gs.last.endChapter as num).toInt(),
              overallSummary: '',
            );
            state.saveArcScan();
            state.saveArcAnalyses();
            state.globalGroupedUpTo = rollback;
            state.saveGlobalScenes();
            log('💾 已保存${arcs.length}条弧线成果，断点回退到场景${rollback + 1}——点"批量"增量续跑');
          }
          log('⛔ 已中断——请用"重来"或"批量"继续');
          return;
        }
        log('✓ 覆盖对账通过：${gs.length}场景全覆盖，章节连贯');
        state.arcScan = ArcScan(
          arcs: arcs,
          scannedChapterCount: (gs.last.endChapter as num).toInt(),
          overallSummary: '',
        );
        state.saveArcScan();
        state.saveArcAnalyses();
        log(
          '=== 弧线分组完成：${arcs.length}条弧线，覆盖${gs.length}场景 ===',
        );
        // v495：兜底提取（滚动提取漏掉的——如最后批才闭合的续弧线）
        var done = 0;
        for (final a in arcs) {
          if (extractedArcs.contains(a.number)) continue;
          if (state.userAborted) {
            log('⛔ 用户终止——零件提取已停止');
            break;
          }
          await extractArcParts(state: state, arc: a, log: log);
          done++;
          log('零件提取进度：$done/${arcs.length}');
        }
        log('=== 弧线零件提取完成 ===');
      }
    } catch (err) {
      log('异常：$err');
      if (err is Error) log('   堆栈：${err.stackTrace}');
    } finally {
      state.setSceneStreamBusy(false);
    }
  }



/// v474：逐弧线零件提取——分组定边界后，啃该弧线原文切片（场景切片拼接）
/// 提取全套弧线零件写arcAnalyses（对齐旧版"划分即提取"信息量）
Future<void> extractArcParts({
  required AppState state,
  required Arc arc,
  required void Function(String msg) log,
}) async {
  if (arc.text.isEmpty) {
    log('⚠ 弧线${arc.number}无正文切片，跳过零件提取');
    return;
  }
  final systemPrompt = PromptBuilder.buildArcPartsSystemPrompt();
  final userPrompt = PromptBuilder.buildArcPartsUserPrompt(
    arcTitle: arc.title,
    arcSummary: arc.summary,
    arcText: arc.text,
  );
  final config = state.getApiConfig('arc');
  final result = await state.api.callApi(
    systemPrompt: systemPrompt,
    userPrompt: userPrompt,
    apiConfig: config,
  );
  if (!result.isSuccess) {
    log('⚠ 弧线${arc.number}零件提取请求失败：${result.error}——跳过');
    return;
  }
  final parts = JsonRepair.parseResponse(result.content);
  if (parts == null) {
    log('⚠ 弧线${arc.number}零件解析失败——跳过');
    return;
  }
  // v486b用户裁决：概述两次生成各归其位——第一次（分组时基于场景摘要）放弧线页，
  // 第二次（零件提取时基于原文切片，更细）只进分析层放分镜页展示，不写回覆盖弧线页
  // v488：详细概述存metadata['arc_summary_detailed']独立字段（场景页拆解链与零件提取链
  // 共用analysis.arcSummary互相覆盖导致两页概述一模一样——独立字段隔离）
  // ❌旧逻辑（v487，与场景页链打架已废弃）：
  // if (newSummary.isNotEmpty) analysis.arcSummary = newSummary;
  // analysis.arcSummary = arc.summary;
  final newSummary = parts['arc_summary']?.toString() ?? '';
  if (newSummary.isNotEmpty) {
    log('✓ 弧线${arc.number}详细概述已生成（分镜页展示，弧线页保留分组概述）');
  } else {
    log('⚠ 弧线${arc.number}：AI未输出arc_summary键，分镜页详细概述缺位');
  }
  final key = arc.number.toString();
  final old = state.arcAnalyses[key];
  final analysis = old ?? ArcAnalysis(arcNumber: arc.number, arcTitle: arc.title);
  analysis.metadata = {
    ...?analysis.metadata,
    'arc_summary_detailed': newSummary,
    'characters': parts['characters'],
    'conflicts': parts['conflicts'],
    'foreshadowing': parts['foreshadowing'],
    'arc_functions': parts['arc_functions'],
    'irreversible_changes': parts['irreversible_changes'],
    'emotional_curve': parts['emotional_curve'],
    'author_fantasy': parts['author_fantasy'],
    'ink_hobby': parts['ink_hobby'],
    'worldbuilding_facts': parts['worldbuilding_facts'],
  };
  state.arcAnalyses[key] = analysis;
  state.saveArcAnalyses();
  // v481：概述同步到弧线页（arcScan.arcs的summary）
  if (newSummary.isNotEmpty && state.syncArcSummariesFromAnalyses() > 0) {
    state.saveArcScan();
  }
  log('✓ 弧线${arc.number}零件已提取（人设/冲突/伏笔/脑洞/笔墨癖好/facts）');
  // v496：实时刷新分镜页/弧线页（结果落盘后立即notify，用户边跑边看）
  state.notifyListeners();
}

/// v492弧线覆盖对账：返回null=通过；否则返回失败原因（场景洞/章洞清单）
String? auditArcCoverage(List<Arc> arcs, int totalScenes, int lastChapter) {
  final coveredScenes = <int>{};
  final coveredChapters = <int>{};
  for (final a in arcs) {
    if (a.sceneFrom >= 1 && a.sceneTo >= a.sceneFrom) {
      for (var sc = a.sceneFrom; sc <= a.sceneTo; sc++) {
        coveredScenes.add(sc);
      }
    }
    if (a.startChapter >= 1 && a.endChapter >= a.startChapter) {
      for (var ch = a.startChapter; ch <= a.endChapter; ch++) {
        coveredChapters.add(ch);
      }
    }
  }
  final missingScenes = [
    for (var sc = 1; sc <= totalScenes; sc++)
      if (!coveredScenes.contains(sc)) sc,
  ];
  if (missingScenes.isNotEmpty) {
    return '场景流共$totalScenes个场景，弧线未覆盖${missingScenes.length}个：'
        '${missingScenes.take(20).join(",")}${missingScenes.length > 20 ? "..." : ""}';
  }
  final missingChapters = [
    for (var ch = 1; ch <= lastChapter; ch++)
      if (!coveredChapters.contains(ch)) ch,
  ];
  if (missingChapters.isNotEmpty) {
    return '第1-$lastChapter章中有${missingChapters.length}章未被任何弧线覆盖：'
        '${missingChapters.take(20).join(",")}${missingChapters.length > 20 ? "..." : ""}';
  }
  return null;
}
