/// 章节模型
class Chapter {
  String title;
  String content;
  int wordCount;
  int number; // 章节编号

  Chapter({
    required this.title,
    required this.content,
    this.wordCount = 0,
    this.number = 0,
  });

  factory Chapter.fromJson(Map<String, dynamic> json) {
    return Chapter(
      title: json['title'] ?? '',
      content: json['content'] ?? '',
      wordCount: json['wordCount'] ?? (json['content'] ?? '').length,
      number: json['number'] ?? 0,
    );
  }

  Map<String, dynamic> toJson() => {
    'title': title,
    'content': content,
    'wordCount': wordCount,
    'number': number,
  };
}
