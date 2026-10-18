import 'dart:convert';

import 'package:flutter/material.dart';

import '../models/arc.dart';
import '../models/scene.dart';
import '../state/app_state.dart';
import '../services/api_service.dart';
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
/// v534b：按保留末场景的物化切片精确计算字符级续切锚点（章索引+章内偏移）。
/// 原理：切片文本若跨章，最后一个'=== 第N章 ==='标记之后就是endChapter的
/// 章内已消费内容；其在章节对象内的起点用切片末尾120字长尾定位——长尾远比
/// 20-40字end_text抗"两更重头/相似句"干扰。末场景恰收在章尾→返回false
/// （无锚点，自然从下一章续扫）。剪断后必须调用并saveGlobalScenes持久化。
/// v646：接力前置闭合验证——保留末场景若未自然闭合（中断/剪断硬切），
/// 自动回退丢弃（其正文随重扫窗口重新划分，原文不丢、边界重画），最多回退
/// 3个防连环伪闭合。返回实际生效的保留场景数（判定调用失败=按闭合不回退）
/// v819：单场景概述重生成——完整切片重喂AI，重出summary+changes（v812标准）。
/// 边界/弧线/分组全不动；给"边界切得对但概述漏关键信息"的轻量修复路径。
Future<void> regenSceneSummary({
  required AppState state,
  required int index, // 0-based
  required void Function(String msg) log,
}) async {
  if (index < 0 || index >= state.globalScenes.length) {
    log('⛔ 场景序号越界');
    return;
  }
  final sc = state.globalScenes[index];
  if (sc.text.trim().isEmpty) {
    log('⛔ 场景${index + 1}无切片正文——无法重概述');
    return;
  }
  final prev = index > 0 ? state.globalScenes[index - 1] : null;
  final sys = '你是网文场景概述重写员。基于场景完整切片重写概述，供后续弧线分组判定与续写前情使用。\n'
      '只输出纯JSON：{"summary": "新概述", "changes": "关键变化/得失"}\n'
      'summary要求（80-150字，信息必须显形）：\n'
      '- 开头标明视角人物（如"魏索视角："）\n'
      '- 登场关键角色\n'
      '- 交代起因、经过的关键情节节点（关键对话承诺/交易/冲突/转折）、结果或未竟之处\n'
      '- 让只读概述的AI也能知道"这个场景里谁对谁做了什么承诺/交易/敌对动作"\n'
      'changes要求：本场景中角色的关键得失/变化，10-30字具体化（如"获得火凤肚兜""与姬雅达成合作"）。无实质变化填""';
  final user = '【场景名】${sc.name}\n'
      '【章节范围】${sc.chapterRange}\n'
      '${prev == null ? '' : '【前一场景概述（衔接上下文）】\n${prev.summary}\n\n'}'
      '【本场景完整切片】\n${sc.text}';
  state.api.clearAbort();
  final config = state.getApiConfig('scene');
  final result = await state.api.callApi(
    task: '场景重概述',  // v824任务级反馈
    systemPrompt: sys,
    userPrompt: user,
    apiConfig: config,
  );
  if (!result.isSuccess) {
    log('⛔ 场景${index + 1}重概述失败：${result.error}');
    return;
  }
  final json = JsonRepair.parseResponse(result.content);
  final newSummary = json?['summary']?.toString().trim() ?? '';
  final newChanges = json?['changes']?.toString().trim() ?? '';
  if (newSummary.isEmpty) {
    log('⚠️ 场景${index + 1}重概述解析为空——保持原概述');
    return;
  }
  // v915：字段赋值替代对象重建（v893教训：重建新实例=其它容器引用脱钩
  // +此处原重建漏choreo字段会把已分析的编排策略清空）
  sc.summary = newSummary;
  if (newChanges.isNotEmpty) sc.changes = newChanges;
  // v915：双容器同步——analysis.scenes（弧线页/分镜页数据源）重载后是
  // 独立实例，按globalIndex同步概述/变化
  state.arcAnalyses.forEach((_, an) {
    for (final asc in an.scenes) {
      if (asc.globalIndex == sc.globalIndex) {
        asc.summary = newSummary;
        if (newChanges.isNotEmpty) asc.changes = newChanges;
      }
    }
  });
  state.saveGlobalScenes();
  state.saveArcAnalyses();
  log('✓ 场景${index + 1}概述已重生成（${newSummary.length}字，changes：${newChanges.isEmpty ? "无变化" : newChanges}）——边界/弧线/分组未动');
}

Future<int> verifyLastSceneClosure(
  AppState state, {
  required void Function(String msg) log,
}) async {
  var count = state.globalScenes.length;
  for (var attempt = 0; attempt < 3 && count > 0; attempt++) {
    final last = state.globalScenes[count - 1];
    final sample = <String>[
      if (last.endText.isNotEmpty) '结尾锚点句：「${last.endText}」',
      if (last.text.length > 200)
        '切片末尾300字：…${last.text.substring(last.text.length - 300)}'
      else if (last.text.isNotEmpty)
        '切片全文：${last.text}',
    ].join('\n');
    if (sample.isEmpty) return count; // 无文本可判（旧数据）——按闭合处理
    final sys = '你是网文场景边界审计员。判断一个场景的结尾是否为自然闭合：'
        '自然闭合=事件收束/场景切换明确/时间地点跳转清晰（读者不觉得故事讲到一半被掐断）；'
        '未闭合=动作进行到一半、对话中断、冲突悬在半空、叙事被硬切。\n'
        '只输出JSON：{"closed": true或false, "reason": "一句话"}';
    final user = '以下是一个场景的结尾内容，判断它是否自然闭合：\n\n$sample';
    state.api.clearAbort();
    final config = state.getApiConfig('scene');
    final result = await state.api.callApi(
      task: '末场景闭合校验',  // v824任务级反馈
      systemPrompt: sys,
      userPrompt: user,
      apiConfig: config,
    );
    if (!result.isSuccess) {
      log('⚠ 闭合判定调用失败——按闭合处理不回退');
      return count;
    }
    var closed = true;
    var reason = '';
    final json = JsonRepair.parseResponse(result.content) ?? {};
    closed = json['closed']?.toString() == 'true';
    reason = json['reason']?.toString() ?? '';
    if (closed) {
      if (attempt > 0) {
        log('✅ 回退后场景$count结尾已闭合——接力锚点就绪');
      }
      return count;
    }
    log('⚠ 场景$count未闭合（${reason.isEmpty ? "硬切痕迹" : reason}）——回退，正文随重扫窗口重切');
    state.globalScenes.removeLast();
    count--;
  }
  log('⚠ 连续3个场景均未闭合——按最老锚点接力（重扫窗口覆盖重切）');
  return count;
}

