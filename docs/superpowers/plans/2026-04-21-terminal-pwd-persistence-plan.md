# Terminal PWD Persistence & Inheritance Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让新建 tab / 新建 workspace / 拆分 pane 时新 terminal 继承当前焦点 pane 的 pwd，并让 app 重启后每个 terminal 恢复到关闭前的目录。

**Architecture:** 把 `TerminalPwdStore` 升级为 UserDefaults 持久化源（pwd 继承 + 重启还原共用），新增 `inherit(from:to:)` API；`WorkspaceStore.addTab` / `createWorkspace` 扩展返回值以暴露新 terminalId；`GhosttyTerminalView` 从注入的 pwdStore 读 seed、用 FileManager 校验目录有效性，传给 `GhosttyBridge.newSurface`。失效路径静默回退到 ghostty 默认 `$HOME`。

**Tech Stack:** Swift / AppKit / SwiftUI / XCTest / UserDefaults / libghostty C API

**Spec:** `docs/superpowers/specs/2026-04-21-terminal-pwd-persistence-design.md`

---

## File Structure

**Modified (7):**
- `TheAll/Models/TerminalPwdStore.swift` — 加持久化、debounce save、`inherit` API
- `TheAll/Models/WorkspaceStore.swift` — `addTab` 改返回 `(tabId, terminalId)?`、`createWorkspace` 改返回 `UUID?`
- `TheAll/Ghostty/GhosttyTerminalView.swift` — 加 `pwdStoreRef`、`validatedDirectory` static helper、`viewDidMoveToWindow` 读 seed
- `TheAll/Bridge/TabBridge.swift` — 加 `pwdStore` 参数，转给 `TabContentView`
- `TheAll/TabContent/TabContentView.swift` — 加 `var pwdStore`、在 `terminalViewFor` 赋给 view、归一 `addNewTab`、三处 inherit 接线
- `TheAll/Sidebar/SidebarView.swift` — `createWorkspaceWithDefaultName` 加 inherit
- `TheAll/ContentView.swift` — 把 `pwdStore` 传给 `TabBridge`

**Modified tests (1):**
- `TheAllTests/WorkspaceStoreTests.swift` — 两处捕获 `addTab` 返回值的测试改用 `.tabId`

**Created tests (2):**
- `TheAllTests/TerminalPwdStoreTests.swift` — 新（持久化 round-trip、inherit、forget save）
- `TheAllTests/GhosttyTerminalViewPwdTests.swift` — 新（`validatedDirectory` 分支覆盖）

**Docs (1):**
- `docs/architecture.md` — 更新 `TerminalPwdStore` 段落（不再 "session-scoped only"）、`newSurface` 条目 workingDirectory 含义

---

## Task 1: `TerminalPwdStore` 加持久化 + `inherit` API

**Files:**
- Modify: `TheAll/Models/TerminalPwdStore.swift`
- Create: `TheAllTests/TerminalPwdStoreTests.swift`

- [ ] **Step 1.1: 写失败测试 — init with persistenceKey 不加载不存在 key**

Create `TheAllTests/TerminalPwdStoreTests.swift`:

```swift
import XCTest
@testable import TheAll

final class TerminalPwdStoreTests: XCTestCase {

    func testDefaultIsEmpty() {
        let store = TerminalPwdStore(persistenceKey: "test-\(UUID())")
        XCTAssertNil(store.pwd(for: UUID()))
    }
}
```

- [ ] **Step 1.2: 运行测试，验证编译失败**

```bash
xcodebuild test -project TheAll.xcodeproj -scheme TheAllTests \
  -only-testing:TheAllTests/TerminalPwdStoreTests/testDefaultIsEmpty 2>&1 | tail -20
```

Expected: build FAIL — `TerminalPwdStore` 当前 `init()` 不接受 `persistenceKey` 参数。

- [ ] **Step 1.3: 实现 persistenceKey init + load**

Replace contents of `TheAll/Models/TerminalPwdStore.swift` with:

```swift
import Foundation
import Observation

/// Per-terminal working directory keyed by the terminal UUID. Populated by
/// `GhosttyBridge.onPwdChanged` → main-queue callback; each PTY shell emits OSC 7
/// (`kitty-shell-cwd://`) on startup and every `chpwd`, which ghostty forwards as
/// `GHOSTTY_ACTION_PWD`.
///
/// Persisted to UserDefaults under `theall.pwds.v1` so that on app restart each
/// terminal can reopen in its previous directory. Writes are debounced (300 ms)
/// because `cd`-heavy workflows would otherwise trigger hundreds of writes per
/// second. `GhosttyTerminalView.viewDidMoveToWindow` reads this store to seed
/// `ghostty_surface_config.working_directory` — that's how both "inherit from
/// source pane" (new tab / split / new workspace) and "restore on relaunch"
/// resolve through a single mechanism.
@Observable
final class TerminalPwdStore {
    private var storage: [String: String] = [:]
    private let persistenceKey: String
    private var saveWorkItem: DispatchWorkItem?

