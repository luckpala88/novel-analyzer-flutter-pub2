/// 世界书条目
class WBEntry {
  String uid;
  String key; // 触发关键词（逗号分隔）
  String? keySecondary;
  String comment; // 条目名称/注释
  String content;
  bool constant;
  bool selective;
  int order;
  int position;
  bool disable;
  String? arcKey; // 所属弧线
  String? sceneTag; // 所属场景
  String? beatTag; // 所属节拍标记

  WBEntry({
    required this.uid,
    required this.key,
    this.keySecondary,
    required this.comment,
    required this.content,
    this.constant = false,
    this.selective = true,
    this.order = 100,
    this.position = 0,
    this.disable = false,
    this.arcKey,
    this.sceneTag,
    this.beatTag,
  });

  /// 字段归一化：AI返回的key可能是数组（SillyTavern原生格式 ["a","b"]）、
  /// comment/content偶发数组、uid/order是数字——全部容错转成模型字段类型
  /// （v469同款兜底：Array.isArray(e.key)?e.key:[e.key]）
  static String _asStr(dynamic v, [String def = '']) {
    if (v == null) return def;
    if (v is String) return v;
    if (v is List)
      return v.where((e) => e != null).map((e) => e.toString()).join(',');
    if (v is Map) return v.toString();
    return v.toString();
  }

  static bool _asBool(dynamic v, [bool def = false]) {
    if (v == null) return def;
    if (v is bool) return v;
    if (v is String) return v.toLowerCase() == 'true';
    if (v is num) return v != 0;
    return def;
  }

  static int _asInt(dynamic v, [int def = 100]) {
    if (v == null) return def;
    if (v is int) return v;
    if (v is num) return v.round();
    if (v is String) {
      final n = int.tryParse(v);
      if (n != null) return n;
      final d = double.tryParse(v);
      if (d != null) return d.round();
    }
    return def;
  }

  factory WBEntry.fromJson(Map<String, dynamic> json) {
    return WBEntry(
      uid: _asStr(json['uid']),
      key: _asStr(json['key']),
      keySecondary: _asStr(json['keysecondary']),
      comment: _asStr(json['comment']),
      content: _asStr(json['content']),
      constant: _asBool(json['constant']),
      selective: _asBool(json['selective'], true),
      order: _asInt(json['order'], 100),
      position: _asInt(json['position'], 0),
      disable: _asBool(json['disable']),
      arcKey: _asStr(json['arcKey']),
      sceneTag: _asStr(json['sceneTag']),
      beatTag: _asStr(json['beatTag']),
    );
  }

  Map<String, dynamic> toJson() => {
    'uid': uid,
    'key': key,
    if (keySecondary != null) 'keysecondary': keySecondary,
    'comment': comment,
    'content': content,
    'constant': constant,
    'selective': selective,
    'order': order,
    'position': position,
    'disable': disable,
    if (arcKey != null) 'arcKey': arcKey,
    if (sceneTag != null) 'sceneTag': sceneTag,
    if (beatTag != null) 'beatTag': beatTag,
  };
}

/// 世界观体系设定（独立于角色/地点/物品的条目）
/// 存原著规则+功能目的+改编映射+功能校验，支持换皮/推演两种改编方式
class WorldbuildingSystem {
  String id;
  String name; // 体系名（经济/修炼/社会/地理/科技/魔法/其他）
  String originalRules; // 原著规则（结构化文本，AI提取后汇总）
  String functions; // 功能目的（为什么要这样设定）
  String adaptationType; // 'rename' 换皮 / 'deduce' 推演
  String adaptedRules; // 改编后设定
  String functionCheck; // 功能校验（新设定是否实现同样功能）
  String? arcKey; // 来源弧线
  List<String> arcKeys; // 涉及的所有弧线（创作时按当前弧线过滤注入）

  WorldbuildingSystem({
    required this.id,
    required this.name,
    this.originalRules = '',
    this.functions = '',
    this.adaptationType = 'rename',
    this.adaptedRules = '',
    this.functionCheck = '',
    this.arcKey,
    List<String>? arcKeys,
  }) : arcKeys = arcKeys ?? [];

