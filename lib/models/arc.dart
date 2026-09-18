import '../utils/chinese_number.dart';

/// 弧线模型（扫描结果）
class Arc {
  int number; // 弧线编号
  String title;
  String chapterRange; // 如 "第1-20章" 或 "1-7"
  int startChapter;
  int endChapter;
  String status; // 'complete', 'incomplete', ''
  String summary; // 弧线总结
  String coreChange; // 核心变化
  String? closurePoint; // 闭合判断点
  String? closureEvent; // v439：闭合的不可逆变化（分组产出）
  String? closureEvidence; // v439：闭合依据（a落定b为何是这幕c提前会怎样）
  String focusCharacter; // v283：视角主角（focus_character，群像书多线判定的锚点）
  String closeType; // v283：'real'=真闭合（不可逆变化）/ 'pseudo'=伪闭合（该线叙事段结束且切线）
  String boundaryAnchor; // v293：闭合章内分界原句（该句前含属本弧线、后属下一弧线），弧线精准正文切分锚点
  int boundaryOffset; // v294：解析时定位好的切分点字符偏移（章文本内，锚点句末尾）；-1=未定位
  String text; // v294：弧线精准正文（扫描闭合时物化落库，场景/分镜直接读）
  // v429：尾修剪偏移——场景划分完成后，共享章内"最后场景end_text之后"的字符
  // 偏移（相对闭合章title+content文本）。-1=未修剪（弧线text=章级原样）。
  // 下一弧线物化时从该偏移取共享章文本（A剪掉的部分=B的开头，无丢失无重复）
  int tailTrim;
  int sceneFrom; // v437：弧线内起始全局场景序号（1-based，分组产出；-1=旧数据）
  int sceneTo; // v437：弧线内结束全局场景序号

  Arc({
    required this.number,
    required this.title,
    required this.chapterRange,
    this.startChapter = 0,
    this.endChapter = 0,
    this.status = '',
    this.summary = '',
    this.coreChange = '',
    this.closurePoint,
    this.closureEvent,
    this.closureEvidence,
    this.focusCharacter = '',
    this.closeType = 'real',
    this.boundaryAnchor = '',
    this.boundaryOffset = -1,
    this.text = '',
    this.tailTrim = -1,
    this.sceneFrom = -1,
    this.sceneTo = -1,
  });

  factory Arc.fromJson(Map<String, dynamic> json) {
    final range = json['chapter_range'] ?? json['chapterRange'] ?? '';
    final parsedRange = parseChapterRange(range);
    return Arc(
      number: json['number'] ?? 0,
      title: json['title'] ?? '',
      chapterRange: range,
      startChapter:
          json['start_chapter'] ?? json['startChapter'] ?? parsedRange.start,
      endChapter: json['end_chapter'] ?? json['endChapter'] ?? parsedRange.end,
      status: json['status'] ?? '',
      summary: json['summary'] ?? '',
      coreChange: json['core_change'] ?? json['coreChange'] ?? '',
      closurePoint: json['closure_point'] ?? json['closurePoint'],
      closureEvent: json['closure_event'] ?? json['closureEvent'],
      closureEvidence: json['closure_evidence'] ?? json['closureEvidence'],
      focusCharacter:
          json['focus_character'] ?? json['focusCharacter'] ?? '',
      closeType: json['close_type'] ?? json['closeType'] ?? 'real',
      boundaryAnchor:
          json['boundary_text'] ?? json['boundaryAnchor'] ?? '',
      boundaryOffset: json['boundary_offset'] ?? -1,
      sceneFrom: json['scene_from'] ?? json['sceneFrom'] ?? -1,
      sceneTo: json['scene_to'] ?? json['sceneTo'] ?? -1,
      text: json['text'] ?? '',
      tailTrim: json['tail_trim'] ?? -1,
    );
  }

  Map<String, dynamic> toJson() => {
    'number': number,
    'title': title,
    'chapter_range': chapterRange,
    'start_chapter': startChapter,
    'end_chapter': endChapter,
    'status': status,
    'summary': summary,
    'core_change': coreChange,
    if (closurePoint != null) 'closure_point': closurePoint,
    if (closureEvent != null) 'closure_event': closureEvent,
    if (closureEvidence != null) 'closure_evidence': closureEvidence,
    if (focusCharacter.isNotEmpty) 'focus_character': focusCharacter,
    if (closeType != 'real') 'close_type': closeType,
    if (boundaryAnchor.isNotEmpty) 'boundary_text': boundaryAnchor,
    if (boundaryOffset >= 0) 'boundary_offset': boundaryOffset,
    if (tailTrim >= 0) 'tail_trim': tailTrim,
    if (sceneFrom >= 0) 'scene_from': sceneFrom,
    if (sceneTo >= 0) 'scene_to': sceneTo,
    if (text.isNotEmpty) 'text': text,
  };
}

/// 扫描结果
class ArcScan {
  List<Arc> arcs;
  int scannedChapterCount;
  String overallSummary;
  Map<String, dynamic>? patternSummary;
  String? lastScanTime;

  ArcScan({
    this.arcs = const [],
    this.scannedChapterCount = 0,
    this.overallSummary = '',
    this.patternSummary,
    this.lastScanTime,
  });

  factory ArcScan.fromJson(Map<String, dynamic> json) {
    return ArcScan(
      arcs:
          (json['arcs'] as List?)
              ?.map((e) => Arc.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
      scannedChapterCount: json['scannedChapterCount'] ?? 0,
      overallSummary: json['overall_summary'] ?? json['overallSummary'] ?? '',
      patternSummary: json['pattern_summary'] ?? json['patternSummary'],
      lastScanTime: json['lastScanTime'],
    );
  }

  Map<String, dynamic> toJson() => {
    'arcs': arcs.map((e) => e.toJson()).toList(),
    'scannedChapterCount': scannedChapterCount,
    'overall_summary': overallSummary,
    if (patternSummary != null) 'pattern_summary': patternSummary,
    if (lastScanTime != null) 'lastScanTime': lastScanTime,
  };
}
