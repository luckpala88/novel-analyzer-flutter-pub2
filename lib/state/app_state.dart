import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/api_config.dart';
import '../models/chapter.dart';
import '../models/arc.dart';
import '../models/scene.dart';
import '../utils/json_repair.dart';
import '../utils/prompt_builder.dart';
import '../utils/text_cleaner.dart';
import '../models/world_book.dart';
import '../models/writing.dart';
import '../models/preset.dart';
import '../services/storage_service.dart';
import '../services/api_service.dart';
import '../services/cloud_sync_service.dart';
import '../services/tts_service.dart';

/// 全局应用状态
/// 对应原版JS的 var state = {...} 和 NativeBridge
class AppState extends ChangeNotifier {
  /// v264：伪JSON连击计数（运行时，不持久化）——同会话连续坏格式≥2=中转
  /// 稳定剥response_format，跳过格式重试直接剥壳抢救（gcli中转实测3/3）
  int pseudoJsonStreak = 0;

  final StorageService storage = StorageService();

  // ===== UI状态持久化（per-book：books/{书}/ui_state.json）=====
  /// 读当前书某页面状态（如 state.uiGet('analysis', 'expandedShots')）
  dynamic uiGet(String page, String key) {
    final raw = storage.readBookData('ui_state') as Map<String, dynamic>?;
    if (raw == null) return null;
    final pageMap = raw[page];
    if (pageMap is! Map) return null;
    return pageMap[key];
  }

  /// 写当前书某页面状态（合并写入；页面状态变更时调用）
  void uiSet(String page, String key, dynamic value) {
    try {
      final raw =
          storage.readBookData('ui_state') as Map<String, dynamic>? ?? {};
      final pageMap = (raw[page] is Map)
          ? raw[page] as Map<String, dynamic>
          : <String, dynamic>{};
      pageMap[key] = value;
      raw[page] = pageMap;
      storage.writeBookData('ui_state', raw);
    } catch (_) {}
  }

  final ApiService api = ApiService();
  final CloudSyncService cloudSync = CloudSyncService();
  final TTSService tts = TTSService();

  // ===== API配置 =====
  // 主页API
  ApiConfig mainApi = ApiConfig();
  // 创作API
  ApiConfig writingApi = ApiConfig();
  // 审核API
  ApiConfig detectApi = ApiConfig();
  // 世界书API
  ApiConfig wbApi = ApiConfig();
  // 场景API
  ApiConfig sceneApi = ApiConfig();
  ApiConfig arcApi = ApiConfig();
  // 拆解API
  ApiConfig analysisApi = ApiConfig();

  // 预设列表
  List<Preset> presets = [];

  // ===== 书目管理 =====
  String currentBook = '';
  List<String> bookList = [];

  // ===== 章节数据 =====
  List<Chapter> chapters = [];

  // ===== 弧线扫描 =====
  ArcScan? arcScan;
  // v431：全局场景流——场景脱离弧线独立存在，按章流窗口划分，弧线分组引用
  List<Scene> globalScenes = [];
  int globalSceneScannedUpTo = 0; // 已划分到的章节（1-based，失败停机续跑锚点）
  // v534：字符级续切锚点——剪断时按保留末场景切片精确算出的章索引+章内偏移，
  // 重扫窗口直接从该偏移喂文本，不做任何文本搜索（短句indexOf会被两更重头骗）
  int sceneResumeChapIdx = -1;
  int sceneResumeOffset = 0;
  int globalGroupedUpTo = 0; // v439：已分组场景数（弧线分组断点，增量生成锚点）
  int sceneStepSize = 4; // v455：场景扫描步进（每批章数，默认4）
  // v461：全局场景/分组busy——单一事实源（此前各页State字段+闭包翻转，
  // 多重翻转/漏翻转导致终止后卡true进度条走、生成时无动画等连环状态错乱）
  bool sceneStreamBusy = false;
  int groupBatchSize = 30; // v441：弧线分组步进（每批场景数）
  int scanStepSize = 4; // v346：默认步进4（v345实测步进2太慢；B首句语义下步进与切点精度解耦）
  // v345：字数步进移除——大章书自动退化单章无意义，章数模式足够（用户裁决）
  bool isScanning = false;

  // ===== 场景划分 =====
  Map<String, List<Scene>> arcScenes = {}; // key: arc number
  bool isDividingScenes = false;

  // ===== 弧线分析（分镜） =====
  Map<String, ArcAnalysis> arcAnalyses = {}; // key: arc number
  bool isAnalyzing = false;
  // 分析元数据：跟踪哪些弧线已拆解
  Map<String, dynamic> reportMeta = {}; // {analyzedArcNumbers: []}
  // 模式总结
  Map<String, dynamic>? lastPatternSummary;
  String lastOverallSummary = '';
  // 叙事线分类
  List<Map<String, dynamic>> narrativeLines = [];

  // ===== 世界书 =====
  WorldBook? worldBook;
  bool isGeneratingWB = false;

  // ===== 创作文档 =====
  Map<String, WritingItem> writings = {}; // key: writing key
  bool isGeneratingWriting = false;
  // 创作提示词
  String writingPrompt = '';
  Map<String, String> writingScenePrompts = {}; // key: arcKey_sceneIdx
  List<Map<String, dynamic>> writingAttachments = [];
  bool writingPromptPreview = false;
  bool writingImitateAuthor = false; // v313：模仿原文作者（创作时注入弧线原文范文）
  bool writingPlagiarismCheck = true; // v755：防抄袭检测开关（关=不检测不比较）
  bool writingPostCheck = true; // v758：分镜校验开关（正文是否按分镜维度创作；字数只是其中一项）
  bool writingFreeMode = false; // v545：自由创作——不注入世界书分镜结构（其余照注）
  bool writingLeanShots = false; // v592：精简分镜
  int writingShotStep = 1; // v642：逐镜批量步进（每次API生成N镜，1=传统逐镜）——屏蔽投放信息/文笔节奏/语感/笔墨（v612转场手法移出：它是镜间衔接指令）
  bool writingModelNote = false;
  bool nameReplaceEnabled = false; // v388：二创页按映射表替换原著名（flag持久化）
  /// v266：逐镜分步生成开关（默认开）——每镜单独API，结构行由代码从
  /// 世界书确定性插入，AI只输出纯正文（用户架构方案：信息与正文天然
  /// 分离，格式问题源头消失）
  bool writingShotByShot = true;
  // v469对齐：各功能预览开关（scene/shot/wb/detect）
  bool scenePromptPreview = false;
  bool shotPromptPreview = false;
  bool wbPromptPreview = false;
  bool detectPromptPreview = false;

  // ===== 审核文件 =====
  List<String> detectFiles = [];

  // ===== UI状态 =====
  bool isLoading = false;
  String loadingMessage = '';
  String currentTab = ''; // 一次性跳页指令：switchTab写入→AppShell消费后清''；空=无指令
  String mainFormatMode = 'compatible'; // 'json' or 'compatible'
  bool tokenLength = false; // 分镜篇幅标注
  bool funcAbstract = true; // v295：分镜功能抽象标注默认必选（开关已从场景/弧线页移除，分镜页prompt恒用）

  void setFuncAbstract(bool v) {
    funcAbstract = v;
    storage.writeGlobal('func_abstract', v ? '1' : '0');
    notifyListeners();
  }

  // ===== API日志 =====
  List<String> apiLogs = [];
  bool terminalPinned = false; // 终端常显（点过清理后保持显示空终端，不再自动隐藏）
  // API计时器状态
  // v203：计时器ValueNotifier化——原Timer每100ms notifyListeners让全App
  // （8个keep-alive重页面）每秒整体重建10次，UI线程饱和=生成任务中
  // 翻页点击经常无效的元凶。现在tick只更新Notifier，只有计时文本局部重建
  final ValueNotifier<bool> apiTimerRunning = ValueNotifier(false);

  /// v224：用户主动终止标志（终端abort按钮）——页面级批量循环统一检查，
  /// 任任务启动时清零。终端按钮此前只断当前请求，循环继续发下一请求
  bool userAborted = false;
  final ValueNotifier<double> apiTimerSeconds = ValueNotifier(0);
  // 生成状态（前台服务）
  int generationCount = 0;
  String generationMessage = '';

  /// 初始化
  Future<void> init() async {
    await storage.init();
    currentBook = storage.currentBook;
    await loadBookList();
    await loadAllData();
    await loadSettings();
    await cloudSync.init();
    _setupApiCallbacks();
  }

  /// 全局单例引用（页面_addLog不经过build也能写全局日志）
  static AppState instance = AppState();

  /// 公开日志入口：页面级日志（_addLog）也汇入全局终端，实现信息出口合一
  void apiLog(String msg) {
    final ts = DateTime.now();
    final tsStr =
        '${ts.hour.toString().padLeft(2, '0')}:'
        '${ts.minute.toString().padLeft(2, '0')}:'
        '${ts.second.toString().padLeft(2, '0')}.'
        '${ts.millisecond.toString().padLeft(3, '0').substring(0, 2)}';
    apiLogs.add('[$tsStr] $msg');
    if (apiLogs.length > 200) apiLogs.removeAt(0);
    notifyListeners();
  }

