import 'dart:io';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider/path_provider.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart'
    show kIsWeb, defaultTargetPlatform, TargetPlatform, debugPrint;

/// 存储服务 — 替代原NativeFS
/// 文件组织: {baseDir}/books/{bookId}/*.json + {baseDir}/global/*.json
/// 存储模式: public（公共Documents目录）或 appprivate（app专属外部存储）
class StorageService {
  static const String _dataDirName = 'novel_analyzer_flutter';
  static const String _packageName = 'com.luckpala.novel_analyzer';

  Directory? _baseDir;

  /// 存储根绝对路径（v385：导出/分享用，含桌面与appprivate各模式；未初始化返回''）
  String get baseDirPath => _baseDir?.path ?? '';
  String _currentBook = '';
  String _storageMode = ''; // 'public' 或 'appprivate'

  /// 存储模式
  String get storageMode => _storageMode;

  /// 初始化存储目录
  /// [mode] 'public'=公共目录, 'appprivate'=app专属, ''=自动检测
  Future<void> init({String mode = ''}) async {
    // 桌面平台（win/mac/linux）：固定用户Documents目录，无Android存储模式概念
    if (_isDesktop) {
      _baseDir = await _desktopDir();
      _storageMode = 'desktop';
      await _ensureDirs();
      await _loadCurrentBook();
      return;
    }
    if (mode.isEmpty) {
      // 读取已保存的存储模式
      final prefs = await SharedPreferences.getInstance();
      mode = prefs.getString('storage_mode') ?? '';
    }

    if (mode.isEmpty) {
      // 首次启动：自动检测
      _baseDir = await _autoDetectDir();
    } else {
      _storageMode = mode;
      _baseDir = await _getStorageDirForMode(mode);
      if (_baseDir == null || !_canWriteTo(_baseDir!)) {
        // 所选模式暂不可用（如覆盖安装后权限延迟生效）
        // 关键：不能盲fallback到空目录——优先找回有数据的目录，防止"书目被清空"
        debugPrint('[Storage] 存储模式 $mode 不可写，尝试找回数据目录...');
        _baseDir = await _findDataDir() ?? await _autoDetectDir();
        _storageMode = '';
      }
    }
    await _ensureDirs();
    await _loadCurrentBook();
  }

  /// 桌面平台（Windows/macOS/Linux）：存储根=用户Documents/novel_analyzer_flutter
  /// （Android走原有/storage/emulated/0逻辑不变）
  static bool get _isDesktop =>
      !Platform.isAndroid && !Platform.isIOS && !kIsWeb;

  Future<Directory?> _desktopDir() async {
    try {
      final docs = await getApplicationDocumentsDirectory();
      final dir = Directory('${docs.path}/$_dataDirName');
      if (!dir.existsSync()) dir.createSync(recursive: true);
      return dir;
    } catch (_) {
      return null;
    }
  }

  /// 纯路径定位目录（不创建、不写测试）——找回数据专用
  /// v471事故教训：_findDataDir之前复用_getStorageDirForMode（内部带_canWriteTo写测试），
  /// 覆盖安装后公共目录权限延迟生效时public返回null进不了候选列表→"找回数据"保护完全失效
  Directory? _dirPathForMode(String mode) {
    final List<String> paths;
    if (mode == 'public') {
      paths = ['/storage/emulated/0/Documents', '/sdcard/Documents'];
    } else if (mode == 'appprivate') {
      paths = [
        '/storage/emulated/0/Android/data/$_packageName/files',
        '/sdcard/Android/data/$_packageName/files',
      ];
    } else {
      paths = ['/data/data/$_packageName/files'];
    }
    for (final p in paths) {
      final dir = Directory('$p/$_dataDirName');
      if (dir.existsSync()) return dir;
    }
    return null;
  }