  factory WorldbuildingSystem.fromJson(Map<String, dynamic> json) {
    return WorldbuildingSystem(
      id: json['id']?.toString() ?? '',
      name: json['name']?.toString() ?? '',
      originalRules: json['originalRules']?.toString() ?? '',
      functions: json['functions']?.toString() ?? '',
      adaptationType: json['adaptationType']?.toString() ?? 'rename',
      adaptedRules: json['adaptedRules']?.toString() ?? '',
      functionCheck: json['functionCheck']?.toString() ?? '',
      arcKey: json['arcKey']?.toString(),
      arcKeys:
          (json['arcKeys'] as List<dynamic>?)
              ?.map((e) => e.toString())
              .toList() ??
          [],
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'originalRules': originalRules,
    'functions': functions,
    'adaptationType': adaptationType,
    'adaptedRules': adaptedRules,
    'functionCheck': functionCheck,
    if (arcKey != null) 'arcKey': arcKey,
    'arcKeys': arcKeys,
  };
}

/// 世界书
class WorldBook {
  Map<String, WBEntry> entries;
  Map<String, String> arcStatus;
  String requirements;
  Map<String, String> arcRequirements;
  Map<String, String> sceneRequirements;
  bool deduceMode;
  /// v225：改编模式三选一：'auto'（按有无要求自动判断，默认兼容旧数据）/
  /// 'original'（强制原样整理）/ 'reskin'（换皮）/ 'deduce'（推演）
  String adaptMode;
  String adaptBible; // v566：改编圣经（累积式全书总结v626，全书级一致性的生成依据）
  String originalBible; // v627：原著圣经（原著因果链+人物对应+事实基准，静态不动，改编圣经初版的推导来源）
  Map<String, String> deduceSkeletons;
  List<WorldbuildingSystem> systems; // 世界观体系设定
  Map<String, String> arcDeclarations; // per-弧线改编声明（场景功能声明/禁令/行为模式卡，生成条目的指导）
  Map<String, bool> arcDeclEnabled; // v385：per-弧线声明是否注入生成（默认true，不勾选=声明保留但不注入）
  Map<String, String> sceneDeclarations; // v573：场景改编声明（key=arcKey_si，场景层注入）

  /// v658：弧线/场景重扫后清空改编派生数据——arcStatus等按弧线号存,
  /// 重扫后新弧线撞旧状态会显示"已生成"且增量模式跳过改编(幽灵状态)
  void clearAdaptDerived() {
    entries.clear();
    arcStatus.clear();
    arcRequirements.clear();
    sceneRequirements.clear();
    deduceSkeletons.clear();
    arcDeclarations.clear();
    arcDeclEnabled.clear();
    sceneDeclarations.clear();
    adaptBible = '';
    // originalBible保留：原著圣经源于原著静态因果链,与改编重扫无关
  }
  Map<String, String> arcRequirementsAI; // v588：弧线改编要求AI优化稿（独立框，勾选才生效）
  Map<String, String> sceneRequirementsAI; // v588：场景改编要求AI优化稿
  Map<String, bool> reqEnabled; // v588：要求勾选开关 key=u_弧线/a_弧线/u_弧线_si/a_弧线_si（u=用户稿默认勾选 a=AI稿默认不勾）
  Map<String, String> creationDeclarations; // v582：创作声明（创作页独立生成，替代改编声明注入创作）
  Map<String, bool> creationDeclEnabled; // v582：创作声明注入开关
  String nameMapping; // v388：名称映射表（每行"原著名→新名（定位）"——生成端保持原著名，输出层替换）
  String nameMapReq; // v393：起名要求（指定主角新名/命名风格，映射表生成与增量抽取共用）
  Set<String> nameMapManual; // v706：手动添加的映射左列（重拟右列时锁定不动，优先级最高）

  WorldBook({
    this.entries = const {},
    this.arcStatus = const {},
    this.requirements = '',
    this.arcRequirements = const {},
    this.sceneRequirements = const {},
    this.deduceMode = false,
    this.adaptMode = 'auto',
    this.adaptBible = '',
    this.originalBible = '',
    this.deduceSkeletons = const {},
    this.systems = const [],
    Map<String, String>? arcDeclarations,
    Map<String, bool>? arcDeclEnabled,
    Map<String, String>? sceneDeclarations,
    Map<String, String>? arcRequirementsAI,
    Map<String, String>? sceneRequirementsAI,
    Map<String, bool>? reqEnabled,
    Map<String, String>? creationDeclarations,
    Map<String, bool>? creationDeclEnabled,
    this.nameMapping = '',
    this.nameMapReq = '',
    Set<String>? nameMapManual,
  }) : nameMapManual = nameMapManual ?? {}, arcDeclarations = arcDeclarations ?? {},
       arcDeclEnabled = arcDeclEnabled ?? {},
       sceneDeclarations = sceneDeclarations ?? {},
       arcRequirementsAI = arcRequirementsAI ?? {},
       sceneRequirementsAI = sceneRequirementsAI ?? {},
       reqEnabled = reqEnabled ?? {},
       creationDeclarations = creationDeclarations ?? {},
       creationDeclEnabled = creationDeclEnabled ?? {};

  /// v588：生效改编要求——用户稿+AI稿按各自勾选拼接（用户稿默认勾选，AI稿默认不勾）
  String combinedReq(String userKey, {String? aiKey}) {
    final a = aiKey ?? userKey;
    final u = (arcRequirements[userKey] ?? '').trim();
    final ai = (arcRequirementsAI[a] ?? '').trim();
    final uOn = reqEnabled['u_$userKey'] ?? true;
    final aiOn = reqEnabled['a_$a'] ?? false;
    return [
      if (u.isNotEmpty && uOn) u,
      if (ai.isNotEmpty && aiOn) ai,
    ].join('\n');
  }

