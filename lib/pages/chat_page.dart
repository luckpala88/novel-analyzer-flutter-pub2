import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:provider/provider.dart';
import '../models/chat_session.dart';
import '../services/api_service.dart';
import '../utils/prompt_builder.dart';
import '../state/app_state.dart';
import '../widgets/api_config_panel.dart';
import '../widgets/v119_ui.dart'; // showV119Sheet / MiniButton

/// v833：AI聊天页——独立会话/独立API/单条复制/流式回复
/// 独立ApiService实例：不与创作任务busy锁互斥，聊天/创作可并行
class ChatPage extends StatefulWidget {
  const ChatPage({super.key});

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage>
    with AutomaticKeepAliveClientMixin {
  final ApiService _chatApi = ApiService(); // 独立实例
  final ScrollController _listCtl = ScrollController();
  final TextEditingController _inputCtl = TextEditingController();
  final FocusNode _inputFocus = FocusNode();
  bool _sending = false;
  final List<ChatAttachment> _pending = []; // v838：待发送附件

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    // 终端日志桥接（v824任务级反馈也进全局终端）
    _chatApi.onLog = (msg) =>
        context.read<AppState>().apiLog('[聊天] $msg');
  }

  @override
  void dispose() {
    _listCtl.dispose();
    _inputCtl.dispose();
    _inputFocus.dispose();
    super.dispose();
  }

