import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('help manual sections & keyword hit', () async {
    final raw = await rootBundle.loadString('assets/docs/help_manual.md');
    final sections = raw.split(RegExp(r'(?=\n## )'));
    final catalog = sections
        .map((e) => e.trim().split('\n').first.replaceFirst('## ', '').trim())
        .where((t) => t.isNotEmpty && t != '# APP功能说明书（聊天助手按需查阅）')
        .toList();
    print('sections=${sections.length} catalog=$catalog');
    expect(catalog.length, 11);
    final hits = sections.where((e) => e.toLowerCase().contains('chat_images')).take(2);
    expect(hits.isNotEmpty, true);
    expect(hits.first, contains('Documents'));
  });
}
