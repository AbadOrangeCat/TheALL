<p align="center">
  <img src="landing-page/assets/logo@2x.png" width="96" height="96" alt="TheAll 标志" />
</p>

<h1 align="center">TheAll</h1>
<p align="center"><strong>把 Claude Code 和 Codex，放进同一个 Mac 与 Windows 工作台。</strong><br />项目、AI 对话和模型集中管理。离开电脑，也能在手机上继续。</p>

<p align="center">
  <a href="https://github.com/AbadOrangeCat/TheALL/releases/tag/v0.1.9"><img alt="版本 v0.1.9" src="https://img.shields.io/badge/release-v0.1.9-176B68?style=flat-square" /></a>
  <img alt="macOS 14 及以上，Apple Silicon" src="https://img.shields.io/badge/macOS-14%2B_%C2%B7_Apple_Silicon-263C3B?style=flat-square" />
  <img alt="Windows 预览版：Windows 10 1809 及以上与 Windows 11，x64 和 ARM64" src="https://img.shields.io/badge/Windows_preview-10%2B_%C2%B7_x64_%26_ARM64-263C3B?style=flat-square" />
  <img alt="支持 iOS 和 Android 手机 Web App" src="https://img.shields.io/badge/mobile-iOS_%26_Android-263C3B?style=flat-square" />
</p>

<p align="center">
  <a href="https://github.com/AbadOrangeCat/TheALL/releases/tag/v0.1.9"><strong>下载 macOS 与 Windows 版</strong></a> ·
  <a href="docs/windows.md">Windows 说明</a> ·
  <a href="https://abadorangecat.github.io/TheALL/">项目主页</a> ·
  <a href="docs/mobile-access.md">手机连接</a> ·
  <a href="README.md">English</a>
</p>

![TheAll 功能概览：原生 AI 对话、工作区、模型选择，以及从手机访问电脑](landing-page/assets/overview.png)
<p align="center"><sub>产品功能示意图，非应用截图。</sub></p>

## 保留上下文，让 AI 编程更顺手

**TheAll 是面向 Claude Code 和 OpenAI Codex 的 AI 编程工作台，支持 macOS 与 Windows。** 它为命令行 Agent 提供图形化聊天界面，将工作区、标签页、分屏、聊天记录、模型与思考强度选择、附件和手机连接整合在一起。使用自己的 API 连接，选定项目文件夹，即可开始。

| 你想做的事 | TheAll 如何帮助你 |
| --- | --- |
| **有序管理项目** | 工作区、标签页和分屏；工作区根据首次提问自动命名。 |
| **换模型，保留对话** | 在输入框旁选择模型和思考强度，保留聊天历史和未发送草稿；支持官方 API 与兼容的自定义 Base URL。 |
| **接着上次继续** | 恢复已保存的对话、工作目录、模型和桌面草稿；↑ / ↓ 可调取之前发送的问题。 |
| **上传文件和照片** | 共用一个附件按钮，支持混合选择、拖入和粘贴；每条最多 5 个文件和 4 张照片，随草稿和历史保存。图片需使用支持图片的模型。 |
| **执行中调整任务** | 运行时发送补充指令，可附带文件和照片，保留任务上下文，并提供独立停止按钮。 |
| **清楚阅读回答** | 提问使用独立颜色，每轮对话有分界线；完成后的思考与进度自动折叠，可随时跳到最新消息。每个完成的回合显示完成时间和耗时。 |
| **在手机上继续** | iOS / Android Web App 支持查看历史、回复、新建对话和停止 Mac 或 Windows 电脑上的任务；可开启任务完成提醒，兼容手表同步显示。 |
| **保持最新** | 自动检查新版本，在「连接手机」上方点击即可下载并安装；安装前会等待运行中的任务完成并保存草稿。 |
| **按你的习惯** | 内置约 500 个 Ghostty 配色主题，可调整透明度、模糊和字体。 |
| **使用熟悉的语言** | 桌面和手机支持简体中文、English、Français、日本語和한국어。 |

API 连接在 Mac 上通过 macOS Keychain 保存，在 Windows 上使用系统加密保存。聊天记录保存在本机，对话会发送到你配置的 AI 服务地址。Mac 版使用 SwiftUI、AppKit 和 Ghostty 终端引擎；Windows 预览版位于 [`desktop/`](desktop/)，基于 Electron，沿用相同的工作区、标签页、分屏和聊天布局。

## 开始使用

