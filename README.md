<p align="center">
  <img src="landing-page/assets/logo@2x.png" width="96" height="96" alt="TheAll logo" />
</p>

<h1 align="center">TheAll</h1>
<p align="center"><strong>Claude Code and Codex. One workspace for Mac and Windows.</strong><br />Keep your projects, AI conversations, and models together. Continue from your phone.</p>

<p align="center">
  <a href="https://github.com/AbadOrangeCat/TheALL/releases/tag/v0.1.9"><img alt="Release v0.1.9" src="https://img.shields.io/badge/release-v0.1.9-176B68?style=flat-square" /></a>
  <img alt="macOS 14 or later on Apple Silicon" src="https://img.shields.io/badge/macOS-14%2B_%C2%B7_Apple_Silicon-263C3B?style=flat-square" />
  <img alt="Windows preview: Windows 10 version 1809 or later and Windows 11, x64 and ARM64" src="https://img.shields.io/badge/Windows_preview-10%2B_%C2%B7_x64_%26_ARM64-263C3B?style=flat-square" />
  <img alt="Mobile web app for iOS and Android" src="https://img.shields.io/badge/mobile-iOS_%26_Android-263C3B?style=flat-square" />
</p>

<p align="center">
  <a href="https://github.com/AbadOrangeCat/TheALL/releases/tag/v0.1.9"><strong>Download for macOS &amp; Windows</strong></a> ·
  <a href="docs/windows.md">Windows guide</a> ·
  <a href="https://abadorangecat.github.io/TheALL/">Website</a> ·
  <a href="docs/mobile-access.md">Mobile setup</a> ·
  <a href="README.zh-CN.md">简体中文</a>
</p>

![TheAll feature overview: native AI conversations, organized workspaces, a model picker, and phone access to your Mac](landing-page/assets/overview.png)
<p align="center"><sub>Feature illustration; not an application screenshot.</sub></p>

## An AI coding workspace that keeps your context

**TheAll is a desktop app for Claude Code and OpenAI Codex on macOS and Windows.** It brings a graphical chat interface to these coding agents, with workspaces, tabs, split panes, saved conversations, and a model dropdown. Bring your own API connection, choose a project folder, and start working.

| Work the way you think | What TheAll does |
| --- | --- |
| **Keep projects organized** | Workspaces, tabs, and splits; a workspace gets a name from your first question. |
| **Change models, keep the conversation** | Choose from a dropdown without losing chat history or an unsent draft. Official endpoints and compatible custom Base URLs are supported. |
| **Pick up where you left off** | Reopen saved conversations, working folders, model choices, and desktop drafts. Use ↑ / ↓ to recall previous questions. |
| **Share files and photos** | Use one attachment button, drag files into chat, or paste. Attach up to 5 files and 4 photos, with saved drafts and history. Photos require an image-capable model. |
| **Steer work as it happens** | Add instructions and attachments during a running task without losing its context; keep a separate Stop control. |
| **Read the answer clearly** | Distinct question cards, conversation dividers, collapsible thinking and progress, and a jump-to-latest button. |
| **Continue from your phone** | An iOS/Android Web App can read history, reply, start conversations, and stop tasks running on your Mac or Windows PC. |
| **Use your language** | English, 简体中文, Français, 日本語, and 한국어 on desktop and mobile. |

API connections are saved through macOS Keychain on Mac and Windows system encryption on Windows. Chat history stays on your computer; conversations are sent to the AI endpoint you configure. The Mac app uses SwiftUI, AppKit, and Ghostty's terminal engine; the Windows preview in [`desktop/`](desktop/) uses Electron with the same workspace, tab, split-pane and chat layout.

## Get started

