import 'dart:convert';
import 'package:share_plus/share_plus.dart';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:scroll_to_index/scroll_to_index.dart'; // v861：楼层跳转
import 'package:provider/provider.dart';
import '../models/chat_session.dart';
import '../services/api_service.dart';
import '../services/chat_agent.dart';
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
  // v861：AutoScrollController=标准ScrollController子类（jumpTo(max)用法不变），
  // 额外支持scrollToIndex按楼层定位；不像v842的ScrollablePositionedList替换滚动组件（死机教训）
  final AutoScrollController _listCtl = AutoScrollController();
  final TextEditingController _inputCtl = TextEditingController();
  final FocusNode _inputFocus = FocusNode();
  bool _sending = false;
  bool _didOpenJump = false; // v860：打开跳末尾标记
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

  // v866：楼层跳转——当前楼层按滚动比例实时估算（手动滚动后仍准确，
  // 修复此前_curFloor与实际视口错位导致按键要按两次）
  // v941：比例估算法在楼层高度不均时严重错位（用户实测v939：↓按两次
  // 不动/有时往上动/⏬要按两次）——根因=pixels/max×(n-1)假设等高楼层。
  // 修：①跳转后锚定_curFloor，连按从此逐层走（不再依赖失真估算）
  // ②用户手动拖动→NotificationListener清锚回估算 ③向下保底+1（估
  // 算卡住时不再"不动"）
  int? _curFloorAnchor; // v941：上次跳转目标楼层（null=无锚，用估算）
  Future<void> _jumpFloor(int delta) async {
    final n = state_msgCount;
    if (n == 0 || !_listCtl.hasClients) return;
    final pos = _listCtl.position;
    if (pos.maxScrollExtent <= 0) return;
    final curEst =
        ((pos.pixels / pos.maxScrollExtent) * (n - 1)).round().clamp(0, n - 1);
    // v941：有锚优先用锚（跳转序列内逐层准确）；无锚才用比例估算
    final cur = _curFloorAnchor != null
        ? _curFloorAnchor!.clamp(0, n - 1)
        : curEst;
    var target = cur + delta;
    // v941：向下卡住保底+1（估算偏小连按不动的兜底）；锚定模式天然+1不受影响
    if (target == curEst &&
        target == cur &&
        delta > 0 &&
        _curFloorAnchor == null &&
        cur < n - 1) {
      target = cur + 1;
    }
    target = target.clamp(0, n - 1);
    if (target == cur) return;
    await _listCtl.scrollToIndex(target,
        preferPosition: AutoScrollPosition.begin,
        duration: const Duration(milliseconds: 180));
    _curFloorAnchor = target;
  }

  int get state_msgCount =>
      context.read<AppState>().chatActive?.messages.length ?? 0;

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

  /// v861：半透明圆形楼层导航键；v862：加大尺寸+间隔，位置左移
  Widget _navBtn(String label, VoidCallback? onTap) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: 44,
          height: 44,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: const Color(0x99C89137),
            borderRadius: BorderRadius.circular(22),
          ),
          child: Text(label,
              style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: Colors.white)),
        ),
      ),
    );
  }

  // ===== v861：会话导入/导出 =====

  void _exportImportMenu(AppState state) {
    showModalBottomSheet(
      context: context,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.ios_share),
              title: const Text('导出当前会话（txt，可分享）'),
              onTap: () {
                Navigator.pop(context);
                _exportSession(state);
              },
            ),
            ListTile(
              leading: const Icon(Icons.download_outlined),
              title: const Text('导入会话（从txt文件）'),
              onTap: () {
                Navigator.pop(context);
                _importSession(state);
              },
            ),
          ],
        ),
      ),
    );
  }

  /// 导出格式：--- 用户 --- / --- AI --- 分段（导入可回解析）
  Future<void> _exportSession(AppState state) async {
    final sess = state.chatActive;
    if (sess == null || sess.messages.isEmpty) {
      _toast('当前会话为空');
      return;
    }
    final sb = StringBuffer();
    sb.writeln('【会话】' + sess.title);
    sb.writeln('【导出】' + DateTime.now().toString().substring(0, 19));
    for (final m in sess.messages) {
      sb.writeln('--- ' + (m.role == 'user' ? '用户' : 'AI') + ' ---');
      sb.writeln(m.content);
    }
    final fname =
        'chat_' + sess.title.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_') + '.txt';
    final path = state.storage.getBackupPath(fname);
    File(path).writeAsStringSync(sb.toString());
    _log('[聊天] 已导出：' + path);
    await Share.shareXFiles([XFile(path)], text: sess.title);
  }

  Future<void> _importSession(AppState state) async {
    final files = await FilePicker.pickFiles(type: FileType.any);
    if (files.isEmpty) return;
    final f = files.first;
    String content;
    try {
      content = await File.fromUri(f.uri).readAsString();
    } catch (e) {
      _toast('读取失败：' + e.toString());
      return;
    }
    // 解析 --- 用户 --- / --- AI --- 分段；无分隔符则整段作为第一条用户消息
    final msgs = <ChatMessage>[];
    final re = RegExp(r'^--- (用户|AI) ---\s*$', multiLine: true);
    final matches = re.allMatches(content).toList();
    if (matches.isEmpty) {
      msgs.add(ChatMessage(
          role: 'user',
          content: content.trim(),
          ts: DateTime.now().millisecondsSinceEpoch));
    } else {
      for (var i = 0; i < matches.length; i++) {
        final start = matches[i].end;
        final end =
            i + 1 < matches.length ? matches[i + 1].start : content.length;
        final body = content.substring(start, end).trim();
        if (body.isEmpty) continue;
        msgs.add(ChatMessage(
          role: matches[i].group(1) == '用户' ? 'user' : 'assistant',
          content: body,
          ts: DateTime.now().millisecondsSinceEpoch,
        ));
      }
    }
    if (msgs.isEmpty) {
      _toast('未解析到消息');
      return;
    }
    state.newChatSession();
    final sess = state.chatActive!;
    sess.title = f.name.replaceFirst(RegExp(r'\.txt$'), '');
    sess.messages.addAll(msgs);
    state.saveChatSessions();
    if (mounted) setState(() => _didOpenJump = false);
    _log('[聊天] 导入完成：' + msgs.length.toString() + '条消息');
  }

  void _log(String msg) => AppState.instance.apiLog(msg);

  void _toast(String msg) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg), duration: const Duration(seconds: 2)));
  }

  /// v836：历史文本构造（含upto索引，inclusive）——v840：tool消息入历史
  String _histText(List<ChatMessage> msgs, int upto) {
    final hist = StringBuffer();
    for (var i = 0; i <= upto && i < msgs.length; i++) {
      final m = msgs[i];
      if (m.role == 'tool') {
        hist.writeln('【工具结果】${m.content}');
      } else {
        hist.writeln('${m.role == 'user' ? "用户" : "AI"}：${m.content}');
      }
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
  /// v840：agent循环——AI输出工具指令→执行（写类确认）→结果回喂→继续，最多4轮
  Future<void> _generate(AppState state, String text, String hist,
      {List<ChatAttachment> atts = const []}) async {
    final sess = state.chatActive;
    if (sess == null || _sending) return;

    final sys = '你是网文创作搭子，与作者自由聊天：可以讨论剧情/人物/设定/写作技巧，'
        '也可以闲聊；同时你是本APP「网文拆解器」的功能助手，作者问APP功能/选项/流程时按下助手手册解答，'
        '手册没写的不要编。回答直接自然，不需要客套。当前书目：${state.currentBook}'
        '${state.chapters.isNotEmpty ? '（共${state.chapters.length}章）' : ''}。\n\n'
        '${PromptBuilderHelp.appHelpDoc}\n\n$agentToolDoc';

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
    var usr = hist.isEmpty
        ? textAll
        : '【聊天历史】\n${hist}【本轮用户消息】\n$textAll';

    setState(() => _sending = true);
    _jumpBottom();
    try {
      // v840：agent循环
      for (var round = 0; round < 4; round++) {
        // 追加assistant占位
        setState(() {
          state.chatActive?.messages.add(ChatMessage(
            role: 'assistant',
            content: '…',
            ts: DateTime.now().millisecondsSinceEpoch,
          ));
        });
        state.saveChatSessions();
        _jumpBottom();
        final replyIdx = state.chatActive!.messages.length - 1;
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
        if (!mounted) return;
        final reply = state.chatActive?.messages[replyIdx].content ?? '';
        // 工具指令检测
        final call = parseToolCall(reply);
        if (call == null) break; // 普通回复——结束
        if (round >= 3) {
          setState(() {
            state.chatActive?.messages.add(ChatMessage(
              role: 'tool',
              content: '⚙ 连续工具轮次达上限——请用户继续下达指令',
              ts: DateTime.now().millisecondsSinceEpoch,
            ));
          });
          state.saveChatSessions();
          break;
        }
        // 写类工具确认
        var result = AgentToolResult(call.tool, false, '用户拒绝执行');
        final needConfirm = _writeTools.contains(call.tool);
        if (!needConfirm ||
            await _confirmTool(state, call.tool, call.args)) {
          result = await runTool(state, call.tool, call.args);
        }
        if (!mounted) return;
        setState(() {
          state.chatActive?.messages.add(ChatMessage(
            role: 'tool',
            content:
                '⚙ ${call.tool}（${result.ok ? "成功" : "失败"}）：${result.message}',
            ts: DateTime.now().millisecondsSinceEpoch,
          ));
        });
        state.saveChatSessions();
        _jumpBottom();
        final msgs = state.chatActive!.messages;
        usr =
            '【聊天历史】\n${_histText(msgs, msgs.length - 1)}\n【本轮用户消息】\n（上一条为工具执行结果，请基于结果继续：完成汇报或发出下一条工具指令）';
      }
    } finally {
      if (mounted) setState(() => _sending = false);
      _inputFocus.requestFocus();
    }
  }

  // v840：写类工具（需确认）
  static const _writeTools = {'switch_book', 'start_batch_shots'};

  Future<bool> _confirmTool(
      AppState state, String tool, Map<String, dynamic> args) async {
    final desc = tool == 'switch_book'
        ? '切换当前书目到「${args['name'] ?? '?'}」'
        : tool == 'start_batch_shots'
            ? '启动批量拆分镜（长任务，当前书全部已划分未拆场景）'
            : '$tool ${args.toString()}';
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('AI请求执行操作'),
        content: Text(desc, style: const TextStyle(fontSize: 15)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('拒绝')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('允许')),
        ],
      ),
    );
    return ok == true;
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
                onChanged: (id) {
                  // v860：切会话重新定位末尾
                  _didOpenJump = false;
                  setState(() => state.chatActiveId = id ?? '');
                },
                hint: const Text('暂无会话', style: TextStyle(fontSize: 14)),
              ),
            ),
          ),
        ]),
        actions: [
          MiniButton(label: '⇅', onTap: () => _exportImportMenu(state)),
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
            // v861：Stack包列表+右侧楼层快捷键（只锚bottom——v847教训：禁top+bottom双约束）
            child: Stack(
              children: [
                if (sess == null || sess.messages.isEmpty)
                  const Center(
                    child: Text('输入第一条消息开始聊天',
                        style: TextStyle(color: Color(0xFF9B8F7A))),
                  )
                else
                  // v941：用户手动拖动清楼层锚（回估算模式——锚只在连按跳转序列内有效）
                  NotificationListener<ScrollNotification>(
                    onNotification: (notif) {
                      // 用户手指拖动（dragDetails非空）→清锚回估算模式
                      if (notif is ScrollUpdateNotification &&
                          notif.dragDetails != null) {
                        _curFloorAnchor = null;
                      }
                      return false;
                    },
                    child: ListView.builder(
                    controller: _listCtl,
                    padding: const EdgeInsets.fromLTRB(10, 10, 10, 6),
                    itemCount: sess.messages.length,
                    itemBuilder: (ctx, i) {
                      final m = sess.messages[i];
                      // v860：打开/切回聊天页定位到末尾（一次性；v845方案普通列表安全）
                      if (!_didOpenJump && i == sess.messages.length - 1) {
                        _didOpenJump = true;
                        WidgetsBinding.instance.addPostFrameCallback((_) {
                          if (_listCtl.hasClients) {
                            _listCtl.jumpTo(_listCtl.position.maxScrollExtent);
                          }
                        });
                      }
                      // v861：统一包楼层号+AutoScrollTag
                      Widget body;
                      if (m.role == 'tool') {
                        // v840：工具执行结果窄条
                        body = Align(
                          alignment: Alignment.center,
                          child: Container(
                            margin: const EdgeInsets.symmetric(vertical: 3),
                            padding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 5),
                            constraints: BoxConstraints(
                                maxWidth:
                                    MediaQuery.of(context).size.width * 0.9),
                            decoration: BoxDecoration(
                              color: const Color(0xFFEFE9DB),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: SelectableText(
                              m.content,
                              style: const TextStyle(
                                  fontSize: 12.5,
                                  height: 1.45,
                                  color: Color(0xFF6B5230)),
                            ),
                          ),
                        );
                      } else {
                        final isUser = m.role == 'user';
                        body = _bubble(state, m, isUser, i);
                      }
                      return AutoScrollTag(
                        key: ValueKey('floor_$i'),
                        controller: _listCtl,
                        index: i,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Padding(
                              padding: const EdgeInsets.only(bottom: 1),
                              child: Row(mainAxisSize: MainAxisSize.min, children: [
                                Text('#${i + 1}',
                                    style: const TextStyle(
                                        fontSize: 10,
                                        color: Color(0xFFB8AF9F))),
                                const SizedBox(width: 6),
                                // v861：单条删除——整理聊天记录用
                                GestureDetector(
                                  onTap: () async {
                                    final okDel = await showDialog<bool>(
                                        context: context,
                                        builder: (d) => AlertDialog(
                                            title: const Text('删除这条消息'),
                                            content: Text('删除第${i + 1}楼（不影响其他楼层）'),
                                            actions: [
                                              TextButton(
                                                  onPressed: () =>
                                                      Navigator.pop(d, false),
                                                  child: const Text('取消')),
                                              FilledButton(
                                                  onPressed: () =>
                                                      Navigator.pop(d, true),
                                                  child: const Text('删除')),
                                            ]));
                                    if (okDel != true || !mounted) return;
                                    setState(() {
                                      state.chatActive!.messages.removeAt(i);
                                    });
                                    state.saveChatSessions();
                                  },
                                  child: const Icon(Icons.close,
                                      size: 12, color: Color(0xFFB8AF9F)),
                                ),
                              ]),
                            ),
                            body,
                          ],
                        ),
                      );
                    },
                  ),
                ),
                // v861：右侧竖排半透明楼层快捷键
                if (sess != null && sess.messages.isNotEmpty)
                  Positioned(
                    right: 14,
                    bottom: 90,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _navBtn('⏫', () {
                          if (_listCtl.hasClients) _listCtl.jumpTo(0);
                        }),
                        _navBtn('↑', () => _jumpFloor(-1)),
                        _navBtn('↓', () => _jumpFloor(1)),
                        _navBtn('⏬', () {
                          // v866：直达底部+下一帧补跳一次（列表刚变化时maxExtent可能未刷新）
                          // v941：补跳改延时300ms——异步布局（图片/富文本）未完成时
                          // maxExtent仍偏小，一帧补跳不够（用户实测要按两次）
                          if (!_listCtl.hasClients) return;
                          _listCtl.jumpTo(_listCtl.position.maxScrollExtent);
                          Future.delayed(const Duration(milliseconds: 300), () {
                            if (_listCtl.hasClients) {
                              _listCtl.jumpTo(
                                  _listCtl.position.maxScrollExtent);
                            }
                          });
                        }),
                      ],
                    ),
                  ),
              ],
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
          // v863：气泡下操作行——复制（全部消息）+重新回答（AI消息）
          if (!_sending && m.content != '…')
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Wrap(
                spacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  MiniButton(
                    label: '📋 复制',
                    onTap: () {
                      Clipboard.setData(
                          ClipboardData(text: _copyPlain(m.content)));
                      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                          content: Text('已复制（纯文本）'),
                          duration: Duration(seconds: 1)));
                    },
                  ),
                  // v864：转发——调系统分享面板（微信/QQ等已安装应用）
                  MiniButton(
                    label: '↗ 转发',
                    onTap: () {
                      final plain = _copyPlain(m.content);
                      final title = '【${m.role == 'user' ? '我' : 'AI'}】';
                      if (m.attachments.isNotEmpty) {
                        // 带附件：把图片/文件一并分享（文本+首图）
                        final img = m.attachments
                            .where((a) => a.isImage)
                            .toList();
                        if (img.isNotEmpty) {
                          final tmp = File(
                              '${Directory.systemTemp.path}/chat_share_${DateTime.now().millisecondsSinceEpoch}.png');
                          tmp.writeAsBytesSync(base64Decode(img.first.data));
                          Share.shareXFiles([XFile(tmp.path)],
                              text: '$title\n$plain');
                          return;
                        }
                      }
                      Share.share('$title\n$plain');
                    },
                  ),
                  if (!isUser && idx > 0)
                    MiniButton(
                      label: '↻ 重新回答',
                      onTap: () => _regen(state, idx),
                    ),
                ],
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
                          // v860：v846防御补回——坏图片数据显示占位，防启动build反复崩
                          errorBuilder: (_, __, ___) => const SizedBox(
                              height: 40,
                              child: Center(
                                  child: Text('🖼 图片数据损坏',
                                      style: TextStyle(fontSize: 12)))),
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
                      // v841：复制净化文本——JSON转可读文本/markdown去符号，换行保留
                      Clipboard.setData(
                          ClipboardData(text: _copyPlain(m.content)));
                      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                          content: Text('已复制（纯文本）'),
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

  /// v841：复制净化——JSON转"key：值"可读文本（换行保留），markdown去符号
  String _copyPlain(String content) {
    var trimmed = content.trim();
    final isJson = (trimmed.startsWith('{') && trimmed.endsWith('}')) ||
        (trimmed.startsWith('[') && trimmed.endsWith(']'));
    if (isJson) {
      try {
        return _flatJson(jsonDecode(trimmed), '');
      } catch (_) {}
    }
    // markdown去符号（保留换行）
    final out = StringBuffer();
    var inCode = false;
    for (final line in trimmed.split('\n')) {
      final t = line.trimLeft();
      if (t.startsWith('```')) {
        inCode = !inCode;
        continue; // 围栏行去掉
      }
      if (inCode) {
        out.writeln(line);
        continue;
      }
      var l = t;
      l = l.replaceFirst(RegExp(r'^#{1,4}\s+'), ''); // 标题#
      l = l.replaceFirst(RegExp(r'^([-*]|\d+[.)])\s+'), '· '); // 列表符→·
      l = l.replaceAll('**', ''); // 粗体
      l = l.replaceAll('`', ''); // 行内code
      out.writeln(l);
    }
    return out.toString().trimRight();
  }

  /// JSON→纯文本递归（key：value行/数组逐项换行，字符串原样保换行）
  String _flatJson(dynamic node, String key) {
    final label = key.isEmpty ? '' : '${_zhKey(key)}：';
    if (node is Map) {
      return node.entries
          .map((e) => _flatJson(e.value, e.key.toString()))
          .where((s) => s.isNotEmpty)
          .join('\n');
    }
    if (node is List) {
      return node.map((e) => _flatJson(e, '')).where((s) => s.isNotEmpty).join('\n\n');
    }
    final s = node.toString();
    if (s.contains('\n')) return s; // 长文本原样（自带换行）
    return '$label$s';
  }

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
