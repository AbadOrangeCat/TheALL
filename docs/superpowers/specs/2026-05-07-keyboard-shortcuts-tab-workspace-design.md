# Tab / Workspace 切换快捷键 —— Design

## Context

theall 当前的 tab/workspace 导航快捷键集中在 Terminal 菜单：

- `⌘T` 新建 tab、`⌘W` 关闭 pane、`⌘D`/`⌘⇧D` 拆分
- `⌘⌥→/←` 在 pane 之间切焦点、`⌘⇧]/[` 在 tab 之间循环
- `⌘1…⌘9` 直接选当前 workspace 的第 N 个 tab

但**没有给 workspace 留键盘入口**——用户只能用鼠标点击侧栏切 workspace。Workspace 是 theall 的顶层导航单元（每个 workspace 是一组独立的 tabs），这种"必须离手到鼠标"的体验跟终端 app 的 keyboard-first 定位不符。

同时用户反馈 `Ctrl+Tab` / `Ctrl+Shift+Tab` 是浏览器 / iTerm2 / Warp 通用的"切换 tab"按键习惯，希望在 theall 里也能用。

本次改动加入：

1. **`Cmd+1…Cmd+9`** 切换到第 1…9 个 workspace（取代当前的"切到第 N 个 tab"绑定）
2. **`Cmd+Option+1…Cmd+Option+9`** 接管旧的"切到第 N 个 tab"
3. **`Ctrl+Tab` / `Ctrl+Shift+Tab`** 作为 `⌘⇧]/[` 的等价快捷键，循环切 tab

## Goals

- `Cmd+1-9` 直达 workspace；workspace 不足 N 时静默忽略
- `Cmd+Option+1-9` 仍然能直达当前 workspace 的第 N 个 tab（不丢功能，只是降一档）
- `Ctrl+Tab` / `Ctrl+Shift+Tab` 跟 `⌘⇧]/[` 行为完全一致：当前 workspace 内顺序循环，复用现有 `cycleTab(forward:)`
- 菜单里给 `Cmd+1-9` 切 workspace 留下可发现入口（File 菜单底部）
- 保留 `Cmd+Option+1-9` 的菜单项（沿用现有 ForEach，只改 modifier）
- `Ctrl+Tab` 不进菜单，跟 `⌘⌥↑/↓` 一样作为"intentional hidden duplicate"

## Non-Goals

- 不实现 `Cmd+Shift+T` 重开关闭的 tab（用户明确放弃）
- 不实现三指左右滑动切 tab（用户明确放弃）
- 不做 MRU（most-recently-used）顺序——`Ctrl+Tab` 也是 sequential，跟 `⌘⇧]/[` 同一个 `cycleTab` 实现
- 不为 `Cmd+1-9` 加 workspace 数量大于 9 时的"More…"或翻页菜单——超过 9 个的 workspace 只能鼠标点击或拖拽
- 不为 `Cmd+1-9` 在 workspace 数 < N 时弹 alert 或 beep；静默忽略
- 不开"Workspace"顶层菜单——`Cmd+1-9` 切 workspace 复用 File 菜单（"Workspace" 与 "New Workspace" 都是 workspace 级命令，归 File 一致）
- 不改 `⌘⌥→/←` / `⌘⇧]/[` / `⌘⌥↑/↓` 等现有绑定

## Architecture

```
[TheAllApp.swift @main]
   ├─ File menu
   │    ├─ New Workspace            ⌘N    → post(.theAllBeginCreateWorkspace)
   │    └─ Select Workspace 1…9     ⌘1…⌘9 → post(.theAllSelectWorkspaceAtIndex, idx)   ← 新增
   │
   └─ Terminal menu
        ├─ … (existing items)
        └─ Select Tab 1…9           ⌘⌥1…⌘⌥9 → post(.theAllSelectTabAtIndex, idx)       ← 改 modifier

[ContentView.swift Notification.Name]
   └─ + theAllSelectWorkspaceAtIndex                                                    ← 新增

[Sidebar/SidebarView.swift]
   └─ .onReceive(.theAllSelectWorkspaceAtIndex) { idx in                                ← 新增
        if idx < store.workspaces.count {
            store.select(id: store.workspaces[idx].id)
        }
      }

[TabContent/TabContentView.swift installKeyMonitor]
   └─ + Ctrl+Tab        keyCode 48 + .control          → cycleTab(forward: true)     ← 新增
   └─ + Ctrl+Shift+Tab  keyCode 48 + [.control,.shift] → cycleTab(forward: false)    ← 新增
```

### 数据流：`Cmd+1` 切 workspace

```
Cmd+1 keydown
   ↓
SwiftUI Commands → Button "Select Workspace 1" 触发
   ↓
post(.theAllSelectWorkspaceAtIndex, userInfo: ["index": 0])
   ↓
SidebarView.onReceive 收到
   ↓
store.workspaces[0] 存在 → store.select(id: workspaces[0].id)
   ↓
WorkspaceStore @Observable 触发 selectedId 变更
   ↓
SidebarListBridge / TabBridge.updateNSView 各自重渲
   ↓
TabContentView.reloadFromStore() 切到该 workspace 的 selectedTab
```

