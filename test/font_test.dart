// 三字体渲染对比：楷/行为何丢字
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> loadFont(String family, String path) async {
  final data = await rootBundle.load(path);
  final loader = FontLoader(family)..addFont(Future.value(data));
  await loader.load();
}

Future<int> inkPixels(String family, String text) async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  canvas.drawRect(const Rect.fromLTWH(0, 0, 640, 300),
      ui.Paint()..color = Colors.white);
  final tp = TextPainter(
      text: TextSpan(
          text: text,
          style: TextStyle(fontSize: 120, fontFamily: family.isEmpty ? null : family)),
      textDirection: TextDirection.ltr)
    ..layout(maxWidth: 600);
  tp.paint(canvas, const ui.Offset(20, 50));
  debugPrint('$family: tp.width=${tp.width}, height=${tp.height}');
  final img = await recorder.endRecording().toImage(640, 300);
  final data = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
  final px = data!.buffer.asUint32List();
  var ink = 0;
  for (final p in px) {
    if ((p & 0xFFFFFF) != 0xFFFFFF) ink++;
  }
  return ink;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('三字体渲染对比', () async {
    await loadFont('KaiShu', 'assets/fonts/kai.ttf');
    await loadFont('XingShu', 'assets/fonts/xing.ttf');
    await loadFont('CaoShu', 'assets/fonts/cao.ttf');
    for (final f in ['', 'KaiShu', 'XingShu', 'CaoShu']) {
      final ink = await inkPixels(f, '神通者');
      final inkRare = await inkPixels(f, '籥魃');
      print('${f.isEmpty ? "黑体(系统)" : f}: 常用字墨水px=$ink, 生僻字墨水px=$inkRare');
    }
  });
}
