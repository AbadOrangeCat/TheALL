# TheAll

English · [简体中文](README.zh-CN.md)

TheAll **0.1.3** is a macOS workspace for Claude Code and Codex, with a native chat composer, model picker, workspaces, tabs, and split panes.

## Usage

1. Open a tab and choose a working folder and Claude / OpenAI.
2. Reuse the saved connection or enter an API key and optional custom Base URL. Connections are stored in macOS Keychain.
3. Chat in the native composer and select a model below it. Model changes preserve the conversation and draft.
4. Click the folder path at the bottom of the chat to change the working directory after the current task finishes.

The transcript shows replies, progress, and thinking returned by the provider, while hiding routine tool records. Tool operations run automatically; questions requiring your answer remain visible. Completed thinking and progress messages collapse individually while the final answer stays visible. User questions have a tinted background; workspaces are named from the first submitted question. Automatic updates are not configured.

## Local build

Requires macOS 14+, Xcode, XcodeGen, and the Claude Code or Codex CLI for the selected provider. The project, app target, module and source directory are named `TheAll`; the test target is `TheAllTests`.

```bash
# Only when the Ghostty build artifacts are missing
./scripts/build-vendor.sh
xcodegen generate
# Once, if Local.xcconfig does not exist: keep this identity for later builds
bash scripts/setup-local-signing.sh
xcodebuild -project TheAll.xcodeproj -scheme TheAll -configuration Debug build
```

The product is `TheAll.app`; Debug windows display **TheAll dev**. Quit the older app and open the new build manually to use changes.

[AI chats](docs/ai-terminals.md) · [Build guide](docs/build.md) · [Architecture](docs/architecture.md)

## License

Public source availability does not grant a general reuse or redistribution license. See [`LICENSE`](LICENSE). Separately granted permissions and third-party component licenses remain applicable.
