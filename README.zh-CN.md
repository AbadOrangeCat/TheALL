<p align="center">
  <img src="landing-page/assets/logo@2x.png" width="96" height="96" alt="TheAll 标志" />
</p>

<h1 align="center">TheAll</h1>
<p align="center"><strong>把 Claude Code 和 Codex，放进同一个 Mac 与 Windows 工作台。</strong><br />项目、AI 对话和模型集中管理。离开电脑，也能在手机上继续。</p>

<p align="center">
  <a href="https://github.com/AbadOrangeCat/TheALL/releases/tag/v0.1.6"><img alt="版本 v0.1.6" src="https://img.shields.io/badge/release-v0.1.6-176B68?style=flat-square" /></a>
  <img alt="macOS 14 及以上，Apple Silicon" src="https://img.shields.io/badge/macOS-14%2B_%C2%B7_Apple_Silicon-263C3B?style=flat-square" />
  <img alt="Windows 预览版：Windows 10 1809 及以上与 Windows 11，x64 和 ARM64" src="https://img.shields.io/badge/Windows_preview-10%2B_%C2%B7_x64_%26_ARM64-263C3B?style=flat-square" />
  <img alt="支持 iOS 和 Android 手机 Web App" src="https://img.shields.io/badge/mobile-iOS_%26_Android-263C3B?style=flat-square" />
</p>

<p align="center">
  <a href="https://github.com/AbadOrangeCat/TheALL/releases/tag/v0.1.6"><strong>下载 macOS 与 Windows 版</strong></a> ·
  <a href="docs/windows.md">Windows 说明</a> ·
  <a href="https://abadorangecat.github.io/TheALL/">项目主页</a> ·
  <a href="docs/mobile-access.md">手机连接</a> ·
  <a href="README.md">English</a>
</p>

![TheAll 功能概览：原生 AI 对话、工作区、模型选择，以及从手机访问 Mac](landing-page/assets/overview.png)
<p align="center"><sub>产品功能示意图，非应用截图。</sub></p>

## 保留上下文，让 AI 编程更顺手

**TheAll 是面向 Claude Code 和 OpenAI Codex 的 AI 编程工作台，支持 macOS 与 Windows。** 它为命令行 Agent 提供图形化聊天界面，将工作区、标签页、分屏、聊天记录和模型选择整合在一起。使用自己的 API 连接，选定项目文件夹，即可开始。

| 你想做的事 | TheAll 如何帮助你 |
| --- | --- |
| **有序管理项目** | 工作区、标签页和分屏；工作区根据首次提问自动命名。 |
| **换模型，保留对话** | 下拉选择模型，保留聊天历史和未发送草稿；支持官方 API 与兼容的自定义 Base URL。 |
| **接着上次继续** | 恢复已保存的对话、工作目录、模型和桌面草稿；↑ / ↓ 可调取之前发送的问题。 |
| **把图片交给 AI** | 电脑与手机每条可添加最多 4 张照片；桌面支持直接拖入图片或粘贴截图，可预览，并随聊天记录保存。需使用支持图片的模型。 |
| **清楚阅读回答** | 提问使用独立颜色，每轮对话有分界线；完成后的思考与进度自动折叠，可随时跳到最新消息。 |
| **在手机上继续** | iOS / Android Web App 支持查看历史、回复、新建对话和停止 Mac 或 Windows 电脑上的任务。 |
| **使用熟悉的语言** | 桌面和手机支持简体中文、English、Français、日本語和한국어。 |

API 连接在 Mac 上通过 macOS Keychain 保存，在 Windows 上使用系统加密保存。聊天记录保存在本机，对话会发送到你配置的 AI 服务地址。Mac 版使用 SwiftUI、AppKit 和 Ghostty 终端引擎；Windows 预览版位于 [`desktop/`](desktop/)，基于 Electron，沿用相同的工作区、标签页、分屏和聊天布局。

## 开始使用

