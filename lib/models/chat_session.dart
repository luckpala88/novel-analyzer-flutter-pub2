/// v833：AI聊天会话模型——多会话+消息持久化（书目录chat_sessions.json）
/// v838：附件支持——图片base64（vision）+文本类附件（内容直接注入）
class ChatAttachment {
  String name;
  String mime; // image/png, image/jpeg, text/plain...
  String data; // 图片=base64裸串；文本类=UTF8内容
  bool isImage;

  ChatAttachment({
    required this.name,
    required this.mime,
    required this.data,
    required this.isImage,
  });

  Map<String, dynamic> toJson() =>
      {'name': name, 'mime': mime, 'data': data, 'isImage': isImage};

  factory ChatAttachment.fromJson(Map<String, dynamic> j) => ChatAttachment(
        name: (j['name'] ?? '').toString(),
        mime: (j['mime'] ?? '').toString(),
        data: (j['data'] ?? '').toString(),
        isImage: j['isImage'] == true,
      );
}

class ChatMessage {
  String role; // 'user' / 'assistant'
  String content;
  int ts; // 毫秒时间戳
  List<ChatAttachment> attachments; // v838

  ChatMessage({
    required this.role,
    required this.content,
    required this.ts,
    List<ChatAttachment>? attachments,
  }) : attachments = attachments ?? [];

  Map<String, dynamic> toJson() => {
        'role': role,
        'content': content,
        'ts': ts,
        if (attachments.isNotEmpty)
          'attachments': attachments.map((a) => a.toJson()).toList(),
      };

  factory ChatMessage.fromJson(Map<String, dynamic> j) => ChatMessage(
        role: (j['role'] ?? 'user').toString(),
        content: (j['content'] ?? '').toString(),
        ts: (j['ts'] as num?)?.toInt() ?? 0,
        attachments: ((j['attachments'] as List?) ?? [])
            .map((e) => ChatAttachment.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

class ChatSession {
  String id;
  String title;
  List<ChatMessage> messages;
  int createdAt;

  ChatSession({
    required this.id,
    required this.title,
    required this.messages,
    required this.createdAt,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'createdAt': createdAt,
        'messages': messages.map((m) => m.toJson()).toList(),
      };

  factory ChatSession.fromJson(Map<String, dynamic> j) => ChatSession(
        id: (j['id'] ?? '').toString(),
        title: (j['title'] ?? '新会话').toString(),
        createdAt: (j['createdAt'] as num?)?.toInt() ?? 0,
        messages: ((j['messages'] as List?) ?? [])
            .map((e) => ChatMessage.fromJson(e as Map<String, dynamic>))
            .toList(),
      );

  static List<ChatSession> listFromJson(List raw) =>
      raw.map((e) => ChatSession.fromJson(e as Map<String, dynamic>)).toList();
}