  /// v588：场景版生效要求（sceneRequirements/sceneRequirementsAI）
  String combinedSceneReq(String key) {
    final u = (sceneRequirements[key] ?? '').trim();
    final ai = (sceneRequirementsAI[key] ?? '').trim();
    final uOn = reqEnabled['u_$key'] ?? true;
    final aiOn = reqEnabled['a_$key'] ?? false;
    return [
      if (u.isNotEmpty && uOn) u,
      if (ai.isNotEmpty && aiOn) ai,
    ].join('\n');
  }

  factory WorldBook.fromJson(Map<String, dynamic> json) {
    final entriesRaw = json['entries'] as Map<String, dynamic>? ?? {};
    return WorldBook(
      entries: entriesRaw.map(
        (k, v) => MapEntry(k, WBEntry.fromJson(v as Map<String, dynamic>)),
      ),
      arcStatus:
          (json['arcStatus'] as Map<String, dynamic>?)?.map(
            (k, v) => MapEntry(k, v.toString()),
          ) ??
          {},
      requirements: json['requirements'] ?? '',
      arcRequirements:
          (json['arcRequirements'] as Map<String, dynamic>?)?.map(
            (k, v) => MapEntry(k, v.toString()),
          ) ??
          {},
      sceneRequirements:
          (json['sceneRequirements'] as Map<String, dynamic>?)?.map(
            (k, v) => MapEntry(k, v.toString()),
          ) ??
          {},
      deduceMode: json['deduceMode'] == true,
      adaptMode: json['adaptMode'] ?? 'auto',
      adaptBible: json['adaptBible'] ?? '',
      originalBible: json['originalBible'] ?? '',
      sceneDeclarations: (json['sceneDeclarations'] as Map<String, dynamic>?)?.map((k, v) => MapEntry(k, v.toString())) ?? {},
      arcRequirementsAI: (json['arcRequirementsAI'] as Map<String, dynamic>?)?.map((k, v) => MapEntry(k, v.toString())) ?? {},
      sceneRequirementsAI: (json['sceneRequirementsAI'] as Map<String, dynamic>?)?.map((k, v) => MapEntry(k, v.toString())) ?? {},
      reqEnabled: (json['reqEnabled'] as Map<String, dynamic>?)?.map((k, v) => MapEntry(k, v == true)) ?? {},
      creationDeclarations: (json['creationDeclarations'] as Map<String, dynamic>?)?.map((k, v) => MapEntry(k, v.toString())) ?? {},
      creationDeclEnabled: (json['creationDeclEnabled'] as Map<String, dynamic>?)?.map((k, v) => MapEntry(k, v == true)) ?? {},
      deduceSkeletons:
          (json['deduceSkeletons'] as Map<String, dynamic>?)?.map(
            (k, v) => MapEntry(k, v.toString()),
          ) ??
          {},
      systems:
          (json['systems'] as List<dynamic>?)
              ?.map(
                (e) => WorldbuildingSystem.fromJson(e as Map<String, dynamic>),
              )
              .toList() ??
          [],
      arcDeclarations: Map.of(
        (json['arcDeclarations'] as Map<String, dynamic>?)?.map(
              (k, v) => MapEntry(k, v.toString()),
            ) ??
            {},
      ),
      arcDeclEnabled: Map.of(
        (json['arcDeclEnabled'] as Map<String, dynamic>?)?.map(
              (k, v) => MapEntry(k, v == true),
            ) ??
            {},
      ),
      nameMapping: (json['nameMapping'] ?? '').toString(),
      nameMapReq: (json['nameMapReq'] ?? '').toString(),
      nameMapManual: ((json['nameMapManual'] as List<dynamic>?) ?? const [])
          .map((e) => e.toString())
          .toSet(),
    );
  }

  Map<String, dynamic> toJson() => {
    'entries': entries.map((k, v) => MapEntry(k, v.toJson())),
    'arcStatus': arcStatus,
    'requirements': requirements,
    'arcRequirements': arcRequirements,
    'sceneRequirements': sceneRequirements,
    'deduceMode': deduceMode,
    'adaptMode': adaptMode,
    'adaptBible': adaptBible,
    if (originalBible.isNotEmpty) 'originalBible': originalBible,
    if (sceneDeclarations.isNotEmpty)
      'sceneDeclarations': sceneDeclarations,
    if (arcRequirementsAI.isNotEmpty)
      'arcRequirementsAI': arcRequirementsAI,
    if (sceneRequirementsAI.isNotEmpty)
      'sceneRequirementsAI': sceneRequirementsAI,
    if (reqEnabled.isNotEmpty)
      'reqEnabled': reqEnabled,
    if (creationDeclarations.isNotEmpty)
      'creationDeclarations': creationDeclarations,
    if (creationDeclEnabled.isNotEmpty)
      'creationDeclEnabled': creationDeclEnabled,
    'deduceSkeletons': deduceSkeletons,
    'systems': systems.map((s) => s.toJson()).toList(),
    'arcDeclarations': arcDeclarations,
    'arcDeclEnabled': arcDeclEnabled,
    if (nameMapping.isNotEmpty) 'nameMapping': nameMapping,
    if (nameMapReq.isNotEmpty) 'nameMapReq': nameMapReq,
    if (nameMapManual.isNotEmpty)
      'nameMapManual': nameMapManual.toList(),
  };
}