### 数据流：`Ctrl+Tab` 切 tab

```
Ctrl+Tab keydown
   ↓
TabContentView.keyMonitor (NSEvent.addLocalMonitorForEvents)
   ↓ 匹配 keyCode 48 (Tab) + .control 修饰
   ↓
cycleTab(forward: true)  // 现有方法，直接调，不走 NotificationCenter
   ↓
return nil  // 吃掉事件，不传给 ghostty surface
```

## Components

### 1. `TheAllApp.swift` — 菜单与快捷键绑定

**新增**：`@CommandsBuilder workspaceCommands`，发到 File 菜单。

```swift
@CommandsBuilder private var workspaceCommands: some Commands {
    CommandGroup(after: .newItem) {
        Divider()
        ForEach(1...9, id: \.self) { idx in
            Button(String(localized: L10n.Menu.selectWorkspaceN(idx)
                              .withLocale(LanguageStore.shared.locale))) {
                NotificationCenter.default.post(
                    name: .theAllSelectWorkspaceAtIndex,
                    object: nil,
                    userInfo: ["index": idx - 1])
            }
            .keyboardShortcut(KeyEquivalent(Character(String(idx))), modifiers: .command)
        }
    }
}
```

放置点：`var body: some Scene` 的 `.commands { ... }` 里。注意 `@CommandsBuilder` 的 10-element tuple 上限，本来 `terminalCommands` 已经独立出来；本次再独立 `workspaceCommands` 即可。

**改动**：`terminalCommands` 末尾的 `Cmd+1-9` ForEach 把 modifier 改为 `[.command, .option]`，并把文案 key 沿用现有 `L10n.Menu.selectTabN`：

```swift
ForEach(1...9, id: \.self) { idx in
    Button(String(localized: L10n.Menu.selectTabN(idx)...)) { ... }
        .keyboardShortcut(KeyEquivalent(Character(String(idx))),
                          modifiers: [.command, .option])  // ← 改这里
}
```

### 2. `ContentView.swift` — Notification 名字

```swift
extension Notification.Name {
    // ... 已有
    static let theAllSelectWorkspaceAtIndex = Notification.Name("theall.selectWorkspaceAtIndex")
}
```

### 3. `Sidebar/SidebarView.swift` — workspace 选择路由

`SidebarView` 是 SwiftUI 壳，`@Bindable var store: WorkspaceStore`，最适合接收这个 notification（不需要桥接 AppKit 层）。

加在 `.onReceive(NotificationCenter.default.publisher(for: .theAllBeginCreateWorkspace))` 旁边：

```swift
.onReceive(NotificationCenter.default.publisher(for: .theAllSelectWorkspaceAtIndex)) { note in
    guard let idx = note.userInfo?["index"] as? Int,
          idx >= 0, idx < store.workspaces.count else { return }
    store.select(id: store.workspaces[idx].id)
}
```

`WorkspaceStore.select(id:)` 内部已有 `guard contains` 防御（见 `WorkspaceStore.swift:92-95`），双重保险无副作用。

### 4. `TabContent/TabContentView.swift` — Ctrl+Tab key monitor

在现有 `installKeyMonitor()` 里追加分支：

```swift
private func installKeyMonitor() {
    keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
        guard let self else { return event }

        // 只看 ⌘⌃⌥⇧ 这四位，忽略 .numericPad / .function / .capsLock
        let interesting: NSEvent.ModifierFlags = [.command, .control, .option, .shift]
        let mods = event.modifierFlags.intersection(interesting)

        // 已有：⌘⌥↑/↓
        if mods == [.command, .option] {
            switch event.keyCode {
            case 125: self.focusAdjacentPane(forward: true);  return nil
            case 126: self.focusAdjacentPane(forward: false); return nil
            default: break
            }
        }

        // 新增：Ctrl+Tab / Ctrl+Shift+Tab（keyCode 48 = Tab）
        if event.keyCode == 48 {
            if mods == [.control] {
                self.cycleTab(forward: true);  return nil
            }
            if mods == [.control, .shift] {
                self.cycleTab(forward: false); return nil
            }
        }

        return event
    }
}
```

`window?.isKeyWindow` 不需要在这里检查——`addLocalMonitorForEvents` 只接收当前进程 key window 的事件，且 `cycleTab` 自己又 guard 了 `selectedWorkspace` 是否存在。

> **为什么不放 menu**：跟代码里现有注释一致："intentional hidden duplicates not shown in the menu, kept because they're a common pane-nav habit"。`Ctrl+Tab` / `⌘⇧]` 是同一动作的两种习惯；菜单里只展示一种，避免菜单 blink + 重复展示。

