import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> loadFont(String family, String path) async {
  final data = await rootBundle.load(path);
  final loader = FontLoader(family)..addFont(Future.value(data));
  await loader.load();
}

Future<int> inkPixels(String family, String ch) async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  canvas.drawRect(const Rect.fromLTWH(0, 0, 200, 200),
      ui.Paint()..color = const Color(0xFF010101));
  final tp = TextPainter(
      text: TextSpan(
          text: ch,
          style: TextStyle(
              fontSize: 140,
              fontFamily: family.isEmpty ? null : family,
              color: Colors.white)),
      textDirection: TextDirection.ltr)
    ..layout();
  tp.paint(canvas, const ui.Offset(30, 30));
  final img = await recorder.endRecording().toImage(200, 200);
  final png = (await img.toByteData(format: ui.ImageByteFormat.png))!
      .buffer
      .asUint8List();
  final codec = await ui.instantiateImageCodec(png);
  final frame = await codec.getNextFrame();
  final data =
      await frame.image.toByteData(format: ui.ImageByteFormat.rawRgba);
  final px = data!.buffer.asUint32List();
  var ink = 0;
  for (final v in px) {
    final r = (v >> 16) & 0xFF, g = (v >> 8) & 0xFF, b = v & 0xFF;
    if (r > 60 || g > 60 || b > 60) ink++;
  }
  return ink;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('行书字形覆盖实测', () async {
    await loadFont('XingShu', 'assets/fonts/xing.ttf');
    await loadFont('WenKai', 'assets/fonts/wenkai.ttf');
    final samples = ['神', '通', '者', '李', '大', '开', '没', '钱', '修', '仙', '籥', '魃'];
    for (final ch in samples) {
      final xing = await inkPixels('XingShu', ch);
      final wen = await inkPixels('WenKai', ch);
      final sys = await inkPixels('', ch);
      debugPrint('$ch: 行书=$xing 文楷=$wen 黑体=$sys ${xing < 100 ? "←行书缺字!" : ""}');
    }
  });
}
