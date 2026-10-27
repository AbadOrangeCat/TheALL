<p align="center">
  <img src="landing-page/assets/logo@2x.png" width="96" height="96" alt="TheAll logo" />
</p>

<h1 align="center">TheAll</h1>
<p align="center"><strong>Claude Code and Codex. One native macOS workspace.</strong><br />Keep your projects, AI conversations, and models together. Continue from your phone.</p>

<p align="center">
  <a href="https://github.com/AbadOrangeCat/TheALL/releases/tag/v0.1.3"><img alt="Release v0.1.3" src="https://img.shields.io/badge/release-v0.1.3-176B68?style=flat-square" /></a>
  <img alt="macOS 14 or later" src="https://img.shields.io/badge/macOS-14%2B-263C3B?style=flat-square" />
  <img alt="Apple Silicon" src="https://img.shields.io/badge/Apple_Silicon-arm64-263C3B?style=flat-square" />
  <img alt="Mobile web app for iOS and Android" src="https://img.shields.io/badge/mobile-iOS_%26_Android-263C3B?style=flat-square" />
</p>

<p align="center">
  <a href="https://github.com/AbadOrangeCat/TheALL/releases/tag/v0.1.3"><strong>Download for Mac</strong></a> ·
  <a href="https://abadorangecat.github.io/TheALL/">Website</a> ·
  <a href="docs/mobile-access.md">Mobile setup</a> ·
  <a href="README.zh-CN.md">简体中文</a>
</p>

![TheAll feature overview: native AI conversations, organized workspaces, a model picker, and phone access to your Mac](landing-page/assets/overview.png)
<p align="center"><sub>Feature illustration; not an application screenshot.</sub></p>

## An AI coding workspace that keeps your context

**TheAll is a native macOS app for Claude Code and OpenAI Codex.** It brings a graphical chat interface to these coding agents, with workspaces, tabs, split panes, saved conversations, and a model dropdown. Bring your own API connection, choose a project folder, and start working.

| Work the way you think | What TheAll does |
| --- | --- |
| **Keep projects organized** | Workspaces, tabs, and splits; a workspace gets a name from your first question. |
| **Change models, keep the conversation** | Choose from a dropdown without losing chat history or an unsent draft. Official endpoints and compatible custom Base URLs are supported. |
| **Pick up where you left off** | Reopen saved conversations, working folders, model choices, and desktop drafts. Use ↑ / ↓ to recall previous questions. |
| **Read the answer clearly** | Distinct question cards, conversation dividers, collapsible thinking and progress, and a jump-to-latest button. |
| **Continue from your phone** | An iOS/Android Web App can read history, reply, start conversations, and stop tasks running on your Mac. |
| **Use your language** | English, 简体中文, Français, 日本語, and 한국어 on desktop and mobile. |

API connections are saved through macOS Keychain. Chat history stays on your Mac; conversations are sent to the AI endpoint you configure. TheAll uses SwiftUI, AppKit, and Ghostty's terminal engine.

## Get started

**Requirements:** macOS 14 or later, an Apple Silicon Mac, an API connection, and the [Claude Code CLI](https://code.claude.com/docs/en/setup) or [Codex CLI](https://developers.openai.com/codex/cli) for your chosen provider. The CLIs are installed separately.

1. Download the [v0.1.3 DMG](https://github.com/AbadOrangeCat/TheALL/releases/download/v0.1.3/TheAll-0.1.3-macos-arm64.dmg) or [ZIP](https://github.com/AbadOrangeCat/TheALL/releases/download/v0.1.3/TheAll-0.1.3-macos-arm64.zip), then move **TheAll.app** to Applications.
2. Open TheAll, create a workspace, and select a working folder and **Claude / OpenAI**.
3. Enter your API key and, if needed, a custom Base URL. Later conversations can reuse the saved connection.
4. Choose a model and send your first question. The folder control and model dropdown stay beside the composer.

**About this release:** v0.1.3 is signed with a local development certificate and is **not notarized by Apple**. macOS may block the first launch. After verifying the download and choosing to trust it, follow [Apple’s guidance](https://support.apple.com/en-us/102445) and use **System Settings → Privacy & Security → Open Anyway** if macOS offers it. Keep system security protections enabled. [SHA-256 checksums](https://github.com/AbadOrangeCat/TheALL/releases/download/v0.1.3/SHA256SUMS.txt) are included. This release is arm64 only, and automatic updates are not configured.

**Execution behavior:** coding-agent tools run automatically, including file changes, deletion, dependency installation, and Git pushes. Use a project and API connection you intend the agent to operate. Questions that require your answer still pause for input.

## Your Mac, reachable from your phone

TheAll Mobile is a Web App you can add to the home screen on **iPhone, iPad, and Android**. Your Mac runs the agents; the phone controls the same conversations.

| Connection | Setup |
| --- | --- |
| **Same Wi-Fi / LAN** | The Mac serves the app over HTTPS. Install the Mac's exported public CA certificate on the phone, then scan a pairing QR code. No server or domain required. |
| **Away from home** | Deploy the included relay on your own server and domain. The Mac connects out over WSS; the phone uses HTTPS. No extra VPN app or router port forwarding required. |

Pair a phone with access to all workspaces or just one, and choose **read-only** or **control** access. Revoke devices from the Mac. API keys are not sent to the phone. The Mac must stay running and awake; a self-hosted relay can read the traffic it forwards, so deploy it on infrastructure you trust. No hosted relay service is included.

[Mobile connection guide](docs/mobile-access.md) · [Relay deployment](mobile-relay/README.md)

## A few useful keys

| Key | Action |
| --- | --- |
| **⌘ Return** | Send the current message. |
| **Return** | Insert a new line. |
| **↑** on the first visual line | Recall an older question in this conversation. |
| **↓** on the last visual line | Move toward newer questions, then restore your unsent draft. |

Recalled questions are editable copies. Original messages stay intact, and multiline editing and input-method selection remain native.

## Build and explore

Building locally also requires Xcode, XcodeGen, and Ghostty build dependencies. See the [build guide](docs/build.md) for toolchain and signing details.

```bash
# Only when the Ghostty build artifacts are missing
./scripts/build-vendor.sh
xcodegen generate
# Only when Local.xcconfig does not exist; keep this identity across rebuilds
bash scripts/setup-local-signing.sh
xcodebuild -project TheAll.xcodeproj -scheme TheAll -configuration Debug build
```

Debug builds display **TheAll dev**. Keep existing local signing configuration and credentials when rebuilding; follow the migration guidance before changing application identifiers.

[AI chat behavior](docs/ai-terminals.md) · [Architecture](docs/architecture.md) · [Testing](docs/testing.md) · [Report an issue](https://github.com/AbadOrangeCat/TheALL/issues)

## License

The source is publicly available for inspection. Use and distribution of both source code and binary downloads are governed by [LICENSE](LICENSE) and any separately granted permissions; public availability does **not** grant a general license. See [LICENSE](LICENSE); separately granted written permissions and third-party component licenses remain applicable. Third-party components retain their respective licenses; see the [component notices and corresponding source](docs/third-party-components.md). Check permissions before reusing code or proposing contributions.
