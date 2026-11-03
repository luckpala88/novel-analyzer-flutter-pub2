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
                    : '野生',
            enabled: state.chatImageGen,
            onTap: state.chatImageGen
                ? () {
                    final order = ['silicon', 'cf', 'pollination'];
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
                  child: _richContent(state, m.content),
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
  Widget _richContent(AppState state, String content) {
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
    final imgRe = RegExp(
        '<img\\s[^>]*src\\s*=\\s*"?(https?://[^"\\s>]+)[^>]*>',
        caseSensitive: false);
    if (imgRe.hasMatch(content)) {
      final parts = <Widget>[];
      var cursor = 0;
      for (final m in imgRe.allMatches(content)) {
        if (m.start > cursor) {
          final txt = content.substring(cursor, m.start).trim();
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
                bookName: bookName));
        cursor = m.end;
      }
      if (cursor < content.length) {
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
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d), child: const Text('取消')),
          FilledButton(
            onPressed: () {
              state.setChatSiliconKey(siliconCtl.text);
              state.setChatCf(cfKeyCtl.text, cfAccCtl.text);
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
  final String engine; // v1348：'silicon'|'cf'
  final String skey;
  final String cfKey;
  final String cfAccount;
  final String bookName; // v1344：自动叠封面书名
  const _SiliconImage(
      {required this.src,
      required this.engine,
      required this.skey,
      this.cfKey = '',
      this.cfAccount = '',
      this.bookName = ''});
  @override
  State<_SiliconImage> createState() => _SiliconImageState();
}

class _SiliconImageState extends State<_SiliconImage> {
  static final Map<String, Uint8List> _cache = {};
  Uint8List? _bytes;
  Uint8List? _origBytes; // v1349：无字原底图（合成输入固定用它）
  // v1367：封面调字——合成参数留存+每字偏移+调字模式
  String _coverName = '';
  String _coverAuthor = '';
  String _coverFont = '';
  final Map<int, Offset> _charOffsets = {};
  final Map<int, Offset?> _dragLast = {}; // v1375：拖动起点（pointer坐标）
  bool _adjustMode = false;
  String? _err;
  static String? _imgDir; // v1343：磁盘缓存目录（prompt+size命名，永久复用防重复烧token）

  Future<String> _diskPath(String key) async {
    final dir = _imgDir ??= await _ensureDir();
    final safe = key.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '').substring(0, 80);
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
    _load();
  }

  /// v1344：封面合成后更新显示+落盘
  Future<void> updateBytes(Uint8List b) async {
    _bytes = b;
    setState(() {});
    try {
      final diskPath = await _diskPath('${widget.src}_composed');
      await File(diskPath).writeAsBytes(b);
    } catch (_) {}
  }

  Future<void> _load() async {
    final src = widget.src;
    if (_cache.containsKey(src)) {
      setState(() => _bytes = _cache[src]);
      return;
    }
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
      final key = '${widget.engine}|$prompt|$size'; // v1352：key含引擎——防CF/硅基缓存互相覆盖
      if (_cache.containsKey(key)) {
        setState(() => _bytes = _cache[key]);
        return;
      }
      // v1343：磁盘缓存命中——切引擎/重启APP不重复生成（防历史楼层重烧token）
      // v1344：合成版优先（封面标签叠过字后直接读合成版）
      final composedPath = await _diskPath('${key}_composed');
      final composedFile = File(composedPath);
      final diskPath = await _diskPath(key); // v1373b：提前声明（composed分支也要读无字底图）
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
      Uint8List genBytes;
      if (widget.engine == 'cf') {
        // v1348：CF Workers AI flux-1-schnell（固定1024方图）
        final ckey = widget.cfKey;
        final acc = widget.cfAccount;
        if (ckey.isEmpty || acc.isEmpty) {
          setState(() => _err = '点顶栏🔑填CF Token+账户ID');
          return;
        }
        final cbody = jsonEncode({'prompt': prompt});
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
      var finalBytes = genBytes;
      // v1344：封面标签自动叠书名+作者（prompt含cover触发，AI画不了汉字的正解）
      if (prompt.toLowerCase().contains('cover') && widget.bookName.isNotEmpty) {
        try {
          final composed = await composeCoverText(
              finalBytes, widget.bookName, 'luckpala');
          if (composed != null) finalBytes = composed;
        } catch (_) {}
      }
      if (mounted) setState(() => _bytes = finalBytes);
    } catch (ex) {
      if (mounted) setState(() => _err = '生成超时/失败');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_err != null) {
      return Container(
        width: 260,
        height: 56,
        color: const Color(0xFFEFE8D8),
        alignment: Alignment.center,
        child: Text('🖼 $_err',
            style: const TextStyle(fontSize: 12, color: Color(0xFF9B8F7A))),
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
                child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                TextButton.icon(
                  icon: const Icon(Icons.text_fields, color: Colors.white70),
                  label: const Text('叠封面文字',
                      style: TextStyle(color: Colors.white70)),
                  onPressed: () => _coverTextDialog(context, b, this,
                      onDone: () => setD2(() {})),
                ),
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
          child: Image.memory(b, fit: BoxFit.fitWidth),
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
    const fontNames = {'': '黑体', 'WenKai': '楷书', 'XingShu': '行书', 'CaoShu': '草书'};
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
                    fontFamily: font, charOffsets: st._charOffsets);
                if (out != null) {
                  st.updateBytes(out);
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
              left: (nameX + (_charOffsets[i]?.dx ?? 0)) * scale - 30,
              top: (y0 + i * lineH + nameSize / 2 +
                      (_charOffsets[i]?.dy ?? 0)) *
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
                    final cur = _charOffsets[i] ?? Offset.zero;
                    _charOffsets[i] =
                        cur + Offset(d.dx / scale, d.dy / scale);
                  });
                },
                onPointerUp: (_) async {
                  _dragLast[i] = null;
                  AppState.instance
                      .apiLog('调字重合成 #$i off=${_charOffsets[i]}');
                  if (_origBytes == null) return;
                  final out = await composeCoverText(_origBytes!,
                      _coverName, _coverAuthor,
                      fontFamily: _coverFont, charOffsets: _charOffsets);
                  if (out != null) {
                    setState(() => _bytes = out); // 楼层图更新
                    setD2(() {}); // v1376：Dialog也刷（Image读_bytes新值）
                  }
                },
                child: Container(
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
                          fontFamily: _coverFont.isEmpty ? null : _coverFont)),
                ),
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

  Future<Uint8List?> composeCoverText(
      Uint8List baseBytes, String bookName, String author,
      {String fontFamily = '', Map<int, Offset> charOffsets = const {}}) async {
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
    for (final ch in chars) {
      // v1367：逐字检测——行书等覆盖小字体缺字空白→回退文楷
      var useFont = ff;
      if (ff != null && ff != 'WenKai') {
        final hasInk = await glyphHasInk(ch, nameSize, ff, fallback);
        if (!hasInk) useFont = 'WenKai';
      }
      // 阴影层
      final sh = TextPainter(
          text: TextSpan(
              text: ch,
              style: TextStyle(
                  fontSize: nameSize,
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
                  fontSize: nameSize,
                  fontFamily: useFont,
                  fontWeight: FontWeight.w900,
                  foreground: grad)),
          textDirection: TextDirection.ltr)
        ..layout();
      final off = charOffsets[chars.indexOf(ch)] ?? Offset.zero;
      tp.paint(canvas,
          ui.Offset(nameX - tp.width / 2 + off.dx, y + off.dy));
      y += lineH;
    }

    // ===== 作者竖排“某某著”（书名左侧，末字金圈印章） =====
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
                    fontSize: isLast ? aSize * 0.62 : aSize,
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
        if (isLast) {
          // 印章圆圈
          canvas.drawCircle(
              ui.Offset(ax, ay + ringR * 0.55),
              ringR,
              ui.Paint()
                ..color = const Color(0xFFB8860B)
                ..style = ui.PaintingStyle.stroke
                ..strokeWidth = aSize * 0.09);
        }
        tp.paint(canvas, ui.Offset(ax - tp.width / 2, ay));
        ay += isLast ? aSize * 0.9 : aSize * 1.18;
      }
    }

    AppState.instance.apiLog(
        '合成 fontFamily=${fontFamily.isEmpty ? "系统" : fontFamily} 字数=${bookName.length} 竖排');
    final pic = recorder.endRecording();
    final out = await pic.toImage(img.width, img.height);
    final bd = await out.toByteData(format: ui.ImageByteFormat.png);
    img.dispose();
    return bd?.buffer.asUint8List();
  }
