import 'package:flutter_test/flutter_test.dart';
import 'package:novel_analyzer/models/arc.dart';
import 'package:novel_analyzer/services/scene_stream.dart';

void main() {
  Arc mk(int n, int sf, int st, int sc, int ec) => Arc(
    number: n, title: 't$n', chapterRange: '', startChapter: sc, endChapter: ec,
    sceneFrom: sf, sceneTo: st, status: 'complete', summary: '', focusCharacter: '',
    closeType: 'real', boundaryAnchor: '', boundaryOffset: -1, text: '',
  );
  test('正常覆盖通过', () {
    final r = auditArcCoverage([mk(1,1,10,1,8), mk(2,11,25,9,15), mk(3,26,40,16,27)], 40, 27);
    expect(r, isNull);
  });
  test('章洞16-23被拦下(用户截图实证形态)', () {
    final r = auditArcCoverage([mk(1,1,16,1,15), mk(2,17,24,24,27), mk(3,25,40,28,40)], 40, 40);
    expect(r, contains('章未被任何弧线覆盖'));
    expect(r, contains('16'));
  });
  test('场景洞被拦下', () {
    final r = auditArcCoverage([mk(1,1,16,1,15), mk(2,18,24,16,20)], 24, 20);
    expect(r, contains('场景'));
    expect(r, contains('17'));
  });
}