| | macOS | Windows（预览版） |
| --- | --- | --- |
| **系统** | macOS 14 及以上 | Windows 10 1809 及以上，或 Windows 11（推荐） |
| **处理器** | Apple Silicon（arm64） | x64；另提供 ARM64 |
| **v0.1.9 下载** | [DMG](https://github.com/AbadOrangeCat/TheALL/releases/download/v0.1.9/TheAll-0.1.9-macos-arm64.dmg) · [ZIP](https://github.com/AbadOrangeCat/TheALL/releases/download/v0.1.9/TheAll-0.1.9-macos-arm64.zip) | x64：[安装包](https://github.com/AbadOrangeCat/TheALL/releases/download/v0.1.9/TheAll-0.1.9-windows-x64-nsis.exe) · [便携 EXE](https://github.com/AbadOrangeCat/TheALL/releases/download/v0.1.9/TheAll-0.1.9-windows-x64-portable.exe) · [ZIP](https://github.com/AbadOrangeCat/TheALL/releases/download/v0.1.9/TheAll-0.1.9-windows-x64-zip.zip)<br />ARM64：[安装包](https://github.com/AbadOrangeCat/TheALL/releases/download/v0.1.9/TheAll-0.1.9-windows-arm64-nsis.exe) · [便携 EXE](https://github.com/AbadOrangeCat/TheALL/releases/download/v0.1.9/TheAll-0.1.9-windows-arm64-portable.exe) · [ZIP](https://github.com/AbadOrangeCat/TheALL/releases/download/v0.1.9/TheAll-0.1.9-windows-arm64-zip.zip) |

两个平台都需要可用的 API 连接，以及在同一台电脑上单独安装对应提供商的 [Claude Code CLI](https://code.claude.com/docs/en/setup) 或 [Codex CLI](https://developers.openai.com/codex/cli)。Windows 版直接在本机运行 Claude Code / Codex，不需要 Mac 或 WSL；CLI 安装方法见 [Windows 说明](docs/windows.md)。

1. 安装 TheAll。**Mac：** 将 **TheAll.app** 移到「应用程序」。**Windows：** 运行安装包或便携 EXE，或完整解压 ZIP 后运行 `TheAll.exe`。
2. 打开 TheAll，创建工作区，选择工作文件夹和 **Claude / OpenAI**。
3. 输入 API Key，需要时填写自定义 Base URL；之后的对话可复用已保存的连接。
4. 选择模型，按需选择思考强度，然后发送第一个问题。工作目录、模型和思考强度选择始终位于输入框旁。

**本版安装说明：**

- **macOS：** v0.1.9 使用本地开发证书签名，**尚未经过 Apple 公证**。macOS 可能阻止首次打开；核对下载并确认信任后，可按 [Apple 官方说明](https://support.apple.com/en-us/102445)，使用系统提供的「系统设置 → 隐私与安全性 → 仍要打开」。请保留系统安全保护。Mac 版仅提供 arm64 构建。
- **Windows：** 预览安装包**未签名**，Windows 可能显示 SmartScreen 提示，组织策略也可能阻止运行。ARM64 为交叉构建、尚未实机测试；Windows CI 验证 x64 运行、凭据和历史恢复，安装升级、真实 CLI 与手机/手表仍需实机验收。
- [SHA-256 校验文件](https://github.com/AbadOrangeCat/TheALL/releases/download/v0.1.9/SHA256SUMS.txt)涵盖两个平台。
- 已加入自动检查更新与下载/安装按钮，位于「连接手机」上方。Mac v0.1.7、Windows v0.1.8 及以上可在应用内更新，更早的版本需手动安装一次；安装前会等待任务完成并保存草稿。 <!-- version:keep -->

**执行方式：** 编程 Agent 的工具操作会自动执行，包括修改和删除文件、安装依赖及 Git 推送。请选用你准备让 Agent 操作的项目与 API 连接；需要用户回答的问题仍会暂停等待输入。

## v0.1.9 更新 <!-- version:keep -->

**Windows 版的外观和操作与 Mac 版对齐：**

- **一体化窗口：** 侧栏和内容区延伸到窗口顶端，Windows 原生的最小化、最大化和关闭按钮叠放在标签栏右侧。
- **Mac 的图标与布局：** 线条图标取代文字符号；侧栏、标签、AI 选择页、连接表单、聊天顶栏和输入框沿用 Mac 的尺寸、间距和文案。
- **标签与窗格与 Mac 一致：** 标签不再显示关闭按钮，可用鼠标中键或标签右键菜单关闭；窗格不再有工具栏，分屏和关闭在标签右键菜单中，或使用 Ctrl+D、Ctrl+Shift+D、Ctrl+W。
- **聊天使用系统字体：** 新安装的 Windows 版使用 Segoe UI，与 Mac 聊天使用系统字体一致。已有安装保留原来保存的字体；如需一致，可在「设置 → 字体」中选择 Segoe UI。

Mac 版除版本号外没有变化。

v0.1.7 与 v0.1.8 加入的功能： <!-- version:keep -->

- **文件和照片统一上传：** 共用一个附件按钮，支持混合选择、拖入和粘贴。普通文件每条最多 5 个，单个 10 MiB、合计 20 MiB，副本随草稿与聊天记录保存。
- **任务中 Steer：** Claude Code / Codex 执行中可发送补充指令，支持照片和文件，保留当前模型、计时及上下文。停止时一并取消 Claude 尚未处理的补充指令。
- **应用内更新：** Mac 和 Windows 自动检查新版本，点击「连接手机」上方的更新按钮即可下载并安装；安装前等待任务完成和草稿保存。Mac 使用签名 Sparkle 更新源，Windows 校验发布资产摘要。
- **修复 Windows 启动：** 补齐 0.1.7 遗漏的证书库依赖；每个安装包发布前都会从隔离目录实际启动验证。

## 上传文件和照片

点击附件按钮、直接拖入文件或图片，或用 **⌘V**（Windows 为 **Ctrl+V**）粘贴。每条消息可附带 5 个普通文件（单个 10 MiB、合计 20 MiB）和 4 张照片，也可只发送附件。桌面原图每张最多 20 MiB，导入时校正方向、缩小尺寸并去除原始元数据；原文件保持不变，发送失败时保留草稿。

含普通文件的聊天需要 v0.1.7 或更新版本。自建中继请同步更新，以支持更大的上传请求。详见[附件说明](docs/ai-terminals.md#files-and-photos)和[任务中补充指令](docs/ai-terminals.md#additional-instructions-during-a-task)。 <!-- version:keep -->

## 手机连上你的电脑

TheAll Mobile 可在 **iPhone、iPad 和 Android** 的浏览器中使用；HTTPS 连接还支持安装到主屏幕。Agent 继续在 Mac 或 Windows 电脑上运行，手机控制同一份对话。

| 连接方式 | 如何设置 |
| --- | --- |
| **同一 Wi-Fi / 局域网** | 点击桌面应用侧边栏的 **连接手机**，扫码并打开链接即可；快捷连接无需证书、服务器或域名。请使用可信 Wi-Fi，也可在高级设置选择 HTTPS。 |
| **外出使用** | 在自己的服务器和域名部署仓库提供的中继。桌面应用主动通过 WSS 连接，手机使用 HTTPS；无需额外 VPN App 或路由器端口转发。 |

通过 HTTPS 连接时可开启任务完成提醒：iPhone 需添加到主屏幕，Android 需使用支持推送的浏览器，兼容手表会同步手机通知。HTTP 快捷连接无法接收后台提醒。

配对时可选择全部或指定工作区，以及**仅查看**或**查看与操作**权限；可随时在桌面应用撤销设备。API Key 不会发送给手机。电脑必须保持运行且未休眠；自建中继能够读取转发的流量，应部署在自己信任的服务器上。项目不提供已托管的公网中继。

[手机连接指南](docs/mobile-access.md) · [中继部署说明](mobile-relay/README.md)

## 顺手的快捷键

| 操作 | Mac | Windows |
| --- | --- | --- |
| 发送消息，或向运行中的任务补充指令 | **⌘ Return** | **Ctrl Enter** |
| 输入换行 | **Return** | **Enter** |
| 调取较早 / 较新的问题 | 首行按 **↑** · 末行按 **↓** | 同左 |
| 新建工作区 · 新建标签页 | **⌘N** · **⌘T** | **Ctrl N** · **Ctrl T** |
| 左右分屏 · 上下分屏 | **⌘D** · **⇧⌘D** | **Ctrl D** · **Ctrl Shift D** |
| 关闭窗格 | **⌘W** | **Ctrl W** |
| 切换到下一个 / 上一个窗格 | **⌥⌘→** / **⌥⌘←** | **Ctrl Alt →** / **Ctrl Alt ←** |
| 下一个 / 上一个标签页 | **⇧⌘]** / **⇧⌘[** | **Ctrl Shift ]** / **Ctrl Shift [** |
| 第 1–9 个工作区 · 标签页 | **⌘1–9** · **⌥⌘1–9** | **Ctrl 1–9** · **Ctrl Alt 1–9** |
| 设置 | **⌘,** | **Ctrl ,** |

调出的问题可以修改后再次发送，原始记录不会改变；多行光标移动和输入法选词保留原生行为。用鼠标中键或标签右键菜单关闭标签页；Windows 的标签右键菜单还可以分屏和关闭窗格。

## 本地构建与文档

**macOS：** 本地构建还需要 Xcode、XcodeGen 和 Ghostty 构建依赖。工具链与签名配置见[构建指南](docs/build.md)。

```bash
# 仅在缺少 Ghostty 编译产物时运行
./scripts/build-vendor.sh
xcodegen generate
# 仅在没有 Local.xcconfig 时初始化一次，之后保留该签名身份
bash scripts/setup-local-signing.sh
xcodebuild -project TheAll.xcodeproj -scheme TheAll -configuration Debug build
```

Debug 构建显示为 **TheAll dev**。重新构建时保留已有的本地签名配置和凭据；修改应用标识前，请阅读迁移说明。

**Windows：** 使用 Node.js 24。测试与打包见[从源码构建](docs/windows.md#build-from-source)。

```powershell
npm ci --prefix desktop
npm start --prefix desktop
```

[AI 聊天行为](docs/ai-terminals.md) · [项目架构](docs/architecture.md) · [测试说明](docs/testing.md) · [反馈问题](https://github.com/AbadOrangeCat/TheALL/issues)

## 许可

源代码公开供查阅；源码及安装包的使用与分发遵循 [LICENSE](LICENSE) 和单独授予的许可，公开本身**不授予通用许可**。详见 [LICENSE](LICENSE)；单独授予的书面许可及第三方组件各自的许可证继续适用。第三方组件保留各自的许可条款，详见[组件声明与对应源码](docs/third-party-components.md)。复用代码或计划贡献前，请确认相应权限。
