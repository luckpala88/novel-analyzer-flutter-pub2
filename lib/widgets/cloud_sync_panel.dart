import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../state/app_state.dart';
import 'v119_ui.dart';
import '../utils/v469_style.dart';

/// 云同步面板组件
class CloudSyncPanel extends StatefulWidget {
  final AppState state;
  const CloudSyncPanel({super.key, required this.state});

  @override
  State<CloudSyncPanel> createState() => _CloudSyncPanelState();
}

class _CloudSyncPanelState extends State<CloudSyncPanel> {
  final _urlController = TextEditingController();
  final _keyController = TextEditingController();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _isWorking = false;
  String _statusText = '';
  final List<String> _logs = [];
  bool _rememberMe = true;
  bool _showConfig = false;

  @override
  void initState() {
    super.initState();
    _loadConfig();
  }

  void _loadConfig() async {
    final prefs = await SharedPreferences.getInstance();
    _urlController.text = widget.state.cloudSync.supabaseUrl;
    _keyController.text = widget.state.cloudSync.anonKey;
    _emailController.text = prefs.getString('cloud_email') ?? '';
    _passwordController.text = prefs.getString('cloud_password') ?? '';
    _rememberMe = prefs.getBool('cloud_remember') ?? true;
    if (mounted) setState(() {});
  }

  void _log(String msg) {
    setState(() {
      _logs.add(msg);
      if (_logs.length > 100) _logs.removeAt(0);
    });
  }

