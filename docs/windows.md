# TheAll for Windows

The Windows desktop app runs Claude Code and Codex **on the Windows computer itself**. It does not require a Mac, WSL, a browser extension, or a separately hosted server. The desktop layout follows the Mac app: workspaces on the left, conversation tabs and split panes on the right, with the model and working folder beside the composer. Windows supplies its own window controls and font rendering.

The Windows implementation is in `desktop/`. The existing SwiftUI/AppKit macOS app remains in `TheAll/`. The [v0.1.8 release](https://github.com/AbadOrangeCat/TheALL/releases/tag/v0.1.8) includes unsigned Windows preview packages for x64 and ARM64, alongside the Mac release. The Windows workflow validates and builds packages; publishing remains a separate step.

## Requirements

- Windows 10 version 1809 or newer, or Windows 11. Windows 11 is recommended.
- x64 is the primary validation target. An ARM64 build is also configured; it is cross-built on an x64 runner and needs separate ARM64 device acceptance.
- Install Claude Code, Codex CLI, or both for the same Windows account that runs TheAll.
- An API Key and an API endpoint compatible with the chosen provider. Photos require a model and endpoint that accept image input.
- Git and any project-specific tools such as Node.js, Python, .NET or Java must be installed separately when the agent needs them.

The packaged TheAll app includes Electron and its runtime. Node.js 24 is required to build TheAll from source, and is a convenient choice if installing a provider CLI through npm.

If 0.1.7 reports `ERR_MODULE_NOT_FOUND` for `@peculiar/asn1-schema` at startup, install 0.1.8 or later. That package omitted required certificate-library peer dependencies; installing Node.js or re-entering API keys does not repair it. The fix preserves the existing user data directory.

## Install the AI tools

Open a normal PowerShell window. Follow the provider's official instructions for the current release.

For Claude Code, one Windows installation option is:

```powershell
winget install --id Anthropic.ClaudeCode --exact
```

For Codex CLI, with Node.js installed:

```powershell
npm install -g @openai/codex
```

Close and reopen PowerShell, then check the tools you installed:

```powershell
claude --version
codex --version
```

Claude Code supports native Windows. Git for Windows is recommended for its Bash tools; current Claude versions can use PowerShell when Git Bash is absent. See [Claude Code setup](https://code.claude.com/docs/en/setup) and the [official Codex installation instructions](https://github.com/openai/codex#installing-and-running-codex-cli).

TheAll searches the Windows `PATH`, the user's `.local\bin`, the npm global directory under `%APPDATA%\npm`, and WinGet links. If discovery fails, set the executable path in TheAll's AI connection settings. A native `.exe` or an official npm JavaScript entry is supported. TheAll resolves official `.cmd` shims to their JavaScript entry rather than running arbitrary wrapper text through `cmd.exe`.

TheAll uses its saved API connection, with optional custom Base URL. A separate `claude login` or `codex login` is not needed for this API workflow. It keeps its provider configuration and session state inside its own application-data directory.

## Run or install TheAll

Open the [release page](https://github.com/AbadOrangeCat/TheALL/releases/tag/v0.1.8), choose your CPU architecture, and download one of these packages. The release provides a combined `SHA256SUMS.txt`; CI artifacts also contain per-architecture checksums:

| File | Use |
| --- | --- |
| `TheAll-<version>-windows-x64-nsis.exe` | Per-user installer with Start menu and desktop shortcuts |
| `TheAll-<version>-windows-x64-portable.exe` | Launch without installing |
| `TheAll-<version>-windows-x64-zip.zip` | Extract the complete app folder and run `TheAll.exe` |
| `SHA256SUMS-x64.txt` | SHA-256 checksums for those three files |

ARM64 artifacts use `arm64` in the corresponding filenames. Keep the full extracted app folder together; the EXE inside the ZIP depends on its bundled resources.

These preview packages are unsigned. Windows may display a SmartScreen notice, and organization policy may prevent them from running. Code signing is not configured; the workflow does not change system security settings.

Open TheAll, choose a workspace and AI provider, and save your API Key. Select a working folder, choose a model in the dropdown, and send a question. The saved connection is reused by new conversations for that provider. As in the Mac app, tool operations execute automatically; questions that require your answer remain interactive.

## Features and platform differences

| Area | Windows implementation |
| --- | --- |
| Desktop navigation | Workspace sidebar, tabs, horizontal/vertical split panes, rename, close, reorder and persisted selection/layout |
| AI providers | Local Claude Code and Codex processes; official or custom API endpoint; saved provider credentials |
| Models and folders | Model catalog/dropdown, per-conversation working folder, model switch without resetting the provider session |
| Conversation history | Persisted messages, provider conversation IDs, drafts and file/photo references; reopen to resume the same provider context |
| Chat presentation | Distinct user styling, round separators, intermediate thinking/progress collapse, jump-to-bottom when scrolled away |
| Composer | Prior-prompt recall with arrow keys, unified file/photo picker, mixed paste/drop, previews/removal, and Steer during active tasks |
| Language and appearance | English, Simplified Chinese, French, Japanese and Korean; all 502 bundled Mac themes, palette matching, font/opacity/padding settings |
| Phone connection | Same-computer workspaces/history on iOS/Android; LAN QR pairing, optional certificate HTTPS and self-hosted remote relay |
| Device access | Workspace scoping, read-only or writable access, device revocation, live changes and reconnect behavior |

Native macOS materials, traffic-light window controls, AppKit font metrics and OS-specific keyboard modifiers are platform-specific. Windows keeps native Windows window controls and uses Control-based shortcuts where the Mac uses Command. The historical Ghostty shell renderer is not ported: current conversations run through the same Claude/Codex structured protocols as the Mac AI chat, rather than embedding a general-purpose terminal. Windows checks the public GitHub stable release at startup and every six hours, with an update card above Connect Phone. Clicking it downloads the matching architecture and install format, verifies the asset and waits for active work before installation. Neither platform includes a hosted public relay.

The two apps have independent local data stores. This implementation does not import an existing Mac application's history into Windows and does not synchronize two desktop computers automatically. A phone controls the desktop it paired with.

## Stored data and upgrades

The installed, portable and extracted Windows distributions share the same stable directory for the current Windows account:

```text
%APPDATA%\TheAll\
```

Running the source tree uses a separate directory:

```text
%APPDATA%\TheAll Development\
```

The folder names do not contain the application version. Installing a newer Windows build therefore continues to use the same conversations and provider sessions. The NSIS uninstaller is configured to preserve application data. Do not delete the data directory to troubleshoot an empty or damaged history view.

The store includes `workspaces.json`, attachment files, encrypted files under `Credentials\`, and app-owned `claude\` / `codex\` session state. Writes replace complete files atomically. An unreadable or unsupported store causes startup to report an error while preserving the original files, instead of silently replacing the store with empty history.

API Keys are encrypted through Electron's asynchronous `safeStorage` API. On Windows its keys are protected by DPAPI and tied to the Windows user's credentials. Copying only the encrypted files to a different Windows account is not a portable credential backup; enter the connection again on that account. Other processes running as the same Windows user are not isolated from DPAPI-protected secrets. See [Electron safeStorage](https://www.electronjs.org/docs/latest/api/safe-storage).

For a history backup, fully exit TheAll and copy the whole application-data directory. Keep it private. Development/test data and installed-app data are intentionally separate.

## Connect a phone

1. Keep the Windows computer and phone on the same trusted Wi-Fi, and keep TheAll running.
2. Click **Connect phone** in the sidebar.
3. Scan the QR code with the phone camera and open its link. Pairing completes automatically.

Quick pairing uses private-LAN HTTP, which is unencrypted. The advanced mode provides certificate-based HTTPS. A fully installed, offline-capable PWA requires HTTPS; HTTP can be used as an online browser shortcut. If Windows Firewall asks about local-network access, allow the app on the private network you intend to use. TheAll does not silently change firewall rules. Guest-network isolation, a VPN, or a computer going to sleep can prevent the phone from reaching it.

For access away from home, deploy the included relay and configure its HTTPS address in the desktop app. The Windows host connects outward over WSS; no WSL service or Mac is involved. See [mobile access](mobile-access.md) and [relay deployment](../mobile-relay/README.md).

## Turn timing and reasoning effort

Completed turns show the local completion date/time and elapsed duration below the final answer, with both fields saved in history. Legacy messages without timing remain unchanged. Failed or stopped turns with an existing answer display their corresponding status.

The reasoning effort control beside the model picker applies to the next message and preserves the conversation and draft. Options come from the current model's reported capabilities; the control remains visible but disabled while no selectable levels are available. Default restores the selected model's default effort.

Codex levels such as `ultra` are passed unchanged to its app-server; the CLI can translate a client mode into a different underlying API effort. Claude subprocesses isolate inherited `CLAUDE_CODE_EFFORT_LEVEL` and `CLAUDE_CODE_EXTRA_BODY` overrides so they cannot silently replace the selected effort. Validate settings using the outbound request rather than the assistant's description of its own effort. Each Claude turn reapplies its level (including Default) and checks `get_settings.applied.effort` before submitting. A mismatch, malformed response or unsupported readback blocks submission and keeps the draft; older CLIs need updating. The answer footer persists the CLI-confirmed level for that turn, while Codex records the requested level. Only `applied.effort` is retained, never the full settings response. Active chats retain their own backend capabilities when another chat initializes.

## Phone and watch completion notifications

Windows uses the same opt-in Web Push flow as macOS. Pair through HTTPS, open **Task completion notifications** on the phone, allow notifications and send a test. iPhone requires a Home Screen Web App; Android requires a Push-capable browser. Apple Watch and Wear OS/Galaxy Watch receive notifications through the phone's system notification forwarding. Quick-connect HTTP cannot enable background notifications.

Only a newly submitted, successfully completed AI turn triggers a completion notification. History restoration, cancellation and failure do not. The payload contains a generic completion message and a conversation link, with no prompt, answer, path or API key. Device revocation and workspace grants apply to delivery. The computer must be awake, running and online; the phone's focus/battery settings can delay presentation. See the [phone and watch guide](mobile-access.md#手机与手表的任务完成提醒).

## Build from source

Use Node.js **24** and npm on Windows. From the repository root:

```powershell
npm ci --prefix desktop
npm ci --prefix mobile-relay
npm run prepare:assets --prefix desktop
npm test --prefix desktop
npm test --prefix mobile-relay
npm run test:desktop --prefix desktop
npm start --prefix desktop
```

Build the installer, portable executable and ZIP:

```powershell
npm run dist:win --prefix desktop -- --publish never
```

Or cross-build ARM64 packages:

```powershell
npm run dist:win:arm64 --prefix desktop -- --publish never
```

Packaging automatically checks the ASAR production dependencies and required peers, exercises bundled certificate generation, and starts an isolated copy of the packaged application. Native Windows x64 builds launch the real executable; ARM64 cross-builds validate the production ASAR on host Electron and still require ARM64 device acceptance. A missing module or failed startup blocks the package build.

For ZIP-only cross-builds (including an Apple Silicon Mac without the NSIS toolchain), use:

```sh
npm run dist:win:zip --prefix desktop -- --publish never -c.win.signExecutable=false
npm run dist:win:zip:arm64 --prefix desktop -- --publish never -c.win.signExecutable=false
```

This disables signing while preserving the Windows icon, version and executable resources. A cross-built ZIP contains the complete Windows application, but cannot be executed or used to validate DPAPI on macOS. Build the NSIS and portable EXEs on the Windows CI runner.

Outputs are written under `desktop/dist/`. The build packages the shared mobile web assets, the current logo and third-party notices. It does not invoke Xcode, build libghostty, or modify the macOS `Local.xcconfig`.

## Validation

[Windows desktop workflow](../.github/workflows/windows.yml) runs on manual dispatch or a pull request affecting the Windows implementation and shared mobile components. It installs locked dependencies, runs Node protocol/runtime/mobile/relay tests and the native Electron smoke, then packages x64 and ARM64. It uploads Actions artifacts with checksums, with no release publishing or signing credentials. ARM64 packaging is cross-compilation, not an ARM64 execution test.

The Electron smoke must use an isolated temporary application-data directory. The app supports `THEALL_TEST_DATA_DIR` for this purpose; do not point tests at `%APPDATA%\TheAll` or `%APPDATA%\TheAll Development`. `THEALL_TEST_HIDE_WINDOW` suppresses the test window. Test configuration does not change the normal application-data path.

The CLI integration test is optional and separate from the default test suite. Install the provider CLIs and Python, then run:

```powershell
$env:THEALL_TEST_INSTALLED_CLIS = '1'
node --test desktop/test/ai.integration.test.mjs
Remove-Item Env:THEALL_TEST_INSTALLED_CLIS
```

It uses a loopback fake API, fake credentials and temporary provider state to test real CLI model switches, image delivery, tool execution and process restart/resume. It does not send prompts to a real AI endpoint. The regular protocol tests cover native executable/npm discovery, mixed-case Windows environment variables, question handling, pre-ACK approvals, backpressure/timeouts, revoked access and closure during startup.

The workflow configuration alone is not evidence of a successful Windows run. Before publishing preview downloads, require a successful native Windows x64 workflow. Stable-platform acceptance additionally requires an installed build with real Windows CLI paths, DPAPI across relaunch, history/drafts after upgrade, an iPhone/Android LAN connection, and the desired ARM64 hardware. These physical-device and installed-package checks remain pending for the preview. macOS-hosted protocol tests and cross-built binaries cannot substitute for those checks.

## 中文快速开始

Windows 版直接在本机运行 Claude Code / Codex，不需要 Mac 或 WSL。先安装对应 CLI，再运行 Windows 安装包或便携版，在设置中保存 API Key 与可选的 Base URL。界面保留工作区、标签页、分屏、模型选择、工作文件夹、历史、图片和手机连接的操作。

安装版历史固定保存在 `%APPDATA%\TheAll`，源码开发版使用 `%APPDATA%\TheAll Development`；升级不会因为版本号改变而换数据目录。API Key 使用当前 Windows 账户的系统加密保存。手机与电脑连接同一可信 Wi-Fi 后，点击侧栏「连接手机」并扫码。

v0.1.8 提供未签名的 Windows 预览包。发布需通过 Windows x64 CI；安装升级、真实 CLI 和手机连接仍待实机验收，ARM64 交叉构建尚未在 ARM64 设备运行验证。
