import 'dart:convert';
import 'package:share_plus/share_plus.dart';
import 'dart:io';
import 'dart:ui' as ui;
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:scroll_to_index/scroll_to_index.dart'; // v861：楼层跳转
import '../widgets/content_font.dart'; // v979：聊天页字号持久化
import 'package:provider/provider.dart';
import '../models/chat_session.dart';
import '../services/api_service.dart';
import '../services/chat_agent.dart';
import '../utils/prompt_builder.dart';
import '../state/app_state.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:http/http.dart' as http; // v1342：硅基Kolors生成调用
import 'package:path_provider/path_provider.dart'; // v1343：磁盘缓存目录
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
    // v1414b：进聊天页=新会话起点（AppState页面级），切引擎组件重建不重置
    AppState.instance.chatPageOpenedAt =
        DateTime.now().millisecondsSinceEpoch;
    ContentFont.load('chat').then((v) {
      if (mounted) setState(() => _chatFontScale = v);
    });
    // 终端日志桥接（v824任务级反馈也进全局终端）
    _chatApi.onLog = (msg) =>
        context.read<AppState>().apiLog('[聊天] $msg');
  }

  @override
  void dispose() {
    _navVisible.dispose();
    _navHideTimer?.cancel();
    _listCtl.dispose();
    _inputCtl.dispose();
    _inputFocus.dispose();
    super.dispose();
  }

  // v979：聊天页字号（ContentFont持久化，key='chat'）
  double _chatFontScale = 1.0;

  // v967：快捷键滚动可见性——滚动/操作时出现，静止2秒后隐藏
  // v970：改ValueNotifier+常驻树透明度切换——原setState整页rebuild会
  // 打断惯性滚动+闪烁（浏览位置乱跑），现在完全不触碰列表
  final ValueNotifier<bool> _navVisible = ValueNotifier(false);
  Timer? _navHideTimer;

  void _bumpNav() {
    if (!mounted) return;
    _navVisible.value = true;
    _navHideTimer?.cancel();
    _navHideTimer = Timer(const Duration(seconds: 2), () {
      _navVisible.value = false;
    });
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
            color: const Color(0x26C89137), // v967：更透更浅（原0x99）
            borderRadius: BorderRadius.circular(22),
          ),
          child: Text(label,
              style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: const Color(0x99806A2E))), // v967：浅棕字（原纯白）
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

  /// v989：重答——把当前这条AI回复删掉，重新生成新回答（对齐用户对"重新回答"的直觉）
  Future<void> _redit(AppState state, int aiIdx) async {
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
    // 删除本条AI回复（含可能的历史=userIdx+1..aiIdx），再重新生成
    sess.messages.removeRange(userIdx + 1, aiIdx + 1);
    state.saveChatSessions();
    setState(() {});
    final hist = _histText(sess.messages, userIdx);
    await _generate(state, text, hist);
  }

  /// v836/v989：再答——把该条AI回复对应的提问重新发送，新答案追加不覆盖旧答案
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

    // v953：聚焦作家——选中后注入该档案全文+完善训练令（聊天即训练场）
    final focusStyle = state.selectedWriterStyle.isEmpty
        ? ''
        : '\n\n${state.writerStyleBlock}'
            '【当前任务：完善作家「${state.selectedWriterStyle}」的风格档案】'
            '讨论写作技巧时结合该档案已有的条目展开；发现值得沉淀的新心得'
            '（用户认可的写法/有效的trick用法）主动建议"要不要记进档案"；'
            '用户要求记录/修订时，先get_styles读旧档，再update_style提交合并版。\n';

    final sys = '你是网文创作搭子，与作者自由聊天：可以讨论剧情/人物/设定/写作技巧，'
        '也可以闲聊；同时你是本APP「网文拆解器」的功能助手，作者问APP功能/选项/流程时按下助手手册解答，'
        '手册没写的不要编。回答直接自然，不需要客套。当前书目：${state.currentBook}'
        '${state.chapters.isNotEmpty ? '（共${state.chapters.length}章）' : ''}。\n\n'
        '${PromptBuilderHelp.appHelpDoc}\n\n$agentToolDoc$focusStyle';

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
    // v1338：插图生成指令（pollinations野生API，酒馆4.25预设迁移）
    if (state.chatImageGen) {
      usr = '【插图生成】在回复的合适位置插入0-2张插图标签（按剧情需要，无合适画面可不插），标签独立成段：\n'
          '<img src="https://image.pollinations.ai/prompt/{URL编码的英文场景prompt}?width={宽}&height={高}" alt="场景简述"/>\n'
          'prompt规则：固定前缀 best quality, masterpiece, 然后是画面主体/人物外观/服装/动作/镜头角度/氛围光线的英文关键词，逗号分隔，基于当前剧情场景生成。prompt末尾固定加 no text, no letters, no watermark（AI画不了汉字，文字由APP后期叠加）。\n'
          '比例自选：人物/特写用 width=640&height=960（竖版），风景/大场面用 width=960&height=640（横版），其他默认 width=768&height=768。用户要画小说封面时：竖版640x960，构图留出上方1/3空白供后期叠加书名，prompt加 book cover composition。\n\n'
          + usr;
    }

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

  /// v1011：会话切换弹层——全宽列会话标题（完整可读），点选切换
  void _showSessionPicker(AppState state) {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const Padding(
              padding: EdgeInsets.all(12),
              child: Text('切换会话',
                  style: TextStyle(
                      fontWeight: FontWeight.w700, fontSize: 14)),
            ),
            if (state.chatSessions.isEmpty)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text('暂无会话',
                    style: TextStyle(fontSize: 13, color: Colors.grey)),
              ),
            for (final s0 in state.chatSessions)
              ListTile(
                dense: true,
                title: Text(s0.title, style: const TextStyle(fontSize: 13.5)),
                trailing: s0.id == state.chatActiveId
                    ? const Icon(Icons.check, size: 18)
                    : null,
                onTap: () {
                  _didOpenJump = false;
                  setState(() => state.chatActiveId = s0.id);
                  Navigator.pop(ctx);
                },
              ),
            // v1012：当前会话操作行——改名/删除收进弹层（用户裁决：外面按键栏单行放完不溢出）
            if (state.chatActive != null)
              Builder(builder: (ctx2) {
                final cur = state.chatActive!;
                return Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 10),
                child: Wrap(
                  spacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    MiniButton(
                      label: '✏ 改名',
                      onTap: () {
                        Navigator.pop(ctx);
                        _renameSession(state, cur);
                      },
                    ),
                    MiniButton(
                      label: '🗑 删除',
                      danger: true,
                      onTap: () async {
                        Navigator.pop(ctx);
                        final ok = await showDialog<bool>(
                          context: context,
                          builder: (_) => AlertDialog(
                            title: const Text('删除会话'),
                            content: Text(
                                '删除「${cur.title}」？聊天记录不可恢复。'),
                            actions: [
                              TextButton(
                                  onPressed: () =>
                                      Navigator.pop(context, false),
                                  child: const Text('取消')),
                              TextButton(
                                  onPressed: () =>
                                      Navigator.pop(context, true),
                                  child: const Text('删除')),
                            ],
                          ),
                        );
                        if (ok == true) {
                          state.deleteChatSession(cur.id);
                          setState(() {});
                        }
                      },
                    ),
                  ],
                ),
              );
              }),
          ],
        ),
      ),
    );
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
        titleSpacing: 0,
        toolbarHeight: 76, // v1358：两行收紧
        // v1011：会话标题不占工具栏（用户裁决：标题挤瘪右侧按键）——
        // 会话切换收进首个'会话▾'键，点开底部弹层看全标题
        title: const SizedBox.shrink(),
        // v1010：动作键横向滚动区（占屏55%且reverse=右缘对齐）——会话下拉
        // 恢复可见宽度（此前动作键过宽把标题挤成一条缝，用户截图实锤）
        actions: [
          SizedBox(
            width: MediaQuery.of(context).size.width - 16,
            child: Wrap(
              alignment: WrapAlignment.start, // v1358：靠左排（用户裁决）
              runSpacing: 2,
              spacing: 4, // v1013：按键间距（此前紧贴）
              children: [
          // v1011：会话切换键（替代原Expanded下拉，点开弹层看全标题）
          MiniButton(
            label: '会话 ▾',
            primary: sess != null,
            onTap: () => _showSessionPicker(state),
          ),
          ContentFontButtons(
            pageKey: 'chat',
            scale: _chatFontScale,
            onChanged: (v) {
              setState(() => _chatFontScale = v);
              ContentFont.save('chat', v);
            },
          ),
          writerStyleButton(context, state), // v953：聚焦作家（聊天即训练场）
          MiniButton(label: '导出/导入', onTap: () => _exportImportMenu(state)),
          MiniButton(
              label: '新建',
              onTap: () {
                state.newChatSession();
                setState(() {});
              }),
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
          // v1358：插图三键原子组（同转行不拆散，粘一起用户裁决）
          SizedBox(
            child: Row(mainAxisSize: MainAxisSize.min, spacing: 4, children: [
          MiniButton(
            label: state.chatImageGen ? '插图开' : '插图关',
            onTap: () {
              state.setChatImageGen(!state.chatImageGen);
              setState(() {});
            },
          ),
          MiniButton(
            label: state.chatImageEngine == 'silicon'
                ? '硅基'
                : state.chatImageEngine == 'cf'
                    ? 'CF'
                    : state.chatImageEngine == 'mj'
                        ? 'MJ公'
                        : state.chatImageEngine == 'mjpro'
                            ? 'MJ企'
                            : '野生',
            enabled: state.chatImageGen,
            onTap: state.chatImageGen
                ? () {
                    final order = ['silicon', 'cf', 'mj', 'mjpro', 'pollination'];
                    final idx = order.indexOf(state.chatImageEngine);
                    final next = order[(idx + 1) % order.length];
                    state.setChatImageEngine(next);
                    setState(() {});
                  }
                : null,
          ),
          MiniButton(
            label: (state.chatImageEngine == 'silicon'
                    ? state.chatSiliconKey
                    : state.chatImageEngine == 'mjpro'
                        ? state.chatMjProKey
                        : state.chatCfKey)
                .isEmpty
                ? '🔑填Key'
                : '🔑已配',
            enabled: state.chatImageGen && state.chatImageEngine != 'pollination',
            onTap: state.chatImageGen && state.chatImageEngine != 'pollination'
                ? () => _editImageKeys(state)
                : null,
          ),
            ]),
          ),
                ],
              ),
            ),
              ],
            ),
      body: Column(
        children: [
          Expanded(
            // v979：聊天消息区字号缩放（ContentFont持久化key='chat'）
            child: ContentFont.area(
              context,
              scale: _chatFontScale,
              child: Builder(builder: (ctx) => Stack(
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
                      // v967：有滚动动作→快捷键现身，静止2秒后隐藏
                      if (notif is ScrollUpdateNotification ||
                          notif is UserScrollNotification ||
                          notif is OverscrollNotification) {
                        _bumpNav();
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
                // v861：右侧竖排半透明楼层快捷键（v967滚动现身/v970常驻树只切透明度——
                // 移除/插入节点会闪+挤列表，现在零布局变化不乱跑）
                if (sess != null && sess.messages.isNotEmpty)
                  Positioned(
                    right: 14,
                    bottom: 90,
                    child: ValueListenableBuilder<bool>(
                      valueListenable: _navVisible,
                      builder: (_, navVisible, __) => IgnorePointer(
                        ignoring: !navVisible,
                        child: AnimatedOpacity(
                          opacity: navVisible ? 1 : 0,
                          duration: const Duration(milliseconds: 150),
                          child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _navBtn('⏫', () {
                          _bumpNav();
                          if (_listCtl.hasClients) _listCtl.jumpTo(0);
                        }),
                        _navBtn('↑', () {
                          _bumpNav();
                          _jumpFloor(-1);
                        }),
                        _navBtn('↓', () {
                          _bumpNav();
                          _jumpFloor(1);
                        }),
                        _navBtn('⏬', () {
                          _bumpNav();
                          // v942：模拟手指拖到底——animateTo(max)后复查高度，
                          // 异步布局追加了新高度就再跟一轮，直到稳定（jumpTo
                          // 一次性设值会错过异步追加的高度，v941延时法只是
                          // 打补丁，这个是正路：手指拖动就是持续跟最新的）
                          Future<void> chase(int round) async {
                            if (!_listCtl.hasClients || round > 5) return;
                            final target = _listCtl.position.maxScrollExtent;
                            await _listCtl.animateTo(target,
                                duration: const Duration(milliseconds: 200),
                                curve: Curves.easeOut);
                            if (!_listCtl.hasClients) return;
                            final now = _listCtl.position.maxScrollExtent;
                            if ((now - target).abs() > 1) {
                              await chase(round + 1);
                            } else {
                              _listCtl.jumpTo(now);
                            }
                          }

                          chase(0);
                        }),
                      ],
                    ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
            ),
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
                    compact: true,
                    label: '复制',
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
                    compact: true,
                    label: '转发',
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
                  if (!isUser && idx > 0) ...[
                    MiniButton(
                      compact: true,
                      label: '重答',
                      onTap: () => _redit(state, idx),
                    ),
                    MiniButton(
                      compact: true,
                      label: '再答',
                      onTap: () => _regen(state, idx),
                    ),
                  ],
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
                  child: _richContent(state, m.content,
                      msgCreatedAt: m.ts),
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
  Widget _richContent(AppState state, String content, {int? msgCreatedAt}) {
    final useSilicon =
        state.chatImageGen && state.chatImageEngine == 'silicon';
    final skey = state.chatSiliconKey;
    final bookName = state.currentBook; // v1344：自动叠封面书名
    // v1009：LaTeX箭头宏转符号——AI偶发输出$\rightarrow$等未渲染的宏，显示成源码
    content = content
        .replaceAll(r'$\rightarrow$', '→')
        .replaceAll(r'\rightarrow', '→')
        .replaceAll(r'$\to$', '→')
        .replaceAll(r'\to', '→')
        .replaceAll(r'$\Rightarrow$', '⇒')
        .replaceAll(r'\Rightarrow', '⇒')
        .replaceAll(r'$\leftarrow$', '←')
        .replaceAll(r'\leftarrow', '←');
    // v1338：img插图标签→网络图渲染（pollinations野生API迁移）
    // v1339：整标签匹配——消费src/alt等全部属性到闭合>，防alt残文本漏出
    // v1379：AI输出长prompt时img标签内常插换行→正则[^"\\s>]遇换行断=标签原文本显示不画图——先压缩<img>段内换行
    var normContent = content.replaceAllMapped(
        RegExp('<img[\\s\\S]*?>', caseSensitive: false),
        (m) => m.group(0)!.replaceAll(RegExp(r'[\n\r]'), ' '));
    final imgRe = RegExp(
        '<img\\s[^>]*src\\s*=\\s*"?(https?://[^"\\s>]+)[^>]*>',
        caseSensitive: false);
    // v1390：AI偶发输出未闭合标签（缺末尾>）——补闭合再试，未闭合不再整条漏掉
    if (!imgRe.hasMatch(normContent) &&
        RegExp('<img\\s', caseSensitive: false).hasMatch(normContent) &&
        !normContent.trimRight().endsWith('>')) {
      normContent = '${normContent.trimRight()}>';
    }
    // v1391：img解析失败诊断——flash流式偶发原文本显示，真实content形状进日志定位
    if (RegExp('<img\\s', caseSensitive: false).hasMatch(normContent) &&
        !imgRe.hasMatch(normContent)) {
      final tail = normContent.length > 80
          ? normContent.substring(normContent.length - 80)
          : normContent;
      AppState.instance.apiLog(
          'img解析失败 len=${normContent.length} 含闭合>=${normContent.contains('>')} 尾=[$tail]');
    }
    if (imgRe.hasMatch(normContent)) {
      final parts = <Widget>[];
      var cursor = 0;
      for (final m in imgRe.allMatches(normContent)) {
        if (m.start > cursor) {
          final txt = normContent.substring(cursor, m.start).trim();
          if (txt.isNotEmpty) {
            parts.add(SelectableText.rich(
              TextSpan(children: _mdSpans(txt)),
              style: const TextStyle(fontSize: 14.5, height: 1.5),
            ));
          }
        }
        parts.add(state.chatImageEngine == 'pollination'
            ? _chatImage(context, m.group(1)!)
            : _SiliconImage(
                src: m.group(1)!,
                engine: state.chatImageEngine,
                skey: skey,
                cfKey: state.chatCfKey,
                cfAccount: state.chatCfAccount,
                bookName: bookName,
                mjBase: state.chatMjBase,
                mjProKey: state.chatMjProKey,
                floorCreatedAt: msgCreatedAt));
        cursor = m.end;
      }
      if (cursor < normContent.length) {
        final tail = content.substring(cursor).trim();
        if (tail.isNotEmpty) {
          parts.add(SelectableText.rich(
            TextSpan(children: _mdSpans(tail)),
            style: const TextStyle(fontSize: 14.5, height: 1.5),
          ));
        }
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < parts.length; i++) ...[
            parts[i],
            if (i < parts.length - 1) const SizedBox(height: 6),
          ]
        ],
      );
    }
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

  /// v1342：硅基流动key编辑
  /// v1351：画图Key编辑（硅基/CF双引擎三字段）
  void _editImageKeys(AppState state) {
    final siliconCtl = TextEditingController(text: state.chatSiliconKey);
    final mjCtl = TextEditingController(text: state.chatMjBase);
    final mjProCtl = TextEditingController(text: state.chatMjProKey);
    final cfKeyCtl = TextEditingController(text: state.chatCfKey);
    final cfAccCtl = TextEditingController(text: state.chatCfAccount);
    showDialog(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('画图引擎 Key'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: siliconCtl,
              decoration: const InputDecoration(labelText: '硅基流动 Key（sk-开头）',
                  border: OutlineInputBorder())),
          const SizedBox(height: 12),
          TextField(controller: cfKeyCtl,
              decoration: const InputDecoration(labelText: 'Cloudflare Token（cfut-开头）',
                  border: OutlineInputBorder())),
          const SizedBox(height: 12),
          TextField(controller: cfAccCtl,
              decoration: const InputDecoration(labelText: 'CF 账户ID（32位）',
                  border: OutlineInputBorder())),
          TextField(controller: mjCtl,
              decoration: const InputDecoration(labelText: 'MJ公益接口地址（免key，默认ai.trueai.org）',
                  border: OutlineInputBorder())),
          TextField(controller: mjProCtl,
              decoration: const InputDecoration(labelText: '环网key（MJ企付费引擎）',
                  border: OutlineInputBorder())),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d), child: const Text('取消')),
          FilledButton(
            onPressed: () {
              state.setChatSiliconKey(siliconCtl.text);
              state.setChatCf(cfKeyCtl.text, cfAccCtl.text);
              state.setChatMjBase(mjCtl.text);
              state.setChatMjProKey(mjProCtl.text);
              Navigator.pop(d);
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
  }

  /// v1342：硅基Kolors画图组件——从pollinations标签提取prompt异步生成
  /// （缓存内存Map，URL临时过期所以存bytes）
}

class _SiliconImage extends StatefulWidget {
  final String src;
  final String engine; // v1348：'silicon'|'cf'；v1383：'mj'
  final String skey;
  final String cfKey;
  final String cfAccount;
  final String bookName; // v1344：自动叠封面书名
  final String mjBase; // v1383：MJ公益接口地址
  final String mjProKey; // v1385：MJ企（环网关）key
  final int? floorCreatedAt; // v1388：楼层消息时间——切引擎前的历史楼层不自动生成
  const _SiliconImage(
      {required this.src,
      required this.engine,
      required this.skey,
      this.cfKey = '',
      this.cfAccount = '',
      this.bookName = '',
      this.mjBase = 'https://ai.trueai.org',
      this.mjProKey = '',
      this.floorCreatedAt});
  @override
  State<_SiliconImage> createState() => _SiliconImageState();
}

class _SiliconImageState extends State<_SiliconImage> {
  static final Map<String, Uint8List> _cache = {};
  // v1384：全局在飞任务去重——流式输出期间楼层每chunk重建State，无此锁=MJ提交风暴（日志实证1.6秒16连发）
  static final Set<String> _inflight = {};
  int _sessionStartMs = 0; // v1412：会话起点（initState赋值），防止打开APP自动补画历史楼层
  static int _activeGen = 0; // v1388：全局生成并发计数（上限2，防超服务商并发）
  // v1395：MJ任务ID持久化——轮询超时后凭ID回站取图，不重新生成不耗额度
  static Map<String, String>? _mjTaskIds;
  static bool _mjTasksLoaded = false;
  List<Uint8List>? _mjGrid; // v1400：MJ四宫格切分后的4张单图（[i]=当前显示，可能是合成版）
  List<Uint8List>? _origGrid; // v1440：每张变体的无字原图——各张独立加标题的合成底图
  String? _curKey; // v1438：当前图缓存key（重新取图按钮清缓存用）
  int _mjGridSel = 0; // v1400：当前选中的宫格

  /// v1400：MJ四宫格2x2切分为4张单图
  Future<List<Uint8List>?> _splitGrid(Uint8List src) async {
    try {
      final codec = await ui.instantiateImageCodec(src);
      final frame = await codec.getNextFrame();
      final img = frame.image;
      // v1404：删除方图判定——MJ的imagine永远是2x2四宫格，--ar竖版时整体也是竖的（2:3实证漏切）
      if (img.width % 2 != 0 || img.height % 2 != 0) return null;
      final w = img.width ~/ 2, h = img.height ~/ 2;
      final out = <Uint8List>[];
      for (final rc in [
        const Offset(0, 0),
        Offset(w.toDouble(), 0),
        const Offset(0, 0) + Offset(0, h.toDouble()),
        Offset(w.toDouble(), h.toDouble())
      ]) {
        final rec = ui.PictureRecorder();
        final c = ui.Canvas(rec);
        c.drawImageRect(
            img,
            ui.Rect.fromLTWH(rc.dx, rc.dy, w.toDouble(), h.toDouble()),
            ui.Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
            ui.Paint());
        final pi = await rec.endRecording().toImage(w, h);
        final bd = await pi.toByteData(format: ui.ImageByteFormat.png);
        out.add(bd!.buffer.asUint8List());
      }
      return out;
    } catch (_) {
      return null;
    }
  }
  // v1388：切引擎前的历史楼层=手动生成（点击占位才画），防切引擎自动重绘刷额度
  static final Set<String> _manualOnly = {};
  static final Set<String> _manualRetry = {};
  // v1386：失败冷却——429后finally移除inflight→chunk重建立即重试→"失败-移除-重试"死循环（v1384日志实证百次429）
  static final Map<String, DateTime> _failCooldown = {};
  // v1387：失败一次就停——用户裁决"提交失败一次就让它停"——重建的State不再自动重试，手动点击错误框重试
  static final Set<String> _failedOnce = {};
  Uint8List? _bytes;
  Uint8List? _origBytes; // v1349：无字原底图（合成输入固定用它）
  // v1367：封面调字——合成参数留存+每字偏移+调字模式
  String _coverName = '';
  String _coverAuthor = '';
  String _coverFont = '';
  final Map<int, Offset> _charOffsets = {};
  final Map<int, Offset?> _dragLast = {}; // v1375：拖动起点（pointer坐标）
  Offset _authorOffset = Offset.zero; // v1377b：作者列整体偏移
  bool _lockName = true; // v1379：书名锁——开=4字绑定一起移
  bool _lockAuthor = true; // v1379：作者锁——开=作者与书名联动
  List<Offset> _charCenters = []; // v1382：各字真实视觉中心（compose返回）
  Offset _authorCenter = Offset.zero; // v1382：作者拖块锚点
  final Map<int, double> _charScales = {}; // v1382：单字缩放
  double _authorScale = 1.0; // v1382：作者列缩放
  final Map<int, Offset?> _aDragLast = {}; // v1376：作者拖动起点
  bool _adjustMode = false;
  String? _err;
  static String? _imgDir; // v1343：磁盘缓存目录（prompt+size命名，永久复用防重复烧token）

  Future<void> _saveMjTask(String src, String taskId) async {
    _mjTaskIds ??= {};
    _mjTaskIds![src] = taskId;
    // v1425：票库入global存储（global/mj_tasks）——随云同步备份迁移（用户裁决：图不同步、ID同步）
    try {
      AppState.instance.storage.writeGlobalJson('mj_tasks', _mjTaskIds);
    } catch (e) {
      // v1423：写盘失败必须留痕
      AppState.instance.apiLog('MJ任务票写盘失败: $e');
    }
  }

  Future<void> _loadMjTasks() async {
    if (_mjTasksLoaded) return;
    _mjTasksLoaded = true;
    // v1416：merge读盘——内存已有taskId不覆盖（08:51事故：提交已存ID，读盘旧数据覆盖后savedTaskId空→重新提交重画一单）
    _mjTaskIds ??= {};
    void absorb(Map<dynamic, dynamic> src) {
      src.forEach((k, v) {
        if (v.toString().isNotEmpty &&
            (!_mjTaskIds!.containsKey(k) ||
                (_mjTaskIds![k] ?? '').isEmpty)) {
          _mjTaskIds![k.toString()] = v.toString(); // v1422：有效票恢复空串脏位
        }
      });
    }

    try {
      // v1425：主票库=global存储（随云同步备份）
      final g = AppState.instance.storage.readGlobalJson('mj_tasks');
      if (g is Map) absorb(g);
      // 旧私有文件一次性迁移（v1425前票存chat_images目录）
      try {
        final f = File(await _diskPath('mj_tasks.json'));
        if (f.existsSync()) {
          final old =
              (jsonDecode(f.readAsStringSync()) as Map).cast<String, String>();
          absorb(old);
          AppState.instance.storage.writeGlobalJson('mj_tasks', _mjTaskIds);
        }
      } catch (_) {}
    } catch (_) {
      _mjTaskIds ??= {};
    }
  }

  Future<String> _diskPath(String key) async {
    final dir = _imgDir ??= await _ensureDir();
    var safe = key.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '');
    // v1426：substring(0,80)对短文件名越界炸——mj_tasks.json(11字符)从v1343起每次写盘必炸被吞，
    // 票从未落盘=内存票刷新即丢（11:49日志RangeError 0..11:80实锤）——这就是"有ID取不到图"的总根源
    if (safe.length > 80) safe = safe.substring(0, 80);
    return '$dir/si_$safe.png';
  }

  Future<String> _ensureDir() async {
    final docs = (await getApplicationDocumentsDirectory()).path;
    final dir = '$docs/chat_images';
    final d = Directory(dir);
    if (!d.existsSync()) d.createSync(recursive: true);
    return dir;
  }

  @override
  void initState() {
    super.initState();
    // v1412/v1414b：会话起点改读AppState页面级（进聊天页时刻）——
    // 组件级会随切引擎重建/不重建两个方向都失效
    _sessionStartMs = AppState.instance.chatPageOpenedAt > 0
        ? AppState.instance.chatPageOpenedAt
        : DateTime.now().millisecondsSinceEpoch;
    _load();
  }

  /// v1438：重新取图（测试票链用）——清缓存凭票重取，纯续取不提交不耗额度
  Future<void> _reFetchFromTicket() async {
    final key = _curKey;
    if (key == null) return;
    _cache.remove(key);
    try {
      File(await _diskPath(key)).deleteSync();
    } catch (_) {}
    try {
      File(await _diskPath('${widget.src}_composed')).deleteSync();
    } catch (_) {}
    _manualRetry.add(widget.src);
    setState(() => _err = '重新取图中（凭票续取，不耗额度）…');
    _bytes = null;
    await _load();
  }

  /// v1344：封面合成后更新显示+落盘
  Future<void> updateBytes(Uint8List b) async {
    _bytes = b;
    // v1445：取图成功必须清_err——build里占位优先于图显示，
    // 不清则"取回MJ图…"占位永远盖住已取到的图（17:59实证取完不显示要重启）
    _err = null;
    // v1439：合成版同步进宫格——加过标题的缩略也带标题（用户确认交互）
    // 落盘变体位，换标题永远从无字底图(_origBytes)重新合成
    if (_mjGrid != null && _mjGridSel < _mjGrid!.length) {
      _mjGrid![_mjGridSel] = b;
      try {
        final key = _curKey;
        if (key != null) {
          // v1440：合成版存_c文件（v{n}保持无字原图——各张独立换标题互不影响）
          await File(await _diskPath('${key}_v${_mjGridSel}_c'))
              .writeAsBytes(b);
        }
      } catch (_) {}
    }
    setState(() {});
    try {
      final diskPath = await _diskPath('${widget.src}_composed');
      await File(diskPath).writeAsBytes(b);
    } catch (_) {}
  }

  /// v1402：监听在飞任务——在飞State销毁后其async轮询仍会写缓存，本循环2秒一查接住显示
  Future<void> _watchInflight(String src) async {
    final pm = RegExp(r'/prompt/([^?]+)').firstMatch(src);
    if (pm == null) return;
    final prompt = Uri.decodeComponent(pm.group(1)!);
    final wm = RegExp(r'width=(\d+)').firstMatch(src);
    final hm = RegExp(r'height=(\d+)').firstMatch(src);
    final key =
        '$prompt|${wm != null ? wm.group(1) : 768}x${hm != null ? hm.group(1) : 768}';
    for (var t = 0; t < 150; t++) {
      await Future.delayed(const Duration(seconds: 2));
      if (!mounted) return;
      if (_cache.containsKey(key)) {
        setState(() {
          _bytes = _cache[key];
          _err = null;
        });
        return;
      }
      if (!_inflight.contains(src)) return; // 在飞已结束（失败路径），留在错误态
    }
  }

  Future<void> _load() async {
    final src = widget.src;
    if (_cache.containsKey(src)) {
      setState(() => _bytes = _cache[src]);
      return;
    }
    // v1387：失败过就永久挂起（自动重试禁用），用户点击错误框手动重试
    if (_failedOnce.contains(src)) {
      return; // _err显示走build的错误分支
    }
    // v1384：同key在飞直接挂起等结果（rebuild的新State复用缓存/in-flight结果）
    if (_inflight.contains(src)) {
      setState(() => _err = '任务进行中，请稍候…');
      _watchInflight(src); // v1402：后台监听缓存——在飞State销毁后其结果仍能接住显示
      return;
    }
    // v1386：失败冷却60秒——期内重建挂起，防"失败-移除-重试"死循环刷爆公益池
    final cd = _failCooldown[src];
    if (cd != null &&
        DateTime.now().difference(cd) < const Duration(seconds: 60)) {
      setState(() => _err = '刚才失败，冷却中（60秒后可重试）');
      return;
    }
    _inflight.add(src);
    try {
      // 提取prompt（/prompt/后?前）与尺寸
      final pm = RegExp(r'/prompt/([^?]+)').firstMatch(src);
      if (pm == null) {
        setState(() => _err = '标签格式错误');
        return;
      }
      final prompt = Uri.decodeComponent(pm.group(1)!);
      final wm = RegExp(r'width=(\d+)').firstMatch(src);
      final hm = RegExp(r'height=(\d+)').firstMatch(src);
      final size =
          '${wm != null ? wm.group(1) : 768}x${hm != null ? hm.group(1) : 768}';
      // v1389：磁盘缓存key去引擎前缀——一个prompt一张图，"谁画的显示谁"，重画后新版本覆盖保留
      final key = '$prompt|$size';
      _curKey = key; // v1438：记录当前key
      final legacyKey = '${widget.engine}|$prompt|$size'; // v1352旧格式（含引擎），兼容读取
      // v1446：重建段必须先于_cache命中执行——命中直接return会让重建跳过，
      // 滚动列表销毁重建后_mjGrid丢失全部变单图（18:18用户实证）
      // v1437/v1440：磁盘变体重建宫格——v{n}=无字原图进_origGrid，
      // v{n}_c=合成版存在则_mjGrid显示合成版（各张独立标题跨重启保留）
      try {
        final variants = <Uint8List>[];
        final origs = <Uint8List>[];
        for (var n = 0; n < 4; n++) {
          final vf = File(await _diskPath('${key}_v$n'));
          if (!vf.existsSync()) continue;
          final orig = vf.readAsBytesSync();
          origs.add(orig);
          final cf = File(await _diskPath('${key}_v${n}_c'));
          variants.add(cf.existsSync() ? cf.readAsBytesSync() : orig);
        }
        if (variants.length >= 2) {
          _mjGrid = variants;
          _origGrid = origs;
          _mjGridSel = 0;
          _bytes = variants[0];
        }
      } catch (_) {}
      if (_cache.containsKey(key)) {
        setState(() => _bytes = _cache[key]);
        return;
      }
      // v1343：磁盘缓存命中——切引擎/重启APP不重复生成（防历史楼层重烧token）
      // v1344：合成版优先（封面标签叠过字后直接读合成版）
      // v1429：合成版写读统一用widget.src（1642写侧是src_composed——此前读侧用key，
      // 两个净化结果不同=合成版重启后读不回，v1344以来的暗bug今日用户问保存机制才暴露）
      final composedPath = await _diskPath('${widget.src}_composed');
      final composedFile = File(composedPath);
      var diskPath = await _diskPath(key); // v1373b：提前声明（composed分支也要读无字底图）
      // v1389：新格式miss则读旧格式（v1352含引擎前缀的存量文件），兼容过渡
      if (!File(diskPath).existsSync()) {
        final legacyPath = await _diskPath(legacyKey);
        if (File(legacyPath).existsSync()) diskPath = legacyPath;
      }
      if (composedFile.existsSync() &&
          prompt.toLowerCase().contains('cover')) {
        final b = composedFile.readAsBytesSync();
        _cache[key] = b;
        // v1373：composed命中时补_origBytes=无字底图——否则调字重合成静默return（金圈动字不动实证）
        try {
          _origBytes = File(diskPath).readAsBytesSync();
        } catch (_) {}
        if (mounted) setState(() => _bytes = b);
        return;
      }
      final diskFile = File(diskPath);
      if (diskFile.existsSync()) {
        final b = diskFile.readAsBytesSync();
        _cache[key] = b;
        _origBytes = b; // v1349：原底图留存
        if (mounted) setState(() => _bytes = b);
        return;
      }
      // v1388：切引擎前的历史楼层不自动生成——用户回复/重答的新楼层才画
      // v1412：本次打开APP时已存在的楼层一律不自动绘制，只认会话起点之后新产生的楼层——
      // 防止冷启动把昨晚失败过的楼层整批自动补画烧额度（11-04凌晨01:41三连发实证）
      final switchMs = AppState.instance.chatEngineSwitchAt?.millisecondsSinceEpoch;
      final beforeSession = _sessionStartMs > 0 &&
          widget.floorCreatedAt != null &&
          widget.floorCreatedAt! < _sessionStartMs;
      if (widget.floorCreatedAt != null &&
          ((switchMs != null && widget.floorCreatedAt! < switchMs) ||
              beforeSession) &&
          !_manualRetry.contains(src)) {
        _manualOnly.add(src);
        // v1397：有MJ在途任务时提示取回（凭taskId跨引擎取图，不耗额度）
        // v1411：空串ID不算有任务；无ID历史楼层不承诺生成（点了也取不了，绝不重画）
        final hasTask = _mjTaskIds?[src]?.isNotEmpty == true;
        setState(() => _err = hasTask
            ? '有MJ在途任务，点此取回'
            : '未生成（无存档任务ID）');
        return;
      }
      // v1414b：manualRetry一次性消费——豁免本次挂起后即清除，
      // 防static集合残留无限豁免挂起（每切一个引擎重画一轮的帮凶）
      _manualRetry.remove(src);
      // v1388：全局并发闸——多楼层同时自动生成超服务商并发限制（环网关code=-1实证）
      while (_activeGen >= 2) {
        await Future.delayed(const Duration(milliseconds: 500));
        if (!mounted) return;
      }
      _activeGen++;
      late Uint8List genBytes;
      // v1414：野生引擎（CF/硅基/pollinations）无任务ID取回机制——
      // 本次打开APP前的旧楼层一律不生成（此前防护只覆盖MJ分支，切野生即重画一轮）
      if (widget.engine != 'mj' &&
          widget.engine != 'mjpro' &&
          (widget.floorCreatedAt ?? 0) < _sessionStartMs) {
        if (_activeGen > 0) _activeGen--;
        setState(() => _err = _mjTaskIds?[src]?.isNotEmpty == true
            ? 'MJ任务请切回MJ引擎取回'
            : '旧楼层不自动重绘（想重画请重新生成）');
        return;
      }
      if (widget.engine == 'mj' || widget.engine == 'mjpro') {
        // v1383：MJ公益接口（trueai-org/midjourney-proxy）——提交任务+轮询取图
        // v1385：mjpro=MJ企付费引擎（环网关，Bearer key）
        // prompt=标签URL里的英文场景，AI标签width/height→--ar比例（MJ真出对应构图）
        final isPro = widget.engine == 'mjpro';
        final mjBase = isPro ? 'https://api.huanwangai.com' : widget.mjBase;
        final mjHeaders = isPro
            ? {
                'Content-Type': 'application/json',
                'Authorization': 'Bearer ${widget.mjProKey}'
              }
            : {'Content-Type': 'application/json'};
        if (isPro && widget.mjProKey.isEmpty) {
          setState(() => _err = '点顶栏🔑填环网key');
          return;
        }
        final w0 = int.tryParse(RegExp(r'width=(\d+)').firstMatch(widget.src)?.group(1) ?? '1024');
        final h0 = int.tryParse(RegExp(r'height=(\d+)').firstMatch(widget.src)?.group(1) ?? '1024');
        final g = w0 != null && h0 != null && w0 > 0 && h0 > 0 ? w0.gcd(h0) : 1;
        final ar = w0 != null && h0 != null ? ' --ar ${w0 ~/ g}:${h0 ~/ g}' : '';
        var mjPrompt = '$prompt$ar';
        // v1444：mj公强制RELAX——FAST队列全站拥堵240深，提交排队到超时必败
        // （14:30-15:13五连败全"超时失败"实证，RELAX慢车道3单全成）
        // 额度预检保留打日志（fastAvailableCount是全站池仅供参考）
        if (!isPro) {
          mjPrompt = '$mjPrompt --relax';
          try {
            final hr = await http
                .get(Uri.parse('$mjBase/mj/home'))
                .timeout(const Duration(seconds: 10));
            if (hr.statusCode == 200) {
              final hd = (jsonDecode(hr.body)['data'] ?? {}) as Map;
              AppState.instance.apiLog(
                  '额度预检: FAST剩${hd['fastAvailableCount']}，RELAX剩${hd['relaxAvailableCount']}，悠船剩${hd['youChuanRelaxAvailableCount']}（已强制RELAX绕开FAST拥堵）');
            }
          } catch (_) {}
        }
        String? imageUrl;
        // v1395：找回超时任务——凭已存taskId直接续轮询，不重新提交不耗额度
        await _loadMjTasks();
        // v1411：空串ID不算命中（任务闭环""hack残留）
        final savedTaskId =
            (_mjTaskIds?[src] ?? '').isNotEmpty ? _mjTaskIds![src] : null;
        // v1416：内存taskId兜底——savedTaskId判定外再查内存map（闭环""/读盘竞态下不丢ID）
        final memTaskId =
            (_mjTaskIds?[src] ?? '').isNotEmpty ? _mjTaskIds![src] : null;
        // v1421：prompt匹配兜底已回滚（用户裁决：公共池匹配有取错图隐患）——
        // ID链靠 v1416内存兜底+v1416 merge读盘+v1419 SUCCESS等URL 三个根因修复保稳
        final effTaskId = savedTaskId ?? memTaskId;
        // v1412b：点击只允许"取回"——本次打开APP之前就存在的楼层，无存档ID绝不重新提交
        // （判定用会话起点，不用_manualRetry——static集合残留会误杀本会话新楼层自动画）
        if (effTaskId == null &&
            (widget.floorCreatedAt ?? 0) < _sessionStartMs) {
          if (_activeGen > 0) _activeGen--;
          setState(() => _err = '该图无存档任务ID，取不了');
          return;
        }
        if (savedTaskId != null) {
          AppState.instance.apiLog('MJ续取任务: $savedTaskId');
          setState(() => _err = '找回超时任务，继续取图…');
        } else {
        AppState.instance.apiLog('MJ提交(${widget.engine}): $mjPrompt');
        try {
          final sub = await http
              .post(Uri.parse('$mjBase/mj/submit/imagine'),
                  headers: mjHeaders,
                  body: jsonEncode({'prompt': mjPrompt}))
              .timeout(const Duration(seconds: 30));
          if (sub.statusCode != 200) {
            if (_activeGen > 0) _activeGen--;
            _failedOnce.add(src);
            _failCooldown[src] = DateTime.now();
            AppState.instance.apiLog('MJ提交失败 HTTP${sub.statusCode}');
            setState(() => _err = 'MJ提交失败 HTTP${sub.statusCode}');
            return;
          }
          final subData = jsonDecode(sub.body);
          if (subData['code'] != 1) {
            if (_activeGen > 0) _activeGen--;
            _failedOnce.add(src);
            _failCooldown[src] = DateTime.now();
            AppState.instance.apiLog(
                'MJ提交失败 code=${subData['code']} ${subData['description'] ?? subData['result']}');
            setState(() =>
                _err = 'MJ提交失败: ${subData['description'] ?? subData['result']}');
            return;
          }
          _mjTaskIds ??= {};
          _mjTaskIds![src] = subData['result'].toString();
          _saveMjTask(src, _mjTaskIds![src]!);
          // v1430：票据全程可见——提交响应回来即打终端（用户要求发起时+绘制中都能看到ID）
          AppState.instance
              .apiLog('MJ任务ID: ${_mjTaskIds![src]}（票已落盘）');
        } catch (ex) {
          if (_activeGen > 0) _activeGen--;
          _failedOnce.add(src);
          AppState.instance.apiLog('MJ异常: $ex');
          setState(() => _err = 'MJ异常: $ex');
          return;
        }
        }
        try {
          final taskId = effTaskId ?? savedTaskId ?? memTaskId ?? _mjTaskIds![src]!;
          String? imageUrl;
          // v1424：独立4图通道标记——该通道只写genBytes不写imageUrl，
          // 循环后超时检查只看imageUrl会把"已下载成功"误判成超时（11:45实证6秒循环）
          var gotGrid = false;
          var lastProg = ''; // v1403：进度去重
          var _fetchFail = 0; // v1431：连续fetch失败计数（留痕限频：前3次+每6次打一条）
          // v1433：轮询无上限——proxy解卡自动出图（14:23用户裁决：还要点占位有点傻）。
          // 99%=MJ画完等proxy收尾（切图传CDN），proxy啥时候交卷啥时候SUCCESS，APP只管每5秒问。
          // 组件销毁(mounted)自动停；FAILURE是终态退出。
          while (true) {
            // v1435：轮询间隔5秒→60秒（14:31用户裁决——proxy收尾动辄几分钟，5秒一问纯浪费电）
            await Future.delayed(const Duration(seconds: 60));
            if (!mounted) return;
            http.Response? ft;
            try {
              ft = await http
                  .get(Uri.parse('$mjBase/mj/task/$taskId/fetch'),
                      headers: mjHeaders)
                  .timeout(const Duration(seconds: 20));
            } catch (e) {
              // v1431：fetch失败必须留痕（13:55实证：持续超时静默continue，13分钟零日志像死机）
              _fetchFail++;
              if (_fetchFail <= 3 || _fetchFail % 6 == 0) {
                AppState.instance
                    .apiLog('MJ轮询fetch失败x$_fetchFail: $e');
              }
            }
            if (ft != null && ft.statusCode != 200) {
              _fetchFail++;
              if (_fetchFail <= 3 || _fetchFail % 6 == 0) {
                AppState.instance.apiLog(
                    'MJ轮询fetch失败x$_fetchFail: HTTP${ft.statusCode}');
              }
            }
            // v1434：fetch接口挂（连续失败>=6）→查task/list按ID兜底——
            // list与fetch同库，fetch接口本身故障时list可能还活着（14:27用户提议）
            if ((ft == null || ft.statusCode != 200) && _fetchFail >= 6) {
              try {
                // v1441：list兜底按引擎分路径——公益站GET /mj/task/list（开放），
                // 环网关POST /mj/task/list-by-condition带ids（15:08文档实测，GET 404）
                final lr = isPro
                    ? await http
                        .post(
                            Uri.parse('$mjBase/mj/task/list-by-condition'),
                            headers: mjHeaders,
                            body: jsonEncode({'ids': [taskId]}))
                        .timeout(const Duration(seconds: 20))
                    : await http
                        .get(Uri.parse('$mjBase/mj/task/list'),
                            headers: mjHeaders)
                        .timeout(const Duration(seconds: 20));
                if (lr.statusCode == 200) {
                  final decoded = jsonDecode(lr.body);
                  Map? me;
                  if (decoded is List) {
                    for (final t in decoded) {
                      if (t is Map && t['id'].toString() == taskId) {
                        me = t;
                        break;
                      }
                    }
                  }
                  if (me != null && me['status'] == 'SUCCESS') {
                    AppState.instance
                        .apiLog('fetch接口挂，list兜底取到SUCCESS数据');
                    ft = http.Response(jsonEncode(me), 200);
                  }
                }
              } catch (_) {}
            }
            if (ft == null || ft.statusCode != 200) {
              continue; // v1394：单次失败不断链，下一轮继续问
            }
            _fetchFail = 0;
            final ftData = jsonDecode(ft.body);
            final status = ftData['status']?.toString() ?? '';
            if (status == 'SUCCESS') {
              // v1401：独立单图URL数组优先（环网关后台4张独立图，原始分辨率）
              final urls = ftData['imageUrls'];
              if (urls is List && urls.length >= 2) {
                final dl = <Uint8List>[];
                for (final u in urls) {
                  try {
                    // v1403：元素是{url,thumbnail}对象——取url字段（toString={url:..}导致解析全失败回退拼图实证）
                    final uu = u is Map ? (u['url'] ?? u) : u;
                    final rs = await http
                        .get(Uri.parse(uu.toString()))
                        .timeout(const Duration(seconds: 60));
                    if (rs.statusCode == 200) dl.add(rs.bodyBytes);
                  } catch (_) {}
                }
                if (dl.length >= 2) {
                  _mjGrid = List<Uint8List>.from(dl);
                  _origGrid = List<Uint8List>.from(dl); // v1440：每张无字原图独立追踪
                  _mjGridSel = 0;
                  // v1422：票据铁律——成功也不清ID，MJ没删就永远可重新取图
                  genBytes = dl[0];
                  gotGrid = true;
                  // v1428：4张变体全落盘——图下缩略条随时切换（用户裁决：四张都用）
                  for (var n = 0; n < dl.length; n++) {
                    try {
                      await File(await _diskPath('${key}_v$n'))
                          .writeAsBytes(dl[n]);
                    } catch (_) {}
                  }
                  break;
                }
              }
              // 拼图兜底：imageUrl四宫格→本地切分
              imageUrl = (ftData['imageUrl']?.toString().isNotEmpty == true
                      ? ftData['imageUrl']
                      : null) ??
                  (urls is List && urls.isNotEmpty ? urls[0] : null) ??
                  ftData['result']?['imageUrl'] ??
                  ftData['uri'];
              imageUrl = imageUrl?.toString();
              AppState.instance.apiLog(
                  'MJ SUCCESS响应: ${ft.body.length > 500 ? ft.body.substring(0, 500) : ft.body}');
              // v1416：SUCCESS但URL全空→继续等（环网关status先SUCCESS、URL后到；
              // 08:50事故：此处break后imageUrl空被当"轮询超时"，白瞎已生成的任务）
              if (imageUrl == null || imageUrl.isEmpty) continue;
              break;
            }
            if (status == 'FAILURE') {
              if (_activeGen > 0) _activeGen--;
              _failedOnce.add(src);
              _failCooldown[src] = DateTime.now();
              AppState.instance
                  .apiLog('MJ任务失败: ${ftData['failReason'] ?? '未知'}');
              setState(() =>
                  _err = 'MJ任务失败: ${ftData['failReason'] ?? '未知'}');
              return;
            }
            final prog = ftData['progress']?.toString() ?? status;
            if (prog != lastProg) {
              lastProg = prog;
              // v1430：绘制中终端同步显示ID+进度（变化时打，不刷屏）
              AppState.instance
                  .apiLog('MJ绘制中 $prog（任务$taskId）');
            }
            setState(() =>
                _err = 'MJ绘制中 $prog…（任务$taskId）');
          }
          if (!gotGrid && (imageUrl == null || imageUrl.isEmpty)) {
            if (_activeGen > 0) _activeGen--;
            _failedOnce.add(src);
            AppState.instance
                .apiLog('MJ轮询超时 任务ID已存（点重试继续取图）');
            // v1419：占位直接显示任务ID——ID可见化，后台画好凭ID随时可取回
            setState(() => _err =
                'MJ等待超时，任务$taskId已存档（点此继续取图）');
            return;
          }
          if (!gotGrid) {
            setState(() => _err = 'MJ完成，下载中…');
            final imgRs = await http
                .get(Uri.parse(imageUrl!))
                .timeout(const Duration(seconds: 60));
            if (imgRs.statusCode != 200) {
              if (_activeGen > 0) _activeGen--;
              _failedOnce.add(src);
              AppState.instance
                  .apiLog('MJ图下载失败 HTTP${imgRs.statusCode}');
              setState(() => _err = 'MJ图下载失败 HTTP${imgRs.statusCode}');
              return;
            }
            // v1422：票据铁律——废除v1395闭环清映射/删除，ID永久保留（用户定稿：
            // 提交即存票、票据唯一不能丢、任何时候可凭票重新取图，除非MJ那边删了）
            genBytes = imgRs.bodyBytes;
            // v1400：MJ四宫格自动切分
            _mjGrid = await _splitGrid(genBytes);
            _mjGridSel = 0;
          }
        } catch (ex) {
          if (_activeGen > 0) _activeGen--;
          _failedOnce.add(src);
          AppState.instance.apiLog('MJ异常: $ex');
          setState(() => _err = 'MJ异常: $ex');
          return;
        }
        _cache[key] = genBytes;
        _origBytes = genBytes;
        try {
          await File(diskPath).writeAsBytes(genBytes);
        } catch (_) {}
        var finalBytes = genBytes;
        if (prompt.toLowerCase().contains('cover') &&
            widget.bookName.isNotEmpty) {
          try {
            final composed = await composeCoverText(
                finalBytes, widget.bookName, 'luckpala');
            if (composed != null) finalBytes = composed.bytes;
          } catch (_) {}
        }
        if (mounted) {
          setState(() {
            _bytes = finalBytes;
            _err = null; // v1445：成功清占位（双链并发时占位不能盖图）
          });
        }
        if (_activeGen > 0) _activeGen--;
        return;
      }
      if (widget.engine == 'cf') {
        // v1348：CF Workers AI flux-1-schnell（固定1024方图）
        final ckey = widget.cfKey;
        final acc = widget.cfAccount;
        if (ckey.isEmpty || acc.isEmpty) {
          setState(() => _err = '点顶栏🔑填CF Token+账户ID');
          return;
        }
        // v1382：flux-schnell对裸prompt出图随机——加封面质量增强前缀
        final cbody = jsonEncode({
          'prompt':
              'professional book cover art, masterpiece, best quality, highly detailed, dramatic lighting, cinematic composition, rich colors. $prompt'
        });
        final creq = http.Request(
            'POST',
            Uri.parse(
                'https://api.cloudflare.com/client/v4/accounts/$acc/ai/run/@cf/black-forest-labs/flux-1-schnell'))
          ..headers['Content-Type'] = 'application/json'
          ..headers['Authorization'] = 'Bearer $ckey'
          ..bodyBytes = cbody.codeUnits;
        final crs = await http.Response.fromStream(
            await creq.send().timeout(const Duration(seconds: 120)));
        if (crs.statusCode != 200) {
          setState(() => _err = 'CF生成失败 HTTP${crs.statusCode}');
          return;
        }
        final cdata = jsonDecode(crs.body);
        final b64 = (cdata['result'] ?? {})['image'] as String?;
        if (b64 == null) {
          setState(() => _err = 'CF生成失败（无图）');
          return;
        }
        genBytes = base64Decode(b64);
      } else {
        final skey = widget.skey;
        if (skey.isEmpty) {
          setState(() => _err = '点顶栏🔑填硅基Key');
          return;
        }
        final body = jsonEncode({
          'model': 'Kwai-Kolors/Kolors',
          'prompt': prompt,
          'image_size': size,
        });
        final req = http.Request(
            'POST', Uri.parse('https://api.siliconflow.cn/v1/images/generations'))
          ..headers['Content-Type'] = 'application/json'
          ..headers['Authorization'] = 'Bearer $skey'
          ..bodyBytes = body.codeUnits;
        final rs = await http.Response.fromStream(
            await req.send().timeout(const Duration(seconds: 90)));
        if (rs.statusCode != 200) {
          setState(() => _err = '生成失败 HTTP${rs.statusCode}');
          return;
        }
        final data = jsonDecode(rs.body);
        final url = (data['images'] as List?)?.firstOrNull?['url'] as String?;
        if (url == null) {
          setState(() => _err = '生成失败（无图）');
          return;
        }
        final imgRs = await http.get(Uri.parse(url))
            .timeout(const Duration(seconds: 60));
        if (imgRs.statusCode != 200) {
          setState(() => _err = '图片下载失败');
          return;
        }
        genBytes = imgRs.bodyBytes;
      }
      _cache[key] = genBytes;
      _origBytes = genBytes; // v1349：原底图留存（重复合成从干净底图开始，防双层字）
      try {
        await File(diskPath).writeAsBytes(genBytes); // v1343：落盘
      } catch (_) {}
      _manualRetry.remove(src); // v1388：生成完成，撤销手动重试豁免
      _activeGen--; // v1388：并发闸释放
      var finalBytes = genBytes;
      // v1344：封面标签自动叠书名+作者（prompt含cover触发，AI画不了汉字的正解）
      if (prompt.toLowerCase().contains('cover') && widget.bookName.isNotEmpty) {
        try {
          final composed = await composeCoverText(
              finalBytes, widget.bookName, 'luckpala');
          if (composed != null) finalBytes = composed.bytes;
        } catch (_) {}
      }
      if (mounted) {
          setState(() {
            _bytes = finalBytes;
            _err = null; // v1445：成功清占位（双链并发时占位不能盖图）
          });
        }
    } catch (ex) {
      if (mounted) setState(() => _err = '生成超时/失败');
    } finally {
      _inflight.remove(src); // v1384：无论成败，飞完移除
      if (_activeGen > 0) _activeGen--; // v1388：异常路径也释放
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_err != null) {
      final failed = _failedOnce.contains(widget.src) ||
          _manualOnly.contains(widget.src);
      return GestureDetector(
        // v1432：占位恒可点——绘制中点击=清挂起重走load（票在手必续取不重画，
        // proxy解卡时点一下立刻出图；旧轮询实例fetch幂等无副作用）
        onTap: () {
          // v1387/1388：手动重试——清失败标记/冷却/手动标记后重新加载
          _failedOnce.remove(widget.src);
          _failCooldown.remove(widget.src);
          _inflight.remove(widget.src);
          if (_manualOnly.contains(widget.src)) {
            _manualOnly.remove(widget.src);
            _manualRetry.add(widget.src); // 本次load豁免manualOnly
          }
          setState(() {
            _err = null;
          });
          _load();
        },
        child: Container(
          width: 260,
          height: 56,
          color: const Color(0xFFEFE8D8),
          alignment: Alignment.center,
          // v1417：_err自带"点此"提示时不再叠"（点此重试）"——超时文案两段"点此"连排被当成两个按键
          child: Text(
              failed && !_err!.contains('点此')
                  ? '🖼 $_err（点此重试）'
                  : '🖼 $_err',
              style:
                  const TextStyle(fontSize: 12, color: Color(0xFF9B8F7A))),
        ),
      );
    }
    final b = _bytes;
    if (b == null) {
      return Container(
        width: 260,
        height: 170,
        color: const Color(0xFFEFE8D8),
        alignment: Alignment.center,
        child: const SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    // v1400：MJ四宫格选择视图——点选一张设为正身
    if (_mjGrid != null && _mjGrid!.length >= 2) {
      // v1438：田字四宫格——点哪张哪张进全屏（用户定稿交互），金框为当前使用
      // 4张已落盘(key_v0..v3)重启保留（v1437重建），点宫格即切正身（调字/加标题对当前张）
      return Container(
        width: 260,
        padding: const EdgeInsets.all(4),
        color: const Color(0xFFEFE8D8),
        child: Column(children: [
          GridView.count(
            crossAxisCount: 2,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            childAspectRatio: 0.78,
            mainAxisSpacing: 4,
            crossAxisSpacing: 4,
            children: [
              for (var i = 0; i < _mjGrid!.length; i++)
                GestureDetector(
                  onTap: () {
                    final img = _mjGrid![i];
                    setState(() {
                      _mjGridSel = i;
                      _bytes = img;
                    });
                    // v1440：各张独立标题——底图切到该张的无字原图
                    _origBytes = _origGrid?[i] ?? img;
                    showDialog(
                      context: context,
                      builder: (d) => Dialog.fullscreen(
                        backgroundColor: Colors.black,
                        child: GestureDetector(
                          onTap: () => Navigator.pop(d),
                          child: Column(children: [
                            Expanded(
                              child: Image.memory(img, fit: BoxFit.contain),
                            ),
                            Padding(
                              padding: const EdgeInsets.all(12),
                              child: Text(
                                  '第${i + 1}张｜点击任意处返回（此张已设为使用中）',
                                  style: const TextStyle(
                                      fontSize: 13,
                                      color: Colors.white70)),
                            ),
                          ]),
                        ),
                      ),
                    );
                  },
                  child: Container(
                    decoration: BoxDecoration(
                      border: Border.all(
                          color: _mjGridSel == i
                              ? const Color(0xFFFFD700)
                              : Colors.transparent,
                          width: 3),
                    ),
                    child: Image.memory(_mjGrid![i], fit: BoxFit.cover),
                  ),
                ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Row(children: [
              const Expanded(
                child: Text('点图全屏查看，金框为使用中（四张已保存）',
                    style: TextStyle(
                        fontSize: 11, color: Color(0xFF9B8F7A))),
              ),
              GestureDetector(
                onTap: _reFetchFromTicket,
                child: const Text('⟳重新取图',
                    style: TextStyle(
                        fontSize: 11, color: Color(0xFFB8860B))),
              ),
            ]),
          ),
          // v1442：任务ID常显——重新取图/出图后占位退场，ID随时可查可抄
          Builder(builder: (c) {
            final tid = _mjTaskIds?[widget.src];
            return Padding(
              padding: const EdgeInsets.only(top: 1),
              child: Text(
                  tid != null && tid.isNotEmpty
                      ? '任务ID: $tid'
                      : '（无存档任务ID）',
                  style: const TextStyle(
                      fontSize: 10, color: Color(0xFFB0A58C))),
            );
          }),
        ]),
      );
    }
    final hasMjTask = _mjTaskIds?[widget.src] != null &&
        widget.engine == 'mjpro'; // v1399：仅MJ企引擎显示取图浮标
    return GestureDetector(
      onTap: () => showDialog(
        context: context,
        // v1356：StatefulBuilder——合成后实时刷新（原闭包b不更新=合成"无效"假象）
        builder: (d) => StatefulBuilder(
          builder: (d2, setD2) => Dialog.fullscreen(
          backgroundColor: Colors.black,
          child: Column(
            children: [
              Expanded(
                child: _adjustMode
                    ? _buildAdjustLayout(setD2)
                    : GestureDetector(
                        onTap: () => Navigator.pop(d),
                        child: Center(
                          child: InteractiveViewer(
                              child: Image.memory(_bytes ?? b,
                                  fit: BoxFit.contain)),
                        ),
                      ),
              ),
              SafeArea(
                child: Wrap(
                alignment: WrapAlignment.center,
                spacing: 8,
                runSpacing: 2,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                TextButton.icon(
                  icon: const Icon(Icons.text_fields, color: Colors.white70),
                  label: const Text('叠封面文字',
                      style: TextStyle(color: Colors.white70)),
                  onPressed: () => _coverTextDialog(context, b, this,
                      onDone: () => setD2(() {})),
                ),
                const SizedBox(width: 16),
                if (_adjustMode) ...[
                  // v1379：双锁开关——书名4字绑定/作者与书名联动
                  TextButton.icon(
                    icon: Icon(_lockName ? Icons.lock : Icons.lock_open,
                        color: const Color(0xFFFFD700), size: 18),
                    label: const Text('书名锁',
                        style: TextStyle(color: Colors.white70, fontSize: 12)),
                    onPressed: () => setD2(() => _lockName = !_lockName),
                  ),
                  TextButton.icon(
                    icon: Icon(_lockAuthor ? Icons.lock : Icons.lock_open,
                        color: const Color(0xFF7FD4C8), size: 18),
                    label: const Text('作者锁',
                        style: TextStyle(color: Colors.white70, fontSize: 12)),
                    onPressed: () => setD2(() => _lockAuthor = !_lockAuthor),
                  ),
                  // v1382：复位——清偏移+缩放回合成初始
                  TextButton.icon(
                    icon: const Icon(Icons.restart_alt,
                        color: Colors.white70, size: 18),
                    label: const Text('复位',
                        style: TextStyle(color: Colors.white70, fontSize: 12)),
                    onPressed: () async {
                      setD2(() {
                        _charOffsets.clear();
                        _authorOffset = Offset.zero;
                        _charScales.clear();
                        _authorScale = 1.0;
                      });
                      final src0 = _origBytes ?? _bytes;
                      if (src0 == null) return;
                      final out = await composeCoverText(src0, _coverName,
                          _coverAuthor,
                          fontFamily: _coverFont);
                      if (out != null) {
                        _charCenters = out.charCenters;
                        _authorCenter = out.authorCenter;
                        setState(() => _bytes = out.bytes);
                        setD2(() {});
                      }
                    },
                  ),
                  const SizedBox(width: 8),
                ],
                const SizedBox(width: 16),
                TextButton.icon(
                  icon: const Icon(Icons.open_with, color: Colors.white70),
                  label: Text(_adjustMode ? '完成调字' : '调字',
                      style: const TextStyle(color: Colors.white70)),
                  onPressed: () {
                    if (_coverName.isEmpty) {
                      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                          content: Text('请先合成一次再调字')));
                      return;
                    }
                    setD2(() => _adjustMode = !_adjustMode);
                  },
                ),
                const SizedBox(width: 16),
                TextButton.icon(
                  icon: const Icon(Icons.save_alt, color: Colors.white70),
                  label: const Text('保存到Download',
                      style: TextStyle(color: Colors.white70)),
                  onPressed: () async {
                    try {
                      final dir = Directory('/storage/emulated/0/Download');
                      if (!dir.existsSync()) dir.createSync(recursive: true);
                      final f = File(
                          '${dir.path}/chat_img_${DateTime.now().millisecondsSinceEpoch}.png');
                      await f.writeAsBytes(
                          _bytes!); // v1373：直读_bytes（闭包b过时嫌疑消除）+留证据
                      AppState.instance.apiLog(
                          '保存PNG ${_bytes!.length}B -> ${f.path}');
                      ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('已保存：${f.path}')));
                    } catch (ex) {
                      ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('保存失败（需存储授权）')));
                    }
                  },
                ),
              ]),
              ),
            ],
          ),
        ),
      ),
    ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Stack(children: [
            Image.memory(b, fit: BoxFit.fitWidth),
            // v1399：取MJ图浮标——仅MJ企引擎+有存档任务时显示
            if (hasMjTask)
              Positioned(
                right: 6, bottom: 6,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () async {
                    final tid = _mjTaskIds![widget.src]!;
                    setState(() => _err = '取回MJ图…');
                    String? imageUrl;
                    var lastProg = '';
                    for (var t = 0; t < 108; t++) {
                      await Future.delayed(
                          Duration(seconds: t < 60 ? 2 : 5));
                      if (!mounted) return;
                      http.Response ft;
                      try {
                        ft = await http
                            .get(Uri.parse(
                                'https://api.huanwangai.com/mj/task/$tid/fetch'),
                            headers: {
                              'Content-Type': 'application/json',
                              'Authorization': 'Bearer ${widget.mjProKey}'
                            })
                            .timeout(const Duration(seconds: 20));
                      } catch (_) {
                        continue;
                      }
                      if (ft.statusCode != 200) continue;
                      final ftData = jsonDecode(ft.body);
                      final status = ftData['status']?.toString() ?? '';
                      final prog = ftData['progress']?.toString() ?? '';
                      if (prog.isNotEmpty && prog != lastProg) {
                        lastProg = prog;
                        AppState.instance.apiLog('MJ进度 $prog');
                      }
                      if (status == 'SUCCESS') {
                        // v1401：独立单图URL数组优先
                        final urls = ftData['imageUrls'];
                        if (urls is List && urls.length >= 2) {
                          final dl = <Uint8List>[];
                          for (final u in urls) {
                            try {
                              // v1403：{url,thumbnail}对象取url
                              final uu = u is Map ? (u['url'] ?? u) : u;
                              final rs = await http
                                  .get(Uri.parse(uu.toString()))
                                  .timeout(const Duration(seconds: 60));
                              if (rs.statusCode == 200) dl.add(rs.bodyBytes);
                            } catch (_) {}
                          }
                          if (dl.length >= 2) {
                            _mjGrid = List<Uint8List>.from(dl);
                            _origGrid = List<Uint8List>.from(dl);
                            _mjGridSel = 0;
                            // v1445：浮标链补4张落盘（v1428只加在主链——漏了浮标链致重启后无四图）
                            for (var n = 0; n < dl.length; n++) {
                              try {
                                final k0 = _curKey;
                                if (k0 != null) {
                                  await File(await _diskPath('${k0}_v' + n.toString()))
                                      .writeAsBytes(dl[n]);
                                }
                              } catch (_) {}
                            }
                            // v1427：票据铁律补漏——此处清票是v1422扫描漏网点（widget.src写法绕过了当时的rg模式）
                            await updateBytes(dl[0]);
                            AppState.instance
                                .apiLog('MJ图取回成功(4图) ${dl.length}张');
                            return;
                          }
                        }
                        imageUrl = (ftData['imageUrl']?.toString()
                                        .isNotEmpty ==
                                    true
                                ? ftData['imageUrl']
                                : null) ??
                            (urls is List && urls.isNotEmpty
                                ? urls[0]
                                : null) ??
                            ftData['result']?['imageUrl'] ??
                            ftData['uri'];
                        imageUrl = imageUrl?.toString();
                        break;
                      }
                      if (status == 'FAILURE') {
                        setState(() =>
                            _err = 'MJ任务失败: ${ftData['failReason'] ?? '未知'}');
                        return;
                      }
                      setState(() =>
                          _err = '取回中 ${ftData['progress'] ?? status}…');
                    }
                    if (imageUrl == null || imageUrl.isEmpty) {
                      setState(() => _err = '取回超时，稍后再点');
                      return;
                    }
                    final imgRs = await http
                        .get(Uri.parse(imageUrl))
                        .timeout(const Duration(seconds: 60));
                    if (imgRs.statusCode != 200) {
                      setState(() =>
                          _err = 'MJ图下载失败 HTTP${imgRs.statusCode}');
                      return;
                    }
                    _mjTaskIds?.remove(widget.src); // 取回闭环
                    await updateBytes(imgRs.bodyBytes); // 正身替换
                    AppState.instance.apiLog('MJ图取回成功 ${imgRs.bodyBytes.length}B');
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(0.55),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                          color: const Color(0xFFFFD700), width: 1),
                    ),
                    child: const Text('取MJ图',
                        style: TextStyle(
                            color: Color(0xFFFFD700), fontSize: 12)),
                  ),
                ),
              ),
          ]),
        ),
      ),
    );
  }

  /// v1344：封面文字叠加——Canvas+TextPainter画系统字体汉字（AI画不了中文的正解）
  void _coverTextDialog(BuildContext ctx, Uint8List baseBytes, _SiliconImageState st,
      {VoidCallback? onDone}) {
    final nameCtl = TextEditingController();
    final authorCtl = TextEditingController();
    var font = ''; // v1350：''=系统黑体 KaiShu/XingShu/CaoShu
    const fontNames = {
      '': '黑体',
      'QiuHong': '秋鸿楷',
      'MaShanZheng': '马善政',
      'WenKai': '楷书',
      'XingShu': '行书',
      'CaoShu': '草书',
      'YouRan': '悠然小楷',
    }; // v1408：新增秋鸿楷/悠然小楷（free-font）/马善政（Google Fonts）三款毛笔字
    showDialog(
      context: ctx,
      builder: (d) => StatefulBuilder(
        builder: (d, setD) => AlertDialog(
        scrollable: true, // v1358：键盘弹出时可滚动——合成键不被遮挡
        title: const Text('叠封面文字'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: nameCtl,
              decoration: const InputDecoration(labelText: '书名（顶部横排大字）',
                  border: OutlineInputBorder())),
          const SizedBox(height: 12),
          TextField(controller: authorCtl,
              decoration: const InputDecoration(labelText: '作者名（底部小字，可空）',
                  border: OutlineInputBorder())),
          const SizedBox(height: 12),
          Wrap(
            spacing: 6,
            runSpacing: 4,
            children: fontNames.entries
                .map((e) => ChoiceChip(
                    label: Text(e.value),
                    selected: font == e.key,
                    onSelected: (_) => setD(() => font = e.key)))
                .toList(),
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d), child: const Text('取消')),
          FilledButton(
            onPressed: () async {
              final src0 = st._origBytes ?? baseBytes; // v1349：永远从无字底图合成
              final name = nameCtl.text.trim();
              if (name.isEmpty) {
                ScaffoldMessenger.of(ctx).showSnackBar(
                    const SnackBar(content: Text('请先填书名')));
                return; // v1358：空书名不关闭对话框
              }
              try {
                st._coverName = name;
                st._coverAuthor = authorCtl.text.trim();
                st._coverFont = font;
                final out = await composeCoverText(src0,
                    name, authorCtl.text.trim(),
                    fontFamily: font,
                    charOffsets: st._charOffsets,
                    authorOffset: st._authorOffset,
                    charScales: st._charScales,
                    authorScale: st._authorScale);
                if (out != null) {
                  // v1378：合成实际用的底图记为_origBytes——历史缓存路径_origBytes漏赋值时重合成静默return实证
                  if (st._origBytes == null) st._origBytes = src0;
                  st._charCenters = out.charCenters; // v1382：圈套真实字位
                  st._authorCenter = out.authorCenter;
                  // v1393：偏移永久累计不清——清了下次重合成字弹回基础位（用户"会弹回"实证）
                  st.updateBytes(out.bytes);
                  onDone?.call(); // 合成后刷新全屏预览
                } else {
                  ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(
                      content: Text('合成失败：底图异常')));
                }
              } catch (ex) {
                ScaffoldMessenger.of(ctx).showSnackBar(
                    SnackBar(content: Text('合成异常：$ex')));
              }
              if (ctx.mounted) Navigator.pop(d);
            },
            child: const Text('合成'),
          ),
        ],
      ),
    ),
    );
  }

  /// 合成封面文字：鎏金渐变+黑描边+阴影（v1349重写——多轮补丁踩踏后推倒重来）
  Future<Size>? _imgSizeF;
  Future<Size> _decodeSize(Uint8List b) async {
    final c = await ui.instantiateImageCodec(b);
    final f = await c.getNextFrame();
    return Size(f.image.width.toDouble(), f.image.height.toDouble());
  }

  /// v1367：调字布局——合成图铺底+每字可拖块（图内坐标系），拖动重合成
  Widget _buildAdjustLayout(void Function(void Function()) setD2) {
    _imgSizeF ??= _decodeSize(_bytes!);
    return FutureBuilder<Size>(
      future: _imgSizeF,
      builder: (ctx, snap) {
        if (!snap.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        return _adjustInner(snap.data!.width, snap.data!.height, setD2);
      },
    );
  }

  DateTime? _lastScaleTap; // v1392：缩放防抖
  Future<void> _rescaleCompose(
      void Function(void Function()) setD2) async {
    final now = DateTime.now();
    if (_lastScaleTap != null &&
        now.difference(_lastScaleTap!) < const Duration(milliseconds: 400)) {
      return; // 400ms防抖：连点合并，最后一次生效
    }
    _lastScaleTap = now;
    final src0 = _origBytes ?? _bytes;
    if (src0 == null) return;
    try {
      final out = await composeCoverText(src0, _coverName, _coverAuthor,
          fontFamily: _coverFont,
          charOffsets: _charOffsets,
          authorOffset: _authorOffset,
          charScales: _charScales,
          authorScale: _authorScale);
      if (out != null) {
        _charCenters = out.charCenters;
        _authorCenter = out.authorCenter;
        // v1393：偏移永久累计不清
        setState(() => _bytes = out.bytes);
        setD2(() {});
      }
    } catch (_) {}
  }

  Widget _adjustInner(double imgW, double imgH,
      void Function(void Function()) setD2) {
    return LayoutBuilder(builder: (ctx, box) {
      final scale = box.maxWidth / imgW; // fitWidth缩放比
      final dispH = imgH * scale;
      final chars = _coverName.split('');
      final nameSize = (imgW / 2.2).clamp(0.0, (imgH * 0.66) / chars.length);
      final nameX = imgW * 0.585;
      final y0 = imgH * 0.055;
      final lineH = nameSize * 1.08;
      return SizedBox(
        height: dispH,
        child: Stack(children: [
          // v1372：Image劫持Stack hit-test（沙盒drag_test复现实锤）——包IgnorePointer放行拖块手势
          Positioned.fill(
            child: IgnorePointer(
                child: Center(
                    child: Image.memory(_bytes ?? Uint8List(0),
                        fit: BoxFit.fitWidth))),
          ),
          for (var i = 0; i < chars.length; i++)
            Positioned(
              // v1382：圈=compose返回的真实字中心+offset增量
              // v1393：centers已含偏移，不再叠加（双计=拖动后跳位）
              left: (i < _charCenters.length
                          ? _charCenters[i].dx
                          : nameX) *
                  scale -
                  30,
              top: (i < _charCenters.length
                          ? _charCenters[i].dy
                          : y0 + i * lineH + 0.7 * nameSize) *
                  scale -
                  30,
              // v1375：Listener raw pointer——不走手势竞技场无18px slop死区，
              // 按下即动（GestureDetector完整结构沙盒全绿但真机无效，换最底层方案）
              child: Listener(
                onPointerDown: (e) {
                  _dragLast[i] = e.position;
                  AppState.instance.apiLog('调字按下 #$i pos=${e.position}');
                },
                onPointerMove: (e) {
                  final last = _dragLast[i] ?? e.position;
                  _dragLast[i] = e.position;
                  final d = e.position - last;
                  if (d.distance < 0.5) return;
                  // v1376：setD2刷新Dialog（state.setState只刷楼层=金圈不跟手根因）
                  setD2(() {
                    final dd = Offset(d.dx / scale, d.dy / scale);
                    if (_lockName) {
                      // v1379：书名锁开——4字绑定一起移
                      for (var j = 0; j < chars.length; j++) {
                        _charOffsets[j] =
                            (_charOffsets[j] ?? Offset.zero) + dd;
                      }
                    } else {
                      _charOffsets[i] = (_charOffsets[i] ?? Offset.zero) + dd;
                    }
                    if (_lockAuthor) _authorOffset += dd; // 作者锁开=跟书名联动
                  });
                },
                onPointerUp: (_) async {
                  _dragLast[i] = null;
                  AppState.instance
                      .apiLog('调字重合成 #$i off=${_charOffsets[i]}');
                  // v1378：底图空时兜底用当前图重画（字重复叠加劣于静默无反应）
                  final src0 = _origBytes ?? _bytes;
                  if (src0 == null) {
                    AppState.instance.apiLog('重合成跳过：无底图');
                    return;
                  }
                  try {
                    final out = await composeCoverText(src0,
                        _coverName, _coverAuthor,
                        fontFamily: _coverFont,
                        charOffsets: _charOffsets,
                        authorOffset: _authorOffset,
                        charScales: _charScales,
                        authorScale: _authorScale);
                    if (out != null) {
                      _charCenters = out.charCenters; // v1382：圈跟新字位
                      _authorCenter = out.authorCenter;
                      // v1393：偏移永久累计不清（弹回根因）
                      setState(() => _bytes = out.bytes); // 楼层图更新
                      setD2(() {}); // v1376：Dialog也刷（Image读_bytes新值）
                    } else {
                      AppState.instance.apiLog('重合成返回空');
                    }
                  } catch (ex) {
                    AppState.instance.apiLog('重合成异常：$ex');
                  }
                },
                child: Stack(clipBehavior: Clip.none, children: [
                  Container(
                    width: 60,
                    height: 60,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.white.withOpacity(0.12),
                      border: Border.all(
                          color: const Color(0xFFFFD700), width: 1.5),
                    ),
                    child: Text(chars[i],
                        style: TextStyle(
                            fontSize: 22,
                            color: const Color(0xFFFFD700),
                            fontFamily:
                                _coverFont.isEmpty ? null : _coverFont)),
                  ),
                  // v1382：单字缩放角标——左上减/右上加
                  Positioned(
                    top: -12, left: -12,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () async {
                        setD2(() => _charScales[i] =
                            ((_charScales[i] ?? 1.0) - 0.1).clamp(0.5, 2.0));
                        await _rescaleCompose(setD2); // v1392：点击即重合成
                      },
                      child: Container(
                        width: 30, height: 30,
                        alignment: Alignment.center,
                        decoration: const BoxDecoration(
                            shape: BoxShape.circle,
                            color: Color(0xFF6B5A2E)),
                        child: const Text('-',
                            style: TextStyle(
                                color: Colors.white, fontSize: 20, height: 1)),
                      ),
                    ),
                  ),
                  Positioned(
                    top: -12, right: -12,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () async {
                        setD2(() => _charScales[i] =
                            ((_charScales[i] ?? 1.0) + 0.1).clamp(0.5, 2.0));
                        await _rescaleCompose(setD2); // v1392：点击即重合成
                      },
                      child: Container(
                        width: 30, height: 30,
                        alignment: Alignment.center,
                        decoration: const BoxDecoration(
                            shape: BoxShape.circle,
                            color: Color(0xFF6B5A2E)),
                        child: const Text('+',
                            style: TextStyle(
                                color: Colors.white, fontSize: 20, height: 1)),
                      ),
                    ),
                  ),
                ]),
              ),
            ),
          // v1376：作者列“某某著”独立拖块（青圈44px区分书名金圈）
          // v1382：作者块=compose返回锚点（列底部下方不压字）+36px小圈
          Positioned(
            // v1393：authorCenter已含偏移
            left: _authorCenter.dx * scale - 18,
            top: _authorCenter.dy * scale - 18,
            child: Listener(
              onPointerDown: (e) {
                _aDragLast[0] = e.position;
                AppState.instance.apiLog('作者按下 pos=${e.position}');
              },
              onPointerMove: (e) {
                final last = _aDragLast[0] ?? e.position;
                _aDragLast[0] = e.position;
                final d = e.position - last;
                if (d.distance < 0.5) return;
                setD2(() {
                  final dd = Offset(d.dx / scale, d.dy / scale);
                  _authorOffset += dd;
                  if (_lockAuthor) {
                    // v1379：作者锁开=书名跟作者联动
                    for (var j = 0; j < chars.length; j++) {
                      _charOffsets[j] = (_charOffsets[j] ?? Offset.zero) + dd;
                    }
                  }
                });
              },
              onPointerUp: (_) async {
                _aDragLast[0] = null;
                AppState.instance
                    .apiLog('作者重合成 off=$_authorOffset');
                final src0 = _origBytes ?? _bytes; // v1378：同书名兜底
                if (src0 == null) {
                  AppState.instance.apiLog('作者重合成跳过：无底图');
                  return;
                }
                try {
                  final out = await composeCoverText(src0,
                      _coverName, _coverAuthor,
                      fontFamily: _coverFont,
                      charOffsets: _charOffsets,
                      authorOffset: _authorOffset,
                      charScales: _charScales,
                      authorScale: _authorScale);
                  if (out != null) {
                    _charCenters = out.charCenters;
                    _authorCenter = out.authorCenter;
                    // v1393：偏移永久累计不清
                    setState(() => _bytes = out.bytes);
                    setD2(() {});
                  } else {
                    AppState.instance.apiLog('作者重合成返回空');
                  }
                } catch (ex) {
                  AppState.instance.apiLog('作者重合成异常：$ex');
                }
              },
              child: Stack(clipBehavior: Clip.none, children: [
                Container(
                  width: 36,
                  height: 36,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.white.withOpacity(0.12),
                    border:
                        Border.all(color: const Color(0xFF7FD4C8), width: 1.5),
                  ),
                  child: Text(_coverAuthor.isEmpty ? '著' : _coverAuthor[0],
                      style: const TextStyle(
                          fontSize: 13, color: Color(0xFF7FD4C8))),
                ),
                Positioned(
                  top: -11, left: -11,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () async {
                      setD2(() =>
                          _authorScale = (_authorScale - 0.1).clamp(0.5, 2.0));
                      await _rescaleCompose(setD2);
                    },
                    child: Container(
                      width: 26, height: 26,
                      alignment: Alignment.center,
                      decoration: const BoxDecoration(
                          shape: BoxShape.circle, color: Color(0xFF2E5A55)),
                      child: const Text('-',
                          style: TextStyle(
                              color: Colors.white, fontSize: 14, height: 1)),
                    ),
                  ),
                ),
                Positioned(
                  top: -11, right: -11,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () async {
                      setD2(() =>
                          _authorScale = (_authorScale + 0.1).clamp(0.5, 2.0));
                      await _rescaleCompose(setD2);
                    },
                    child: Container(
                      width: 26, height: 26,
                      alignment: Alignment.center,
                      decoration: const BoxDecoration(
                          shape: BoxShape.circle, color: Color(0xFF2E5A55)),
                      child: const Text('+',
                          style: TextStyle(
                              color: Colors.white, fontSize: 14, height: 1)),
                    ),
                  ),
                ),
              ]),
            ),
          ),
        ]),
      );
    });
    }


  /// 合成封面：竖排鎏金书名+作者“某某著”竖排小字（参考正版网文封面布局）
}