    init(persistenceKey: String = "theall.pwds.v1") {
        self.persistenceKey = persistenceKey
        load()
    }

    func pwd(for terminalId: UUID) -> String? {
        storage[terminalId.uuidString]
    }

    func setPwd(_ pwd: String, for terminalId: UUID) {
        storage[terminalId.uuidString] = pwd
        scheduleSave()
    }

    /// Copy `source`'s pwd onto `dest` so the next surface created for `dest`
    /// spawns its shell in that directory. No-op when source has no record
    /// (first-run / shell hasn't emitted OSC 7 yet).
    func inherit(from source: UUID, to dest: UUID) {
        guard let src = storage[source.uuidString] else { return }
        storage[dest.uuidString] = src
        scheduleSave()
    }

    func forget(terminalId: UUID) {
        storage.removeValue(forKey: terminalId.uuidString)
        scheduleSave()
    }

    func pwdsSnapshot() -> [UUID: String] {
        var out: [UUID: String] = [:]
        for (k, v) in storage {
            if let id = UUID(uuidString: k) { out[id] = v }
        }
        return out
    }

    // MARK: - Persistence

    private func scheduleSave() {
        saveWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.save() }
        saveWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: item)
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(storage) else { return }
        UserDefaults.standard.set(data, forKey: persistenceKey)
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: persistenceKey),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data)
        else { return }
        storage = decoded
    }
}
```

- [ ] **Step 1.4: 运行测试，验证 testDefaultIsEmpty 通过**

```bash
xcodebuild test -project TheAll.xcodeproj -scheme TheAllTests \
  -only-testing:TheAllTests/TerminalPwdStoreTests/testDefaultIsEmpty 2>&1 | tail -20
```

Expected: PASS.

- [ ] **Step 1.5: 添加 round-trip 持久化测试**

Append to `TheAllTests/TerminalPwdStoreTests.swift` inside the class:

```swift
    func testSetPwdPersists() {
        let key = "test-\(UUID())"
        let id = UUID()
        do {
            let store = TerminalPwdStore(persistenceKey: key)
            store.setPwd("/tmp/foo", for: id)
            // 触发私有 save — 通过手动刷新 debounce
            _ = store.pwdsSnapshot()  // access for @Observable trace
        }
        // 等待 debounce（0.3s）；XCTest 里用 expectation 同步等
        let exp = expectation(description: "debounce")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)

        let store2 = TerminalPwdStore(persistenceKey: key)
        XCTAssertEqual(store2.pwd(for: id), "/tmp/foo")

        // cleanup
        UserDefaults.standard.removeObject(forKey: key)
    }
```

- [ ] **Step 1.6: 运行测试，验证持久化 round-trip 通过**

```bash
xcodebuild test -project TheAll.xcodeproj -scheme TheAllTests \
  -only-testing:TheAllTests/TerminalPwdStoreTests/testSetPwdPersists 2>&1 | tail -20
```

Expected: PASS.

- [ ] **Step 1.7: 添加 inherit 行为测试**

Append inside the class:

```swift
    func testInheritCopiesPwd() {
        let store = TerminalPwdStore(persistenceKey: "test-\(UUID())")
        let src = UUID(); let dst = UUID()
        store.setPwd("/tmp/bar", for: src)
        store.inherit(from: src, to: dst)
        XCTAssertEqual(store.pwd(for: dst), "/tmp/bar")
    }

    func testInheritWithoutSourceIsNoop() {
        let store = TerminalPwdStore(persistenceKey: "test-\(UUID())")
        let src = UUID(); let dst = UUID()
        store.inherit(from: src, to: dst)
        XCTAssertNil(store.pwd(for: dst))
    }

    func testForgetRemovesEntry() {
        let store = TerminalPwdStore(persistenceKey: "test-\(UUID())")
        let id = UUID()
        store.setPwd("/tmp/baz", for: id)
        store.forget(terminalId: id)
        XCTAssertNil(store.pwd(for: id))
    }

    func testPwdsSnapshotReturnsAll() {
        let store = TerminalPwdStore(persistenceKey: "test-\(UUID())")
        let a = UUID(); let b = UUID()
        store.setPwd("/tmp/a", for: a)
        store.setPwd("/tmp/b", for: b)
        let snap = store.pwdsSnapshot()
        XCTAssertEqual(snap.count, 2)
        XCTAssertEqual(snap[a], "/tmp/a")
        XCTAssertEqual(snap[b], "/tmp/b")
    }