bool computeSceneResumeAnchor(AppState state) {
  state.sceneResumeChapIdx = -1;
  state.sceneResumeOffset = 0;
  if (state.globalScenes.isEmpty) return false;
  final kept = state.globalScenes.last;
  final st = kept.text;
  if (st.isEmpty) return false;
  final chapters = state.chapters;
  if (chapters.isEmpty) return false;
  int chNumOf(int i) =>
      chapters[i].number > 0 ? chapters[i].number : i + 1;
  var chapIdx = -1;
  var contentPortion = st;
  final mi = st.lastIndexOf('=== ');
  if (mi >= 0) {
    final titleStart = st.indexOf('\n\n', mi);
    final titleEnd = st.indexOf('\n\n', titleStart + 2);
    if (titleStart < 0 || titleEnd < 0) return false;
    final title = st.substring(titleStart + 2, titleEnd);
    // 标题匹配章对象（区分"第80章"两更的重复章号）
    chapIdx = chapters.indexWhere((c) => c.title == title);
    contentPortion = st.substring(titleEnd + 2);
  }
  final tailLen = contentPortion.length < 120 ? contentPortion.length : 120;
  final tail = contentPortion.substring(contentPortion.length - tailLen);
  // v535b：切片已纯正文（无窗口标记）。无标记时场景整段在同一章内——
  // 但重复章号（两更）有多个候选章，逐一用120字长尾定位，命中的才对
  if (chapIdx >= 0) {
    final c = chapters[chapIdx].content;
    var p = c.indexOf(tail);
    if (p < 0) {
      final fz = ArcText.fuzzyLocate(c, tail);
      if (fz != null) p = c.indexOf(fz);
    }
    if (p < 0) chapIdx = -1; // 标题匹配的章里找不到长尾→换候选
  }
  if (chapIdx < 0) {
    for (var i = 0; i < chapters.length; i++) {
      if (chNumOf(i) != kept.endChapter) continue;
      final c = chapters[i].content;
      var p = c.indexOf(tail);
      if (p < 0) {
        final fz = ArcText.fuzzyLocate(c, tail);
        if (fz != null) p = c.indexOf(fz);
      }
      if (p >= 0) {
        chapIdx = i;
        break;
      }
    }
  }
  if (chapIdx < 0) return false;
  final c = chapters[chapIdx].content;
  var p = c.indexOf(tail);
  if (p < 0) {
    final fz = ArcText.fuzzyLocate(c, tail);
    if (fz != null) p = c.indexOf(fz);
  }
  if (p < 0) return false;
  final off = p + tail.length;
  if (off >= c.length) return false; // 末场景收在章尾→自然下一章续扫
  state.sceneResumeChapIdx = chapIdx;
  state.sceneResumeOffset = off;
  return true;
}

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
    int chNumOf(int i) =>
        chapters[i].number > 0 ? chapters[i].number : i + 1;
    // v534b（用户裁决：切片字符级不重不漏）：续切位不靠文本搜索——剪断时
    // 已把"章索引+章内偏移"精确持久化（sceneResumeChapIdx/Offset），此处直接
    // 用偏移喂半章；正常增量无锚点=旧行为（末场景收在窗口末尾，余量自然为空）
    var from = state.globalSceneScannedUpTo + 1;
    final useAnchor = state.sceneResumeChapIdx >= 0 &&
        state.sceneResumeChapIdx < chapters.length &&
        state.sceneResumeOffset > 0 &&
        state.sceneResumeOffset < chapters[state.sceneResumeChapIdx].content.length;
    if (useAnchor) {
      from = chNumOf(state.sceneResumeChapIdx);
    }
    log(
      from == 1
          ? '开始全书场景扫描：$totalChapters章，窗口$stepSize章'
          : '继续场景扫描：从第$from章起${useAnchor ? "（字符级续切：自剪断锚点偏移${state.sceneResumeOffset}）" : ""}（已完成${state.globalScenes.length}场景）',
    );
    try {
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

        // 窗口文本——v534b：锚点章喂偏移后半章（偏移在剪断时已精确算出）
        final anchorOffset =
            (useAnchor && fromIdx == state.sceneResumeChapIdx)
                ? state.sceneResumeOffset
                : 0;
        final buf = StringBuffer();
        for (var i = fromIdx; i <= toIdx; i++) {
          final ch = chapters[i];
          final n = ch.number > 0 ? ch.number : i + 1;
          final content =
              (i == fromIdx && anchorOffset > 0)
                  ? ch.content.substring(anchorOffset)
                  : ch.content;
          buf.write('\n\n=== 第$n章 ===\n\n${ch.title}\n\n$content');
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
          task: '场景流扫描',  // v824任务级反馈
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
        // v535b：切片纯正文——剔除窗口家具（章标记+标题行）。家具是窗口喂
        // 文的定位设施，不该进切片：创作范文/arc.text拼接/剪断锚点全在消费
        // scene.text。用精确构造的家具串整串替换，章界接缝保留双换行
        for (final sc in winScenes) {
          for (var i = fromIdx; i <= toIdx; i++) {
            final ch = chapters[i];
            final n = ch.number > 0 ? ch.number : i + 1;
            sc.text = sc.text.replaceAll(
              '\n\n=== 第$n章 ===\n\n${ch.title}\n\n',
              '\n\n',
            );
          }
          sc.text = sc.text.trim();
        }

        // 落库：globalIndex连续递增；continuation=true的首场景与全局流
        // 最后场景合并（跨窗口同一场景不拆两条，v437）
        for (final sc in winScenes) {
          final last = state.globalScenes.isNotEmpty
              ? state.globalScenes.last
              : null;
          // v653：合并门槛——仅半章锚点续扫(anchorOffset>0)才允许跨窗合并。
          // 常规窗口末场景必收束,模型误标continuation会把两个独立场景缝成
          // 一条(用户实测场景38"夺宝比试"+"回屋报喜"被"；"缝死)。
          // 宁可多切一条可后并,不可错并难拆
          if (sc.continuation && last != null && anchorOffset > 0) {
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
            if (sc.continuation && anchorOffset == 0) {
              log('⚠ 场景「${sc.name}」continuation标记被拒（非锚点续扫）——按新场景落库');
            }
            sc.continuation = false;
            sc.globalIndex = state.globalScenes.length;
            state.globalScenes.add(sc);
          }
        }
        state.globalSceneScannedUpTo = wTo;
        state.saveGlobalScenes();
        log(
          '✓ 第$wFrom-$wTo章：${winScenes.length}场景（累计${state.globalScenes.length}）',
        );
        // v534b：锚点仅首窗生效——本窗口末场景必收在窗口末尾，余量为空
        state.sceneResumeChapIdx = -1;
        state.sceneResumeOffset = 0;
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
    // v824：'终章/大结局/尾声/后记/番外'被章号解析沉底为100000（chinese_number v281）——
    // 分组前钳回实际章数，否则对账lastChapter=100000误报99958章未覆盖+scannedChapterCount污染
    final totalCh = state.chapters.length;
    if (totalCh > 0) {
      var clamped = 0;
      for (final sc in gs) {
        if (sc.endChapter > totalCh) {
          sc.endChapter = totalCh;
          clamped++;
        }
      }
      if (clamped > 0) {
        log('ℹ v824：$clamped个场景章号超总章数（终章沉底100000）已钳回$totalCh');
      }
    }
    log('开始弧线分组：${gs.length}个场景');
    try {
      // v824：任务开始摘要——模式/输入规模/模型/批量/RPM一眼可查
      final cfg0 = state.getApiConfig('arc');
      final sw = Stopwatch()..start();
      log(
        '▶ 任务开始：弧线分组｜${resume ? "增量续跑" : "全新分组"}｜输入${gs.length}个场景'
        '（第${gs.first.startChapter}-${gs.last.endChapter}章）'
        '｜模型${cfg0.effectiveModel}｜批量${state.groupBatchSize > 0 ? state.groupBatchSize : 30}场景/批'
        '｜RPM${cfg0.rpmLimit > 0 ? cfg0.rpmLimit : "不限"}',
      );
      final batch = state.groupBatchSize > 0 ? state.groupBatchSize : 30;
      final arcs = <Arc>[]; // 组装中的弧线
      final extractedArcs = <int>{}; // v495已提取零件的弧线号
      var cursor = 0; // 已分组到的场景序号
      var arcNum = 0;
      // 未闭合弧线上文（跨批传递）
      Arc? openArc;
      // v496：增量续跑——恢复上次已保存的弧线成果，从断点继续
      if (resume && state.arcScan != null && state.arcScan!.arcs.isNotEmpty) {
        // v537：一致性卫兵——弧线必须从场景1连续平铺到分组断点，且断点不超
        // 场景流长度。违反=场景流曾重建/清零而旧弧线残留（两代流混血）：
        // 级联清空旧弧线+对应分镜/拆解，从场景1重新分组（用户裁决：清流必清弧）
        // v1181：增量前置——先自动减掉末条不完整弧线（用户裁决：增量前自动减，
        // 不完整尾弧本来就要重分；留着会让sceneTo越过断点触发卫兵级联清空）
        final preArcs = state.arcScan!.arcs;
        if (preArcs.isNotEmpty && preArcs.last.status == 'incomplete') {
          final drop = preArcs.removeLast();
          state.arcAnalyses.remove(drop.number.toString());
          state.arcScenes.remove(drop.number.toString());
          state.globalGroupedUpTo =
              preArcs.isEmpty ? 0 : preArcs.last.sceneTo;
          // v1187：账本回滚到保留末弧快照（与手动剪断v1175同规则）——中断前旧尾弧
          // 对账可能已落盘，残留会让弧线${drop.number - 1}重提对账被"未来状态"倒灌
          state.rollbackLedgerToLatestSnapshot();
          state.saveArcScan();
          state.saveArcAnalyses();
          state.saveArcScenes();
          state.saveGlobalScenes();
          log('↻ 增量前置：自动减掉不完整弧线${drop.number}「${drop.title}」（场景${drop.sceneFrom}-${drop.sceneTo}），从场景${state.globalGroupedUpTo + 1}重分（账本已回滚）');
        }
        final oldArcs = state.arcScan!.arcs;
        // v1181：平铺完好性（首弧=1+连续不交叉）与断点数字分开判——弧线平铺
        // 是分组成果本体，断点只是账面数字（重导章节/旧bug会让数字过期）。
        // 数字坏了修正数字继续跑，不再级联清空48条弧线（用户实测惨案）
        var flat = oldArcs.first.sceneFrom == 1;
        var expect = 1;
        if (flat) {
          for (final a in oldArcs) {
            if (a.sceneFrom != expect) {
              flat = false;
              break;
            }
            expect = a.sceneTo + 1;
          }
        }
        final lastTo = oldArcs.last.sceneTo;
        if (!flat || lastTo > gs.length) {
          state.clearArcCascade();
          log('⛔ 弧线平铺断裂（首弧起点/连续性/越界检查失败）——已级联清空旧弧线/分镜/拆解/正文切片，本次从场景1重新分组');
        } else {
          if (state.globalGroupedUpTo != lastTo) {
            final stale = state.globalGroupedUpTo;
            state.globalGroupedUpTo = lastTo;
            state.saveGlobalScenes();
            log('ℹ 账面断点($stale)与弧线尾($lastTo)不一致——已按弧线平铺修正断点，增量续跑');
          }
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
          // v1164：零件+编排都齐才判"已提取"——只判零件会把没跑过编排的旧弧线
          // 一并跳过（用户实测：增量续跑时前面弧线全跳过编排，只有新弧线有编排）
          // v1187：判据加账本快照（v1185裁决"零件含账本不齐=整条重新生成"）——
          // 漏查会让账本缺的弧线直接跳过，主循环hasSnap检查永远轮不到（弧线64实证）
          final md = state.arcAnalyses[a.number.toString()]?.metadata;
          if ((md?['arc_summary_detailed'] ?? '').toString().isNotEmpty && // v1183：判非空防空串脏数据误跳
              (md?['arc_choreo'] ?? '').toString().isNotEmpty &&
              (md?['state_ledger_snapshot'] as List? ?? []).isNotEmpty) {
            extractedArcs.add(a.number);
          }
        }
        if (dropped != null) {
          log('↻ 增量续跑：保留${arcs.length}条完整弧线，抛弃未闭合弧线${dropped.number}「${dropped.title}」（场景${dropped.sceneFrom}-${dropped.sceneTo}），从场景${cursor + 1}重分');
        } else {
          log('↻ 增量续跑：已恢复${arcs.length}条弧线，从场景${cursor + 1}继续');
        }
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
            '## summary=关键事件概述（v1206b用户裁决：弧线级只总结关键事件，不做目标/行动分析）\n'
            '按时间顺序串联这条弧线的关键事件：谁在什么情况下做了什么、结果如何——每句一个具体事件（含人名/物品/结果），环环推进，最终落定在一个明确的不可逆变化上收束（"达成约定"不是"发现机会"）。\n'
            '- 弧线级禁写角色目标/阻力/行动/矛盾/特质的分析框架——那是场景/分镜级单位，弧线概述只记事件链与状态落点；弧线未闭合（status=incomplete）时如实写到当前进度，禁止编造收束\n\n'
            '## 规则\n'
            '- 场景必须全部归入弧线，按顺序连续，不得跳过/重叠\n'
            '- **闭合判定看下一场景**：处理到场景M时，场景M+1仍是本弧线主角/叙事延续→继续；切到别的角色/线→本场景收束（伪闭合）；主角发生不可逆变化（真闭合）→也可在此收束\n'
            '- focus=视角主角\n'
            '- 最后一条弧线若叙事未收束（书未读完的中间态），status=incomplete\n\n'
            '- ⚠️ arc_choreo与scene_choreos为**必填字段**（v886实测：模型常只给arc_choreo漏scene_choreos=输出不完整）\n'
            '- arc_choreo（弧线总目的）：${PromptBuilder.arcChoreoTemplate}\n'
            '- scene_choreos（逐场景目的，**本弧线每个场景都必须有一项**）：${PromptBuilder.scenePurposeTemplate}\n'
            '只输出纯JSON：{"arcs": [{"title": "...", "summary": "...", "focus": "...", "close_type": "real/pseudo", "status": "complete/incomplete", "scene_from": 起始场景序号, "scene_to": 结束场景序号, "closure_reason": "闭合依据(a)落定在哪个场景(b)为什么不是前一场景(c)提前闭合会怎样", "arc_choreo": "弧线总目的", "scene_choreos": "场景N:目的内容；场景M:无"}]}';
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
        if (arcsJson == null) {
          // v1194：裸数组兜底（AI格式漂移无arcs包装——22:40三连解析失败实证）
          final bare = JsonRepair.parseListResponse(result.content);
          if (bare != null && bare.isNotEmpty) {
            arcsJson = bare;
            log('ℹ 分组输出为裸数组（无arcs包装）——已兼容解析');
          }
        }
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
          if (arcsJson == null) {
            final bare2 = JsonRepair.parseListResponse(r2.content);
            if (bare2 != null && bare2.isNotEmpty) {
              arcsJson = bare2;
              log('ℹ 重试输出为裸数组——已兼容解析');
            }
          }
        }
        if (arcsJson == null || arcsJson.isEmpty) {
          log('⛔ 分组解析失败（重试${retryN}次仍无弧线返回）——中断，请用"重来"重新分组');
          break;
        }
        // v1194：全列表未闭合收口——AI单批可返回多条弧线，中间条标"待续"但本批
        // 后续已另起（只有最后一条进openArc），中间条永久遗incomplete→提取循环
        // 只认complete→零件永远空白（弧线100/101实证：体系0/10+无账本）。
        // 批尾统一扫：除最后一条外的所有incomplete弧线补转伪闭合
        if (arcsJson.isNotEmpty) {
          for (var i = 0; i < arcs.length - 1; i++) {
            final a = arcs[i];
            if (a.status != 'complete') {
              a.status = 'complete';
              a.closeType = 'pseudo';
              log('ℹ 未闭合弧线${a.number}「${a.title}」后续弧线已存在——补转伪闭合');
            }
          }
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
          // v900概念定稿：scene_choreos=弧线总目的的**逐场景目的判定**（v1209改）
          // （弧线层结构数据）——存arcAnalyses.metadata，不再写Scene.choreo
          // （Scene.choreo专属"场景内分镜编排策略"=拆分镜详版，字段分家防覆盖）
          final scChoreos = m['scene_choreos']?.toString() ?? '';
          String scChoreosSaved = ''; // v900：延后到analysis创建后落库
          // v1177：-1=AI未输出；>=0=输出且为落点数——日志延到arcNum赋值后
          // （v1086教训：先算新值再打日志。首条弧线曾误报"弧线0"——log在arcNum+1之前打）
          int choreoCount = -1;
          if (scChoreos.isNotEmpty) {
            scChoreosSaved = scChoreos;
            choreoCount =
                RegExp(r'(\d+)\s*[:：]').allMatches(scChoreos).length;
          }
          final arcChoreoV = m['arc_choreo']?.toString() ?? '';
          final isContinuation = openArc != null &&
              (m['title']?.toString() ?? '').contains(openArc.title);
          arcNum = isContinuation ? openArc!.number : arcNum + 1;
          if (scChoreos.isEmpty) {
            log('⚠️ 弧线$arcNum AI未输出scene_choreos字段（arc_choreo=${m['arc_choreo'] != null ? "有" : "无"}）');
          } else if (choreoCount == 0) {
            log('⚠️ 弧线$arcNum scene_choreos格式未解析出任何场景（原文头80字：${scChoreos.substring(0, scChoreos.length > 80 ? 80 : scChoreos.length)}）');
          } else {
            log('✓ 编排落库：弧线$arcNum $choreoCount个场景状态变化');
          }
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
          // v900/v917：弧线层策略数据统一存analysis.metadata（语料/条目唯一读取源）
          // arc_choreo总目的+scene_choreos逐场景目的——分组即落，不等重提零件
          final newMeta = <String, dynamic>{...?analysis.metadata};
          if (scChoreosSaved.isNotEmpty) newMeta['scene_choreos'] = scChoreosSaved;
          if (arcChoreoV.isNotEmpty) newMeta['arc_choreo'] = arcChoreoV;
          analysis.metadata = newMeta;
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
            // v1164：零件/编排分别判缺补跑——零件齐的不重烧零件API，只补编排
            final md = state.arcAnalyses[a.number.toString()]?.metadata;
            var hasParts =
                (md?['arc_summary_detailed'] ?? '').toString().isNotEmpty; // v1183：判非空
            final hasChoreo =
                (md?['arc_choreo'] ?? '').toString().isNotEmpty;
            // v1185：零件或账本快照不齐——整条弧线重新提取（用户裁决：零件含账本，
            // 不齐减掉重来；分组边界保留不影响其他弧线）。配合各任务3次重试抗网络抖动
            final hasSnap =
                (md?['state_ledger_snapshot'] as List? ?? []).isNotEmpty;
            if (hasParts && !hasSnap) {
              log('↻ 弧线${a.number}账本快照缺失——清零件记录整条重新提取（编排保留）');
              state.arcAnalyses[a.number.toString()]!.metadata
                  ?.remove('arc_summary_detailed'); // 只清零件判据，编排字段保留
              hasParts = false; // 重置后走下方完整提取分支
            }
            if (hasParts) {
              log('ℹ 弧线${a.number}零件已有——补跑编排策略分析');
            } else {
              final ok = await extractArcParts(state: state, arc: a, log: log);
              // v1172：报错即终止——保存分组成果断点，增量续跑从本弧线重来
              if (!ok) {
                log('⛔ 弧线${a.number}零件提取失败——批量生成弧线终止（已保存${arcs.length}条弧线分组，成果已落盘）');
                log('ℹ 修复API配置后重新「批量」——从弧线${a.number}增量继续');
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
                // v1179：断点=已分组弧线尾而非cursor——cursor在提取循环后才推进，
                // 此刻还是上一批的值，弧线尾>账面断点会触发卫兵级联清空（断点续跑失效实测）
                state.globalGroupedUpTo =
                    arcs.last.sceneTo.clamp(0, gs.length);
                state.saveGlobalScenes();
                return;
              }
            }
            // v903：编排分析自动化（滚动模式同步）
            if (!hasChoreo) {
              log('▶ 弧线${a.number}【弧线总目的】分析开始');
              final okC = await analyzeArcChoreo(state: state, arc: a, log: log);
              if (!okC) {
                log('⛔ 弧线${a.number}编排分析失败——批量生成弧线终止（零件已落盘，编排增量补跑）');
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
                // v1179：断点=已分组弧线尾而非cursor——cursor在提取循环后才推进，
                // 此刻还是上一批的值，弧线尾>账面断点会触发卫兵级联清空（断点续跑失效实测）
                state.globalGroupedUpTo =
                    arcs.last.sceneTo.clamp(0, gs.length);
                state.saveGlobalScenes();
                return;
              }
            }
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
          // v1164：零件/编排分别判缺补跑（与主循环同规则）
          final md = state.arcAnalyses[a.number.toString()]?.metadata;
          var hasParts =
              (md?['arc_summary_detailed'] ?? '').toString().isNotEmpty; // v1183：判非空
          final hasChoreo = (md?['arc_choreo'] ?? '').toString().isNotEmpty;
          // v1185：账本快照缺=整条重新提取（用户裁决：零件含账本，不齐减掉重来）
          final hasSnap =
              (md?['state_ledger_snapshot'] as List? ?? []).isNotEmpty;
          if (hasParts && !hasSnap) {
            log('↻ 弧线${a.number}账本快照缺失——清零件记录整条重新提取（编排保留）');
            state.arcAnalyses[a.number.toString()]!.metadata
                ?.remove('arc_summary_detailed'); // 只清零件判据，编排字段保留
            hasParts = false; // 重置后走下方完整提取分支
          }
          if (!hasParts) {
            final ok = await extractArcParts(state: state, arc: a, log: log);
            if (!ok) {
              log('⛔ 弧线${a.number}零件提取失败——兜底提取终止（增量续跑可从本弧线重来）');
              return;
            }
          }
          if (!hasChoreo) {
            log('▶ 弧线${a.number}【弧线总目的】分析开始');
            final okC = await analyzeArcChoreo(state: state, arc: a, log: log);
            if (!okC) {
              log('⛔ 弧线${a.number}编排分析失败——兜底提取终止（零件已落盘，编排增量补跑）');
              return;
            }
          }
          done++;
          log('零件+编排提取进度：$done/${arcs.length}');
        }
        log('=== 弧线零件提取完成 ===');
        // v824：任务完成总汇报——结果规模/章覆盖/耗时/提取完整度
        log(
          '✅ 任务完成：弧线分组共${arcs.length}条弧线'
          '（第${arcs.first.startChapter}-${arcs.last.endChapter}章），'
          '覆盖${gs.length}场景，耗时${(sw.elapsed.inSeconds / 60).toStringAsFixed(1)}分钟，'
          '零件提取${extractedArcs.length}/${arcs.length}条',
        );
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
/// v901：场景内分镜编排策略分析（场景页/分镜页共用——拆分镜后才能跑）
Future<void> analyzeSceneChoreo({
  required AppState state,
  required Scene scene,
  required void Function(String msg) log,
}) async {
  if (scene.shots.isEmpty) {
    log('⛔ 场景无分镜——先拆分镜，编排策略基于分镜序列分析');
    return;
  }
  if (scene.text.isEmpty) {
    log('⛔ 场景无锚定切片（旧数据）——无法分析编排');
    return;
  }
  final skeleton = [
    for (var i = 0; i < scene.shots.length; i++)
      '分镜${i + 1}：焦点=${scene.shots[i].focus}｜意图=${scene.shots[i].intent}',
  ].join('\n');
  // v1030：改读'analysis'——编排分析在分镜页触发，用户在分镜页⚙API设的就是它；
  // 原读'shot'（历史遗留旧section）=用户设gemini拆解却用deepseek跑编排的根因
  final config = state.getApiConfig('analysis');
  state.api.clearAbort();
  final result = await state.api.callApi(
    task: '场景内分镜编排策略分析',
    systemPrompt: PromptBuilder.buildSceneChoreoSystemPrompt(),
    userPrompt: '【场景原文切片】\n${scene.text}\n\n【分镜骨架清单】\n$skeleton',
    apiConfig: config,
  );
  if (!result.isSuccess) {
    log('⚠ 编排分析失败：${result.error}');
    return;
  }
  final parts = JsonRepair.parseResponse(result.content);
  final choreo = parts?['choreo']?.toString() ?? '';
  if (choreo.isEmpty) {
    log('⚠ 编排分析解析失败（无choreo字段）');
    return;
  }
  // 双容器写（重载后两实例独立）
  scene.choreo = choreo;
  if (scene.globalIndex >= 0 && scene.globalIndex < state.globalScenes.length) {
    state.globalScenes[scene.globalIndex].choreo = choreo;
  }
  state.saveArcAnalyses();
  state.saveGlobalScenes();
  log('✓ 场景${scene.globalIndex + 1}【场景内分镜编排策略】已落库（${choreo.length}字）');
}

/// v901：弧线总目的分析（独立按键——骨架/表述分离，单任务保质量；v1209总目的）
/// v1172：返回true=成功落库；false=失败（批量报错即终止，增量续跑从该弧线重来）
Future<bool> analyzeArcChoreo({
  required AppState state,
  required Arc arc,
  required void Function(String msg) log,
  Future<bool> Function(String sys, String user)? previewHook, // v1157：词链预览
}) async {
  if (arc.text.isEmpty) {
    log('⚠ 弧线${arc.number}无正文切片，跳过编排分析');
    return false;
  }
  final gsAll = state.globalScenes;
  final sceneList = (arc.sceneFrom >= 1 && gsAll.length >= arc.sceneTo)
      ? [
          for (var i = arc.sceneFrom; i <= arc.sceneTo && i <= gsAll.length; i++)
            '场景$i：${gsAll[i - 1].name}｜${gsAll[i - 1].summary.length > 60 ? gsAll[i - 1].summary.substring(0, 60) : gsAll[i - 1].summary}',
        ].join('\n')
      : '';
  final systemPrompt = PromptBuilder.buildArcChoreoSystemPrompt();
  final userPrompt = PromptBuilder.buildArcPartsUserPrompt(
    arcTitle: arc.title,
    arcSummary: arc.summary,
    arcText: arc.text,
    sceneList: sceneList,
    choreoMode: true,
  );
  // v1157：词链预览（编排任务发前弹，取消即中止）
  if (previewHook != null) {
    final ok = await previewHook!(systemPrompt, userPrompt);
    if (!ok) {
      log('⛔ 弧线${arc.number}编排分析已取消（词链预览）');
      return false;
    }
  }
  final config = state.getApiConfig('arc');
  final result = await state.api.callApi(
    task: '弧线总目的分析', // v824任务级反馈；v1165改名——原与分镜级analyzeSceneChoreo重名致日志混淆

    systemPrompt: systemPrompt,
    userPrompt: userPrompt,
    apiConfig: config,
  );
  if (!result.isSuccess) {
    log('⛔ 弧线${arc.number}编排分析失败：${result.error}');
    return false; // v1172：报错即失败（重试一次）
  }
  // v1185：最多3次尝试
  var parts = JsonRepair.parseResponse(result.content);
  for (var attempt = 1; parts == null && attempt <= 2; attempt++) {
    log('↻ 弧线${arc.number}编排解析失败，重试（$attempt/2）…');
    final r = await state.api.callApi(
      task: '弧线总目的分析',
      systemPrompt: systemPrompt,
      userPrompt: userPrompt,
      apiConfig: config,
    );
    parts = r.isSuccess ? JsonRepair.parseResponse(r.content) : null;
  }
  if (parts == null) {
    log('⛔ 弧线${arc.number}编排分析两次尝试均失败——增量续跑可从本弧线重来');
    return false;
  }
  // 总纲：Arc+metadata双写（显示+语料两个消费端）
  final arcChoreoV = parts['arc_choreo']?.toString() ?? '';
  final scChoreos = parts['scene_choreos']?.toString() ?? '';
  if (scChoreos.isEmpty) {
    log('⛔ 弧线${arc.number}编排输出缺scene_choreos——视为失败，增量续跑可从本弧线重来');
    return false;
  }
  final analysis = state.arcAnalyses[arc.number.toString()];
  if (analysis != null) {
    analysis.metadata = {
      ...?analysis.metadata,
      'arc_choreo': arcChoreoV,
      'scene_choreos': scChoreos,
    };
    state.saveArcAnalyses();
  }
  log('✓ 弧线${arc.number}【弧线总目的】已落库（总目的${arcChoreoV.length}字+逐场景目的${scChoreos.length}字）');
  return true;
}


/// v1163：零件输出净化——AI格式漂移把"💎 不可逆变化+内容"粘进其他字段值
/// （截图实证：弧线功能第二条尾部粘连）。irreversible_changes为空时切出归还；
/// 其他零件标题标记只剥离保内容（兜底可读）
void sanitizeParts(Map<String, dynamic> m) {
  const irMarker = '💎 不可逆变化';
  final ir = (m['irreversible_changes'] ?? '').toString().trim();
  if (ir.isNotEmpty) return; // 目标字段有内容：只剥离不转移
  for (final key in ['arc_functions', 'conflicts', 'foreshadowing', 'author_fantasy']) {
    final v = m[key];
    if (v is List) {
      for (var i = 0; i < v.length; i++) {
        final t = v[i].toString();
        final idx = t.indexOf(irMarker);
        if (idx < 0) continue;
        final head = t.substring(0, idx).trim();
        var tail = t.substring(idx + irMarker.length).trim();
        tail = tail.replaceFirst(RegExp(r'^[：:]\s*'), '');
        if (head.isNotEmpty) {
          v[i] = head;
        } else {
          v.removeAt(i);
        }
        if (tail.isNotEmpty) m['irreversible_changes'] = tail;
        return;
      }
    }
  }
}

/// v1154：世界状态对账（零件提取第四任务）——上一版账本+本弧线零件→增量更新。
/// 账本=实体状态单一事实源（AppState.stateLedger），每弧线快照进metadata可回溯
/// v1172：返回true=账本已滚动更新；false=对账失败（账本保留上一版，零件不落盘）
Future<bool> reconcileStateLedger({
  required AppState state,
  required Arc arc,
  required Map<String, dynamic> parts,
  required void Function(String msg) log,
}) async {
  final prevLedger = state.stateLedger.isEmpty ? '' : jsonEncode(state.stateLedger);
  final pb = StringBuffer();
  final ov = parts['arc_summary']?.toString() ?? '';
  if (ov.isNotEmpty) pb.writeln('【本弧线概述】\n$ov');
  if (parts['characters'] != null) pb.writeln('【人设】${jsonEncode(parts['characters'])}');
  if (parts['conflicts'] != null) pb.writeln('【矛盾冲突】${jsonEncode(parts['conflicts'])}');
  if (parts['foreshadowing'] != null) pb.writeln('【伏笔】${jsonEncode(parts['foreshadowing'])}');
  final ir = parts['irreversible_changes']?.toString() ?? '';
  if (ir.isNotEmpty) pb.writeln('【不可逆变化】$ir');
  final facts = parts['worldbuilding_facts'] == null ? '' : jsonEncode(parts['worldbuilding_facts']);
  if (facts.isNotEmpty) pb.writeln('【世界观facts】$facts');
  if (pb.toString().trim().isEmpty) {
    log('⛔ 弧线${arc.number}无零件可对账');
    return false;
  }
  final config = state.getApiConfig('arc');
  // v1179：对账与其他任务同款重试一次（实测对账输出无效直接终止整批太脆）
  Future<ApiResult> callReconcile() => state.api.callApi(
        task: '世界状态对账', // v824任务级反馈
        systemPrompt: PromptBuilder.buildLedgerReconcileSystemPrompt(),
        userPrompt: PromptBuilder.buildLedgerReconcileUserPrompt(
          arcNum: arc.number,
          prevLedger: prevLedger,
          partBlock: pb.toString(),
        ),
        apiConfig: config,
      );
  // v1185：最多3次尝试
  var r = await callReconcile();
  var out = r.isSuccess ? JsonRepair.parseResponse(r.content) : null;
  for (var attempt = 1; attempt <= 2; attempt++) {
    // v1195：判据兼容增量格式（changed/added任一非空=有效）与全量ledger
    final bad = out == null ||
        !((out['ledger'] is List && (out['ledger'] as List).isNotEmpty) ||
            ((out['changed'] as List?)?.isNotEmpty ?? false) ||
            ((out['added'] as List?)?.isNotEmpty ?? false));
    if (!bad) break;
    log('↻ 弧线${arc.number}状态对账无效，重试（$attempt/2）…');
    r = await callReconcile();
    out = r.isSuccess ? JsonRepair.parseResponse(r.content) : null;
  }
  if (!r.isSuccess) {
    log('⚠ 弧线${arc.number}状态对账请求失败：${r.error}——账本保留上一版');
    return false;
  }
  final list = out?['ledger'];
  // v1195：增量格式（无ledger键）放行，由下方merge处理；全量格式仍验空
  final isInc = list is! List;
  if (!isInc && list.isEmpty) {
    log('⚠ 弧线${arc.number}状态对账输出无效——账本保留上一版');
    return false;
  }
  final newLedger = <Map<String, dynamic>>[];
  // v1195：增量merge——AI只回吐changed/added/removed（瘦身：67k全量→5-10k增量），
  // 程序合并进上一版快照；落库仍是全量账本，下游消费端零改动。
  // 兜底：AI格式漂移回吐旧全量格式{"ledger":[...]}时直接全量采用
  final changed = (out?['changed'] as List?) ?? const [];
  final added = (out?['added'] as List?) ?? const [];
  final removedRaw = (out?['removed'] as List?) ?? const [];
  final isIncremental = isInc && (changed.isNotEmpty || added.isNotEmpty);
  if (isIncremental) {
    String entKey(Map e) => '${e['category']}|${e['name']}';
    final removedNames = <String>{
      for (final r in removedRaw)
        if (r is Map)
          r['name'].toString()
        else
          r.toString(),
    };
    final changedByKey = <String, Map<String, dynamic>>{
      for (final e in changed)
        if (e is Map)
          entKey(e.map((k, v) => MapEntry(k.toString(), v))):
              e.map((k, v) => MapEntry(k.toString(), v)),
    };
    final addedByKey = <String, Map<String, dynamic>>{
      for (final e in added)
        if (e is Map)
          entKey(e.map((k, v) => MapEntry(k.toString(), v))):
              e.map((k, v) => MapEntry(k.toString(), v)),
    };
    // 保序合并：旧账本顺序遍历，removed剔除、changed覆盖、其余原样
    final seen = <String>{};
    for (final e0 in state.stateLedger) {
      final k = entKey(e0);
      if (removedNames.contains(k.split('|').last) || removedNames.contains(k)) continue;
      seen.add(k);
      newLedger.add(changedByKey[k] ?? e0);
    }
    // 新增（changed未命中旧账也按新增处理）追加尾部
    for (final entry in addedByKey.entries) {
      if (!seen.contains(entry.key)) newLedger.add(entry.value);
    }
    for (final entry in changedByKey.entries) {
      if (!seen.contains(entry.key) && !addedByKey.containsKey(entry.key)) {
        newLedger.add(entry.value);
      }
    }
    log('ℹ 弧线${arc.number}增量对账：变更${changedByKey.length}+新增${addedByKey.length}-剔除$removedNames.length，合并后${newLedger.length}实体');
  } else {
    if (list is! List) {
      // v1195：重试后仍无变更无账本（changed/added/removed全空）——保留上一版
      log('⚠ 弧线${arc.number}状态对账输出无变更无账本——保留上一版');
      return false;
    }
    for (final e in list) {
      if (e is Map) newLedger.add(e.map((k, v) => MapEntry(k.toString(), v)));
    }
  }
  if (newLedger.isEmpty) {
    log('⚠ 弧线${arc.number}状态对账账本为空——保留上一版');
    return false;
  }
  state.stateLedger = newLedger;
  state.saveStateLedger();
  final key = arc.number.toString();
  final analysis = state.arcAnalyses[key];
  if (analysis != null) {
    analysis.metadata = {
      ...?analysis.metadata,
      'state_ledger_snapshot': newLedger, // 快照可回溯
    };
    state.saveArcAnalyses();
  }
  log('✓ 弧线${arc.number}世界状态账本已更新（${newLedger.length}实体，快照已存）');
  return true;
}

/// v1153：历史弧线零件注入——N-1弧线全量+更早弧线关键状态行（v1190缩为一条）。
/// 数据源=arcAnalyses.metadata（拆解层自身产物，拆书阶段世界书条目尚不存在）。
/// 用途：新弧线零件提取时人设承接（角色生死/关系变化/未回收伏笔需前情基准）
String buildArcHistoryBlock(AppState state, int curNum) {
  final nums = <int>[];
  for (final k in state.arcAnalyses.keys) {
    final n = int.tryParse(k);
    if (n != null && n < curNum) nums.add(n);
  }
  if (nums.isEmpty) return '';
  nums.sort();
  String jStr(dynamic v) => v == null ? '' : (v is String ? v : jsonEncode(v));
  String meta(Map<String, dynamic>? m, String k) {
    final v = m?[k];
    return v == null ? '' : v.toString();
  }
  final sb = StringBuffer();
  var has = false;
  // v1190：全量注入缩为N-1一条（用户裁决：71k字注入太大）——人设承接是
  // 递推链：N-1条目本身已写"状态变化（从什么变到什么）"，N-2信息已被N-1
  // 吸收，单独再注一遍是重复；更早弧线关键状态行保留（每行仅500余字）
  final recent = nums.reversed.take(1).toSet(); // N-1
  for (final n in nums.reversed.take(1)) {
    final a = state.arcAnalyses[n.toString()];
    if (a == null) continue;
    has = true;
    final m = a.metadata;
    sb.writeln('—— 弧线$n（${a.arcTitle}）全部零件 ——');
    final ov = meta(m, 'arc_summary_detailed');
    if (ov.isNotEmpty) sb.writeln('概述：$ov');
    if (m?['characters'] != null) sb.writeln('人设：${jStr(m!['characters'])}');
    if (m?['conflicts'] != null) sb.writeln('矛盾冲突：${jStr(m!['conflicts'])}');
    if (m?['foreshadowing'] != null) sb.writeln('伏笔：${jStr(m!['foreshadowing'])}');
    final ir = meta(m, 'irreversible_changes');
    if (ir.isNotEmpty) sb.writeln('不可逆变化：$ir');
    final ec = meta(m, 'emotional_curve');
    if (ec.isNotEmpty) sb.writeln('情绪曲线：$ec');
    sb.writeln();
  }
  for (final n in nums) {
    if (recent.contains(n)) continue; // N-1已全量注入
    final a = state.arcAnalyses[n.toString()];
    if (a == null) continue;
    has = true;
    final m = a.metadata;
    final ch = jStr(m?['characters']);
    final ov = meta(m, 'arc_summary_detailed'); // v1153：概述含物品得失/归属变化——older行补前120字
    sb.writeln('弧线$n（${a.arcTitle}）：不可逆变化：${meta(m, 'irreversible_changes')}'
        '${ch.isEmpty ? '' : '｜人设状态：${ch.length > 400 ? ch.substring(0, 400) : ch}'}'
        '${ov.isEmpty ? '' : '｜概述：${ov.length > 120 ? ov.substring(0, 120) : ov}'}');
  }
  return has ? sb.toString().trim() : '';
}

/// v1172：返回true=四任务全成功且零件+账本已落盘；false=任一失败（不落盘，
/// 增量续跑从本弧线重来——用户裁决：批量报错即终止，保证前面没问题再做后面的）
Future<bool> extractArcParts({
  required AppState state,
  required Arc arc,
  required void Function(String msg) log,
  Future<bool> Function(String sys, String user)? previewHook, // v1157：词链预览（调用1发前弹）
}) async {
  if (arc.text.isEmpty) {
    log('⚠ 弧线${arc.number}无正文切片，跳过零件提取');
    return false;
  }
  // v889：场景清单（全局序号+名称）——scene_choreos标号依据
  final gsAll = state.globalScenes;
  final sceneList = (arc.sceneFrom >= 1 && gsAll.length >= arc.sceneTo)
      ? [
          for (var i = arc.sceneFrom; i <= arc.sceneTo && i <= gsAll.length; i++)
            '场景$i：${gsAll[i - 1].name}｜${gsAll[i - 1].summary.length > 60 ? gsAll[i - 1].summary.substring(0, 60) : gsAll[i - 1].summary}',
        ].join('\n')
      : '';
  // v1191：历史零件注入废除（用户裁决：拆书提取的输入=原文，原文自带连续性
  // →提取结果天然与N-1一致，注入是冗余烧token；防前后矛盾真正需要的是续写链
  // ——那条走世界书条目+格局摘要，不吃此注入）。buildArcHistoryBlock保留备用
  final config = state.getApiConfig('arc');
  final merged = <String, dynamic>{};
  // v1191：旧预览段删除（v1186全景提取前已有previewHook，此段残留致双弹+旧prompt）
  // v1186：四任务合一"弧线全景提取"（用户裁决：200弧线×5次API太慢）——
  // 编排+剧情零件+facts+脑洞文风一次调用（输入高度重叠输出约8k字）；
  // 对账仍独立（输出2-3万字账本链，混入长输出砍尾=污染单一事实源）
  final sysFull = PromptBuilder.buildArcFullExtractSystemPrompt();
  // v1193：边界状态注入——分组器已判闭合的弧线禁用"弧线未闭合"句式
  // （防AI再判一遍与分组器打架，弧线85实证：✅完整但不可逆变化写"弧线未闭合"）
  final boundaryStatus = arc.status != 'complete'
      ? '边界未闭合（待续）——正文切片是进行中片段，按未闭合句式如实提取'
      : arc.closeType == 'pseudo'
          ? '边界已闭合（伪闭合）——本弧线叙事段在此完整结束并切线，正文切片是完整叙事段，按已闭合规则提取'
          : '边界已闭合（真闭合）——本弧线正文在此收束，正文切片是完整叙事段，按已闭合规则提取';
  final userFull = PromptBuilder.buildArcPartsUserPrompt(
    arcTitle: arc.title,
    arcSummary: arc.summary,
    arcText: arc.text,
    sceneList: sceneList,
    boundaryStatus: boundaryStatus,
    fullMode: true,
  );
  // v1157：词链预览（全景提取=提取主链唯一调用，发前弹，取消即中止）
  if (previewHook != null) {
    final ok = await previewHook!(sysFull, userFull);
    if (!ok) {
      log('⛔ 弧线${arc.number}全景提取已取消（词链预览）');
      return false;
    }
  }
  Map<String, dynamic>? full;
  for (var attempt = 1; attempt <= 3; attempt++) {
    final r = await state.api.callApi(
      task: '弧线全景提取（编排+零件+facts+脑洞）',
      systemPrompt: sysFull,
      userPrompt: userFull,
      apiConfig: config,
    );
    if (!r.isSuccess) {
      log('⚠ 弧线${arc.number}全景提取请求失败：${r.error}');
    } else {
      final p = JsonRepair.parseResponse(r.content);
      if (p == null) {
        log('⚠ 弧线${arc.number}全景提取解析失败（输出${r.content.length}字）');
      } else {
        final noSummary = (p['arc_summary'] ?? '').toString().trim().isEmpty;
        final chars = p['characters'];
        final noChars = chars is! List || chars.isEmpty;
        final noFacts = p['worldbuilding_facts'] is! List;
        final noChoreo = (p['scene_choreos'] ?? '').toString().trim().isEmpty;
        if (noSummary || noChars || noFacts || noChoreo) {
          log('⚠ 弧线${arc.number}全景提取缺核心键'
              '${noSummary ? "（无概述）" : ""}${noChars ? "（无人设）" : ""}'
              '${noFacts ? "（无facts）" : ""}${noChoreo ? "（无逐场景目的）" : ""}，输出${r.content.length}字');
        } else {
          full = p;
        }
      }
    }
    if (full != null) break;
    if (attempt < 3) log('↻ 弧线${arc.number}全景提取重试（$attempt/2）…');
  }
  if (full == null) {
    log('⛔ 弧线${arc.number}全景提取三次尝试均不完整——增量续跑可从本弧线重来');
    return false;
  }
  // 编排+零件+facts+脑洞文风统一落merged（原三任务键集不变，编排两键新增）
  for (final k in [
    'arc_choreo', 'scene_choreos',
    'arc_summary', 'characters', 'conflicts', 'foreshadowing',
    'arc_functions', 'irreversible_changes', 'emotional_curve',
    'worldbuilding_facts', 'author_fantasy', 'ink_hobby', 'style_dna',
  ]) {
    if (full[k] != null) merged[k] = full[k];
  }
  sanitizeParts(merged); // v1163：AI粘连带净化（💎不可逆变化切出归还）
  // v486b用户裁决：概述两次生成各归其位——第一次（分组时基于场景摘要）放弧线页，
  // 第二次（零件提取时基于原文切片，更细）只进分析层放分镜页展示，不写回覆盖弧线页
  // v488：详细概述存metadata['arc_summary_detailed']独立字段（场景页拆解链与零件提取链
  // 共用analysis.arcSummary互相覆盖导致两页概述一模一样——独立字段隔离）
  // ❌旧逻辑（v487，与场景页链打架已废弃）：
  // if (newSummary.isNotEmpty) analysis.arcSummary = newSummary;
  // analysis.arcSummary = arc.summary;
  final newSummary = merged['arc_summary']?.toString() ?? '';
  if (newSummary.isNotEmpty) {
    log('✓ 弧线${arc.number}详细概述已生成（分镜页展示，弧线页保留分组概述）');
  } else {
    log('⚠ 弧线${arc.number}：AI未输出arc_summary键，分镜页详细概述缺位');
  }
  final key = arc.number.toString();
  final old = state.arcAnalyses[key];
  final analysis = old ?? ArcAnalysis(arcNumber: arc.number, arcTitle: arc.title);
  // v1186：编排随全景提取一并落库（analyzeArcChoreo降级为旧数据兜底补跑）
  analysis.metadata = {
    ...?analysis.metadata,
    'arc_choreo': merged['arc_choreo'],
    'scene_choreos': merged['scene_choreos'],
    'arc_summary_detailed': newSummary,
    'characters': merged['characters'],
    'conflicts': merged['conflicts'],
    'foreshadowing': merged['foreshadowing'],
    'arc_functions': merged['arc_functions'],
    'irreversible_changes': merged['irreversible_changes'],
    'emotional_curve': merged['emotional_curve'],
    'author_fantasy': merged['author_fantasy'],
    'ink_hobby': merged['ink_hobby'],
    'style_dna': merged['style_dna'],
    'worldbuilding_facts': merged['worldbuilding_facts'],
  };
  // v1172：先写内存（对账快照需要读analysis）——对账成功才落盘，失败回滚内存，
  // 保证增量续跑判断（arc_summary_detailed非空）不误跳失败弧线
  state.arcAnalyses[key] = analysis;
  // v1154：状态对账第四任务——账本滚动更新（v1172：失败=弧线失败，不落盘）
  final ledgerOk = await reconcileStateLedger(state: state, arc: arc, parts: merged, log: log);
  if (!ledgerOk) {
    // v1183：回滚要完整——old非null（编排落库建的analysis）时恢复原metadata，
    // 否则本轮写入的空arc_summary_detailed键残留，增量续跑hasParts误判跳过该弧线
    if (old == null) {
      state.arcAnalyses.remove(key);
    } else {
      analysis.metadata = old.metadata;
    }
    state.saveArcAnalyses(); // v1185：清键状态落盘（重启后判缺依然成立，幂等重跑）
    log('⛔ 弧线${arc.number}状态对账失败——零件未落盘，增量续跑可从本弧线重来');
    return false;
  }
  state.saveArcAnalyses();
  // v481：概述同步到弧线页（arcScan.arcs的summary）
  if (newSummary.isNotEmpty && state.syncArcSummariesFromAnalyses() > 0) {
    state.saveArcScan();
  }
  log('✓ 弧线${arc.number}全景提取+账本已落盘（编排/人设/冲突/伏笔/脑洞/facts/对账）');
  // v496：实时刷新分镜页/弧线页（结果落盘后立即notify，用户边跑边看）
  state.notifyListeners();
  return true;
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
