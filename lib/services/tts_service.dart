import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter_tts/flutter_tts.dart';

/// TTS服务 — 支持系统TTS和硅基流动TTS
/// 照抄v468逻辑：SiliconTTS(硅基流动mp3) + NativeFS.speakTTS(Android系统TTS)
class TTSService {
  static final TTSService _instance = TTSService._internal();
  factory TTSService() => _instance;
  TTSService._internal();

  final AudioPlayer _player = AudioPlayer();
  FlutterTts? _flutterTts;
  final Map<int, Uint8List> _cache = {};
  bool _playing = false;

  // v561：蓝牙媒体按键方案撤除（原生ROM不路由按键，详见TOOLS.md 2026-09-16）。
  // 字段保留为空操作，兼容阅读页现有赋值
  VoidCallback? onMediaButton;
  void Function(String action)? onMediaAction;
  void Function(String msg)? onMediaDebug;

  Future<void> setMediaSession({required bool active, bool playing = false}) async {}

  // 配置
  String engine = 'silicon'; // 'silicon' or 'native'
  String siliconKey = 'sk-ucstyxvfruuyjfxrexssgfgihkadxhyfgfadbvpcbayfirfz';
  String siliconVoice = 'alex';

  bool get isPlaying => _playing;

  /// 懒初始化系统TTS
  FlutterTts _getNativeTts() {
    if (_flutterTts != null) return _flutterTts!;
    _flutterTts = FlutterTts();
    _flutterTts!.setLanguage('zh-CN');
    _flutterTts!.setSpeechRate(0.5);
    _flutterTts!.setVolume(1.0);
    _flutterTts!.setPitch(1.0);
    // v1665：progress逐字回调（Android）——整块直读时上层映射分句高亮
    _flutterTts!.setProgressHandler((text, start, end, word) {
      _onNativeUtteranceProgress?.call(start, end);
    });
    return _flutterTts!;
  }

  /// 设置引擎
  void setEngine(String e) {
    engine = e;
    stop();
  }

  /// 说话 — 朗读一句
  Future<void> speak(String text, {VoidCallback? onDone, VoidCallback? onError}) async {
    if (engine == 'silicon') {
      await _speakSilicon(text, onDone: onDone, onError: onError);
    } else {
      await _speakNative(text, onDone: onDone, onError: onError);
    }
  }

  /// 系统TTS（Android原生TextToSpeech，同v468的NativeFS.speakTTS）
  Future<void> _speakNative(String text, {VoidCallback? onDone, VoidCallback? onError}) async {
    try {
      final tts = _getNativeTts();
      // 先取消之前的朗读
      await tts.stop();
      tts.setCompletionHandler(() {
        _playing = false;
        onDone?.call();
      });
      tts.setErrorHandler((msg) {
        _playing = false;
        onError?.call();
      });
      _playing = true;
      final result = await tts.speak(text);
      if (result != 1) {
        _playing = false;
        onError?.call();
      }
    } catch (e) {
      _playing = false;
      onError?.call();
    }
  }

  // v1665：native整块直读——逐句stop/speak往返=句间明显停顿（TA 09:45
  // 实测，电子书同病）。系统TTS本地合成无需预取，按句组装成块直读：
  // 块内引擎自然衔接零停顿；块边界仅换utterance（gap可忽略）。
  // Android TTS单次有约4000字符上限，块上限2800留余量。
  // 高亮：progressHandler逐字回调（utterance内偏移）→加块偏移=绝对偏移
  // →onNativeProgress交上层映射分句span。
  void Function(int start, int end)? onNativeProgress; // 绝对偏移回调（上层设）
  void Function(int start, int end)? _onNativeUtteranceProgress; // 块内偏移
  int _nativeChainGen = 0; // v1665：块链代际——stop()++中止推进（防停止后
  // completion回调把下一块拉起来继续读）

  Future<void> speakNativeChunked(
    String text, {
    required List<List<int>> spans,
    VoidCallback? onDone,
    VoidCallback? onError,
  }) async {
    final gen = ++_nativeChainGen;
    void chainDone(VoidCallback? cb) {
      if (gen == _nativeChainGen) cb?.call();
    }

    // 组装块：非空句累计≤2800字成一块
    final blocks = <List<int>>[]; // [start,end)
    int bs = -1, be = -1, len = 0;
    for (final sp in spans) {
      final s = sp[0], e = sp[1];
      if (text.substring(s, e).trim().isEmpty) continue;
      if (bs < 0) {
        bs = s; be = e; len = e - s;
        continue;
      }
      if (len + (e - s) > 2800) {
        blocks.add([bs, be]);
        bs = s; be = e; len = e - s;
      } else {
        be = e;
        len += e - s;
      }
    }
    if (bs >= 0) blocks.add([bs, be]);
    if (blocks.isEmpty) {
      onDone?.call();
      return;
    }
    Future<void> next(int i) async {
      final b = blocks[i];
      _onNativeUtteranceProgress = (s, e) =>
          onNativeProgress?.call(b[0] + s, b[0] + e);
      await _speakNative(text.substring(b[0], b[1]),
          onDone: () {
            if (i + 1 < blocks.length) {
              chainDone(() => next(i + 1));
            } else {
              chainDone(onDone);
            }
          },
          onError: () {
            // 单块失败不中断：跳过继续下一块（同硅基路径跳句兜底）
            if (i + 1 < blocks.length) {
              chainDone(() => next(i + 1));
            } else {
              chainDone(onError);
            }
          });
    }

    await next(0);
  }