```

- [ ] **Step 1.8: 运行 pwdStore 全测试**

```bash
xcodebuild test -project TheAll.xcodeproj -scheme TheAllTests \
  -only-testing:TheAllTests/TerminalPwdStoreTests 2>&1 | tail -20
```

Expected: 5 tests PASS.

- [ ] **Step 1.9: Commit**

```bash
git add TheAll/Models/TerminalPwdStore.swift TheAllTests/TerminalPwdStoreTests.swift
git commit -m "$(cat <<'EOF'
feat(models): persist TerminalPwdStore + add inherit API

UserDefaults-backed (theall.pwds.v1) with 300ms debounced writes; new
inherit(from:to:) copies a source terminal's pwd onto a destination
UUID so new-tab / split / new-workspace paths can seed the new
terminal's initial working directory.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: `WorkspaceStore` 扩展 `addTab` / `createWorkspace` 返回值

**Files:**
- Modify: `TheAll/Models/WorkspaceStore.swift`
- Modify: `TheAllTests/WorkspaceStoreTests.swift`

- [ ] **Step 2.1: 写新测试 — addTab 返回 (tabId, terminalId)**

Append to `TheAllTests/WorkspaceStoreTests.swift` (inside the class, at the end before the closing brace):

```swift
    func testAddTabReturnsTerminalId() {
        let store = WorkspaceStore(persistenceKey: "test-\(UUID())")
        store.createWorkspace(name: "ws")
        let wsId = store.workspaces[0].id
        guard let result = store.addTab(to: wsId) else {
            XCTFail("addTab returned nil"); return
        }
        let tab = store.workspaces[0].tabs.first(where: { $0.id == result.tabId })
        XCTAssertNotNil(tab)
        XCTAssertEqual(tab?.layout.allTerminalIds().first, result.terminalId)
    }

    func testCreateWorkspaceReturnsFirstTerminalId() {
        let store = WorkspaceStore(persistenceKey: "test-\(UUID())")
        guard let termId = store.createWorkspace(name: "ws") else {
            XCTFail("createWorkspace returned nil"); return
        }
        let firstTerm = store.workspaces.last?.tabs.first?.layout.allTerminalIds().first
        XCTAssertEqual(termId, firstTerm)
    }
```

- [ ] **Step 2.2: 运行新测试，验证编译失败**

```bash
xcodebuild test -project TheAll.xcodeproj -scheme TheAllTests \
  -only-testing:TheAllTests/WorkspaceStoreTests/testAddTabReturnsTerminalId 2>&1 | tail -20
```

Expected: build FAIL — `addTab` 当前返回 `UUID?`，没有 `.tabId` / `.terminalId`。

- [ ] **Step 2.3: 改 `addTab` 和 `createWorkspace` 签名**

Edit `TheAll/Models/WorkspaceStore.swift`:

Replace `createWorkspace(name:)`:

```swift
    @discardableResult
    func createWorkspace(name: String) -> UUID? {
        var ws = Workspace(name: name)
        let tab = makeNewTab(index: 1)
        ws.tabs.append(tab)
        ws.selectedTabId = tab.id
        workspaces.append(ws)
        if selectedId == nil { selectedId = ws.id }
        save()
        return tab.layout.allTerminalIds().first
    }
```

Replace `addTab(to:)`:

```swift
    @discardableResult
    func addTab(to workspaceId: UUID) -> (tabId: UUID, terminalId: UUID)? {
        guard let wsIdx = wsIndex(workspaceId) else { return nil }
        let index = workspaces[wsIdx].tabs.count + 1
        let tab = makeNewTab(index: index)
        workspaces[wsIdx].tabs.append(tab)
        workspaces[wsIdx].selectedTabId = tab.id
        save()
        guard let termId = tab.layout.allTerminalIds().first else { return nil }
        return (tabId: tab.id, terminalId: termId)
    }
```

- [ ] **Step 2.4: 更新两处捕获 addTab 返回的现有测试**

Edit `TheAllTests/WorkspaceStoreTests.swift`:

Change line 135 from:
```swift
        let tabId = store.addTab(to: wsId)
```
to:
```swift
        let tabId = store.addTab(to: wsId)?.tabId
```

Change line 155 from:
```swift
        let tab2Id = store.addTab(to: wsId)!
```
to:
```swift
        let tab2Id = store.addTab(to: wsId)!.tabId
```

