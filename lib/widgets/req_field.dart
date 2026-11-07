import 'package:flutter/material.dart';

/// 紧凑要求输入框（v242改编页样式，v379提取共享）——
/// 未聚焦1行label，聚焦展开6行；创作页全局要求/改编要求共用
class ReqField extends StatefulWidget {
  const ReqField({
    super.key,
    required this.controller,
    required this.labelText,
    this.hintText,
    this.fontSize = 12,
    this.expandLines = 6,
    this.onChanged,
  });

  final TextEditingController controller;
  final String labelText;
  final String? hintText;
  final double fontSize;
  final int expandLines;
  final ValueChanged<String>? onChanged;

  @override
  State<ReqField> createState() => _ReqFieldState();
}

class _ReqFieldState extends State<ReqField> {
  final _focus = FocusNode();
  bool _expanded = false;
  // v1507：内部稳定controller——调用点（创作页全局要求）传inline新建
  // controller（每次rebuild换实例），中文输入法合成区被掐断=打不进字
  // （v1226改编页同族坑）。内部持有稳定实例；didUpdateWidget只在内部
  // text≠外部text（外部赋值/清空）时同步，用户输入中不打断光标
  TextEditingController? _ownCtrl;
  // v1507b：外部controller基准值——只在外部text相对上次真的变了（程序化
  // 填充/清空）才同步进内部；外部稳定但从不随输入更新时，按text不等就
  // 同步会把用户每敲一字抹回旧值=打不进字（v1226逻辑漏洞真凶）
  String? _lastExt;

  TextEditingController get _ctrl {
    if (_ownCtrl == null) {
      _ownCtrl = TextEditingController(text: widget.controller.text);
      _lastExt = widget.controller.text; // v1507b：创建时记基准，防首帧update误同步
    }
    return _ownCtrl!;
  }

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (mounted) setState(() => _expanded = _focus.hasFocus);
    });
  }

  @override
  void didUpdateWidget(covariant ReqField oldWidget) {
    super.didUpdateWidget(oldWidget);
    final ext = widget.controller.text;
    if (_ownCtrl != null && ext != _lastExt) {
      _lastExt = ext;
      if (ext != _ownCtrl!.text) _ownCtrl!.text = ext;
    } else if (_lastExt == null) {
      _lastExt = ext;
    }
  }

  @override
  void dispose() {
    _ownCtrl?.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedSize(
      duration: const Duration(milliseconds: 150),
      curve: Curves.easeOut,
      alignment: Alignment.topLeft,
      child: TextField(
        controller: _ctrl, // v1507：内部稳定实例（见_ownCtrl注释）
        focusNode: _focus,
        style: TextStyle(fontSize: widget.fontSize),
        maxLines: _expanded ? widget.expandLines : 1,
        minLines: 1,
        keyboardType: TextInputType.multiline,
        decoration: InputDecoration(
          labelText: widget.labelText,
          hintText: _expanded ? widget.hintText : null,
          border: const OutlineInputBorder(),
          isDense: true,
        ),
        onChanged: widget.onChanged,
      ),
    );
  }
}
