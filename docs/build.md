# Build & Vendor

## Prerequisites

- macOS 14+
- Xcode 15+
- `xcodegen` (`brew install xcodegen`)
- Zig（构建 libghostty 需要，`brew install zig`）

## First-time Setup

```bash
# 1. 构建 libghostty 静态库（只需一次）
./scripts/build-vendor.sh

# 2. 生成 Xcode 工程
xcodegen generate

# 3. 验证构建
xcodebuild -project TheAll.xcodeproj -scheme TheAll -configuration Debug build
```

## project.yml

`project.yml` 是 xcodegen 配置，定义 target、依赖、编译选项。
**修改后必须重新运行 `xcodegen generate`**，否则 Xcode 工程不更新。

修改场景：
- 添加新的 Swift 文件目录
- 添加系统 framework 依赖
- 修改 deployment target

修改 `project.yml` 需要人工确认（见 AGENTS.md Agent Permissions）。

## Vendor 目录

```
Vendor/
└── ghostty/
    ├── include/ghostty.h    — C API 头文件
    └── lib/libghostty.a     — 静态库（gitignored）
```

`libghostty.a` 已加入 `.gitignore`，每台机器首次使用需运行 `scripts/build-vendor.sh` 构建。

## Build Settings (project.yml)

| 设置 | 值 | 原因 |
|------|-----|------|
| `LIBRARY_SEARCH_PATHS` | `$(PROJECT_DIR)/Vendor/ghostty/lib` | 链接 libghostty.a |
| `HEADER_SEARCH_PATHS` | `$(PROJECT_DIR)/Vendor/ghostty/include` | 找到 ghostty.h |
| `OTHER_LDFLAGS` | `-lghostty -lc++ -framework Carbon` | ghostty 依赖 |
| `SWIFT_OBJC_BRIDGING_HEADER` | `TheAll/Ghostty/ghostty-bridging-header.h` | Swift ↔ C 桥接 |
| `LD_RUNPATH_SEARCH_PATHS` | `""` | 静态库不需要 rpath |

## CI 注意事项

- CI 环境需要预置 Vendor/ghostty（或在 CI 里运行 build-vendor.sh）
- 在 release workflow 里 libghostty 单独跑在一个 `macos-15` job 上构建，再以
  artifact 传给主 `macos-26` build job —— 因为 zig 0.15.2 自带的 darwin libc
  tubs 与 macOS 26 SDK 的 libSystem.tbd 不兼容（compiler_rt 引用的
  `__availability_version_check` 等符号在新 SDK 上找不到），而 macos-26
  runner 又只装了 macOS 26.x SDK 没有老 SDK 兜底。等 ghostty 上游适配
  zig 0.16+ 后可以删掉这个分离 job
- 设置 `SKIP_GHOSTTY_INTEGRATION=1` 可跳过需要 libghostty 的集成测试
- `xcodebuild` 需要 `-destination 'platform=macOS'` 在非 GUI 环境下运行

## TheAll 本地构建

当前版本为 **0.1.3**，产物为 `TheAll.app`（Debug 显示名 `TheAll dev`）。
工程、target 和 module 统一为 `TheAll`，测试宿主为 TheAll.app。
应用没有配置自动更新：发布前需设置自有 `SUFeedURL` 和 `SUPublicEDKey`，
不能复用上游更新源或签名。当前仅进行本地构建，发布已暂停。下文记录未来发布所需的准备。

## TheAll 本地签名与钥匙串

