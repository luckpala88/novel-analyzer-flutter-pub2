/// 创作文档模型
class WritingItem {
  String key; // 文件名key（arcKey_sceneIdx）
  String arcKey;
  int sceneIdx;
  String sceneName;
  String chapterRange;
  String content;
  String prompt; // 使用的prompt
  DateTime? createdAt;
  int version; // 当前版本号（重创+1）
  List<WritingItem> versions; // 历史版本
  String model; // 生成时用的模型（txt备注用）
  double temperature; // v361：生成时用的温度（txt备注用）
  bool draft; // v548：逐镜实时保存草稿标记（中断保留部分成果）
  String genMode; // v733：生成模式备注（"逐镜·自由"等，列表直显）

  WritingItem({
    required this.key,
    required this.arcKey,
    required this.sceneIdx,
    this.sceneName = '',
    this.chapterRange = '',
    this.content = '',
    this.prompt = '',
    this.createdAt,
    this.version = 1,
    List<WritingItem>? versions,
    this.model = '',
    this.temperature = 0.3,
    this.draft = false,
    this.genMode = '',
  }) : versions = versions ?? [];

  factory WritingItem.fromJson(Map<String, dynamic> json) {
    return WritingItem(
      key: json['key'] ?? '',
      arcKey: json['arcKey'] ?? '',
      sceneIdx: json['sceneIdx'] ?? 0,
      sceneName: json['sceneName'] ?? '',
      chapterRange: json['chapterRange'] ?? '',
      content: json['content'] ?? '',
      prompt: json['prompt'] ?? '',
      createdAt: json['createdAt'] != null
          ? DateTime.tryParse(json['createdAt'])
          : null,
      version: json['version'] ?? 1,
      versions:
          (json['versions'] as List?)
              ?.map((e) => WritingItem.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
      model: json['model'] ?? '',
      temperature: (json['temperature'] ?? 0.3).toDouble(),
      draft: json['draft'] == true,
      genMode: (json['genMode'] ?? '').toString(),
    );
  }

  Map<String, dynamic> toJson() => {
    'key': key,
    'arcKey': arcKey,
    'sceneIdx': sceneIdx,
    'sceneName': sceneName,
    'chapterRange': chapterRange,
    'content': content,
    'prompt': prompt,
    if (createdAt != null) 'createdAt': createdAt!.toIso8601String(),
    'version': version,
    'versions': versions.map((e) => e.toJson()).toList(),
    'model': model,
    'temperature': temperature,
    if (draft) 'draft': true,
  };
}