/// v1338：pollinations插图（野生API直连URL，CachedNetworkImage）
Widget _chatImage(BuildContext context, String rawSrc) {
    var url = rawSrc.contains('%') ? rawSrc : Uri.encodeFull(rawSrc);
    // v1363：野生API缺尺寸参数时默认竖版640x960（pollinations缺参默认1024方图
    // ——竖版构图要求下方图观感=被拉长，实测证显示层不拉伸、是生成分辨率方的）
    if (url.contains('image.pollinations.ai') &&
        !url.contains('width=') &&
        !url.contains('height=')) {
      url = '$url?width=640&height=960&nologo=true';
    }
    return GestureDetector(
      onTap: () {
        showDialog(
          context: context,
          builder: (d) => Dialog.fullscreen(
            backgroundColor: Colors.black,
            child: Column(
              children: [
                Expanded(
                  child: GestureDetector(
                    onTap: () => Navigator.pop(d),
                    child: Center(
                      child: InteractiveViewer(
                          child: CachedNetworkImage(imageUrl: url)),
                    ),
                  ),
                ),
                SafeArea(
                  child: TextButton.icon(
                    icon: const Icon(Icons.save_alt, color: Colors.white70),
                    label: const Text('保存到Download',
                        style: TextStyle(color: Colors.white70)),
                    onPressed: () async {
                      try {
                        final rs = await http.get(Uri.parse(url))
                            .timeout(const Duration(seconds: 60));
                        final dir = Directory('/storage/emulated/0/Download');
                        if (!dir.existsSync()) dir.createSync(recursive: true);
                        final f = File(
                            '${dir.path}/chat_img_${DateTime.now().millisecondsSinceEpoch}.jpg');
                        await f.writeAsBytes(rs.bodyBytes);
                        ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text('已保存：${f.path}')));
                      } catch (ex) {
                        ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('保存失败（需存储授权）')));
                      }
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        // v1341：cached_network_image——磁盘缓存+稳定下载（Image.network在
        // ListView流式重建下下载流不可控，全屏能看气泡转圈实证）；fitWidth原图比例
        child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: CachedNetworkImage(
          imageUrl: url,
          fit: BoxFit.fitWidth,
          placeholder: (c, u) => Container(
            width: 260,
            height: 170,
            color: const Color(0xFFEFE8D8),
            alignment: Alignment.center,
            child: const SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
          ),
          errorWidget: (c, u, e) => Container(
            width: 260,
            height: 56,
            color: const Color(0xFFEFE8D8),
            alignment: Alignment.center,
            child: const Text('🖼 插图加载失败（点重答再试）',
                style: TextStyle(fontSize: 12, color: Color(0xFF9B8F7A))),
          ),
        ),
      ),
      ),
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

  /// v1367：逐字字形检测——志莽行书缺字渲染空白（cmap有映射glyph空，fallback不触发），
  /// 离屏试画检查墨迹，空白字回退文楷画
  Future<bool> glyphHasInk(
      String ch, double size, String? ff, List<String>? fb) async {
    final rec = ui.PictureRecorder();
    final c = ui.Canvas(rec);
    c.drawRect(const Rect.fromLTWH(0, 0, 160, 160),
        ui.Paint()..color = const Color(0xFF010101));
    final tp = TextPainter(
        text: TextSpan(
            text: ch,
            style: TextStyle(
                fontSize: size,
                fontFamily: ff,
                fontFamilyFallback: fb,
                color: Colors.white)),
        textDirection: TextDirection.ltr)
      ..layout();
    tp.paint(c, const ui.Offset(20, 20));
    final img = await rec.endRecording().toImage(160, 160);
    final bd = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
    final px = bd!.buffer.asUint32List();
    var ink = 0;
    for (final v in px) {
      final r = (v >> 16) & 0xFF, g = (v >> 8) & 0xFF, b = v & 0xFF;
      if (r > 60 || g > 60 || b > 60) ink++; // 非背景=有墨
    }
    return ink > 40;
  }

  Future<CoverComposeResult?> composeCoverText(
      Uint8List baseBytes, String bookName, String author,
      {String fontFamily = '',
      Map<int, Offset> charOffsets = const {},
      Offset authorOffset = Offset.zero,
      Map<int, double> charScales = const {},
      double authorScale = 1.0}) async {
    if (bookName.isEmpty) return null;
    final codec = await ui.instantiateImageCodec(baseBytes);
    final frame = await codec.getNextFrame();
    final img = frame.image;
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    canvas.drawImage(img, ui.Offset.zero, ui.Paint());

    // ===== 书名竖排（靠右列） =====
    final chars = bookName.split('');
    final nameSize =
        (img.width / 2.2).clamp(0.0, (img.height * 0.66) / chars.length);
    // v1369：书名+作者组整体居中（参考图神通者布局——组合宽=nameSize+作者列，中心0.5w）
    final nameX = img.width * 0.585;
    final y0 = img.height * 0.055;
    final lineH = nameSize * 1.08;
    final ff = fontFamily.isEmpty ? null : fontFamily;
    final fallback = fontFamily.isEmpty ? null : const ['WenKai'];
    // 鎏金渐变跨整列
    final grad = ui.Paint()
      ..shader = ui.Gradient.linear(
          ui.Offset(nameX - nameSize / 2, y0),
          ui.Offset(nameX - nameSize / 2, y0 + chars.length * lineH),
          const [
            Color(0xFFFFF3B0),
            Color(0xFFFFD700),
            Color(0xFFB8860B),
          ], [0.0, 0.5, 1.0], TileMode.clamp);
    var y = y0;
    final centers = <Offset>[]; // v1382：各字真实视觉中心
    for (var i = 0; i < chars.length; i++) {
      final ch = chars[i];
      final sc = charScales[i] ?? 1.0; // v1382：单字缩放
      // v1367：逐字检测——行书等覆盖小字体缺字空白→回退文楷
      var useFont = ff;
      if (ff != null && ff != 'WenKai') {
        final hasInk = await glyphHasInk(ch, nameSize * sc, ff, fallback);
        if (!hasInk) useFont = 'WenKai';
      }
      // 阴影层
      final sh = TextPainter(
          text: TextSpan(
              text: ch,
              style: TextStyle(
                  fontSize: nameSize * sc,
                  fontFamily: useFont,
                  fontWeight: FontWeight.w900,
                  foreground: ui.Paint()
                    ..color = Colors.black.withOpacity(0.6)
                    ..maskFilter =
                        const ui.MaskFilter.blur(ui.BlurStyle.normal, 8))),
          textDirection: TextDirection.ltr)
        ..layout();
      sh.paint(canvas, ui.Offset(nameX - sh.width / 2 + 3, y + 4));
      // 渐变金字层
      final tp = TextPainter(
          text: TextSpan(
              text: ch,
              style: TextStyle(
                  fontSize: nameSize * sc,
                  fontFamily: useFont,
                  fontWeight: FontWeight.w900,
                  foreground: grad)),
          textDirection: TextDirection.ltr)
        ..layout();
      final off = charOffsets[i] ?? Offset.zero;
      tp.paint(canvas,
          ui.Offset(nameX - tp.width / 2 + off.dx, y + off.dy));
      centers.add(Offset(
          nameX + off.dx, y + tp.height / 2 + off.dy)); // v1382：真实视觉中心
      y += lineH;
    }

    // ===== 作者竖排“某某著”（书名左侧，末字金圈印章） =====
    var authorCenter = Offset(img.width * 0.7, img.height * 0.25);
    final aCenters = <Offset>[];
    if (author.isNotEmpty) {
      final aChars = '$author著'.split('');
      final aSize = nameSize * 0.30;
      // v1370：作者在书名右上（参考图——竖排小字贴书名右缘顶部起排）
      final ax = nameX + nameSize * 0.60;
      var ay = y0 + nameSize * 0.08;
      final ringR = aSize * 0.78;
      for (var i = 0; i < aChars.length; i++) {
        final isLast = i == aChars.length - 1;
        var aUseFont = ff;
        if (ff != null && ff != 'WenKai') {
          final hasInk =
              await glyphHasInk(aChars[i], aSize, ff, fallback);
          if (!hasInk) aUseFont = 'WenKai';
        }
        final tp = TextPainter(
            text: TextSpan(
                text: aChars[i],
                style: TextStyle(
                    fontSize: isLast
                        ? aSize * 0.62 * authorScale
                        : aSize * authorScale,
                    fontFamily: aUseFont,
                    fontWeight: FontWeight.w600,
                    color: const Color(0xFFFFE9A8),
                    shadows: [
                      Shadow(
                          blurRadius: 4,
                          color: Colors.black.withOpacity(0.85)),
                    ])),
            textDirection: TextDirection.ltr)
          ..layout();
        final offA = authorOffset; // v1377b：整列一起移动
        if (isLast) {
          // 印章圆圈
          canvas.drawCircle(
              ui.Offset(ax + offA.dx, ay + ringR * 0.55 + offA.dy),
              ringR,
              ui.Paint()
                ..color = const Color(0xFFB8860B)
                ..style = ui.PaintingStyle.stroke
                ..strokeWidth = aSize * 0.09);
        }
        tp.paint(canvas,
            ui.Offset(ax - tp.width / 2 + offA.dx, ay + offA.dy));
        aCenters.add(Offset(ax + offA.dx, ay + tp.height / 2 + offA.dy));
        ay += isLast ? aSize * 0.9 : aSize * 1.18;
      }
      // v1382：作者拖块中心=列底部下方（不压名字）
      authorCenter = Offset(ax + authorOffset.dx, ay + aSize * 1.2);
    }

    AppState.instance.apiLog(
        '合成 fontFamily=${fontFamily.isEmpty ? "系统" : fontFamily} 字数=${bookName.length} 竖排');
    final pic = recorder.endRecording();
    final out = await pic.toImage(img.width, img.height);
    final bd = await out.toByteData(format: ui.ImageByteFormat.png);
    img.dispose();
    if (bd == null) return null;
    return CoverComposeResult(bd.buffer.asUint8List(), centers, authorCenter);
  }

/// v1382：封面合成结果——bytes+各字真实视觉中心（TextPainter实测，圈套字零偏差）
class CoverComposeResult {
  final Uint8List bytes;
  final List<Offset> charCenters;
  final Offset authorCenter;
  CoverComposeResult(this.bytes, this.charCenters, this.authorCenter);
}
