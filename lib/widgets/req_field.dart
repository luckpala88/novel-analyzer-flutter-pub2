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

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (mounted) setState(() => _expanded = _focus.hasFocus);
    });
  }

  @override
  void dispose() {
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
        controller: widget.controller,
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
