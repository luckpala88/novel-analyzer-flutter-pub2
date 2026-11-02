// 显示比例沙盒实测：fitWidth在maxWidth:420约束下，方图/竖图的实际渲染尺寸
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'dart:async';
import 'dart:ui' as ui;
import 'pngs.dart';

Widget mk(Uint8List b) => Center(
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Image.memory(b, fit: BoxFit.fitWidth),
        ),
      ),
    );

void main() {
  testWidgets('fitWidth显示尺寸实测', (tester) async {
    for (final e in {'方图500x500': SQ, '竖图640x960': VT}.entries) {
      final b = Uint8List.fromList(base64Decode(e.value));
      late ui.Image decoded;
      await tester.runAsync(() async {
        final stream = MemoryImage(b).resolve(ImageConfiguration.empty);
        final c = Completer<ui.Image>();
        late ImageStreamListener ls;
        ls = ImageStreamListener((info, _) {
          decoded = info.image;
          if (!c.isCompleted) c.complete(decoded);
          stream.removeListener(ls);
        });
        stream.addListener(ls);
        decoded = await c.future;
      });
      await tester.pumpWidget(mk(b));
      await tester.pumpAndSettle(const Duration(seconds: 2));
      final size = tester.getSize(find.byType(Image).first);
      debugPrint('${e.key} → 解码${decoded.width}x${decoded.height} 显示 ${size.width.toStringAsFixed(0)}x${size.height.toStringAsFixed(0)}');
    }
  });
}