  void _jumpBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_listCtl.hasClients) {
        _listCtl.jumpTo(_listCtl.position.maxScrollExtent);
      }
    });
  }

  // ===== v838：附件选择 =====
  static const _imgExt = ['png', 'jpg', 'jpeg', 'webp', 'gif'];
  static const _textExt = [
    'txt', 'md', 'markdown', 'json', 'csv', 'log', 'yaml', 'yml',
    'html', 'htm', 'xml', 'dart', 'py', 'js', 'ts',
  ];

  Future<void> _pickAttachment() async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.image_outlined),
              title: const Text('图片（识别需模型支持视觉）'),
              onTap: () => Navigator.pop(context, 'image'),
            ),
            ListTile(
              leading: const Icon(Icons.description_outlined),
              title: const Text('文本文件（txt/md/json等）'),
              onTap: () => Navigator.pop(context, 'file'),
            ),
          ],
        ),
      ),
    );
    if (choice == null) return;
    final files = await FilePicker.pickFiles(
      type: choice == 'image' ? FileType.image : FileType.any,
    );
    if (files.isEmpty) return;
    final f = files.first;
    // v838：file_picker v13无withData——按uri读字节
    Uint8List bytes;
    try {
      bytes = await File.fromUri(f.uri).readAsBytes();
    } catch (e) {
      _toast('读取文件失败：$e');
      return;
    }
    if (bytes.isEmpty) return;
    final ext = (f.extension ?? '').toLowerCase();
    if (choice == 'image') {
      if (!_imgExt.contains(ext)) {
        _toast('暂不支持该图片格式：$ext');
        return;
      }
      if (bytes.length > 4 * 1024 * 1024) {
        _toast('图片超过4MB——请压缩后重试');
        return;
      }
      final mime = ext == 'png'
          ? 'image/png'
          : ext == 'webp'
              ? 'image/webp'
              : ext == 'gif'
                  ? 'image/gif'
                  : 'image/jpeg';
      setState(() => _pending.add(ChatAttachment(
            name: f.name,
            mime: mime,
            data: base64Encode(bytes),
            isImage: true,
          )));
    } else {
      if (!_textExt.contains(ext)) {
        _toast('不支持的文本格式：.$ext（支持${_textExt.join("/")}）');
        return;
      }
      setState(() => _pending.add(ChatAttachment(
            name: f.name,
            mime: 'text/plain',
            data: utf8.decode(bytes, allowMalformed: true),
            isImage: false,
          )));
    }
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg), duration: const Duration(seconds: 2)));
  }

  /// v836：历史文本构造（含upto索引，inclusive）
  String _histText(List<ChatMessage> msgs, int upto) {
    final hist = StringBuffer();
    for (var i = 0; i <= upto && i < msgs.length; i++) {
      hist.writeln(
          '${msgs[i].role == 'user' ? "用户" : "AI"}：${msgs[i].content}');
    }
    return hist.toString();
  }

  Future<void> _send(AppState state) async {
    final text = _inputCtl.text.trim();
    if ((text.isEmpty && _pending.isEmpty) || _sending) return;
    var sess = state.chatActive;
    if (sess == null) {
      state.newChatSession();
      sess = state.chatActive;
      if (sess == null) return;
    }
    // 首条消息作为会话标题（截前16字）
    if (sess.messages.isEmpty) {
      sess.title = text.length > 16 ? text.substring(0, 16) : text;
    }
    final atts = List<ChatAttachment>.from(_pending);
    setState(() {
      sess!.messages.add(ChatMessage(
        role: 'user',
        content: text,
        ts: DateTime.now().millisecondsSinceEpoch,
        attachments: atts,
      ));
      _pending.clear();
    });
    _inputCtl.clear();
    final hist = _histText(sess.messages, sess.messages.length - 1);
    await _generate(state, text, hist, atts: atts);
  }

  /// v836：重新回答——把该条AI回复对应的提问重新发送，新答案追加不覆盖旧答案
  Future<void> _regen(AppState state, int aiIdx) async {
    if (_sending) return;
    final sess = state.chatActive;
    if (sess == null || aiIdx <= 0) return;
    // 向前找最近的user消息
    String text = '';
    var userIdx = -1;
    for (var i = aiIdx - 1; i >= 0; i--) {
      if (sess.messages[i].role == 'user') {
        text = sess.messages[i].content;
        userIdx = i;
        break;
      }
    }
    if (text.isEmpty) return;
    // 历史=该提问及之前（不含旧AI答案与更早内容）——fresh重答
    final hist = _histText(sess.messages, userIdx);
    await _generate(state, text, hist);
  }

  /// v836：生成核心（追加assistant占位→流式更新→落盘），供_send/_regen共用
  /// v838：atts——文本类附件注入prompt，图片附件走vision
  Future<void> _generate(AppState state, String text, String hist,
      {List<ChatAttachment> atts = const []}) async {
    final sess = state.chatActive;
    if (sess == null || _sending) return;
    setState(() {
      sess.messages.add(ChatMessage(
        role: 'assistant',
        content: '…',
        ts: DateTime.now().millisecondsSinceEpoch,
      ));
      _sending = true;
    });
    state.saveChatSessions();
    _jumpBottom();

    final replyIdx = sess.messages.length - 1;
    final sys = '你是网文创作搭子，与作者自由聊天：可以讨论剧情/人物/设定/写作技巧，'
        '也可以闲聊；同时你是本APP「网文拆解器」的功能助手，作者问APP功能/选项/流程时按下助手手册解答，'
        '手册没写的不要编。回答直接自然，不需要客套。当前书目：${state.currentBook}'
        '${state.chapters.isNotEmpty ? '（共${state.chapters.length}章）' : ''}。\n\n'
        '${PromptBuilderHelp.appHelpDoc}';
    // v838：文本类附件注入prompt（图片走vision）；文本上限60KB防prompt爆炸
    String textAll = text;
    final imgs = <({String mime, String base64})>[];
    for (final a in atts) {
      if (a.isImage) {
        imgs.add((mime: a.mime, base64: a.data));
      } else {
        final body = a.data.length > 60000
            ? '${a.data.substring(0, 60000)}\n…（超长截断）'
            : a.data;
        textAll += '\n\n【附件：${a.name}】\n$body';
      }
    }
    final usr = hist.isEmpty
        ? textAll
        : '【聊天历史】\n${hist}【本轮用户消息】\n$textAll';
    try {
      final r = await _chatApi.callApi(
        task: '聊天回复',
        systemPrompt: sys,
        userPrompt: usr,
        apiConfig: state.getApiConfig('chat'),
        images: imgs,
        onChunk: (chunk) {
          if (!mounted) return;
          setState(() {
            final m = state.chatActive!.messages[replyIdx];
            m.content = m.content == '…' ? chunk : m.content + chunk;
          });
          _jumpBottom();
        },
      );
      if (mounted) {
        setState(() {
          final m = state.chatActive!.messages[replyIdx];
          if (r.isSuccess) {
            if (m.content == '…') m.content = r.content;
          } else {
            m.content = '⚠️ ${r.error ?? '请求失败'}';
          }
        });
        state.saveChatSessions();
      }
    } finally {
      if (mounted) setState(() => _sending = false);
      _inputFocus.requestFocus();
    }
  }

  Future<void> _renameSession(AppState state, ChatSession s) async {
    final ctl = TextEditingController(text: s.title);
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('重命名会话'),
        content: TextField(controller: ctl, autofocus: true),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('确定')),
        ],
      ),
    );
    if (ok == true && ctl.text.trim().isNotEmpty) {
      s.title = ctl.text.trim();
      state.saveChatSessions();
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final state = context.watch<AppState>();
    final sess = state.chatActive;

    return Scaffold(
      backgroundColor: const Color(0xFFFAF6EE),
      appBar: AppBar(
        backgroundColor: const Color(0xFFF3E9D4),
        titleSpacing: 8,
        title: Row(children: [
          // v833：会话下拉切换
          Expanded(
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                value: sess?.id,
                isDense: true,
                isExpanded: true,
                items: state.chatSessions
                    .map((s) => DropdownMenuItem(
                        value: s.id,
                        child: Text(s.title,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 14))))
                    .toList(),
                onChanged: (id) => setState(() => state.chatActiveId = id ?? ''),
                hint: const Text('暂无会话', style: TextStyle(fontSize: 14)),
              ),
            ),
          ),
        ]),
        actions: [
          MiniButton(
              label: '新建',
              onTap: () {
                state.newChatSession();
                setState(() {});
              }),
          if (sess != null) ...[
            MiniButton(label: '改名', onTap: () => _renameSession(state, sess)),
            MiniButton(
                label: '删除',
                onTap: () async {
                  final ok = await showDialog<bool>(
                    context: context,
                    builder: (_) => AlertDialog(
                      title: const Text('删除会话'),
                      content: Text('删除「${sess.title}」？聊天记录不可恢复。'),
                      actions: [
                        TextButton(
                            onPressed: () => Navigator.pop(context, false),
                            child: const Text('取消')),
                        TextButton(
                            onPressed: () => Navigator.pop(context, true),
                            child: const Text('删除')),
                      ],
                    ),
                  );
                  if (ok == true) {
                    state.deleteChatSession(sess.id);
                    setState(() {});
                  }
                }),
          ],
          MiniButton(
            label: '⚙ API',
            onTap: () => showV119Sheet(
              context,
              title: 'API设置 · AI聊天',
              child: ApiConfigPanel(
                config: state.getApiConfig('chat'),
                section: 'chat',
              ),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: sess == null || sess.messages.isEmpty
                ? Center(
                    child: Text(
                      sess == null ? '点右上「新建」开始会话' : '输入第一条消息开始聊天',
                      style: const TextStyle(color: Color(0xFF9B8F7A)),
                    ),
                  )
                : ListView.builder(
                    controller: _listCtl,
                    padding: const EdgeInsets.fromLTRB(10, 10, 10, 6),
                    itemCount: sess.messages.length,
                    itemBuilder: (ctx, i) {
                      final m = sess.messages[i];
                      final isUser = m.role == 'user';
                      return _bubble(state, m, isUser, i);
                    },
                  ),
          ),
          if (_sending)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: MiniButton(
                label: '⏹ 终止生成',
                onTap: () => _chatApi.abort(),
              ),
            ),
          // v838：待发送附件预览条
          if (_pending.isNotEmpty)
            Container(
              height: 56,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: ListView(
                scrollDirection: Axis.horizontal,
                children: [
                  for (var i = 0; i < _pending.length; i++)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: Stack(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(4),
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: const Color(0xFFE2D9C6)),
                            ),
                            child: _pending[i].isImage
                                ? Image.memory(
                                    base64Decode(_pending[i].data),
                                    height: 44,
                                    fit: BoxFit.cover,
                                  )
                                : SizedBox(
                                    height: 44,
                                    child: Center(
                                      child: Text('📄 ${_pending[i].name}',
                                          style: const TextStyle(fontSize: 12)),
                                    ),
                                  ),
                          ),
                          Positioned(
                            right: -2,
                            top: -2,
                            child: GestureDetector(
                              onTap: () => setState(() => _pending.removeAt(i)),
                              child: const CircleAvatar(
                                radius: 9,
                                backgroundColor: Color(0xFFB4552D),
                                child: Icon(Icons.close,
                                    size: 12, color: Colors.white),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
              child: Row(
                children: [
                  // v838：附件按钮
                  MiniButton(
                    label: '📎',
                    onTap: _sending ? null : () => _pickAttachment(),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: TextField(
                      controller: _inputCtl,
                      focusNode: _inputFocus,
                      minLines: 1,
                      maxLines: 4,
                      style: const TextStyle(fontSize: 14.5),
                      decoration: InputDecoration(
                        isDense: true,
                        hintText: '输入消息…',
                        filled: true,
                        fillColor: Colors.white,
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 8),
                        border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10)),
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  MiniButton(
                    label: '发送',
                    primary: true,
                    onTap: _sending ? null : () => _send(state),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _bubble(AppState state, ChatMessage m, bool isUser, int idx) {
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Column(
        crossAxisAlignment: isUser
            ? CrossAxisAlignment.end
            : CrossAxisAlignment.start,
        children: [
          _bubbleBody(state, m, isUser),
          // v836：重新回答——重发该轮提问，新答案追加不覆盖
          if (!isUser && idx > 0 && !_sending && m.content != '…')
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: MiniButton(
                label: '↻ 重新回答',
                onTap: () => _regen(state, idx),
              ),
            ),
        ],
      ),
    );
  }

  Widget _bubbleBody(AppState state, ChatMessage m, bool isUser) {
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 3),
        padding: const EdgeInsets.fromLTRB(10, 7, 10, 7),
        constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width * 0.82),
        decoration: BoxDecoration(
          color: isUser ? const Color(0xFFDCEBDD) : Colors.white,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
              color: isUser ? const Color(0xFFB7D3B9) : const Color(0xFFE2D9C6)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            // v838：消息附件（图片缩略图/文件名chip）
            for (final a in m.attachments)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: a.isImage
                    ? ClipRRect(
                        borderRadius: BorderRadius.circular(6),
                        child: Image.memory(
                          base64Decode(a.data),
                          width: 180,
                          fit: BoxFit.cover,
                        ),
                      )
                    : Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: const Color(0xFFF5F1E6),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text('📄 ${a.name}',
                            style: const TextStyle(fontSize: 12)),
                      ),
              ),
            Stack(
              children: [
                // v836：富文本渲染（JSON美化/简易markdown），单条复制保留
                Padding(
                  padding: const EdgeInsets.only(right: 22),
                  child: _richContent(m.content),
                ),
                Positioned(
                  right: 0,
                  top: 0,
                  child: GestureDetector(
                    onTap: () {
                      Clipboard.setData(ClipboardData(text: m.content));
                      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                          content: Text('已复制'),
                          duration: Duration(seconds: 1)));
                    },
                    child: const Icon(Icons.copy,
                        size: 15, color: Color(0xFF9B8F7A)),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // ===== v836：聊天富文本渲染 =====

  /// 内容分发：JSON→美化卡片；markdown→富文本span；普通文本原样
  Widget _richContent(String content) {
    final trimmed = content.trim();
    final isJson = (trimmed.startsWith('{') && trimmed.endsWith('}')) ||
        (trimmed.startsWith('[') && trimmed.endsWith(']'));
    if (isJson) {
      try {
        final obj = jsonDecode(trimmed);
        return _jsonWidget(obj);
      } catch (_) {}
    }
    return SelectableText.rich(
      TextSpan(children: _mdSpans(trimmed)),
      style: const TextStyle(fontSize: 14.5, height: 1.5),
    );
  }

  /// 简易markdown解析：#/##/###标题、**粗体**、`code`、-列表、1.列表、```代码块
  List<InlineSpan> _mdSpans(String text) {
    final spans = <InlineSpan>[];
    final lines = text.split('\n');
    var inCode = false;
    var codeBuf = StringBuffer();
    for (final line in lines) {
      if (line.trimLeft().startsWith('```')) {
        if (inCode) {
          // 代码块结束——整块等宽底色
          spans.add(_codeSpan(codeBuf.toString()));
          codeBuf = StringBuffer();
          inCode = false;
        } else {
          inCode = true;
        }
        continue;
      }
      if (inCode) {
        codeBuf.writeln(line);
        continue;
      }
      final t = line.trimLeft();
      final headingM = RegExp(r'^(#{1,4})\s+(.*)').firstMatch(t);
      if (headingM != null) {
        final level = headingM.group(1)!.length;
        final size = 17.0 - level;
        spans.add(TextSpan(
          text: '\n${headingM.group(2)!}\n',
          style: TextStyle(
              fontSize: size,
              fontWeight: FontWeight.w700,
              color: const Color(0xFF8B5E1E),
              height: 1.3),
        ));
        continue;
      }
      final listM = RegExp(r'^([-*]|\d+[.)])\s+(.*)').firstMatch(t);
      if (listM != null) {
        spans.add(TextSpan(
          children: [
            const TextSpan(text: '• ', style: TextStyle(color: Color(0xFFC89137))),
            ..._inlineSpans(listM.group(2)!),
          ],
        ));
        continue;
      }
      spans.addAll(_inlineSpans(line));
      spans.add(const TextSpan(text: '\n'));
    }
    if (inCode && codeBuf.isNotEmpty) spans.add(_codeSpan(codeBuf.toString()));
    return spans;
  }

  // ===== v839：JSON结构化卡片渲染（通用规则，非写死schema）=====
  // object→字段块(key金色小标)；数组→卡片列表；长字符串→正文段；短值→键值行
  Widget _jsonWidget(dynamic node, {String? key, bool inCard = false}) {
    Widget body;
    if (node is Map) {
      final kids = <Widget>[];
      for (final e in node.entries) {
        final v = e.value;
        // 标量短值→行；复合→递归块
        if (v is String || v is num || v is bool) {
          kids.add(Padding(
            padding: const EdgeInsets.only(bottom: 2),
            child: SelectableText.rich(
              TextSpan(children: [
                TextSpan(
                    text: '${_zhKey(e.key)}：',
                    style: const TextStyle(
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF8B5E1E))),
                TextSpan(text: '$v'),
              ]),
              style: const TextStyle(fontSize: 14, height: 1.5),
            ),
          ));
        } else {
          kids.add(_jsonWidget(v, key: e.key.toString(), inCard: inCard));
        }
      }
      body = Column(
          crossAxisAlignment: CrossAxisAlignment.start, children: kids);
    } else if (node is List) {
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final item in node)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: const Color(0xFFF5F1E6),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: const Color(0xFFE2D9C6)),
                ),
                child: _jsonWidget(item, inCard: true),
              ),
            ),
        ],
      );
    } else {
      // 标量（含数组内长文本正文）
      final s = node.toString();
      body = SelectableText(s,
          style: const TextStyle(fontSize: 14, height: 1.5));
    }
    // 组key标题（顶层不显）
    if (key == null) return body;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 4, bottom: 3),
          child: Text(_zhKey(key),
              style: const TextStyle(
                  fontSize: 14.5,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF8B5E1E))),
        ),
        body,
      ],
    );
  }

  /// key美化：下划线/驼峰→空格（不做翻译，AI的key多为英文短语）
  String _zhKey(String k) {
    final spaced = k
        .replaceAllMapped(RegExp(r'_+'), (m) => ' ')
        .replaceAllMapped(
            RegExp(r'([a-z])([A-Z])'), (m) => '${m.group(1)} ${m.group(2)}');
    if (spaced.isEmpty) return spaced;
    return spaced[0].toUpperCase() + spaced.substring(1);
  }

  InlineSpan _codeSpan(String s) {
    return WidgetSpan(
      child: Container(
        width: double.infinity,
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: const Color(0xFFF0EBDD),
          borderRadius: BorderRadius.circular(6),
        ),
        child: SelectableText(s.trimRight(),
            style: const TextStyle(
                fontSize: 12.5, fontFamily: 'monospace', height: 1.4)),
      ),
    );
  }

  /// 行内解析：**粗体**、`code`
  List<InlineSpan> _inlineSpans(String text) {
    final spans = <InlineSpan>[];
    final re = RegExp(r'\*\*(.+?)\*\*|`([^`]+)`');
    var last = 0;
    for (final m in re.allMatches(text)) {
      if (m.start > last) {
        spans.add(TextSpan(text: text.substring(last, m.start)));
      }
      if (m.group(1) != null) {
        spans.add(TextSpan(
            text: m.group(1),
            style: const TextStyle(fontWeight: FontWeight.w700)));
      } else {
        spans.add(TextSpan(
            text: m.group(2),
            style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 13,
                color: Color(0xFF7A5B1E))));
      }
      last = m.end;
    }
    if (last < text.length) spans.add(TextSpan(text: text.substring(last)));
    return spans;
  }
}
