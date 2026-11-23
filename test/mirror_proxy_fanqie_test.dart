// v1639b：镜像式代理宿主机验证——番茄/rank/1镜像伺服HTML完整性
// 自查汇总式：所有断言收进issues清单，最后一次性报告（避开宿主机
// audioplayers噪声淹没单个expect输出）
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:novel_analyzer/services/render_proxy.dart';

void main() {
  test('镜像模式：原路径伺服番茄榜单页', () async {
    final issues = <String>[];
    final port = await RenderProxy.start();

    final url = RenderProxy.renderUrl(
      'https://fanqienovel.com/rank/1',
      keepScripts: true,
    );
    print('镜像URL：$url');
    if (url.contains('/render?u=')) issues.add('URL仍是/render形式');
    if (!url.contains('/rank/1')) issues.add('URL缺原路径');

    final client = HttpClient();
    final resp =
        await client.getUrl(Uri.parse(url)).then((r) => r.close());
    print('HTTP状态：${resp.statusCode}，content-type：${resp.headers.value('content-type')}');
    final body = await resp
        .fold<List<int>>(<int>[], (a, b) => a..addAll(b))
        .then((b) => String.fromCharCodes(b));
    client.close();
    print('响应长度：${body.length}');

    if (resp.statusCode != 200) issues.add('状态码${resp.statusCode}');
    // 1. SSR内容在
    if (!body.contains('book-item-text')) issues.add('SSR书目缺失');
    // 2. secsdk防篡改脚本已剥
    if (body.contains('security-secsdk')) issues.add('secsdk未剥净');
    if (body.contains('rc-client-security')) issues.add('secglue未剥净');
    // 3. mount点#app存在且后面有内容
    final appIdx = body.indexOf('<div id="app">');
    if (appIdx < 0) {
      issues.add('id=app缺失');
    } else {
      final seg = body.substring(appIdx + 14, appIdx + 214);
      print('app后片段：$seg');
      if (seg.replaceAll(RegExp(r'\s'), '').length < 50) {
        issues.add('app内SSR内容为空');
      }
    }
    // 4. React bundle还在（剥的是sec不是app代码）
    if (!body.contains('<script')) issues.add('app脚本被误剥');
    // 5. 同站绝对链接已转本地路径
    if (!body.contains('href="/page/')) issues.add('站内链接未转本地路径');
    if (body.contains('href="https://fanqienovel.com/page/')) {
      issues.add('绝对链接残留→点击会跳真站');
    }
    await RenderProxy.stop();

    print(issues.isEmpty ? '✅ 全部通过' : '⛔ 问题：${issues.join('；')}');
    expect(issues, isEmpty);
  }, timeout: const Timeout(Duration(seconds: 60)));
}