  void _setupApiCallbacks() {
    api.onLog = (msg) {
      final ts = DateTime.now();
      final tsStr =
          '${ts.hour.toString().padLeft(2, '0')}:'
          '${ts.minute.toString().padLeft(2, '0')}:'
          '${ts.second.toString().padLeft(2, '0')}.'
          '${ts.millisecond.toString().padLeft(3, '0').substring(0, 2)}';
      apiLogs.add('[$tsStr] $msg');
      if (apiLogs.length > 200) apiLogs.removeAt(0);
      notifyListeners();
    };
    api.onStartTimer = () {
      apiTimerRunning.value = true;
      apiTimerSeconds.value = 0;
      // 启动定时器每100ms更新（v203：只更新Notifier，不notifyListeners）
      _apiTimerStopwatch?.reset();
      _apiTimerStopwatch = Stopwatch()..start();
      _apiTimerTimer?.cancel();
      // v224：100ms→1秒（用户建议）——计时显示到0.1秒无意义，
      // 1秒刷新再降10倍开销；stopwatch保证精度不受影响
      _apiTimerTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (apiTimerRunning.value && _apiTimerStopwatch != null) {
          apiTimerSeconds.value =
              _apiTimerStopwatch!.elapsedMilliseconds / 1000.0;
        }
      });
      notifyListeners(); // 开始事件（低频）保持全局刷新
    };
    // v224：用户主动终止广播——页面级批量循环（扫描/拆解/生成）监听此标志
    api.onUserAbort = () {
      userAborted = true;
    };

    api.onStopTimer = () {
      apiTimerRunning.value = false;
      if (_apiTimerStopwatch != null) {
        apiTimerSeconds.value =
            _apiTimerStopwatch!.elapsedMilliseconds / 1000.0;
        _apiTimerStopwatch!.stop();
      }
      _apiTimerTimer?.cancel();
      notifyListeners(); // 结束事件（低频）保持全局刷新
    };
    api.onStartGen = (msg) {
      generationCount++;
      if (generationCount == 1) {
        generationMessage = msg;
        // 启动前台服务：息屏/后台保持CPU+WiFi（通知栏显示生成中）
        _genChannel.invokeMethod('startGen', {'msg': msg}).catchError((_) {});
        notifyListeners();
      }
    };
    api.onStopGen = () {
      if (generationCount > 0) generationCount--;
      if (generationCount == 0) {
        generationMessage = '';
        // 最后一个任务结束→停前台服务释放WakeLock/WiFiLock
        _genChannel.invokeMethod('stopGen').catchError((_) {});
        notifyListeners();
      }
    };
  }

  /// 清空API终端日志+计时归零（信息终端的"清理"按钮）
  void clearApiLogs() {
    terminalPinned = true; // 清屏但终端保持显示
    apiLogs.clear();
    apiTimerRunning.value = false;
    apiTimerSeconds.value = 0;
    _apiTimerTimer?.cancel();
    _apiTimerStopwatch?.stop();
    _apiTimerStopwatch?.reset();
    notifyListeners();
  }

  /// 生成任务前台服务通道（Android原生）
  static const _genChannel = MethodChannel(
    'com.luckpala/novel_analyzer/gen_service',
  );

  Stopwatch? _apiTimerStopwatch;
  Timer? _apiTimerTimer;

  /// 加载书目列表
  Future<void> loadBookList() async {
    // 先从全局文件读取book_list
    final savedList = storage.readGlobal('book_list');
    if (savedList != null && savedList.isNotEmpty) {
      try {
        final list = jsonDecode(savedList) as List;
        bookList = list
            .map((e) => e.toString())
            .where((e) => e.isNotEmpty)
            .toList();
      } catch (e) {
        bookList = [];
      }
    } else {
      // 文件没有 → SharedPreferences兜底（覆盖安装/目录切换防丢）
      try {
        final prefs = await SharedPreferences.getInstance();
        final raw = prefs.getString('book_list');
        if (raw != null && raw.isNotEmpty) {
          final list = jsonDecode(raw) as List;
          bookList = list
              .map((e) => e.toString())
              .where((e) => e.isNotEmpty)
              .toList();
        }
      } catch (_) {}
      if (bookList.isEmpty) {
        // 没有book_list文件，从目录扫描
        bookList = storage.listBooks();
      }
      if (bookList.isNotEmpty) {
        // 保存扫描结果到全局文件+prefs
        _persistBookList();
        _syncBookListPrefs();
      }
    }

    // 检查目录中有但book_list中没有的书目（可能是其他版本创建的）
    final dirBooks = storage.listBooks();
    var dirAdded = false;
    for (final b in dirBooks) {
      if (b.isNotEmpty && !bookList.contains(b)) {
        bookList.add(b);
        dirAdded = true;
      }
    }
    if (dirAdded) {
      _persistBookList();
      _syncBookListPrefs();
    }

    if (bookList.isEmpty && currentBook.isEmpty) {
      await createBook('默认');
    }
    // 一致性保护：currentBook存在但不在列表（book_list写入失败/时序）→目录补录+持久化
    if (currentBook.isNotEmpty && !bookList.contains(currentBook)) {
      final dirs = storage.listBooks();
      if (dirs.contains(currentBook) ||
          storage.readGlobal('book_list') == null) {
        bookList.add(currentBook);
        _persistBookList();
        _syncBookListPrefs();
      }
    }
    notifyListeners();
  }

  /// 书目列表双写SharedPreferences（覆盖安装防丢）
  Future<void> _syncBookListPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('book_list', jsonEncode(bookList));
    } catch (_) {}
  }

  /// 创建新书
  /// v222：book_list持久化加固——writeGlobal失败（HTML版遗留文件的
  /// 属主权限拒绝）时，删旧文件重建（新文件归自己，后续可写），再不行写prefs
  void _persistBookList() {
    final json = jsonEncode(bookList);
    final ok = storage.writeGlobal('book_list', json);
    if (!ok) {
      // 属主权限拒绝：删除旧文件（可能失败）→强制重建
      storage.deleteFile('global/book_list.txt');
      storage.writeGlobal('book_list', json);
    }
    _syncBookListPrefs(); // prefs永远双写（最终兜底）
  }

  Future<bool> createBook(String name) async {
    name = name.trim();
    if (name.isEmpty) return false;
    if (bookList.contains(name)) return false;
    storage.createBook(name);
    // v222：目录校验降级为警告——v221的硬拦截误伤正常建书（Android公共目录
    // listSync对新目录有延迟，校验误判"创建失败"→不登记→"建了书列表却没有"
    // 用户实测踩中）。现在：重试一次仍不见→照常登记但终端警告（宁可幽灵可删，
    // 不可吞书）
    if (!storage.listBooks().contains(name)) {
      storage.createBook(name);
      if (!storage.listBooks().contains(name)) {
        debugPrint('[Book] 目录暂未见于列表（可能延迟或特殊字符被拒）：$name——已登记，若数据异常请在终端查看警告');
      }
    }
    if (!bookList.contains(name)) bookList.add(name);
    // 保存book_list到全局文件+prefs双写（任一成功即可，loadBookList有兜底）
    _persistBookList();
    _syncBookListPrefs();
    // 任务运行中：书目创建+登记，但不切换（防止生成数据写进新书）
    if (generationCount > 0 || apiTimerRunning.value) {
      notifyListeners();
      return true;
    }
    await selectBook(name);
    return true;
  }

  /// 切换书目
  /// 切换书目（有生成任务时禁止——防扫描/生成循环把数据写进新书，v162跨书污染根因）
  Future<bool> selectBook(String name) async {
    // v222：切书时目录真实性校验+模糊找回（book_list里的脏名→真实目录名）
    var target = name;
    if (!bookList.contains(target)) {
      String strip(String n) => n
          .replaceAll(' ', '')
          .replaceAll('\u3000', '')
          .replaceAll(RegExp(r'[!！:：?？*]'), '');
      final norm = strip(target);
      final match = bookList.where((b) => strip(b) == norm).toList();
      if (match.isEmpty) return false;
      target = match.first;
    }
    name = target;
    if (generationCount > 0 || apiTimerRunning.value) return false;
    currentBook = name;
    await storage.setBook(name);
    await loadAllData();
    notifyListeners();
    return true;
  }

  /// 删除当前书目
  /// 删除书目（任意书可删；删的是当前书才切到剩余第一本）
  /// 返回false=拒绝（当前书有任务运行中）
  Future<bool> deleteBook(String name) async {
    if (name.isEmpty || !bookList.contains(name)) return false;
    if (name == currentBook &&
        (generationCount > 0 || apiTimerRunning.value)) {
      return false;
    }
    storage.deleteBook(name);
    bookList.remove(name);
    _persistBookList();
    _syncBookListPrefs();
    if (name == currentBook) {
      if (bookList.isNotEmpty) {
        await selectBook(bookList.first);
      } else {
        currentBook = '';
        await storage.setBook('');
        chapters = [];
        arcScan = null;
        arcScenes = {};
        arcAnalyses = {};
        worldBook = null;
        writings = {};
      }
    }
    notifyListeners();
    return true;
  }

  /// v221：截断的chapters.json修复——栈式补全闭合括号后逐章提取
  /// （大文件写入中断的尾巴是残缺的，完整前缀部分按"]"截断点丢弃最后半个对象）
  List<Chapter> _repairChaptersJson(String raw) {
    try {
      var s = raw.trim();
      // 栈式补闭合：追踪{}[]深度与字符串状态
      var inStr = false;
      var escape = false;
      final stack = <String>[];
      for (var i = 0; i < s.length; i++) {
        final c = s[i];
        if (escape) {
          escape = false;
          continue;
        }
        if (c == '\\') {
          if (inStr) escape = true;
          continue;
        }
        if (c == '"') {
          inStr = !inStr;
          continue;
        }
        if (inStr) continue;
        if (c == '{' || c == '[') {
          stack.add(c);
        } else if (c == '}' || c == ']') {
          if (stack.isNotEmpty) stack.removeLast();
        }
      }
      // 回退到字符串外（截断点在字符串中间时丢掉尾巴）
      if (inStr) {
        final lastQuote = s.lastIndexOf('"');
        if (lastQuote > 0) s = s.substring(0, lastQuote);
      }
      // 找最后一个完整的顶层对象边界（数组内最后一个}后补]）
      final lastObjEnd = s.lastIndexOf('}');
      if (lastObjEnd < 0) return [];
      s = s.substring(0, lastObjEnd + 1);
      // 按栈逆序闭合
      var inStr2 = false;
      var escape2 = false;
      final stack2 = <String>[];
      for (var i = 0; i < s.length; i++) {
        final c = s[i];
        if (escape2) {
          escape2 = false;
          continue;
        }
        if (c == '\\') {
          if (inStr2) escape2 = true;
          continue;
        }
        if (c == '"') {
          inStr2 = !inStr2;
          continue;
        }
        if (inStr2) continue;
        if (c == '{' || c == '[') {
          stack2.add(c);
        } else if (c == '}' || c == ']') {
          if (stack2.isNotEmpty) stack2.removeLast();
        }
      }
      final closer = {'{': '}', '[': ']'};
      final sb = StringBuffer(s);
      for (var i = stack2.length - 1; i >= 0; i--) {
        sb.write(closer[stack2[i]]);
      }
      final fixed = sb.toString();
      final list = jsonDecode(fixed) as List;
      return list
          .map((e) => Chapter.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }

  /// 加载当前书目的所有数据
  Future<void> loadAllData() async {
    if (currentBook.isEmpty) return;
    final p = storage.bookPath;
    // v222诊断：切书加载全链路日志（真机定位"切换后0章"）
    debugPrint('[Load] currentBook="$currentBook" bookPath="$p" baseDir=${storage.basePath}');

    // 加载章节（v221：解析失败不再静默清空——大文件写入中断产生截断JSON时，
    // 按栈式修复救回完整前缀部分并报警。用户案例：chapters.json 9MB切书后
    // "消失"但弧线还在=解析失败被chapters=[]吞掉）
    final chaptersJson = storage.readFile('${p}chapters.json');
    debugPrint('[Load] chapters.json读取：${chaptersJson == null ? "null(不存在或读失败)" : "${chaptersJson.length}字"}');
    // v222诊断：切书加载结果进全局终端（真机排查"切回0章"）
    apiLog(
      chaptersJson == null
          ? '⚠️ [$currentBook] chapters.json不存在或读取失败（目录：$p）'
          : '[$currentBook] 章节文件${chaptersJson.length ~/ 1024}KB，解析中...',
    );
    if (chaptersJson != null && chaptersJson.isNotEmpty) {
      try {
        final list = jsonDecode(chaptersJson) as List;
        chapters = list
            .map((e) => Chapter.fromJson(e as Map<String, dynamic>))
            .toList();
      } catch (e) {
        debugPrint('Load chapters error: $e');
        // v221：截断修复——按括号栈补全闭合（TOOLS.md的栈式修复方案）
        chapters = _repairChaptersJson(chaptersJson);
        if (chapters.isEmpty) {
          apiLog('❌ 章节数据损坏无法读取（${chaptersJson.length}字）——文件可能写入时被中断。备份在磁盘未删除，可尝试重新上传');
        } else {
          apiLog('⚠️ 章节数据部分损坏，已修复救回${chapters.length}章（原文件${chaptersJson.length}字）——建议重新上传完整txt以补全');
          saveChapters(); // 修复结果立即回写固化
        }
      }
    } else {
      chapters = [];
    }

    // v455：加载全局场景流——必须无条件（此前误放arc_scan.json块内，
    // 没扫过旧弧线的书永不加载=重启场景流清空大bug）
    loadGlobalScenes();

    // 加载弧线扫描
    final scanJson = storage.readFile('${p}arc_scan.json');
    if (scanJson != null && scanJson.isNotEmpty) {
      try {
      arcScan = ArcScan.fromJson(
          jsonDecode(scanJson) as Map<String, dynamic>,
        );
      } catch (e) {
        debugPrint('Load arcScan error: $e');
        arcScan = null;
      }
    } else {
      arcScan = null;
    }

    // 加载场景划分
    final scenesJson = storage.readFile('${p}arc_scenes.json');
    if (scenesJson != null && scenesJson.isNotEmpty) {
      try {
        final map = jsonDecode(scenesJson) as Map<String, dynamic>;
        arcScenes = map.map(
          (k, v) => MapEntry(
            k,
            (v as List)
                .map((e) => Scene.fromJson(e as Map<String, dynamic>))
                .toList(),
          ),
        );
      } catch (e) {
        arcScenes = {};
      }
    } else {
      arcScenes = {};
    }

    // 加载弧线分析
    final analysesJson = storage.readFile('${p}arc_analyses.json');
    if (analysesJson != null && analysesJson.isNotEmpty) {
      try {
        final map = jsonDecode(analysesJson) as Map<String, dynamic>;
        arcAnalyses = map.map(
          (k, v) =>
              MapEntry(k, ArcAnalysis.fromJson(v as Map<String, dynamic>)),
        );
      } catch (e) {
        arcAnalyses = {};
      }
    } else {
      arcAnalyses = {};
    }

    // v201方案A：场景划分的优质概述自动回写弧线页（幂等，只覆盖不清除）
    final synced = syncArcSummariesFromAnalyses();
    if (synced > 0) saveArcScan();

    // v210自愈：两步拆解历史上不写analyzedArcNumbers（只有一步拆解写）——
    // 有分镜数据却没标记的弧线补标记，否则v209严格化后改编页看不到这些弧线
    for (final e in arcAnalyses.values) {
      if (e.scenes.any((sc) => sc.shots.isNotEmpty)) {
        if (!isArcAnalyzed(e.arcNumber)) markArcAnalyzed(e.arcNumber);
      }
    }

    // 加载世界书
    final wbJson = storage.readFile('${p}worldbook.json');
    if (wbJson != null && wbJson.isNotEmpty) {
      try {
        worldBook = WorldBook.fromJson(
          jsonDecode(wbJson) as Map<String, dynamic>,
        );
      } catch (e) {
        worldBook = null;
      }
    } else {
      worldBook = null;
    }

    // 加载创作文档列表：优先writings.json（完整对象含分镜标记），fallback扫描txt（旧数据）
    writings = {};
    final wj = storage.readFile('${p}writings.json');
    var loadedFromJson = false;
    if (wj != null && wj.isNotEmpty) {
      try {
        final map = jsonDecode(wj);
        if (map is Map && map.isNotEmpty) {
          for (final e in map.entries) {
            try {
              final item = WritingItem.fromJson(
                e.value as Map<String, dynamic>,
              );
              writings[e.key] = item;
            } catch (_) {}
          }
          loadedFromJson = writings.isNotEmpty;
        }
      } catch (_) {}
    }
    if (!loadedFromJson) {
      final wFiles = storage.listFiles('${p}writings');
      for (final fname in wFiles) {
        if (fname.isEmpty || !fname.endsWith('.txt')) continue;
        final content = storage.readFile('${p}writings/$fname');
        if (content != null && content.isNotEmpty) {
          final key = fname.replaceAll('.txt', '');
          writings[key] = WritingItem(
            key: key,
            arcKey: '',
            sceneIdx: 0,
            content: content,
          );
        }
      }
    }

    // 加载创作提示词
    final wp = storage.readFile('${p}writing_prompt.txt');
    if (wp != null) writingPrompt = wp;
    // v469对齐：提示词预览开关+模型名备注开关（flag文件）
    writingPromptPreview =
        storage.readFile('${p}writing_prompt_preview.flag') == 'true';
    writingModelNote =
        storage.readFile('${p}writing_model_note.flag') == 'true';
    nameReplaceEnabled =
        storage.readFile('${p}name_replace.flag') == 'true';
    // v313：模仿原文作者开关
    writingImitateAuthor =
        storage.readFile('${p}writing_imitate_author.flag') == 'true';
    // v755：防抄袭检测开关（默认开——旧装无flag文件时保持开启）
    writingPlagiarismCheck =
        storage.readFile('${p}writing_plagiarism_check.flag') != 'false';
    // v758：分镜校验开关（默认开）
    writingPostCheck =
        storage.readFile('${p}writing_post_check.flag') != 'false';
    // v545：自由创作开关
    writingFreeMode =
        storage.readFile('${p}writing_free_mode.flag') == 'true';
    // v592：精简分镜开关
    writingLeanShots =
        storage.readFile('${p}writing_lean_shots.flag') == 'true';
    // v642：逐镜批量步进（默认1=传统逐镜）
    writingShotStep = int.tryParse(
          storage.readFile('${p}writing_shot_step.flag') ?? '',
        ) ??
        1;
    // v266：逐镜生成开关（默认true：flag文件缺失=开）
    writingShotByShot =
        storage.readFile('${p}writing_shot_by_shot.flag') != 'false';
    scenePromptPreview =
        storage.readFile('${p}scene_prompt_preview.flag') == 'true';
    shotPromptPreview =
        storage.readFile('${p}shot_prompt_preview.flag') == 'true';
    wbPromptPreview = storage.readFile('${p}wb_prompt_preview.flag') == 'true';
    detectPromptPreview =
        storage.readFile('${p}detect_prompt_preview.flag') == 'true';
    final wsp = storage.readFile('${p}writing_scene_prompts.json');
    if (wsp != null && wsp.isNotEmpty) {
      try {
        final map = jsonDecode(wsp) as Map<String, dynamic>;
        writingScenePrompts = map.map((k, v) => MapEntry(k, v.toString()));
      } catch (e) {}
    }
    final wa = storage.readFile('${p}writing_attachments.json');
    if (wa != null && wa.isNotEmpty) {
      try {
        writingAttachments = (jsonDecode(wa) as List)
            .cast<Map<String, dynamic>>();
      } catch (e) {}
    }
    loadSceneAttachments(); // v357：per-scene内容素材

    // 加载报告元数据
    final rm = storage.readFile('${p}report_meta.json');
    if (rm != null && rm.isNotEmpty) {
      try {
        reportMeta = jsonDecode(rm) as Map<String, dynamic>;
      } catch (e) {}
    }

    // 加载叙事线
    final nl = storage.readFile('${p}narrative_lines.json');
    if (nl != null && nl.isNotEmpty) {
      try {
        narrativeLines = (jsonDecode(nl) as List).cast<Map<String, dynamic>>();
      } catch (e) {}
    }

    notifyListeners();
  }

  /// 加载设置（全局配置）
  /// 优先读global/文件；文件缺失（如更新后目录检测变化）时从SharedPreferences恢复并回写文件
  Future<void> loadSettings() async {
    // 全局API配置（6个分页）: 文件 → prefs fallback
    final sections = <String, ApiConfig?>{
      'main': null,
      'writing': null,
      'detect': null,
      'wb': null,
      'scene': null,
      'arc': null,
      'analysis': null,
    };
    final cfgMap = <String, ApiConfig>{
      'main': mainApi,
      'writing': writingApi,
      'detect': detectApi,
      'wb': wbApi,
      'scene': sceneApi,
      'arc': arcApi,
      'analysis': analysisApi,
    };
    for (final section in sections.keys.toList()) {
      var cfg = _loadApiConfigFromFile('${section}_api', cfgMap[section]!);
      if (cfg == null) {
        // 文件没有 → 从SharedPreferences恢复（在线更新防丢）
        cfg = await _restoreApiFromPrefs(section);
        if (cfg != null) {
          storage.saveGlobalJson('${section}_api', cfg.toJson()); // 回写文件
        }
      }
      if (cfg != null) sections[section] = cfg;
    }
    mainApi = sections['main'] ?? mainApi;
    writingApi = sections['writing'] ?? writingApi;
    detectApi = sections['detect'] ?? detectApi;
    wbApi = sections['wb'] ?? wbApi;
    sceneApi = sections['scene'] ?? sceneApi;
    arcApi = sections['arc'] ?? arcApi;
    analysisApi = sections['analysis'] ?? analysisApi;

    // 预设（文件 → prefs fallback）
    final presetsJson = storage.readGlobalJson('saved_presets');
    if (presetsJson != null) {
      try {
        final list = presetsJson as List;
        presets = list
            .map((e) => Preset.fromJson(e as Map<String, dynamic>))
            .toList();
      } catch (e) {
        presets = [];
      }
    } else {
      // 文件没有 → 从SharedPreferences恢复预设
      try {
        final prefs = await SharedPreferences.getInstance();
        final raw = prefs.getString('api_cfg_presets');
        if (raw != null && raw.isNotEmpty) {
          final list = jsonDecode(raw) as List;
          presets = list
              .map((e) => Preset.fromJson(e as Map<String, dynamic>))
              .toList();
          // 回写文件
          storage.saveGlobalJson(
            'saved_presets',
            presets.map((e) => e.toJson()).toList(),
          );
        }
      } catch (e) {}
    }

    // 扫描步进
    final stepSizeStr = storage.readGlobal('scan_step_size');
    if (stepSizeStr != null && stepSizeStr.isNotEmpty) {
      scanStepSize = int.tryParse(stepSizeStr) ?? 4;
    }


    // 格式模式
    final fm = storage.readGlobal('main_format_mode');
    if (fm != null && fm.isNotEmpty) mainFormatMode = fm;

    // 篇幅标注
    final tl = storage.readGlobal('token_length');
    tokenLength = tl == '1';

    // 功能抽象标注（分镜第10维度：类型层功能描述，推演模式依赖）
    final fa = storage.readGlobal('func_abstract');
    funcAbstract = fa != '0'; // 默认必选：仅显式存过'0'的极旧存档才关

    // TTS配置
    final ttsEngine = storage.readGlobal('tts_engine');
    tts.engine = ttsEngine ?? 'silicon';
    final ttsKey = storage.readGlobal('silicon_tts_key');
    tts.siliconKey =
        ttsKey ?? 'sk-ooauhnezueiyargefmbeyqdpetuflidpqdgqelnuylljklqd';
    final ttsVoice = storage.readGlobal('silicon_voice');
    tts.siliconVoice = ttsVoice ?? 'alex';

    notifyListeners();
  }

  /// 保存API配置
  /// 双写：global/文件（备份/云同步用）+ SharedPreferences（覆盖安装不丢）
  Future<void> saveApiConfig(String section, ApiConfig config) async {
    storage.saveGlobalJson('${section}_api', config.toJson());
    // 双写SharedPreferences，防止在线更新后存储目录检测变化导致配置丢失
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('api_cfg_$section', jsonEncode(config.toJson()));
    } catch (e) {
      debugPrint('saveApiConfig prefs error: $e');
    }
    switch (section) {
      case 'main':
        mainApi = config;
        break;
      case 'writing':
        writingApi = config;
        break;
      case 'detect':
        detectApi = config;
        break;
      case 'wb':
        wbApi = config;
        break;
      case 'scene':
        sceneApi = config;
        break;
      case 'arc':
        arcApi = config;
        break;
      case 'analysis':
        analysisApi = config;
        break;
    }
    notifyListeners();
  }

  /// 从SharedPreferences恢复某section的API配置（文件丢失时用）
  Future<ApiConfig?> _restoreApiFromPrefs(String section) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('api_cfg_$section');
      if (raw == null || raw.isEmpty) return null;
      return ApiConfig.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (e) {
      return null;
    }
  }

  /// 从global/文件读API配置
  ApiConfig? _loadApiConfigFromFile(String key, ApiConfig fallback) {
    final json = storage.readGlobalJson(key);
    if (json == null) return null;
    try {
      return ApiConfig.fromJson(json);
    } catch (e) {
      return null;
    }
  }

  /// 保存预设（双写文件+prefs防丢）
  Future<void> savePresets() async {
    final jsonStr = jsonEncode(presets.map((e) => e.toJson()).toList());
    storage.saveGlobalJson(
      'saved_presets',
      presets.map((e) => e.toJson()).toList(),
    );
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('api_cfg_presets', jsonStr);
    } catch (e) {}
    notifyListeners();
  }

  // ===== 章节操作 =====

  /// 添加章节
  void addChapter(Chapter chapter) {
    chapters.add(chapter);
    chapters.sort((a, b) => a.number.compareTo(b.number));
    saveChapters();
    notifyListeners();
  }

  /// 批量添加章节（去重）
  void addChaptersBatch(List<Chapter> newChapters) {
    // 去重判据：number+title双匹配才跳过（同文件重复导入防护）
    // 仅number匹配不放行：不同txt各自从"第一章"编号，会被误杀成"已存在"→总数不增
    final existingKeys = chapters.map((e) => '${e.number}|${e.title}').toSet();
    final incoming = <Chapter>[];
    for (final ch in newChapters) {
      final key = '${ch.number}|${ch.title}';
      if (!existingKeys.contains(key)) {
        incoming.add(ch);
        existingKeys.add(key); // 批内去重
      }
    }
    chapters.addAll(incoming);
    chapters.sort((a, b) => a.number.compareTo(b.number));
    saveChapters();
    notifyListeners();
  }

  /// 删除章节
  void removeChapter(int index) {
    if (index < 0 || index >= chapters.length) return;
    chapters.removeAt(index);
    saveChapters();
    notifyListeners();
  }

  /// 保存章节（v221：落盘失败明示——书名特殊字符导致写盘静默失败时，
  /// 界面显示已加载但数据没落盘=切换/重启后消失的根因）
  void saveChapters() {
    final p = storage.bookPath;
    final ok = storage.writeFile(
      '${p}chapters.json',
      jsonEncode(chapters.map((e) => e.toJson()).toList()),
    );
    if (!ok) {
      debugPrint('[Save] chapters.json写入失败：$p');
      apiLog('❌ 章节保存失败（路径：$p）——书名含特殊字符（!：等）可能导致存储层拒绝写入，建议换不带特殊字符的书名重建');
    }
  }

  // ===== 弧线扫描操作 =====

  /// 保存弧线扫描结果
  /// bookGuard=任务开始时的书名：书已切走→写回原书目录（防扫描循环跨书污染）
  void saveArcScan({String? bookGuard}) {
    if (arcScan != null) {
      var p = storage.bookPath;
      if (bookGuard != null &&
          bookGuard.isNotEmpty &&
          currentBook != bookGuard) {
        p = 'books/$bookGuard/'; // 写回任务所属原书
      }
      storage.writeFile('${p}arc_scan.json', jsonEncode(arcScan!.toJson()));
    }
  }

  /// v461：场景流/分组busy统一入口（notifyListeners驱动两页UI）
  void setSceneStreamBusy(bool v) {
    if (sceneStreamBusy == v) return;
    sceneStreamBusy = v;
    notifyListeners();
  }

  /// v537：弧线数据级联清空——弧线作废时连坐其下游消费数据：分镜拆解
  /// (arcAnalyses，含场景/分镜正文切片)/场景归属(arcScenes)/弧线正文
  /// (arc.text随arcScan)。世界书有独立清理入口不在此动。世界书/创作文档
  /// 与弧线的绑定键(arcKey)残留无害——弧线清了列表自然不显示。
  /// arcNumbers=null→全部清空；否则只清指定弧线号（部分剪断场景）
  void clearArcCascade({Set<String>? arcNumbers}) {
    final partial = arcNumbers != null;
    if (!partial) {
      arcScan = null;
      globalGroupedUpTo = 0;
      arcAnalyses.clear();
      arcScenes.clear();
    } else {
      // v651：闭包显式(Arc a)——?.链上未标类型的闭包被推成(dynamic)=>dynamic,
      // 运行期撞List<Arc>的test校验抛subtype异常(v647同款,剪断重分必炸)
      arcScan?.arcs.removeWhere((Arc a) => arcNumbers.contains('${a.number}'));
      if (arcScan != null && arcScan!.arcs.isNotEmpty) {
        if (globalGroupedUpTo > arcScan!.arcs.last.sceneTo) {
          globalGroupedUpTo = arcScan!.arcs.last.sceneTo;
        }
      }
      arcAnalyses.removeWhere((k, _) => arcNumbers.contains(k));
      arcScenes.removeWhere((k, _) => arcNumbers.contains(k));
    }
    saveArcScan();
    saveArcAnalyses();
    saveArcScenes();
  }

  /// v431：保存全局场景流
  void saveGlobalScenes() {
    final p = storage.bookPath;
    final ok = storage.writeFile(
      '${p}global_scenes.json',
      jsonEncode({
        'scanned_up_to': globalSceneScannedUpTo,
        'resume_chap_idx': sceneResumeChapIdx,
        'resume_offset': sceneResumeOffset,
        'grouped_up_to': globalGroupedUpTo,
        'scene_step': sceneStepSize,
        'group_batch': groupBatchSize,
        'scenes': globalScenes.map((e) => e.toJson()).toList(),
      }),
    );
    if (!ok) debugPrint('[Save] global_scenes.json写入失败：$p');
  }

  /// v431：加载全局场景流
  void loadGlobalScenes() {
    final p = storage.bookPath;
    final raw = storage.readFile('${p}global_scenes.json');
    if (raw == null || raw.isEmpty) {
      globalScenes = [];
      globalSceneScannedUpTo = 0;
      sceneResumeChapIdx = -1;
      sceneResumeOffset = 0;
      return;
    }
    try {
      final data = jsonDecode(raw) as Map<String, dynamic>;
      globalSceneScannedUpTo = (data['scanned_up_to'] as num?)?.toInt() ?? 0;
      sceneResumeChapIdx = (data['resume_chap_idx'] as num?)?.toInt() ?? -1;
      sceneResumeOffset = (data['resume_offset'] as num?)?.toInt() ?? 0;
      globalGroupedUpTo = (data['grouped_up_to'] as num?)?.toInt() ?? 0;
      sceneStepSize = (data['scene_step'] as num?)?.toInt() ?? 4;
      groupBatchSize = (data['group_batch'] as num?)?.toInt() ?? 30;
      globalScenes = (data['scenes'] as List? ?? [])
          .map((e) => Scene.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (e) {
      debugPrint('[Load] global_scenes.json解析失败：$e');
      globalScenes = [];
      globalSceneScannedUpTo = 0;
      sceneResumeChapIdx = -1;
      sceneResumeOffset = 0;
      globalGroupedUpTo = 0;
    }
  }

  /// 保存场景划分
  void saveArcScenes() {
    final p = storage.bookPath;
    final map = <String, dynamic>{};
    arcScenes.forEach((k, v) => map[k] = v.map((e) => e.toJson()).toList());
    storage.writeFile('${p}arc_scenes.json', jsonEncode(map));
  }

  /// v201方案A：场景划分的优质概述（50-150字）回写弧线页概述（扫描时一句话摸底）
  /// 只覆盖不清除：arcSummary非空才写——没划分场景的弧线原概述绝不动
  /// 返回回写条数（0=无变化）
  int syncArcSummariesFromAnalyses() {
    if (arcScan == null) return 0;
    var changed = 0;
    for (final an in arcAnalyses.values) {
      final s = an.arcSummary.trim();
      if (s.isEmpty) continue; // 空概述不回写（防清空）
      for (final arc in arcScan!.arcs) {
        if (arc.number == an.arcNumber && arc.summary != s) {
          arc.summary = s;
          changed++;
        }
      }
    }
    return changed;
  }

  /// 保存弧线分析
  void saveArcAnalyses() {
    final p = storage.bookPath;
    final map = <String, dynamic>{};
    arcAnalyses.forEach((k, v) => map[k] = v.toJson());
    storage.writeFile('${p}arc_analyses.json', jsonEncode(map));
  }

  /// 保存世界书
  void saveWorldBook() {
    if (worldBook != null) {
      final p = storage.bookPath;
      storage.writeFile('${p}worldbook.json', jsonEncode(worldBook!.toJson()));
    }
  }

  /// 保存创作文档
  void saveWriting(WritingItem item) {
    writings[item.key] = item;
    final path = storage.getWritingPath(
      item.arcKey,
      item.sceneIdx,
      item.sceneName,
      item.chapterRange,
      1,
    );
    storage.writeFile(path, item.content);
    notifyListeners();
  }

  /// 保存创作提示词
  void saveWritingPrompt(String prompt) {
    writingPrompt = prompt;
    final p = storage.bookPath;
    storage.writeFile('${p}writing_prompt.txt', prompt);
  }

  /// UI即时保存入口（防抖由调用方TextField处理）
  void setWritingPrompt(String prompt) => saveWritingPrompt(prompt);

  /// 素材附件增删（v469对齐：文风/内容素材，全局存储）
  void addWritingAttachment(Map<String, dynamic> att) {
    writingAttachments.add(att);
    saveWritingAttachments();
    notifyListeners();
  }

  void removeWritingAttachment(int index) {
    if (index >= 0 && index < writingAttachments.length) {
      writingAttachments.removeAt(index);
      saveWritingAttachments();
      notifyListeners();
    }
  }

  // v357：per-scene内容素材（wkey=arcKey_si → 素材列表），随书存scene_attachments.json
  final Map<String, List<Map<String, dynamic>>> sceneAttachments = {};

  void loadSceneAttachments() {
    try {
      final raw = storage.readBookData('scene_attachments');
      if (raw is Map) {
        sceneAttachments.clear();
        raw.forEach((k, v) {
          if (v is List) {
            sceneAttachments[k.toString()] = v
                .whereType<Map>()
                .map((m) => Map<String, dynamic>.from(m))
                .toList();
          }
        });
      }
    } catch (_) {}
  }

  void saveSceneAttachments() {
    storage.writeBookData('scene_attachments', sceneAttachments);
  }

  void addSceneAttachment(String wkey, Map<String, dynamic> att) {
    sceneAttachments.putIfAbsent(wkey, () => []).add(att);
    saveSceneAttachments();
    notifyListeners();
  }

  void removeSceneAttachment(String wkey, int index) {
    final list = sceneAttachments[wkey];
    if (list != null && index >= 0 && index < list.length) {
      list.removeAt(index);
      if (list.isEmpty) sceneAttachments.remove(wkey);
      saveSceneAttachments();
      notifyListeners();
    }
  }

  /// v469对齐：提示词预览开关持久化
  void setWritingPromptPreview(bool v) {
    writingPromptPreview = v;
    storage.writeFile(
      '${storage.bookPath}writing_prompt_preview.flag',
      v ? 'true' : 'false',
    );
    notifyListeners();
  }

  /// v592：精简分镜开关持久化
  void setWritingShotStep(int v) { // v642
    writingShotStep = v.clamp(1, 10);
    storage.writeFile(
      '${storage.bookPath}writing_shot_step.flag',
      '$writingShotStep',
    );
    notifyListeners();
  }

  void setWritingLeanShots(bool v) {
    writingLeanShots = v;
    storage.writeFile(
      '${storage.bookPath}writing_lean_shots.flag',
      v ? 'true' : 'false',
    );
    notifyListeners(); // v597：v594补的notify插到了方法外没生效——挪进方法内
  }

  /// v545：自由创作开关持久化
  void setWritingFreeMode(bool v) {
    writingFreeMode = v;
    storage.writeFile(
      '${storage.bookPath}writing_free_mode.flag',
      v ? 'true' : 'false',
    );
    notifyListeners();
  }

  /// v758：分镜校验开关持久化
  void setWritingPostCheck(bool v) {
    writingPostCheck = v;
    storage.writeFile(
      '${storage.bookPath}writing_post_check.flag',
      v ? 'true' : 'false',
    );
    notifyListeners();
  }

  /// v755：防抄袭检测开关持久化
  void setWritingPlagiarismCheck(bool v) {
    writingPlagiarismCheck = v;
    storage.writeFile(
      '${storage.bookPath}writing_plagiarism_check.flag',
      v ? 'true' : 'false',
    );
    notifyListeners();
  }

  /// v313：模仿原文作者开关持久化
  void setWritingImitateAuthor(bool v) {
    writingImitateAuthor = v;
    storage.writeFile(
      '${storage.bookPath}writing_imitate_author.flag',
      v ? 'true' : 'false',
    );
    notifyListeners();
  }

  /// v266：逐镜生成开关持久化
  void setWritingShotByShot(bool v) {
    writingShotByShot = v;
    storage.writeFile(
      '${storage.bookPath}writing_shot_by_shot.flag',
      v ? 'true' : 'false',
    );
    notifyListeners();
  }

  /// v469对齐：保存txt时备注模型名称持久化
  void setWritingModelNote(bool v) {
    writingModelNote = v;
    storage.writeFile(
      '${storage.bookPath}writing_model_note.flag',
      v ? 'true' : 'false',
    );
    notifyListeners();
  }

  /// v388b：映射表增量抽取——总结条目/场景划分/分镜填充每步成功后调用
  /// v707（用户裁决）：①独立API调用（与改编主任务分开，AI负担不叠加）
  /// ②大切片分批——超9000字拆2-3批逐批调用（每批独立请求，批间合并去重）
  /// ③采集范围恢复三份改编要求文本（用户稿+AI优化稿+声明，v705升格等同用户拟名）
  /// v765：改编页是否处于续写模式
  bool get pageModeContinue => worldBook?.pageMode == 'continue';

  Future<void> extractNameMapIncrement(
    String sourceContent, {
    bool adaptedInput = false,
    String sourceLabel = '', // v676：采集源标签（终端可见读了什么）
  }) async {
    try {
      if (worldBook == null) return;
      // v766：续写模式照常采集，但规则不同——禁止拟新名，只登用户新名
      final config = wbApi.effectiveApiKey.isNotEmpty || wbApi.useCustom
          ? wbApi
          : mainApi;
      if (config.effectiveApiKey.isEmpty && !config.useCustom) return;
      // v707：分批切分——按段落边界近似均分，最多3批
      const maxBatch = 9000;
      final len = sourceContent.length;
      final nBatches = len <= maxBatch
          ? 1
          : (len / maxBatch).ceil().clamp(2, 3);
      final chunks = <String>[];
      if (nBatches == 1) {
        chunks.add(sourceContent);
      } else {
        final size = (len / nBatches).ceil();
        var start = 0;
        for (var i = 0; i < nBatches; i++) {
          var end = (start + size).clamp(0, len);
          if (i < nBatches - 1 && end < len) {
            final nl = sourceContent.lastIndexOf('\n', end);
            if (nl > start + 100) end = nl + 1; // 段落边界切，不腰斩句
          }
          chunks.add(sourceContent.substring(start, end));
          start = end;
        }
      }
      for (var bi = 0; bi < chunks.length; bi++) {
        if (api.isAborted) break;
        final tag = chunks.length > 1 ? '第${bi + 1}/${chunks.length}批' : '';
        final ok = await _extractMapBatch(
          chunks[bi],
          config,
          adaptedInput: adaptedInput,
          sourceLabel: sourceLabel,
          batchTag: tag,
          continueMode: pageModeContinue, // v766
        );
        if (!ok) break; // 失败终止（告警已在批内打出），后续批不再继续
      }
    } catch (e) {
      apiLog('⚠ 映射表增量抽取失败（不影响主流程）：$e');
    }
  }

  /// v574：映射表右列新名清单（防改编产物二次映射）
  List<String> _mapRightColumnNames() {
    final names = <String>[];
    final rowRe = RegExp(
      r'^\s*([^\s→>]+?)\s*[→>]\s*([^\s（(]+)',
      multiLine: true,
    );
    for (final m in rowRe.allMatches(worldBook!.nameMapping)) {
      final right = m.group(2)!.trim();
      if (right.isNotEmpty) names.add(right);
    }
    return names;
  }

  /// v707：单批抽取+合并（返回false=本批失败终止）
  Future<bool> _extractMapBatch(
    String sourceContent,
    dynamic config, {
    bool adaptedInput = false,
    String sourceLabel = '',
    String batchTag = '',
    bool continueMode = false, // v766：续写采集规则
  }) async {
    apiLog(
      '📖 映射表增量抽取${batchTag.isEmpty ? "" : "（$batchTag）"}（采集源${sourceLabel.isEmpty ? "" : "：$sourceLabel"}，${sourceContent.length}字）…',
    );
    final existing = worldBook!.nameMapping;
    // v677：抽取请求失败重试1次（524族掐思考期同主流程待遇）
    Future<ApiResult> nmCall() => api.call(
      apiType: config.effectiveApiType,
      baseUrl: config.effectiveApiBase,
      apiKey: config.effectiveApiKey,
      model: config.effectiveModel,
      systemPrompt: PromptBuilder.buildNameMapIncrementSystemPrompt(
        continueMode: continueMode,
      ),
      userPrompt: PromptBuilder.buildNameMapIncrementUserPrompt(
        existing,
        sourceContent,
        nameReq: worldBook!.nameMapReq,
        // v707：三份改编要求文本全部注入（用户稿+AI优化稿+声明，v705升格
        // 等同用户拟名）——新名出处与配对判定依据
        allRequirements: [
          worldBook!.requirements,
          ...worldBook!.arcRequirements.values,
          ...worldBook!.sceneRequirements.values,
          ...worldBook!.arcRequirementsAI.values,
          ...worldBook!.sceneRequirementsAI.values,
          ...worldBook!.arcDeclarations.values,
          ...worldBook!.sceneDeclarations.values,
        ].where((t) => t.trim().isNotEmpty).join('\n\n'),
        // v635：A方案下改编产物全部用原著原名，素材按原著口径抽取；
        // 右列新名禁收卫兵始终生效防二次映射
        forbiddenNames: _mapRightColumnNames(),
      ),
      temperature: 0.3,
      maxTokens: 4000,
    );
    var response = await nmCall();
    var nmRetry = 0;
    while (!response.isSuccess && nmRetry < 1 && !api.isAborted) {
      nmRetry++;
      apiLog('📖 映射表抽取请求失败（${response.error ?? "HTTP ${response.statusCode}"}），重试第$nmRetry/1次…');
      await Future.delayed(const Duration(seconds: 5));
      response = await nmCall();
    }
    if (!response.isSuccess || response.content.trim().isEmpty) {
      apiLog('⛔ 映射表增量抽取失败，已终止${batchTag.isEmpty ? "" : "（$batchTag）"}（采集源：${sourceLabel.isEmpty ? "${sourceContent.length}字" : sourceLabel}）：${response.error ?? "返回为空"}——本次改编成果不受影响，但该批未进映射表');
      return false;
    }
    var raw = response.content.trim();
    if (config.formatMode == 'json') {
      raw = TextCleaner.normalizeAiOutput(raw, jsonMode: true);
    } else {
      raw = TextCleaner.normalizeAiOutput(raw);
    }
    // 解析"原著名→新名"行，合并去重（原著名已存在=跳过，用户手改不动）
    final existingNow = worldBook!.nameMapping;
    final have = RegExp(
      r'^\s*([^\s→>]+?)\s*[→>]\s*([^\s（(]+)',
      multiLine: true,
    ).allMatches(existingNow).map((m) => m.group(1)!).toSet();
    final rights = RegExp(
      r'^\s*([^\s→>]+?)\s*[→>]\s*([^\s（(]+)',
      multiLine: true,
    ).allMatches(existingNow).map((m) => m.group(2)!).toSet();
    final nameReqText = worldBook!.nameMapReq;
    // v707：判定语料同步恢复三份文本（AI优化稿+声明等同用户拟名）
    final reqAllText = [
      worldBook!.requirements,
      ...worldBook!.arcRequirements.values,
      ...worldBook!.sceneRequirements.values,
      ...worldBook!.arcRequirementsAI.values,
      ...worldBook!.sceneRequirementsAI.values,
      ...worldBook!.arcDeclarations.values,
      ...worldBook!.sceneDeclarations.values,
    ].where((t) => t.trim().isNotEmpty).join('\n\n');
    // v636：原著正文语料——"原著名"判定依据（原著出处 > 改编要求）
    final origCorpus = chapters.isEmpty
        ? ''
        : chapters.map((c) => '${c.title}\n${c.content}').join('\n');
    final added = <String>[];
    final doubts = <String>[];
    final rejected = <String>[];
    final registered = <String>[];
    final buf = StringBuffer(existingNow.trim().isEmpty ? '' : existingNow.trimRight() + '\n');
    for (final line in raw.split('\n')) {
      final t = line.trim();
      final doubt = RegExp(
        r'^？\s*(.+?)\s*[（(]疑似=([^）)]+)[）)]$',
      ).firstMatch(t);
      if (doubt != null) {
        doubts.add('${doubt.group(1)}→${doubt.group(2)}');
        continue;
      }
      final m = RegExp(
        r'^\s*([^\s→>]+?)\s*[→>]\s*([^\s（(]+)',
      ).firstMatch(t);
      if (m == null) continue;
      final from = m.group(1)!.trim();
      if (from.isEmpty || have.contains(from)) continue;
      // v636：合法新名判定——出自要求文本且原著正文无出处=新名（登记右列恒等保留）
      // 原著正文有出处→原著词，放行。优先级：原著出处 > 要求文本
      final isLegalNewName =
          (nameReqText.contains(from) || reqAllText.contains(from)) &&
          !origCorpus.contains(from);
      if (isLegalNewName) {
        if (!rights.contains(from) && !added.contains(from)) {
          buf.writeln('$from→$from（用户新名·原样保留）');
          rights.add(from);
          have.add(from);
          registered.add(from);
          worldBook!.nameMapManual.add(from); // v710：新元素行锁定
        }
        continue;
      }
      if (rights.contains(from)) {
        rejected.add(from);
        continue;
      }
      have.add(from);
      buf.writeln(t);
      added.add(from);
      // v710：右列新名出自改编要求文本（用户稿/AI优化稿/声明）=等同用户
      // 拟名，进锁定集——AI重拟新名时与手动添加同优先级原样保留
      final rightName =
          RegExp(r'^([^\s（(]+)').firstMatch(m.group(2)!.trim())?.group(1) ?? '';
      if (rightName.isNotEmpty &&
          reqAllText.contains(rightName) &&
          !origCorpus.contains(rightName)) {
        worldBook!.nameMapManual.add(from);
      }
    }
    if (added.isNotEmpty) {
      worldBook!.nameMapping = buf.toString();
      saveWorldBook();
      apiLog('📖 映射表追加${added.length}条：${added.take(8).join('、')}${added.length > 8 ? "…" : ""}');
    }
    if (registered.isNotEmpty) {
      if (added.isEmpty) {
        worldBook!.nameMapping = buf.toString();
        saveWorldBook();
      }
      apiLog('🔖 用户新名登记进右列（恒等保留）：${registered.take(8).join('、')}${registered.length > 8 ? "…" : ""}');
    }
    if (rejected.isNotEmpty) {
      apiLog('🛡 已拦截疑似改编新名混入映射表左列：${rejected.take(8).join('、')}${rejected.length > 8 ? "…" : ""}');
    }
    if (doubts.isNotEmpty) {
      apiLog('❓ 疑似别名待确认（映射表弹窗人工处理）：${doubts.take(8).join('；')}${doubts.length > 8 ? "…" : ""}');
    }
    return true;
  }

  /// v388：二创页换名开关持久化
  void setNameReplaceEnabled(bool v) {
    nameReplaceEnabled = v;
    storage.writeFile(
      '${storage.bookPath}name_replace.flag',
      v ? 'true' : 'false',
    );
    notifyListeners();
  }

  /// v469对齐：各功能预览开关持久化（统一模式）
  void _setPreviewFlag(String name, bool v) {
    storage.writeFile(
      '${storage.bookPath}${name}_prompt_preview.flag',
      v ? 'true' : 'false',
    );
    notifyListeners();
  }

  void setScenePromptPreview(bool v) {
    scenePromptPreview = v;
    _setPreviewFlag('scene', v);
  }

  void setShotPromptPreview(bool v) {
    shotPromptPreview = v;
    _setPreviewFlag('shot', v);
  }

  void setWbPromptPreview(bool v) {
    wbPromptPreview = v;
    _setPreviewFlag('wb', v);
  }

  void setDetectPromptPreview(bool v) {
    detectPromptPreview = v;
    _setPreviewFlag('detect', v);
  }

  /// 保存单场景创作要求
  void setScenePrompt(String key, String val) {
    writingScenePrompts[key] = val;
    saveWritingScenePrompts();
  }

  /// 保存创作正文（writings.json）
  void saveWritings() {
    final p = storage.bookPath;
    final data = writings.map((k, v) => MapEntry(k, v.toJson()));
    storage.writeFile('${p}writings.json', jsonEncode(data));
    notifyListeners();
  }

  void saveWritingScenePrompts() {
    final p = storage.bookPath;
    storage.writeFile(
      '${p}writing_scene_prompts.json',
      jsonEncode(writingScenePrompts),
    );
  }

  void saveWritingAttachments() {
    final p = storage.bookPath;
    storage.writeFile(
      '${p}writing_attachments.json',
      jsonEncode(writingAttachments),
    );
  }

  /// 保存报告元数据
  void saveReportMeta() {
    final p = storage.bookPath;
    storage.writeFile('${p}report_meta.json', jsonEncode(reportMeta));
  }

  /// 保存叙事线
  void saveNarrativeLines() {
    final p = storage.bookPath;
    storage.writeFile('${p}narrative_lines.json', jsonEncode(narrativeLines));
  }

  /// 检查弧线是否已拆解
  bool isArcAnalyzed(int arcNumber) {
    final analyzed = reportMeta['analyzedArcNumbers'] as List?;
    if (analyzed == null) return false;
    return analyzed.any((e) => e.toString() == arcNumber.toString());
  }

  /// 标记弧线已拆解
  void markArcAnalyzed(int arcNumber) {
    if (!reportMeta.containsKey('analyzedArcNumbers')) {
      reportMeta['analyzedArcNumbers'] = <int>[];
    }
    final list = (reportMeta['analyzedArcNumbers'] as List).cast<int>();
    if (!list.contains(arcNumber)) {
      list.add(arcNumber);
      reportMeta['analyzedArcNumbers'] = list;
      saveReportMeta();
    }
  }

  /// 合并单条弧线的一步拆解结果到统一存储（arcAnalyses+arcScenes相互覆盖）
  /// 弧线页批量一步拆解 / 场景页"去拆解分镜"（v469 analyzeSingleArc）共用
  bool mergeStepAnalysis(
    String content,
    dynamic arc,
    void Function(String) log,
  ) {
    final json = JsonRepair.parseResponse(content);
    if (json == null) {
      log('错误：JSON解析失败');
      return false;
    }
    final arcsJson = json['arcs'] as List? ?? [];
    Map<String, dynamic>? arcMap;
    if (arcsJson.isNotEmpty) {
      arcMap = arcsJson[0] as Map<String, dynamic>;
    } else if (json['scenes'] != null) {
      arcMap = json; // 有些模型直接返回顶层
    }
    if (arcMap == null) {
      log('错误：未解析到弧线数据');
      return false;
    }

    final arcKey = arc.number.toString();
    final analysis = ArcAnalysis(
      arcNumber: arc.number,
      arcTitle: arcMap['title']?.toString() ?? arc.title,
      arcSummary: arcMap['summary']?.toString() ?? '',
      scenes: <Scene>[],
    );
    // 弧线零件
    analysis.metadata = {
      'characters': arcMap['characters'],
      'conflicts': arcMap['conflicts'],
      'foreshadowing': arcMap['foreshadowing'],
      'arc_functions': arcMap['arc_functions'],
      'irreversible_changes': arcMap['irreversible_changes'],
      'emotional_curve': arcMap['emotional_curve'],
      'author_fantasy': arcMap['author_fantasy'],
      'worldbuilding_facts': arcMap['worldbuilding_facts'],
      // v219：笔墨癖好（作者注意力画像——痴迷点/快进点/啰嗦点，推演写作的权重基准）
      'ink_hobby': arcMap['ink_hobby'],
    };
    // v469对齐：结构模式存per-arc（pattern_summary.structural_patterns → 每条弧线）
    final ps = json['pattern_summary'];
    final structural = ps is Map
        ? ps['structural_patterns']
        : arcMap['structural_patterns'];
    if (structural is List && structural.isNotEmpty) {
      analysis.metadata!['structural_patterns'] = structural;
    }
    // 场景+分镜（统一格式）
    final scenesJson = arcMap['scenes'] as List? ?? [];
    for (final scJson in scenesJson) {
      analysis.scenes.add(Scene.fromJson(scJson as Map<String, dynamic>));
    }
    // 覆盖写入统一存储（一步拆解结果与两步拆解相互覆盖对应内容）
    arcAnalyses[arcKey] = analysis;
    arcScenes[arcKey] = analysis.scenes;
    saveArcAnalyses();
    saveArcScenes();
    // v201方案A：优质概述回写弧线页（只覆盖不清除）
    if (syncArcSummariesFromAnalyses() > 0) {
      saveArcScan();
      log('✓ 弧线概述已同步到弧线页');
    }
    log(
      '✓ 弧线${arc.number}：${analysis.scenes.length}场景，'
      '${analysis.scenes.where((s) => s.shots.isNotEmpty).length}场景有分镜',
    );
    // 自动汇总世界观设定facts到世界书体系条目
    // 注意：拆解的facts只存在arcAnalyses.metadata（分析层，原著参照）
    // 世界书体系设定在「生成世界书」时才汇总创建（改编层）——职责分离
    return true;
  }

  /// 从所有已拆解弧线的worldbuilding_facts汇总到worldBook.systems
  /// ⚠️ 只在生成世界书时调用（adapt_page），拆解时不再自动写入
  /// 按体系类型分组，每个体系一条WorldbuildingSystem
  /// 体系名归一化：AI输出变体名（"经济"/"功法体系"/"社会政治"等）映射到10个标准名
  /// 防同一体系分裂成多条（曾出现4标准+12变体=16条的bug）
  static String normalizeSystemName(String raw) {
    final s = raw.replaceAll(RegExp(r'[/\s]'), '');
    if (s.contains('经济') || s.contains('货币') || s.contains('物价')) return '经济体系';
    if (s.contains('修炼') ||
        s.contains('境界') ||
        s.contains('等级') && !s.contains('装备'))
      return '修炼境界体系';
    if (s.contains('功法') || s.contains('技能') || s.contains('武学'))
      return '功法/技能体系';
    if (s.contains('社会') || s.contains('政治') || s.contains('阶层'))
      return '社会/政治体系';
    if (s.contains('地理') || s.contains('世界') || s.contains('地图'))
      return '地理/世界体系';
    if (s.contains('法宝') ||
        s.contains('物品') ||
        s.contains('装备') ||
        s.contains('炼器'))
      return '法宝/物品体系';
    if (s.contains('丹药') || s.contains('灵草') || s.contains('炼丹'))
      return '丹药/灵草体系';
    if (s.contains('种族') ||
        s.contains('生物') ||
        s.contains('妖兽') ||
        s.contains('魔兽'))
      return '种族/生物体系';
    if (s.contains('组织') ||
        s.contains('势力') ||
        s.contains('门派') ||
        s.contains('宗门'))
      return '组织/势力体系';
    if (s.contains('历史') ||
        s.contains('传说') ||
        s.contains('预言') ||
        s.contains('禁忌'))
      return '历史/传说体系';
    return raw; // 无法识别的原名保留（自定义体系）
  }

  void summarizeWorldbuildingFacts(String currentArcKey) {
    if (worldBook == null) worldBook = WorldBook();
    // 收集所有弧线的facts（体系名归一化，防变体名分裂）
    final allFacts = <Map<String, dynamic>>[];
    for (final entry in arcAnalyses.entries) {
      final facts = entry.value.metadata?['worldbuilding_facts'];
      if (facts is List) {
        for (final f in facts) {
          if (f is Map) {
            allFacts.add({
              'system': normalizeSystemName(f['system']?.toString() ?? '其他'),
              'rule': f['rule']?.toString() ?? '',
              'function': f['function']?.toString() ?? '',
              'arcKey': entry.key,
            });
          }
        }
      }
    }
    if (allFacts.isEmpty) return;
    // 按体系类型分组（同时收集每体系涉及的弧线）
    final grouped = <String, List<Map<String, dynamic>>>{};
    final sysArcKeys = <String, Set<String>>{};
    for (final f in allFacts) {
      final sys = f['system'] as String;
      grouped.putIfAbsent(sys, () => []).add(f);
      sysArcKeys.putIfAbsent(sys, () => {}).add(f['arcKey'] as String);
    }
    // 生成/更新体系条目（保留用户已改编的内容）
    final existingByName = {for (final s in worldBook!.systems) s.name: s};
    final newSystems = <WorldbuildingSystem>[];
    for (final entry in grouped.entries) {
      final sysName = entry.key;
      final facts = entry.value;
      final existing = existingByName[sysName];
      // 汇总原著规则
      final rulesBuf = StringBuffer();
      final funcBuf = StringBuffer();
      for (var i = 0; i < facts.length; i++) {
        final f = facts[i];
        final rule = f['rule'] as String;
        final func = f['function'] as String;
        if (rule.isNotEmpty) rulesBuf.writeln('- $rule');
        if (func.isNotEmpty) funcBuf.writeln('- $func');
      }
      if (existing != null) {
        // 已存在：更新原著规则和功能，保留用户的改编内容
        existing.originalRules = rulesBuf.toString().trim();
        existing.functions = funcBuf.toString().trim();
        existing.arcKeys = sysArcKeys[sysName]?.toList() ?? [];
        newSystems.add(existing);
      } else {
        // 新建
        newSystems.add(
          WorldbuildingSystem(
            id: '${sysName}_${DateTime.now().millisecondsSinceEpoch}',
            name: sysName,
            originalRules: rulesBuf.toString().trim(),
            functions: funcBuf.toString().trim(),
            arcKey: currentArcKey,
            arcKeys: sysArcKeys[sysName]?.toList() ?? [],
          ),
        );
      }
    }
    // 保留未被本次facts覆盖的已有体系（用户手动添加的）
    final newNames = newSystems.map((s) => s.name).toSet();
    for (final s in worldBook!.systems) {
      if (!newNames.contains(s.name)) newSystems.add(s);
    }
    worldBook!.systems = newSystems;
    saveWorldBook();
  }

  /// 构建分析对象（对应HTML版 buildAnalysisObject）
  Map<String, dynamic> buildAnalysisObject() {
    final arcs = <Map<String, dynamic>>[];
    final keys = arcAnalyses.keys.toList()
      ..sort((a, b) => (int.tryParse(a) ?? 0).compareTo(int.tryParse(b) ?? 0));
    for (final key in keys) {
      final item = arcAnalyses[key];
      if (item != null && item.arc != null) {
        arcs.add(item.arc!.toJson());
      }
    }
    final result = <String, dynamic>{'arcs': arcs};
    if (lastPatternSummary != null)
      result['pattern_summary'] = lastPatternSummary;
    return result;
  }

  /// 设置加载状态
  void setLoading(bool loading, [String message = '']) {
    isLoading = loading;
    loadingMessage = message;
    notifyListeners();
  }

  /// 切换Tab
  void switchTab(String tab) {
    currentTab = tab;
    notifyListeners();
  }

  /// 获取已闭合弧线
  List<Arc> get completedArcs {
    if (arcScan == null) return [];
    return arcScan!.arcs.where((a) => a.status == 'complete').toList();
  }

  /// 获取未闭合弧线
  List<Arc> get incompleteArcs {
    if (arcScan == null) return [];
    return arcScan!.arcs.where((a) => a.status != 'complete').toList();
  }

  /// 获取所有弧线
  List<Arc> get allArcs {
    if (arcScan == null) return [];
    return arcScan!.arcs;
  }

  /// 公开触发刷新（外部页面修改state后调用）
  void refresh() => notifyListeners();

  /// 获取API配置，未配置时fallback到mainApi
  ApiConfig getApiConfig(String section) {
    ApiConfig config;
    switch (section) {
      case 'main':
        return mainApi;
      case 'writing':
        config = writingApi;
        break;
      case 'detect':
        config = detectApi;
        break;
      case 'wb':
        config = wbApi;
        break;
      case 'scene':
        config = sceneApi;
        break;
      case 'arc':
        config = arcApi;
        break;
      case 'analysis':
        config = analysisApi;
        break;
      default:
        return mainApi;
    }
    // v485用户裁决：去掉main fallback——每页用自己的配置，没配置就空配置
    // （callApi会报"API Key为空"，引导用户到本页⚙设置）
    return config;
  }

  // ===== 备份/恢复（和v318格式互通）=====

  /// v318兼容的书目数据文件列表
  static const List<String> bookDataFiles = [
    'chapters.json', 'arc_scan.json', 'arc_analyses.json',
    'global_scenes.json', // v431：全局场景流
    'arc_scenes.json', 'narrative_lines.json',
    'report.md', 'report_meta.json', 'worldbook.json',
    'writings.json',
    'writing_prompt.txt',
    'writing_scene_prompts.json',
    'writing_attachments.json',
    'scene_attachments.json', // v357：per-scene内容素材
    // v469对齐：各功能开关flag（备份/恢复同步）
    'writing_imitate_author.flag',
    'writing_prompt_preview.flag', 'writing_model_note.flag',
    'scene_prompt_preview.flag', 'shot_prompt_preview.flag',
    'wb_prompt_preview.flag', 'detect_prompt_preview.flag',
  ];

  /// v318兼容的全局key列表
  static const List<String> globalKeys = [
    'zhipu_api_key',
    'zhipu_model',
    'api_provider',
    'api_base',
    'api_type',
    'custom_api_key',
    'custom_model_name',
    'api_temperature',
    'api_max_tokens',
    'scan_step_size',
  ];

  /// 备份数据（和v318格式互通）
  /// [backupAll] true=全部书目+全局设置, false=仅当前书目
  Map<String, dynamic> backupData({bool backupAll = false}) {
    final data = <String, dynamic>{
      '_version': 3,
      '_scope': backupAll ? 'all' : 'book',
      '_backupDate': DateTime.now().toIso8601String(),
    };

    // 全局文件（v59+）：global/目录全部文件，含各分页API配置/预设/格式模式等
    // v292：书目备份也带（restoreData对_scope不设限，恢复当前书目也能找回API配置）
    final gFiles = storage.listFiles('global');
    if (gFiles.isNotEmpty) {
      final globalFiles = <String, dynamic>{};
      for (final fname in gFiles) {
        if (fname.isEmpty) continue;
        final v = storage.readFile('global/$fname');
        if (v != null && v.isNotEmpty) globalFiles[fname] = v;
      }
      if (globalFiles.isNotEmpty) data['_global_files'] = globalFiles;
    }

    if (backupAll) {
      // 全局设置（旧格式兼容：白名单key平铺在顶层）
      for (final k in globalKeys) {
        final v = storage.readGlobal(k);
        if (v != null && v.isNotEmpty) data[k] = v;
      }
      // 书目列表
      data['book_list'] = jsonEncode(bookList);
    }

    // 书目数据
    final booksToBackup = backupAll
        ? bookList
        : (currentBook.isNotEmpty ? [currentBook] : <String>[]);

    for (final bookId in booksToBackup) {
      final bookData = <String, dynamic>{};
      final bookPath = 'books/$bookId';

      // 标准书目文件
      for (final fn in bookDataFiles) {
        final v = storage.readFile('$bookPath/$fn');
        if (v != null && v.isNotEmpty) bookData[fn] = v;
      }

      // 创作文档目录
      final writings = <String, dynamic>{};
      final wFiles = storage.listFiles('$bookPath/writings');
      for (final fname in wFiles) {
        if (fname.isEmpty) continue;
        final v = storage.readFile('$bookPath/writings/$fname');
        if (v != null && v.isNotEmpty) writings[fname] = v;
      }
      if (writings.isNotEmpty) bookData['_writings'] = writings;

      if (bookData.isNotEmpty) {
        data['book:$bookId'] = bookData;
      }
    }

    return data;
  }

  /// 备份为JSON字符串
  String backupToJson({bool backupAll = false}) {
    return const JsonEncoder.withIndent('  ')
        .convert(backupData(backupAll: backupAll));
  }

  // ===== 云同步数据打包/解包（v318格式）=====

  /// 打包云同步数据（对应v318的packageSyncData）
  /// 格式：{version:1, timestamp:..., books:{书名:{文件名:内容}}, global:{文件名:内容}}
  String packageSyncData() {
    final pkg = <String, dynamic>{
      'version': 1,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
      'books': <String, dynamic>{},
      'global': <String, dynamic>{},
    };

    // 收集所有书目数据
    for (final bookId in bookList) {
      if (bookId.isEmpty) continue;
      final bookData = <String, dynamic>{};
      final bookPath = 'books/$bookId';

      // 书目文件
      for (final fn in bookDataFiles) {
        final v = storage.readFile('$bookPath/$fn');
        if (v != null && v.isNotEmpty) bookData[fn] = v;
      }

      // 创作文档
      final wFiles = storage.listFiles('$bookPath/writings');
      if (wFiles.isNotEmpty) {
        final writings = <String, dynamic>{};
        for (final fname in wFiles) {
          if (fname.isEmpty) continue;
          final v = storage.readFile('$bookPath/writings/$fname');
          if (v != null && v.isNotEmpty) writings[fname] = v;
        }
        if (writings.isNotEmpty) bookData['_writings'] = writings;
      }

      if (bookData.isNotEmpty) {
        (pkg['books'] as Map<String, dynamic>)[bookId] = bookData;
      }
    }

    // 收集全局文件
    final gFiles = storage.listFiles('global');
    for (final fname in gFiles) {
      if (fname.isEmpty) continue;
      final v = storage.readFile('global/$fname');
      if (v != null && v.isNotEmpty) {
        (pkg['global'] as Map<String, dynamic>)[fname] = v;
      }
    }

    return jsonEncode(pkg);
  }

  /// 解包云同步数据到本地（对应v318的unpackSyncData）
  /// 返回恢复的书目数量
  Future<int> unpackSyncData(String jsonStr) async {
    try {
      final pkg = jsonDecode(jsonStr) as Map<String, dynamic>;
      if (pkg['version'] != 1) {
        debugPrint('Invalid sync data format: version=${pkg['version']}');
        return 0;
      }

      int bookCount = 0;

      // 写入书目数据
      final books = pkg['books'] as Map<String, dynamic>? ?? {};
      books.forEach((bookId, bookDataRaw) {
        if (bookId.isEmpty) return;
        final bookData = bookDataRaw as Map<String, dynamic>;
        storage.createBook(bookId);
        if (!bookList.contains(bookId)) bookList.add(bookId);

        final bookPath = 'books/$bookId';

        // 标准文件
        bookData.forEach((fname, content) {
          if (fname == '_writings') return;
          storage.writeFile('$bookPath/$fname', content.toString());
        });

        // 创作文档
        if (bookData.containsKey('_writings')) {
          final writings = bookData['_writings'] as Map<String, dynamic>;
          writings.forEach((fname, content) {
            storage.writeFile('$bookPath/writings/$fname', content.toString());
          });
        }
        bookCount++;
      });

      // 写入全局文件
      final globalFiles = pkg['global'] as Map<String, dynamic>? ?? {};
      globalFiles.forEach((fname, content) {
        storage.writeFile('global/$fname', content.toString());
      });
      // 云同步恢复后同步双写API配置到SharedPreferences（防丢）
      for (final section in [
        'main',
        'writing',
        'detect',
        'wb',
        'scene',
        'analysis',
      ]) {
        if (globalFiles.containsKey('${section}_api.json')) {
          try {
            final cfg = ApiConfig.fromJson(
              jsonDecode(globalFiles['${section}_api.json'].toString())
                  as Map<String, dynamic>,
            );
            final prefs = await SharedPreferences.getInstance();
            await prefs.setString('api_cfg_$section', jsonEncode(cfg.toJson()));
          } catch (e) {}
        }
      }

      // 保存书目列表
      _persistBookList();
      _syncBookListPrefs();

      return bookCount;
    } catch (e) {
      debugPrint('unpackSyncData error: $e');
      return 0;
    }
  }

  /// 恢复数据（和v318格式互通）
  Future<bool> restoreData(Map<String, dynamic> data) async {
    try {
      final version = data['_version'] ?? 3;
      debugPrint('Restoring backup v$version, date=${data['_backupDate']}');

      // 恢复全局设置（旧格式兼容：顶层白名单key）
      for (final k in globalKeys) {
        if (data.containsKey(k)) {
          storage.writeGlobal(k, data[k].toString());
        }
      }

      // 恢复全局文件（v59+格式：global/目录全部文件，含各分页API配置/预设等）
      if (data.containsKey('_global_files')) {
        final globalFiles = data['_global_files'] as Map<String, dynamic>;
        globalFiles.forEach((fname, content) {
          storage.writeFile('global/$fname', content.toString());
        });
        // 恢复后同步双写到SharedPreferences（API配置防丢）
        for (final section in [
          'main',
          'writing',
          'detect',
          'wb',
          'scene',
          'analysis',
        ]) {
          if (globalFiles.containsKey('${section}_api.json')) {
            try {
              final cfg = ApiConfig.fromJson(
                jsonDecode(globalFiles['${section}_api.json'].toString())
                    as Map<String, dynamic>,
              );
              final prefs = await SharedPreferences.getInstance();
              await prefs.setString(
                'api_cfg_$section',
                jsonEncode(cfg.toJson()),
              );
            } catch (e) {}
          }
        }
      }

      // 恢复书目列表
      if (data.containsKey('book_list')) {
        try {
          final list = jsonDecode(data['book_list'] as String) as List;
          final restoredBookList = list.map((e) => e.toString()).toList();
          for (final b in restoredBookList) {
            if (b.isNotEmpty && !bookList.contains(b)) {
              storage.createBook(b);
              bookList.add(b);
            }
          }
        } catch (e) {}
      }

      // 恢复书目数据
      data.keys.where((k) => k.startsWith('book:')).forEach((key) {
        final bookId = key.substring(5);
        if (bookId.isEmpty) return;
        storage.createBook(bookId);
        if (!bookList.contains(bookId)) bookList.add(bookId);

        final bookData = data[key] as Map<String, dynamic>;
        final bookPath = 'books/$bookId';

        // 标准文件
        for (final fn in bookDataFiles) {
          if (bookData.containsKey(fn)) {
            storage.writeFile('$bookPath/$fn', bookData[fn].toString());
          }
        }

        // 创作文档
        if (bookData.containsKey('_writings')) {
          final writings = bookData['_writings'] as Map<String, dynamic>;
          writings.forEach((fname, content) {
            storage.writeFile('$bookPath/writings/$fname', content.toString());
          });
        }
      });

      // 重新加载
      await loadSettings();
      if (bookList.isNotEmpty) {
        await selectBook(bookList.first);
      }
      notifyListeners();
      return true;
    } catch (e) {
      debugPrint('Restore error: $e');
      return false;
    }
  }

  /// 从JSON字符串恢复
  Future<bool> restoreFromJson(String jsonStr) async {
    try {
      final data = jsonDecode(jsonStr) as Map<String, dynamic>;
      return restoreData(data);
    } catch (e) {
      debugPrint('Restore from JSON error: $e');
      return false;
    }
  }
}
