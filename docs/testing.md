# Testing

## Windows desktop

Run `npm ci --prefix desktop` and `npm ci --prefix mobile-relay`, then `npm test --prefix desktop`, `node --test mobile-tests/*.test.mjs`, `npm test --prefix mobile-relay`, and `npm run test:desktop --prefix desktop`. The last command launches an isolated Electron profile with an offline CLI fixture. It forwards real IPC frame metadata through distinct wrappers to cover Electron frame-wrapper identity, then exercises startup, the actual provider/API/folder buttons, IPC isolation, sends, collapsed progress, prompt recall, encrypted credentials, split layout, dirty drafts saved during Quit and history after reopening. Unit tests also reject other windows, child/detached frames, stale documents and mismatched origins. It never opens the user's Mac application. Windows uses real DPAPI; macOS UI verification substitutes encryption only inside the test process to avoid Keychain changes.

Every Windows packaging command also runs `desktop/scripts/after-pack.mjs`. It verifies the production dependency closure, including non-optional peer dependencies, from the actual `app.asar` and generates/restores a TLS identity using only its bundled modules. Then it copies the artifact outside the checkout and runs the desktop smoke again. Matching Windows hosts launch the real packaged `TheAll.exe` and assert `app.isPackaged`; cross-builds run the production ASAR on host Electron. The latter does not claim ARM64 executable acceptance. Clearing `NODE_PATH`/`NODE_OPTIONS` and using a temporary application directory prevents missing modules from falling back to development dependencies. A failed package check aborts packaging before artifacts are uploaded.