### 5. i18n — 9 个新文案

`Localization/L10n.swift`：

```swift
enum Menu {
    // ... 已有
    static func selectWorkspaceN(_ n: Int) -> LocalizedStringResource {
        LocalizedStringResource("menu.terminal.selectWorkspace.\(n)")
    }
}
```

`Localization/Localizable.xcstrings`：9 条，比照现有 `menu.terminal.selectTab.N` key：

| Key | English | 简体中文 |
|-----|---------|----------|
| `menu.terminal.selectWorkspace.1` | Select Workspace 1 | 选择工作区 1 |
| … `.2-.9` | Select Workspace N | 选择工作区 N |

> 命名 key 复用 `menu.terminal.*` 前缀只是为了跟现有 `selectTab.N` 风格一致；实际菜单挂在 File 菜单底下。这不是错的——`menu.terminal` 是历史前缀，不影响 UI。

`TheAllTests/L10nSmokeTests.swift`：在现有 smoke test 列表里加这 9 个 key（覆盖中英）。

## Boundary Conditions

| 条件 | 行为 |
|------|------|
| `Cmd+5` 但只有 3 个 workspace | 静默忽略——`SidebarView.onReceive` 的 `guard idx < count` 直接 return；`store.select(id:)` 也 guard contains |
| `Cmd+1` 当前已经是第 1 个 workspace | `select(id:)` 把 selectedId 设成同样的值；@Observable 不会触发实际重渲（值未变），无副作用 |
| `Ctrl+Tab` 但当前 workspace 只有 1 个 tab | `cycleTab` 算 `(0 + 1) % 1 = 0`，`store?.selectTab(id: same, in: ws)`；同上无副作用 |
| 终端里运行 `vim` / TUI app 用 `Ctrl+Tab` 做窗口切换 | 被 theall 拦截，**不会**传给 ghostty surface。考虑到 `Ctrl+Tab` 在主流终端 TUI 里用得极少（vim/tmux 都不默认绑），可以接受 |
| `Cmd+Option+5` 但当前 workspace 只有 3 个 tab | `selectTab(at:)` 已有 `guard index < ws.tabs.count`，静默忽略（与改前 `Cmd+5` 行为一致） |
| `Cmd+1-9` 跟 NSWindow 的"显示主窗口"系统快捷键冲突 | macOS 系统级没占用 `⌘1-9`；app 自己的 keyEquivalent 会优先 |
| 同时多个 theall 窗口（多 workspace 多窗口场景） | `theAllSelectWorkspaceAtIndex` 是广播；但 `WorkspaceStore.selectedId` 是单例 store 上的状态，所有窗口共享。当前 theall 是单 WindowGroup 单 store 模式，不会出现多窗口分歧 |

## i18n

新增 9 条 key（中英），格式参照现有 `menu.terminal.selectTab.N`。Smoke test 加入 9 条。

## Testing

theall 现有测试以 model 层为主，键盘绑定难单测。本次改动单测覆盖：

- `WorkspaceStoreTests`：`select(id:)` 在 id 不在 workspaces 中时不改 `selectedId`（这是已有行为，加测验回归即可）
- `L10nSmokeTests`：9 条新 i18n key 在中英下都解析

手动验证清单（写进 PR description 取代默认 test plan，按照用户记忆 `feedback_pr_body_no_test_plan` 的精神浓缩）：

1. 多个 workspace 时 `Cmd+1`/`Cmd+2`/`Cmd+3` 切 workspace
2. 只有 2 个 workspace 时 `Cmd+9` 无反应（不 beep）
3. `Cmd+Opt+1`/`Cmd+Opt+2` 切当前 workspace 的 tab
4. `Ctrl+Tab` / `Ctrl+Shift+Tab` 在 1 个 tab、3 个 tab 时分别表现
5. 终端聚焦在 `vim` 时按 `Ctrl+Tab` —— theall 切 tab，shell 不收到 `\t`
6. File 菜单里能看到 "Select Workspace 1" 到 "Select Workspace 9"，快捷键显示 `⌘1`…`⌘9`
7. Terminal 菜单里 "Select Tab 1" 显示 `⌘⌥1`（不再是 `⌘1`）
8. 中英语言切换后，菜单文案跟随变更

## Documentation Updates

按 CLAUDE.md "文档与目录结构同步"约定，本次改动**不新增/重命名/移动 Swift 文件**，仅在已有文件内追加方法/分支/i18n 文案。Directory Structure 无变动，无需改 CLAUDE.md / AGENTS.md。

`docs/architecture.md` 里"Keyboard Shortcuts"或"Menu Commands"章节如果列了完整快捷键表，需要同步更新（实施时检查；如不存在则跳过）。

## Open Questions

无。

## Out of Scope (确认放弃)

- `Cmd+Shift+T` 重开关闭的 tab
- 三指左右滑动切 tab
