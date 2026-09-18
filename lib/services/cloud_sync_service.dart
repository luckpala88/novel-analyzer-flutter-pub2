import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// Supabase云同步服务
/// 使用Supabase Auth + Storage REST API
class CloudSyncService {
  // v318内置的Supabase配置
  static const String _defaultUrl = 'https://poxltqgbvwnpryxzgrdy.supabase.co';
  static const String _defaultAnonKey =
      'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InBveGx0cWdidnducHJ5eHpncmR5Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODY0OTcwODEsImV4cCI6MjEwMjA3MzA4MX0.kkyHbo8RJqmdoN6mvT8m3yEuXftVFRm3js4zeR1Yqds';

  String _supabaseUrl = _defaultUrl;
  String _anonKey = _defaultAnonKey;
  String _accessToken = '';
  String _refreshToken = '';
  String _userEmail = '';
  bool _loggedIn = false;

  String get supabaseUrl => _supabaseUrl;
  String get anonKey => _anonKey;
  bool get isLoggedIn => _loggedIn;
  String get userEmail => _userEmail;

  /// 初始化：从SharedPreferences加载配置，默认使用内置配置
  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    _supabaseUrl = prefs.getString('supabase_url') ?? _defaultUrl;
    _anonKey = prefs.getString('supabase_anon_key') ?? _defaultAnonKey;
    _accessToken = prefs.getString('supabase_access_token') ?? '';
    _refreshToken = prefs.getString('supabase_refresh_token') ?? '';
    _userEmail = prefs.getString('supabase_user_email') ?? '';
    _loggedIn = _accessToken.isNotEmpty && _refreshToken.isNotEmpty;
  }

  /// 保存Supabase配置
  Future<void> saveConfig(String url, String anonKey) async {
    _supabaseUrl = url;
    _anonKey = anonKey;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('supabase_url', url);
    await prefs.setString('supabase_anon_key', anonKey);
  }

  /// 注册
  Future<String> signup(String email, String password) async {
    if (_supabaseUrl.isEmpty) return '请先填写Supabase URL和Anon Key';
    try {
      final resp = await http.post(
        Uri.parse('$_supabaseUrl/auth/v1/signup'),
        headers: {'apikey': _anonKey, 'Content-Type': 'application/json'},
        body: jsonEncode({'email': email, 'password': password}),
      );
      if (resp.statusCode == 200 || resp.statusCode == 201) {
        final data = jsonDecode(resp.body);
        if (data['access_token'] != null) {
          _accessToken = data['access_token'];
          _refreshToken = data['refresh_token'];
          _userEmail = email;
          _loggedIn = true;
          await _saveSession();
          return '注册成功';
        }
        return '注册成功，请登录';
      }
      final err = jsonDecode(resp.body);
      return '注册失败: ${err['msg'] ?? err['message'] ?? resp.body}';
    } catch (e) {
      return '注册异常: $e';
    }
  }

  /// 登录
  Future<String> login(String email, String password) async {
    if (_supabaseUrl.isEmpty) return '请先填写Supabase URL和Anon Key';
    try {
      final resp = await http.post(
        Uri.parse('$_supabaseUrl/auth/v1/token?grant_type=password'),
        headers: {'apikey': _anonKey, 'Content-Type': 'application/json'},
        body: jsonEncode({'email': email, 'password': password}),
      );
      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body);
        _accessToken = data['access_token'];
        _refreshToken = data['refresh_token'];
        _userEmail = email;
        _loggedIn = true;
        await _saveSession();
        return '登录成功';
      }
      final err = jsonDecode(resp.body);
      return '登录失败: ${err['msg'] ?? err['message'] ?? resp.body}';
    } catch (e) {
      return '登录异常: $e';
    }
  }

  /// 退出登录
  Future<void> logout() async {
    _accessToken = '';
    _refreshToken = '';
    _userEmail = '';
    _loggedIn = false;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('supabase_access_token');
    await prefs.remove('supabase_refresh_token');
    await prefs.remove('supabase_user_email');
  }

  /// 刷新token（对应v318的cloudRefreshToken）
  Future<bool> refreshToken() async {
    if (_refreshToken.isEmpty) return false;
    try {
      final resp = await http.post(
        Uri.parse('$_supabaseUrl/auth/v1/token?grant_type=refresh_token'),
        headers: {'apikey': _anonKey, 'Content-Type': 'application/json'},
        body: jsonEncode({'refresh_token': _refreshToken}),
      );
      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body);
        _accessToken = data['access_token'];
        _refreshToken = data['refresh_token'];
        await _saveSession();
        return true;
      }
      // 刷新失败，需要重新登录
      _loggedIn = false;
      return false;
    } catch (e) {
      return false;
    }
  }

  /// 检查token是否快过期，如果是则刷新
  Future<void> _ensureValidToken() async {
    try {
      final parts = _accessToken.split('.');
      if (parts.length < 2) return;
      final payload = parts[1];
      final normalized = base64Url.normalize(payload);
      final decoded = utf8.decode(base64Url.decode(normalized));
      final data = jsonDecode(decoded);
      final exp = data['exp'] as int?;
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      if (exp != null && exp - now < 300) {
        // 5分钟内过期，刷新
        await refreshToken();
      }
    } catch (e) {
      // ignore
    }
  }

  /// 保存会话
  Future<void> _saveSession() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('supabase_access_token', _accessToken);
    await prefs.setString('supabase_refresh_token', _refreshToken);
    await prefs.setString('supabase_user_email', _userEmail);
  }

  /// 上传数据到云端（v318兼容：分块上传到Storage + 元数据写入sync_data表）
  /// 数据格式和v318一致：{version:1, books:{书名:{文件名:内容}}, global:{文件名:内容}}
  Future<String> upload(
    String jsonData, {
    void Function(double progress)? onProgress,
    void Function(String msg)? onLog,
  }) async {
    if (!_loggedIn) return '未登录';
    await _ensureValidToken();
    onLog?.call('开始上传...');
    try {
      final userId = _extractUserId(_accessToken);
      final pkgSize = jsonData.length;
      final sizeMB = (pkgSize / 1024 / 1024).toStringAsFixed(2);
      const chunkSize = 5 * 1024 * 1024;
      final totalChunks = (pkgSize / chunkSize).ceil();
      final bucketName = 'sync-data';
      final baseDir = userId;

      onLog?.call('数据大小: ${sizeMB}MB, 分$totalChunks块');
      onLog?.call('Storage桶: $bucketName');

      for (var idx = 0; idx < totalChunks; idx++) {
        final start = idx * chunkSize;
        final end = (start + chunkSize > pkgSize) ? pkgSize : start + chunkSize;
        final chunkStr = jsonData.substring(start, end);
        final chunkPath = '$baseDir/chunk_$idx.json';
        final url = '$_supabaseUrl/storage/v1/object/$bucketName/$chunkPath';

        onLog?.call('上传块 ${idx + 1}/$totalChunks');

        final resp = await http.post(
          Uri.parse(url),
          headers: {
            'apikey': _anonKey,
            'Authorization': 'Bearer $_accessToken',
            'Content-Type': 'application/json',
            'x-upsert': 'true',
          },
          body: chunkStr,
        );

        if (resp.statusCode != 200 && resp.statusCode != 201) {
          onLog?.call('上传块${idx + 1}失败: HTTP ${resp.statusCode}');
          return '上传失败: 块${idx + 1} HTTP ${resp.statusCode}';
        }

        onLog?.call('✅ 块${idx + 1}完成');
        onProgress?.call((idx + 1) / totalChunks);
      }

      onLog?.call('更新元数据...');
      final metaUrl = '$_supabaseUrl/rest/v1/sync_data';
      final metaResp = await http.post(
        Uri.parse(metaUrl),
        headers: {
          'apikey': _anonKey,
          'Authorization': 'Bearer $_accessToken',
          'Content-Type': 'application/json',
          'Prefer': 'return=representation,resolution=merge-duplicates',
        },
        body: jsonEncode({
          'data': {'chunk_count': totalChunks, 'orig_size': pkgSize},
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        }),
      );

      if (metaResp.statusCode != 200 && metaResp.statusCode != 201) {
        onLog?.call('元数据更新失败: HTTP ${metaResp.statusCode}');
      } else {
        onLog?.call('✅ 上传完成! 共$totalChunks块 ${sizeMB}MB');
      }

      return '成功上传 ${sizeMB}MB, $totalChunks块';
    } catch (e) {
      onLog?.call('上传异常: $e');
      return '上传失败: $e';
    }
  }

  /// 从云端下载数据（v318兼容：先查元数据，再并行下载分块）
  /// 返回的是v318同步格式的JSON字符串
  Future<String?> download({
    void Function(double progress)? onProgress,
    void Function(String msg)? onLog,
  }) async {
    if (!_loggedIn) return null;
    await _ensureValidToken();
    onLog?.call('开始下载...');
    try {
      final userId = _extractUserId(_accessToken);
      final bucketName = 'sync-data';
      final baseDir = userId;

      onLog?.call('读取元数据...');
      final metaResp = await http.get(
        Uri.parse('$_supabaseUrl/rest/v1/sync_data?select=data,updated_at'),
        headers: {'apikey': _anonKey, 'Authorization': 'Bearer $_accessToken'},
      );

      if (metaResp.statusCode != 200) {
        onLog?.call('元数据请求失败: HTTP ${metaResp.statusCode}');
        // 如果401/403，尝试刷新token后重试
        if (metaResp.statusCode == 401 || metaResp.statusCode == 403) {
          onLog?.call('Token可能过期，尝试刷新...');
          final refreshed = await refreshToken();
          if (refreshed) {
            onLog?.call('Token已刷新，重试...');
            final metaResp2 = await http.get(
              Uri.parse(
                '$_supabaseUrl/rest/v1/sync_data?select=data,updated_at',
              ),
              headers: {
                'apikey': _anonKey,
                'Authorization': 'Bearer $_accessToken',
              },
            );
            if (metaResp2.statusCode != 200) {
              onLog?.call('重试失败: HTTP ${metaResp2.statusCode}');
              return null;
            }
            return await _downloadChunks(
              metaResp2,
              baseDir,
              bucketName,
              onProgress,
              onLog,
            );
          }
        }
        return null;
      }

      return await _downloadChunks(
        metaResp,
        baseDir,
        bucketName,
        onProgress,
        onLog,
      );
    } catch (e) {
      onLog?.call('下载异常: $e');
      return null;
    }
  }

  Future<String?> _downloadChunks(
    http.Response metaResp,
    String baseDir,
    String bucketName,
    void Function(double progress)? onProgress,
    void Function(String msg)? onLog,
  ) async {
    final rows = jsonDecode(metaResp.body) as List;
    if (rows.isEmpty) {
      onLog?.call('❌ 云端无数据');
      return null;
    }

    final meta = (rows[0] as Map)['data'] as Map? ?? {};
    final chunkCount = meta['chunk_count'] ?? 1;
    final origSize = meta['orig_size'] ?? 0;
    final ts = (rows[0] as Map)['updated_at'] ?? '';
    final sizeMB = origSize > 0
        ? (origSize / 1024 / 1024).toStringAsFixed(2)
        : '未知';

    onLog?.call('云端数据: $chunkCount块, ${sizeMB}MB, 更新于$ts');

    final pkgChunks = List<String>.filled(chunkCount as int, '');
    var completed = 0;

    final futures = <Future<void>>[];
    for (var ci = 0; ci < chunkCount; ci++) {
      final idx = ci;
      final chunkPath = '$baseDir/chunk_$idx.json';
      final url = '$_supabaseUrl/storage/v1/object/$bucketName/$chunkPath';

      futures.add(() async {
        onLog?.call('下载块 ${idx + 1}/$chunkCount');
        final resp = await http.get(
          Uri.parse(url),
          headers: {
            'apikey': _anonKey,
            'Authorization': 'Bearer $_accessToken',
          },
        );
        if (resp.statusCode == 200) {
          pkgChunks[idx] = resp.body;
          completed++;
          onLog?.call('✅ 块${idx + 1}完成');
          onProgress?.call(completed / chunkCount);
        } else {
          onLog?.call('块${idx + 1}下载失败: HTTP ${resp.statusCode}');
          throw Exception('块${idx + 1} HTTP ${resp.statusCode}');
        }
      }());
    }

    await Future.wait(futures);

    final pkgStr = pkgChunks.join();
    final actualMB = (pkgStr.length / 1024 / 1024).toStringAsFixed(2);
    onLog?.call('全部下载完成，共 $actualMB MB');

    try {
      jsonDecode(pkgStr);
    } catch (e) {
      onLog?.call('JSON解析失败: $e');
      return null;
    }

    return pkgStr;
  }

  /// 从JWT token提取user_id
  String _extractUserId(String token) {
    try {
      final parts = token.split('.');
      if (parts.length < 2) return 'unknown';
      final payload = parts[1];
      final normalized = base64Url.normalize(payload);
      final decoded = utf8.decode(base64Url.decode(normalized));
      final data = jsonDecode(decoded);
      return data['sub'] ?? 'unknown';
    } catch (e) {
      return 'unknown';
    }
  }
}