`desktop/test/runtime-regressions.test.mjs` covers concurrent CLI recovery, revocation during model acknowledgement, shutdown during decryption, uncertain submission persistence and damaged-store preservation. `desktop/test/runtime-lifecycle.test.mjs` additionally verifies deletion during process shutdown, relay cancellation and credential changes during startup. TLS and relay tests use real local network connections. Optional installed-CLI tests use the loopback fake gateway, never a live API account. See [Windows validation](windows.md#validation) for commands and native acceptance requirements. A cross-build or a configured workflow does not count as a completed Windows run.

The following XCTest instructions apply to macOS.

## Test Strategy

| 类型 | 覆盖 | 工具 |
|------|------|------|
| 单元测试 | ThemeManager 解析、WorkspaceStore CRUD、frame 计算 | XCTest |
| 集成测试 | GhosttyBridge surface 创建/销毁（需 libghostty） | XCTest |
| UI 快照测试 | 侧边栏深色/浅色渲染 | XCTest + `XCTAttachment` |
| 手动验收 | 拖拽、workspace 切换、OSC 通知 | 人工 |

## Running Tests

```bash
# 所有测试
./scripts/test-local.sh

# 单个测试文件
./scripts/test-local.sh \
  -only-testing:TheAllTests/WorkspaceStoreTests
```

## 测试应用与真实数据隔离

`test-local.sh` 固定使用 `../work/TestDerivedData` 和 `com.theall.tests.local`；开发版继续使用 `../work/DerivedData` 和 `Local.xcconfig` 中的身份。测试脚本仅接受 `-only-testing:...` / `-skip-testing:...` 选择器，不透传构建覆盖参数，并清除进程环境中的 `XCODE_XCCONFIG_FILE`。Xcode 在测试编译失败前也可能写入测试 Info.plist，因此不能只在测试后重建开发版补救，两者必须始终使用不同目录。测试不会替换用户会打开的 TheAll.app。

若误开测试宿主，界面会读取测试工作区，真实历史仍在原身份的数据目录中。恢复正常构建、完全退出测试宿主再打开开发版即可；不要为了空白界面清除 UserDefaults、聊天文件或 API 连接。

## Test Files

```
TheAllTests/
├── ThemeManagerTests.swift       — 主题解析、降级逻辑
├── WorkspaceStoreTests.swift     — CRUD、持久化、selectedId 状态
└── MetadataRefresherTests.swift  — git/port 解析逻辑
```

## WorkspaceStore 隔离

每个测试用独立 persistenceKey，避免测试间互相污染：

```swift
let store = WorkspaceStore(persistenceKey: "test.\(UUID())")
```

**不要**用 `.testable` import 加 `@testable`，WorkspaceStore 已是 internal，直接测试公开接口。

## libghostty 集成测试

需要 libghostty 存在（`Vendor/ghostty/lib/libghostty.a`）。
标注方式：

```swift
// Integration: requires libghostty
func test_surfaceCreation_succeedsWhenBridgeInitialized() { ... }
```

CI 中可用环境变量跳过：
```swift
try XCTSkipIf(ProcessInfo.processInfo.environment["SKIP_GHOSTTY_INTEGRATION"] == "1")
```

## What to Test

**ThemeManager:**
- ghostty config 包含有效颜色时，tokens 正确映射
- ghostty config 缺失/解析失败时，降级到系统模式
- `applyScheme(.dark/.light/.system)` 后 `currentTheme` 正确更新

**WorkspaceStore:**
- `createWorkspace` 后 `workspaces` 包含新项
- `deleteWorkspace` 后 `selectedId` 切换到下一个可用 workspace
- `updateTerminalFrame` 正确更新嵌套 frame
- 持久化：编码再解码后数据一致
- 空列表时自动创建 Default workspace（仅默认 key）

**MetadataRefresher:**
- git branch 解析：`refs/heads/main` → `"main"`
- `onRefresh` 回调在主线程触发（async 路径）

> 端口列表 (`listeningPorts`) 与 OSC 通知文本 (`latestNotification`) 字段在
> 2026-04-16 sidebar 重构后从 row 视觉中移除：前者整个删除，后者保留在
> `WorkspaceMetadata` 但当前 `WorkspaceRowItemView` 不渲染——后续若决定恢复
> 显示，需要扩展 row 高度并补回测试。

## 自动更新验证

- `./scripts/test-local.sh -only-testing:TheAllTests/UpdateStoreTests -only-testing:TheAllTests/UpdateLifecycleTests`：共享状态、重复检查、下载取消、错误回调、开发版安装限制、运行回合结束后才安装。测试注入安装回调，不重启真实应用，不访问线上 feed。
- `node --test scripts/prepare-update-feed.test.mjs`：更新包签名、错误私钥、篡改检测、XML 内容、私钥权限以及校验文件不包含私钥。
- `npm test --prefix desktop`：稳定版/架构/资产选择、下载校验、IPC 权限、安装门闩和历史保存。Windows 专用 helper 测试必须使用临时 fixture，不可将真实程序目录作为替换目标。
- `npm run test:desktop --prefix desktop`：隔离 Electron profile、fake CLI 和真实 UI 操作；不能给开发实例打开线上自动安装开关来代替测试。

手工验收使用独立的旧/新测试 app、独立 bundle ID / profile 和临时目录。正常路径验证侧栏手机按钮上方的新版本卡片、下载进度、任务运行时等待、任务结束后保存/安装/重启及原会话恢复；异常路径验证网络中断、错误 hash/签名、磁盘写入失败和安装失败可恢复。macOS Debug 允许检查但禁止替换为正式发布应用；无新版或后台检查失败时不应出现“有新版本”卡片，设置页仍保留真实错误。手机 API 不得调用安装接口。

发布验收核对最新稳定 Release 的所有资产先完整上传，再对外公开；macOS appcast 的版本/build、Ed25519 签名和下载 URL 必须匹配同一包。Windows 应分别验收 x64/ARM64 与 NSIS/portable/ZIP；跨构建成功不代表 ARM64 实机安装已验证。保留当前运行的开发应用，不能用它做真实自更新测试。

## Completion notifications, timing and reasoning effort

Run `./scripts/test-local.sh` for the isolated native suite, `node --test mobile-tests/*.test.mjs` for mobile shell/worker logic, and `npm test --prefix desktop` for Windows runtime logic. `npm run test:desktop --prefix desktop` checks the real sandboxed Electron UI, completion timestamps and reasoning-effort drafts across Quit/reopen, including temporarily unavailable model metadata. Installed provider CLIs can be verified offline with `THEALL_TEST_INSTALLED_CLIS=1 node --test desktop/test/ai.integration.test.mjs`; the fixture uses a fake key and a loopback-only gateway.

Notification tests verify the official RFC 8291 encryption vector, VAPID signatures, authorized device/scope/origin routing, revocation/cancellation, expired subscriptions, duplicate completion events and history restore. They never send a real phone notification. Physical acceptance requires an HTTPS mobile connection and explicit notification opt-in; iPhone uses the installed Home Screen web app. Test with the web app closed and the phone locked, then check Apple Watch or Wear OS notification mirroring under the device's normal notification/Focus settings. Plain HTTP LAN pairing remains usable for chat but cannot provide background push.


### 普通文件附件

原生 `AIChatFileTests` 与 `MobileAccessTests` 验证私有副本、空文件/Unicode、符号链接/大小/hash拒绝、混合批次回滚、两种CLI的文件清单、v3历史恢复以及手机权限/幂等发送。`mobile-tests/mobile-files.test.mjs` 与浏览器smoke覆盖统一按钮、混合拖放、5语言、只文件发送及失败保留；desktop/runtime/attachment测试和隔离Electron smoke验证Windows独立草稿存储、缺失文件恢复与退出保存。真实CLI集成仅对本地假API运行，读取合成文件验证原始字节。relay测试覆盖接近最大组合上传和10MiB私有下载，保持无缓存与原有鉴权。

## 任务中 Steer

`AIChatSteeringTests` covers same-turn Codex requests, task-token races, attachment validation, revoked authorization, independent remote drafts, lost/late ACKs, deferred completion, and Claude single/two-result lifecycle coalescing. `MobileAccessTests` verifies the scoped/idempotent `/steer` route. Desktop AI/runtime tests mirror the protocol and access cases; installed-CLI offline integration uses a local fake gateway to verify actual Claude/Codex steer input without real API calls. Browser/Electron smoke covers keyboard steering, attachments, rejection/unknown-result retry, same-round grouping and narrow five-language controls. Stop must cancel queued Claude instructions; a steer must not reset elapsed time or send an early completion notification.
