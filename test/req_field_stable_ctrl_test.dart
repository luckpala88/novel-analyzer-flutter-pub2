import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_analyzer/widgets/req_field.dart';

void main() {
  testWidgets('v1507b：稳定外部controller+逐键rebuild，输入不被抹回', (tester) async {
    final extCtrl = TextEditingController(text: '旧值'); // 稳定但从不随输入更新
    String saved = '旧值';
    Widget w({required ValueChanged<String>? onChanged}) => MaterialApp(
          home: Scaffold(
            body: ReqField(
              controller: extCtrl,
              labelText: '测试',
              onChanged: onChanged,
            ),
          ),
        );

    await tester.pumpWidget(w(
      onChanged: (v) => saved = v, // 模拟落库但不更新extCtrl
    ));
    final field = find.byType(TextField);
    await tester.enterText(field, '旧值ABC');
    await tester.pumpWidget(w(
      onChanged: (v) => saved = v, // rebuild（didUpdateWidget触发）
    ));
    final tf = tester.widget<TextField>(field);
    expect(tf.controller!.text, '旧值ABC'); // 输入保留，不被外部旧值抹掉

    // 外部程序化填充（如AI生成回填）→ 同步进内部
    extCtrl.text = 'AI新稿';
    await tester.pumpWidget(w(
      onChanged: (v) => saved = v,
    ));
    expect(tester.widget<TextField>(field).controller!.text, 'AI新稿');

    // 外部回旧值再rebuild（无新程序化改动）→ 不抹内部
    await tester.pumpWidget(w(
      onChanged: (v) => saved = v,
    ));
    expect(tester.widget<TextField>(field).controller!.text, 'AI新稿');
  });
}
