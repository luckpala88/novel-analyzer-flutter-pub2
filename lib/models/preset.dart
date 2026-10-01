import 'api_config.dart';

/// 预设模型
class Preset {
  String name;
  bool useCustom;
  String provider;
  String model;
  String apiBase;
  String apiKey;
  String customApiKey;
  String customModel;
  String apiType;
  double temperature;
  int maxTokens;
  // v983：补齐ApiConfig全量字段——此前预设丢自定义2/槽位/builtinStash/
  // paramStash/formatMode/rpmLimit，恢复后配置不完整
  String custom2ApiKey;
  String custom2ApiBase;
  String custom2Model;
  String customSlot; // 'custom'(默认)/'custom2'
  String formatMode; // 'json'/'compatible'
  int rpmLimit; // 0=不限
  Map<String, dynamic> builtinStash; // per-provider key/model stash
  Map<String, dynamic> paramStash; // per-provider参数stash

  Preset({
    required this.name,
    this.useCustom = false,
    this.provider = 'zhipu',
    this.model = '',
    this.apiBase = '',
    this.apiKey = '',
    this.customApiKey = '',
    this.customModel = '',
    this.apiType = 'openai',
    this.temperature = 0.3,
    this.maxTokens = 8192,
    this.custom2ApiKey = '',
    this.custom2ApiBase = '',
    this.custom2Model = '',
    this.customSlot = 'custom',
    this.formatMode = 'compatible',
    this.rpmLimit = 0,
    Map<String, dynamic>? builtinStash,
    Map<String, dynamic>? paramStash,
  })  : builtinStash = builtinStash ?? {},
        paramStash = paramStash ?? {};

  factory Preset.fromJson(Map<String, dynamic> json) {
    return Preset(
      name: json['name'] ?? '',
      useCustom: json['useCustom'] ?? false,
      provider: json['provider'] ?? 'zhipu',
      model: json['model'] ?? '',
      apiBase: json['apiBase'] ?? '',
      apiKey: json['apiKey'] ?? '',
      customApiKey: json['customApiKey'] ?? '',
      customModel: json['customModel'] ?? '',
      apiType: json['apiType'] ?? 'openai',
      temperature: (json['temperature'] ?? 0.3).toDouble(),
      maxTokens: json['maxTokens'] ?? 8192,
      // v983：新字段——旧预设JSON缺失走默认值
      custom2ApiKey: json['custom2ApiKey'] ?? '',
      custom2ApiBase: json['custom2ApiBase'] ?? '',
      custom2Model: json['custom2Model'] ?? '',
      customSlot: json['customSlot'] ?? 'custom',
      formatMode: json['formatMode'] ?? 'compatible',
      rpmLimit: json['rpmLimit'] ?? 0,
      builtinStash: json['builtinStash'] != null
          ? Map<String, dynamic>.from(json['builtinStash'] as Map)
          : {},
      paramStash: json['paramStash'] != null
          ? Map<String, dynamic>.from(json['paramStash'] as Map)
          : {},
    );
  }

  Map<String, dynamic> toJson() => {
    'name': name,
    'useCustom': useCustom,
    'provider': provider,
    'model': model,
    'apiBase': apiBase,
    'apiKey': apiKey,
    'customApiKey': customApiKey,
    'customModel': customModel,
    'apiType': apiType,
    'temperature': temperature,
    'maxTokens': maxTokens,
    // v983：新字段全量落盘
    'custom2ApiKey': custom2ApiKey,
    'custom2ApiBase': custom2ApiBase,
    'custom2Model': custom2Model,
    'customSlot': customSlot,
    'formatMode': formatMode,
    'rpmLimit': rpmLimit,
    if (builtinStash.isNotEmpty) 'builtinStash': builtinStash,
    if (paramStash.isNotEmpty) 'paramStash': paramStash,
  };

  /// 从 ApiConfig 创建预设
  factory Preset.fromApiConfig(String name, ApiConfig config) {
    return Preset(
      name: name,
      useCustom: config.useCustom,
      provider: config.provider,
      model: config.model,
      apiBase: config.apiBase,
      apiKey: config.apiKey,
      customApiKey: config.customApiKey,
      customModel: config.customModel,
      apiType: config.apiType,
      temperature: config.temperature,
      maxTokens: config.maxTokens,
      // v983：全量捕获（含stash拷贝防引用串改）
      custom2ApiKey: config.custom2ApiKey,
      custom2ApiBase: config.custom2ApiBase,
      custom2Model: config.custom2Model,
      customSlot: config.customSlot,
      formatMode: config.formatMode,
      rpmLimit: config.rpmLimit,
      builtinStash: config.builtinStash.isEmpty
          ? {}
          : Map<String, dynamic>.from(config.builtinStash),
      paramStash: config.paramStash.isEmpty
          ? {}
          : Map<String, dynamic>.from(config.paramStash),
    );
  }

  /// 转为 ApiConfig
  ApiConfig toApiConfig() {
    return ApiConfig(
      useCustom: useCustom,
      provider: provider,
      apiKey: apiKey,
      model: model,
      apiBase: apiBase,
      customApiKey: customApiKey,
      customModel: customModel,
      temperature: temperature,
      maxTokens: maxTokens,
      // v983：不再写死compatible——恢复存时的真实值；补全自定义2/槽位/限流/stash
      formatMode: formatMode,
      apiType: apiType,
      custom2ApiKey: custom2ApiKey,
      custom2ApiBase: custom2ApiBase,
      custom2Model: custom2Model,
      customSlot: customSlot,
      rpmLimit: rpmLimit,
      builtinStash: builtinStash.isEmpty
          ? {}
          : Map<String, dynamic>.from(builtinStash),
      paramStash: paramStash.isEmpty
          ? {}
          : Map<String, dynamic>.from(paramStash),
    );
  }
}
