// v1470沙盒：复现点四格死机（ANR）——复刻chat_page四格onTap链
// 链路：GridView四格(大图bytes) → tap → setState切bytes/_origBytes →
//       showDialog(Dialog.fullscreen + StatefulBuilder + InteractiveViewer + Image.memory)
// 若pumpAndSettle超时=挂起复现；能settle=沙盒复现不了(真机引擎层)，转装机埋点
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'pngs.dart';

Uint8List _png(String b64) => Uint8List.fromList(Uri.parse('data:image/png;base64,$b64').data!.contentAsBytes());

void main() {
  testWidgets('四格onTap链沙盒：tap后pumpAndSettle不死锁', (tester) async {
    final vt = _png(VT); // 1024x3072 真竖图
    final grid = List<Uint8List>.filled(4, vt);

    int sel = 0;
    Uint8List? bytes;
    Uint8List? origBytes;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              bytes ??= grid[0];
              return Container(
                width: 260,
                color: const Color(0xFFEFE8D8),
                child: GridView.count(
                  crossAxisCount: 2,
                  shrinkWrap: true,
                  childAspectRatio: 0.78,
                  children: [
                    for (var i = 0; i < grid.length; i++)
                      GestureDetector(
                        onTap: () {
                          final img = grid[i];
                          setState(() {
                            sel = i;
                            bytes = img;
                          });
                          origBytes = img;
                          showDialog(
                            context: context,
                            builder: (d) => Dialog.fullscreen(
                              backgroundColor: Colors.black,
                              child: StatefulBuilder(
                                builder: (d2, setD2) => Column(children: [
                                  Expanded(
                                    child: GestureDetector(
                                      onTap: () => Navigator.pop(d),
                                      child: Center(
                                        // v1469同构：InteractiveViewer + 原尺寸解码
                                        child: InteractiveViewer(
                                            child: Image.memory(bytes ?? img,
                                                fit: BoxFit.contain)),
                                      ),
                                    ),
                                  ),
                                ]),
                              ),
                            ),
                          );
                        },
                        child: Container(
                          decoration: BoxDecoration(
                            border: Border.all(
                                color: sel == i
                                    ? const Color(0xFFFFD700)
                                    : Colors.transparent,
                                width: 3),
                          ),
                          child: Image.memory(grid[i], fit: BoxFit.cover),
                        ),
                      ),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
    // 先让四格完成首帧+解码
    await tester.pumpAndSettle(const Duration(seconds: 5));

    // 点第1格 → 完整复刻链路
    final taps = find.byType(GestureDetector);
    await tester.tap(taps.first);
    await tester.pump(); // onTap同步段(setState)
    // ANR=主线程5秒卡死——pumpAndSettle给10秒，卡住即超时复现
    await tester.pumpAndSettle(const Duration(seconds: 10));

    expect(find.byType(Dialog), findsOneWidget,
        reason: '全屏Dialog应已打开（若此处失败+pump超时=死锁复现）');
  }, timeout: const Timeout(Duration(seconds: 60)));
}
