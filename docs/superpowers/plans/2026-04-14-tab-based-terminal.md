# Tab-Based Terminal Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the free-canvas multi-window layout with a tab + split-pane terminal (like Ghostty / tmux) where each workspace has horizontal tabs and each tab supports recursive NSSplitView-based pane splitting.

**Architecture:** A recursive `SplitNode` enum describes each tab's layout tree. `TabContentView` (NSView) owns a cache of `GhosttyTerminalView` instances keyed by UUID, rebuilds its `SplitPaneView` tree from the store on any layout change, and routes keyboard-shortcut notifications from `TheAllApp`. All canvas/drag infrastructure is deleted.

**Tech Stack:** Swift, AppKit (NSView, NSSplitView), SwiftUI (Commands, NSViewRepresentable), libghostty, XCTest, xcodegen

---

## File Map

| Action | Path | Responsibility |
|--------|------|---------------|
| Rewrite | `TheAll/Models/Workspace.swift` | `SplitNode`, `SplitDirection`, `TerminalTab`, `Workspace` |
| Rewrite | `TheAll/Models/WorkspaceStore.swift` | New CRUD: tabs, splits, close, ratio |
| Rewrite | `TheAllTests/WorkspaceStoreTests.swift` | Tests for new model + store |
| Create | `TheAll/TabContent/TabBarView.swift` | Horizontal tab bar with add/close |
| Create | `TheAll/TabContent/SplitPaneView.swift` | Recursive NSSplitView renderer |
| Create | `TheAll/TabContent/TabContentView.swift` | Owns terminal view cache, orchestrates tab+split |
| Create | `TheAll/Bridge/TabBridge.swift` | NSViewRepresentable wrapping TabContentView |
| Modify | `TheAll/ContentView.swift` | Swap CanvasBridge→TabBridge; add new Notification.Names |
| Modify | `TheAll/TheAllApp.swift` | Add Commands for ⌘T, ⌘W, ⌘D, ⌘⇧D, ⌘⇧], ⌘⇧[, ⌘1–⌘9 |
| Delete | `TheAll/Canvas/CanvasScrollView.swift` | — |
| Delete | `TheAll/Canvas/CanvasContentView.swift` | — |
| Delete | `TheAll/Canvas/TerminalWindowView.swift` | — |
| Delete | `TheAll/Canvas/TitleBarView.swift` | — |
| Delete | `TheAll/Bridge/CanvasBridge.swift` | — |

---

## Task 1: Replace data model

**Files:**
- Rewrite: `TheAll/Models/Workspace.swift`

- [ ] **Step 1: Write the new `Workspace.swift`**

Replace the entire file with:

```swift
import Foundation
import CoreGraphics

enum SplitDirection: String, Codable, Equatable {
    case horizontal  // top / bottom
    case vertical    // left / right
}

indirect enum SplitNode: Equatable {
    // Leaf: one terminal identified by UUID
    case terminal(UUID)
    // Branch: (splitId, direction, firstRatio 0…1, first child, second child)
    case split(UUID, SplitDirection, CGFloat, SplitNode, SplitNode)

    // All terminal IDs in depth-first order
    func allTerminalIds() -> [UUID] {
        switch self {
        case .terminal(let id): return [id]
        case .split(_, _, _, let a, let b): return a.allTerminalIds() + b.allTerminalIds()
        }
    }

    // Replace the .terminal(terminalId) leaf with newNode
    func replacing(terminalId: UUID, with newNode: SplitNode) -> SplitNode {
        switch self {
        case .terminal(let id):
            return id == terminalId ? newNode : self
        case .split(let sid, let dir, let ratio, let first, let second):
            return .split(sid, dir, ratio,
                first.replacing(terminalId: terminalId, with: newNode),
                second.replacing(terminalId: terminalId, with: newNode))
        }
    }

    // Remove terminalId. Returns nil when self IS that terminal (caller promotes sibling).
    func removing(terminalId: UUID) -> SplitNode? {
        switch self {
        case .terminal(let id):
            return id == terminalId ? nil : self
        case .split(let sid, let dir, let ratio, let first, let second):
            let r1 = first.removing(terminalId: terminalId)
            let r2 = second.removing(terminalId: terminalId)
            if r1 == nil { return second }   // first WAS the terminal → promote second
            if r2 == nil { return first }    // second WAS the terminal → promote first
            return .split(sid, dir, ratio, r1!, r2!)
        }
    }

    // Update the ratio of the split whose UUID matches splitId
    func updatingRatio(splitId: UUID, to ratio: CGFloat) -> SplitNode {
        switch self {
        case .terminal: return self
        case .split(let sid, let dir, let currentRatio, let first, let second):
            if sid == splitId {
                return .split(sid, dir, ratio, first, second)
            }
            return .split(sid, dir, currentRatio,
                first.updatingRatio(splitId: splitId, to: ratio),
                second.updatingRatio(splitId: splitId, to: ratio))
        }
    }
}

// MARK: - SplitNode Codable

extension SplitNode: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, terminalId, splitId, direction, ratio, first, second
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "terminal":
            self = .terminal(try c.decode(UUID.self, forKey: .terminalId))
        case "split":
            self = .split(
                try c.decode(UUID.self, forKey: .splitId),
                try c.decode(SplitDirection.self, forKey: .direction),
                try c.decode(CGFloat.self, forKey: .ratio),
                try c.decode(SplitNode.self, forKey: .first),
                try c.decode(SplitNode.self, forKey: .second)
            )
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c,
                debugDescription: "Unknown SplitNode type")
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .terminal(let id):
            try c.encode("terminal", forKey: .type)
            try c.encode(id, forKey: .terminalId)
        case .split(let sid, let dir, let ratio, let first, let second):
            try c.encode("split", forKey: .type)
            try c.encode(sid, forKey: .splitId)
            try c.encode(dir, forKey: .direction)
            try c.encode(ratio, forKey: .ratio)
            try c.encode(first, forKey: .first)
            try c.encode(second, forKey: .second)
        }
    }
}

// MARK: - TerminalTab

struct TerminalTab: Codable, Identifiable, Equatable {
    let id: UUID
    var title: String
    var layout: SplitNode
    var focusedTerminalId: UUID

    init(id: UUID = UUID(), title: String, terminalId: UUID = UUID()) {
        self.id = id
        self.title = title
        self.layout = .terminal(terminalId)
        self.focusedTerminalId = terminalId
    }
}

// MARK: - Workspace

struct Workspace: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var tabs: [TerminalTab]
    var selectedTabId: UUID?

    init(id: UUID = UUID(), name: String) {
        self.id = id
        self.name = name
        self.tabs = []
        self.selectedTabId = nil
    }

    var selectedTab: TerminalTab? {
        tabs.first { $0.id == selectedTabId }
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add TheAll/Models/Workspace.swift
git commit -m "feat: replace canvas data model with tab+split tree model"
```

---

## Task 2: Update WorkspaceStore + tests

**Files:**
- Rewrite: `TheAll/Models/WorkspaceStore.swift`
- Rewrite: `TheAllTests/WorkspaceStoreTests.swift`

- [ ] **Step 1: Write new tests first**

Replace `TheAllTests/WorkspaceStoreTests.swift`:

```swift
import XCTest
@testable import TheAll

final class WorkspaceStoreTests: XCTestCase {

    // MARK: - Workspace CRUD

    func testCreateWorkspace() {
        let store = WorkspaceStore(persistenceKey: "test-\(UUID())")
        store.createWorkspace(name: "my-project")
        XCTAssertEqual(store.workspaces.count, 1)
        XCTAssertEqual(store.workspaces[0].name, "my-project")
        // Creating a workspace auto-adds one tab
        XCTAssertEqual(store.workspaces[0].tabs.count, 1)
        XCTAssertNotNil(store.workspaces[0].selectedTabId)
    }

    func testSelectWorkspace() {
        let store = WorkspaceStore(persistenceKey: "test-\(UUID())")
        store.createWorkspace(name: "alpha")
        store.createWorkspace(name: "beta")
        let betaId = store.workspaces[1].id
        store.select(id: betaId)
        XCTAssertEqual(store.selectedId, betaId)
    }

    func testDeleteWorkspace() {
        let store = WorkspaceStore(persistenceKey: "test-\(UUID())")
        store.createWorkspace(name: "to-delete")
        let id = store.workspaces[0].id
        store.deleteWorkspace(id: id)
        XCTAssertTrue(store.workspaces.isEmpty)
    }

    // MARK: - Tab CRUD

    func testAddTab() {
        let store = WorkspaceStore(persistenceKey: "test-\(UUID())")
        store.createWorkspace(name: "ws")
        let wsId = store.workspaces[0].id
        // createWorkspace auto-adds tab 1; add tab 2
        let tabId = store.addTab(to: wsId)
        XCTAssertNotNil(tabId)
        XCTAssertEqual(store.workspaces[0].tabs.count, 2)
        XCTAssertEqual(store.workspaces[0].selectedTabId, tabId)
    }

    func testRemoveTab_keepsAtLeastOne() {
        let store = WorkspaceStore(persistenceKey: "test-\(UUID())")
        store.createWorkspace(name: "ws")
        let wsId = store.workspaces[0].id
        let onlyTabId = store.workspaces[0].tabs[0].id
        store.removeTab(id: onlyTabId, from: wsId)
        // Must still have one tab
        XCTAssertEqual(store.workspaces[0].tabs.count, 1)
    }

    func testSelectTab() {
        let store = WorkspaceStore(persistenceKey: "test-\(UUID())")
        store.createWorkspace(name: "ws")
        let wsId = store.workspaces[0].id
        let tab2Id = store.addTab(to: wsId)!
        let tab1Id = store.workspaces[0].tabs[0].id
        store.selectTab(id: tab1Id, in: wsId)
        XCTAssertEqual(store.workspaces[0].selectedTabId, tab1Id)
        store.selectTab(id: tab2Id, in: wsId)
        XCTAssertEqual(store.workspaces[0].selectedTabId, tab2Id)
    }

    // MARK: - SplitNode tree helpers

    func testSplitNodeAllTerminalIds_leaf() {
        let id = UUID()
        let node = SplitNode.terminal(id)
        XCTAssertEqual(node.allTerminalIds(), [id])
    }

    func testSplitNodeAllTerminalIds_split() {
        let a = UUID(), b = UUID()
        let node = SplitNode.split(UUID(), .vertical, 0.5, .terminal(a), .terminal(b))
        XCTAssertEqual(Set(node.allTerminalIds()), Set([a, b]))
    }

    func testSplitNodeRemoving_leaf_selfIsTarget() {
        let id = UUID()
        let node = SplitNode.terminal(id)
        XCTAssertNil(node.removing(terminalId: id))
    }

    func testSplitNodeRemoving_promotesFirstSibling() {
        let a = UUID(), b = UUID()
        let node = SplitNode.split(UUID(), .vertical, 0.5, .terminal(a), .terminal(b))
        // Remove b → expect .terminal(a)
        let result = node.removing(terminalId: b)
        XCTAssertEqual(result, .terminal(a))
    }

    func testSplitNodeRemoving_promotesSecondSibling() {
        let a = UUID(), b = UUID()
        let node = SplitNode.split(UUID(), .vertical, 0.5, .terminal(a), .terminal(b))
        // Remove a → expect .terminal(b)
        let result = node.removing(terminalId: a)
        XCTAssertEqual(result, .terminal(b))
    }

    func testSplitNodeRemoving_nested() {
        let a = UUID(), b = UUID(), c = UUID()
        let inner = SplitNode.split(UUID(), .horizontal, 0.5, .terminal(b), .terminal(c))
        let node = SplitNode.split(UUID(), .vertical, 0.5, .terminal(a), inner)
        // Remove c → inner becomes .terminal(b); outer stays .split
        guard case .split(_, _, _, let newFirst, let newSecond) = node.removing(terminalId: c) else {
            XCTFail("Expected split"); return
        }
        XCTAssertEqual(newFirst, .terminal(a))
        XCTAssertEqual(newSecond, .terminal(b))
    }

    func testSplitNodeUpdatingRatio() {
        let splitId = UUID()
        let a = UUID(), b = UUID()
        let node = SplitNode.split(splitId, .vertical, 0.5, .terminal(a), .terminal(b))
        let updated = node.updatingRatio(splitId: splitId, to: 0.3)
        guard case .split(_, _, let ratio, _, _) = updated else { XCTFail(); return }
        XCTAssertEqual(ratio, 0.3, accuracy: 0.001)
    }

    func testSplitNodeCodableRoundTrip() throws {
        let a = UUID(), b = UUID(), splitId = UUID()
        let node = SplitNode.split(splitId, .horizontal, 0.4, .terminal(a), .terminal(b))
        let data = try JSONEncoder().encode(node)
        let decoded = try JSONDecoder().decode(SplitNode.self, from: data)
        XCTAssertEqual(node, decoded)
    }

    // MARK: - Store split operations

    func testSplitTerminal() {
        let store = WorkspaceStore(persistenceKey: "test-\(UUID())")
        store.createWorkspace(name: "ws")
        let wsId = store.workspaces[0].id
        let tab = store.workspaces[0].tabs[0]
        let tabId = tab.id
        guard case .terminal(let origId) = tab.layout else { XCTFail(); return }

        let newId = store.splitTerminal(id: origId, in: wsId, tabId: tabId, direction: .vertical)
        XCTAssertNotNil(newId)

        let updatedTab = store.workspaces[0].tabs[0]
        let allIds = updatedTab.layout.allTerminalIds()
        XCTAssertEqual(allIds.count, 2)
        XCTAssertTrue(allIds.contains(origId))
        XCTAssertTrue(allIds.contains(newId!))
        XCTAssertEqual(updatedTab.focusedTerminalId, newId)
    }

    func testCloseTerminal_lastTerminalClosesTab() {
        let store = WorkspaceStore(persistenceKey: "test-\(UUID())")
        store.createWorkspace(name: "ws")
        let wsId = store.workspaces[0].id
        let tab = store.workspaces[0].tabs[0]
        guard case .terminal(let termId) = tab.layout else { XCTFail(); return }

        store.closeTerminal(id: termId, in: wsId, tabId: tab.id)
        // Tab closed, a new default tab was created
        XCTAssertEqual(store.workspaces[0].tabs.count, 1)
        XCTAssertNotEqual(store.workspaces[0].tabs[0].id, tab.id)
    }

    func testCloseTerminal_removesPane() {
        let store = WorkspaceStore(persistenceKey: "test-\(UUID())")
        store.createWorkspace(name: "ws")
        let wsId = store.workspaces[0].id
        let tabId = store.workspaces[0].tabs[0].id
        guard case .terminal(let origId) = store.workspaces[0].tabs[0].layout else { XCTFail(); return }

        let newId = store.splitTerminal(id: origId, in: wsId, tabId: tabId, direction: .vertical)!
        store.closeTerminal(id: newId, in: wsId, tabId: tabId)

        let updatedTab = store.workspaces[0].tabs[0]
        XCTAssertEqual(updatedTab.layout.allTerminalIds(), [origId])
    }

    func testPersistenceRoundTrip() throws {
        let key = "test-persist-\(UUID())"
        let store1 = WorkspaceStore(persistenceKey: key)
        store1.createWorkspace(name: "persistent")
        let wsId = store1.workspaces[0].id
        let tabId = store1.workspaces[0].tabs[0].id
        guard case .terminal(let termId) = store1.workspaces[0].tabs[0].layout else { XCTFail(); return }
        _ = store1.splitTerminal(id: termId, in: wsId, tabId: tabId, direction: .horizontal)

        let store2 = WorkspaceStore(persistenceKey: key)
        XCTAssertEqual(store2.workspaces.count, 1)
        XCTAssertEqual(store2.workspaces[0].name, "persistent")
        XCTAssertEqual(store2.workspaces[0].tabs[0].layout.allTerminalIds().count, 2)

        UserDefaults.standard.removeObject(forKey: key)
    }
}
```

- [ ] **Step 2: Run tests to confirm they fail (model not updated yet)**

```bash
xcodebuild test -project TheAll.xcodeproj -scheme TheAll \
  -destination 'platform=macOS' 2>&1 | grep -E 'error:|FAILED|PASSED'
```

Expected: compile errors because `TerminalTab`, `SplitNode`, etc. don't exist yet.

- [ ] **Step 3: Write new `WorkspaceStore.swift`**

Replace the entire file:

```swift
import Foundation
import Observation

@Observable
final class WorkspaceStore {
    private(set) var workspaces: [Workspace] = []
    private(set) var selectedId: UUID?
    private let persistenceKey: String

    init(persistenceKey: String = "theall.workspaces.v2") {
        self.persistenceKey = persistenceKey
        load()
        if workspaces.isEmpty && persistenceKey == "theall.workspaces.v2" {
            createWorkspace(name: "Default")
        }
        if selectedId == nil { selectedId = workspaces.first?.id }
    }

    var selectedWorkspace: Workspace? {
        workspaces.first { $0.id == selectedId }
    }

    // MARK: - Workspace CRUD

    func createWorkspace(name: String) {
        var ws = Workspace(name: name)
        let tab = makeNewTab(index: 1)
        ws.tabs.append(tab)
        ws.selectedTabId = tab.id
        workspaces.append(ws)
        if selectedId == nil { selectedId = ws.id }
        save()
    }

    func deleteWorkspace(id: UUID) {
        workspaces.removeAll { $0.id == id }
        if selectedId == id { selectedId = workspaces.first?.id }
        save()
    }

    func select(id: UUID) {
        guard workspaces.contains(where: { $0.id == id }) else { return }
        selectedId = id
    }

    // MARK: - Tab CRUD

    @discardableResult
    func addTab(to workspaceId: UUID) -> UUID? {
        guard let wsIdx = wsIndex(workspaceId) else { return nil }
        let index = workspaces[wsIdx].tabs.count + 1
        let tab = makeNewTab(index: index)
        workspaces[wsIdx].tabs.append(tab)
        workspaces[wsIdx].selectedTabId = tab.id
        save()
        return tab.id
    }

    func removeTab(id: UUID, from workspaceId: UUID) {
        guard let wsIdx = wsIndex(workspaceId) else { return }
        workspaces[wsIdx].tabs.removeAll { $0.id == id }
        if workspaces[wsIdx].tabs.isEmpty {
            let replacement = makeNewTab(index: 1)
            workspaces[wsIdx].tabs.append(replacement)
            workspaces[wsIdx].selectedTabId = replacement.id
        } else if workspaces[wsIdx].selectedTabId == id {
            workspaces[wsIdx].selectedTabId = workspaces[wsIdx].tabs.last?.id
        }
        save()
    }

    func selectTab(id: UUID, in workspaceId: UUID) {
        guard let wsIdx = wsIndex(workspaceId),
              workspaces[wsIdx].tabs.contains(where: { $0.id == id }) else { return }
        workspaces[wsIdx].selectedTabId = id
        save()
    }

    // MARK: - Split operations

    @discardableResult
    func splitTerminal(id terminalId: UUID, in workspaceId: UUID, tabId: UUID,
                       direction: SplitDirection) -> UUID? {
        guard let wsIdx = wsIndex(workspaceId),
              let tIdx = tabIndex(tabId, in: wsIdx) else { return nil }
        let newTermId = UUID()
        let splitNode = SplitNode.split(UUID(), direction, 0.5,
                                        .terminal(terminalId), .terminal(newTermId))
        workspaces[wsIdx].tabs[tIdx].layout =
            workspaces[wsIdx].tabs[tIdx].layout.replacing(terminalId: terminalId, with: splitNode)
        workspaces[wsIdx].tabs[tIdx].focusedTerminalId = newTermId
        save()
        return newTermId
    }

    func closeTerminal(id terminalId: UUID, in workspaceId: UUID, tabId: UUID) {
        guard let wsIdx = wsIndex(workspaceId),
              let tIdx = tabIndex(tabId, in: wsIdx) else { return }
        let tab = workspaces[wsIdx].tabs[tIdx]
        if let newLayout = tab.layout.removing(terminalId: terminalId) {
            workspaces[wsIdx].tabs[tIdx].layout = newLayout
            if tab.focusedTerminalId == terminalId {
                workspaces[wsIdx].tabs[tIdx].focusedTerminalId =
                    newLayout.allTerminalIds().first ?? UUID()
            }
            save()
        } else {
            // Last terminal in tab → close the tab
            removeTab(id: tabId, from: workspaceId)
        }
    }

    func updateSplitRatio(splitId: UUID, to ratio: CGFloat,
                          tabId: UUID, in workspaceId: UUID) {
        guard let wsIdx = wsIndex(workspaceId),
              let tIdx = tabIndex(tabId, in: wsIdx) else { return }
        workspaces[wsIdx].tabs[tIdx].layout =
            workspaces[wsIdx].tabs[tIdx].layout.updatingRatio(splitId: splitId, to: ratio)
        save()
    }

    func updateFocusedTerminal(id terminalId: UUID, tabId: UUID, in workspaceId: UUID) {
        guard let wsIdx = wsIndex(workspaceId),
              let tIdx = tabIndex(tabId, in: wsIdx) else { return }
        workspaces[wsIdx].tabs[tIdx].focusedTerminalId = terminalId
        save()
    }

    func updateTabLayout(_ layout: SplitNode, tabId: UUID, in workspaceId: UUID) {
        guard let wsIdx = wsIndex(workspaceId),
              let tIdx = tabIndex(tabId, in: wsIdx) else { return }
        workspaces[wsIdx].tabs[tIdx].layout = layout
        save()
    }

    // MARK: - Helpers

    private func makeNewTab(index: Int) -> TerminalTab {
        TerminalTab(title: "terminal \(index)")
    }

    private func wsIndex(_ id: UUID) -> Int? {
        workspaces.firstIndex(where: { $0.id == id })
    }

    private func tabIndex(_ id: UUID, in wsIdx: Int) -> Int? {
        workspaces[wsIdx].tabs.firstIndex(where: { $0.id == id })
    }

    // MARK: - Persistence

    private func save() {
        guard let data = try? JSONEncoder().encode(workspaces) else { return }
        UserDefaults.standard.set(data, forKey: persistenceKey)
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: persistenceKey),
              let decoded = try? JSONDecoder().decode([Workspace].self, from: data)
        else { return }
        workspaces = decoded
        selectedId = workspaces.first?.id
    }
}
```

- [ ] **Step 4: Run tests — expect all to pass**

```bash
xcodebuild test -project TheAll.xcodeproj -scheme TheAll \
  -destination 'platform=macOS' 2>&1 | grep -E 'error:|Test.*FAILED|Test.*passed'
```

Expected: All `WorkspaceStoreTests` pass. (UI-dependent tests may show compile errors if `CanvasBridge` etc. are referenced elsewhere — that's fine; fix forward references by temporarily commenting out `ContentView` body if needed, then restore later.)

- [ ] **Step 5: Commit**

```bash
git add TheAll/Models/WorkspaceStore.swift TheAllTests/WorkspaceStoreTests.swift
git commit -m "feat: rewrite WorkspaceStore for tab+split model; update tests"
```

---

## Task 3: Create TabBarView

**Files:**
- Create: `TheAll/TabContent/TabBarView.swift`

- [ ] **Step 1: Create directory and file**

Create `TheAll/TabContent/TabBarView.swift`:

```swift
import AppKit

// MARK: - TabBarView

/// Horizontal tab strip. Notifies via callbacks; never touches the store directly.
final class TabBarView: NSView {
    var onSelectTab: ((UUID) -> Void)?
    var onAddTab: (() -> Void)?
    var onCloseTab: ((UUID) -> Void)?

    static let height: CGFloat = DT.Layout.titleBarHeight

    private var theme: AppTheme = .systemFallback(isDark: true)
    private var tabs: [TerminalTab] = []
    private var selectedTabId: UUID?

    private let scrollView = NSScrollView()
    private let tabsContainer = NSView()
    private let addButton = NSButton()

    override init(frame: NSRect) {
        super.init(frame: frame)
        setup()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        wantsLayer = true

        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.drawsBackground = false
        scrollView.documentView = tabsContainer
        scrollView.autoresizingMask = []
        addSubview(scrollView)

        addButton.isBordered = false
        addButton.title = "+"
        addButton.font = DT.Font.body
        addButton.target = self
        addButton.action = #selector(addTapped)
        addSubview(addButton)
    }

    override func layout() {
        super.layout()
        let addW: CGFloat = 28
        addButton.frame = NSRect(x: bounds.width - addW, y: 0, width: addW, height: bounds.height)
        scrollView.frame = NSRect(x: 0, y: 0, width: bounds.width - addW, height: bounds.height)
        layoutTabItems()
    }

    func update(tabs: [TerminalTab], selectedTabId: UUID?, theme: AppTheme) {
        self.tabs = tabs
        self.selectedTabId = selectedTabId
        self.theme = theme
        rebuildTabItems()
        applyTheme(theme)
    }

    private func rebuildTabItems() {
        tabsContainer.subviews.forEach { $0.removeFromSuperview() }
        for tab in tabs {
            let item = TabItemView(tab: tab, isSelected: tab.id == selectedTabId, theme: theme)
            item.onSelect = { [weak self] in self?.onSelectTab?(tab.id) }
            item.onClose  = { [weak self] in self?.onCloseTab?(tab.id) }
            tabsContainer.addSubview(item)
        }
        layoutTabItems()
    }

    private func layoutTabItems() {
        let items = tabsContainer.subviews.compactMap { $0 as? TabItemView }
        let tabW: CGFloat = 140
        let h = bounds.height
        var x: CGFloat = 0
        for item in items {
            item.frame = NSRect(x: x, y: 0, width: tabW, height: h)
            x += tabW
        }
        tabsContainer.frame = NSRect(
            x: 0, y: 0,
            width: max(x, scrollView.frame.width),
            height: h)
    }

    func applyTheme(_ theme: AppTheme) {
        self.theme = theme
        layer?.backgroundColor = theme.sidebar.cgColor
        addButton.contentTintColor = theme.textTertiary
        tabsContainer.subviews
            .compactMap { $0 as? TabItemView }
            .forEach { $0.applyTheme(theme) }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        // Bottom hairline separating tab bar from content
        theme.border.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: DT.Stroke.hairline).fill()
    }

    @objc private func addTapped() { onAddTab?() }
}

// MARK: - TabItemView

private final class TabItemView: NSView {
    var onSelect: (() -> Void)?
    var onClose:  (() -> Void)?

    private let titleLabel = NSTextField(labelWithString: "")
    private let closeBtn   = NSButton()
    private var isSelected: Bool
    private var isHovered  = false
    private var theme: AppTheme

    init(tab: TerminalTab, isSelected: Bool, theme: AppTheme) {
        self.isSelected = isSelected
        self.theme = theme
        super.init(frame: .zero)
        titleLabel.stringValue = tab.title
        setup()
        updateStyle()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        wantsLayer = true

        titleLabel.isBezeled = false
        titleLabel.drawsBackground = false
        titleLabel.isEditable = false
        titleLabel.isSelectable = false
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.font = DT.Font.small
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(titleLabel)

        closeBtn.isBordered = false
        closeBtn.title = "×"
        closeBtn.font = DT.Font.small
        closeBtn.target = self
        closeBtn.action = #selector(closeTapped)
        closeBtn.isHidden = true
        addSubview(closeBtn)

        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect],
            owner: self))
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        let closeW: CGFloat = 16
        let margin: CGFloat = 8
        closeBtn.frame = NSRect(x: bounds.width - closeW - margin,
                                y: (h - 14) / 2, width: closeW, height: 14)
        titleLabel.frame = NSRect(x: margin, y: 0,
                                  width: bounds.width - closeW - margin * 2, height: h)
    }

    func applyTheme(_ theme: AppTheme) {
        self.theme = theme
        updateStyle()
    }

    private func updateStyle() {
        if isSelected {
            layer?.backgroundColor = theme.surface.cgColor
            titleLabel.textColor = theme.textPrimary
        } else if isHovered {
            layer?.backgroundColor = theme.surface.withAlphaComponent(0.5).cgColor
            titleLabel.textColor = theme.textSecondary
        } else {
            layer?.backgroundColor = .clear
            titleLabel.textColor = theme.textSecondary
        }
        closeBtn.contentTintColor = theme.textTertiary
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        // 2 px accent line at bottom of selected tab
        if isSelected {
            theme.accent.setFill()
            NSRect(x: 0, y: 0, width: bounds.width, height: 2).fill()
        }
        // Right-edge separator
        theme.border.withAlphaComponent(0.4).setFill()
        NSRect(x: bounds.width - DT.Stroke.hairline, y: 4,
               width: DT.Stroke.hairline, height: bounds.height - 8).fill()
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        closeBtn.isHidden = false
        updateStyle()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        closeBtn.isHidden = true
        updateStyle()
    }

    override func mouseDown(with event: NSEvent) { onSelect?() }

    @objc private func closeTapped() { onClose?() }
}
```

- [ ] **Step 2: Run xcodegen to pick up new file**

```bash
xcodegen generate
```

Expected: `TheAll.xcodeproj` regenerated, `TabBarView.swift` now in project.

- [ ] **Step 3: Verify it compiles (build only, no run needed)**

```bash
xcodebuild build -project TheAll.xcodeproj -scheme TheAll \
  -destination 'platform=macOS' 2>&1 | grep -E 'error:|Build succeeded'
```

Expected: `Build succeeded` (CanvasBridge still exists so ContentView still compiles).

- [ ] **Step 4: Commit**

```bash
git add TheAll/TabContent/TabBarView.swift TheAll.xcodeproj
git commit -m "feat: add TabBarView with tab switching and add/close"
```

---

## Task 4: Create SplitPaneView

**Files:**
- Create: `TheAll/TabContent/SplitPaneView.swift`

- [ ] **Step 1: Create the file**

Create `TheAll/TabContent/SplitPaneView.swift`:

```swift
import AppKit

// MARK: - ThemedSplitView

/// NSSplitView subclass that renders a 1-px hairline divider in theme.border colour.
private final class ThemedSplitView: NSSplitView {
    var dividerColor: NSColor = .separatorColor

    override var dividerThickness: CGFloat { 1 }

    override func drawDivider(in rect: NSRect) {
        dividerColor.setFill()
        NSBezierPath.fill(rect)
    }
}

// MARK: - SplitPaneView

/// Recursively renders a SplitNode tree.
/// - For `.terminal(id)`: hosts the GhosttyTerminalView returned by `terminalViewForId`.
/// - For `.split(...)`: creates a ThemedSplitView containing two child SplitPaneViews.
///
/// Terminal views are NOT owned here — they live in TabContentView's cache.
final class SplitPaneView: NSView {
    /// Called when the user drags an NSSplitView divider. (splitId, newRatio 0…1)
    var onRatioChanged: ((UUID, CGFloat) -> Void)?
    /// Called when the user clicks a terminal pane to focus it.
    var onFocus: ((UUID) -> Void)?

    private let node: SplitNode
    private let terminalViewForId: (UUID) -> GhosttyTerminalView

    private var splitView: ThemedSplitView?
    private var children: [SplitPaneView] = []
    private var splitDelegate: SplitDelegate?  // strong ref

    init(node: SplitNode, terminalViewForId: @escaping (UUID) -> GhosttyTerminalView) {
        self.node = node
        self.terminalViewForId = terminalViewForId
        super.init(frame: .zero)
        wantsLayer = true
        buildLayout()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func buildLayout() {
        switch node {
        case .terminal(let id):
            let tv = terminalViewForId(id)
            tv.removeFromSuperview()
            addSubview(tv)
            tv.frame = bounds
            tv.autoresizingMask = [.width, .height]

        case .split(let splitId, let direction, let ratio, let first, let second):
            let sv = ThemedSplitView(frame: bounds)
            sv.isVertical = (direction == .vertical)
            sv.autoresizingMask = [.width, .height]

            let firstPane  = makeChild(node: first)
            let secondPane = makeChild(node: second)
            sv.addArrangedSubview(firstPane)
            sv.addArrangedSubview(secondPane)

            // Delegate stored strongly to avoid dealloc
            let delegate = SplitDelegate(splitId: splitId, isVertical: sv.isVertical) { [weak self] sid, r in
                self?.onRatioChanged?(sid, r)
            }
            sv.delegate = delegate
            self.splitDelegate = delegate

            addSubview(sv)
            self.splitView = sv
            self.children  = [firstPane, secondPane]

            // Apply saved ratio after the split view has been laid out
            DispatchQueue.main.async { [weak sv] in
                guard let sv = sv, sv.subviews.count >= 2 else { return }
                let total = sv.isVertical ? sv.bounds.width : sv.bounds.height
                guard total > 0 else { return }
                sv.setPosition(total * ratio, ofDividerAt: 0)
            }
        }
    }

    private func makeChild(node: SplitNode) -> SplitPaneView {
        let pane = SplitPaneView(node: node, terminalViewForId: terminalViewForId)
        pane.onRatioChanged = onRatioChanged
        pane.onFocus = onFocus
        return pane
    }

    func applyTheme(_ theme: AppTheme) {
        splitView?.dividerColor = theme.border
        splitView?.needsDisplay = true
        children.forEach { $0.applyTheme(theme) }
    }
}

// MARK: - SplitDelegate

/// Separate delegate object so SplitPaneView doesn't have to be NSSplitViewDelegate.
private final class SplitDelegate: NSObject, NSSplitViewDelegate {
    private let splitId: UUID
    private let isVertical: Bool
    private let onRatioChanged: (UUID, CGFloat) -> Void

    init(splitId: UUID, isVertical: Bool, onRatioChanged: @escaping (UUID, CGFloat) -> Void) {
        self.splitId = splitId
        self.isVertical = isVertical
        self.onRatioChanged = onRatioChanged
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard let sv = notification.object as? NSSplitView,
              sv.subviews.count >= 2 else { return }
        let total = isVertical ? sv.frame.width : sv.frame.height
        guard total > 0 else { return }
        let first = isVertical ? sv.subviews[0].frame.width : sv.subviews[0].frame.height
        onRatioChanged(splitId, first / total)
    }
}
```

- [ ] **Step 2: Build to verify**

```bash
xcodebuild build -project TheAll.xcodeproj -scheme TheAll \
  -destination 'platform=macOS' 2>&1 | grep -E 'error:|Build succeeded'
```

Expected: `Build succeeded`.

- [ ] **Step 3: Commit**

```bash
git add TheAll/TabContent/SplitPaneView.swift TheAll.xcodeproj
git commit -m "feat: add recursive SplitPaneView with NSSplitView and ratio persistence"
```

---

## Task 5: Create TabContentView

**Files:**
- Create: `TheAll/TabContent/TabContentView.swift`

- [ ] **Step 1: Create the file**

Create `TheAll/TabContent/TabContentView.swift`:

```swift
import AppKit

/// Top-level content view that combines the tab bar and the active tab's split pane.
/// Owns a cache of GhosttyTerminalView instances keyed by terminal UUID.
final class TabContentView: NSView {
    var store: WorkspaceStore?

    private var theme: AppTheme = .systemFallback(isDark: true)
    private let tabBar: TabBarView
    private var currentSplitPane: SplitPaneView?

    /// Persistent cache: GhosttyTerminalView instances survive tab switches.
    private var terminalViews: [UUID: GhosttyTerminalView] = [:]
    private var currentWorkspaceId: UUID?
    private var currentTabLayout: SplitNode?
    private var currentTabId: UUID?
    private var keyMonitor: Any?

    override init(frame: NSRect) {
        tabBar = TabBarView(frame: .zero)
        super.init(frame: frame)
        setup()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        wantsLayer = true

        tabBar.autoresizingMask = [.width]
        addSubview(tabBar)

        tabBar.onSelectTab = { [weak self] tabId in
            guard let self, let wsId = self.store?.selectedId else { return }
            self.store?.selectTab(id: tabId, in: wsId)
            self.reloadCurrentTab()
        }
        tabBar.onAddTab = { [weak self] in
            guard let self, let wsId = self.store?.selectedId else { return }
            self.store?.addTab(to: wsId)
            self.reloadFromStore()
        }
        tabBar.onCloseTab = { [weak self] tabId in
            guard let self, let wsId = self.store?.selectedId else { return }
            self.store?.removeTab(id: tabId, from: wsId)
            self.reloadFromStore()
        }

        subscribeNotifications()
        installKeyMonitor()
    }

    override func layout() {
        super.layout()
        let tbH = TabBarView.height
        tabBar.frame = NSRect(x: 0, y: bounds.height - tbH, width: bounds.width, height: tbH)
        currentSplitPane?.frame = NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height - tbH)
    }

    // MARK: - Workspace loading (called by TabBridge)

    func loadWorkspace(_ workspace: Workspace) {
        // Different workspace → flush all terminal views
        if currentWorkspaceId != workspace.id {
            terminalViews.values.forEach { $0.removeFromSuperview() }
            terminalViews = [:]
            currentWorkspaceId = workspace.id
            currentTabId = nil
            currentTabLayout = nil
        }

        // Remove views for terminals no longer in any tab
        let liveIds = Set(workspace.tabs.flatMap { $0.layout.allTerminalIds() })
        for id in terminalViews.keys where !liveIds.contains(id) {
            terminalViews[id]?.removeFromSuperview()
            terminalViews.removeValue(forKey: id)
        }

        // Update tab bar
        tabBar.update(tabs: workspace.tabs, selectedTabId: workspace.selectedTabId, theme: theme)

        // Rebuild split pane when tab or its layout changed
        let selectedTab = workspace.selectedTab
        if currentTabId != workspace.selectedTabId || selectedTab?.layout != currentTabLayout {
            reloadCurrentTab()
        }
    }

    private func reloadFromStore() {
        guard let ws = store?.selectedWorkspace else { return }
        loadWorkspace(ws)
    }

    private func reloadCurrentTab() {
        guard let ws = store?.selectedWorkspace,
              let tab = ws.selectedTab else { return }

        currentSplitPane?.removeFromSuperview()

        let pane = buildSplitPane(for: tab)
        let tbH = TabBarView.height
        pane.frame = NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height - tbH)
        pane.autoresizingMask = [.width, .height]
        addSubview(pane, positioned: .below, relativeTo: tabBar)

        currentSplitPane = pane
        currentTabId = tab.id
        currentTabLayout = tab.layout

        // Restore focus
        focusTerminal(tab.focusedTerminalId)
    }

    private func buildSplitPane(for tab: TerminalTab) -> SplitPaneView {
        let tabId = tab.id
        let pane = SplitPaneView(node: tab.layout) { [weak self] id -> GhosttyTerminalView in
            guard let self else { return GhosttyTerminalView(frame: .zero) }
            return self.terminalViewFor(id: id)
        }
        pane.applyTheme(theme)
        pane.onFocus = { [weak self] terminalId in
            guard let self, let wsId = self.store?.selectedId else { return }
            self.store?.updateFocusedTerminal(id: terminalId, tabId: tabId, in: wsId)
            self.focusTerminal(terminalId)
        }
        pane.onRatioChanged = { [weak self] splitId, ratio in
            guard let self, let wsId = self.store?.selectedId else { return }
            self.store?.updateSplitRatio(splitId: splitId, to: ratio, tabId: tabId, in: wsId)
        }
        return pane
    }

    private func terminalViewFor(id: UUID) -> GhosttyTerminalView {
        if let existing = terminalViews[id] { return existing }
        let tv = GhosttyTerminalView(frame: .zero)
        terminalViews[id] = tv
        return tv
    }

    private func focusTerminal(_ id: UUID) {
        guard let tv = terminalViews[id] else { return }
        GhosttyTerminalView.makeFrontmost(tv)
        window?.makeFirstResponder(tv)
    }

    func applyTheme(_ theme: AppTheme) {
        self.theme = theme
        layer?.backgroundColor = theme.canvas.cgColor
        tabBar.applyTheme(theme)
        currentSplitPane?.applyTheme(theme)
    }

    func detach() {
        GhosttyTerminalView.makeFrontmost(nil)
        terminalViews.values.forEach { $0.isHidden = true }
    }

    func attach() {
        terminalViews.values.forEach { $0.isHidden = false }
        if let tab = store?.selectedWorkspace?.selectedTab {
            focusTerminal(tab.focusedTerminalId)
        }
    }

    // MARK: - Notification subscriptions

    private func subscribeNotifications() {
        let names: [Notification.Name] = [
            .theAllNewTab, .theAllClosePane,
            .theAllSplitVertical, .theAllSplitHorizontal,
            .theAllSelectNextTab, .theAllSelectPrevTab,
            .theAllSelectTabAtIndex,
        ]
        for name in names {
            NotificationCenter.default.addObserver(
                self, selector: #selector(handleNotification(_:)), name: name, object: nil)
        }
    }

    @objc private func handleNotification(_ note: Notification) {
        switch note.name {
        case .theAllNewTab:           addNewTab()
        case .theAllClosePane:        closeCurrentPane()
        case .theAllSplitVertical:    splitCurrentPane(direction: .vertical)
        case .theAllSplitHorizontal:  splitCurrentPane(direction: .horizontal)
        case .theAllSelectNextTab:    cycleTab(forward: true)
        case .theAllSelectPrevTab:    cycleTab(forward: false)
        case .theAllSelectTabAtIndex:
            if let idx = note.userInfo?["index"] as? Int { selectTab(at: idx) }
        default: break
        }
    }

    private func addNewTab() {
        guard let wsId = store?.selectedId else { return }
        store?.addTab(to: wsId)
        reloadFromStore()
    }

    private func closeCurrentPane() {
        guard let ws = store?.selectedWorkspace,
              let wsId = store?.selectedId,
              let tab = ws.selectedTab else { return }
        store?.closeTerminal(id: tab.focusedTerminalId, in: wsId, tabId: tab.id)
        reloadFromStore()
    }

    private func splitCurrentPane(direction: SplitDirection) {
        guard let ws = store?.selectedWorkspace,
              let wsId = store?.selectedId,
              let tab = ws.selectedTab else { return }
        guard let newId = store?.splitTerminal(
            id: tab.focusedTerminalId, in: wsId, tabId: tab.id, direction: direction)
        else { return }
        reloadFromStore()
        focusTerminal(newId)
    }

    private func cycleTab(forward: Bool) {
        guard let ws = store?.selectedWorkspace,
              let wsId = store?.selectedId,
              let idx = ws.tabs.firstIndex(where: { $0.id == ws.selectedTabId }) else { return }
        let count = ws.tabs.count
        let next = forward ? (idx + 1) % count : (idx - 1 + count) % count
        store?.selectTab(id: ws.tabs[next].id, in: wsId)
        reloadFromStore()
    }

    private func selectTab(at index: Int) {
        guard let ws = store?.selectedWorkspace,
              let wsId = store?.selectedId,
              index < ws.tabs.count else { return }
        store?.selectTab(id: ws.tabs[index].id, in: wsId)
        reloadFromStore()
    }

    // MARK: - Key monitor for ⌘⌥arrow pane navigation

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self,
                  event.modifierFlags.intersection([.command, .option]) == [.command, .option]
            else { return event }
            switch event.keyCode {
            case 124, 125: self.focusAdjacentPane(forward: true);  return nil  // → ↓
            case 123, 126: self.focusAdjacentPane(forward: false); return nil  // ← ↑
            default: return event
            }
        }
    }

    private func focusAdjacentPane(forward: Bool) {
        guard let ws = store?.selectedWorkspace,
              let tab = ws.selectedTab,
              let wsId = store?.selectedId else { return }
        let ids = tab.layout.allTerminalIds()
        guard let idx = ids.firstIndex(of: tab.focusedTerminalId) else { return }
        let next = forward ? (idx + 1) % ids.count : (idx - 1 + ids.count) % ids.count
        let nextId = ids[next]
        store?.updateFocusedTerminal(id: nextId, tabId: tab.id, in: wsId)
        focusTerminal(nextId)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
    }
}
```

- [ ] **Step 2: Build to verify**

```bash
xcodebuild build -project TheAll.xcodeproj -scheme TheAll \
  -destination 'platform=macOS' 2>&1 | grep -E 'error:|Build succeeded'
```

Expected: `Build succeeded` (Notification.Names are not yet defined; if compile errors appear about missing names, temporarily add stubs — they'll be added properly in Task 6).

- [ ] **Step 3: Commit**

```bash
git add TheAll/TabContent/TabContentView.swift TheAll.xcodeproj
git commit -m "feat: add TabContentView - orchestrates tab bar, split panes, terminal view cache"
```

---

## Task 6: TabBridge + wire ContentView + TheAllApp

**Files:**
- Create: `TheAll/Bridge/TabBridge.swift`
- Modify: `TheAll/ContentView.swift`
- Modify: `TheAll/TheAllApp.swift`

- [ ] **Step 1: Create `TabBridge.swift`**

Create `TheAll/Bridge/TabBridge.swift`:

```swift
import SwiftUI
import AppKit

struct TabBridge: NSViewRepresentable {
    @Bindable var store: WorkspaceStore
    var theme: AppTheme

    func makeNSView(context: Context) -> TabContentView {
        let view = TabContentView(frame: .zero)
        view.store = store
        view.applyTheme(theme)
        if let ws = store.selectedWorkspace {
            view.loadWorkspace(ws)
        }
        return view
    }

    func updateNSView(_ nsView: TabContentView, context: Context) {
        nsView.store = store
        nsView.applyTheme(theme)
        if let ws = store.selectedWorkspace {
            nsView.loadWorkspace(ws)
        }
    }

    static func dismantleNSView(_ nsView: TabContentView, coordinator: ()) {
        nsView.detach()
    }
}
```

- [ ] **Step 2: Update `ContentView.swift`**

Replace the entire file:

```swift
import SwiftUI
import AppKit

struct ContentView: View {
    @State private var store = WorkspaceStore()
    @Environment(ThemeManager.self) private var themeManager

    private let trafficLightInset: CGFloat = 28

    var body: some View {
        HStack(spacing: 0) {
            SidebarView(store: store, theme: themeManager.theme)
                .padding(.top, trafficLightInset)
            TabBridge(store: store, theme: themeManager.theme)
        }
        .frame(minWidth: 960, minHeight: 620)
        .background(Color(themeManager.theme.canvas))
        .ignoresSafeArea()
        .theAllFullSizeContent()
        .onAppear {
            themeManager.loadFromGhosttyConfig()
        }
    }
}

// MARK: - Notification names

extension Notification.Name {
    static let theAllBeginCreateWorkspace = Notification.Name("theall.beginCreateWorkspace")
    static let theAllNewTab               = Notification.Name("theall.newTab")
    static let theAllClosePane            = Notification.Name("theall.closePane")
    static let theAllSplitVertical        = Notification.Name("theall.splitVertical")
    static let theAllSplitHorizontal      = Notification.Name("theall.splitHorizontal")
    static let theAllSelectNextTab        = Notification.Name("theall.selectNextTab")
    static let theAllSelectPrevTab        = Notification.Name("theall.selectPrevTab")
    static let theAllSelectTabAtIndex     = Notification.Name("theall.selectTabAtIndex")
}
```

- [ ] **Step 3: Update `TheAllApp.swift`**

Replace the entire file:

```swift
import SwiftUI

@main
struct TheAllApp: App {
    @State private var themeManager = ThemeManager()

    init() {
        let ok = GhosttyBridge.shared.initialize()
        if !ok { print("[theall] Warning: libghostty initialization failed") }
    }

    var body: some Scene {
        WindowGroup {
            if GhosttyBridge.shared.isInitialized {
                ContentView().environment(themeManager)
            } else {
                GhosttyMissingView()
            }
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            // ── Workspace ──────────────────────────────────────────────
            CommandGroup(replacing: .newItem) {
                Button("New Workspace") {
                    post(.theAllBeginCreateWorkspace)
                }
                .keyboardShortcut("n", modifiers: .command)
            }

            // ── Tabs ───────────────────────────────────────────────────
            CommandMenu("Tab") {
                Button("New Tab")        { post(.theAllNewTab) }
                    .keyboardShortcut("t", modifiers: .command)

                Button("Close Pane")     { post(.theAllClosePane) }
                    .keyboardShortcut("w", modifiers: .command)

                Divider()

                Button("Split Vertically (Left/Right)") { post(.theAllSplitVertical) }
                    .keyboardShortcut("d", modifiers: .command)

                Button("Split Horizontally (Top/Bottom)") { post(.theAllSplitHorizontal) }
                    .keyboardShortcut("d", modifiers: [.command, .shift])

                Divider()

                Button("Select Next Tab") { post(.theAllSelectNextTab) }
                    .keyboardShortcut("]", modifiers: [.command, .shift])

                Button("Select Previous Tab") { post(.theAllSelectPrevTab) }
                    .keyboardShortcut("[", modifiers: [.command, .shift])

                Divider()

                ForEach(1...9, id: \.self) { idx in
                    Button("Select Tab \(idx)") {
                        NotificationCenter.default.post(
                            name: .theAllSelectTabAtIndex,
                            object: nil,
                            userInfo: ["index": idx - 1])
                    }
                    .keyboardShortcut(KeyEquivalent(Character(String(idx))), modifiers: .command)
                }
            }

            // ── Appearance ─────────────────────────────────────────────
            CommandMenu("Appearance") {
                Button("Dark")          { themeManager.applyScheme(.dark) }
                    .keyboardShortcut("1", modifiers: [.command, .shift])
                Button("Light")         { themeManager.applyScheme(.light) }
                    .keyboardShortcut("2", modifiers: [.command, .shift])
                Button("Follow System") { themeManager.applyScheme(.system) }
                    .keyboardShortcut("0", modifiers: [.command, .shift])
            }
        }
    }

    private func post(_ name: Notification.Name) {
        NotificationCenter.default.post(name: name, object: nil)
    }
}

/// Shown when libghostty is not available at launch.
struct GhosttyMissingView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40))
                .foregroundColor(.orange)
            Text("Ghostty not found")
                .font(.title2.bold())
            Text("theall requires Ghostty to be installed.\nRun scripts/build-vendor.sh first, then relaunch.")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
        }
        .padding(40)
        .frame(width: 400, height: 280)
    }
}
```

- [ ] **Step 4: Build and verify**

```bash
xcodebuild build -project TheAll.xcodeproj -scheme TheAll \
  -destination 'platform=macOS' 2>&1 | grep -E 'error:|Build succeeded'
```

Expected: `Build succeeded`. At this point the new tab UI is wired in (old canvas files still exist but `ContentView` no longer references them — that's fine).

- [ ] **Step 5: Commit**

```bash
git add TheAll/Bridge/TabBridge.swift TheAll/ContentView.swift TheAll/TheAllApp.swift TheAll.xcodeproj
git commit -m "feat: add TabBridge; wire ContentView and keyboard shortcuts"
```

---

## Task 7: Delete old canvas files and clean up

**Files:**
- Delete: `TheAll/Canvas/CanvasScrollView.swift`
- Delete: `TheAll/Canvas/CanvasContentView.swift`
- Delete: `TheAll/Canvas/TerminalWindowView.swift`
- Delete: `TheAll/Canvas/TitleBarView.swift`
- Delete: `TheAll/Bridge/CanvasBridge.swift`

- [ ] **Step 1: Delete the files**

```bash
rm TheAll/Canvas/CanvasScrollView.swift \
   TheAll/Canvas/CanvasContentView.swift \
   TheAll/Canvas/TerminalWindowView.swift \
   TheAll/Canvas/TitleBarView.swift \
   TheAll/Bridge/CanvasBridge.swift
```

- [ ] **Step 2: Regenerate xcodeproj (removes deleted files from project)**

```bash
xcodegen generate
```

- [ ] **Step 3: Build and run all tests**

```bash
xcodebuild test -project TheAll.xcodeproj -scheme TheAll \
  -destination 'platform=macOS' 2>&1 | grep -E 'error:|Test.*FAILED|Test.*passed|Build succeeded'
```

Expected: `Build succeeded`, all tests pass. No references to `CanvasBridge`, `TerminalWindowView`, `CanvasContentView`, etc. remain.

- [ ] **Step 4: Remove the now-empty Canvas directory if empty**

```bash
rmdir TheAll/Canvas 2>/dev/null || true
```

- [ ] **Step 5: Final commit**

```bash
git add -A
git commit -m "chore: delete canvas/drag infrastructure; complete tab+split terminal redesign"
```

---

## Self-Review Checklist

### Spec coverage

| Spec section | Covered by |
|---|---|
| §1 SplitNode/TerminalTab/Workspace model | Task 1 |
| §1 WorkspaceStore new CRUD | Task 2 |
| §1 persistence key `v2` | Task 2 (`persistenceKey = "theall.workspaces.v2"`) |
| §2 delete 5 canvas files | Task 7 |
| §2 new TabBarView | Task 3 |
| §2 new SplitPaneView | Task 4 |
| §2 new TabContentView | Task 5 |
| §2 new TabBridge | Task 6 |
| §2 modify ContentView | Task 6 |
| §2 modify TheAllApp | Task 6 |
| §3 ⌘T new tab | Task 6 `TheAllApp` |
| §3 ⌘W close pane | Task 6 `TheAllApp` |
| §3 ⌘D split vertical | Task 6 `TheAllApp` |
| §3 ⌘⇧D split horizontal | Task 6 `TheAllApp` |
| §3 ⌘⇧]/⌘⇧[ tab cycle | Task 6 `TheAllApp` |
| §3 ⌘1–⌘9 tab index | Task 6 `TheAllApp` |
| §3 ⌘⌥arrow pane focus | Task 5 `TabContentView.installKeyMonitor` |
| §3 focus restoration on tab switch | Task 5 `reloadCurrentTab` → `focusTerminal` |
| §3 pane close tree transform | Task 1 `SplitNode.removing`; Task 2 `closeTerminal` |
| §4 tab bar styling (selected accent, hover, ×) | Task 3 `TabItemView` |
| §4 NSSplitView hairline divider | Task 4 `ThemedSplitView` |
| §4 tab title "terminal N" | Task 2 `makeNewTab(index:)` |
| §5 persistence key migration | Task 2 (`v2` key; old data silently abandoned) |

All spec requirements are covered. No gaps found.