  @override
  void dispose() {
    _urlController.dispose();
    _keyController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = widget.state.cloudSync;
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Supabase配置（始终可展开）
          ExpansionTile(
            title: const Text('Supabase 配置', style: TextStyle(fontSize: 14)),
            subtitle: Text(
              'URL: ${_urlController.text.isEmpty ? "未设置" : _urlController.text.substring(0, _urlController.text.length > 30 ? 30 : _urlController.text.length)}...',
              style: const TextStyle(fontSize: 11),
            ),
            initiallyExpanded: !cs.isLoggedIn,
            dense: true,
            children: [
              const SizedBox(height: 8),
              TextField(
                controller: _urlController,
                decoration: const InputDecoration(
                  labelText: 'Supabase URL',
                  hintText: 'https://xxxxx.supabase.co',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _keyController,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: 'Anon Key',
                  hintText: 'eyJhbGciOi...',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: FilledButton.tonal(
                  onPressed: _isWorking
                      ? null
                      : () async {
                          await cs.saveConfig(
                            _urlController.text.trim(),
                            _keyController.text.trim(),
                          );
                          _log('配置已保存');
                          widget.state.refresh();
                          if (mounted) {
                            AppState.instance.apiLog('配置已保存');;
                          }
                        },
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.save, size: 18),
                      SizedBox(width: 6),
                      Text('保存配置'),
                    ],
                  ),
                ),
              ),
            ],
          ),

          // 账号区域
          if (!cs.isLoggedIn) ...[
            const Divider(height: 16),
            Text(
              '账号登录',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _emailController,
              keyboardType: TextInputType.emailAddress,
              decoration: const InputDecoration(
                labelText: '邮箱',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _passwordController,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: '密码',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Checkbox(
                  value: _rememberMe,
                  onChanged: (v) => setState(() => _rememberMe = v ?? false),
                ),
                const Text('记住账号密码', style: TextStyle(fontSize: 13)),
              ],
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                FilledButton(
                  onPressed: _isWorking ? null : () => _doSignup(),
                  child: const Text('注册'),
                ),
                const SizedBox(width: 8),
                FilledButton.tonal(
                  onPressed: _isWorking ? null : () => _doLogin(),
                  child: const Text('登录'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.grey[100],
                borderRadius: BorderRadius.circular(4),
              ),
              child: const Text(
                '首次使用步骤：\n'
                '1. 去 supabase.com 注册并创建项目（免费）\n'
                '2. SQL Editor 执行建表SQL（创建sync_data表+RLS策略）\n'
                '3. 左侧菜单 Storage → New bucket → 名称填 sync-data → Public关掉 → Create\n'
                '4. 复制 Project URL 和 anon key 填到上方 → 保存\n'
                '5. 注册账号即可同步\n'
                '\n已内置默认Supabase配置，可直接注册使用',
                style: TextStyle(fontSize: 12, color: Colors.grey),
              ),
            ),
          ] else ...[
            // 已登录
            const Divider(height: 16),
            Row(
              children: [
                Text(
                  '已登录：${cs.userEmail}',
                  style: TextStyle(
                    fontSize: 13,
                    color: Theme.of(context).colorScheme.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                TextButton(
                  onPressed: _isWorking
                      ? null
                      : () async {
                          await cs.logout();
                          // 清除记住的密码
                          final prefs = await SharedPreferences.getInstance();
                          await prefs.remove('cloud_password');
                          widget.state.refresh();
                          _log('已退出登录');
                        },
                  child: const Text('退出登录', style: TextStyle(fontSize: 12)),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                FilledButton(
                  onPressed: _isWorking ? null : () => _doUpload(),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.cloud_upload, size: 18),
                      SizedBox(width: 6),
                      Text('上传到云端'),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton.tonal(
                  onPressed: _isWorking ? null : () => _doDownload(),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.cloud_download, size: 18),
                      SizedBox(width: 6),
                      Text('从云端拉取'),
                    ],
                  ),
                ),
              ],
            ),
          ],

          // 状态
          if (_statusText.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              _statusText,
              style: TextStyle(fontSize: 12, color: Colors.grey[600]),
            ),
          ],

          // 日志终端
          if (_logs.isNotEmpty) ...[
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              constraints: const BoxConstraints(maxHeight: 150),
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: const Color(0xFF1A1A2E),
                borderRadius: BorderRadius.circular(4),
              ),
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(4),
                child: SelectableText(
                  _logs.join('\n'),
                  style: TextStyle(
                    fontSize: 11,
                    color: Color(0xFF00FF00),
                    fontFamily: V469Style.monoFont, fontFamilyFallback: V469Style.monoFallback, // v200等宽+中文雅黑,
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  void _setWorking(bool working, [String status = '']) {
    setState(() {
      _isWorking = working;
      _statusText = status;
    });
  }

  Future<void> _doSignup() async {
    if (_emailController.text.trim().isEmpty ||
        _passwordController.text.isEmpty) {
      AppState.instance.apiLog('请填写邮箱和密码');;
      return;
    }
    _setWorking(true, '正在注册...');
    _log('开始注册: ${_emailController.text}');
    final result = await widget.state.cloudSync.signup(
      _emailController.text.trim(),
      _passwordController.text,
    );
    final ok = result.contains('成功');
    _log(result);
    _setWorking(false, ok ? '注册成功' : result);
    if (ok) {
      await _saveCredentials();
      // 注册成功后自动登录
      await _doLogin();
    }
  }

  Future<void> _doLogin() async {
    if (_emailController.text.trim().isEmpty ||
        _passwordController.text.isEmpty) {
      AppState.instance.apiLog('请填写邮箱和密码');;
      return;
    }
    _setWorking(true, '正在登录...');
    _log('开始登录: ${_emailController.text}');
    final result = await widget.state.cloudSync.login(
      _emailController.text.trim(),
      _passwordController.text,
    );
    final ok = result.contains('成功');
    _log(result);
    _setWorking(false, ok ? '登录成功' : result);
    if (ok) {
      await _saveCredentials();
      widget.state.refresh();
    }
  }

  Future<void> _saveCredentials() async {
    final prefs = await SharedPreferences.getInstance();
    if (_rememberMe) {
      await prefs.setString('cloud_email', _emailController.text.trim());
      await prefs.setString('cloud_password', _passwordController.text);
      await prefs.setBool('cloud_remember', true);
    } else {
      await prefs.remove('cloud_email');
      await prefs.remove('cloud_password');
      await prefs.setBool('cloud_remember', false);
    }
  }

  Future<void> _doUpload() async {
    _setWorking(true, '正在上传到云端...');
    _log('开始打包数据');
    final json = widget.state.packageSyncData();
    _log('打包完成 (${json.length}字)');
    final result = await widget.state.cloudSync.upload(
      json,
      onLog: (msg) => _log(msg),
    );
    _log(result);
    _setWorking(false, result.contains('成功') ? '上传完成' : '上传失败');
  }

  Future<void> _doDownload() async {
    // 先确认是否覆盖
    if (!mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      useRootNavigator: true,
      builder: (ctx) => AlertDialog(
        title: const Text('从云端恢复'),
        content: const Text('下载会覆盖本地所有数据！\n确定继续？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确定恢复'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    _setWorking(true, '正在从云端拉取...');
    _log('开始下载');
    final json = await widget.state.cloudSync.download(
      onLog: (msg) => _log(msg),
    );
    if (json == null || json.isEmpty) {
      _setWorking(false, '云端没有数据');
      return;
    }

    _log('下载完成 (${json.length}字)，正在解包写入...');
    setState(() => _statusText = '正在恢复数据...');

    final bookCount = await widget.state.unpackSyncData(json);
    _log('解包完成：$bookCount本书目');

    if (bookCount > 0) {
      // 重新加载设置和书目数据
      await widget.state.loadSettings();
      if (widget.state.bookList.isNotEmpty) {
        await widget.state.selectBook(widget.state.bookList.first);
      }
      _log('恢复成功，已加载${widget.state.bookList.length}本书目');
      _setWorking(false, '从云端恢复成功（$bookCount本书目）');
    } else {
      _log('恢复失败：数据格式错误或无有效数据');
      _setWorking(false, '恢复失败');
    }
  }
}
