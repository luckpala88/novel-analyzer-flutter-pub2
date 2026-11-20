import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/api_config.dart';
import '../utils/v469_style.dart';
import '../models/preset.dart';
import '../state/app_state.dart';
import 'v119_ui.dart';

/// v1544：API模型胶囊——页顶独立一行最左；键面=当前模型名（去"⚙ API"字样）；
/// 擎天供应商顺带显示余额数字（绿色，直读API设置面板同一份余额历史，同key掩码校验）
class ApiModelButton extends StatelessWidget {
  final ApiConfig config;
  final String section;
  final String title;
  const ApiModelButton({
    super.key,
    required this.config,
    required this.section,
    required this.title,
  });

  @override
  Widget build(BuildContext context) {
    final model = config.useCustom
        ? (config.customSlot == 'custom2'
              ? config.custom2Model
              : config.customModel)
        : config.model;
    String bal = '';
    if (config.provider == 'qingtian') {
      try {
        final raw = context
            .read<AppState>()
            .storage
            .readGlobalJson('qingtian_balance_history');
        final list = (raw is List)
            ? raw
                  .whereType<Map>()
                  .map((e) => Map<String, dynamic>.from(e))
                  .toList()
            : <Map<String, dynamic>>[];
        if (list.isNotEmpty &&
            list.last['key'] ==
                _ApiConfigPanelStateAccess.maskKey(config.effectiveApiKey)) {
          final v = (list.last['v'] as num?)?.toDouble();
          if (v != null && v >= 0) bal = v.toStringAsFixed(1);
        }
      } catch (_) {}
    }
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: () => showV119Sheet(
          context,
          title: title,
          child: ApiConfigPanel(config: config, section: section),
        ),
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
          decoration: BoxDecoration(
            border: Border.all(
              color: Theme.of(context).colorScheme.outline.withOpacity(0.5),
            ),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text.rich(
            TextSpan(
              children: [
                TextSpan(
                  text: model.isEmpty ? '⚙' : model,
                  style: TextStyle(
                    fontSize: 10.5,
                    color: Theme.of(context).colorScheme.onSurface,
                  ),
                ),
                if (bal.isNotEmpty)
                  TextSpan(
                    text: '  $bal',
                    style: TextStyle(
                      fontSize: 10.5,
                      fontWeight: FontWeight.w700,
                      color: Colors.green.shade800,
                    ),
                  ),
              ],
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ),
    );
  }
}

/// v1544：maskKey对外开放壳（ApiModelButton同文件复用）
class _ApiConfigPanelStateAccess {
  static String maskKey(String k) {
    if (k.length <= 8) return '•' * k.length;
    return '${k.substring(0, 4)}••••${k.substring(k.length - 4)}';
  }
}

class ApiConfigPanel extends StatefulWidget {
  final ApiConfig config;
  final String section;

  const ApiConfigPanel({
    super.key,
    required this.config,
    required this.section,
  });

  @override
  State<ApiConfigPanel> createState() => _ApiConfigPanelState();
}

class _ApiConfigPanelState extends State<ApiConfigPanel> {
  late ApiConfig _config;
  bool _fetchingModels = false;
  List<String> _fetchedModels = [];
  String _fetchStatus = '';
  // controller提升为字段：即时保存触发notifyListeners重建时
  // 每次build新建controller会导致光标跳回开头，输入框没法用
  final _apiKeyCtrl = TextEditingController();
  final _apiBaseCtrl = TextEditingController();
  final _customKeyCtrl = TextEditingController();
  final _customModelCtrl = TextEditingController();
  final _custom2BaseCtrl = TextEditingController();
  final _custom2KeyCtrl = TextEditingController();
  final _custom2ModelCtrl = TextEditingController();
  final _modelCtrl = TextEditingController();
  // v1224：公益站baseUrl可编辑（默认gcli.ggchan.dev，改值存builtinStash[provider]['baseUrl']）
  final _gyzBaseCtrl = TextEditingController();
  // v1529：擎天余额显示（进面板自动查一次+查余额键手动刷新）
  String _balanceText = '';
  bool _fetchingBalance = false;
  // v1530：余额历史（最近3次，全局存储按key掩码隔离，换key自动重置）
  List<Map<String, dynamic>> _balanceHistory = [];

  @override
  void initState() {
    super.initState();
    _config = ApiConfig.fromJson(widget.config.toJson());
    _syncControllers();
    // 已有Key：自动拉取模型列表（内置/自定义槽都拉，不预填写死）
    if (_config.effectiveApiKey.isNotEmpty) {
      Future.microtask(() {
        if (mounted) _fetchModels(auto: true);
      });
    }
    // v1529：擎天供应商进面板自动查一次余额（用户裁决：点进去就看）
    if (_config.provider == 'qingtian' && _config.effectiveApiKey.isNotEmpty) {
      // v1530：先载入历史余额显示（不等查询返回）
      _loadBalanceHistory();
      Future.microtask(() {
        if (mounted) _fetchBalance();
      });
    }
  }