API Key 保存在登录钥匙串。现代钥匙串对自签名程序同时检查证书 ACL 和二进制 CDHash partition；**固定证书还不足以保证跨构建读取**。TheAll 使用首次安装后保持不变的独立凭据 helper，隔离 UI 更新与 Keychain 调用者身份。应用和 helper 通过同证书及 identifier 相互验证，参见 [Apple TN3127](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements) 和 [securityd partition 实现](https://github.com/apple-oss-distributions/Security/blob/main/securityd/src/clientid.cpp)。

已有 Apple Development 证书时可使用 `Local.xcconfig.example` 配置团队。
没有证书时，可执行 `bash scripts/setup-local-signing.sh` 创建本地开发身份。
脚本将私钥导入登录钥匙串，仅允许 codesign 使用，并生成 gitignored
`Local.xcconfig`；已有本地配置时会退出，不覆盖。它不修改系统或用户 trust
设置，也不会把私钥保存在仓库中。首次 codesign 可能要求用户在系统窗口输入
登录密码并选择 Always Allow；这是签名私钥授权，与应用读取 API Key 无关。

保留这份证书和 Local.xcconfig，后续 Debug 构建**不要传入
`CODE_SIGN_IDENTITY=-`**。`Config.xcconfig` 的 `THEALL_CODE_SIGN_STYLE` 默认是
Automatic，本地 Debug 可改为 Manual。Release 保持独立配置；自签名证书仅用于
本机开发，不等于发布签名或公证。可用 `codesign -d -r- <TheAll.app>` 检查 DR
包含 identifier 与 certificate leaf，而不是只包含 cdhash。 `TheAllCredentialHelper`
target 也使用同一证书，独立启用 hardened runtime，不注入调试 entitlements。
构建时嵌入 `Contents/Helpers/TheAllCredentialHelper`；首次使用后在
`Application Support/<bundleID>/CredentialHelper/<certificateHash>/v1/` 保留原件。
**后续构建不得清理、覆盖或重新签名该已安装 helper。** helper 协议升级需设计
旧 helper → 新命名空间的迁移，不能用替换二进制的方式更新现有 Keychain 调用者。

应用的钥匙串操作不弹系统授权框。旧签名的 API Key 若无法静默读取，需在连接
表单中重新填写一次；新连接由固定 helper 另存为 `.ai-connections.v3`，旧条目保留。登录钥匙串
锁定时需先解锁。不要用“允许所有应用访问”或明文保存 API Key 来消除提示。

## Release 流程

### 发布准备（尚未发布）

当前 GitHub 仓库为 `AbadOrangeCat/TheALL`。当前本地构建目标为 **macOS 14+ / Apple Silicon（arm64）**；不要把当前只含 arm64 的 Ghostty 静态库打包成 universal。

现有本地证书不属于 Apple Developer ID，不能提供 Apple 公证。GitHub 仓库已公开，但尚未发布 Release；源码使用与分发遵循当前 LICENSE、单独授予的书面许可及第三方组件许可证。应用内自动更新尚未配置，因此不生成 Sparkle appcast。

1. 运行测试、文档漂移检查，并核对 `MARKETING_VERSION` 与发布 tag。
2. 使用已保存的固定签名证书构建当前源码的 Release，而非复用旧构建目录。示例（`SIGNING_IDENTITY` 为已有证书 SHA-1，不是私钥）：

   ```bash
   xcodebuild build -project TheAll.xcodeproj -scheme TheAll \
     -configuration Release -destination 'platform=macOS,arch=arm64' \
     -derivedDataPath build ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
     CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$SIGNING_IDENTITY"
   ```

   不要全局覆盖 `OTHER_CODE_SIGN_FLAGS`：helper target 通过这个字段设置独立 identifier。app 的 identifier 应为 `com.theall.app`，helper 应为 `com.theall.app.credential-helper`，二者必须使用同一证书。ad-hoc 签名缺少证书，无法使用当前凭据 helper。
3. 核对版本、架构及 `Contents/Helpers/TheAllCredentialHelper`，运行 `codesign --verify --deep --strict`，将应用和许可证打包成 DMG，另生成 SHA256 校验文件。
4. 提交代码后给对应提交打 `v0.1.3` annotated tag。准备对应版本的发布说明，用 `gh release create --verify-tag --notes-file <发布说明>` 上传安装包和校验文件。
5. 核对远端提交、tag、发布页及安装包下载校验和一致。

### 未来的 Developer ID / 公证发布

`.github/workflows/release.yml` 仅通过 **workflow_dispatch** 手动启动，不会因代码推送自动发布。启用前需在仓库配置以下 secrets，并验证 Ghostty/SDK 的 CI 构建兼容性：

- `APPLE_DEVELOPER_ID_CERT_P12`、`APPLE_DEVELOPER_ID_CERT_PASSWORD`
- `APPLE_SIGNING_IDENTITY`、`APPLE_TEAM_ID`
- `APPLE_API_KEY_ID`、`APPLE_API_ISSUER_ID`、`APPLE_API_KEY_P8`
- `SPARKLE_ED_PRIVATE_KEY`，以及应用自己的 `SUFeedURL` 和 `SUPublicEDKey`

工作流执行签名、公证、DMG 打包和 Sparkle 签名。保留 app/helper 的各自签名参数，并在提交公证前验证两者的 identifier 和证书。仅本地签名的安装包不能宣称已公证。

## Retaining an existing local installation

The tracked defaults use `com.theall.app.dev` for Debug and `com.theall.app` for Release. If a locally signed installation uses another identifier, keep that identifier in ignored `Local.xcconfig` with `THEALL_APP_IDENTIFIER[config=Debug]`, alongside the same signing certificate. This preserves the existing helper, API credentials, chat history, Claude session data and mobile pairing identities. Set `THEALL_PREVIOUS_NAMESPACE[config=Debug]` only when preference/config keys also need migration. The app copies those settings once at startup, preserves the source and does not overwrite destination settings. Changing the application identifier without a separate data/credential migration creates a different installation.

Use an isolated `THEALL_APP_IDENTIFIER=com.theall.tests.local` and an empty `THEALL_PREVIOUS_NAMESPACE=` for test-host runs so tests do not write the development installation’s preferences.