| | macOS | Windows（预览版） |
| --- | --- | --- |
| **系统** | macOS 14 及以上 | Windows 10 1809 及以上，或 Windows 11（推荐） |
| **处理器** | Apple Silicon（arm64） | x64；另提供 ARM64 |
| **v0.1.6 下载** | [DMG](https://github.com/AbadOrangeCat/TheALL/releases/download/v0.1.6/TheAll-0.1.6-macos-arm64.dmg) · [ZIP](https://github.com/AbadOrangeCat/TheALL/releases/download/v0.1.6/TheAll-0.1.6-macos-arm64.zip) | x64：[安装包](https://github.com/AbadOrangeCat/TheALL/releases/download/v0.1.6/TheAll-0.1.6-windows-x64-nsis.exe) · [便携 EXE](https://github.com/AbadOrangeCat/TheALL/releases/download/v0.1.6/TheAll-0.1.6-windows-x64-portable.exe) · [ZIP](https://github.com/AbadOrangeCat/TheALL/releases/download/v0.1.6/TheAll-0.1.6-windows-x64-zip.zip)<br />ARM64：[安装包](https://github.com/AbadOrangeCat/TheALL/releases/download/v0.1.6/TheAll-0.1.6-windows-arm64-nsis.exe) · [便携 EXE](https://github.com/AbadOrangeCat/TheALL/releases/download/v0.1.6/TheAll-0.1.6-windows-arm64-portable.exe) · [ZIP](https://github.com/AbadOrangeCat/TheALL/releases/download/v0.1.6/TheAll-0.1.6-windows-arm64-zip.zip) |

两个平台都需要可用的 API 连接，以及在同一台电脑上单独安装对应提供商的 [Claude Code CLI](https://code.claude.com/docs/en/setup) 或 [Codex CLI](https://developers.openai.com/codex/cli)。Windows 版直接在本机运行 Claude Code / Codex，不需要 Mac 或 WSL；CLI 安装方法见 [Windows 说明](docs/windows.md)。

1. 安装 TheAll。**Mac：** 将 **TheAll.app** 移到「应用程序」。**Windows：** 运行安装包或便携 EXE，或完整解压 ZIP 后运行 `TheAll.exe`。
2. 打开 TheAll，创建工作区，选择工作文件夹和 **Claude / OpenAI**。
3. 输入 API Key，需要时填写自定义 Base URL；之后的对话可复用已保存的连接。
4. 选择模型，发送第一个问题。工作目录与模型下拉框始终位于输入框旁。

**本版安装说明：**

- **macOS：** v0.1.6 使用本地开发证书签名，**尚未经过 Apple 公证**。macOS 可能阻止首次打开；核对下载并确认信任后，可按 [Apple 官方说明](https://support.apple.com/en-us/102445)，使用系统提供的「系统设置 → 隐私与安全性 → 仍要打开」。请保留系统安全保护。Mac 版仅提供 arm64 构建。
- **Windows：** 预览安装包**未签名**，Windows 可能显示 SmartScreen 提示，组织策略也可能阻止运行。ARM64 为交叉构建、尚未实机测试；Windows CI 验证 x64 运行、凭据和历史恢复，安装升级、真实 CLI 与手机/手表仍需实机验收。
- [SHA-256 校验文件](https://github.com/AbadOrangeCat/TheALL/releases/download/v0.1.6/SHA256SUMS.txt)涵盖两个平台。暂未配置自动更新。

**执行方式：** 编程 Agent 的工具操作会自动执行，包括修改和删除文件、安装依赖及 Git 推送。请选用你准备让 Agent 操作的项目与 API 连接；需要用户回答的问题仍会暂停等待输入。

## v0.1.6 新功能 <!-- version:keep -->

- **Windows 预览版：** 在 Windows 本机使用 Claude Code / Codex，支持工作区、标签页、分屏、历史与手机连接。
- **模型旁选择思考强度：** 选项取自当前模型报告的能力。Claude 每次发送前读取 CLI 实际设置，不一致时停止发送并保留草稿；回答底部区分「CLI 已确认强度」和 Codex 的「请求强度」。模型在聊天中自述的内部数值不作为设置证据。
- **回合完成信息：** 显示完成时间及使用时长，随聊天历史保存。
- **手机与手表提醒：** HTTPS 下可开启任务完成 Web Push；iOS 需添加为主屏幕 Web App，兼容手表通过手机系统转发通知。实体设备投递仍待验证；局域网 HTTP 快捷连接支持聊天，但无法接收后台推送。

侧边栏 **连接手机** 仍支持可信 Wi-Fi 下自动扫码配对；高级设置提供 HTTPS 与自建中继。

## 让对话支持照片

点击照片按钮、将图片拖入桌面聊天区，或用 **⌘V**（Windows 为 **Ctrl+V**）粘贴截图，即可发送图文或仅图片消息。桌面原图每张最多 20 MiB，导入时会校正方向、缩小尺寸并去除原始元数据，不修改原文件；手机上传前会压缩。发送失败时保留草稿附件。

含照片的聊天使用新的历史格式，请保留 v0.1.4 或更新版本以再次打开。使用自建中继时，请与桌面应用同步更新中继代码以支持照片上传。详见[照片功能说明](docs/ai-terminals.md#photos)。 <!-- version:keep -->

## 手机连上你的电脑

TheAll Mobile 可在 **iPhone、iPad 和 Android** 的浏览器中使用；HTTPS 连接还支持安装到主屏幕。Agent 继续在 Mac 或 Windows 电脑上运行，手机控制同一份对话。

| 连接方式 | 如何设置 |
| --- | --- |
| **同一 Wi-Fi / 局域网** | 点击桌面应用侧边栏的 **连接手机**，扫码并打开链接即可；快捷连接无需证书、服务器或域名。请使用可信 Wi-Fi，也可在高级设置选择 HTTPS。 |
| **外出使用** | 在自己的服务器和域名部署仓库提供的中继。桌面应用主动通过 WSS 连接，手机使用 HTTPS；无需额外 VPN App 或路由器端口转发。 |

配对时可选择全部或指定工作区，以及**仅查看**或**查看与操作**权限；可随时在桌面应用撤销设备。API Key 不会发送给手机。电脑必须保持运行且未休眠；自建中继能够读取转发的流量，应部署在自己信任的服务器上。项目不提供已托管的公网中继。

[手机连接指南](docs/mobile-access.md) · [中继部署说明](mobile-relay/README.md)

## 顺手的快捷键

| 按键 | 操作 |
| --- | --- |
| **⌘ Return**（Windows：**Ctrl Enter**） | 发送当前消息。 |
| **Return**（Windows：**Enter**） | 输入换行。 |
| 首个视觉行按 **↑** | 调取当前对话中较早的问题。 |
| 最后视觉行按 **↓** | 返回较新的问题，最后恢复未发送草稿。 |

调出的内容可以修改后再次发送，原始记录不会改变；多行光标移动和输入法选词保留原生行为。

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