| | macOS | Windows (preview) |
| --- | --- | --- |
| **System** | macOS 14 or later | Windows 10 version 1809 or later, or Windows 11 (recommended) |
| **Processor** | Apple Silicon (arm64) | x64; ARM64 is also available |
| **v0.1.9 downloads** | [DMG](https://github.com/AbadOrangeCat/TheALL/releases/download/v0.1.9/TheAll-0.1.9-macos-arm64.dmg) · [ZIP](https://github.com/AbadOrangeCat/TheALL/releases/download/v0.1.9/TheAll-0.1.9-macos-arm64.zip) | x64: [installer](https://github.com/AbadOrangeCat/TheALL/releases/download/v0.1.9/TheAll-0.1.9-windows-x64-nsis.exe) · [portable EXE](https://github.com/AbadOrangeCat/TheALL/releases/download/v0.1.9/TheAll-0.1.9-windows-x64-portable.exe) · [ZIP](https://github.com/AbadOrangeCat/TheALL/releases/download/v0.1.9/TheAll-0.1.9-windows-x64-zip.zip)<br />ARM64: [installer](https://github.com/AbadOrangeCat/TheALL/releases/download/v0.1.9/TheAll-0.1.9-windows-arm64-nsis.exe) · [portable EXE](https://github.com/AbadOrangeCat/TheALL/releases/download/v0.1.9/TheAll-0.1.9-windows-arm64-portable.exe) · [ZIP](https://github.com/AbadOrangeCat/TheALL/releases/download/v0.1.9/TheAll-0.1.9-windows-arm64-zip.zip) |

Both platforms need an API connection and the [Claude Code CLI](https://code.claude.com/docs/en/setup) or [Codex CLI](https://developers.openai.com/codex/cli) for your chosen provider, installed separately on the same computer. Claude Code and Codex run locally on Windows; no Mac or WSL is needed. See the [Windows guide](docs/windows.md) for CLI setup.

1. Install TheAll. **Mac:** move **TheAll.app** to Applications. **Windows:** run the installer or portable EXE, or extract the full ZIP and run `TheAll.exe`.
2. Open TheAll, create a workspace, and select a working folder and **Claude / OpenAI**.
3. Enter your API key and, if needed, a custom Base URL. Later conversations can reuse the saved connection.
4. Choose a model and send your first question. The folder control and model dropdown stay beside the composer.

**About this release:**

- **macOS:** v0.1.9 is signed with a local development certificate and is **not notarized by Apple**. macOS may block the first launch. After verifying the download and choosing to trust it, follow [Apple’s guidance](https://support.apple.com/en-us/102445) and use **System Settings → Privacy & Security → Open Anyway** if macOS offers it. Keep system security protections enabled. The Mac build is arm64 only.
- **Windows:** the preview packages are **unsigned**. Windows may show a SmartScreen notice, and organization policy may prevent them from running. ARM64 is cross-built and not device-tested. Windows CI covers the x64 runtime and credential/history restoration; installed-package upgrades, real provider CLIs and physical phone/watch delivery still need device acceptance.
- [SHA-256 checksums](https://github.com/AbadOrangeCat/TheALL/releases/download/v0.1.9/SHA256SUMS.txt) cover both platforms.
- Automatic update checks and a download/install button above Connect Phone are included. Mac v0.1.7 and Windows v0.1.8 or later update in the app; older releases need one manual installation. Active tasks and drafts are saved before installation. <!-- version:keep -->

**Execution behavior:** coding-agent tools run automatically, including file changes, deletion, dependency installation, and Git pushes. Use a project and API connection you intend the agent to operate. Questions that require your answer still p## New in v0.1.9 <!-- version:keep -->

**The Windows app now looks and works like the Mac app:**

- **Integrated window:** the sidebar and content reach the top edge, with Windows' native minimize, maximize and close buttons over the tab row.
- **Mac icons and layout:** line icons replace text symbols. The sidebar, tabs, provider chooser, connection form, chat header and composer follow the Mac sizes, spacing and wording.
- **Tabs and panes like the Mac:** tabs have no close button; middle-click or use the tab's right-click menu. Panes have no toolbar; split and close them from the tab menu or with Ctrl+D, Ctrl+Shift+D and Ctrl+W.
- **System font for chat:** new Windows installations use Segoe UI, as the Mac chat uses its system font. Existing installations keep their saved font; choose Segoe UI in **Settings → Font** to match.

The Mac app is unchanged apart from its version.

Added in v0.1.7 and v0.1.8: <!-- version:keep -->

- **Files and photos together:** one attachment button with mixed selection, drag/drop and paste on desktop and mobile. Ordinary files are copied privately and retained with drafts/history; send up to 5 files, 10 MiB each and 20 MiB total.
- **Steer running tasks:** send additional instructions with text, files or photos while Claude Code/Codex works. The current task keeps its model, elapsed time and conversation context. Stop also cancels queued Claude instructions.
- **Updates in the app:** automatic checks on Mac and Windows, with a visible download/install action above Connect Phone. Installation waits for work to finish and drafts to save. Mac updates use a signed Sparkle feed; Windows downloads are checked against the published asset digest.
- **Windows startup repair:** the certificate-library dependencies missing from 0.1.7 are included, and every package is launched from an isolated directory before release.

## Files and photos

Use the attachment button, drag files or images into the desktop chat, or paste with **⌘V** (**Ctrl+V** on Windows). Attach up to 5 ordinary files (10 MiB each, 20 MiB combined) and 4 photos. Send attachments with text or on their own. Desktop photo imports accept up to 20 MiB per source and create smaller copies with orientation corrected and original metadata removed. Originals remain unchanged, and failed sends preserve the draft.

Chats containing ordinary files require v0.1.7 or later. Update a self-hosted relay alongside the desktop app to support the larger uploads. See [attachment details](docs/ai-terminals.md#files-and-photos) and [steering during a task](docs/ai-terminals.md#additional-instructions-during-a-task). <!-- version:keep -->

## Your computer, reachable from your phone

Use TheAll Mobile in a browser on **iPhone, iPad, and Android**. HTTPS connections also support home-screen Web App installation. Your Mac or Windows PC runs the agents; the phone controls the same conversations.

| Connection | Setup |
| --- | --- |
| **Same Wi-Fi / LAN** | Click **Connect phone** in the desktop sidebar, then scan and open the QR link. Quick connect needs no certificate, server, or domain. Use trusted Wi-Fi; optional HTTPS is in Advanced settings. |
| **Away from home** | Deploy the included relay on your own server and domain. The desktop app connects out over WSS; the phone uses HTTPS. No extra VPN app or router port forwarding required. |

Pair a phone with access to all workspaces or just one, and choose **read-only** or **control** access. Revoke devices from the desktop app. API keys are not sent to the phone. The computer must stay running and awake; a self-hosted relay can read the traffic it forwards, so deploy it on infrastructure you trust. No hosted relay service is included.

[Mobile connection guide](docs/mobile-access.md) · [Relay deployment](mobile-relay/README.md)

## A few useful keys

| Key | Action |
| --- | --- |
| **⌘ Return** (Windows: **Ctrl Enter**) | Send a message, or steer the running task. |
| **Return** (Windows: **Enter**) | Insert a new line. |
| **↑** on the first visual line | Recall an older question in this conversation. |
| **↓** on the last visual line | Move toward newer questions, then restore your unsent draft. |

Recalled questions are editable copies. Original messages stay intact, and multiline editing and input-method selection remain native.

## Build and explore

**macOS:** building locally also requires Xcode, XcodeGen, and Ghostty build dependencies. See the [build guide](docs/build.md) for toolchain and signing details.

```bash
# Only when the Ghostty build artifacts are missing
./scripts/build-vendor.sh
xcodegen generate
# Only when Local.xcconfig does not exist; keep this identity across rebuilds
bash scripts/setup-local-signing.sh
xcodebuild -project TheAll.xcodeproj -scheme TheAll -configuration Debug build
```

Debug builds display **TheAll dev**. Keep existing local signing configuration and credentials when rebuilding; follow the migration guidance before changing application identifiers.

**Windows:** use Node.js 24. See [Build from source](docs/windows.md#build-from-source) for tests and packaging.

```powershell
npm ci --prefix desktop
npm start --prefix desktop
```

[AI chat behavior](docs/ai-terminals.md) · [Architecture](docs/architecture.md) · [Testing](docs/testing.md) · [Report an issue](https://github.com/AbadOrangeCat/TheALL/issues)

## License

The source is publicly available for inspection. Use and distribution of both source code and binary downloads are governed by [LICENSE](LICENSE) and any separately granted permissions; public availability does **not** grant a general license. See [LICENSE](LICENSE); separately granted written permissions and third-party component licenses remain applicable. Third-party components retain their respective licenses; see the [component notices and corresponding source](docs/third-party-components.md). Check permissions before reusing code or proposing contributions.
