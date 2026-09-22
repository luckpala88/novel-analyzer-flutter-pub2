import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_analyzer/widgets/v_scroll_bar.dart';

void main() {
  testWidgets('VScrollBar in Stack over ListView does not throw', (tester) async {
    final ctl = ScrollController();
    final errors = <FlutterErrorDetails>[];
    FlutterError.onError = (d) {
      errors.add(d);
      // ignore: avoid_print
      print('=== CAPTURED EXCEPTION ===\n${d.exception}\n=== STACK ===\n${d.stack}');
    };
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Column(
          children: [
            Expanded(
          child: SelectionArea(
            child: Stack(
              children: [
                ListView.builder(
                  controller: ctl,
                  itemCount: 904,
                  itemBuilder: (ctx, i) => Container(
                    height: 120,
                    margin: const EdgeInsets.all(8),
                    child: Text('场景$i'),
                  ),
                ),
                Positioned(
                  right: 0, top: 0, bottom: 0,
                  child: VScrollBar(ctl),
                ),
              ],
            ),
          ),
            ),
          ],
        ),
      ),
    ));
    await tester.pumpAndSettle();
    ctl.jumpTo(5000);
    await tester.pump();
    ctl.jumpTo(20000);
    await tester.pump();
    await tester.pumpAndSettle();
    expect(errors, isEmpty,
        reason: errors.map((e) => e.exception.toString()).join('\n---\n'));
  });
}
