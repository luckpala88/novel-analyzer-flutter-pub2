import '../models/api_config.dart';
import '../state/app_state.dart';
import '../models/arc.dart';
import '../models/chapter.dart';
import 'arc_text.dart';
import 'json_repair.dart';

/// v316：使用时锚点补定位——场景划分/分镜拆解遇到共享边界章缺锚时，
/// 发小请求补B线起始句（内部重试2次，含归一匹配），成功把锚点写回arc。
/// v339：全链路B首句语义——切分点=B首句起点（向前吸附），与ArcText配套。
/// 这是扫描期补定位（scan_page）的使用时复刻，替代"直接终止"。
class AnchorRepair {
  /// 通用分界句定位核心（2次尝试+归一匹配），返回原文字面锚点或null
  static Future<String?> locateBoundary(
    AppState state,
    dynamic config,
    String titleA,
    String summaryA,
    String titleB,
    String summaryB,
    Chapter chapter,
  ) async {
    final chFull = '${chapter.title}\n\n${chapter.content}';
    for (var attempt = 1; attempt <= 2; attempt++) {
      try {
        final extra = attempt == 1
            ? ''
            : '\n\n（第$attempt次重试）注意：分界原句必须逐字摘抄上面给出的原文，一个字都不能增删改，标点也要一致。';
        final rr = await state.api.callApi(
          systemPrompt: '你是网文编辑。只输出纯JSON，不要markdown。',
          userPrompt:
              '一章之内，弧线A「$titleA」（概述：${summaryA.isEmpty ? "无" : summaryA}）在此章内结束，弧线B「$titleB」（概述：${summaryB.isEmpty ? "无" : summaryB}）从此章内开始。以下是这一章的原文。\n\n请找出弧线B在本章开始的第一个句子：从共享章原文同一自然段内连续摘抄20-40字（不要跨段、不要增删改任何字和标点）。该句（含）起属于弧线B，该句之前全部属于弧线A。\n\n要求：这句话必须是B线剧情/场景的起点（B线人物登场、B线话题开启、场景切换后的第一句），严禁选B线场景内部或结尾的句子，也严禁选A线仍在进行的句子。\n\n输出格式：{"boundary_text": "B线首句原句"}\n\n${chapter.title}\n\n${chapter.content}$extra',
          apiConfig: config,
        );
        if (!rr.isSuccess) continue;
        final rj = JsonRepair.parseResponse(rr.content);
        final bt = rj == null ? null : '${rj['boundary_text'] ?? ''}';
        if (bt != null && bt.isNotEmpty && bt.length <= 100) {
          final anchor =
              chFull.contains(bt) ? bt : ArcText.fuzzyLocate(chFull, bt);
          if (anchor != null) return anchor;
        }
      } catch (_) {}
    }
    return null;
  }

  /// 弧线级：锚点写回arcA（boundaryAnchor/Offset基于章全文）
  static Future<bool> repairAnchor(
    AppState state,
    dynamic config,
    Arc arcA,
    Arc arcB,
    Chapter chapter,
  ) async {
    final a = await locateBoundary(state, config, arcA.title, arcA.summary,
        arcB.title, arcB.summary, chapter);
    if (a == null) return false;
    final chFull = '${chapter.title}\n\n${chapter.content}';
    arcA.boundaryAnchor = a;
    // v339：B首句语义，切分点=B首句起点（向前吸附）
    arcA.boundaryOffset = ArcText.snapToSentenceStart(chFull, chFull.indexOf(a));
    return true;
  }
}