- [ ] **Step 2.5: 运行完整 WorkspaceStoreTests**

```bash
xcodebuild test -project TheAll.xcodeproj -scheme TheAllTests \
  -only-testing:TheAllTests/WorkspaceStoreTests 2>&1 | tail -30
```

Expected: all PASS (包括新增两个 + 所有现有测试)。

- [ ] **Step 2.6: Commit**

```bash
git add TheAll/Models/WorkspaceStore.swift TheAllTests/WorkspaceStoreTests.swift
git commit -m "$(cat <<'EOF'
feat(models): expose new terminalId from addTab / createWorkspace

addTab returns (tabId, terminalId); createWorkspace returns the first
tab's terminalId. Callers need this so they can seed pwdStore for the
freshly-minted terminal before its surface is created.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: `GhosttyTerminalView` 加 `validatedDirectory` + `pwdStoreRef`

**Files:**
- Modify: `TheAll/Ghostty/GhosttyTerminalView.swift`
- Create: `TheAllTests/GhosttyTerminalViewPwdTests.swift`

- [ ] **Step 3.1: 写 validatedDirectory 测试（三种输入）**

Create `TheAllTests/GhosttyTerminalViewPwdTests.swift`:

```swift
import XCTest
@testable import TheAll

final class GhosttyTerminalViewPwdTests: XCTestCase {

    func testValidatedDirectory_nil() {
        XCTAssertNil(GhosttyTerminalView.validatedDirectory(nil))
    }

    func testValidatedDirectory_existingDirectory() {
        // /tmp exists on every macOS host and is always a directory
        XCTAssertEqual(GhosttyTerminalView.validatedDirectory("/tmp"), "/tmp")
    }

    func testValidatedDirectory_nonexistentPath() {
        let fake = "/nonexistent/\(UUID().uuidString)"
        XCTAssertNil(GhosttyTerminalView.validatedDirectory(fake))
    }

    func testValidatedDirectory_regularFileRejected() {
        // Write a temp file then confirm validatedDirectory rejects it
        let dir = NSTemporaryDirectory()
        let path = (dir as NSString).appendingPathComponent("theall-test-\(UUID()).txt")
        FileManager.default.createFile(atPath: path, contents: Data("x".utf8))
        defer { try? FileManager.default.removeItem(atPath: path) }
        XCTAssertNil(GhosttyTerminalView.validatedDirectory(path))
    }
}
```

- [ ] **Step 3.2: 运行测试，验证编译失败**

```bash
xcodebuild test -project TheAll.xcodeproj -scheme TheAllTests \
  -only-testing:TheAllTests/GhosttyTerminalViewPwdTests 2>&1 | tail -20
```

Expected: build FAIL — `validatedDirectory` 不存在。

- [ ] **Step 3.3: 添加 validatedDirectory static helper**

Edit `TheAll/Ghostty/GhosttyTerminalView.swift`. Add right after the existing `static func allLiveSurfaces() -> [ghostty_surface_t]` block (around line 52, before the `private final class Weak<T>` nested class):

```swift
    /// Returns `path` iff it points to an existing directory. Returns nil for
    /// nil input, nonexistent paths, regular files, and anything else. Used by
    /// `viewDidMoveToWindow` to decide whether to forward a seeded pwd to
    /// libghostty — an invalid path would make the spawned shell print a
    /// `chdir` error, so we silently fall back to ghostty's default ($HOME).
    static func validatedDirectory(_ path: String?) -> String? {
        guard let path else { return nil }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir),
              isDir.boolValue else { return nil }
        return path
    }
```

- [ ] **Step 3.4: 运行 validatedDirectory 测试**

```bash
xcodebuild test -project TheAll.xcodeproj -scheme TheAllTests \
  -only-testing:TheAllTests/GhosttyTerminalViewPwdTests 2>&1 | tail -20
```

Expected: 4 tests PASS.

- [ ] **Step 3.5: 添加 pwdStoreRef 属性**

Edit `TheAll/Ghostty/GhosttyTerminalView.swift`. Add right after the existing `var terminalId: UUID?` line (around line 35):

```swift
    /// Injected by TabContentView right after construction. When present,
    /// `viewDidMoveToWindow` reads `pwd(for: terminalId)` and feeds it into
    /// ghostty's `working_directory` so the spawned PTY shell starts in the
    /// inherited / last-known directory.
    var pwdStoreRef: TerminalPwdStore?