  /// 在两个候选目录中找有数据的（books/下有子目录或global/book_list存在）
  /// 覆盖安装后公共目录权限延迟生效时，避免静默切到空目录导致书目"消失"
  /// v472修复：用_dirPathForMode纯定位（public目录只要存在就进候选），数据存在优先于可写
  Future<Directory?> _findDataDir() async {
    final candidates = <Directory>[];
    for (final m in ['public', 'appprivate']) {
      final d = _dirPathForMode(m);
      if (d != null) candidates.add(d);
    }
    for (final d in candidates) {
      try {
        final booksDir = Directory('${d.path}/books');
        final bookListFile = File('${d.path}/global/book_list');
        if (bookListFile.existsSync() && bookListFile.lengthSync() > 10)
          return d; // 有书目列表
        if (booksDir.existsSync()) {
          final subs = booksDir.listSync().whereType<Directory>().toList();
          if (subs.isNotEmpty) return d; // 有书目数据目录
        }
      } catch (_) {}
    }
    return null;
  }

  /// 设置存储模式（用户选择后调用）
  Future<bool> setStorageMode(String mode) async {
    if (_isDesktop) return true; // 桌面固定Documents，无模式切换
    final dir = await _getStorageDirForMode(mode);
    if (dir == null || !_canWriteTo(dir)) return false;
    _storageMode = mode;
    _baseDir = dir;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('storage_mode', mode);
    await _ensureDirs();
    return true;
  }

  /// 自动检测可用存储目录
  Future<Directory?> _autoDetectDir() async {
    // 先试公共目录
    final publicDir = await _getStorageDirForMode('public');
    if (publicDir != null && _canWriteTo(publicDir)) {
      _storageMode = 'public';
      // v472: 不写prefs——此函数也被init()的fallback路径调用，写prefs会把权限延迟时的
      // 错误选择（appprivate）固化，下次启动直接进空目录。用户显式setStorageMode才持久化。
      return publicDir;
    }

    // 再试app专属目录
    final privateDir = await _getStorageDirForMode('appprivate');
    if (privateDir != null && _canWriteTo(privateDir)) {
      _storageMode = 'appprivate';
      return privateDir;
    }

    // 最终fallback
    final fallback = Directory('/data/data/$_packageName/files/$_dataDirName');
    if (!fallback.existsSync()) {
      try {
        fallback.createSync(recursive: true);
      } catch (e) {}
    }
    _storageMode = 'internal';
    return fallback;
  }

  /// 按模式获取存储目录
  Future<Directory?> _getStorageDirForMode(String mode) async {
    if (mode == 'public') {
      // 公共Documents目录（文件管理器可见，覆盖安装不丢数据）
      final paths = ['/storage/emulated/0/Documents', '/sdcard/Documents'];
      for (final p in paths) {
        try {
          final dir = Directory('$p/$_dataDirName');
          if (!dir.existsSync()) dir.createSync(recursive: true);
          if (_canWriteTo(dir)) return dir;
        } catch (e) {}
      }
      return null;
    }

    if (mode == 'appprivate') {
      // app专属外部存储（无需权限，覆盖安装不丢数据，文件管理器在Android/data/下可见）
      final paths = [
        '/storage/emulated/0/Android/data/$_packageName/files',
        '/sdcard/Android/data/$_packageName/files',
      ];
      for (final p in paths) {
        try {
          final dir = Directory('$p/$_dataDirName');
          if (!dir.existsSync()) dir.createSync(recursive: true);
          if (_canWriteTo(dir)) return dir;
        } catch (e) {}
      }
      return null;
    }

    return null;
  }

  bool _canWriteTo(Directory dir) {
    try {
      final test = File('${dir.path}/.write_test');
      test.writeAsStringSync('ok');
      test.deleteSync();
      return true;
    } catch (e) {
      return false;
    }
  }

