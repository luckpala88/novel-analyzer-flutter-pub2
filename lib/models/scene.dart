import 'arc.dart';
import '../utils/chinese_number.dart';

/// 叙事分镜模型
class Shot {
  String focus; // 聚焦点（内容层：原著具体内容）
  String shotType; // 镜头类型: 特写/近景/中景/远景/全景
  String pov; // 视角: 主角/配角/旁白/上帝视角
  String info; // 信息量: 补充/揭示/误导/回响（内容层）
  String intent; // 意图: 铺垫/推进/高潮/过渡/收束
  String transition; // 转场: 直接/时间跳/空间转/意识流
  String length; // 篇幅: 一句话/短/中/长/超长
  String content; // 分镜内容描述
  String proseStyle; // 文笔节奏
  String abstraction; // 功能抽象（类型层：该分镜的叙事功能，无原著专有名词。推演模式的骨架维度）
  String voice; // 语感锚（v218：修饰密度|句式|语域|原著例句——约束改编与正文的行文质感，治AI文学腔）
  String ink; // 笔墨配额（v219：分镜内各部分字数分配"心理盘算70字·摊主反应30字"——治AI平均用力，作者注意力权重的分镜级量化）
  String style; // 文风量化标尺（v640：句长N字|短句占比N%|动词密度N|对话占比N%|形容词密度N|比喻密度N——逐镜独立统计，防AI退回默认文风）
  String endText; // v363：镜级分界原句（本分镜结束处的最后一句原文，照抄含标点）
  String text; // v363：镜级锚定切片（拆解后按end_text链式物化；空=未物化回退场景切片）

  Shot({
    this.focus = '',
    this.shotType = '',
    this.pov = '',
    this.info = '',
    this.intent = '',
    this.transition = '',
    this.length = '',
    this.content = '',
    this.proseStyle = '',
    this.abstraction = '',
    this.voice = '',
    this.ink = '',
    this.style = '',
    this.endText = '',
    this.text = '',
  });

  factory Shot.fromJson(Map<String, dynamic> json) {
    return Shot(
      focus: json['focus'] ?? '',
      shotType: json['shot_type'] ?? json['shotType'] ?? '',
      pov: json['pov'] ?? '',
      info: json['info'] ?? '',
      intent: json['intent'] ?? '',
      transition: json['transition'] ?? '',
      length: json['length'] ?? '',
      content: json['content'] ?? '',
      proseStyle: json['prose_style'] ?? json['proseStyle'] ?? '',
      abstraction: json['abstract'] ?? json['abstraction'] ?? '',
      voice: json['voice'] ?? '',
      style: json['style'] ?? '',
      ink: json['ink'] ?? '',
      endText: json['end_text'] ?? json['endText'] ?? '',
      text: json['text'] ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
    'focus': focus,
    'shot_type': shotType,
    'pov': pov,
    'info': info,
    'intent': intent,
    'transition': transition,
    'length': length,
    'content': content,
    if (proseStyle.isNotEmpty) 'prose_style': proseStyle,
    if (abstraction.isNotEmpty) 'abstract': abstraction,
    if (voice.isNotEmpty) 'voice': voice,
    if (style.isNotEmpty) 'style': style,
    if (ink.isNotEmpty) 'ink': ink,
    if (endText.isNotEmpty) 'end_text': endText,
    if (text.isNotEmpty) 'text': text,
  };
}

/// 场景模型
class Scene {
  String name;
  String chapterRange;
  int startChapter;
  int endChapter;
  List<Shot> shots;
  String summary;
  String text; // v320：场景锚定切片（划分后按end_text链式物化落库）
  String endText; // v320：本场景结束处分界原句（该句含之前归本场景）
  int globalIndex; // v431：全局场景流序号（全书唯一，弧线分组引用；-1=弧线内局部场景）
  String changes; // v473：本场景关键变化/得失（供弧线概述与closure提炼）

  bool continuation; // v437：跨窗口续写标记——与全局流最后场景合并，不持久化

  Scene({
    required this.name,
    this.chapterRange = '',
    this.startChapter = 0,
    this.endChapter = 0,
    this.shots = const [],
    this.summary = '',
    this.text = '',
    this.endText = '',
    this.globalIndex = -1,
    this.continuation = false,
    this.changes = '',
  });

  factory Scene.fromJson(Map<String, dynamic> json) {
    final range = json['chapter_range'] ?? json['chapterRange'] ?? '';
    final parsedRange = parseChapterRange(range);
    return Scene(
      name: json['name'] ?? json['title'] ?? '',
      chapterRange: range,
      startChapter:
          json['start_chapter'] ?? json['startChapter'] ?? parsedRange.start,
      endChapter: json['end_chapter'] ?? json['endChapter'] ?? parsedRange.end,
      shots:
          (json['shots'] as List?)
              ?.map((e) => Shot.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
      summary: json['summary'] ?? '',
      text: json['text'] ?? '',
      endText: json['end_text'] ?? json['endText'] ?? '',
      globalIndex: json['global_index'] ?? -1,
      continuation: json['continuation'] == true,
      changes: json['changes'] ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
    'name': name,
    'chapter_range': chapterRange,
    'start_chapter': startChapter,
    'end_chapter': endChapter,
    'shots': shots.map((e) => e.toJson()).toList(),
    'summary': summary,
    'text': text,
    'end_text': endText,
    if (globalIndex >= 0) 'global_index': globalIndex,
    'changes': changes,
  };
}

/// 弧线分析结果（含场景和分镜）
class ArcAnalysis {
  int arcNumber;
  String arcTitle;
  String arcSummary;
  List<Scene> scenes;
  Map<String, dynamic>? metadata;
  Arc? arc; // 引用原始弧线对象

  ArcAnalysis({
    required this.arcNumber,
    this.arcTitle = '',
    this.arcSummary = '',
    this.scenes = const [],
    this.metadata,
    this.arc,
  });

  factory ArcAnalysis.fromJson(Map<String, dynamic> json) {
    return ArcAnalysis(
      arcNumber: json['arc_number'] ?? json['arcNumber'] ?? 0,
      arcTitle: json['arc_title'] ?? json['arcTitle'] ?? json['title'] ?? '',
      arcSummary:
          json['arc_summary'] ?? json['arcSummary'] ?? json['summary'] ?? '',
      scenes:
          (json['scenes'] as List?)
              ?.map((e) => Scene.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
      metadata: json['metadata'],
      arc: json.containsKey('number') ? Arc.fromJson(json) : null,
    );
  }

  Map<String, dynamic> toJson() => {
    'arc_number': arcNumber,
    'arc_title': arcTitle,
    'arc_summary': arcSummary,
    'scenes': scenes.map((e) => e.toJson()).toList(),
    if (metadata != null) 'metadata': metadata,
  };
}
