import 'package:flutter/material.dart';

import 'dart:convert';

import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'state/app_state.dart';
import 'utils/v469_style.dart';
import 'pages/home_page.dart';
import 'pages/scan_page.dart';
import 'pages/scene_page.dart';
import 'pages/analysis_page.dart';
import 'pages/adapt_page.dart';
import 'pages/worldbook_page.dart';
import 'pages/writing_page.dart';
import 'pages/detection_page.dart';
import 'widgets/api_terminal_widget.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // v343：release下崩溃默认渲染灰屏（看不到任何信息）——改为把异常+栈
  // 直接显示出来，用户截图即可定位（诊断用，问题闭环后可移除）
  ErrorWidget.builder = (details) => SingleChildScrollView(
        padding: const EdgeInsets.all(12),
        child: Text(
          '💥 页面崩溃\n\n${details.exception}\n\n${details.stack}',
          style: const TextStyle(fontSize: 11, color: Colors.red),
        ),
      );
  runApp(const NovelAnalyzerApp());
}

class NovelAnalyzerApp extends StatelessWidget {
  const NovelAnalyzerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => AppState.instance,
      child: MaterialApp(
        title: '网文拆解器',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFF8B6914), // v318金棕色
            brightness: Brightness.light,
            surface: const Color(0xFFFFFFFF),
          ),
          scaffoldBackgroundColor: const Color(0xFFFAF7F2), // v318暖色背景
          cardColor: const Color(0xFFFFFFFF),
          primaryColor: const Color(0xFF8B6914),
          useMaterial3: true,
          // v200：字体统一走V469Style.uiFont（Windows雅黑，Android默认Noto）
          fontFamily: V469Style.uiFont,
          appBarTheme: const AppBarTheme(
            centerTitle: false,
            elevation: 0,
            backgroundColor: Color(0xFFFFFFFF),
            foregroundColor: Color(0xFF2C1810),
          ),
          navigationBarTheme: NavigationBarThemeData(
            backgroundColor: const Color(0xFFFFFFFF),
            indicatorColor: const Color(0xFFFDF6E8),
            labelTextStyle: WidgetStateProperty.resolveWith((states) {
              return const TextStyle(fontSize: 11);
            }),
          ),
          inputDecorationTheme: const InputDecorationTheme(
            border: OutlineInputBorder(
              borderRadius: BorderRadius.all(Radius.circular(8)),
              borderSide: BorderSide(color: Color(0xFFE8E0D5)),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.all(Radius.circular(8)),
              borderSide: BorderSide(color: Color(0xFFD4A84A)),
            ),
          ),
          cardTheme: const CardThemeData(
            color: Color(0xFFFFFFFF),
            elevation: 0.5,
            margin: EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          ),
          textTheme: const TextTheme(
            bodyMedium: TextStyle(color: Color(0xFF2C1810)),
            bodySmall: TextStyle(color: Color(0xFF6B5D54)),
            labelSmall: TextStyle(color: Color(0xFF9A8B80)),
          ),
          // 文字按钮描边（不加尺寸）：让它看起来是按键而不是纯文字
          textButtonTheme: TextButtonThemeData(
            style: ButtonStyle(
              side: WidgetStateProperty.resolveWith((states) {
                if (states.contains(WidgetState.disabled)) {
                  return const BorderSide(
                    color: Color(0xFFE0D8CC),
                    width: 0.8,
                  ); // 禁用淡边框
                }
                return const BorderSide(
                  color: Color(0xFFC9A85C),
                  width: 0.8,
                ); // 金棕描边
              }),
              shape: WidgetStateProperty.all(
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
              ),
            ),
          ),
          dividerColor: const Color(0xFFE8E0D5),
        ),
        darkTheme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFF8B6914),
            brightness: Brightness.dark,
          ),
          useMaterial3: true,
        ),
        themeMode: ThemeMode.light,
        home: const AppShell(),
      ),
    );
  }
}