  /// 过滤特殊字符（同v468）— 供API请求用，返回null表示无需朗读
  String? _filterForApi(String text) {
    var filtered = text.length > 1000 ? text.substring(0, 1000) : text;
    filtered = filtered
        .replaceAll(RegExp(r'''["'‘’“”「」『』]'''), '')
        .replaceAll(RegExp(r'[\u0000-\u001f]'), '')
        .trim();
    if (filtered.isEmpty) return null;
    return filtered;
  }

  /// 硅基流动TTS
  Future<void> _speakSilicon(String text, {VoidCallback? onDone, VoidCallback? onError}) async {
    if (siliconKey.isEmpty) {
      onError?.call();
      return;
    }
    final filtered = _filterForApi(text);
    if (filtered == null) {
      onDone?.call();
      return;
    }

    final cacheKey = filtered.hashCode;
    if (_cache.containsKey(cacheKey)) {
      await _playBytes(_cache[cacheKey]!, onDone: onDone, onError: onError);
      return;
    }

    try {
      final response = await http.post(
        Uri.parse('https://api.siliconflow.cn/v1/audio/speech'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $siliconKey',
        },
        body: jsonEncode({
          'model': 'FunAudioLLM/CosyVoice2-0.5B',
          'input': filtered,
          'voice': 'FunAudioLLM/CosyVoice2-0.5B:$siliconVoice',
          'response_format': 'mp3',
        }),
      );

      if (response.statusCode != 200) {
        onError?.call();
        return;
      }

      final bytes = response.bodyBytes;
      if (bytes.length < 100) {
        onError?.call();
        return;
      }

      _cache[cacheKey] = bytes;
      await _playBytes(bytes, onDone: onDone, onError: onError);
    } catch (e) {
      onError?.call();
    }
  }

  /// 播放音频字节 — 关键：监听器只挂一次，用代际token防旧回调
  StreamSubscription? _completeSub;
  int _playGeneration = 0;

  Future<void> _playBytes(Uint8List bytes, {VoidCallback? onDone, VoidCallback? onError}) async {
    _playing = true;
    final gen = ++_playGeneration;
    try {
      // 取消旧的监听器（修复：之前每次播放都叠加listen导致onDone多次触发乱跳）
      await _completeSub?.cancel();
      await _player.stop();
      _completeSub = _player.onPlayerComplete.listen((_) {
        if (gen != _playGeneration) return; // 旧回调丢弃
        _playing = false;
        onDone?.call();
      });
      await _player.play(BytesSource(bytes));
    } catch (e) {
      _playing = false;
      onError?.call();
    }
  }

  /// 预取下一句音频（缓存）
  Future<void> prefetch(String text) async {
    if (siliconKey.isEmpty || engine != 'silicon') return;
    final filtered = _filterForApi(text);
    if (filtered == null) return;

    final cacheKey = filtered.hashCode;
    if (_cache.containsKey(cacheKey)) return;

    try {
      final response = await http.post(
        Uri.parse('https://api.siliconflow.cn/v1/audio/speech'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $siliconKey',
        },
        body: jsonEncode({
          'model': 'FunAudioLLM/CosyVoice2-0.5B',
          'input': filtered,
          'voice': 'FunAudioLLM/CosyVoice2-0.5B:$siliconVoice',
          'response_format': 'mp3',
        }),
      );

      if (response.statusCode == 200 && response.bodyBytes.length > 100) {
        _cache[cacheKey] = response.bodyBytes;
      }
    } catch (e) {
      // 预取失败忽略
    }
  }

  /// 暂停
  Future<void> pause() async {
    if (engine == 'native') {
      await _flutterTts?.pause();
    } else {
      await _player.pause();
    }
  }

  /// 恢复
  Future<void> resume() async {
    if (engine == 'native') {
      // flutter_tts没有resume，重新播放由上层处理
    } else {
      await _player.resume();
    }
  }

  /// 停止
  Future<void> stop() async {
    _playing = false;
    _playGeneration++; // 使所有pending回调失效
    _nativeChainGen++; // v1665：中止native块链推进
    await _completeSub?.cancel();
    _completeSub = null;
    _onNativeUtteranceProgress = null; // v1665：块链中止
    if (engine == 'native') {
      await _flutterTts?.stop();
    }
    await _player.stop();
  }

  /// 清空缓存
  void clearCache() {
    _cache.clear();
  }
}
