import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../state/app_state.dart';

/// 按下即赢手势竞技场——普通GestureDetector的垂直拖拽与列表滚动识别器
/// 同场竞技,列表常先赢(用户实测"要停顿一会儿才能选中")。addPointer时
/// 立即accept,拇指独占该指针,列表不再抢
class _ImmediateDrag extends VerticalDragGestureRecognizer {
  @override
  void addPointer(PointerDownEvent event) {
    super.addPointer(event);
    resolve(GestureDisposition.accepted);
  }
}

/// v664：自绘可拖垂直滚动条
/// - StatefulWidget：ScrollController在列表挂载/尺寸就绪时**不通知**,
///   此前无状态版首帧永远shrink(用户实测"重启后无滚动条"),就绪后主动
///   补一帧重建
/// - build全程try/catch：任何首帧布局怪癖(约束未定/极端尺寸)一律降级
///   为无滚动条,绝不喷红字(用户实测"重启满屏红字,点API设置重排后消失")
class VScrollBar extends StatefulWidget {
  final ScrollController ctl;
  final double thickness; // 视觉宽度
  final double hitWidth; // 命中区宽度(大于视觉宽度,手指友好)

  const VScrollBar(
    this.ctl, {
    super.key,
    this.thickness = 28, // v668：宽度翻倍(14→28),手指好按
    this.hitWidth = 40,
  });

  @override
  State<VScrollBar> createState() => _VScrollBarState();
}

class _VScrollBarState extends State<VScrollBar> {
  @override
  void initState() {
    super.initState();
    widget.ctl.addListener(_onScroll);
    _scheduleRebuild();
  }

  @override
  void didUpdateWidget(VScrollBar old) {
    super.didUpdateWidget(old);
    if (old.ctl != widget.ctl) {
      old.ctl.removeListener(_onScroll);
      widget.ctl.addListener(_onScroll);
      _scheduleRebuild();
    }
  }

  void _onScroll() {
    if (mounted) setState(() {});
  }

  void _scheduleRebuild() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    widget.ctl.removeListener(_onScroll);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    Widget? result;
    try {
      result = _build(context);
    } catch (e) {
      // v665：降级不静默——真实原因打进统一终端(用户可复制回报定位)
      try {
        AppState.instance.apiLog('⛔ 滚动条布局异常(已降级): $e');
      } catch (_) {}
      result = const SizedBox.shrink(); // 布局怪癖降级：无滚动条不喷红字
    }
    return result ?? const SizedBox.shrink();
  }

  Widget? _build(BuildContext context) {
    final ctl = widget.ctl;
    if (!ctl.hasClients) return null;
    // v667：不用ctl.position(=positions.single)——页面切换/重排那一帧
    // 旧position未detach新position已attach,single撞双挂载抛"Too many
    // elements"(iqoo实测)。取最新position,瞬时态也稳
    if (ctl.positions.isEmpty) return null;
    final pos = ctl.positions.last;
    // hasContentDimensions=false=首帧尺寸未定——等下一帧(postFrame已排)
    if (!pos.hasContentDimensions) return null;
    final trackH = _trackH;
    if (trackH == null || trackH <= 0) return null;
    final maxScroll = pos.maxScrollExtent;
    if (maxScroll <= 0 || !maxScroll.isFinite) return null;

    final viewRatio =
        (pos.viewportDimension / (pos.viewportDimension + maxScroll))
            .clamp(0.08, 1.0);
    var thumbH = (trackH * viewRatio).clamp(24.0, trackH);
    var top = (ctl.offset / maxScroll) * (trackH - thumbH);
    top = top.isFinite ? top.clamp(0.0, trackH - thumbH) : 0.0;
    final cs = Theme.of(context).colorScheme;
    return SizedBox(
      width: widget.hitWidth,
      child: Stack(
        children: [
          // 轨道点按跳转
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTapUp: (d) {
                final ratio =
                    (d.localPosition.dy / trackH).clamp(0.0, 1.0);
                ctl.jumpTo(ratio * maxScroll);
              },
            ),
          ),
          // 拇指拖拽（按下即赢）
          Positioned(
            top: top,
            right: 2,
            child: RawGestureDetector(
              behavior: HitTestBehavior.opaque,
              gestures: {
                _ImmediateDrag:
                    GestureRecognizerFactoryWithHandlers<_ImmediateDrag>(
                  () => _ImmediateDrag(),
                  (instance) {
                    instance.onUpdate = (d) {
                      final scale = maxScroll / (trackH - thumbH);
                      ctl.jumpTo((ctl.offset + d.delta.dy * scale)
                          .clamp(0.0, maxScroll));
                    };
                  },
                ),
              },
              child: Container(
                width: widget.thickness,
                height: thumbH,
                decoration: BoxDecoration(
                  color: cs.primary.withOpacity(0.28), // v668：更透更浅,不抢内容视线
                  borderRadius: BorderRadius.circular(7),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  double? get _trackH {
    try {
      final box = context.findRenderObject();
      if (box is RenderBox && box.hasSize && box.size.height > 0) {
        return box.size.height;
      }
    } catch (_) {}
    return null;
  }
}
