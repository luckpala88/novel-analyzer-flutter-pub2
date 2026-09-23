/// API配置模型
class ApiConfig {
  bool useCustom;
  String provider;

  /// 内置提供商per-provider stash：切换不清key（v469 provider_key_xxx对齐），{provider: {'apiKey':..,'model':..}}
  Map<String, dynamic> builtinStash; // zhipu, custom
  String apiKey;
  String model;
  String apiBase;
  String customApiKey;
  String customModel;
  // 自定义2（第二中转）：独立key/base/model，与自定义1并存可快速切换
  String custom2ApiKey;
  String custom2ApiBase;
  String custom2Model;
  String customSlot; // useCustom=true时选哪个槽：'custom'(默认)/'custom2'
  double temperature;
  int maxTokens;
  String formatMode; // 'json' or 'compatible'
  String apiType; // 'openai' or 'claude'
  int rpmLimit; // 每分钟最大请求数（0=不限流；中转站RPM限制用）
  // v679：per-provider参数stash——{providerId: {temperature,maxTokens,formatMode,apiType,rpmLimit}}
  // 切换供应商时旧参数入stash、新参数从stash恢复，参数跟着供应商走不再全局
  Map<String, dynamic> paramStash;
  /// 当前供应商唯一标识：内置=zhipu/deepseek/gemini；自定义=custom/custom2
  String get providerId =>
      useCustom ? (customSlot == 'custom2' ? 'custom2' : 'custom') : provider;
  /// 当前供应商参数入stash（在改参数后/切走前调用）
  void stashParams() {
    paramStash[providerId] = {
      'temperature': temperature,
      'maxTokens': maxTokens,
      'formatMode': formatMode,
      'apiType': apiType,
      'rpmLimit': rpmLimit,
    };
  }

  /// 从stash恢复当前供应商参数（切到新供应商时调用；没有→保持现值=首次使用）
  void loadParams() {
    final p = paramStash[providerId];
    if (p is! Map) return;
    if (p['temperature'] != null) temperature = (p['temperature'] as num).toDouble();
    if (p['maxTokens'] != null) maxTokens = p['maxTokens'] as int;
    if (p['formatMode'] != null) formatMode = p['formatMode'] as String;
    if (p['apiType'] != null) apiType = p['apiType'] as String;
    if (p['rpmLimit'] != null) rpmLimit = p['rpmLimit'] as int;
  }

  ApiConfig({
    this.useCustom = false,
    this.provider = 'zhipu',
    this.apiKey = '',
    this.model = '',
    Map<String, dynamic>? builtinStash,
    this.apiBase = '',
    this.customApiKey = '',
    this.customModel = '',
    this.custom2ApiKey = '',
    this.custom2ApiBase = '',
    this.custom2Model = '',
    this.customSlot = 'custom',
    this.temperature = 0.3,
    this.maxTokens = 8192,
    this.formatMode = 'compatible',
    this.apiType = 'openai',
    this.rpmLimit = 5,
    Map<String, dynamic>? paramStash,
  }) : builtinStash = builtinStash ?? {},
       paramStash = paramStash ?? {};

  factory ApiConfig.fromJson(Map<String, dynamic> json) {
    return ApiConfig(
      useCustom: json['useCustom'] ?? false,
      provider: json['provider'] ?? 'zhipu',
      apiKey: json['apiKey'] ?? '',
      model: json['model'] ?? '',
      builtinStash: json['builtinStash'] is Map
          ? Map<String, dynamic>.from(json['builtinStash'])
          : {},
      apiBase: json['apiBase'] ?? '',
      customApiKey: json['customApiKey'] ?? '',
      customModel: json['customModel'] ?? '',
      custom2ApiKey: json['custom2ApiKey'] ?? '',
      custom2ApiBase: json['custom2ApiBase'] ?? '',
      custom2Model: json['custom2Model'] ?? '',
      customSlot: json['customSlot'] ?? 'custom',
      temperature: (json['temperature'] ?? 0.3).toDouble(),
      maxTokens: json['maxTokens'] ?? 8192,
      formatMode: json['formatMode'] ?? 'compatible',
      apiType: json['apiType'] ?? 'openai',
      rpmLimit: json['rpmLimit'] ?? 5,
      paramStash: json['paramStash'] is Map
          ? Map<String, dynamic>.from(json['paramStash'])
          : {},
    );
  }

  Map<String, dynamic> toJson() => {
    'useCustom': useCustom,
    'provider': provider,
    'apiKey': apiKey,
    'model': model,
    'apiBase': apiBase,
    'customApiKey': customApiKey,
    'customModel': customModel,
    'custom2ApiKey': custom2ApiKey,
    'custom2ApiBase': custom2ApiBase,
    'custom2Model': custom2Model,
    'customSlot': customSlot,
    'temperature': temperature,
    'maxTokens': maxTokens,
    'formatMode': formatMode,
    'rpmLimit': rpmLimit,
    'apiType': apiType,
    'builtinStash': builtinStash,
    'paramStash': paramStash,
  };

  /// 获取实际生效的API配置
  /// useCustom=false→内置；true→按customSlot选槽（custom/custom2）
  String get effectiveApiKey => !useCustom
      ? apiKey
      : (customSlot == 'custom2' ? custom2ApiKey : customApiKey);
  String get effectiveModel => !useCustom
      ? model
      : (customSlot == 'custom2' ? custom2Model : customModel);

  /// 内置提供商官方端点（v469 BUILTIN_PROVIDERS对齐+Gemini官方OpenAI兼容层）
  static const Map<String, String> builtinBases = {
    'zhipu': 'https://open.bigmodel.cn/api/paas/v4',
    'deepseek': 'https://api.deepseek.com/v1',
    'gemini': 'https://generativelanguage.googleapis.com/v1beta/openai',
  };

  String get effectiveApiBase {
    if (useCustom && customSlot == 'custom2') {
      return custom2ApiBase.isNotEmpty ? custom2ApiBase : apiBase;
    }
    if (useCustom && apiBase.isNotEmpty) return apiBase;
    if (builtinBases.containsKey(provider)) return builtinBases[provider]!;
    return apiBase;
  }

  String get effectiveApiType => useCustom ? apiType : 'openai';
}
