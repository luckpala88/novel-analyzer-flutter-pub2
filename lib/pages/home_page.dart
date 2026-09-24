import 'dart:io';
import 'dart:typed_data';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:open_filex/open_filex.dart';

import '../state/app_state.dart';
import '../models/chapter.dart';
import '../models/preset.dart';
import '../services/chapter_parser.dart';
import '../services/file_picker_service.dart';
import '../utils/encoding_detector.dart';
import '../widgets/api_config_panel.dart';
import '../widgets/cloud_sync_panel.dart';
import '../widgets/chapter_reader_inline.dart';
import '../widgets/v119_ui.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true; // 页面滑出PageView时保持State：生成任务不中断/表单不清空

  // v190：启动静默检查更新，有新版时"检查更新"项亮红标
  int? _latestRemoteBuild;

  @override
  void initState() {
    super.initState();
    _silentCheckUpdate();
  }

  /// 启动静默检查（无弹窗，仅点亮红标）
  /// 启动静默检查（无弹窗，仅点亮红标；v302双仓库取最高版本）
  Future<void> _silentCheckUpdate() async {
    final best = await _queryBestRelease(silent: true);
    if (best != null && best.build > _appVersion && mounted) {
      setState(() => _latestRemoteBuild = best.build);
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context); // AutomaticKeepAlive必须
    final state = context.watch<AppState>();
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            // 顶行：书名+操作（唯一一行，空态也显示——新书空章节时可切回旧书/加载文本）
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 2),
              // Wrap：桌面8栏窄栏宽下自动换行不挤爆
              child: Wrap(
                spacing: 4,
                runSpacing: 2,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  SizedBox(
                    width: 150,
                    child: Text(
                      state.currentBook.isNotEmpty
                          ? '${state.currentBook} · ${state.chapters.length}章'
                          : '未选择书目',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
                        color: Colors.grey[700],
                      ),
                    ),
                  ),
                  MiniButton(label: '书目', onTap: () => _showBookDialog(state)),
                  PopupMenuButton<String>(
                    position: PopupMenuPosition.under,
                    onSelected: (v) {
                      if (v == 'file') _uploadFile(state);
                      if (v == 'paste') _pasteText(state);
                    },
                    child: const MiniButton(label: '加载 ▾'),
                    itemBuilder: (ctx) => [
                      const PopupMenuItem(
                        value: 'file',
                        height: 40,
                        child: Text('从文件加载', style: TextStyle(fontSize: 13)),
                      ),
                      const PopupMenuItem(
                        value: 'paste',
                        height: 40,
                        child: Text('粘贴文本', style: TextStyle(fontSize: 13)),
                      ),
                    ],
                  ),
                  const SizedBox(width: 4),
                  MiniButton(
                    label: '设置',
                    onTap: () => _showSettingsDialog(state),
                  ),
                ],
              ),
            ),
            // 正文：空态=加载引导；有章节=阅读器
            Expanded(
              child: state.chapters.isEmpty
                  ? _buildEmpty(state)
                  : ChapterReaderInline(
                      key: ValueKey('reader_${state.currentBook}'),
                      chapters: state.chapters,
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmpty(AppState state) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.menu_book, size: 64, color: Colors.grey[400]),
          const SizedBox(height: 16),
          Text('暂无章节', style: TextStyle(color: Colors.grey[600])),
          const SizedBox(height: 8),
          Text(
            '点击上方"加载 ▾"导入小说文本，或点"书目"切换其他书',
            style: TextStyle(color: Colors.grey[500], fontSize: 13),
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            icon: const Icon(Icons.file_upload),
            label: const Text('从文件加载'),
            onPressed: () => _uploadFile(state),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            icon: const Icon(Icons.content_paste),
            label: const Text('粘贴文本'),
            onPressed: () => _pasteText(state),
          ),
        ],
      ),
    );
  }

  // ===== 书目管理 =====
  void _showBookDialog(AppState state) {
    showModalBottomSheet(
      context: context,
      // builder内watch：删除/切换书目后列表立即刷新（原一次性闭包不响应notifyListeners）
      builder: (ctx) {
        final live = ctx.watch<AppState>();
        return Column(
          children: [
            AppBar(
              title: Text('书目 (${live.bookList.length})'),
              leading: IconButton(
                icon: const Icon(Icons.close),
                onPressed: () => Navigator.pop(ctx),
              ),
              actions: [
                IconButton(
                  icon: const Icon(Icons.add),
                  tooltip: '新建书目',
                  onPressed: () => _showCreateBookDialog(state),
                ),
              ],
            ),
            Expanded(
              child: ListView(
                children: live.bookList
                    .map(
                      (b) => ListTile(
                        leading: const Icon(Icons.book_outlined),
                        title: Text(b),
                        subtitle: Text(b == live.currentBook ? '当前' : ''),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (b == live.currentBook)
                              const Icon(
                                Icons.check_circle,
                                color: Colors.green,
                              ),
                            // 删除键（确认弹窗后才删）
                            IconButton(
                              icon: Icon(
                                Icons.delete_outline,
                                size: 20,
                                color: Colors.red.shade400,
                              ),
                              tooltip: '删除书目',
                              onPressed: () =>
                                  _confirmDeleteBook(ctx, state, b),
                            ),
                          ],
                        ),
                        onTap: () async {
                          final ok = await state.selectBook(b);
                          if (!ok) {
                            if (ctx.mounted) {
                              AppState.instance.apiLog('有生成任务运行中，不能切换书目');;
                            }
                            return;
                          }
                          if (ctx.mounted) Navigator.pop(ctx);
                        },
                      ),
                    )
                    .toList(),
              ),
            ),
            // 敏感词警示（Android公共存储MediaProvider会拦截敏感词目录名）
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: Text(
                '⚠️ 请勿用敏感词作书目名（如脏话等），否则系统存储层会拦截，导致书目数据无法保存。',
                style: TextStyle(
                  fontSize: 10,
                  color: Colors.orange.shade700,
                  height: 1.4,
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  /// 删除书目确认（二次确认才删；当前书有任务运行会被拒绝并提示）
  void _confirmDeleteBook(BuildContext sheetCtx, AppState state, String name) {
    showDialog<bool>(
      context: sheetCtx,
      builder: (ctx) => AlertDialog(
        title: const Text('删除书目'),
        content: Text('确定删除「$name」？该书的章节/扫描/拆解/世界书/创作数据将全部删除，不可恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    ).then((confirmed) async {
      if (confirmed != true) return;
      final ok = await state.deleteBook(name);
      if (!ok && sheetCtx.mounted) {
        AppState.instance.apiLog('当前书有任务运行中，不能删除');;
      }
    });
  }

  void _showCreateBookDialog(AppState state) {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('创建新书目'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
            labelText: '书目名称',
            hintText: '如：凡人修仙传',
            border: OutlineInputBorder(),
          ),
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () async {
              final name = controller.text.trim();
              if (name.isEmpty) return;
              // v221：书名特殊字符预检——!：?*等会被Android存储层静默拒绝
              // （创建成功但写入失败=切换/重启后书目数据消失的根因）
              final badChars = RegExp(r'''[!！:：?？*|<>/"']''');
              if (badChars.hasMatch(name)) {
                if (ctx.mounted) Navigator.pop(ctx);
                if (mounted) {
                  AppState.instance.apiLog('书名不能含 ! ！ : ： ? ？ * 等特殊字符——存储系统会静默拒绝写入，导致书目数据消失。请去掉特殊字符');;
                }
                return;
              }
              final ok = await state.createBook(name);
              if (ctx.mounted) Navigator.pop(ctx);
              if (!ok && mounted) {
                AppState.instance.apiLog('书目已存在');;
              }
            },
            child: const Text('创建'),
          ),
        ],
      ),
    );
  }

  // ===== 加载章节 =====
  Future<void> _uploadFile(AppState state) async {
    final result = await FilePickerService.pickTextFile();
    if (result == null) return;

    state.setLoading(true, '正在解析文件...');
    try {
      final bytes = await result.readAsBytes();
      final text = EncodingDetector.decode(Uint8List.fromList(bytes));
      final chapters = ChapterParser.parseChapters(text);

      if (chapters.isEmpty) {
        chapters.add(
          Chapter(
            title: '全文',
            content: text,
            wordCount: text.length,
            number: 1,
          ),
        );
      }

      state.addChaptersBatch(chapters);
      if (mounted) {
        AppState.instance.apiLog('已加载 ${chapters.length} 章');;
      }
    } catch (e) {
      if (mounted) {
        AppState.instance.apiLog('解析失败: $e');;
      }
    }
    state.setLoading(false);
  }

  void _pasteText(AppState state) {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('粘贴文本'),
        content: SizedBox(
          width: double.maxFinite,
          height: 300,
          child: TextField(
            controller: controller,
            maxLines: null,
            expands: true,
            decoration: const InputDecoration(
              hintText: '粘贴小说文本...',
              border: OutlineInputBorder(),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              final text = controller.text;
              if (text.isEmpty) return;
              final chapters = ChapterParser.parseChapters(text);
              if (chapters.isEmpty) {
                chapters.add(
                  Chapter(
                    title: '全文',
                    content: text,
                    wordCount: text.length,
                    number: 1,
                  ),
                );
              }
              state.addChaptersBatch(chapters);
              Navigator.pop(ctx);
              AppState.instance.apiLog('已加载 ${chapters.length} 章');;
            },
            child: const Text('加载'),
          ),
        ],
      ),
    );
  }

  // ===== 设置弹窗（API配置+备份+预设+检查更新） =====
  void _showSettingsDialog(AppState state) {
    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        // v204：宽度占满（原默认inset 40水平边距太窄，对齐API设置面板的宽度感）
        insetPadding: const EdgeInsets.symmetric(
          horizontal: 8,
          vertical: 24,
        ),
        child: SizedBox(
          width: double.maxFinite,
          height: MediaQuery.of(context).size.height * 0.85,
          child: Column(
            children: [
              AppBar(
                title: const Text('设置'),
                // v204：关闭键移右上角
                actions: [
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(ctx),
                  ),
                ],
              ),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    // 预设
                    Text(
                      'API预设',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'API配置在各功能页顶部设置',
                      style: Theme.of(context).textTheme.bodySmall
                          ?.copyWith(color: Colors.grey),
                    ),
                    const SizedBox(height: 8),
                    if (state.presets.isEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Text(
                          '暂无预设。在API配置面板中保存当前配置为预设。',
                          style: TextStyle(
                            color: Colors.grey[500],
                            fontSize: 13,
                          ),
                        ),
                      )
                    else
                      ...state.presets.map(
                        (p) => Card(
                          child: ListTile(
                            leading: const Icon(
                              Icons.bookmark,
                              color: Color(0xFF8B6914),
                            ),
                            title: Text(p.name),
                            subtitle: Text(
                              '${p.useCustom ? '自定义' : '智谱'} · ${p.model}',
                            ),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  icon: const Icon(
                                    Icons.drive_file_move,
                                    size: 18,
                                  ),
                                  tooltip: '应用到主页API',
                                  onPressed: () => _applyPreset(state, p),
                                ),
                                IconButton(
                                  icon: const Icon(
                                    Icons.delete_outline,
                                    size: 18,
                                    color: Colors.red,
                                  ),
                                  tooltip: '删除预设',
                                  onPressed: () => _deletePreset(state, p),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    const Divider(height: 32),
                    // 数据备份
                    Text(
                      '数据备份',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '备份格式与v318互通',
                      style: Theme.of(context).textTheme.bodySmall
                          ?.copyWith(color: Colors.grey),
                    ),
                    const SizedBox(height: 8),
                    Card(
                      child: ListTile(
                        leading: const Icon(Icons.cloud_upload),
                        title: const Text('备份当前书目'),
                        onTap: () => _backupBook(state),
                      ),
                    ),
                    Card(
                      child: ListTile(
                        leading: const Icon(Icons.backup),
                        title: const Text('备份全部书目'),
                        onTap: () => _backupAll(state),
                      ),
                    ),
                    Card(
                      child: ListTile(
                        leading: const Icon(Icons.cloud_download),
                        title: const Text('从备份恢复'),
                        onTap: () => _restoreBackup(state),
                      ),
                    ),
                    const Divider(height: 32),
                    // 云同步（v285：直接平铺不折叠）
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 0, 0, 0),
                      child: Text(
                        '云同步',
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                    ),
                    CloudSyncPanel(state: state),
                    const Divider(height: 32),
                    // 存储+更新
                    Card(
                      child: ListTile(
                        leading: const Icon(Icons.folder_outlined),
                        title: const Text('存储模式'),
                        subtitle: Text(
                          state.storage.storageMode == 'public'
                              ? '公共目录'
                              : state.storage.storageMode == 'appprivate'
                              ? '专属目录'
                              : state.storage.storageMode,
                        ),
                        onTap: () => _showStorageModeDialog(state),
                      ),
                    ),
                    Card(
                      child: ListTile(
                        leading: const Icon(Icons.refresh),
                        title: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Text('检查更新'),
                            // v190：有新版时红标提示
                            if (_latestRemoteBuild != null) ...[
                              const SizedBox(width: 6),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                  vertical: 1,
                                ),
                                decoration: BoxDecoration(
                                  color: Colors.red,
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Text(
                                  '新v$_latestRemoteBuild',
                                  style: const TextStyle(
                                    fontSize: 10,
                                    color: Colors.white,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                        subtitle: Text(
                          _latestRemoteBuild != null
                              ? '发现新版本 v$_latestRemoteBuild，点击更新'
                              : '检查并下载最新版本',
                        ),
                        onTap: () => _checkUpdate(),
                      ),
                    ),
                    const SizedBox(height: 32),
                    Center(
                      child: Column(
                        children: [
                          Text(
                            'Designed by luckpala',
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(color: Colors.grey),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            '接下来的一百年，我将为您拆解人类脑洞的光辉！',
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(
                                  color: Colors.grey[400],
                                  fontSize: 9,
                                ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'Flutter v$_appVersion',
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(
                                  color: Colors.grey[400],
                                  fontSize: 11,
                                ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _apiSubtitle(AppState state, String section) {
    final config = state.getApiConfig(section);
    final isFallback =
        config.effectiveApiKey == state.mainApi.effectiveApiKey &&
        section != 'main';
    final provider = config.useCustom ? '自定义' : '智谱';
    final status = config.effectiveApiKey.isEmpty ? '未设置' : '已设置';
    final fallback = isFallback ? ' · 使用主页API' : '';
    return '$provider · ${config.effectiveModel} · $status$fallback';
  }

  // ===== 备份 =====
  // v386：备份统一走异步——先确保存储权限（老手机公共目录必须运行时授权），
  // writeFile结果如实反馈（此前失败也打"已备份"=用户看到"没反应"）
  Future<void> _backupBook(AppState state) async {
    final ok = await _doBackup(
      state,
      'novel_backup_${state.currentBook}_${DateTime.now().toIso8601String().substring(0, 10)}.json',
      () => state.backupData(backupAll: false),
    );
    if (mounted && ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('✓ 备份完成（backups/目录）')),
      );
    }
  }

  Future<void> _backupAll(AppState state) async {
    final ok = await _doBackup(
      state,
      'novel_backup_all_${DateTime.now().toIso8601String().substring(0, 10)}.json',
      () => state.backupData(backupAll: true),
    );
    if (mounted && ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('✓ 全部书目备份完成（backups/目录）')),
      );
    }
  }

  Future<bool> _doBackup(
    AppState state,
    String filename,
    Map<String, dynamic> Function() build,
  ) async {
    // 公共目录模式：先确保运行时存储权限（老手机Android<=9必须，拒绝=写不进去）
    final writable = await state.storage.ensurePublicWritable();
    if (!writable) {
      AppState.instance.apiLog('❌ 备份失败：存储权限被拒绝（请在系统设置授予存储权限，或切换到专属目录模式）');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('❌ 备份失败：存储权限被拒绝——请在系统设置授权，或改用专属目录模式'),
            duration: Duration(seconds: 4),
          ),
        );
      }
      return false;
    }
    final json = jsonEncode(build());
    final path = state.storage.getBackupPath(filename);
    final ok = state.storage.writeFile(path, json);
    if (ok) {
      AppState.instance.apiLog('✓ 已备份到$path');
    } else {
      AppState.instance.apiLog('❌ 备份失败：$path 写入失败（权限/空间不足？）');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('❌ 备份失败：$path 写入失败'),
            duration: const Duration(seconds: 4),
          ),
        );
      }
    }
    return ok;
  }

  void _restoreBackup(AppState state) async {
    final result = await FilePickerService.pickTextFile();
    if (result == null) return;
    try {
      final bytes = await result.readAsBytes();
      final json = String.fromCharCodes(bytes);
      final ok = await state.restoreFromJson(json);
      if (mounted) {
        AppState.instance.apiLog(ok ? '恢复成功' : '恢复失败：格式错误');;
      }
    } catch (e) {
      if (mounted)
        AppState.instance.apiLog('恢复失败: $e');;
    }
  }

  // ===== 存储模式 =====
  void _showStorageModeDialog(AppState state) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('选择存储模式'),
        content: const Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('选择数据存储位置：'),
            SizedBox(height: 12),
            Text('• 公共目录：文件管理器可见，方便管理'),
            SizedBox(height: 8),
            Text('• 专属目录：Android/data/下，无需权限，所有版本兼容'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton.tonal(
            onPressed: () async {
              final ok = await state.storage.setStorageMode('public');
              if (ctx.mounted) {
                Navigator.pop(ctx);
                AppState.instance.apiLog(ok ? '已切换到公共目录' : '公共目录不可用，请使用专属目录');;
                state.refresh();
              }
            },
            child: const Text('公共目录'),
          ),
          FilledButton(
            onPressed: () async {
              final ok = await state.storage.setStorageMode('appprivate');
              if (ctx.mounted) {
                Navigator.pop(ctx);
                AppState.instance.apiLog(ok ? '已切换到专属目录' : '切换失败');;
                state.refresh();
              }
            },
            child: const Text('专属目录'),
          ),
        ],
      ),
    );
  }

  // ===== 检查更新 =====
  static const int _appVersion = 505;
  // v497：token占位符——私有仓存占位符，镜像仓Actions编译时用secret注入
  // （公开镜像源码零token；APK下载仍走私有仓Release）
  static const String _updateToken = '__UPD_TOKEN_OLD__';
  static const String _updateTokenNew = '__UPD_TOKEN__';
  static const Map<String, String> _updateRepos = {
    'luckpala88/novel-analyzer-flutter': _updateTokenNew,
    'luckpala/novel-analyzer-flutter': _updateToken,
  };
  
  /// v302: 双仓库查询latest release，取版本号最高的仓库（token与仓库配对）
  /// 返回null=两个仓库都失败；silent=true不写apiLog（启动静默检查用）
  Future<({String repo, String token, int build})?> _queryBestRelease(
      {bool silent = false}) async {
    String? bestRepo;
    String? bestToken;
    int bestBuild = 0;
    for (final entry in _updateRepos.entries) {
      try {
        final resp = await http
            .get(
              Uri.parse(
                'https://api.github.com/repos/${entry.key}/releases/latest',
              ),
              headers: {
                'Authorization': 'token ${entry.value}',
                'Accept': 'application/vnd.github.v3+json',
              },
            )
            .timeout(const Duration(seconds: 30));
        if (resp.statusCode != 200) {
          if (!silent && mounted)
            AppState.instance
                .apiLog('${entry.key} 检查失败: HTTP ${resp.statusCode}');
          continue;
        }
        // 读latest release的tag（而非pubspec：发版窗口期pubspec已更新但APK未发布，会误报新版本）
        final jsonObj = jsonDecode(resp.body) as Map<String, dynamic>;
        final tagName = jsonObj['tag_name'] as String? ?? '';
        final match = RegExp(r'^v(\d+)$').firstMatch(tagName.trim());
        if (match == null) continue;
        final remoteBuild = int.tryParse(match.group(1)!) ?? 0;
        if (remoteBuild > bestBuild) {
          bestBuild = remoteBuild;
          bestRepo = entry.key;
          bestToken = entry.value;
        }
      } catch (e) {
        if (!silent && mounted)
          AppState.instance.apiLog('${entry.key} 检查失败: $e');
      }
    }
    if (bestRepo == null || bestToken == null) return null;
    return (repo: bestRepo, token: bestToken, build: bestBuild);
  }

  void _checkUpdate() async {
    final best = await _queryBestRelease();
    if (best == null) {
      if (mounted) AppState.instance.apiLog('所有仓库检查更新均失败');
      return;
    }
    if (best.build > _appVersion) {
      if (!mounted) return;
      final shouldUpdate = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('发现新版本'),
          content: Text(
            '远程版本：v${best.build}\n当前版本：v$_appVersion\n来源：${best.repo}\n\n是否下载并安装更新？',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('下载更新'),
            ),
          ],
        ),
      );
      if (shouldUpdate == true) {
        await _downloadAndInstall(
          best.build,
          repo: best.repo,
          token: best.token,
        );
      }
    } else {
      if (mounted) AppState.instance.apiLog('已是最新版本 v$_appVersion');
    }
  }

  /// 公共断点续传下载器（Android APK与win zip共用，v186从Android路径抽出）
  /// Range请求续传 + 302跟随 + 失败自动重试3次 + 实时速度/剩余时间
  /// ⚠️指纹校验：残留文件必须和目标asset同源（v版本#assetId一致）才续传。
  /// 旧版完整文件残留被当作续传基底时=旧头+新尾=损坏包
  Future<void> _downloadAssetWithResume({
    required int remoteBuild,
    required String repo,
    required String token,
    required int assetId,
    required int assetSize,
    required String filePath,
    required ValueNotifier<double> progressNotifier,
    required ValueNotifier<String> statusNotifier,
  }) async {
    final file = File(filePath);
    final downloadUrl =
        'https://api.github.com/repos/$repo/releases/assets/$assetId';
    statusNotifier.value =
        '开始下载 (${(assetSize / 1024 / 1024).toStringAsFixed(1)}MB)...';

    var downloaded = 0;
    final metaFile = File('$filePath.meta');
    final expectMeta = 'v$remoteBuild#$assetId';
    final lastMeta = metaFile.existsSync()
        ? await metaFile.readAsString()
        : '';
    if (lastMeta != expectMeta) {
      // 换版本了或首次：清掉旧残留
      if (file.existsSync()) file.deleteSync();
      if (metaFile.existsSync()) metaFile.deleteSync();
    }
    if (file.existsSync()) {
      downloaded = await file.length();
      // 残留异常（超目标大小或为0），重下
      if (downloaded >= assetSize || downloaded == 0) {
        file.deleteSync();
        downloaded = 0;
      } else {
        statusNotifier.value =
            '发现未完成下载，从 ${(downloaded / 1024 / 1024).toStringAsFixed(1)}MB 处续传...';
      }
    }
    if (!metaFile.existsSync()) {
      await metaFile.writeAsString(expectMeta);
    }
    var sink = file.openWrite(mode: FileMode.append); // 追加模式支持续传（200全量时需重开）
    final client = http.Client();

    // 速度计算：滑动窗口
    var speedStart = DateTime.now();
    var speedBytes = downloaded;

    try {
      var attempt = 0;
      while (downloaded < assetSize) {
        attempt++;
        try {
          final streamedRequest = http.Request('GET', Uri.parse(downloadUrl));
          streamedRequest.headers['Authorization'] = 'token $token';
          streamedRequest.headers['Accept'] = 'application/octet-stream';
          if (downloaded > 0) {
            streamedRequest.headers['Range'] = 'bytes=$downloaded-'; // 断点续传
          }

          var response = await client
              .send(streamedRequest)
              .timeout(const Duration(seconds: 30));

          // 手动跟随302重定向（Dart http不自动跟POST/带头的302）
          var hop = 0;
          while (response.statusCode == 302 || response.statusCode == 301) {
            if (++hop > 3) throw Exception('重定向次数过多');
            final location = response.headers['location'];
            if (location == null) throw Exception('重定向缺少location');
            await response.stream.listen(null).cancel();
            final redirectReq = http.Request('GET', Uri.parse(location));
            if (downloaded > 0)
              redirectReq.headers['Range'] = 'bytes=$downloaded-';
            response = await client
                .send(redirectReq)
                .timeout(const Duration(seconds: 30));
          }

          // 200=全量（服务器不支持Range或从头开始）；206=续传成功
          if (response.statusCode != 200 && response.statusCode != 206) {
            throw Exception('HTTP ${response.statusCode}');
          }
          if (response.statusCode == 200 && downloaded > 0) {
            // 服务器忽略Range给了全量，重置到文件头
            await sink.flush();
            await sink.close();
            file.deleteSync();
            downloaded = 0;
            sink = file.openWrite(mode: FileMode.append);
          }

          final total = assetSize;
          speedStart = DateTime.now();
          speedBytes = downloaded;

          await for (final chunk in response.stream) {
            sink.add(chunk);
            downloaded += chunk.length;
            final progress = total > 0 ? downloaded / total : 0.0;
            // 速度（每500ms更新一次UI，避免每chunk刷屏）
            final now = DateTime.now();
            if (now.difference(speedStart).inMilliseconds >= 500) {
              final secs = now.difference(speedStart).inMilliseconds / 1000.0;
              final speed = (downloaded - speedBytes) / secs; // bytes/s
              speedStart = now;
              speedBytes = downloaded;
              final speedStr = speed > 1024 * 1024
                  ? '${(speed / 1024 / 1024).toStringAsFixed(1)}MB/s'
                  : '${(speed / 1024).toStringAsFixed(0)}KB/s';
              var eta = '';
              if (speed > 0 && total > downloaded) {
                final remainSec = ((total - downloaded) / speed).round();
                eta = remainSec > 60
                    ? ' 约${(remainSec / 60).toStringAsFixed(0)}分钟'
                    : ' 约${remainSec}秒';
              }
              progressNotifier.value = progress;
              statusNotifier.value =
                  '下载中 ${(progress * 100).toInt()}% · $speedStr$eta '
                  '(${(downloaded / 1024 / 1024).toStringAsFixed(1)}/${(total / 1024 / 1024).toStringAsFixed(1)}MB)';
            }
          }
          await sink.flush();
        } catch (e) {
          // 网络中断：已下载部分保留在文件里，重试续传
          if (downloaded < assetSize && attempt < 3) {
            statusNotifier.value =
                '网络中断，第$attempt次重试（已下${(downloaded / 1024 / 1024).toStringAsFixed(1)}MB，断点续传）...';
            await Future.delayed(Duration(seconds: 2 * attempt));
            continue;
          }
          rethrow;
        }
      }
    } finally {
      await sink.close();
      client.close();
    }

    // 下载完成：meta使命完成（残留文件已完整，重进时大小==assetSize会被重下逻辑处理）
    if (metaFile.existsSync()) metaFile.deleteSync();
    progressNotifier.value = 1.0;
    statusNotifier.value = '下载完成';
  }

  /// Windows在线更新：下载win zip→解压到update_new→生成批处理（等待退出→替换→重启）→重启自身
  Future<void> _downloadAndUpdateWindows(
    int remoteBuild,
    String repo,
    String token,
    ValueNotifier<double> progressNotifier,
    ValueNotifier<String> statusNotifier,
  ) async {
    // exe所在目录
    final exePath = Platform.resolvedExecutable;
    final appDir = File(exePath).parent;

    statusNotifier.value = '获取版本信息...';
    final releaseResp = await http
        .get(
          Uri.parse(
            'https://api.github.com/repos/$repo/releases/tags/v$remoteBuild',
          ),
          headers: {
            'Authorization': 'token $token',
            'Accept': 'application/vnd.github.v3+json',
          },
        )
        .timeout(const Duration(seconds: 30));
    if (releaseResp.statusCode != 200) {
      throw Exception('获取版本信息失败: HTTP ${releaseResp.statusCode}');
    }
    final releaseJson = jsonDecode(releaseResp.body) as Map<String, dynamic>;
    final assets = releaseJson['assets'] as List? ?? [];
    // 找win zip（Actions上传名为novel_analyzer_win.zip）
    Map<String, dynamic>? winAsset;
    for (final a in assets) {
      if (a is Map && (a['name'] as String? ?? '').contains('win')) {
        winAsset = Map<String, dynamic>.from(a);
        break;
      }
    }
    if (winAsset == null) {
      throw Exception('该版本没有Windows包（novel_analyzer_win.zip）');
    }
    final assetId = winAsset['id'];
    final assetSize = winAsset['size'] as int? ?? 0;

    // 下载zip（公共断点续传下载器：Android APK与win zip共用）
    final zipPath = '${appDir.path}\\update_new.zip';
    await _downloadAssetWithResume(
      remoteBuild: remoteBuild,
      repo: repo,
      token: token,
      assetId: assetId as int,
      assetSize: assetSize,
      filePath: zipPath,
      progressNotifier: progressNotifier,
      statusNotifier: statusNotifier,
    );

    progressNotifier.value = 1.0;
    statusNotifier.value = '下载完成，准备安装...';
    if (mounted) Navigator.pop(context);

    // 升级批处理：等1秒（本进程退出）→删旧exe目录文件→copy新文件→重启
    // 注意不能用r''原始字符串包${}——插值不生效会写出字面量"${appDir.path}\update.bat"（v187修复）
    final batPath = '${appDir.path}\\update.bat';
    final bat =
        '''
@echo off
timeout /t 2 /nobreak >nul
taskkill /f /im novel_analyzer.exe >nul 2>&1
cd /d "${appDir.path}"
xcopy /e /y "update_new\\" .
del /q update_new.zip >nul 2>&1
rmdir /s /q update_new >nul 2>&1
start "" novel_analyzer.exe
del /q update.bat
''';
    File(batPath).writeAsStringSync(bat.replaceAll('\n', '\r\n'));

    // 解压zip到update_new（用PowerShell Expand-Archive）
    final extractResult = await Process.run('powershell', [
      '-NoProfile',
      '-Command',
      'Expand-Archive -Path "' +
          zipPath +
          '" -DestinationPath "' +
          appDir.path +
          r'\' +
          'update_new" -Force',
    ]);
    if (extractResult.exitCode != 0) {
      throw Exception('解压失败: ${extractResult.stderr}');
    }

    // 启动升级脚本并退出APP
    await Process.start('cmd', [
      '/c',
      batPath,
    ], mode: ProcessStartMode.detached);
    exit(0);
  }

  Future<void> _downloadAndInstall(int remoteBuild,
      {required String repo, required String token}) async {
    // 用ValueNotifier驱动进度更新
    final progressNotifier = ValueNotifier<double>(0);
    final statusNotifier = ValueNotifier<String>('准备下载...');

    // 显示下载进度对话框
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('下载更新'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ValueListenableBuilder<double>(
              valueListenable: progressNotifier,
              builder: (ctx, val, _) =>
                  LinearProgressIndicator(value: val > 0 ? val : null),
            ),
            const SizedBox(height: 8),
            ValueListenableBuilder<String>(
              valueListenable: statusNotifier,
              builder: (ctx, val, _) =>
                  Text(val, style: const TextStyle(fontSize: 13)),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
            },
            child: const Text('取消'),
          ),
        ],
      ),
    );

    try {
      // Windows版：下载novel_analyzer_win.zip→解压→升级脚本替换重启
      if (Platform.isWindows) {
        await _downloadAndUpdateWindows(
          remoteBuild,
          repo,
          token,
          progressNotifier,
          statusNotifier,
        );
        return;
      }
      // 用外部存储目录（安装器能访问），不用内部缓存
      Directory? dir = await getExternalStorageDirectory();
      if (dir == null) dir = await getTemporaryDirectory();
      final filePath = '${dir.path}/novel_analyzer_update.apk';
      final file = File(filePath);

      // 私有仓库：先用GitHub API获取asset的下载URL（需要token认证）
      statusNotifier.value = '获取下载链接...';
      final releaseResp = await http
          .get(
            Uri.parse(
              'https://api.github.com/repos/$repo/releases/tags/v$remoteBuild',
            ),
            headers: {
              'Authorization': 'token $token',
              'Accept': 'application/vnd.github.v3+json',
            },
          )
          .timeout(const Duration(seconds: 30));
      if (releaseResp.statusCode != 200) {
        throw Exception('获取版本信息失败: HTTP ${releaseResp.statusCode}');
      }
      final releaseJson = jsonDecode(releaseResp.body) as Map<String, dynamic>;
      final assets = releaseJson['assets'] as List? ?? [];
      if (assets.isEmpty) {
        throw Exception('该版本没有可下载的APK文件');
      }
      final assetId = assets[0]['id'];
      final assetName = assets[0]['name'];
      final assetSize = assets[0]['size'] as int? ?? 0;

      // 公共断点续传下载器（Android APK与win zip共用）
      await _downloadAssetWithResume(
        remoteBuild: remoteBuild,
        repo: repo,
        token: token,
        assetId: assetId as int,
        assetSize: assetSize,
        filePath: filePath,
        progressNotifier: progressNotifier,
        statusNotifier: statusNotifier,
      );

      statusNotifier.value = '下载完成，正在安装...';
      if (mounted) Navigator.pop(context);

      // 检查文件是否存在且大小正确
      if (!file.existsSync()) {
        if (mounted)
          AppState.instance.apiLog('下载文件不存在');;
        return;
      }
      final fileSize = await file.length();
      debugPrint('APK downloaded: $filePath ($fileSize bytes)');

      // 调起系统安装器
      final result = await OpenFilex.open(filePath);
      debugPrint('OpenFilex result: ${result.type} ${result.message}');
      if (result.type != ResultType.done) {
        if (mounted)
          AppState.instance.apiLog('安装提示: ${result.message} (文件: ${(fileSize / 1024 / 1024).toStringAsFixed(1)}MB)');;
      }
    } catch (e) {
      progressNotifier.dispose();
      statusNotifier.dispose();
      if (mounted) {
        Navigator.pop(context);
        AppState.instance.apiLog('下载更新失败: $e');;
      }
    }
  }

  // ===== 预设管理 =====
  void _applyPreset(AppState state, Preset preset) {
    final config = preset.toApiConfig();
    state.saveApiConfig('main', config);
    AppState.instance.apiLog('已应用预设「${preset.name}」到主页API');;
  }

  void _deletePreset(AppState state, Preset preset) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除预设'),
        content: Text('确定删除预设「${preset.name}」？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            onPressed: () {
              state.presets.removeWhere((p) => p.name == preset.name);
              state.savePresets();
              Navigator.pop(ctx);
            },
            child: const Text('删除'),
          ),
        ],
      ),
    );
  }
}
