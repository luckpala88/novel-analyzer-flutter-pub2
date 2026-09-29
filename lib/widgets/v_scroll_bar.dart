import 'dart:async';

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
///
/// v949：交互重构（用户实测：宽命中区+点轨道跳转+常显=三重误触源）
/// - 贴最右侧（right:2），命中区收窄=视觉宽28
/// - 点轨道不再跳转——只拖滑块（删onTapUp轨道层）
/// - 无滚动动作2秒后自动淡出；隐藏时IgnorePointer防幽灵命中，滚动即现
class VScrollBar extends StatefulWidget {
  final ScrollController ctl;
  final double thickness; // 视觉宽度
  final double hitWidth; // 命中区宽度

  const VScrollBar(
    this.ctl, {
    super.key,
    this.thickness = 28,
    this.hitWidth = 28, // v949：命中区=视觉宽（旧40易误触）
  });

  @override
  State<VScrollBar> createState() => _VScrollBarState();
}

class _VScrollBarState extends State<VScrollBar> {
  bool _visible = true; // v949：自动隐藏态
  Timer? _hideTimer;

  @override
  void initState() {
    super.initState();
    widget.ctl.addListener(_onScroll);
    _reshow(); // 初始显示2秒后淡出
    _scheduleRebuild();
  }

  @override
  void didUpdateWidget(VScrollBar old) {
    super.didUpdateWidget(old);
    if (old.ctl != widget.ctl) {
      old.ctl.removeListener(_onScroll);
      widget.ctl.addListener(_onScroll);
      _reshow();
      _scheduleRebuild();
    }
  }

  /// v949：显示+重置2秒隐藏计时（可取消Timer——滚动高频回调不堆叠delay）
  void _reshow() {
    _hideTimer?.cancel();
    if (!mounted) return;
    if (!_visible) setState(() => _visible = true);
    _hideTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _visible = false);
    });
  }

  void _onScroll() {
    if (!mounted) return;
    _reshow();
    setState(() {});
  }

  void _scheduleRebuild() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
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
    // v931：offset内部=positions.single（v667同款坑）——用pos.last.offset
    var top = (pos.pixels / maxScroll) * (trackH - thumbH);
    top = top.isFinite ? top.clamp(0.0, trackH - thumbH) : 0.0;
    final cs = Theme.of(context).colorScheme;
    return IgnorePointer(
      // v949：隐藏态零命中（幽灵误触根除）
      ignoring: !_visible,
      child: AnimatedOpacity(
        opacity: _visible ? 1.0 : 0.0,
        duration: const Duration(milliseconds: 250),
        child: SizedBox(
          width: widget.hitWidth,
          child: Stack(
            children: [
              // v949：轨道点按跳转已删（误触源）——保留透明轨道仅作拇指背景定位
              const Positioned.fill(child: SizedBox.shrink()),
              // 拇指拖拽（按下即赢）——v949贴最右(right:2)
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
                          _reshow(); // 拖拽中保持显示
                          final scale = maxScroll / (trackH - thumbH);
                          ctl.jumpTo((ctl.offset + d.delta.dy * scale)
                              .clamp(0.0, maxScroll));
                        };
                        instance.onEnd = (_) => _reshow();
                      },
                    ),
                  },
                  child: Container(
                    width: widget.thickness,
                    height: thumbH,
                    decoration: BoxDecoration(
                      color: cs.primary.withOpacity(0.28),
                      borderRadius: BorderRadius.circular(7),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
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
