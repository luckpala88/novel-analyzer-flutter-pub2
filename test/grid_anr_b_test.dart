// v1470沙盒B：补真机要素——①重新取图的readAsBytesSync同步IO ②4张独立大图
// （前次全绿因4格共用同一bytes=ImageCache只解码1次；真机是4次+慢盘）
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'pngs.dart';

Uint8List _png(String b64) => Uint8List.fromList(Uri.parse('data:image/png;base64,$b64').data!.contentAsBytes());

void main() {
  testWidgets('沙盒B：同步读盘x4+独立大图四格+tap全链', (tester) async {
    // ①模拟重新取图：写盘4份独立PNG再readAsBytesSync读回（真机2MB级，测试用VT×4拷贝）
    final vt = _png(VT);
    final dir = await Directory.systemTemp.createTemp('anrtest');
    final grid = <Uint8List>[];
    for (var i = 0; i < 4; i++) {
      final f = File('${dir.path}/g$i.png');
      await f.writeAsBytes(vt, flush: true);
      grid.add(f.readAsBytesSync()); // ← 与_reFetchFromTicket同款同步读
    }

    int sel = 0;
    Uint8List? bytes;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              bytes ??= grid[0];
              return Container(
                width: 260,
                padding: const EdgeInsets.all(4),
                child: Column(children: [
                  GridView.count(
                    crossAxisCount: 2,
                    shrinkWrap: true,
                    childAspectRatio: 0.78,
                    children: [
                      for (var i = 0; i < grid.length; i++)
                        GestureDetector(
                          onTap: () {
                            setState(() {
                              sel = i;
                              bytes = grid[i];
                            });
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
                                          child: InteractiveViewer(
                                            child: Image.memory(bytes ?? grid[i], fit: BoxFit.contain),
                                          ),
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
                ]),
              );
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle(const Duration(seconds: 10));

    await tester.tap(find.byType(GestureDetector).first);
    await tester.pump();
    await tester.pumpAndSettle(const Duration(seconds: 15));

    expect(find.byType(Dialog), findsOneWidget, reason: '全屏应已打开——超时即复现死锁');
    await dir.delete(recursive: true);
  }, timeout: const Timeout(Duration(seconds: 120)));
}
