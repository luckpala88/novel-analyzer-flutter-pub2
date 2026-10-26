import 'dart:async';
import 'dart:convert';
import 'dart:io' as dart_io;

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import '../models/api_config.dart';

/// API调用结果
class ApiResult {
  final String content;
  final String? error;
  final int statusCode;
  final Duration? elapsed;

  ApiResult({
    required this.content,
    this.error,
    this.statusCode = 200,
    this.elapsed,
  });

  bool get isSuccess => error == null && statusCode == 200;
}

/// API日志回调
typedef ApiLogCallback = void Function(String message);

/// HTTP错误信息（带请求体大小诊断，413专属提示）
String _httpErrorMessage(int statusCode, String errShort, String requestBody) {
  if (statusCode == 413) {
    final kb = (requestBody.length * 3 / 1024).round(); // 中文UTF-8约3字节/字
    final sizeText = kb > 1024
        ? '${(kb / 1024).toStringAsFixed(1)} MB'
        : '$kb KB';
    return 'HTTP 413 请求体过大（本次发送约 $sizeText）——中转/网关拒绝了请求。'
        '解决：①换直连API或调大中转的请求体限制（如nginx client_max_body_size） '
        '②该弧线章节太多，去弧线页重扫让弧线更短后再划分 '
        '③或换到限制更大的API提供商。原始错误：$errShort';
  }
  if (statusCode >= 520 && statusCode <= 527) {
    return 'HTTP $statusCode 中转CDN错误（520/522/524/525/527同族：中转站Cloudflare把Gemini思考期>100s的连接掐断，或中转上游拥堵）——'
        '请求未消耗生成结果，点"继续扫描"即可原段重试。'
        '若反复出现：①减小步进章节数 ②换Gemini官方直连端点 ③换时段。原始错误：$errShort';
  }
  if (statusCode == 503) {
    return 'HTTP 503 模型过载（临时高负载，通常几分钟内恢复）——稍等重试或先换一个模型（如flash系）。原始错误：$errShort';
  }
  if (statusCode == 429) {
    return 'HTTP 429 配额用尽/限流——该模型可能不在免费额度内（如pro系模型free tier配额为0）或当日额度已用完。'
        '解决：①换flash等免费模型 ②等待额度重置 ③检查Google AI Studio的plan与billing。原始错误：$errShort';
  }
  return 'HTTP $statusCode: $errShort';
}

/// v1221：朱雀AI浓度检测结果（腾讯EdgeOne Makers @makers/zhuque-text）
class ZhuqueSeg {
  final String text;
  final int label; // 0=人工 1=AI 2=疑似AI
  final double conf;
  final List<int> position;
  ZhuqueSeg({
    required this.text,
    required this.label,
    required this.conf,
    required this.position,
  });
}

class ZhuqueResult {
  final double human, ai, suspect; // labels_ratio三占比（0人工/1AI/2疑似）
  final double softmax; // 整体置信度，越大越像AI
  final List<ZhuqueSeg> segments;
  final int usedTokens; // makers_models_usage.total_tokens=实扣免费额度
  ZhuqueResult({
    required this.human,
    required this.ai,
    required this.suspect,
    required this.softmax,
    required this.segments,
    required this.usedTokens,
  });
}

/// API服务 — 统一HTTP客户端
/// 支持: OpenAI兼容格式, Claude原生格式
class ApiService {
  ApiLogCallback? onLog;
  void Function()? onStartTimer;
  void Function()? onStopTimer;
  // v224：用户主动终止回调——终端abort按钮触发，通知所有页面的
  // 批量循环任务（扫描/拆解/生成）停止。此前abort只断当前请求，
  // v213的call()入口自清_aborted让下一请求照发=循环停不下来
  void Function()? onUserAbort;
  bool _busy = false; // 全局忙锁：同时只允许一个生成任务（禁止并行，数据安全）
  // v1242用户裁决：call内换模型重试废除+对应开关删除——看门狗断开保留，
  // 失败交上层任务级重试接力（等60秒躲冷却重发）
  bool _noFirstByteFired = false; // 看门狗已触发（90秒零内容chunk强制断连）
  int _clientGen = 0; // 客户端代际：看门狗防误伤后续请求的新连接

  // ===== 滑动窗口限流（中转站RPM限制）=====
  final List<DateTime> _recentCalls = [];
  int rpmLimit = 5; // 每分钟最大请求数（0=不限）
  int get _rpmUsed => _recentCalls.length;

