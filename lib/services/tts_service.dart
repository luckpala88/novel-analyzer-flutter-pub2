import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter_tts/flutter_tts.dart';

/// TTS服务 — 支持系统TTS和硅基流动TTS
/// 照抄v468逻辑：SiliconTTS(硅基流动mp3) + NativeFS.speakTTS(Android系统TTS)
class TTSService {
  static final TTSService _instance = TTSService._internal();
  factory TTSService() => _instance;
  TTSService._internal() {
    // v550：接收原生媒体按键回调
    _mediaCh.setMethodCallHandler((call) async {
      if (call.method == 'playPause') onMediaButton?.call();
    });
  }

  final AudioPlayer _player = AudioPlayer();
  FlutterTts? _flutterTts;
  final Map<int, Uint8List> _cache = {};
  bool _playing = false;

  // v550：蓝牙耳机媒体按键——原生MediaSession回调playPause，阅读页
  // 设onMediaButton接自己的暂停/继续逻辑
  static const MethodChannel _mediaCh = MethodChannel(
    'com.luckpala.novel_analyzer/tts_media',
  );
  VoidCallback? onMediaButton;

  Future<void> setMediaSession({required bool active, bool playing = false}) async {
    try {
      await _mediaCh.invokeMethod('setActive', {
        'active': active,
        'playing': playing,
      });
    } catch (_) {
      // 媒体会话失败不影响朗读本身
    }
  }

  // 配置
  String engine = 'silicon'; // 'silicon' or 'native'
  String siliconKey = 'sk-ooauhnezueiyargefmbeyqdpetuflidpqdgqelnuylljklqd';
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
    await _completeSub?.cancel();
    _completeSub = null;
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
