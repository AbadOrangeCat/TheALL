# TheAll

[English](README.md) · 简体中文

TheAll **0.1.3** 是面向 Claude Code 和 Codex 的 macOS AI 工作台，提供原生聊天输入、模型下拉选择、工作区、标签页和分屏。

## 使用

1. 打开新标签页，选择工作文件夹和 Claude / OpenAI。
2. 使用已保存的连接，或输入 API Key 和可选的自定义 Base URL；连接保存在 macOS Keychain 中。
3. 在原生输入框中聊天，用下方的下拉框选择模型。切换模型保留当前聊天和草稿。
4. 点击聊天区最下方的文件夹路径切换工作目录；运行中的任务结束后即可操作。

聊天显示回复、进度和提供商返回的思考内容，隐藏常规工具记录。工具操作自动执行，需要你回答的问题仍会显示。正式回答完成后，思考和过程说明自动折叠，可分别点击展开。用户提问使用独立背景色；工作区从首次提问自动命名。自动更新暂未配置。

## 本地构建

需要 macOS 14+、Xcode、XcodeGen，以及所选后端的 Claude Code 或 Codex CLI。工程、应用 target、模块与源码目录统一为 `TheAll`，测试 target 为 `TheAllTests`。

```bash
# 仅缺少 Ghostty 编译产物时运行
./scripts/build-vendor.sh
xcodegen generate
# 仅在没有 Local.xcconfig 时初始化一次，之后保留该签名身份
bash scripts/setup-local-signing.sh
xcodebuild -project TheAll.xcodeproj -scheme TheAll -configuration Debug build
```

生成的应用为 `TheAll.app`，Debug 窗口显示 **TheAll dev**。应用不支持热更新，重新编译后需手动退出旧实例再打开新构建。

[AI 聊天说明](docs/ai-terminals.md) · [构建说明](docs/build.md) · [架构](docs/architecture.md)

## 许可

源码公开不代表授予通用的使用、修改或再分发许可，详见 [`LICENSE`](LICENSE)。单独授予的书面许可及第三方组件各自的许可证继续适用。