  /// 限流等待：窗口内已满→返回需等待的毫秒数；否则0。同时清理过期记录
  int _rpmWaitMs() {
    if (rpmLimit <= 0) return 0;
    final now = DateTime.now();
    _recentCalls.removeWhere((t) => now.difference(t).inMilliseconds > 60000);
    if (_rpmUsed < rpmLimit) return 0;
    // 最早一次调用出窗的时间=剩余等待
    final oldest = _recentCalls.first;
    final wait = 60000 - now.difference(oldest).inMilliseconds;
    return wait > 0 ? wait : 0;
  }

  void _rpmRecord() {
    _recentCalls.add(DateTime.now());
    if (_recentCalls.length > rpmLimit + 10) {
      _recentCalls.removeRange(0, _recentCalls.length - rpmLimit);
    }
  }

  /// 限流守卫：超限则终端提示+等待出窗（可被abort打断）
  Future<void> _rpmGuard() async {
    if (rpmLimit <= 0) return;
    var waitMs = _rpmWaitMs();
    while (waitMs > 0 && !_aborted) {
      final sec = (waitMs / 1000).ceil();
      _log('⏳ 限流等待：本分钟已 $_rpmUsed/$rpmLimit 次请求，${sec}秒后自动发送...');
      // 分段睡（每秒检查abort）
      final sleepEnd = DateTime.now().add(Duration(milliseconds: waitMs));
      while (DateTime.now().isBefore(sleepEnd) && !_aborted) {
        await Future.delayed(const Duration(milliseconds: 500));
      }
      waitMs = _rpmWaitMs();
    }
    _rpmRecord();
  }

  /// 全局忙锁状态（页面启动任务前检查，给即时提示）
  bool get isBusy => _busy;
  IOClient? _activeClient;
  dart_io.HttpClient? _activeInner; // 底层HttpClient引用：abort时force close立即断连
  bool _aborted = false;

  /// 中断当前请求
  /// 关键：http包的Client.close()是优雅关闭（等活动请求跑完才断），
  /// 必须拿底层HttpClient做close(force:true)才能立即掐断TCP连接
  void abort() {
    _aborted = true;
    _busy = false; // 终止即释放忙锁
    onUserAbort?.call(); // v224：通知页面级循环停止
    try {
      _activeInner?.close(force: true); // 强制断开：await中的请求立即抛ClientException
    } catch (_) {}
    _activeInner = null;
    _activeClient = null;
  }

  /// 新建带强制断连能力的client（所有请求统一走这里）
  IOClient _newClient() {
    _clientGen++; // 每个新client一代：旧看门狗到期按代际失效（防误关新连接）
    final inner = dart_io.HttpClient()
      ..connectionTimeout = const Duration(seconds: 60);
    final client = IOClient(inner);
    _activeInner = inner;
    _activeClient = client;
    return client;
  }

  /// 重置中断状态（新请求前调用）
  void _resetAbort() {
    _aborted = false;
  }

  /// 公开重置中断状态（新任务开始前调用，清除上次abort残留）
  void clearAbort() {
    _aborted = false;
  }

