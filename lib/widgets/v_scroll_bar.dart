import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';

/// v660：自绘可拖垂直滚动条——Material Scrollbar在触屏上拇指拖拽
/// 常被列表垂直手势抢占(用户实测"无法选中拖动")。自绘手势层盖在
/// 列表之上,pan+tap必中
/// v663：按下即赢手势竞技场——普通GestureDetector的垂直拖拽与列表
/// 滚动识别器同场竞技,列表常先赢(用户实测"要停顿一会儿才能选中")。
/// addPointer时立即accept,拇指独占该指针,列表不再抢
class _ImmediateDrag extends VerticalDragGestureRecognizer {
  @override
  void addPointer(PointerDownEvent event) {
    super.addPointer(event);
    resolve(GestureDisposition.accepted);
  }
}

class VScrollBar extends StatelessWidget {
  final ScrollController ctl;
  final double thickness; // 视觉宽度
  final double hitWidth; // 命中区宽度(大于视觉宽度,手指友好)

  const VScrollBar(
    this.ctl, {
    super.key,
    this.thickness = 14,
    this.hitWidth = 28,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: ctl,
      builder: (_, __) => LayoutBuilder(
        builder: (ctx, box) {
          final trackH = box.maxHeight;
          if (trackH <= 0 ||
              !trackH.isFinite ||
              !ctl.hasClients) {
            return const SizedBox.shrink();
          }
          final pos = ctl.position;
          final maxScroll = pos.maxScrollExtent;
          if (maxScroll <= 0 ||
              !maxScroll.isFinite ||
              !pos.viewportDimension.isFinite) {
            return const SizedBox.shrink();
          }
          final viewRatio =
              (pos.viewportDimension / (pos.viewportDimension + maxScroll))
                  .clamp(0.08, 1.0);
          var thumbH = trackH * viewRatio;
          var top = (ctl.offset / maxScroll) * (trackH - thumbH);
          top = top.isFinite ? top.clamp(0.0, trackH - thumbH) : 0.0;
          thumbH = thumbH.isFinite ? thumbH.clamp(24.0, trackH) : 24.0;
          final cs = Theme.of(context).colorScheme;
          return SizedBox(
            width: hitWidth,
            child: Stack(
              children: [
                // 轨道点按跳转
                Positioned.fill(
                  child: GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    onTapUp: (d) {
                      final ratio = (d.localPosition.dy / trackH)
                          .clamp(0.0, 1.0);
                      ctl.jumpTo(ratio * maxScroll);
                    },
                  ),
                ),
                // 拇指拖拽
                Positioned(
                  top: top,
                  right: 2,
                  child: RawGestureDetector(
                    behavior: HitTestBehavior.opaque,
                    gestures: {
                      _ImmediateDrag:
                          GestureRecognizerFactoryWithHandlers<
                              _ImmediateDrag>(
                        () => _ImmediateDrag(),
                        (instance) {
                          instance.onUpdate = (d) {
                            final scale = maxScroll / (trackH - thumbH);
                            ctl.jumpTo(
                                (ctl.offset + d.delta.dy * scale)
                                    .clamp(0.0, maxScroll));
                          };
                        },
                      ),
                    },
                    child: Container(
                      width: thickness,
                      height: thumbH,
                      decoration: BoxDecoration(
                        color: cs.primary.withOpacity(0.55),
                        borderRadius: BorderRadius.circular(7),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
