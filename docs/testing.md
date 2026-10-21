# Testing

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
xcodebuild test -project TheAll.xcodeproj -scheme TheAllTests

# 单个测试文件
xcodebuild test -project TheAll.xcodeproj -scheme TheAllTests \
  -only-testing:TheAllTests/WorkspaceStoreTests
```

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

## 手动 QA：自动更新

依赖已经发布到 GitHub Releases 的 v0.1.0 + 一个本地构建的"伪低版本"。

1. 把 `project.yml` 里 `MARKETING_VERSION` 临时改成 `0.0.9`，`xcodegen generate`，构建 Release：
   ```bash
   xcodebuild -project TheAll.xcodeproj -scheme TheAll -configuration Release build
   ```
2. 启动产物。~3 s 内 sidebar 左下角红点应亮起。
3. 点版本号，Settings 应直接定位到 Update section，显示 `Version 0.1.0 is available` + release notes。
4. 点 `Download & Install`：进度 0-100%，app 退出并重启。重启后版本显示 `v0.1.0`，红点消失。
5. 重复 1-3。点 `Skip This Version`：红点立刻消失，关闭 app 再开不再提醒 0.1.0。发布一个 0.1.1（测试用）后红点重新出现。
6. 断网，点 `Check for Updates`：显示红色错误卡 + Retry 按钮。
7. Debug 构建：启动后无论如何不应发 appcast 请求；Update section 的 button 为 disabled，hint 行可见。

完事把 `MARKETING_VERSION` 改回。
