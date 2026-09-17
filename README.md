# 网文拆解器 Flutter版

长篇网文结构分析与创作工具，使用Flutter重写。

## 技术栈

- Flutter 3.47.0 + Dart 3.13.0
- Provider 状态管理
- AGP 8.13.0 + Gradle 8.14.3 + Kotlin 2.2.20 + JDK 21
- 编译模式：内存限制1.5G + no-daemon

## 仓库结构

```
lib/
├── main.dart                     # 入口
├── state/app_state.dart          # 全局状态管理
├── models/                       # 数据模型
│   ├── api_config.dart
│   ├── arc.dart
│   ├── chapter.dart
│   ├── preset.dart
│   ├── scene.dart
│   ├── world_book.dart
│   └── writing.dart
├── services/                     # 业务服务
│   ├── api_service.dart          # API调用（OpenAI兼容/Claude原生）
│   ├── chapter_parser.dart       # 章节解析
│   ├── cloud_sync_service.dart   # Supabase云同步
│   ├── file_picker_service.dart  # 文件选择
│   └── storage_service.dart      # 本地存储
├── pages/                        # 页面
│   ├── home_page.dart
│   ├── scan_page.dart
│   ├── scene_page.dart
│   ├── analysis_page.dart
│   ├── worldbook_page.dart
│   ├── writing_page.dart
│   ├── detection_page.dart
│   └── chapter_reader_page.dart
├── widgets/                      # 组件
│   ├── api_config_panel.dart
│   ├── api_log_widget.dart
│   ├── chapter_list_widget.dart
│   └── cloud_sync_panel.dart
└── utils/                        # 工具
    ├── chinese_number.dart
    ├── encoding_detector.dart
    ├── json_repair.dart
    └── prompt_builder.dart
```

## 编译

```bash
# 需要Flutter SDK + JDK 21 + Android SDK
flutter pub get
flutter build apk --release
```

## 与v318 HTML版的关系

Flutter版是对HTML版（luckpala/novel-analyzer）的原生重写，存储格式和云同步协议与v318兼容互通。

## Designed by luckpala