class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _currentIndex = 0;
  bool _initialized = false;
  String? _initError;
  late PageController _pageController;
  bool _forceDesktop = false; // 手动分栏开关（null=自动检测横屏）
  // 桌面8栏并排：栏目显隐（对齐HTML版column-toolbar，prefs持久化）
  final List<bool> _colVisible = List.filled(8, true);
  bool _colsRestored = false;

  final _pages = const [
    HomePage(),
    ScenePage(), // v435：场景页与弧线页对调——先场景后弧线（新流程顺序）
    ScanPage(),
    AnalysisPage(),
    AdaptPage(),
    WorldBookPage(),
    WritingPage(),
    DetectionPage(),
  ];

  final _tabs = const [
    ('主页', Icons.home),
    ('场景', Icons.view_module),
    ('弧线', Icons.timeline),
    ('分镜', Icons.list_alt),
    ('改续', Icons.auto_fix_high),
    ('世界', Icons.menu_book),
    ('创作', Icons.edit_note),
    ('二创', Icons.fact_check),
  ];

  @override
  void initState() {
    super.initState();
    _pageController = PageController();
    // 监听currentTab变化联动跳页（switchTab('scene')等跨页跳转）
    final state = context.read<AppState>();
    state.addListener(_onTabChanged);
    _restoreLastTab();
    _restoreColumns();
    _initApp();
  }

  /// 恢复栏目显隐（HTML版desktop_col_visibility对齐）
  Future<void> _restoreColumns() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('desktop_col_visibility');
      if (raw != null && raw.isNotEmpty) {
        final list = jsonDecode(raw) as List;
        for (var i = 0; i < _colVisible.length && i < list.length; i++) {
          _colVisible[i] = list[i] != false;
        }
      }
      _colsRestored = true;
      if (mounted) setState(() {});
    } catch (_) {
      _colsRestored = true;
    }
  }

  Future<void> _saveColumns() async {
    if (!_colsRestored) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('desktop_col_visibility', jsonEncode(_colVisible));
    } catch (_) {}
  }

  /// 栏目开关（至少保留一栏，对齐HTML版'至少保留一个栏目'）
  void _toggleColumn(int i) {
    final visibleCount = _colVisible.where((v) => v).length;
    if (!_colVisible[i] == false && visibleCount <= 1) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('至少保留一个栏目'),
          duration: Duration(milliseconds: 1200),
        ),
      );
      return;
    }
    setState(() => _colVisible[i] = !_colVisible[i]);
    _saveColumns();
  }

  /// 栏目开关按钮（胶囊，激活=强调色——HTML版col-tb-btn同款）
  Widget _colBtn(int i) {
    final active = _colVisible[i];
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: () => _toggleColumn(i),
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
        decoration: BoxDecoration(
          border: Border.all(
            color: active ? scheme.primary : scheme.outlineVariant,
          ),
          borderRadius: BorderRadius.circular(12),
          color: active ? scheme.primary : scheme.surface,
        ),
        child: Text(
          _tabs[i].$1,
          style: TextStyle(
            fontSize: 11,
            color: active ? scheme.onPrimary : scheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }

  void _showAllColumns() {
    setState(() {
      for (var i = 0; i < _colVisible.length; i++) {
        _colVisible[i] = true;
      }
    });
    _saveColumns();
  }

  /// 恢复上次停留的Tab（重启回到上次页面）
  Future<void> _restoreLastTab() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final idx = prefs.getInt('last_tab') ?? 0;
      if (idx > 0 && idx < _pages.length) {
        setState(() => _currentIndex = idx);
        // PageController初始位置（hasClients前直接jump）
        if (_pageController.hasClients) {
          _pageController.jumpToPage(idx);
        } else {
          _pageController = PageController(initialPage: idx);
        }
      }
    } catch (_) {}
  }

  /// 记住当前Tab（切页时调用）
  Future<void> _saveLastTab(int idx) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt('last_tab', idx);
    } catch (_) {}
  }

  void _onTabChanged() {
    final state = context.read<AppState>();
    // 只消费"跳页指令"：currentTab为空表示无指令，直接忽略本次notifyListeners
    // （任何notifyListeners都会进这里——改API设置/扫描进度等——绝不能被误跳）
    if (state.currentTab.isEmpty) return;
    final tabNames = [
      'home',
      'scan',
      'scene',
      'analysis',
      'adapt',
      'worldbook',
      'writing',
      'detect',
    ];
    final idx = tabNames.indexOf(state.currentTab);
    if (idx >= 0 && idx != _currentIndex && _pageController.hasClients) {
      _pageController.animateToPage(
        idx,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeInOut,
      );
      setState(() => _currentIndex = idx);
      _saveLastTab(idx);
    }
    // 消费完清掉指令，避免后续notifyListeners重复触发
    state.currentTab = '';
  }

  @override
  void dispose() {
    try {
      context.read<AppState>().removeListener(_onTabChanged);
    } catch (_) {}
    _pageController.dispose();
    super.dispose();
  }

  Future<void> _initApp() async {
    try {
      final state = context.read<AppState>();
      await state.init();
    } catch (e) {
      _initError = e.toString();
    }
    if (mounted) {
      setState(() => _initialized = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_initialized) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    if (_initError != null) {
      return Scaffold(
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.error_outline, size: 48, color: Colors.red),
              const SizedBox(height: 16),
              Text('初始化失败: $_initError'),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: () {
                  setState(() {
                    _initialized = false;
                    _initError = null;
                  });
                  _initApp();
                },
                child: const Text('重试'),
              ),
            ],
          ),
        ),
      );
    }

    final state = context.watch<AppState>();
    // 分栏模式：手动开关 或 横屏自动检测（width > height 或 width >= 900）
    final size = MediaQuery.of(context).size;
    final isWide =
        _forceDesktop || size.width > size.height || size.width >= 900;

    if (isWide) {
      // 桌面/横屏布局：终端 + 栏目工具条 + 8栏并排（对齐HTML版column-toolbar分栏）
      // 外层SafeArea统一吃一次安全区（内层8页removePadding去重）
      return Scaffold(
        body: SafeArea(
          bottom: false,
          child: Column(
            children: [
              const ApiTerminalWidget(),
              // 栏目开关工具条（HTML版col-tb-btn同款：圆角胶囊按钮，激活=强调色）
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surface,
                  border: Border(
                    bottom: BorderSide(color: Theme.of(context).dividerColor),
                  ),
                ),
                child: Row(
                  children: [
                    Text(
                      '栏目',
                      style: TextStyle(
                        fontSize: 11,
                        color: Theme.of(context).hintColor,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          children: [
                            for (var i = 0; i < _tabs.length; i++)
                              Padding(
                                padding: const EdgeInsets.only(right: 4),
                                child: _colBtn(i),
                              ),
                          ],
                        ),
                      ),
                    ),
                    TextButton(
                      onPressed: _showAllColumns,
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        minimumSize: const Size(0, 26),
                        textStyle: const TextStyle(fontSize: 11),
                      ),
                      child: const Text('全部显示'),
                    ),
                    const SizedBox(width: 4),
                    // 手动切回手机布局
                    IconButton(
                      icon: const Icon(Icons.smartphone, size: 16),
                      tooltip: '切换手机布局',
                      onPressed: () => setState(() => _forceDesktop = false),
                    ),
                  ],
                ),
              ),
              // 8栏并排：可见栏目flex均分，各栏独立滚动（页面常驻不销毁）
              // removePadding：页面级SafeArea不再重复吃顶部安全区（8层叠加会把终端挤出屏）
              Expanded(
                child: MediaQuery.removePadding(
                  context: context,
                  removeTop: true,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: () {
                      final cols = <Widget>[];
                      var first = true;
                      for (var i = 0; i < _pages.length; i++) {
                        if (!_colVisible[i]) continue;
                        if (!first) {
                          cols.add(
                            VerticalDivider(
                              width: 1,
                              thickness: 0.5,
                              color: Theme.of(context).dividerColor,
                            ),
                          );
                        }
                        cols.add(Expanded(child: _pages[i]));
                        first = false;
                      }
                      return cols;
                    }(),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    // 手机布局：内容全屏 + 底部导航 + 终端悬浮胶囊（不占顶部空间）
    return Scaffold(
      // 手机布局：终端常驻顶部（与横屏一致，收起时28px小条点击展开）
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            const ApiTerminalWidget(),
            Expanded(
              child: PageView(
                controller: _pageController,
                onPageChanged: (i) {
                  setState(() => _currentIndex = i);
                  _saveLastTab(i);
                },
                children: _pages,
              ),
            ),
          ],
        ),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _currentIndex,
        height: 56,
        backgroundColor: Theme.of(context).colorScheme.surface,
        indicatorColor: Theme.of(context).colorScheme.primaryContainer,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        onDestinationSelected: (i) {
          _pageController.animateToPage(
            i,
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeInOut,
          );
          setState(() => _currentIndex = i);
          _saveLastTab(i);
        },
        destinations: _tabs.map((t) {
          final selected = _currentIndex == _tabs.indexOf(t);
          return NavigationDestination(
            icon: Icon(t.$2, color: Colors.grey[400], size: 20),
            selectedIcon: Icon(
              t.$2,
              color: Theme.of(context).colorScheme.primary,
              size: 22,
            ),
            label: t.$1,
          );
        }).toList(),
      ),
    );
  }
}
