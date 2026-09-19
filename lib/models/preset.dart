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
  });

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
      formatMode: 'compatible',
      apiType: apiType,
    );
  }
}
