// 拖块手势沙盒实测：Stack+Positioned+GestureDetector(onPanUpdate)能否拖动
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('Positioned拖块手势实测', (tester) async {
    const pngStr =
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==';
    final png = base64Decode(pngStr);
    Offset dragDelta = Offset.zero;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: LayoutBuilder(builder: (ctx, box) {
          return Stack(children: [
            Positioned.fill(
              child: IgnorePointer(
                  child: Image.memory(Uint8List.fromList(png),
                      fit: BoxFit.fitWidth)),
            ),
            Positioned(
              left: 100,
              top: 100,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onPanStart: (d) => debugPrint('panStart: ${d.localPosition}'),
                onPanCancel: () => debugPrint('panCancel!'),
                onTapDown: (d) => debugPrint('tapDown: ${d.localPosition}'),
                onPanUpdate: (d) => dragDelta += d.delta,
                child: Container(
                  width: 60,
                  height: 60,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.white.withOpacity(0.12),
                    border: Border.all(color: Colors.amber, width: 1.5),
                  ),
                ),
              ),
            ),
          ]);
        }),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.drag(find.byType(GestureDetector), const Offset(50, 80));
    await tester.pumpAndSettle();
    debugPrint('拖动delta=$dragDelta 期望=(50.0, 80.0)');
    expect(dragDelta, const Offset(50, 80), reason: '拖块应可拖动');
  });
}
