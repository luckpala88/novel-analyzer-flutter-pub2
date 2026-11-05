// v1476沙盒：锁定"apiLog与全局notify解耦"修复
// 08:12死机日志实证：apiLog→notifyListeners→context.watch<AppState>全页
// rebuild重走MJ楼层渲染链=主线程卡死（四格"全屏builder构建"日志缺位）。
// 本测试锁死行为：apiLog/clearApiLogs绝不触发AppState.notifyListeners，
// 终端只靠logRevision刷新；终端组件在无父级rebuild下也能显示新日志。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:novel_analyzer/state/app_state.dart';
import 'package:novel_analyzer/widgets/api_terminal_widget.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // AppState构造链触发audioplayers初始化——mock掉插件副作用（同cover_compose_test）
  for (final ch in const [
    MethodChannel('xyz.luan/audioplayers.global'),
    MethodChannel('xyz.luan/audioplayers.global/events'),
    MethodChannel('xyz.luan/audioplayers'),
  ]) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(ch, (m) async => null);
  }

  test('apiLog不触发全局notifyListeners，只递增logRevision', () {
    final st = AppState.instance;
    var notified = 0;
    void onNotify() => notified++;
    st.addListener(onNotify);
    st.logRevision.value = 0;

    st.apiLog('测试日志一');
    st.apiLog('测试日志二');
    expect(notified, 0, reason: 'apiLog触发全局notify=v1475死机链复发');
    expect(st.logRevision.value, 2);
    expect(st.apiLogs.where((l) => l.contains('测试日志')).length, 2);

    st.clearApiLogs();
    expect(notified, 0, reason: '清屏也不应触发全局notify');
    expect(st.logRevision.value, 3);
    st.removeListener(onNotify);
  });

  testWidgets('终端组件无父级rebuild也能显示新日志（logRevision驱动）', (tester) async {
    final st = AppState.instance;
    st.apiLogs.clear();
    st.terminalPinned = true;

    // 终端挂在静态父级下——父级永不rebuild，刷新只能靠终端自身listener
    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: st,
        // 终端设计为顶部浮层（内部Column按内容收缩），测试里给足高度防溢出报错
        child: MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: double.infinity,
                height: 120,
                child: ApiTerminalWidget(),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    st.apiLog('v1476沙盒日志');
    await tester.pump();
    expect(find.textContaining('v1476沙盒日志'), findsOneWidget,
        reason: 'apiLog后终端必须显示新日志（logRevision驱动）');
  });

  testWidgets('点四格→apiLog→开全屏：无notify链路下pumpAndSettle不死锁', (tester) async {
    // 复刻v1475死机时序：onTap内apiLog + showDialog（v1476后apiLog已无害）
    final st = AppState.instance;
    st.apiLogs.clear();
    final key = GlobalKey();
    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: st,
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              key: key,
              builder: (context) => Center(
                child: GestureDetector(
                  onTap: () {
                    st.apiLog('四格TAP 沙盒');
                    showDialog(
                      context: context,
                      builder: (d) => Dialog.fullscreen(
                        backgroundColor: Colors.black,
                        child: StatefulBuilder(
                          builder: (d2, setD2) => const Center(
                            child: Text('全屏OK', style: TextStyle(color: Colors.white)),
                          ),
                        ),
                      ),
                    );
                    st.apiLog('push完成');
                  },
                  child: Container(width: 80, height: 80, color: Colors.amber),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.byType(GestureDetector).first);
    await tester.pumpAndSettle(const Duration(milliseconds: 100));

    expect(find.text('全屏OK'), findsOneWidget);
    final logs = st.apiLogs.join('\n');
    expect(logs.contains('四格TAP 沙盒'), isTrue);
    expect(logs.contains('push完成'), isTrue);
  });
}