  /// 确保基础目录存在
  Future<void> _ensureDirs() async {
    if (_baseDir == null) return;
    final globalDir = Directory('${_baseDir!.path}/global');
    if (!globalDir.existsSync()) globalDir.createSync(recursive: true);
    final booksDir = Directory('${_baseDir!.path}/books');
    if (!booksDir.existsSync()) booksDir.createSync(recursive: true);
  }

  /// 加载当前书目
  /// v222：模糊匹配的剥除规则——空格/全角空格/特殊字符(!！:：?？*)全剥
  static String _stripForMatch(String name) {
    return name
        .replaceAll(' ', '')
        .replaceAll('\u3000', '')
        .replaceAll(RegExp(r'[!！:：?？*]'), '');
  }

  /// v222：书名归一化——剥零宽字符（trim去不掉的U+200B/200C/200D/FEFF
  /// 和首尾全角空格U+3000）。输入法/剪贴板可能带出隐形字符，导致
  /// bookPath指向不存在的目录=切换后数据"消失"（磁盘文件完好）
  static String _normalizeBookName(String name) {
    var n = name;
    n = n.replaceAll('\u200B', '').replaceAll('\u200C', '')
         .replaceAll('\u200D', '').replaceAll('\uFEFF', '');
    n = n.trim();
    // 首尾全角空格
    while (n.startsWith('\u3000')) n = n.substring(1);
    while (n.endsWith('\u3000')) n = n.substring(0, n.length - 1);
    return n.trim();
  }

  Future<void> _loadCurrentBook() async {
    // 先从SharedPreferences读
    final prefs = await SharedPreferences.getInstance();
    _currentBook = _normalizeBookName(prefs.getString('current_book') ?? '');

    // 再尝试从文件读
    if (_currentBook.isEmpty) {
      final data = readFile('_current_book.txt');
      if (data != null && data.isNotEmpty) {
        _currentBook = _normalizeBookName(data);
      }
    }

    // 如果仍然为空，列出已有书目取第一个
    if (_currentBook.isEmpty) {
      final books = listBooks();
      if (books.isNotEmpty) {
        _currentBook = books.first;
        await _saveCurrentBook();
      }
    }

    // v222：当前书名与磁盘目录对不上时模糊找回——
    // 剥空格+特殊字符（!：?等曾致存储层拒绝的字符）后比对，
    // 匹配到就改用真名（新旧近名目录分裂的自动愈合）
    if (_currentBook.isNotEmpty) {
      final realBooks = listBooks();
      if (!realBooks.contains(_currentBook)) {
        final norm = _stripForMatch(_currentBook);
        final match = realBooks.where(
          (b) => _stripForMatch(b) == norm,
        ).toList();
        if (match.isNotEmpty) {
          debugPrint('[Book] 书名不匹配已自动纠正：$_currentBook → ${match.first}');
          _currentBook = match.first;
          await _saveCurrentBook();
        }
      }
    }

    // 确保当前书目目录存在
    if (_currentBook.isNotEmpty) {
      makeDir('books/$_currentBook');
      makeDir('books/$_currentBook/writings');
    }
  }