```

- [ ] **Step 3.6: 修改 viewDidMoveToWindow 读 seed 并传 workingDirectory**

Edit `TheAll/Ghostty/GhosttyTerminalView.swift`. Find the block in `viewDidMoveToWindow`:

```swift
        if surface == nil {
            let scale = window?.backingScaleFactor ?? 2.0
            surface = GhosttyBridge.shared.newSurface(
                nsView: self,
                scaleFactor: scale,
                workingDirectory: nil,
                terminalId: terminalId ?? UUID()
            )
```

Replace with:

```swift
        if surface == nil {
            let scale = window?.backingScaleFactor ?? 2.0
            let seed = terminalId.flatMap { pwdStoreRef?.pwd(for: $0) }
            let validated = Self.validatedDirectory(seed)
            surface = GhosttyBridge.shared.newSurface(
                nsView: self,
                scaleFactor: scale,
                workingDirectory: validated,
                terminalId: terminalId ?? UUID()
            )
```

- [ ] **Step 3.7: 构建整个 app 验证编译**

```bash
xcodebuild -project TheAll.xcodeproj -scheme TheAll -configuration Debug build 2>&1 | tail -10
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3.8: Commit**

```bash
git add TheAll/Ghostty/GhosttyTerminalView.swift TheAllTests/GhosttyTerminalViewPwdTests.swift
git commit -m "$(cat <<'EOF'
feat(ghostty): seed surface working_directory from TerminalPwdStore

GhosttyTerminalView reads pwdStoreRef.pwd(for: terminalId) in
viewDidMoveToWindow, FileManager-validates the path, and forwards it
to newSurface so shells spawn in the inherited / persisted directory.
Invalid paths (missing / non-directory) silently fall back to nil →
ghostty default ($HOME).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: 把 `pwdStore` 经 `TabBridge` 注入到 `TabContentView`

**Files:**
- Modify: `TheAll/Bridge/TabBridge.swift`
- Modify: `TheAll/TabContent/TabContentView.swift`
- Modify: `TheAll/ContentView.swift`

- [ ] **Step 4.1: 给 TabBridge 加 pwdStore 参数**

Edit `TheAll/Bridge/TabBridge.swift`. Add a new prop after `@Bindable var statusStore: TerminalStatusStore`:

```swift
    @Bindable var pwdStore: TerminalPwdStore
```

In `makeNSView`, after `view.store = store` add:

```swift
        view.pwdStore = pwdStore
```

In `updateNSView`, after `nsView.store = store` add:

```swift
        nsView.pwdStore = pwdStore
```

- [ ] **Step 4.2: 给 TabContentView 加 var pwdStore + 注入到 GhosttyTerminalView**

Edit `TheAll/TabContent/TabContentView.swift`. Add new prop right after `var store: WorkspaceStore?` (around line 23):

```swift
    var pwdStore: TerminalPwdStore?
```

Edit `terminalViewFor(id:)` (around line 224). Change from:

```swift
    private func terminalViewFor(id: UUID) -> GhosttyTerminalView {
        if let existing = terminalViews[id] { return existing }
        let tv = GhosttyTerminalView(frame: .zero)
        tv.terminalId = id
        terminalViews[id] = tv
        return tv
    }
```

to:

```swift
    private func terminalViewFor(id: UUID) -> GhosttyTerminalView {
        if let existing = terminalViews[id] { return existing }
        let tv = GhosttyTerminalView(frame: .zero)
        tv.terminalId = id
        tv.pwdStoreRef = pwdStore
        terminalViews[id] = tv
        return tv
    }
```

- [ ] **Step 4.3: ContentView 把 pwdStore 传给 TabBridge**

Edit `TheAll/ContentView.swift`. Find the `TabBridge(` call (around line 59). Change from:

```swift
                    TabBridge(
                        store: store,
                        statusStore: statusStore,
                        theme: themeManager.theme,
                        backgroundOpacity: contentBg,
                        showStatusIndicators: showStatusIndicators,
                        languageTick: languageStore.tick
                    )
```

to:

```swift
                    TabBridge(
                        store: store,
                        statusStore: statusStore,
                        pwdStore: pwdStore,
                        theme: themeManager.theme,
                        backgroundOpacity: contentBg,
                        showStatusIndicators: showStatusIndicators,
                        languageTick: languageStore.tick
                    )
```

- [ ] **Step 4.4: 构建验证编译**

```bash
xcodebuild -project TheAll.xcodeproj -scheme TheAll -configuration Debug build 2>&1 | tail -10
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4.5: 跑完整测试套确保没倒退**

```bash
xcodebuild test -project TheAll.xcodeproj -scheme TheAllTests 2>&1 | tail -30
```

Expected: all tests PASS.

- [ ] **Step 4.6: Commit**

```bash
git add TheAll/Bridge/TabBridge.swift TheAll/TabContent/TabContentView.swift TheAll/ContentView.swift
git commit -m "$(cat <<'EOF'
feat(bridge): inject TerminalPwdStore through TabBridge into TabContentView

ContentView → TabBridge → TabContentView → GhosttyTerminalView now
passes the pwdStore reference so every terminal view can read its
seed pwd on surface creation. Foundation for the inherit wiring that
lands in the next commits.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: 新建 tab 继承 pwd（归一 `addNewTab`）

**Files:**
- Modify: `TheAll/TabContent/TabContentView.swift`

- [ ] **Step 5.1: 归一 tabBar.onAddTab → addNewTab()**

Edit `TheAll/TabContent/TabContentView.swift`. Find `setup()` block (around line 74-78):

```swift
        tabBar.onAddTab = { [weak self] in
            guard let self, let wsId = self.store?.selectedId else { return }
            self.store?.addTab(to: wsId)
            self.reloadFromStore()
        }
```

Replace with:

```swift
        tabBar.onAddTab = { [weak self] in
            self?.addNewTab()
        }
```

- [ ] **Step 5.2: 在 addNewTab 加 inherit 逻辑**

Edit the existing `addNewTab()` method (around line 340-344). Change from:

```swift
    private func addNewTab() {
        guard let wsId = store?.selectedId else { return }
        store?.addTab(to: wsId)
        reloadFromStore()
    }
```

to:

```swift
    private func addNewTab() {
        guard let wsId = store?.selectedId,
              let ws = store?.selectedWorkspace else { return }
        let sourceId = ws.selectedTab?.focusedTerminalId
        guard let result = store?.addTab(to: wsId) else { return }
        if let sourceId {
            pwdStore?.inherit(from: sourceId, to: result.terminalId)
        }
        reloadFromStore()
    }
```

- [ ] **Step 5.3: 构建验证**

```bash
xcodebuild -project TheAll.xcodeproj -scheme TheAll -configuration Debug build 2>&1 | tail -10
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5.4: 跑测试**

```bash
xcodebuild test -project TheAll.xcodeproj -scheme TheAllTests 2>&1 | tail -20
```

Expected: all PASS.

- [ ] **Step 5.5: Commit**

```bash
git add TheAll/TabContent/TabContentView.swift
git commit -m "$(cat <<'EOF'
feat(tabcontent): inherit pwd when adding a new tab

Both + button paths now funnel through addNewTab(); after the store
returns the new terminalId, copy the currently-focused terminal's
pwd onto it so the spawned shell starts in the same directory.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: 拆分 pane 继承 pwd

**Files:**
- Modify: `TheAll/TabContent/TabContentView.swift`

- [ ] **Step 6.1: 在 splitCurrentPane 加 inherit 逻辑**

Edit `TheAll/TabContent/TabContentView.swift`. Find `splitCurrentPane` (around line 354-363). Change from:

```swift
    private func splitCurrentPane(direction: SplitDirection) {
        guard let ws = store?.selectedWorkspace,
              let wsId = store?.selectedId,
              let tab = ws.selectedTab else { return }
        guard store?.splitTerminal(
            id: tab.focusedTerminalId, in: wsId, tabId: tab.id, direction: direction) != nil
        else { return }
        reloadFromStore()
        // reloadFromStore 会根据 store 里的 focusedTerminalId 恢复焦点到原 pane。
    }
```

to:

```swift
    private func splitCurrentPane(direction: SplitDirection) {
        guard let ws = store?.selectedWorkspace,
              let wsId = store?.selectedId,
              let tab = ws.selectedTab else { return }
        let sourceId = tab.focusedTerminalId
        guard let newId = store?.splitTerminal(
            id: sourceId, in: wsId, tabId: tab.id, direction: direction)
        else { return }
        pwdStore?.inherit(from: sourceId, to: newId)
        reloadFromStore()
        // reloadFromStore 会根据 store 里的 focusedTerminalId 恢复焦点到原 pane。
    }
```

- [ ] **Step 6.2: 构建验证**

```bash
xcodebuild -project TheAll.xcodeproj -scheme TheAll -configuration Debug build 2>&1 | tail -10
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 6.3: 跑测试**

```bash
xcodebuild test -project TheAll.xcodeproj -scheme TheAllTests 2>&1 | tail -20
```

Expected: all PASS.

- [ ] **Step 6.4: Commit**

```bash
git add TheAll/TabContent/TabContentView.swift
git commit -m "$(cat <<'EOF'
feat(tabcontent): inherit pwd when splitting a pane

Copy the split source pane's pwd onto the newly created pane so the
new split starts in the same directory. Keeps split behavior aligned
with new-tab / new-workspace, avoiding the split-falls-to-$HOME vs
new-tab-inherits inconsistency.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: 新建 workspace 继承 pwd

**Files:**
- Modify: `TheAll/Sidebar/SidebarView.swift`

- [ ] **Step 7.1: 在 createWorkspaceWithDefaultName 加 inherit**

Edit `TheAll/Sidebar/SidebarView.swift`. Find `createWorkspaceWithDefaultName()` (around line 144-147). Change from:

```swift
    func createWorkspaceWithDefaultName() {
        let name = "workspace \(store.workspaces.count + 1)"
        store.createWorkspace(name: name)
    }
```

to:

```swift
    func createWorkspaceWithDefaultName() {
        // 读 source 必须在 createWorkspace 之前 —— createWorkspace 如果是首次
        // 运行且当前无 workspace, 会自动把新 workspace 设为 selected, selectedWorkspace
        // 随之切到新 workspace, 就拿不到"上一个 workspace 的焦点 pane"了。
        let sourceId = store.selectedWorkspace?.selectedTab?.focusedTerminalId
        let name = "workspace \(store.workspaces.count + 1)"
        guard let newTerminalId = store.createWorkspace(name: name) else { return }
        if let sourceId {
            pwdStore.inherit(from: sourceId, to: newTerminalId)
        }
    }
```

- [ ] **Step 7.2: 构建验证**

```bash
xcodebuild -project TheAll.xcodeproj -scheme TheAll -configuration Debug build 2>&1 | tail -10
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 7.3: 跑测试**

```bash
xcodebuild test -project TheAll.xcodeproj -scheme TheAllTests 2>&1 | tail -20
```

Expected: all PASS.

- [ ] **Step 7.4: Commit**

```bash
git add TheAll/Sidebar/SidebarView.swift
git commit -m "$(cat <<'EOF'
feat(sidebar): inherit pwd when creating a new workspace

Resolve source terminalId BEFORE createWorkspace (new workspace
becomes selected on first run, which would otherwise clobber the
source lookup), then copy the previous workspace's focused pane pwd
onto the new workspace's first terminal.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 8: 更新 architecture.md 文档

**Files:**
- Modify: `docs/architecture.md`

- [ ] **Step 8.1: 搜文档中 TerminalPwdStore 相关段落**

```bash
grep -n "TerminalPwdStore\|newSurface\|working_directory\|workingDirectory" docs/architecture.md
```

Read each match to determine what needs updating.

- [ ] **Step 8.2: 更新 TerminalPwdStore 描述**

Edit `docs/architecture.md`. Wherever `TerminalPwdStore` is introduced as "session-scoped" or "in-memory only", replace that phrasing with text reflecting the new persistence:

Pattern to find (exact wording varies by current doc state):
- "session-scoped" / "in-memory only" / "app restart → entries gone" 类似表述

Replace with:
```
`TerminalPwdStore` — `@Observable`, UUID → pwd 映射。由 shell 的 OSC 7
(`kitty-shell-cwd://`) → ghostty `GHOSTTY_ACTION_PWD` →
`GhosttyBridge.onPwdChanged` 回调喂入。**持久化到 UserDefaults
(`theall.pwds.v1`)**，300ms debounce 写盘。用途：
1. 新建 tab / 拆分 pane / 新建 workspace 时 `inherit(from:to:)` 预写新
   terminalId 的 pwd，让 shell 落在继承来的目录。
2. app 重启后 `GhosttyTerminalView.viewDidMoveToWindow` 读 pwd 传给
   `GhosttyBridge.newSurface(workingDirectory:)`，让每个 terminal
   重开时回到关闭前所在目录。失效路径（被删 / 非目录）由静态
   `validatedDirectory` 兜底到 nil，shell 回退 `$HOME`。
```

- [ ] **Step 8.3: 更新 newSurface 条目 workingDirectory 含义**

Find the `newSurface(nsView:scaleFactor:workingDirectory:)` 条目. Amend (or add alongside) the existing short description with:

```
`workingDirectory` 参数由 `GhosttyTerminalView.viewDidMoveToWindow`
从 `TerminalPwdStore` 读出并用 `FileManager` 校验过的路径; nil 时
ghostty 在默认目录 (通常 `$HOME`) 启动 shell。
```

- [ ] **Step 8.4: 跑 check-doc-drift 确认无结构漂移**

```bash
./scripts/check-doc-drift.sh
```

Expected: no output (no drift). 该脚本只检查 Directory Structure，这次改动没加/删/挪 Swift 源文件（新增的两个文件在 `TheAllTests/`，不在 `TheAll/` 下不计入），所以应该干净。

- [ ] **Step 8.5: Commit**

```bash
git add docs/architecture.md
git commit -m "$(cat <<'EOF'
docs(architecture): reflect TerminalPwdStore persistence + pwd inheritance

Update the store description from "session-scoped" to
UserDefaults-persisted, document the inherit() role in tab/split/
workspace creation, and clarify what newSurface's workingDirectory
argument actually carries now.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 9: End-to-end 手动验证

**Files:** (none — manual QA pass)

- [ ] **Step 9.1: 清 debug 环境的持久化 key**

```bash
defaults delete com.theall.theall theall.pwds.v1 2>/dev/null || true
```

(如果 bundle identifier 不是 `com.theall.theall`, 改成实际 id；不影响，没这 key 时默认就是空。)

- [ ] **Step 9.2: 构建 + 让用户自己打开 app 做 QA**

```bash
xcodebuild -project TheAll.xcodeproj -scheme TheAll -configuration Debug build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`.

**然后告诉用户重启 theall，按以下脚本走一遍手动 QA。实现者自己不 open / killall TheAll.app。**

QA 脚本：
1. 打开 theall，`cd ~/Documents`，新建一个 tab(⌘T)。新 tab 应该在 `~/Documents` 启动（pwd 命令确认）。
2. 当前 tab `cd /tmp`，用分屏（⌘D 或 ⌘⇧D）。新 pane 应该在 `/tmp` 启动。
3. 当前 workspace 的焦点 pane 里 `cd ~/Desktop`，新建 workspace（侧栏 "+"）。新 workspace 的首个 terminal 应该在 `~/Desktop` 启动。
4. 在任何 pane `cd /some/path/that/DOES/NOT/exist` 不现实，所以换：`cd /tmp/rm-me && mkdir -p /tmp/rm-me && cd /tmp/rm-me`，确认 pwd 是 `/tmp/rm-me`。完全退出 app（⌘Q），然后 `rm -rf /tmp/rm-me`，再重启 theall。该 pane 应回退到 `$HOME`（不报错、不卡住）。
5. 正常流程：在多个 pane `cd` 到不同目录，完全退出 app（⌘Q），重启。每个 pane 应在关闭前的目录里启动 shell。

- [ ] **Step 9.3: 如果 QA 全过，告诉用户可以开始日常使用；如果发现问题，根据问题现象判断是否要补 patch**

---

## Self-Review

本计划覆盖 spec 每一节：

- **D1（继承来源 = 最近焦点）** → Task 5 / 6 / 7 的 sourceId 解析都是 `focusedTerminalId`
- **D2（split 同规则）** → Task 6
- **D3（失效路径静默回退 `$HOME`）** → Task 3 Step 3.3 `validatedDirectory`
- **Components §1（持久化 + inherit）** → Task 1
- **Components §2（Store 返回值扩展）** → Task 2
- **Components §3（依赖注入链）** → Task 4
- **Components §4（surface 创建读 seed）** → Task 3
- **Components §5（三入口接线）** → Task 5 / 6 / 7
- **Components §6（首次启动无 source）** → inherit 的 no-op 行为由 Task 1 的 `testInheritWithoutSourceIsNoop` 覆盖
- **Components §7（重启时序）** → pwdStore 在 `ContentView.@State` init 时同步 load（已有行为），`GhosttyTerminalView.viewDidMoveToWindow` lazy 读，Task 3 实现；Task 9.5 手动验证
- **Testing Strategy** → Task 1 覆盖 TerminalPwdStore，Task 2 覆盖 WorkspaceStore 返回值，Task 3 覆盖 validatedDirectory；非 UI 集成部分由 Task 9 手动 QA

**Placeholder scan:** 无 TODO / TBD；每个 step 都有具体代码或命令；Task 8 的文档修改措辞按实际发现的段落替换（附了 pattern）。

**Type consistency:**
- `TerminalPwdStore.inherit(from:to:)` — Task 1 定义，Task 5/6/7 按同名调用 ✓
- `addTab(to:) -> (tabId: UUID, terminalId: UUID)?` — Task 2 定义，Task 5 用 `result.terminalId` ✓
- `createWorkspace(name:) -> UUID?` — Task 2 定义，Task 7 用 `newTerminalId` 变量名捕获 ✓
- `GhosttyTerminalView.validatedDirectory(_:)` / `pwdStoreRef` — Task 3 定义，Task 4 引用 ✓
