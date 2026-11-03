// v1374复刻真机完整嵌套结构：Dialog.fullscreen+StatefulBuilder+Column+Expanded+FutureBuilder+LayoutBuilder
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// 复刻_adjustInner的拖块结构（v1372版：IgnorePointer底图+opaque拖块）
class FakePage extends StatefulWidget {
  const FakePage({super.key});
  @override
  State<FakePage> createState() => _FakePageState();
}

class _FakePageState extends State<FakePage> {
  bool _adjustMode = false;
  final List<Offset?> _charOffsets = [null]; // 1个字
  final List<String> _logs = [];

  @override
  Widget build(BuildContext context) {
    return StatefulBuilder(
      builder: (d2, setD2) => Dialog.fullscreen(
        backgroundColor: Colors.black,
        child: Column(children: [
          const SizedBox(height: 40),
          Expanded(
            child: _adjustMode
                ? _buildAdjust(setD2)
                : GestureDetector(
                    onTap: () => setD2(() => _adjustMode = true),
                    child: const Center(child: FlutterLogo(size: 120))),
          ),
        ]),
      ),
    );
  }

  Widget _buildAdjust(void Function(void Function()) setD2) {
    return FutureBuilder<Size>(
      future: Future.delayed(const Duration(milliseconds: 10), () => const Size(480, 720)),
      builder: (ctx, snap) {
        if (!snap.hasData) return const Center(child: CircularProgressIndicator());
        return _adjustInner(snap.data!, setD2);
      },
    );
  }

  Widget _adjustInner(Size sz, void Function(void Function()) setD2) {
    return LayoutBuilder(builder: (ctx, box) {
      final scale = box.maxWidth / sz.width;
      final dispH = sz.height * scale;
      return SizedBox(
        height: dispH,
        child: Stack(children: [
          Positioned.fill(
            child: IgnorePointer(
                child: Center(child: Container(color: const Color(0xFF223344)))),
          ),
          Positioned(
            left: (200 + (_charOffsets[0]?.dx ?? 0)) * scale - 30,
            top: (40 + (_charOffsets[0]?.dy ?? 0)) * scale - 30,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onPanStart: (_) => _logs.add('panStart'),
              onPanUpdate: (det) {
                _logs.add('panUpdate d=${det.delta}');
                setD2(() =>
                    _charOffsets[0] = (_charOffsets[0] ?? Offset.zero) + det.delta);
              },
              child: Container(
                width: 60, height: 60,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.white.withOpacity(0.12),
                    border: Border.all(color: const Color(0xFFFFD700), width: 1.5)),
                child: const Text('仙'),
              ),
            ),
          ),
        ]),
      );
    });
  }
}

void main() {
  testWidgets('完整真机结构拖块', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: const FakePage()));
    await tester.pumpAndSettle();
    // 进入调字模式
    await tester.tap(find.byType(FlutterLogo));
    await tester.pumpAndSettle();
    // 金圈中心拖动
    final circle = find.text('仙');
    expect(circle, findsOneWidget);
    final before = tester.getCenter(circle);
    await tester.drag(circle, const Offset(50, 80));
    await tester.pumpAndSettle();
    final after = tester.getCenter(circle);
    debugPrint('金圈位移=${after - before} (期望≈50,80)');
    final st = tester.state(find.byType(FakePage)) as dynamic;
    final logs = st._logs as List<String>;
    debugPrint('手势日志=$logs');
    final off = st._charOffsets[0] as Offset?;
    debugPrint('charOffsets[0]=$off');
    expect((after - before).distance, greaterThan(80),
        reason: '完整嵌套结构下金圈应可拖动');
  });
}
