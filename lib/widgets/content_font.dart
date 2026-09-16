import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'v119_ui.dart';

/// v288：生成内容字号（每页独立互不干扰）
/// 范围：弧线/场景/分镜/改编/世界 5页（主页/二创/创作页已创作查看器/菜单不参与）
/// 实现：内容区包MediaQuery textScaler子树等比缩放；顶栏按钮在子树外不受影响
class ContentFont {
  static const double min = 0.8;
  static const double max = 1.6;
  static const double step = 0.1;

  static Future<double> load(String pageKey) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getDouble('font_scale_$pageKey') ?? 1.0;
  }

  static Future<void> save(String pageKey, double v) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('font_scale_$pageKey', v);
  }

  /// 内容区包裹：子树所有Text（含显式fontSize）等比缩放
  static Widget area(
    BuildContext context, {
    required double scale,
    required Widget child,
  }) {
    if (scale == 1.0) return child;
    return MediaQuery(
      data: MediaQuery.of(context).copyWith(
        textScaler: TextScaler.linear(scale),
      ),
      child: child,
    );
  }
}

/// 顶栏A-/A+按键对（放各页顶行MiniButton队列里，横滑不折行）
class ContentFontButtons extends StatelessWidget {
  final String pageKey;
  final double scale;
  final ValueChanged<double> onChanged;

  const ContentFontButtons({
    super.key,
    required this.pageKey,
    required this.scale,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        MiniButton(
          label: 'A-',
          onTap: scale > ContentFont.min
              ? () => onChanged(
                  ((scale - ContentFont.step) * 10).round() / 10,
                )
              : null,
        ),
        const SizedBox(width: 4),
        MiniButton(
          label: 'A+',
          onTap: scale < ContentFont.max
              ? () => onChanged(
                  ((scale + ContentFont.step) * 10).round() / 10,
                )
              : null,
        ),
      ],
    );
  }
}