  /// v1530：从全局存储载入余额历史（仅同key掩码的有效）
  void _loadBalanceHistory() {
    try {
      final raw = context
          .read<AppState>()
          .storage
          .readGlobalJson('qingtian_balance_history');
      final list = (raw is List)
          ? raw
                .whereType<Map>()
                .map((e) => Map<String, dynamic>.from(e))
                .toList()
          : <Map<String, dynamic>>[];
      if (list.isNotEmpty &&
          list.last['key'] != _maskKey(_config.effectiveApiKey)) {
        return; // 换key了，旧历史不显示
      }
      _balanceHistory = list;
    } catch (_) {}
  }

  /// v1529：擎天余额查询——POST key到站点查询页，显示剩余额度
  Future<void> _fetchBalance() async {
    final key = _config.effectiveApiKey;
    if (key.isEmpty) {
      setState(() => _balanceText = '先填Key');
      return;
    }
    setState(() => _fetchingBalance = true);
    try {
      final (msg, remaining) = await context
          .read<AppState>()
          .api
          .fetchQingtianBalance(apiKey: key);
      if (mounted) {
        setState(() {
          _balanceText = msg;
          _fetchingBalance = false;
        });
        if (remaining >= 0) _recordBalance(key, remaining);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _balanceText = '查询失败：$e';
          _fetchingBalance = false;
        });
      }
    }
  }

  /// v1530：余额历史落盘+差额计算——全局存储（余额跟着key不跟书），
  /// key掩码不一致=换了key，历史重置；最多存3次
  void _recordBalance(String key, double remaining) {
    try {
      final storage = context.read<AppState>().storage;
      final masked = _maskKey(key);
      final now = DateTime.now();
      final t =
          '${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')} '
          '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
      dynamic raw = storage.readGlobalJson('qingtian_balance_history');
      var list = (raw is List)
          ? raw
                .whereType<Map>()
                .map((e) => Map<String, dynamic>.from(e))
                .toList()
          : <Map<String, dynamic>>[];
      // 换key：旧历史属于旧key，差额对比无意义→重置
      if (list.isNotEmpty && list.last['key'] != masked) list = [];
      final prev = list.isNotEmpty ? (list.last['v'] as num).toDouble() : null;
      final diff = prev == null ? null : remaining - prev;
      // v1536：与上次余额相同=期间无消耗，不落新记录——进面板自动查询
      // 不再把更老的记录冲掉（差额对比窗口保持有意义）
      if (prev != remaining) {
        list.add({'v': remaining, 't': t, 'key': masked});
        while (list.length > 5) {
          list.removeAt(0);
        }
        storage.writeGlobalJson('qingtian_balance_history', list);
      }
      final diffStr = diff == null
          ? ''
          : '（较上次${diff >= 0 ? '+' : ''}${diff.toStringAsFixed(1)}）';
      setState(() {
        _balanceText = '剩余额度：${remaining.toStringAsFixed(1)}$diffStr';
        _balanceHistory = list;
      });
    } catch (_) {
      // 历史读写失败不影响余额显示
    }
  }

  @override
  void dispose() {
    _saveDebounce?.cancel();
    _apiKeyCtrl.dispose();
    _apiBaseCtrl.dispose();
    _customKeyCtrl.dispose();
    _customModelCtrl.dispose();
    _custom2BaseCtrl.dispose();
    _custom2KeyCtrl.dispose();
    _custom2ModelCtrl.dispose();
    _modelCtrl.dispose();
    _gyzBaseCtrl.dispose();
    _autoFetchDebounce?.cancel();
    super.dispose();
  }

  /// 内置提供商显示名（v469对齐+Gemini官方；v1224统一引用ApiConfig.providerLabels单一事实源）
  String get _providerLabel =>
      ApiConfig.providerLabels[_config.provider] ?? '智谱';

  /// 模型名不预填写死（官方模型迭代快），填Key后自动从/models拉取真实列表

  /// v991：key掩码——显示前4位+••••+后4位（短key全掩）
  static String _maskKey(String k) {
    if (k.length <= 8) return '•' * k.length;
    return '${k.substring(0, 4)}••••${k.substring(k.length - 4)}';
  }

  /// 切换内置提供商：per-provider独立保存key/model，切换不清key（v469 provider_key_xxx对齐）
  /// 旧provider的key/model入stash，新provider从stash恢复；stash没有→空（待自动获取）
  void _switchBuiltin(String k) {
    setState(() {
      // 1. 旧provider参数入stash
      if (!_config.useCustom && _config.provider != k) {
        _config.builtinStash[_config.provider] = {
          'apiKey': _config.apiKey,
          'model': _config.model,
        };
      }
      // v679：旧供应商调参入stash（温度/格式/协议/RPM跟着供应商走）
      _config.stashParams();
      // 2. 切换（apiType回归openai——自定义槽可能是claude类型，残留会让
      // 内置提供商的后续请求走错协议）
      _config.useCustom = false;
      _config.provider = k;
      _config.apiType = 'openai';
      // 3. 新provider从stash恢复
      final saved = _config.builtinStash[k];
      _config.apiKey = saved is Map ? (saved['apiKey'] ?? '') : '';
      _config.model = saved is Map ? (saved['model'] ?? '') : '';
      // v679：新供应商调参从stash恢复
      _config.loadParams();
      _config.apiType = 'openai'; // 内置提供商恒为openai（stash可能残留claude）
      _apiKeyCtrl.text = _config.apiKey;
      _modelCtrl.text = _config.model;
      _gyzBaseCtrl.text = _config.effectiveApiBase; // v1224：公益站baseUrl随provider切换刷新
      _fetchStatus = '';
      _fetchedModels = [];
      _balanceText = ''; // v1529：切供应商清旧余额显示
    });
    _saveNow();
    // v1529：切到擎天且有key→自动查余额
    if (k == 'qingtian' && _config.effectiveApiKey.isNotEmpty) {
      Future.microtask(() {
        if (mounted) _fetchBalance();
      });
    }
    // 4. 恢复出key→自动拉取模型列表
    if (_config.apiKey.isNotEmpty) {
      _scheduleAutoFetch();
    }
  }

  void _syncControllers() {
    if (_apiKeyCtrl.text != _config.apiKey) _apiKeyCtrl.text = _config.apiKey;
    if (_apiBaseCtrl.text != _config.apiBase)
      _apiBaseCtrl.text = _config.apiBase;
    if (_customKeyCtrl.text != _config.customApiKey)
      _customKeyCtrl.text = _config.customApiKey;
    if (_customModelCtrl.text != _config.customModel)
      _customModelCtrl.text = _config.customModel;
    if (_custom2BaseCtrl.text != _config.custom2ApiBase)
      _custom2BaseCtrl.text = _config.custom2ApiBase;
    if (_custom2KeyCtrl.text != _config.custom2ApiKey)
      _custom2KeyCtrl.text = _config.custom2ApiKey;
    if (_custom2ModelCtrl.text != _config.custom2Model)
      _custom2ModelCtrl.text = _config.custom2Model;
    if (_modelCtrl.text != _config.model) _modelCtrl.text = _config.model;
    // v1224：公益站baseUrl控制器同步（effective值=改过用改的/没改用默认）
    final gyzBase = _config.effectiveApiBase;
    if (_gyzBaseCtrl.text != gyzBase) _gyzBaseCtrl.text = gyzBase;
  }

  @override
  void didUpdateWidget(ApiConfigPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 外部配置变化时同步（应用预设/恢复备份后）。
    // 即时保存路径：本地已保存，外部值==本地值，同步无副作用
    if (oldWidget.config != widget.config) {
      final external = widget.config;
      if (external.apiKey != _config.apiKey ||
          external.apiBase != _config.apiBase ||
          external.customApiKey != _config.customApiKey ||
          external.customModel != _config.customModel ||
          external.model != _config.model ||
          external.useCustom != _config.useCustom) {
        _config = ApiConfig.fromJson(external.toJson());
        _syncControllers();
      }
    }
  }

  /// key输入后800ms自动拉取（防抖避免每字符打一次API）
  Timer? _autoFetchDebounce;
  void _scheduleAutoFetch() {
    _autoFetchDebounce?.cancel();
    // 自定义槽也自动拉（effective取值按slot分流）：key非空即可
    if (_config.effectiveApiKey.isEmpty) return;
    _autoFetchDebounce = Timer(const Duration(milliseconds: 800), () {
      if (mounted && !_fetchingModels) _fetchModels(auto: true);
      // v1529：擎天key填完→余额也跟着自动刷新（换key即见新key余额）
      if (mounted &&
          _config.provider == 'qingtian' &&
          !_fetchingBalance) {
        _fetchBalance();
      }
    });
  }

  Future<void> _fetchModels({bool auto = false}) async {
    final baseUrl = _config.effectiveApiBase;
    final apiKey = _config.effectiveApiKey;
    if (apiKey.isEmpty) {
      setState(() => _fetchStatus = '请先填写API Key');
      return;
    }
    if (baseUrl.isEmpty) {
      setState(() => _fetchStatus = '请先填写API Base URL');
      return;
    }

    setState(() {
      _fetchingModels = true;
      _fetchStatus = '正在获取...';
    });

    final state = context.read<AppState>();
    List<String> models;
    try {
      models = await state.api.fetchModels(
        baseUrl: baseUrl,
        apiKey: apiKey,
      );
    } catch (e) {
      // v648：异常兜底——此前无catch,网络异常/URL异常会卡死"正在获取..."
      setState(() {
        _fetchingModels = false;
        _fetchStatus = '获取出错：$e（URL：$baseUrl/models）';
      });
      return;
    }

    setState(() {
      _fetchingModels = false;
      _fetchedModels = models;
      _fetchStatus = models.isEmpty
          ? '获取失败（Key无效或网络不通？URL：$baseUrl/models）'
          : '获取到${models.length}个模型';
    });
    // 拉取成功且当前模型为空或不在列表中：自动选第一个（不写死默认值）
    if (models.isNotEmpty && !_fetchedModels.contains(_config.model)) {
      setState(() {
        _config.model = models.first;
        _modelCtrl.text = models.first;
      });
      _saveNow();
    }
    // 自定义模式同样自动选first并同步输入框（模型名称TextField显示当前值）
    if (models.isNotEmpty &&
        _config.useCustom &&
        _config.customSlot != 'custom2' &&
        !_fetchedModels.contains(_config.customModel)) {
      setState(() {
        _config.customModel = models.first;
        _customModelCtrl.text = models.first;
      });
      _saveNow();
    }
    // 自定义2：同样自动选first
    if (models.isNotEmpty &&
        _config.useCustom &&
        _config.customSlot == 'custom2' &&
        !_fetchedModels.contains(_config.custom2Model)) {
      setState(() {
        _config.custom2Model = models.first;
        _custom2ModelCtrl.text = models.first;
      });
      _saveNow();
    }
  }

  /// 即时保存（v468对齐：改完就走，不需要点保存按钮）
  /// 600ms防抖：连续输入只写一次，避免每字符notifyListeners全页重建
  Timer? _saveDebounce;
  void _saveNow() {
    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(milliseconds: 600), () {
      if (mounted)
        context.read<AppState>().saveApiConfig(widget.section, _config);
    });
  }

  @override
  Widget build(BuildContext context) {
    // 限高+内部滚动：面板放在各页Column>ExpansionTile里，
    // 不限高会撑爆外层导致无法滚动、保存按钮够不着
    final maxH = MediaQuery.of(context).size.height * 0.55;
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxH),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // v292：扫描配方提示（弧线扫描用主页API，section=main）
            if (widget.section == 'main')
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(8),
                margin: const EdgeInsets.only(bottom: 12),
                decoration: BoxDecoration(
                  // v1554：夜间跟随
                  color: V469Style.accentBg,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: const Color(0xFFE0C88F)),
                ),
                child: const Text(
                  '💡 扫描配方建议：Pro系模型（闭合判断最强）+ 温度0.3 + 步进10（弧线页可调）。Flash系只适合快速过书摸底。',
                  style: TextStyle(fontSize: 12, color: Color(0xFF8A6D1A)),
                ),
              ),
            // 应用预设（把已保存预设一键应用到本分页）
            Builder(
              builder: (ctx) {
                final presets = ctx.watch<AppState>().presets;
                if (presets.isEmpty) return const SizedBox.shrink();
                return Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Row(
                    children: [
                      const Text('应用预设:', style: TextStyle(fontSize: 13)),
                      const SizedBox(width: 8),
                      Expanded(
                        child: DropdownButtonFormField<Preset>(
                          key: ValueKey(
                            'preset_${presets.length}_${widget.section}',
                          ),
                          isExpanded: true,
                          decoration: const InputDecoration(
                            isDense: true,
                            border: OutlineInputBorder(),
                            hintText: '选择预设应用到本页',
                            contentPadding: EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 10,
                            ),
                          ),
                          items: presets
                              .map(
                                (p) => DropdownMenuItem(
                                  value: p,
                                  child: Text(
                                    p.name,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              )
                              .toList(),
                          onChanged: (p) {
                            if (p != null) _applyPreset(p);
                          },
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.manage_accounts, size: 20),
                        tooltip: '管理预设',
                        onPressed: _managePresets,
                      ),
                    ],
                  ),
                );
              },
            ),

            // Provider选择（v469 BUILTIN_PROVIDERS对齐+Gemini官方，切换清key防串用）
            Wrap(
              spacing: 8,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                const Text('服务提供商:'),
                ...['zhipu', 'deepseek', 'gemini', 'siliconflow', 'openrouter',
                  'gyz1', 'gyz2', 'gyz3', 'qingtian'].map(
                  (k) => Padding(
                    padding: const EdgeInsets.only(left: 4),
                    child: ChoiceChip(
                      label: Text(ApiConfig.providerLabels[k]!),
                      selected: !_config.useCustom && _config.provider == k,
                      onSelected: (_) => _switchBuiltin(k),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(left: 4),
                  child: ChoiceChip(
                    label: const Text('自定义1'),
                    selected:
                        _config.useCustom && _config.customSlot != 'custom2',
                    onSelected: (_) {
                      setState(() {
                        _config.stashParams(); // v679：旧槽调参入stash
                        _config.useCustom = true;
                        _config.customSlot = 'custom';
                        _config.loadParams(); // v679：新槽调参恢复
                      });
                      _saveNow();
                    },
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(left: 4),
                  child: ChoiceChip(
                    label: const Text('自定义2'),
                    selected:
                        _config.useCustom && _config.customSlot == 'custom2',
                    onSelected: (_) {
                      setState(() {
                        _config.stashParams(); // v679：旧槽调参入stash
                        _config.useCustom = true;
                        _config.customSlot = 'custom2';
                        _config.loadParams(); // v679：新槽调参恢复
                      });
                      _saveNow();
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),

            if (!_config.useCustom) ...[
              // 内置提供商配置（智谱/DeepSeek/Gemini官方，v469对齐）
              TextField(
                decoration: InputDecoration(
                  labelText: '${_providerLabel}API Key',
                  hintText: '输入${_providerLabel}API Key',
                  border: const OutlineInputBorder(),
                  prefixIcon: const Icon(Icons.key),
                  // v991：显示前4后4掩码，方便确认当前用的哪把key
                  helperText: _config.apiKey.isEmpty
                      ? null
                      : '当前key：${_maskKey(_config.apiKey)}',
                ),
                obscureText: true,
                controller: _apiKeyCtrl,
                onChanged: (v) {
                  _config.apiKey = v;
                  _config.builtinStash[_config.provider] = {
                    'apiKey': v,
                    'model': _config.model,
                  };
                  _saveNow();
                  _scheduleAutoFetch(); // 模型不写死：key填完自动拉/models
                },
              ),
              // v1529：擎天余额行——进面板自动查+查余额键手动刷新
              if (_config.provider == 'qingtian')
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          _fetchingBalance
                              ? '余额查询中...'
                              : (_balanceText.isEmpty ? '' : _balanceText),
                          // v1533：字号×2+加粗醒目（用户裁决：余额是重点信息）
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                            color: _balanceText.startsWith('查询失败')
                                ? Colors.red.shade700
                                : Colors.green.shade800,
                          ),
                        ),
                      ),
                      MiniButton(
                        label: '查余额',
                        enabled: true,
                        onTap: _fetchingBalance ? null : _fetchBalance,
                      ),
                    ],
                  ),
                ),
              if (_config.provider == 'qingtian' &&
                  _balanceHistory.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    '近${_balanceHistory.length}次：'
                    '${_balanceHistory.reversed.map((e) => "${(e['v'] as num).toStringAsFixed(1)}(${e['t']})").join(' · ')}',
                    // v1533：字号×2+棕金色醒目
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF9A6B1F),
                    ),
                  ),
                ),
              const SizedBox(height: 4),
              // v1224：公益站baseUrl允许修改（改值存stash随provider走）
              if (ApiConfig.editableBaseProviders.contains(_config.provider))
                Column(
                  children: [
                    TextField(
                      decoration: InputDecoration(
                        labelText: 'API Base URL（${_providerLabel}）',
                        hintText: ApiConfig.builtinBases[_config.provider],
                        border: const OutlineInputBorder(),
                        helperText: '留空=使用默认地址；填到站点根路径即可，程序自动拼接/chat/completions和/models',
                      ),
                      controller: _gyzBaseCtrl,
                      onChanged: (v) {
                        final s = _config.builtinStash.putIfAbsent(
                          _config.provider,
                          () => <String, dynamic>{},
                        );
                        if (s is Map) s['baseUrl'] = v.trim();
                        _saveNow();
                        _scheduleAutoFetch();
                      },
                    ),
                    const SizedBox(height: 4),
                  ],
                ),
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '端点: ${_config.effectiveApiBase}',
                  style: const TextStyle(fontSize: 11, color: Colors.grey),
                ),
              ),
              const SizedBox(height: 8),
              // 模型：拉取到列表→下拉选择；未拉取→手输（模型名不预填写死）
              if (_fetchedModels.isNotEmpty)
                DropdownButtonFormField<String>(
                  value: _fetchedModels.contains(_config.model)
                      ? _config.model
                      : null,
                  decoration: const InputDecoration(
                    labelText: '模型（自动获取）',
                    border: OutlineInputBorder(),
                  ),
                  items: _fetchedModels
                      .map((m) => DropdownMenuItem(value: m, child: Text(m)))
                      .toList(),
                  onChanged: (v) => setState(() {
                    _config.model = v ?? _config.model;
                    _modelCtrl.text = _config.model;
                    _saveNow();
                  }),
                )
              else
                TextField(
                  decoration: const InputDecoration(
                    labelText: '模型',
                    hintText: '填Key后自动获取，或手动输入模型名',
                    border: OutlineInputBorder(),
                  ),
                  controller: _modelCtrl,
                  onChanged: (v) {
                    _config.model = v;
                    _saveNow();
                  },
                ),
              const SizedBox(height: 8),
              // 获取模型列表按钮（手动重试；key填完会自动触发）
              Row(
                children: [
                  FilledButton.tonalIcon(
                    icon: _fetchingModels
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.download, size: 16),
                    label: const Text('获取模型列表'),
                    onPressed: _fetchingModels ? null : () => _fetchModels(),
                  ),
                  const SizedBox(width: 8),
                  if (_fetchStatus.isNotEmpty)
                    Expanded(
                      child: Text(
                        _fetchStatus,
                        style: const TextStyle(
                          fontSize: 12,
                          color: Colors.grey,
                        ),
                      ),
                    ),
                ],
              ),
            ] else if (_config.customSlot == 'custom2') ...[
              // 自定义2配置（第二中转：独立base/key/model）
              TextField(
                decoration: const InputDecoration(
                  labelText: 'API Base URL（自定义2）',
                  hintText: 'https://api.example.com/v1',
                  border: OutlineInputBorder(),
                  helperText: '填到/v1即可，程序自动拼接/chat/completions和/models',
                ),
                controller: _custom2BaseCtrl,
                onChanged: (v) {
                  _config.custom2ApiBase = v;
                  _saveNow();
                  _scheduleAutoFetch(); // 换base重拉模型列表
                },
              ),
              const SizedBox(height: 12),
              TextField(
                decoration: InputDecoration(
                  labelText: 'API Key（自定义2）',
                  border: const OutlineInputBorder(),
                  prefixIcon: const Icon(Icons.key),
                  helperText: _config.custom2ApiKey.isEmpty
                      ? null
                      : '当前key：${_maskKey(_config.custom2ApiKey)}',
                ),
                obscureText: true,
                controller: _custom2KeyCtrl,
                onChanged: (v) {
                  _config.custom2ApiKey = v;
                  _saveNow();
                  _scheduleAutoFetch(); // 自定义2填完key自动拉/models
                },
              ),
              const SizedBox(height: 12),
              TextField(
                decoration: const InputDecoration(
                  labelText: '模型名称（自定义2）',
                  hintText: '如: gemini-3-flash-preview',
                  border: OutlineInputBorder(),
                ),
                controller: _custom2ModelCtrl,
                onChanged: (v) {
                  _config.custom2Model = v;
                  _saveNow();
                },
              ),
              const SizedBox(height: 8),
              // 获取模型列表按钮（与自定义1同款）
              Row(
                children: [
                  FilledButton.tonalIcon(
                    icon: _fetchingModels
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.download, size: 16),
                    label: const Text('获取模型列表'),
                    onPressed: _fetchingModels ? null : () => _fetchModels(),
                  ),
                  const SizedBox(width: 8),
                  if (_fetchStatus.isNotEmpty)
                    Expanded(
                      child: Text(
                        _fetchStatus,
                        style: const TextStyle(
                          fontSize: 12,
                          color: Colors.grey,
                        ),
                      ),
                    ),
                ],
              ),
              // 拉取成功显示下拉选择
              if (_fetchedModels.isNotEmpty) ...[
                const SizedBox(height: 8),
                DropdownButtonFormField<String>(
                  value: _fetchedModels.contains(_config.custom2Model)
                      ? _config.custom2Model
                      : null,
                  decoration: const InputDecoration(
                    labelText: '模型（从API获取）',
                    border: OutlineInputBorder(),
                  ),
                  items: _fetchedModels
                      .map((m) => DropdownMenuItem(value: m, child: Text(m)))
                      .toList(),
                  onChanged: (v) => setState(() {
                    _config.custom2Model = v ?? _config.custom2Model;
                    _custom2ModelCtrl.text = _config.custom2Model;
                    _saveNow();
                  }),
                ),
              ],
            ] else ...[
              // 自定义1配置
              TextField(
                decoration: const InputDecoration(
                  labelText: 'API Base URL',
                  hintText: 'https://api.example.com/v1',
                  border: OutlineInputBorder(),
                  helperText: '填到/v1即可，程序自动拼接/chat/completions和/models',
                ),
                controller: _apiBaseCtrl,
                onChanged: (v) {
                  _config.apiBase = v;
                  _saveNow();
                  _scheduleAutoFetch(); // 换base=换端点，重拉模型列表
                },
              ),
              const SizedBox(height: 12),
              TextField(
                decoration: InputDecoration(
                  labelText: 'API Key',
                  border: const OutlineInputBorder(),
                  prefixIcon: const Icon(Icons.key),
                  helperText: _config.customApiKey.isEmpty
                      ? null
                      : '当前key：${_maskKey(_config.customApiKey)}',
                ),
                obscureText: true,
                controller: _customKeyCtrl,
                onChanged: (v) {
                  _config.customApiKey = v;
                  _saveNow();
                  _scheduleAutoFetch(); // 自定义1填完key自动拉/models
                },
              ),
              const SizedBox(height: 12),
              TextField(
                decoration: const InputDecoration(
                  labelText: '模型名称',
                  hintText: '如: deepseek-chat, gpt-4o',
                  border: OutlineInputBorder(),
                ),
                controller: _customModelCtrl,
                onChanged: (v) {
                  _config.customModel = v;
                  _saveNow();
                },
              ),
              const SizedBox(height: 8),
              // 获取模型列表按钮
              Row(
                children: [
                  FilledButton.tonalIcon(
                    icon: _fetchingModels
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.download, size: 16),
                    label: const Text('获取模型列表'),
                    onPressed: _fetchingModels ? null : _fetchModels,
                  ),
                  const SizedBox(width: 8),
                  if (_fetchStatus.isNotEmpty)
                    Expanded(
                      child: Text(
                        _fetchStatus,
                        style: const TextStyle(
                          fontSize: 12,
                          color: Colors.grey,
                        ),
                      ),
                    ),
                ],
              ),
              if (_fetchedModels.isNotEmpty) ...[
                const SizedBox(height: 8),
                DropdownButtonFormField<String>(
                  value: _fetchedModels.contains(_config.customModel)
                      ? _config.customModel
                      : null,
                  decoration: const InputDecoration(
                    labelText: '模型（从API获取）',
                    border: OutlineInputBorder(),
                  ),
                  items: _fetchedModels
                      .map((m) => DropdownMenuItem(value: m, child: Text(m)))
                      .toList(),
                  onChanged: (v) => setState(() {
                    _config.customModel = v ?? _config.customModel;
                    _customModelCtrl.text = _config.customModel;
                    _saveNow();
                  }),
                ),
              ],
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  const Text('API类型:'),
                  ChoiceChip(
                    label: const Text('OpenAI兼容'),
                    selected: _config.apiType == 'openai',
                    onSelected: (_) {
                      setState(() => _config.apiType = 'openai');
                      _saveNow();
                    },
                  ),
                  ChoiceChip(
                    label: const Text('Claude原生'),
                    selected: _config.apiType == 'claude',
                    onSelected: (_) {
                      setState(() => _config.apiType = 'claude');
                      _saveNow();
                    },
                  ),
                ],
              ),
            ],

            const SizedBox(height: 12),

            // 输出格式（v204缩文字防超格；v1575：传输方式拆独立开关——
            // 流式/整包与输出格式正交，公益站整包长回复被CF掐524实证）
            DropdownButtonFormField<String>(
              value: _config.formatMode,
              decoration: const InputDecoration(
                labelText: '输出格式',
                border: OutlineInputBorder(),
                helperText: 'JSON严格=response_format:json_object（防JSON乱字符）',
              ),
              items: const [
                DropdownMenuItem(
                  value: 'compatible',
                  child: Text('兼容模式（通用）', style: TextStyle(fontSize: 12)),
                ),
                DropdownMenuItem(
                  value: 'json',
                  child: Text(
                    'JSON严格模式（json_object）',
                    style: TextStyle(fontSize: 12),
                  ),
                ),
              ],
              onChanged: (v) => setState(() {
                _config.formatMode = v ?? 'compatible';
                _saveNow();
              }),
            ),

            const SizedBox(height: 8),

            // 传输方式（v1575：流式默认——连接持续有字节，CF不掐100s空闲；
            // 整包仅短回复场景或特殊中转用）
            Wrap(
              spacing: 8,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                const Text('传输方式:'),
                ChoiceChip(
                  label: const Text('流式'),
                  selected: _config.streamEnabled,
                  onSelected: (_) {
                    setState(() => _config.streamEnabled = true);
                    _saveNow();
                  },
                ),
                ChoiceChip(
                  label: const Text('整包'),
                  selected: !_config.streamEnabled,
                  onSelected: (_) {
                    setState(() => _config.streamEnabled = false);
                    _saveNow();
                  },
                ),
                const Text(
                  '流式=长回复不被掐，推荐',
                  style: TextStyle(fontSize: 11, color: Colors.grey),
                ),
              ],
            ),

            // v1580：擎天专属警告（json_object实测挂死——v1580定案：23:32那次
            // 39秒成功属偶发，01:01三连测带response_format全挂0字节，对照去掉
            // 立通；流式/整包都挂，唯一正解=兼容模式。只警告不代办）
            if (_config.providerId.contains('qingtian') ||
                _config.effectiveApiBase.contains('qingtian'))
              const Padding(
                padding: EdgeInsets.only(top: 2),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    '擎天警告：JSON严格实测挂死，建议用兼容模式',
                    style: TextStyle(
                        fontSize: 11,
                        color: Colors.orange,
                        fontWeight: FontWeight.w600),
                  ),
                ),
              ),

            const SizedBox(height: 16),

            // 高级设置（v292：平铺不折叠——温度/maxTokens/RPM是常用参数）
            const Padding(
              padding: EdgeInsets.only(bottom: 6),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '高级设置',
                  style: TextStyle(fontSize: 12, color: Colors.grey),
                ),
              ),
            ),
            Row(
                  children: [
                    const Text('温度:'),
                    Expanded(
                      child: Slider(
                        value: _config.temperature,
                        min: 0.0,
                        max: 2.0,
                        divisions: 20,
                        label: _config.temperature.toStringAsFixed(1),
                        // 拖动只更新UI，松手才保存（避免拖动过程每帧写文件）
                        onChanged: (v) =>
                            setState(() => _config.temperature = v),
                        onChangeEnd: (v) {
                          setState(() => _config.temperature = v);
                          _saveNow();
                        },
                      ),
                    ),
                    SizedBox(
                      width: 40,
                      child: Text(_config.temperature.toStringAsFixed(1)),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    const Text('Max Tokens:'),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Slider(
                        value: _config.maxTokens.toDouble(),
                        min: 1024,
                        max: 1000000,
                        divisions: 999,
                        label: _config.maxTokens.toString(),
                        onChanged: (v) =>
                            setState(() => _config.maxTokens = v.toInt()),
                        onChangeEnd: (v) {
                          setState(() => _config.maxTokens = v.toInt());
                          _saveNow();
                        },
                      ),
                    ),
                    SizedBox(
                      width: 60,
                      child: Text(_config.maxTokens.toString()),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                // RPM限流（中转站每分钟请求上限；0=不限）
                Row(
                  children: [
                    const Text('限流RPM:'),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Slider(
                        value: _config.rpmLimit.toDouble(),
                        min: 0,
                        max: 20,
                        divisions: 20,
                        label: _config.rpmLimit == 0
                            ? '不限'
                            : _config.rpmLimit.toString(),
                        onChanged: (v) =>
                            setState(() => _config.rpmLimit = v.toInt()),
                        onChangeEnd: (v) {
                          setState(() => _config.rpmLimit = v.toInt());
                          _saveNow();
                        },
                      ),
                    ),
                    SizedBox(
                      width: 60,
                      child: Text(
                        _config.rpmLimit == 0 ? '不限' : '${_config.rpmLimit}/分',
                      ),
                    ),
                  ],
                ),

                // v1242用户裁决：无首字换模型重试开关废除（机制已删，失败交上层任务级重试）

            const SizedBox(height: 12),

            // 底部按钮行：💾保存当前配置（v468同款，立即落盘+反馈）+ 存为预设
            Row(
              children: [
                FilledButton.icon(
                  icon: const Icon(Icons.save, size: 18),
                  label: const Text('保存当前配置'),
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF2E7D32),
                    foregroundColor: Colors.white,
                  ),
                  onPressed: () {
                    // 立即落盘（不等600ms防抖）
                    _saveDebounce?.cancel();
                    context.read<AppState>().saveApiConfig(
                      widget.section,
                      _config,
                    );
                    AppState.instance.apiLog('✓ 已保存当前配置');;
                  },
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  icon: const Icon(Icons.bookmark_add, size: 18),
                  label: const Text('存为预设'),
                  onPressed: () => _saveAsPreset(),
                ),
              ],
            ),

            // v204：保存并关闭——立即保存+提示+退出API设置
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                icon: const Icon(Icons.check, size: 16),
                label: const Text('保存并关闭'),
                onPressed: () {
                  _saveDebounce?.cancel(); // 取消防抖立即保存
                  context.read<AppState>().saveApiConfig(
                    widget.section,
                    _config,
                  );
                  final messenger = ScaffoldMessenger.of(context);
                  Navigator.pop(context); // 关闭底部抽屉
                  AppState.instance.apiLog('✓ API设置已保存');;
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 应用预设到当前分页（立即生效并保存）
  void _applyPreset(Preset p) {
    setState(() {
      _config = p.toApiConfig();
      _syncControllers(); // 应用预设后同步输入框内容
    });
    // 直接保存到当前分页（应用即生效，不用再点保存配置）
    context.read<AppState>().saveApiConfig(widget.section, _config);
    AppState.instance.apiLog('已应用预设「${p.name}」到本页并保存');;
  }

  /// 管理预设（查看/删除）
  void _managePresets() {
    final state = context.read<AppState>();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('管理预设'),
        content: SizedBox(
          width: double.maxFinite,
          child: state.presets.isEmpty
              ? const Text('暂无预设')
              : ListView.builder(
                  shrinkWrap: true,
                  itemCount: state.presets.length,
                  itemBuilder: (c, i) {
                    final p = state.presets[i];
                    return ListTile(
                      dense: true,
                      title: Text(p.name, style: const TextStyle(fontSize: 14)),
                      subtitle: Text(
                        '${p.useCustom ? "自定义" : ApiConfig.providerLabels[p.provider] ?? '智谱'} · ${p.useCustom ? p.customModel : p.model}',
                        style: const TextStyle(fontSize: 11),
                      ),
                      trailing: IconButton(
                        icon: const Icon(
                          Icons.delete,
                          size: 18,
                          color: Colors.red,
                        ),
                        onPressed: () {
                          setState(() {
                            state.presets.removeAt(i);
                            state.savePresets();
                          });
                          Navigator.pop(ctx);
                          _managePresets(); // 重新打开刷新列表
                        },
                      ),
                    );
                  },
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  // v982：存为预设——可输入新名，也可点已有预设名直接覆盖
  void _saveAsPreset() {
    final controller = TextEditingController();
    final state = context.read<AppState>();
    final existing = state.presets.map((p) => p.name).toList();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('保存为预设'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: controller,
              decoration: const InputDecoration(
                labelText: '预设名称',
                hintText: '如：DeepSeek-V3',
                border: OutlineInputBorder(),
              ),
              autofocus: true,
            ),
            if (existing.isNotEmpty) ...[
              const SizedBox(height: 10),
              const Text('或选择已有预设（点选覆盖）：',
                  style: TextStyle(fontSize: 12, color: Colors.grey)),
              const SizedBox(height: 4),
              Wrap(
                spacing: 6,
                runSpacing: 4,
                children: [
                  for (final name in existing)
                    ActionChip(
                      label: Text(name, style: const TextStyle(fontSize: 12)),
                      onPressed: () => controller.text = name,
                    ),
                ],
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              final name = controller.text.trim();
              if (name.isEmpty) return;
              final state = context.read<AppState>();
              // 如果同名预设已存在，覆盖
              state.presets.removeWhere((p) => p.name == name);
              state.presets.add(Preset.fromApiConfig(name, _config));
              state.savePresets();
              Navigator.pop(ctx);
              AppState.instance.apiLog('已保存预设「$name」');;
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
  }
}
