// 沙盒验证composeCoverText画字逻辑（复刻chat_page实现）
import 'dart:ui' as ui;
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<Uint8List?> compose(Uint8List baseBytes, String bookName, String author,
    {String fontFamily = ''}) async {
  if (bookName.isEmpty) return null;
  final codec = await ui.instantiateImageCodec(baseBytes);
  final frame = await codec.getNextFrame();
  final img = frame.image;
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  canvas.drawImage(img, ui.Offset.zero, ui.Paint());
  final fontSize = img.width / (bookName.length * 1.15);
  final nameX = (img.width - fontSize * bookName.length) / 2;
  final nameY = img.height * 0.06;
  final ff = fontFamily.isEmpty ? null : fontFamily;
  final textSpan = TextSpan(
      text: bookName,
      style: TextStyle(
          fontSize: fontSize,
          fontFamily: ff,
          fontWeight: FontWeight.w900,
          foreground: ui.Paint()
            ..shader = ui.Gradient.linear(
                ui.Offset(nameX, nameY),
                ui.Offset(nameX, nameY + fontSize * 1.15),
                const [
                  Color(0xFFFFF3B0),
                  Color(0xFFFFD700),
                  Color(0xFFB8860B),
                ], [0.0, 0.5, 1.0], TileMode.clamp)));
  final strokeSpan = TextSpan(
      text: bookName,
      style: TextStyle(
          fontSize: fontSize,
          fontFamily: ff,
          fontWeight: FontWeight.w900,
          foreground: ui.Paint()
            ..color = Colors.black
            ..style = ui.PaintingStyle.stroke
            ..strokeWidth = fontSize / 12));
  for (final span in [strokeSpan, textSpan]) {
    final tp = TextPainter(text: span, textDirection: TextDirection.ltr)
      ..layout(maxWidth: img.width * 0.92);
    tp.paint(canvas, ui.Offset(nameX, nameY));
  }
  final pic = recorder.endRecording();
  final out = await pic.toImage(img.width, img.height);
  final bd = await out.toByteData(format: ui.ImageByteFormat.png);
  img.dispose();
  return bd?.buffer.asUint8List();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('composeCoverText 画字验证', () async {
    // 生成640x960纯白底图
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    canvas.drawRect(
        const Rect.fromLTWH(0, 0, 640, 960), ui.Paint()..color = Colors.white);
    final pic = recorder.endRecording();
    final img = await pic.toImage(640, 960);
    final base = (await img.toByteData(format: ui.ImageByteFormat.png))!
        .buffer
        .asUint8List();

    final out = await compose(base, '神通者', 'luckpala');
    expect(out, isNotNull, reason: '合成返回null');
    expect(out!.length, greaterThan(base.length),
        reason: '输出PNG应比纯白底图大（含字形数据）');
    print('输入PNG ${base.length}B → 输出PNG ${out.length}B');

    // 解码输出，检查书名区域（y=0.06h附近）像素不再纯白
    final codec = await ui.instantiateImageCodec(out);
    final frame = await codec.getNextFrame();
    final data =
        await frame.image.toByteData(format: ui.ImageByteFormat.rawRgba);
    final px = data!.buffer.asUint32List();
    final y0 = (960 * 0.06 + 30).toInt() * 640;
    var changed = 0;
    for (var i = y0; i < y0 + 640 * 60 && i < px.length; i++) {
      if (px[i] != 0xFFFFFFFF) changed++;
    }
    print('书名区域非白像素: $changed');
    expect(changed, greaterThan(100), reason: '书名区域应有大量文字像素');
  });
}
