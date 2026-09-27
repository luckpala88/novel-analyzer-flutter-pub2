import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

  Future<void> _send(AppState state) async {
    final text = _inputCtl.text.trim();
    if (text.isEmpty || _sending) return;
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
    setState(() {
      sess!.messages.add(ChatMessage(
        role: 'user',
        content: text,
        ts: DateTime.now().millisecondsSinceEpoch,
      ));
      sess!.messages.add(ChatMessage(
        role: 'assistant',
        content: '…',
        ts: DateTime.now().millisecondsSinceEpoch,
      ));
      _sending = true;
    });
    _inputCtl.clear();
    state.saveChatSessions();
    _jumpBottom();

    final replyIdx = sess!.messages.length - 1;
    // 历史→prompt（全量携带；篇章大了再砍）
    final hist = StringBuffer();
    for (final m in sess.messages) {
      if (identical(m, sess.messages[replyIdx])) continue;
      hist.writeln('${m.role == 'user' ? "用户" : "AI"}：${m.content}');
    }
    final sys = '你是网文创作搭子，与作者自由聊天：可以讨论剧情/人物/设定/写作技巧，'
        '也可以闲聊；同时你是本APP「网文拆解器」的功能助手，作者问APP功能/选项/流程时按下助手手册解答，'
        '手册没写的不要编。回答直接自然，不需要客套。当前书目：${state.currentBook}'
        '${state.chapters.isNotEmpty ? '（共${state.chapters.length}章）' : ''}。\n\n'
        '${PromptBuilderHelp.appHelpDoc}';
    final usr = hist.isEmpty
        ? text
        : '【聊天历史】\n${hist}【本轮用户消息】\n$text';
    try {
      final r = await _chatApi.callApi(
        task: '聊天回复',
        systemPrompt: sys,
        userPrompt: usr,
        apiConfig: state.getApiConfig('chat'),
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
                      return _bubble(state, m, isUser);
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
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
              child: Row(
                children: [
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

  Widget _bubble(AppState state, ChatMessage m, bool isUser) {
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
        child: Stack(
          children: [
            // v833：单条复制——按钮占右侧
            Padding(
              padding: const EdgeInsets.only(right: 22),
              child: SelectableText(m.content,
                  style: const TextStyle(fontSize: 14.5, height: 1.5)),
            ),
            Positioned(
              right: 0,
              top: 0,
              child: GestureDetector(
                onTap: () {
                  Clipboard.setData(ClipboardData(text: m.content));
                  ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('已复制'), duration: Duration(seconds: 1)));
                },
                child: const Icon(Icons.copy, size: 15, color: Color(0xFF9B8F7A)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