  Future<void> _saveCurrentBook() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('current_book', _currentBook);
    writeFile('_current_book.txt', _currentBook);
  }

  // ===== 基础文件操作 =====

  String get basePath => _baseDir?.path ?? '';
  String get currentBook => _currentBook;

  /// 书目路径前缀
  String get bookPath => _currentBook.isNotEmpty ? 'books/$_currentBook/' : '';

  /// v386：确保公共目录可写——老手机（Android<=9）公共Documents需要运行时存储权限，
  /// 主工程从未申请过=备份/导出静默失败。返回false=用户拒绝（调用方应提示）
  Future<bool> ensurePublicWritable() async {
    if (_isDesktop || _storageMode != 'public') return true;
    try {
      const ch = MethodChannel('com.luckpala/novel_analyzer');
      return await ch.invokeMethod<bool>('requestStoragePermission') ?? false;
    } catch (_) {
      return true; // 通道异常不阻塞（新系统本就无需授权）
    }
  }

  /// 写文件
  bool writeFile(String filename, String data) {
    try {
      if (_baseDir == null) return false;
      final file = File('${_baseDir!.path}/$filename');
      final parent = file.parent;
      if (!parent.existsSync()) parent.createSync(recursive: true);
      // v221：原子写——先写tmp再rename。9MB的chapters.json直接覆盖写时
      // 若APP被切后台/杀进程，写一半中断=截断文件（加载时jsonDecode失败
      // 被静默清空=用户"书目消失"事故根因）。rename原子，要么旧要么新
      final tmp = File('${file.path}.tmp');
      tmp.writeAsStringSync(data, encoding: utf8, flush: true);
      tmp.renameSync(file.path);
      return true;
    } catch (e) {
      print('writeFile error: $e');
      return false;
    }
  }

  /// v763：文件修改时间毫秒值（相对路径按_baseDir解析；异常/不存在=null）
  /// detection页排序用——此前页面层File(path)拿相对路径开文件=逐文件异常
  /// 被catch吞掉→列表整体清空（v763实测事故）
  int? fileMtime(String filename) {
    try {
      if (_baseDir == null) return null;
      final f = File('${_baseDir!.path}/$filename');
      if (!f.existsSync()) return null;
      return f.lastModifiedSync().millisecondsSinceEpoch;
    } catch (_) {
      return null;
    }
  }

  /// 读文件（v221：解码失败不再静默null——剥BOM+坏字节兜底解码）
  String? readFile(String filename) {
    try {
      if (_baseDir == null) return null;
      final file = File('${_baseDir!.path}/$filename');
      if (!file.existsSync()) return null;
      final bytes = file.readAsBytesSync();
      // 剥UTF-8 BOM（EF BB BF）——某些工具会给文件加头导致解码路径异常
      var start = 0;
      if (bytes.length >= 3 &&
          bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF) {
        start = 3;
      }
      try {
        return utf8.decode(bytes.sublist(start), allowMalformed: false);
      } catch (_) {
        // 坏字节兜底：允许U+FFFD替换，不整文件判死
        return utf8.decode(bytes.sublist(start), allowMalformed: true);
      }
    } catch (e) {
      print('readFile error: $e');
      return null;
    }
  }

  /// 删除文件
  bool deleteFile(String filename) {
    try {
      if (_baseDir == null) return false;
      final file = File('${_baseDir!.path}/$filename');
      if (file.existsSync()) {
        file.deleteSync();
        return true;
      }
      return false;
    } catch (e) {
      return false;
    }
  }

  /// 文件是否存在
  bool fileExists(String filename) {
    if (_baseDir == null) return false;
    return File('${_baseDir!.path}/$filename').existsSync();
  }

  /// 列出目录下文件
  List<String> listFiles(String? subdir) {
    try {
      if (_baseDir == null) return [];
      final dir = subdir == null || subdir.isEmpty
          ? _baseDir!
          : Directory('${_baseDir!.path}/$subdir');
      if (!dir.existsSync() || !dir.existsSync()) return [];
      return dir
          .listSync()
          .whereType<File>()
          .map((f) => f.uri.pathSegments.last)
          .toList();
    } catch (e) {
      return [];
    }
  }

  /// 列出目录下子目录
  List<String> listDirs(String? subdir) {
    try {
      if (_baseDir == null) return [];
      final dir = subdir == null || subdir.isEmpty
          ? _baseDir!
          : Directory('${_baseDir!.path}/$subdir');
      if (!dir.existsSync()) return [];
      return dir
          .listSync()
          .whereType<Directory>()
          .map((d) => d.uri.pathSegments.last)
          .toList();
    } catch (e) {
      return [];
    }
  }

  /// 创建目录
  bool makeDir(String path) {
    try {
      if (_baseDir == null) return false;
      final dir = Directory('${_baseDir!.path}/$path');
      if (!dir.existsSync()) dir.createSync(recursive: true);
      return true;
    } catch (e) {
      return false;
    }
  }

  /// 删除目录（递归）
  bool deleteDir(String path) {
    try {
      if (_baseDir == null) return false;
      final dir = Directory('${_baseDir!.path}/$path');
      if (dir.existsSync()) {
        dir.deleteSync(recursive: true);
        return true;
      }
      return true;
    } catch (e) {
      return false;
    }
  }

  // ===== 书目管理 =====

  /// 列出所有书目
  List<String> listBooks() {
    final dirs = listDirs('books');
    return dirs
        .where((d) => d.isNotEmpty && d != 'migrated.flag' && d != '.')
        .toList();
  }

  /// 创建书目
  bool createBook(String bookId) {
    makeDir('books/$bookId');
    makeDir('books/$bookId/writings');
    return true;
  }

  /// 切换书目
  Future<void> setBook(String bookId) async {
    _currentBook = bookId;
    await _saveCurrentBook();
    makeDir('books/$bookId');
    makeDir('books/$bookId/writings');
  }

  /// 删除书目
  bool deleteBook(String bookId) {
    return deleteDir('books/$bookId');
  }

  // ===== Per-book 数据文件路径 =====

  /// 获取per-book文件路径
  String bookFile(String key) {
    final p = bookPath;
    switch (key) {
      case 'novel_chapters':
        return '${p}chapters.json';
      case 'novel_arc_scan':
        return '${p}arc_scan.json';
      case 'novel_arc_analyses':
        return '${p}arc_analyses.json';
      case 'novel_arc_scenes':
        return '${p}arc_scenes.json';
      case 'novel_narrative_lines':
        return '${p}narrative_lines.json';
      case 'novel_report':
        return '${p}report.md';
      case 'novel_report_meta':
        return '${p}report_meta.json';
      case 'worldbook':
      case 'novel_worldbook':
        return '${p}worldbook.json';
      case 'novel_writings':
        return '${p}writings.json';
      case 'novel_writing_prompt':
        return '${p}writing_prompt.txt';
      case 'novel_writing_scene_prompts':
        return '${p}writing_scene_prompts.json';
      case 'novel_writing_attachments':
        return '${p}writing_attachments.json';
      case 'novel_writing_prompt_preview':
        return '${p}writing_prompt_preview.flag';
      case 'novel_writing_model_note':
        return '${p}writing_model_note.flag';
      default:
        return '${p}$key.json';
    }
  }

  /// 获取全局文件路径
  String globalFile(String key) {
    switch (key) {
      case 'novel_writing_api':
        return 'global/writing_api.json';
      case 'novel_detect_api':
        return 'global/detect_api.json';
      case 'novel_wb_api':
        return 'global/wb_api.json';
      case 'novel_analysis_api':
        return 'global/analysis_api.json';
      case 'novel_scene_api':
        return 'global/scene_api.json';
      case 'saved_presets':
        return 'global/saved_presets.json';
      case 'zhipu_api_key':
        return 'global/zhipu_api_key.txt';
      case 'zhipu_model':
        return 'global/zhipu_model.txt';
      case 'api_provider':
        return 'global/api_provider.txt';
      case 'api_base':
        return 'global/api_base.txt';
      case 'api_type':
        return 'global/api_type.txt';
      case 'custom_api_key':
        return 'global/custom_api_key.txt';
      case 'custom_model_name':
        return 'global/custom_model_name.txt';
      case 'api_temperature':
        return 'global/api_temperature.txt';
      case 'api_max_tokens':
        return 'global/api_max_tokens.txt';
      case 'main_format_mode':
        return 'global/main_format_mode.txt';
      case 'scan_step_size':
        return 'global/scan_step_size.txt';
      default:
        return 'global/$key.txt';
    }
  }

  /// 读取per-book JSON数据
  dynamic readBookData(String key) {
    final path = bookFile(key);
    final raw = readFile(path);
    if (raw == null || raw.isEmpty) return null;
    try {
      return jsonDecode(raw);
    } catch (e) {
      // 非JSON文件直接返回原始字符串
      return raw;
    }
  }

  /// 写入per-book JSON数据
  bool writeBookData(String key, dynamic data) {
    final path = bookFile(key);
    if (data is String) {
      return writeFile(path, data);
    }
    return writeFile(path, jsonEncode(data));
  }

  /// 读取全局设置
  String? readGlobal(String key) {
    return readFile(globalFile(key));
  }

  /// 写入全局设置
  bool writeGlobal(String key, String value) {
    return writeFile(globalFile(key), value);
  }

  /// 读取全局JSON设置
  dynamic readGlobalJson(String key) {
    final raw = readGlobal(key);
    if (raw == null || raw.isEmpty) return null;
    try {
      return jsonDecode(raw);
    } catch (e) {
      return null;
    }
  }

  /// 写入全局JSON设置
  bool writeGlobalJson(String key, dynamic data) {
    return writeGlobal(key, jsonEncode(data));
  }

  /// saveGlobalJson 别名（兼容AppState调用）
  bool saveGlobalJson(String key, dynamic data) => writeGlobalJson(key, data);

  /// 创作文件路径（简短版，兼容AppState.saveWriting调用）
  String getWritingPath(
    String arcKey,
    int sceneIdx,
    String sceneName,
    String chapterRange,
    int version,
  ) {
    return getWritingFilePath(
      arcKey,
      sceneIdx,
      sceneName,
      chapterRange,
      version,
    );
  }

  /// 创作文件路径
  String getWritingFilePath(
    String arcKey,
    int sceneIdx,
    String sceneName,
    String chapterRange,
    int version,
  ) {
    final p = bookPath;
    final safeName = sceneName
        .replaceAll(RegExp(r'[\\/:*?"<>|,]'), '_')
        .substring(0, sceneName.length > 30 ? 30 : sceneName.length);
    final cr = chapterRange
        .replaceAll(RegExp(r'[\\/:*?"<>|,]'), '_')
        .substring(0, chapterRange.length > 20 ? 20 : chapterRange.length);
    var fname = '弧线${arcKey}_场景${sceneIdx + 1}';
    // v383：一个场景算一章——文件名章节号用场景序号递增（原chapterRange两场景同为"第1章"）
    final crAdj = cr.replaceAll(
      RegExp(r'第\d+(-\d+)?章'),
      '第${sceneIdx + 1}章',
    );
    if (crAdj.isNotEmpty) fname += '_$crAdj';
    if (safeName.isNotEmpty) fname += '_$safeName';
    if (version > 1) fname += '_v$version';
    fname += '.txt';
    return '${p}writings/$fname';
  }

  /// 导出文件路径（如worldbook_report.md）
  String getExportPath(String filename) {
    final p = bookPath;
    return '${p}exports/$filename';
  }

  /// 备份文件路径（存到根目录的backups/下，不依附于任何书目）
  String getBackupPath(String filename) {
    return 'backups/$filename';
  }

  /// 获取存储信息
  String getStorageInfo() {
    if (_baseDir == null) return 'Not initialized';
    final modeDesc = {
      'public': '公共目录（文件管理器可见）',
      'appprivate': '专属目录（Android/data下）',
      'internal': '内部存储',
      '': '未设置',
    };
    final sb = StringBuffer();
    sb.writeln('存储模式：${modeDesc[_storageMode] ?? _storageMode}');
    sb.writeln('路径：${_baseDir!.path}');
    sb.writeln('可读：${_baseDir!.existsSync()}');
    sb.writeln('可写：${_canWriteTo(_baseDir!)}');
    sb.writeln('当前书目：$_currentBook');
    return sb.toString();
  }
}
