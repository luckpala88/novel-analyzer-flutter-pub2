/// v833：AI聊天会话模型——多会话+消息持久化（书目录chat_sessions.json）
class ChatMessage {
  String role; // 'user' / 'assistant'
  String content;
  int ts; // 毫秒时间戳

  ChatMessage({required this.role, required this.content, required this.ts});

  Map<String, dynamic> toJson() => {'role': role, 'content': content, 'ts': ts};

  factory ChatMessage.fromJson(Map<String, dynamic> j) => ChatMessage(
        role: (j['role'] ?? 'user').toString(),
        content: (j['content'] ?? '').toString(),
        ts: (j['ts'] as num?)?.toInt() ?? 0,
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