  /// v1221：朱雀AI浓度检测（腾讯EdgeOne Makers @makers/zhuque-text）
  /// 独立POST不走忙锁不占生成通道（查询型请求）；返回null=失败（error为null时看日志）
  Future<ZhuqueResult?> zhuqueClassify({
    required String apiKey,
    required String text,
  }) async {
    try {
      final resp = await http
          .post(
            Uri.parse(
              'https://ai-gateway.edgeone.link/v1/providers/zhuque-text/classify',
            ),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $apiKey',
            },
            body: jsonEncode({'text': text, 'is_merge': false}),
          )
          .timeout(const Duration(seconds: 60));
      if (resp.statusCode != 200) {
        _log('朱雀检测失败：HTTP ${resp.statusCode} ${resp.body.length > 200 ? resp.body.substring(0, 200) : resp.body}');
        return null;
      }
      final d = jsonDecode(resp.body) as Map<String, dynamic>;
      if (d['status'] != 'success') {
        _log('朱雀检测失败：${d['msg'] ?? d['status']}');
        return null;
      }
      final ratio = (d['labels_ratio'] as Map<String, dynamic>? ?? {});
      final segs = <ZhuqueSeg>[];
      for (final s in (d['segment_labels'] as List? ?? const [])) {
        final m = s as Map<String, dynamic>;
        segs.add(ZhuqueSeg(
          text: (m['text'] as String?) ?? '',
          label: (m['label'] as num?)?.toInt() ?? 0,
          conf: (m['conf'] as num?)?.toDouble() ?? 0,
          position: ((m['position'] as List?) ?? const [])
              .map((e) => (e as num).toInt())
              .toList(),
        ));
      }
      return ZhuqueResult(
        human: (ratio['0'] as num?)?.toDouble() ?? 0,
        ai: (ratio['1'] as num?)?.toDouble() ?? 0,
        suspect: (ratio['2'] as num?)?.toDouble() ?? 0,
        softmax: (d['softmax_confidence'] as num?)?.toDouble() ?? 0,
        segments: segs,
        usedTokens:
            ((d['makers_models_usage'] as Map<String, dynamic>? ?? {})['total_tokens']
                    as num?)
                ?.toInt() ??
            0,
      );
    } catch (e) {
      _log('朱雀检测异常：$e');
      return null;
    }
  }

  bool get isAborted => _aborted;
  void Function(String msg)? onStartGen;
  void Function()? onStopGen;

  /// 便捷方法：用ApiConfig调用
  /// v824：task传入任务名后统一输出任务级反馈（▶开始含参数/✅完成含耗时字数/⛔失败含原因）
  Future<ApiResult> callApi({
    required String systemPrompt,
    required String userPrompt,
    required ApiConfig apiConfig,
    void Function(String chunk)? onChunk,
    String task = '',
    List<({String mime, String base64})> images = const [], // v838：vision图片
    double? tempOverride, // v1136：任务级温度覆盖（独立温度开关用）
  }) async {
    rpmLimit = apiConfig.rpmLimit; // 配置的每分钟请求上限（0=不限）
    final effTemp = tempOverride ?? apiConfig.temperature;
    final sw = Stopwatch()..start();
    if (task.isNotEmpty) {
      _log(
        '▶ $task｜模型${apiConfig.effectiveModel}'
        '｜温度$effTemp${tempOverride != null ? '（独立）' : ''}｜max_tokens${apiConfig.maxTokens}'
        '｜RPM${apiConfig.rpmLimit > 0 ? apiConfig.rpmLimit : "不限"}',
      );
    }
    final r = await call(
      apiType: apiConfig.effectiveApiType,
      baseUrl: apiConfig.effectiveApiBase,
      apiKey: apiConfig.effectiveApiKey,
      model: apiConfig.effectiveModel,
      systemPrompt: systemPrompt,
      userPrompt: userPrompt,
      temperature: effTemp,
      maxTokens: apiConfig.maxTokens,
      formatMode: apiConfig.formatMode,
      onChunk: onChunk,
      images: images,
      task: task, // v1242：透传任务名——全景提取类重任务首字看门狗放宽180秒
    );
    if (task.isNotEmpty) {
      final mins = (sw.elapsed.inSeconds / 60).toStringAsFixed(1);
      if (r.isSuccess) {
        _log('✅ $task完成｜耗时$mins分钟｜输出${r.content.length}字');
      } else {
        _log('⛔ $task失败｜耗时$mins分钟｜${r.error}');
      }
    }
    return r;
  }

  /// 发送API请求
  Future<ApiResult> call({
    required String apiType,
    required String baseUrl,
    required String apiKey,
    required String model,
    required String systemPrompt,
    required String userPrompt,
    double temperature = 0.3,
    int maxTokens = 8192,
    String formatMode = 'compatible',
    void Function(String chunk)? onChunk,
    List<({String mime, String base64})> images = const [], // v838：vision图片
    String task = '', // v1242：重任务（全景提取）首字看门狗放宽到180秒
  }) async {
    // 全局忙锁：已有任务在跑→拒绝（禁止并行生成，防止多任务乱序写盘脏数据）
    if (_busy) {
      _log('⚠️ 已有生成任务进行中，拒绝并发请求（等当前任务完成或终止后再试）');
      return ApiResult(
        content: '',
        statusCode: 409,
        error: '已有生成任务进行中，请等待完成或先终止',
      );
    }
    _busy = true;
    // v213：新请求自动清abort残留——busy锁保证同时只有一个任务，
    // 进入这里时_aborted=true必是上次终止的残留（页面忘clearAbort也不复现）
    _aborted = false;
    // RPM限流守卫（滑动窗口，超限终端显示倒计时等待）
    await _rpmGuard();
    if (_aborted) {
      _busy = false;
      return ApiResult(content: '', error: '用户中断', statusCode: 0);
    }
    final stopwatch = Stopwatch()..start();
    final baseUrlShort = baseUrl.length > 40
        ? baseUrl.substring(0, 40)
        : baseUrl;
    _log('API -> $model [$apiType] @ $baseUrlShort');
    _startTimer();
    _startGen('正在生成中...');

    try {
      final isClaude = apiType == 'claude';
      // 尾斜杠规范化：fetchModels剥过但这里漏了——baseUrl带/拼成//chat/completions必404（openrouter实证）
      final base = baseUrl.endsWith('/') ? baseUrl.substring(0, baseUrl.length - 1) : baseUrl;
      final url = isClaude ? '$base/messages' : '$base/chat/completions';

      // v838：vision图片——openai=content数组image_url(data URI)；claude=base64 source块
      final userContent = images.isEmpty
          ? userPrompt
          : (isClaude
              ? [
                  {'type': 'text', 'text': userPrompt},
                  for (final img in images)
                    {
                      'type': 'image',
                      'source': {
                        'type': 'base64',
                        'media_type': img.mime,
                        'data': img.base64,
                      },
                    },
                ]
              : [
                  {'type': 'text', 'text': userPrompt},
                  for (final img in images)
                    {
                      'type': 'image_url',
                      'image_url': {'url': 'data:${img.mime};base64,${img.base64}'},
                    },
                ]);

      final messages = [
        {'role': 'system', 'content': systemPrompt},
        {'role': 'user', 'content': userContent},
      ];

      Map<String, String> headers;
      Map<String, dynamic> body;

      if (isClaude) {
        headers = {
          'Content-Type': 'application/json',
          'x-api-key': apiKey,
          'anthropic-version': '2023-06-01',
        };
        final userMessages = messages
            .where((m) => m['role'] != 'system')
            .toList();
        body = {
          'model': model,
          'system': systemPrompt,
          'messages': userMessages,
          'temperature': temperature,
          'max_tokens': maxTokens,
          'stream': true,
        };
      } else {
        headers = {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $apiKey',
        };
        body = {
          'model': model,
          'messages': messages,
          'temperature': temperature,
          'max_tokens': maxTokens,
        };
        if (formatMode == 'json') {
          // json模式（Gemini严格输出）：流式+json_object
          // （Gemini thinking>100s不吐首字节会被CF掐524——流式+重试兜底）
          body['stream'] = true;
          body['response_format'] = {'type': 'json_object'};
        } else {
          // 兼容模式：整包stream:false（同HTML版——中转整包路径成熟；
          // v169曾改全流式反而在gcli假流式中转上空响应/截断频发，v175回退）
          body['stream'] = false;
        }
      }

      // v1220：参数日志=实际发送值（组装完body后从body读，防"设置≠发送"漂移——用户裁决）
      _log(
        '发送参数：模型${body['model']}｜温度${body['temperature']}'
        '｜max_tokens${body['max_tokens']}${body['stream'] == true ? '｜流式' : '｜整包'}',
      );
      _log('发送请求...');
      // 传输模式分流（v175对齐HTML版）：
      // - json模式/Claude：流式（Gemini thinking防CF 524；Claude原生流）
      // - 兼容模式：整包（中转整包路径成熟，假流式中转的SSE路径反而脆）
      // CF系错误自动重试：524=首字节>100s被掐（Gemini thinking阶段常见，
      // 上游往往仍在跑，重试第二次通常命中快路径）；520/522/525/527同类
      final useStream = isClaude || formatMode == 'json';
      // v1242：重任务首字看门狗放宽——全景提取类思考期长（四件套大输出），
      // 90秒常误杀；其它任务维持90秒快速判死
      final firstByteTimeout = task.contains('全景提取') ? 180 : 90;
      const cfRetryCodes = [520, 522, 524, 525, 527];
      // v427：取消CF系自动重试（用户裁决：API拥堵不重试，失败即告警暂停）
      const maxRetries = 0;
      for (var attempt = 0; attempt <= maxRetries; attempt++) {
        _resetAbort();
        final result = useStream
            ? await _fetchStream(
                url,
                headers,
                body,
                isClaude,
                onChunk,
                stopwatch,
                firstByteTimeoutSec: firstByteTimeout,
              )
            : await _fetchJson(
                url,
                headers,
                body,
                isClaude,
                stopwatch,
                onChunk: onChunk,
              );
        // 可重试：CF系错误码；或200但内容空（中转假流式快连发时偶发返回空body）
        final emptyOk = result.statusCode == 200 && result.content.isEmpty;
        final retryable = cfRetryCodes.contains(result.statusCode) || emptyOk;
        if (!retryable || attempt == maxRetries || _aborted) {
          if (emptyOk && attempt == maxRetries) {
            return ApiResult(
              content: '',
              error: '连续${maxRetries + 1}次空响应（中转假流式异常）：建议降低限流RPM拉开请求间隔',
              statusCode: 200,
              elapsed: stopwatch.elapsed,
            );
          }
          // v1242用户裁决：换模型重试废除——90秒无首字断开后直接返回失败，
          // 由上层任务级重试接力（等60秒躲中转冷却后重发，比同链路秒级重发有效）
          return result;
        }
        final waitSec = emptyOk ? 5 : 8 * (attempt + 1);
        _log(
          emptyOk
              ? '⚠️ HTTP 200但内容为空（中转假流式抽风），${waitSec}秒后重发 ${attempt + 1}/$maxRetries...'
              : '⚠️ HTTP ${result.statusCode}（中转CDN超时，Gemini思考阶段>100s常见），${waitSec}秒后自动重试 ${attempt + 1}/$maxRetries...',
        );
        await Future.delayed(Duration(seconds: waitSec));
      }
      return ApiResult(
        content: '',
        error: '重试后仍524：中转站缓冲整包响应（伪流式），生成超100秒被CDN掐断。建议：①减小步进章节数（20→10） ②换Gemini官方直连端点 ③拆解用兼容模式代替严格json',
        statusCode: 524,
        elapsed: stopwatch.elapsed,
      );
    } catch (e) {
      _stopTimer();
      if (_aborted) {
        _log('请求已中断');
        return ApiResult(
          content: '',
          error: '用户中断',
          statusCode: 0,
          elapsed: stopwatch.elapsed,
        );
      }
      // v1219：看门狗强制断连引发的ClientException——交599给上层换模型重试
      if (_noFirstByteFired) {
        return ApiResult(
          content: '',
          error: '90秒无首字（中转SSE挂起）',
          statusCode: 599,
          elapsed: stopwatch.elapsed,
        );
      }
      _log('异常: $e');
      return ApiResult(
        content: '',
        error: e.toString(),
        statusCode: 0,
        elapsed: stopwatch.elapsed,
      );
    } finally {
      _busy = false; // 释放忙锁
      _stopGen();
      _stopTimer(); // v783：异常路径计时器也归零（此前catch路径漏调→切书被拒"计时器未归零"）
      _activeClient = null;
    }
  }

  /// 流式请求
  Future<ApiResult> _fetchStream(
    String url,
    Map<String, String> headers,
    Map<String, dynamic> body,
    bool isClaude,
    void Function(String chunk)? onChunk,
    Stopwatch stopwatch, {
    int firstByteTimeoutSec = 90, // v1242：重任务（全景提取）放宽到180秒
  }) async {
    _log('SSE流式请求...');
    final request = http.Request('POST', Uri.parse(url));
    request.headers.addAll(headers);
    request.body = jsonEncode(body);

    final client = _newClient(); // abort可force close
    _activeClient = client;
    // v1219：无首字看门狗——90秒没收到任何内容chunk就强制断连（防中转SSE
    // 挂起假死：HTTP 200后服务端一个字节不吐，用户只能干等再手动终止）。
    // 实证：gcli中转00:29:37发出→00:30:23收到200→166秒零字节被迫手动中断。
    // 代际校验防误伤：本请求提前结束后，到期看门狗不得关掉后续请求的新连接
    // v1242：全景提取类重任务（四件套8千-1.2万字输出）思考期长，flash-high
    // 首字常超90秒=被误杀挂起（19:34/22:44两实证，Claude同任务4.5分钟成功）
    // ——按task放宽到180秒，小任务维持90秒快速判死
    var gotFirst = false;
    _noFirstByteFired = false;
    final myGen = _clientGen;
    // 不持有Timer引用：代际+gotFirst+_aborted三重守卫保证到期自动失效
    Timer(Duration(seconds: firstByteTimeoutSec), () {
      if (gotFirst || _aborted || myGen != _clientGen) return;
      _noFirstByteFired = true;
      _log('⚠️ $firstByteTimeoutSec秒无首字，主动断开（中转SSE挂起/CDN掐思考期）...');
      try {
        _activeInner?.close(force: true);
      } catch (_) {}
    });
    final response = await client.send(request);

    _log('收到响应: HTTP ${response.statusCode}');

    if (response.statusCode != 200) {
      final errText = await response.stream.bytesToString();
      _stopTimer();
      final errShort = errText.length > 500
          ? errText.substring(0, 500)
          : errText;
      final errMsg = _httpErrorMessage(
        response.statusCode,
        errShort,
        request.body,
      );
      _log('错误: $errMsg');
      return ApiResult(
        content: '',
        error: errMsg,
        statusCode: response.statusCode,
        elapsed: stopwatch.elapsed,
      );
    }

    final buffer = StringBuffer();
    var rawBuffer = '';
    var fullRaw = ''; // 完整raw（SSE解析0内容时fallback按chunked JSON解析，对齐HTML版）

    await for (final chunk in response.stream.transform(utf8.decoder)) {
      if (_aborted) {
        client.close();
        _stopTimer();
        _log('请求已中断, 已接收${buffer.length}字');
        return ApiResult(
          content: buffer.toString(),
          statusCode: 200,
          elapsed: stopwatch.elapsed,
        );
      }
      fullRaw += chunk;
      rawBuffer += chunk;
      while (true) {
        final idx = rawBuffer.indexOf('\n');
        if (idx < 0) break;
        final line = rawBuffer.substring(0, idx).trim();
        rawBuffer = rawBuffer.substring(idx + 1);
        if (line.isEmpty || !line.startsWith('data:')) continue;
        final d = line.substring(5).trim();
        if (d.isEmpty) continue;
        if (d == '[DONE]') {
          _log('SSE完成, 内容${buffer.length}字');
          _stopTimer();
          return ApiResult(
            content: buffer.toString(),
            statusCode: 200,
            elapsed: stopwatch.elapsed,
          );
        }
        try {
          final parsed = jsonDecode(d);
          if (isClaude) {
            if (parsed['type'] == 'content_block_delta' &&
                parsed['delta']?['text'] != null) {
              final text = parsed['delta']['text'] as String;
              gotFirst = true; // v1219：首字已到，看门狗失效
              buffer.write(text);
              onChunk?.call(text);
            }
            if (parsed['type'] == 'message_stop') {
              _log('SSE完成[Claude], 内容${buffer.length}字');
              _stopTimer();
              return ApiResult(
                content: buffer.toString(),
                statusCode: 200,
                elapsed: stopwatch.elapsed,
              );
            }
          } else {
            final choices = parsed['choices'] as List?;
            if (choices != null && choices.isNotEmpty) {
              final choice = choices[0] as Map<String, dynamic>;
              if (choice['delta']?['content'] != null) {
                final text = choice['delta']['content'] as String;
                gotFirst = true; // v1219：首字已到，看门狗失效
                buffer.write(text);
                onChunk?.call(text);
              }
              if (choice['message']?['content'] != null) {
                final text = choice['message']['content'] as String;
                gotFirst = true; // v1219：首字已到，看门狗失效
                buffer.write(text);
                onChunk?.call(text);
              }
              if (choice['finish_reason'] == 'stop') {
                _log('SSE完成[OpenAI], 内容${buffer.length}字');
                _stopTimer();
                return ApiResult(
                  content: buffer.toString(),
                  statusCode: 200,
                  elapsed: stopwatch.elapsed,
                );
              }
            }
          }
        } catch (e) {
          // 忽略JSON解析错误
        }
      }
    }

    // v1219：流被正常结束但看门狗已触发（close后stream走done不走error的路径）——
    // 此时零内容，不能当正常完成返回，交599给callApi换模型重试
    if (_noFirstByteFired) {
      _stopTimer();
      return ApiResult(
        content: '',
        error: '90秒无首字（中转SSE挂起）',
        statusCode: 599,
        elapsed: stopwatch.elapsed,
      );
    }
    _log('SSE流结束, 内容${buffer.length}字');
    // 处理rawBuffer中可能残留的最后一行（不以\n结尾的情况）
    if (rawBuffer.trim().isNotEmpty) {
      final lastLine = rawBuffer.trim();
      if (lastLine.startsWith('data:')) {
        final d = lastLine.substring(5).trim();
        if (d == '[DONE]') {
          _log('SSE完成(末行), 内容${buffer.length}字');
        } else if (d.isNotEmpty) {
          try {
            final parsed = jsonDecode(d);
            if (isClaude) {
              if (parsed['type'] == 'content_block_delta' &&
                  parsed['delta']?['text'] != null) {
                buffer.write(parsed['delta']['text'] as String);
              }
            } else {
              final choices = parsed['choices'] as List?;
              if (choices != null && choices.isNotEmpty) {
                final choice = choices[0] as Map<String, dynamic>;
                if (choice['delta']?['content'] != null) {
                  buffer.write(choice['delta']['content'] as String);
                }
                if (choice['message']?['content'] != null) {
                  buffer.write(choice['message']['content'] as String);
                }
              }
            }
          } catch (e) {
            // 忽略JSON解析错误
          }
        }
      }
    }
    _stopTimer();
    // 【fallback】SSE解析0内容（对齐HTML版）：中转假流式实际返回整包JSON body
    // （Content-Type标event-stream但内容非SSE格式）→按chunked JSON解析message.content
    var content = buffer.toString();
    if (content.isEmpty && fullRaw.trim().isNotEmpty) {
      _log('SSE解析0内容, 尝试chunked JSON解析 (raw:${fullRaw.length}字)');
      content = _parseChunkedJson(fullRaw);
      if (content.isNotEmpty) {
        _log('chunked JSON解析成功, 内容${content.length}字');
      }
    }
    return ApiResult(
      content: content,
      statusCode: 200,
      elapsed: stopwatch.elapsed,
    );
  }

  /// 整包JSON body抠content（假流式中转fallback：OpenAI choices.message.content
  /// + Claude content[].text + 裸{...}提取，对齐HTML版三层尝试）
  String _parseChunkedJson(String raw) {
    var s = raw.trim();
    // 剥可能的SSE data:前缀行（混合体：中转把整包JSON当data行发）
    if (s.startsWith('data:')) {
      s = s.substring(5).trim();
    }
    for (final candidate in [s, _extractJsonObject(s)]) {
      if (candidate.isEmpty) continue;
      try {
        final data = jsonDecode(candidate);
        if (data is Map<String, dynamic>) {
          // OpenAI格式
          final choices = data['choices'] as List?;
          if (choices != null && choices.isNotEmpty) {
            final choice = choices[0] as Map<String, dynamic>;
            final mc = choice['message']?['content'];
            if (mc is String && mc.isNotEmpty) return mc;
          }
          // Claude格式
          final cc = data['content'];
          if (cc is List) {
            final buf = StringBuffer();
            for (final item in cc) {
              if (item is Map && item['text'] is String) {
                buf.write(item['text']);
              }
            }
            if (buf.isNotEmpty) return buf.toString();
          }
        }
      } catch (_) {}
    }
    return '';
  }

  /// 从混合文本提取最外层JSON对象
  String _extractJsonObject(String s) {
    final m = RegExp(r'\{[\s\S]*\}').firstMatch(s);
    return m?.group(0) ?? '';
  }

  /// 非流式JSON请求
  Future<ApiResult> _fetchJson(
    String url,
    Map<String, String> headers,
    Map<String, dynamic> body,
    bool isClaude,
    Stopwatch stopwatch, {
    void Function(String chunk)? onChunk,
  }) async {
    _log('正在读取响应...');
    final client = _newClient(); // abort可force close
    _activeClient = client;
    final response = await client.post(
      Uri.parse(url),
      headers: headers,
      body: jsonEncode(body),
    );

    _log('收到响应: HTTP ${response.statusCode}');

    // 检查Content-Type——某些中转在compatible模式也返回SSE流
    final contentType = response.headers['content-type'] ?? '';
    if (contentType.contains('text/event-stream')) {
      _log('检测到SSE流式响应，切换到流式解析');
      return _parseSseResponse(response, isClaude, onChunk, stopwatch);
    }

    if (response.statusCode != 200) {
      _stopTimer();
      final errShort = response.body.length > 500
          ? response.body.substring(0, 500)
          : response.body;
      final errMsg = _httpErrorMessage(
        response.statusCode,
        errShort,
        jsonEncode(body),
      );
      _log('错误: $errMsg');
      return ApiResult(
        content: '',
        error: errMsg,
        statusCode: response.statusCode,
        elapsed: stopwatch.elapsed,
      );
    }

    final data = jsonDecode(response.body);
    String content = '';

    if (isClaude && data['content'] != null && data['content'] is List) {
      for (final block in data['content'] as List) {
        if (block['text'] != null) {
          content += block['text'] as String;
        }
      }
      _log('Claude响应归一化, 返回${content.length}字');
    } else {
      content = data['choices']?[0]?['message']?['content'] ?? '';
      _log('完成, 返回${content.length}字');
    }

    _stopTimer();
    return ApiResult(
      content: content,
      statusCode: 200,
      elapsed: stopwatch.elapsed,
    );
  }

  /// 解析SSE流式响应（兼容中转返回SSE的情况）
  Future<ApiResult> _parseSseResponse(
    http.Response response,
    bool isClaude,
    void Function(String chunk)? onChunk,
    Stopwatch stopwatch,
  ) async {
    final raw = response.body;
    var sseContent = '';
    final lines = raw.split('\n');
    for (final line in lines) {
      final trimmed = line.trim();
      if (trimmed.isEmpty || !trimmed.startsWith('data:')) continue;
      final dataStr = trimmed.substring(5).trim();
      if (dataStr == '[DONE]') break;
      try {
        final parsed = jsonDecode(dataStr) as Map<String, dynamic>;
        if (isClaude) {
          if (parsed['type'] == 'content_block_delta' &&
              parsed['delta'] != null &&
              parsed['delta']['text'] != null) {
            final text = parsed['delta']['text'] as String;
            sseContent += text;
            onChunk?.call(text);
          }
          if (parsed['type'] == 'message_stop') break;
        } else {
          final choices = parsed['choices'];
          if (choices != null && choices.isNotEmpty) {
            final choice = choices[0] as Map<String, dynamic>;
            if (choice['delta'] != null && choice['delta']['content'] != null) {
              final text = choice['delta']['content'] as String;
              sseContent += text;
              onChunk?.call(text);
            }
            if (choice['finish_reason'] == 'stop') break;
          }
        }
      } catch (e) {
        // 忽略无法解析的行
      }
    }
    _log('SSE完成 [$isClaude], 内容${sseContent.length}字');
    _stopTimer();
    return ApiResult(
      content: sseContent,
      statusCode: 200,
      elapsed: stopwatch.elapsed,
    );
  }

  void _log(String msg) {
    onLog?.call(msg);
  }

  void _startTimer() {
    onStartTimer?.call();
  }

  void _stopTimer() {
    onStopTimer?.call();
  }

  void _startGen(String msg) {
    onStartGen?.call(msg);
  }

  void _stopGen() {
    onStopGen?.call();
  }

  /// 获取模型列表（GET /models）
  Future<List<String>> fetchModels({
    required String baseUrl,
    required String apiKey,
  }) async {
    try {
      var url = baseUrl;
      if (url.endsWith('/')) url = url.substring(0, url.length - 1);
      if (!url.endsWith('/models')) {
        // Gemini官方OpenAI兼容层baseUrl以/openai结尾，直接拼/models
        if (url.endsWith('/v4') ||
            url.endsWith('/v1') ||
            url.endsWith('/openai')) {
          url = '$url/models';
        } else {
          url = '$url/v1/models';
        }
      }

      _log('获取模型列表: $url');
      final response = await http
          .get(
            Uri.parse(url),
            headers: {
              'Authorization': 'Bearer $apiKey',
              'Content-Type': 'application/json',
            },
          )
          .timeout(const Duration(seconds: 30));

      if (response.statusCode != 200) {
        _log('获取失败: ${response.statusCode}');
        return [];
      }

      final data = jsonDecode(response.body);
      final models = data['data'] as List? ?? [];
      // Gemini官方/models返回资源名"models/gemini-xxx"（调用层兼容但显示脏+困惑）——统一剥前缀
      final modelIds =
          models
              .map(
                (m) => (m['id'] as String? ?? '').replaceAll(
                  RegExp(r'^models/'),
                  '',
                ),
              )
              .where((s) => s.isNotEmpty)
              .toSet()
              .toList()
            ..sort();
      _log('获取到 ${modelIds.length} 个模型');
      return modelIds;
    } catch (e) {
      _log('获取模型列表异常: $e');
      return [];
    }
  }
}
