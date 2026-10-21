# Sidebar Drag Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace SwiftUI `.onDrag`/`.onHover`-based workspace reorder in the sidebar with an AppKit `NSDraggingSource`/`NSDraggingDestination` implementation mirroring `TabBarView`, eliminating hover residual, "+" copy cursor, tap-vs-drag conflicts, and 6pt dropZone dead bands.

**Architecture:** SwiftUI `SidebarView` shell stays — it keeps owning header / footer / `.alert` / notification subscription / metadata refresher lifecycle. The list portion (currently `ScrollView + LazyVStack + WorkspaceRowView` + drag plumbing) is replaced by a single `SidebarListBridge: NSViewRepresentable` wrapping a new `WorkspaceListView: NSView`. Each row is a `WorkspaceRowItemView: NSView` (private, same file as `WorkspaceListView`) handling its own hover (`NSTrackingArea`), click select, right-click menu, inline rename, and drag source. List handles `NSDraggingDestination` with live reorder preview at 0.16s ease, threshold 4pt, `.move` operation. Pattern mirrors `TheAll/TabContent/TabBarView.swift` 1:1.

**Tech Stack:** Swift 5+, AppKit (`NSView`, `NSScrollView`, `NSDraggingSource`, `NSDraggingDestination`, `NSTrackingArea`, `NSTextField`, `NSMenu`, `NSPasteboard`), SwiftUI (`NSViewRepresentable`, `@State`, `@Observable`), `xcodegen` for project regen.

---

## File Structure

**New:**
- `TheAll/Sidebar/WorkspacePasteboardType.swift` — `NSPasteboard.PasteboardType.theAllWorkspace` constant
- `TheAll/Sidebar/WorkspaceListView.swift` — two classes in one file: `final class WorkspaceListView: NSView, NSDraggingDestination` (container + drag dest + live preview) and `private final class WorkspaceRowItemView: NSView, NSTextFieldDelegate, NSDraggingSource` (per-row interactions)
- `TheAll/Bridge/SidebarListBridge.swift` — `struct SidebarListBridge: NSViewRepresentable`
- `TheAllTests/SidebarListBridgeTests.swift` — smoke tests for bridge instantiation + update
- `TheAllTests/MetadataRefresherOnRefreshTests.swift` — unit test for new `onRefresh` callback

**Modify:**
- `TheAll/Sidebar/SidebarView.swift` — strip drag/hover/rename state; embed `SidebarListBridge`; add `metadataTick`
- `TheAll/Metadata/MetadataRefresher.swift` — add `var onRefresh: (() -> Void)?` fired on main after metadata mutation
- `CLAUDE.md` — Key Conventions §4 wording + Common Tasks sidebar row

**Delete:**
- `TheAll/Sidebar/WorkspaceRowView.swift`

---

## Task 1: Add pasteboard type

**Files:**
- Create: `TheAll/Sidebar/WorkspacePasteboardType.swift`

- [ ] **Step 1: Write the file**

```swift
import AppKit

extension NSPasteboard.PasteboardType {
    /// theall sidebar workspace 拖拽类型。仅用于 WorkspaceListView 自身内部重排——
    /// 不跨进程、不支持外部拖入。与 .theAllTab 命名对称。
    static let theAllWorkspace = NSPasteboard.PasteboardType("com.theall.workspace")
}
```

- [ ] **Step 2: Regenerate Xcode project & build**

```bash
xcodegen generate && xcodebuild -project TheAll.xcodeproj -scheme TheAll -configuration Debug build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add TheAll/Sidebar/WorkspacePasteboardType.swift project.yml
git commit -m "feat(sidebar): add theAllWorkspace pasteboard type for AppKit drag"
```

---

## Task 2: Create WorkspaceListView.swift skeleton with `WorkspaceRowItemView` (visual states + theme + refresh)

**Files:**
- Create: `TheAll/Sidebar/WorkspaceListView.swift`

This task creates the row class with init/layout/visual states only. Hover, click, rename, drag, menu come in subsequent tasks. Container `WorkspaceListView` also gets a minimal skeleton so the file compiles and we can wire it in tasks 7+.

- [ ] **Step 1: Create the file with both class skeletons**

```swift
import AppKit

// MARK: - FlippedRowsContainer

/// 文档视图坐标系翻转：第 0 行 y=0 在顶部，行索引递增向下。
/// 不翻转的话 NSView 默认 origin-bottom-left，row 布局算式反复 (height - i*rowH)，
/// 容易出错且难维护。
private final class FlippedRowsContainer: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - WorkspaceListView

/// 侧边栏 workspace 列表（AppKit 实现，对标 TabBarView）。
/// 拖拽 / hover / rename / 右键菜单全部在此层完成，外层 SidebarView 仅作 SwiftUI 壳。
final class WorkspaceListView: NSView {
    var onSelect: ((UUID) -> Void)?
    var onRename: ((UUID, String) -> Void)?
    var onReorder: ((Int, Int) -> Void)?       // (fromIndex, toIndex) insertion 0…count
    var onRequestDelete: ((UUID) -> Void)?

    private let scrollView = NSScrollView()
    private let rowsContainer = FlippedRowsContainer()
    private var theme: AppTheme = .systemFallback(isDark: true)
    private var workspaces: [Workspace] = []
    private var selectedId: UUID?
    private var metadataMap: [UUID: WorkspaceMetadata] = [:]

    // Drag preview state (Task 8 fills these in)
    fileprivate var draggingId: UUID?
    fileprivate var previewInsertionIndex: Int?

    static let rowHeight: CGFloat = 44
    static let rowSpacing: CGFloat = 0
    static let outerHorizontalInset: CGFloat = DT.Space.sm

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
        scrollView.documentView = rowsContainer
        scrollView.autoresizingMask = []
        addSubview(scrollView)
    }

    override func layout() {
        super.layout()
        scrollView.frame = bounds
        layoutRows(animated: false)
    }

    func update(workspaces: [Workspace],
                selectedId: UUID?,
                metadata: [UUID: WorkspaceMetadata],
                theme: AppTheme) {
        self.workspaces = workspaces
        self.selectedId = selectedId
        self.metadataMap = metadata
        self.theme = theme
        rebuildRows()
        applyTheme(theme)
    }

    func applyTheme(_ theme: AppTheme) {
        self.theme = theme
        rowsContainer.subviews
            .compactMap { $0 as? WorkspaceRowItemView }
            .forEach { $0.applyTheme(theme) }
        needsDisplay = true
    }

    // 完整重建（Task 7 升级为 id-diff 增量刷新）
    private func rebuildRows() {
        rowsContainer.subviews
            .compactMap { $0 as? WorkspaceRowItemView }
            .forEach { $0.removeFromSuperview() }

        for ws in workspaces {
            let meta = metadataMap[ws.id] ?? WorkspaceMetadata()
            let item = WorkspaceRowItemView(
                workspace: ws,
                isSelected: ws.id == selectedId,
                metadata: meta,
                theme: theme)
            rowsContainer.addSubview(item)
        }
        layoutRows(animated: false)
    }

    // 默认按 self.workspaces 顺序排布。Task 8 会加入 preview 顺序覆盖。
    // rowsContainer 已 flipped → y=0 顶部，向下递增。
    fileprivate func layoutRows(animated: Bool = false) {
        let items = rowsContainer.subviews.compactMap { $0 as? WorkspaceRowItemView }
        let w = max(0, scrollView.contentSize.width - Self.outerHorizontalInset * 2)
        let h = Self.rowHeight
        let totalH = CGFloat(items.count) * (h + Self.rowSpacing) - (items.isEmpty ? 0 : Self.rowSpacing)
        let containerH = max(totalH, scrollView.contentSize.height)

        let apply = {
            var y: CGFloat = 0
            for item in items {
                let frame = NSRect(x: Self.outerHorizontalInset, y: y, width: w, height: h)
                if animated {
                    item.animator().frame = frame
                } else {
                    item.frame = frame
                }
                y += h + Self.rowSpacing
            }
            self.rowsContainer.frame = NSRect(
                x: 0, y: 0,
                width: self.scrollView.contentSize.width,
                height: containerH)
        }
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.16
                ctx.allowsImplicitAnimation = true
                apply()
            }
        } else {
            apply()
        }
    }
}

// MARK: - WorkspaceRowItemView

private final class WorkspaceRowItemView: NSView {
    let workspaceId: UUID

    var onSelect: (() -> Void)?
    var onRename: ((String) -> Void)?
    var onRequestDelete: (() -> Void)?
    var onDragEnded: (() -> Void)?

    var isDragGhost: Bool = false {
        didSet {
            guard oldValue != isDragGhost else { return }
            alphaValue = isDragGhost ? 0.35 : 1
        }
    }

    private let backgroundLayerView = NSView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let branchLabel = NSTextField(labelWithString: "")
    private let prBadge = NSTextField(labelWithString: "")
    fileprivate let renameField = NSTextField()

    fileprivate var isSelected: Bool
    fileprivate var isHovered = false
    fileprivate var isRenaming = false
    fileprivate var theme: AppTheme
    private var workspace: Workspace
    private var metadata: WorkspaceMetadata
    fileprivate var originalTitle: String = ""

    init(workspace: Workspace, isSelected: Bool,
         metadata: WorkspaceMetadata, theme: AppTheme) {
        self.workspaceId = workspace.id
        self.workspace = workspace
        self.isSelected = isSelected
        self.metadata = metadata
        self.theme = theme
        super.init(frame: .zero)
        setup()
        updateContent()
        updateStyle()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        wantsLayer = true

        backgroundLayerView.wantsLayer = true
        backgroundLayerView.layer?.cornerRadius = DT.Radius.row
        backgroundLayerView.layer?.masksToBounds = true
        addSubview(backgroundLayerView)

        titleLabel.isBezeled = false
        titleLabel.drawsBackground = false
        titleLabel.isEditable = false
        titleLabel.isSelectable = false
        titleLabel.lineBreakMode = .byTruncatingTail
        addSubview(titleLabel)

        branchLabel.isBezeled = false
        branchLabel.drawsBackground = false
        branchLabel.isEditable = false
        branchLabel.isSelectable = false
        branchLabel.lineBreakMode = .byTruncatingMiddle
        branchLabel.font = DT.Font.mono
        addSubview(branchLabel)

        prBadge.isBezeled = false
        prBadge.drawsBackground = false
        prBadge.isEditable = false
        prBadge.isSelectable = false
        prBadge.font = DT.Font.micro
        addSubview(prBadge)

        renameField.isBezeled = false
        renameField.drawsBackground = false
        renameField.isEditable = true
        renameField.isSelectable = true
        renameField.focusRingType = .none
        renameField.isHidden = true
        addSubview(renameField)
    }

    override func layout() {
        super.layout()
        backgroundLayerView.frame = bounds

        let hPad = DT.Space.md
        let topPad = DT.Space.xs
        let titleH = ceil(titleLabel.intrinsicContentSize.height)
        let branchH = ceil(branchLabel.intrinsicContentSize.height)
        let prW: CGFloat = prBadge.isHidden
            ? 0
            : ceil(prBadge.intrinsicContentSize.width) + DT.Space.xs

        let titleFrame = NSRect(
            x: hPad, y: bounds.height - topPad - titleH,
            width: bounds.width - hPad * 2 - prW, height: titleH)
        titleLabel.frame = titleFrame
        renameField.frame = titleFrame
        renameField.font = titleLabel.font

        if !prBadge.isHidden {
            prBadge.frame = NSRect(
                x: bounds.width - hPad - prW + DT.Space.xs,
                y: bounds.height - topPad - titleH,
                width: prW, height: titleH)
        }

        branchLabel.frame = NSRect(
            x: hPad, y: topPad,
            width: bounds.width - hPad * 2, height: branchH)
    }

    func refresh(workspace: Workspace, isSelected: Bool,
                 metadata: WorkspaceMetadata, theme: AppTheme) {
        self.workspace = workspace
        self.isSelected = isSelected
        self.metadata = metadata
        self.theme = theme
        if !isRenaming, titleLabel.stringValue != workspace.name {
            titleLabel.stringValue = workspace.name
        }
        updateContent()
        updateStyle()
        needsLayout = true
    }

    func applyTheme(_ theme: AppTheme) {
        self.theme = theme
        updateStyle()
    }

    private func updateContent() {
        titleLabel.stringValue = workspace.name
        if let branch = metadata.gitBranch {
            branchLabel.stringValue = "⎇ \(branch)"
            branchLabel.isHidden = false
        } else {
            branchLabel.stringValue = ""
            branchLabel.isHidden = true
        }
        if let pr = metadata.prStatus {
            prBadge.stringValue = pr.uppercased()
            prBadge.isHidden = false
        } else {
            prBadge.stringValue = ""
            prBadge.isHidden = true
        }
    }

    fileprivate func updateStyle() {
        if isSelected {
            backgroundLayerView.layer?.backgroundColor = theme.borderStrong.cgColor
            titleLabel.textColor = theme.textPrimary
            titleLabel.font = DT.Font.bodyB
        } else if isHovered {
            backgroundLayerView.layer?.backgroundColor = theme.border.cgColor
            titleLabel.textColor = theme.textSecondary
            titleLabel.font = DT.Font.body
        } else {
            backgroundLayerView.layer?.backgroundColor = NSColor.clear.cgColor
            titleLabel.textColor = theme.textSecondary
            titleLabel.font = DT.Font.body
        }
        branchLabel.textColor = theme.textTertiary
        prBadge.textColor = theme.textTertiary
        renameField.textColor = theme.textPrimary
        needsDisplay = true
    }
}
```

- [ ] **Step 2: Build to verify compile**

```bash
xcodegen generate && xcodebuild -project TheAll.xcodeproj -scheme TheAll -configuration Debug build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add TheAll/Sidebar/WorkspaceListView.swift project.yml
git commit -m "feat(sidebar): WorkspaceListView + WorkspaceRowItemView skeleton"
```

---

## Task 3: Add hover via NSTrackingArea

**Files:**
- Modify: `TheAll/Sidebar/WorkspaceListView.swift` (`WorkspaceRowItemView`)

- [ ] **Step 1: Add tracking area + mouse enter/exit overrides inside `WorkspaceRowItemView`**

Insert after the `applyTheme(_:)` method:

```swift
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect],
            owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        updateStyle()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        updateStyle()
    }
```

- [ ] **Step 2: Build**

```bash
xcodebuild -project TheAll.xcodeproj -scheme TheAll -configuration Debug build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add TheAll/Sidebar/WorkspaceListView.swift
git commit -m "feat(sidebar): NSTrackingArea-driven hover for workspace rows"
```

---

## Task 4: Add click select + right-click context menu

**Files:**
- Modify: `TheAll/Sidebar/WorkspaceListView.swift` (`WorkspaceRowItemView`)

- [ ] **Step 1: Add click + menu handlers + `acceptsFirstMouse`**

Insert after `mouseExited`:

```swift
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    fileprivate var mouseDownLocation: NSPoint = .zero

    override func mouseDown(with event: NSEvent) {
        mouseDownLocation = event.locationInWindow
        onSelect?()
    }

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        // autoenablesItems=true 会把 isEnabled=false 覆盖回 true，
        // 这里需要严格遵守我们设的 enabled 状态。
        menu.autoenablesItems = false

        let renameItem = NSMenuItem(
            title: "Rename",
            action: #selector(beginRenameAction),
            keyEquivalent: "")
        renameItem.target = self
        menu.addItem(renameItem)

        menu.addItem(.separator())

        let deleteItem = NSMenuItem(
            title: "Delete",
            action: #selector(deleteAction),
            keyEquivalent: "")
        deleteItem.target = self
        menu.addItem(deleteItem)

        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc fileprivate func deleteAction() {
        onRequestDelete?()
    }

    // beginRenameAction 在 Task 5 实现
    @objc fileprivate func beginRenameAction() {
        // placeholder — Task 5 fills in
    }
```

- [ ] **Step 2: Build**

```bash
xcodebuild -project TheAll.xcodeproj -scheme TheAll -configuration Debug build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add TheAll/Sidebar/WorkspaceListView.swift
git commit -m "feat(sidebar): click select + right-click menu (Rename/Delete) on rows"
```

---

## Task 5: Inline rename via NSTextField

**Files:**
- Modify: `TheAll/Sidebar/WorkspaceListView.swift` (`WorkspaceRowItemView`)

- [ ] **Step 1: Conform to `NSTextFieldDelegate`**

Change the class declaration line:

```swift
private final class WorkspaceRowItemView: NSView, NSTextFieldDelegate {
```

- [ ] **Step 2: Wire `renameField.delegate = self` in `setup()`**

Inside `setup()`, after `renameField.isHidden = true`:

```swift
        renameField.delegate = self
        renameField.font = DT.Font.body
```

- [ ] **Step 3: Replace placeholder `beginRenameAction` and add commit/cancel + delegate methods**

Replace the placeholder `@objc fileprivate func beginRenameAction()` with:

```swift
    @objc fileprivate func beginRenameAction() {
        guard !isRenaming else { return }
        originalTitle = titleLabel.stringValue
        renameField.stringValue = originalTitle
        titleLabel.isHidden = true
        renameField.isHidden = false
        isRenaming = true
        window?.makeFirstResponder(renameField)
        renameField.currentEditor()?.selectAll(nil)
    }

    private func finishRenameUI() {
        renameField.isHidden = true
        titleLabel.isHidden = false
        isRenaming = false
    }

    private func commitRename() {
        guard isRenaming else { return }
        let newTitle = renameField.stringValue
        finishRenameUI()
        onRename?(newTitle)
    }

    private func cancelRename() {
        guard isRenaming else { return }
        renameField.stringValue = originalTitle
        finishRenameUI()
    }

    // NSTextFieldDelegate
    func control(_ control: NSControl, textView: NSTextView,
                 doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            cancelRename()
            return true
        }
        return false
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        // 回车 / 失焦都走这里；Esc 已在 doCommandBy 中提前 finish 了
        commitRename()
    }
```

- [ ] **Step 4: Build**

```bash
xcodebuild -project TheAll.xcodeproj -scheme TheAll -configuration Debug build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add TheAll/Sidebar/WorkspaceListView.swift
git commit -m "feat(sidebar): inline rename via NSTextField on workspace rows"
```

---

## Task 6: Drag source (NSDraggingSource) with 4pt threshold and `.move` operation

**Files:**
- Modify: `TheAll/Sidebar/WorkspaceListView.swift` (`WorkspaceRowItemView`)

- [ ] **Step 1: Conform to `NSDraggingSource`**

Update class declaration:

```swift
private final class WorkspaceRowItemView: NSView, NSTextFieldDelegate, NSDraggingSource {
```

- [ ] **Step 2: Add `mouseDragged` + drag source methods + snapshot**

Insert after `controlTextDidEndEditing`:

```swift
    override func mouseDragged(with event: NSEvent) {
        if isRenaming { return }
        let dx = event.locationInWindow.x - mouseDownLocation.x
        let dy = event.locationInWindow.y - mouseDownLocation.y
        guard (dx * dx + dy * dy) > 16 else { return }    // 4pt 阈值

        let pbItem = NSPasteboardItem()
        pbItem.setString(workspaceId.uuidString, forType: .theAllWorkspace)

        let draggingItem = NSDraggingItem(pasteboardWriter: pbItem)
        draggingItem.setDraggingFrame(bounds, contents: snapshotForDragging())

        beginDraggingSession(with: [draggingItem], event: event, source: self)
    }

    private func snapshotForDragging() -> NSImage {
        guard let rep = bitmapImageRepForCachingDisplay(in: bounds) else { return NSImage() }
        cacheDisplay(in: bounds, to: rep)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(rep)
        return image
    }

    // NSDraggingSource
    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        return .move
    }

    func draggingSession(_ session: NSDraggingSession,
                         endedAt screenPoint: NSPoint,
                         operation: NSDragOperation) {
        onDragEnded?()
    }
```

- [ ] **Step 3: Build**

```bash
xcodebuild -project TheAll.xcodeproj -scheme TheAll -configuration Debug build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add TheAll/Sidebar/WorkspaceListView.swift
git commit -m "feat(sidebar): NSDraggingSource on rows (4pt threshold, .move op)"
```

---

## Task 7: WorkspaceListView id-diff incremental update + callback wiring

**Files:**
- Modify: `TheAll/Sidebar/WorkspaceListView.swift` (`WorkspaceListView`)

- [ ] **Step 1: Replace `rebuildRows()` with id-diff strategy**

Find the existing `rebuildRows()` method and replace with:

```swift
    /// id-diff：只在 workspace 序列变化时完整重建；否则原地 refresh，保留每行
    /// first responder 与 mouseDown/mouseDragged 链（rename / 拖拽不被打断）。
    private func rebuildRows() {
        let existing = rowsContainer.subviews.compactMap { $0 as? WorkspaceRowItemView }
        let existingIds = existing.map(\.workspaceId)
        let targetIds = workspaces.map(\.id)

        if existingIds == targetIds {
            for item in existing {
                guard let ws = workspaces.first(where: { $0.id == item.workspaceId }) else { continue }
                let meta = metadataMap[item.workspaceId] ?? WorkspaceMetadata()
                item.refresh(workspace: ws,
                             isSelected: ws.id == selectedId,
                             metadata: meta,
                             theme: theme)
            }
            return
        }

        existing.forEach { $0.removeFromSuperview() }
        for ws in workspaces {
            let meta = metadataMap[ws.id] ?? WorkspaceMetadata()
            let item = WorkspaceRowItemView(
                workspace: ws,
                isSelected: ws.id == selectedId,
                metadata: meta,
                theme: theme)
            wireRowCallbacks(item)
            rowsContainer.addSubview(item)
        }
        layoutRows(animated: false)
    }

    private func wireRowCallbacks(_ item: WorkspaceRowItemView) {
        let id = item.workspaceId
        item.onSelect        = { [weak self] in self?.onSelect?(id) }
        item.onRename        = { [weak self] newName in self?.onRename?(id, newName) }
        item.onRequestDelete = { [weak self] in self?.onRequestDelete?(id) }
        item.onDragEnded     = { [weak self] in self?.cleanupAfterDrag() }
    }

    fileprivate func cleanupAfterDrag() {
        guard draggingId != nil || previewInsertionIndex != nil else { return }
        draggingId = nil
        previewInsertionIndex = nil
        rowsContainer.subviews
            .compactMap { $0 as? WorkspaceRowItemView }
            .forEach { $0.isDragGhost = false }
        layoutRows(animated: true)
    }
```

- [ ] **Step 2: Build**

```bash
xcodebuild -project TheAll.xcodeproj -scheme TheAll -configuration Debug build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add TheAll/Sidebar/WorkspaceListView.swift
git commit -m "feat(sidebar): id-diff incremental row refresh + callback wiring"
```

---

## Task 8: NSDraggingDestination + live preview reorder

**Files:**
- Modify: `TheAll/Sidebar/WorkspaceListView.swift` (`WorkspaceListView`)

- [ ] **Step 1: Conform to `NSDraggingDestination` and register pasteboard type**

Update class declaration:

```swift
final class WorkspaceListView: NSView, NSDraggingDestination {
```

In `setup()`, after `addSubview(scrollView)`:

```swift
        registerForDraggedTypes([.theAllWorkspace])
```

- [ ] **Step 2: Add `previewOrdered` + `insertionIndex(at:)` helpers**

Insert before `layoutRows`:

```swift
    /// 返回应当显示的行顺序（考虑 drag preview）。
    private func previewOrdered(items: [WorkspaceRowItemView]) -> [WorkspaceRowItemView] {
        guard let draggingId,
              let insertion = previewInsertionIndex,
              let fromIdx = items.firstIndex(where: { $0.workspaceId == draggingId })
        else { return items }

        var copy = items
        let picked = copy.remove(at: fromIdx)
        // insertion 用 "before index" 语义；移除被拖项后 > fromIdx 的 insertion 左移 1
        let dest = insertion > fromIdx ? insertion - 1 : insertion
        copy.insert(picked, at: max(0, min(copy.count, dest)))
        return copy
    }

    /// 根据鼠标 y 算应插入的位置（0…workspaces.count）。基于原始 workspaces 顺序的 slot 中线。
    /// rowsContainer 已 flipped → y=0 在顶部，pointInContainer.y 即 distance-from-top。
    private func insertionIndex(at pointInSelf: NSPoint) -> Int {
        guard !workspaces.isEmpty else { return 0 }
        let pointInContainer = rowsContainer.convert(pointInSelf, from: self)
        let rowH = Self.rowHeight + Self.rowSpacing
        for i in 0..<workspaces.count {
            let midY = (CGFloat(i) + 0.5) * rowH
            if pointInContainer.y < midY { return i }
        }
        return workspaces.count
    }
```

- [ ] **Step 3: Update `layoutRows` to use preview ordering and mark ghost**

Replace the existing `layoutRows` body with:

```swift
    fileprivate func layoutRows(animated: Bool = false) {
        let items = rowsContainer.subviews.compactMap { $0 as? WorkspaceRowItemView }
        let ordered = previewOrdered(items: items)
        let w = max(0, scrollView.contentSize.width - Self.outerHorizontalInset * 2)
        let h = Self.rowHeight
        let totalH = CGFloat(ordered.count) * (h + Self.rowSpacing) - (ordered.isEmpty ? 0 : Self.rowSpacing)
        let containerH = max(totalH, scrollView.contentSize.height)

        let apply = {
            // flipped 容器 → y=0 顶部，向下递增
            var y: CGFloat = 0
            for item in ordered {
                let frame = NSRect(x: Self.outerHorizontalInset, y: y, width: w, height: h)
                if animated {
                    item.animator().frame = frame
                } else {
                    item.frame = frame
                }
                item.isDragGhost = (item.workspaceId == self.draggingId)
                y += h + Self.rowSpacing
            }
            self.rowsContainer.frame = NSRect(
                x: 0, y: 0,
                width: self.scrollView.contentSize.width,
                height: containerH)
        }
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.16
                ctx.allowsImplicitAnimation = true
                apply()
            }
        } else {
            apply()
        }
    }
```

- [ ] **Step 4: Add NSDraggingDestination overrides at the bottom of `WorkspaceListView` (before closing `}`)**

```swift
    // MARK: - NSDraggingDestination

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if let idString = sender.draggingPasteboard.string(forType: .theAllWorkspace),
           let uuid = UUID(uuidString: idString) {
            draggingId = uuid
        }
        return draggingUpdated(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard sender.draggingPasteboard.types?.contains(.theAllWorkspace) == true else {
            return []
        }
        let pointInSelf = convert(sender.draggingLocation, from: nil)
        let idx = insertionIndex(at: pointInSelf)
        if idx != previewInsertionIndex {
            previewInsertionIndex = idx
            layoutRows(animated: true)
        }
        if let event = NSApp.currentEvent {
            scrollView.contentView.autoscroll(with: event)
        }
        return .move
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        if previewInsertionIndex != nil {
            previewInsertionIndex = nil
            layoutRows(animated: true)
        }
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let idString = sender.draggingPasteboard.string(forType: .theAllWorkspace),
              let uuid = UUID(uuidString: idString),
              let from = workspaces.firstIndex(where: { $0.id == uuid })
        else {
            cleanupAfterDrag()
            return false
        }
        let pointInSelf = convert(sender.draggingLocation, from: nil)
        let to = insertionIndex(at: pointInSelf)
        onReorder?(from, to)
        cleanupAfterDrag()
        return true
    }
```

- [ ] **Step 5: Build**

```bash
xcodebuild -project TheAll.xcodeproj -scheme TheAll -configuration Debug build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 6: Commit**

```bash
git add TheAll/Sidebar/WorkspaceListView.swift
git commit -m "feat(sidebar): NSDraggingDestination live reorder preview"
```

---

## Task 9: SidebarListBridge (NSViewRepresentable)

**Files:**
- Create: `TheAll/Bridge/SidebarListBridge.swift`

- [ ] **Step 1: Write the bridge**

```swift
import SwiftUI
import AppKit

struct SidebarListBridge: NSViewRepresentable {
    @Bindable var store: WorkspaceStore
    var theme: AppTheme
    var metadata: [UUID: WorkspaceMetadata]
    /// 由 SidebarView 用 @State Int 触发；本身不读，只用于让 SwiftUI 重跑 body→updateNSView，
    /// 把最新 metadata 推进 WorkspaceListView。
    var metadataTick: Int
    var onRequestDelete: (UUID) -> Void

    func makeNSView(context: Context) -> WorkspaceListView {
        let view = WorkspaceListView()
        wire(view)
        view.update(workspaces: store.workspaces,
                    selectedId: store.selectedId,
                    metadata: metadata,
                    theme: theme)
        return view
    }

    func updateNSView(_ view: WorkspaceListView, context: Context) {
        wire(view)
        view.update(workspaces: store.workspaces,
                    selectedId: store.selectedId,
                    metadata: metadata,
                    theme: theme)
    }

    private func wire(_ view: WorkspaceListView) {
        view.onSelect        = { id in store.select(id: id) }
        view.onRename        = { id, name in store.renameWorkspace(id: id, to: name) }
        view.onReorder       = { from, to in store.moveWorkspace(from: IndexSet([from]), to: to) }
        view.onRequestDelete = { id in onRequestDelete(id) }
    }
}
```

- [ ] **Step 2: Regenerate Xcode project & build**

```bash
xcodegen generate && xcodebuild -project TheAll.xcodeproj -scheme TheAll -configuration Debug build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add TheAll/Bridge/SidebarListBridge.swift project.yml
git commit -m "feat(sidebar): SidebarListBridge NSViewRepresentable"
```

---

## Task 10: MetadataRefresher onRefresh callback (TDD)

**Files:**
- Modify: `TheAll/Metadata/MetadataRefresher.swift`
- Create: `TheAllTests/MetadataRefresherOnRefreshTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import TheAll

final class MetadataRefresherOnRefreshTests: XCTestCase {

    func testOnRefreshFiresAfterMetadataMutation() {
        let metadata = WorkspaceMetadata()
        let refresher = MetadataRefresher(
            metadata: metadata,
            workingDirectory: NSHomeDirectory())

        let exp = expectation(description: "onRefresh fires on main")
        refresher.onRefresh = {
            XCTAssertTrue(Thread.isMainThread)
            exp.fulfill()
        }

        refresher.start()
        wait(for: [exp], timeout: 5)
        refresher.stop()
    }
}
```

- [ ] **Step 2: Regen + run test, expect failure**

```bash
xcodegen generate && xcodebuild test -project TheAll.xcodeproj -scheme TheAllTests -only-testing:TheAllTests/MetadataRefresherOnRefreshTests 2>&1 | tail -20
```

Expected: build fails OR test fails — `MetadataRefresher` has no `onRefresh` property.

- [ ] **Step 3: Add `onRefresh` to MetadataRefresher**

In `TheAll/Metadata/MetadataRefresher.swift`, add a stored property below `private var timer: Timer?`:

```swift
    var onRefresh: (() -> Void)?
```

Then in the `refresh()` method, after `self.metadata.gitBranch = branch`, add:

```swift
                self.onRefresh?()
```

So the full updated `refresh()` looks like:

```swift
    private func refresh() {
        DispatchQueue.global(qos: .background).async { [weak self] in
            guard let self else { return }
            let branch = self.fetchGitBranch()
            DispatchQueue.main.async {
                self.metadata.gitBranch = branch
                self.onRefresh?()
            }
        }
    }
```

- [ ] **Step 4: Run test, expect pass**

```bash
xcodebuild test -project TheAll.xcodeproj -scheme TheAllTests -only-testing:TheAllTests/MetadataRefresherOnRefreshTests 2>&1 | tail -20
```

Expected: `Test Suite 'MetadataRefresherOnRefreshTests' passed`

- [ ] **Step 5: Commit**

```bash
git add TheAll/Metadata/MetadataRefresher.swift TheAllTests/MetadataRefresherOnRefreshTests.swift
git commit -m "feat(metadata): MetadataRefresher onRefresh callback fires on main"
```

---

## Task 11: Refactor SidebarView — strip drag/hover/rename state, embed bridge

**Files:**
- Modify: `TheAll/Sidebar/SidebarView.swift`

- [ ] **Step 1: Replace SidebarView with the trimmed version**

Open `TheAll/Sidebar/SidebarView.swift` and replace the entire file contents with:

```swift
import SwiftUI
import Observation

/// 引用类型 ticker：MetadataRefresher 的 onRefresh 是逃逸闭包，
/// 直接 `metadataTick &+= 1` (值类型 @State Int) 只会修改捕获的副本，不会触发
/// SwiftUI 重渲。换成 @Observable class，闭包按引用捕获，mutate 才能让 SwiftUI 重跑 body。
@Observable
fileprivate final class MetadataChangeTicker {
    var tick: Int = 0
}

struct SidebarView: View {
    @Bindable var store: WorkspaceStore
    var theme: AppTheme
    @State private var metadataMap: [UUID: WorkspaceMetadata] = [:]
    @State private var refreshers: [UUID: MetadataRefresher] = [:]
    @State private var metadataTicker = MetadataChangeTicker()
    @State private var isCreating = false
    @State private var newWorkspaceName = ""
    @FocusState private var newFieldFocused: Bool

    // Delete confirmation (alert lives in SwiftUI shell; AppKit row bubbles request up)
    @State private var workspaceToDelete: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            SidebarListBridge(
                store: store,
                theme: theme,
                metadata: metadataMap,
                metadataTick: metadataTicker.tick,    // 读取触发 @Observable 跟踪
                onRequestDelete: { workspaceToDelete = $0 }
            )
            footer
        }
        .frame(width: DT.Layout.sidebarWidth)
        .background(Color(theme.sidebar))
        .onAppear { startRefreshers() }
        .onChange(of: store.workspaces) { _, _ in startRefreshers() }
        .onReceive(NotificationCenter.default.publisher(for: .theAllBeginCreateWorkspace)) { _ in
            beginCreate()
        }
        .alert("Delete workspace?",
               isPresented: Binding(
                   get: { workspaceToDelete != nil },
                   set: { if !$0 { workspaceToDelete = nil } })) {
            Button("Cancel", role: .cancel) { workspaceToDelete = nil }
            Button("Delete", role: .destructive) {
                if let id = workspaceToDelete {
                    store.deleteWorkspace(id: id)
                }
                workspaceToDelete = nil
            }
        } message: {
            if let id = workspaceToDelete,
               let ws = store.workspaces.first(where: { $0.id == id }) {
                Text("「\(ws.name)」及其所有 tab 将被删除，此操作不可撤销。")
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: DT.Space.sm) {
            Text("theall")
                .font(Font(DT.Font.title))
                .foregroundColor(Color(theme.textPrimary))
            Spacer()
            Text("\(store.workspaces.count)")
                .font(Font(DT.Font.mono))
                .foregroundColor(Color(theme.textTertiary))
        }
        .padding(.horizontal, DT.Space.md)
        .padding(.vertical, DT.Space.md)
    }

    // MARK: - Footer

    private var footer: some View {
        Group {
            if isCreating {
                creationField
            } else {
                createButton
            }
        }
    }

    private var createButton: some View {
        Button {
            beginCreate()
        } label: {
            HStack(spacing: DT.Space.sm) {
                Text("+")
                    .font(Font(DT.Font.body))
                Text("New workspace")
                    .font(Font(DT.Font.small))
                Spacer()
                Text("⌘N")
                    .font(Font(DT.Font.mono))
                    .foregroundColor(Color(theme.textTertiary))
            }
            .foregroundColor(Color(theme.textSecondary))
            .padding(.horizontal, DT.Space.md)
            .padding(.vertical, DT.Space.md)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var creationField: some View {
        HStack(spacing: DT.Space.sm) {
            Text("›")
                .font(Font(DT.Font.body))
                .foregroundColor(Color(theme.accent))
            TextField("workspace name", text: $newWorkspaceName)
                .textFieldStyle(.plain)
                .font(Font(DT.Font.small))
                .foregroundColor(Color(theme.textPrimary))
                .focused($newFieldFocused)
                .onSubmit { commitCreate() }
                .onExitCommand { cancelCreate() }
        }
        .padding(.horizontal, DT.Space.md)
        .padding(.vertical, DT.Space.md)
    }

    // MARK: - Create flow

    func beginCreate() {
        isCreating = true
        newWorkspaceName = ""
        DispatchQueue.main.async { newFieldFocused = true }
    }

    private func commitCreate() {
        let name = newWorkspaceName.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty {
            store.createWorkspace(name: name)
        }
        cancelCreate()
    }

    private func cancelCreate() {
        isCreating = false
        newWorkspaceName = ""
        newFieldFocused = false
    }

    // MARK: - Refreshers

    private func startRefreshers() {
        let activeIds = Set(store.workspaces.map { $0.id })
        for id in refreshers.keys where !activeIds.contains(id) {
            refreshers[id]?.stop()
            refreshers.removeValue(forKey: id)
            metadataMap.removeValue(forKey: id)
        }
        for ws in store.workspaces where refreshers[ws.id] == nil {
            let meta = WorkspaceMetadata()
            metadataMap[ws.id] = meta
            let refresher = MetadataRefresher(metadata: meta, workingDirectory: NSHomeDirectory())
            let ticker = metadataTicker  // capture by reference
            refresher.onRefresh = {
                // mutate 引用类型属性 → @Observable 通知 SwiftUI body 重跑 → updateNSView 推 metadata
                // overflow-safe：tick 数值无意义，只要变化就行
                ticker.tick &+= 1
            }
            refreshers[ws.id] = refresher
            refresher.start()
        }
    }
}
```

- [ ] **Step 2: Build**

```bash
xcodebuild -project TheAll.xcodeproj -scheme TheAll -configuration Debug build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add TheAll/Sidebar/SidebarView.swift
git commit -m "refactor(sidebar): strip SwiftUI drag/hover/rename; embed SidebarListBridge"
```

---

## Task 12: Delete WorkspaceRowView.swift

**Files:**
- Delete: `TheAll/Sidebar/WorkspaceRowView.swift`

- [ ] **Step 1: Delete the file**

```bash
git rm TheAll/Sidebar/WorkspaceRowView.swift
```

- [ ] **Step 2: Regen + build**

```bash
xcodegen generate && xcodebuild -project TheAll.xcodeproj -scheme TheAll -configuration Debug build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add project.yml
git commit -m "chore(sidebar): remove obsolete WorkspaceRowView.swift"
```

---

## Task 13: SidebarListBridge smoke test

**Files:**
- Create: `TheAllTests/SidebarListBridgeTests.swift`

- [ ] **Step 1: Write the test file**

`NSViewRepresentableContext` has no public initializer, so we drive the bridge through `NSHostingView` and walk the resulting view tree to find the `WorkspaceListView`.

```swift
import XCTest
import SwiftUI
@testable import TheAll

final class SidebarListBridgeTests: XCTestCase {

    private func makeStore(workspaceCount: Int) -> WorkspaceStore {
        // Unique persistence key per test → no UserDefaults cross-pollution.
        let key = "theall.test.sidebar.\(UUID().uuidString)"
        let store = WorkspaceStore(persistenceKey: key)
        // Custom-key store starts empty (auto-default only on prod key).
        for i in 0..<workspaceCount {
            store.createWorkspace(name: "ws\(i)")
        }
        return store
    }

    /// Drives the bridge through NSHostingView and returns the inner WorkspaceListView.
    private func materialize(_ store: WorkspaceStore,
                             metadata: [UUID: WorkspaceMetadata] = [:],
                             tick: Int = 0) throws -> (NSHostingView<AnyView>, WorkspaceListView) {
        let bridge = SidebarListBridge(
            store: store,
            theme: .systemFallback(isDark: true),
            metadata: metadata,
            metadataTick: tick,
            onRequestDelete: { _ in }
        )
        let host = NSHostingView(rootView: AnyView(bridge))
        host.frame = NSRect(x: 0, y: 0, width: 200, height: 400)
        host.layout()
        // Run loop tick — SwiftUI may defer NSView creation until the next iteration.
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        let listView = try XCTUnwrap(findFirst(WorkspaceListView.self, in: host),
                                     "WorkspaceListView not found in hosting view tree")
        return (host, listView)
    }

    private func findFirst<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let hit = view as? T { return hit }
        for sub in view.subviews {
            if let hit = findFirst(type, in: sub) { return hit }
        }
        return nil
    }

    /// Counts WorkspaceRowItemView instances by class name (the type itself is private to
    /// WorkspaceListView.swift, so direct `as?` won't compile here).
    private func rowCount(in listView: WorkspaceListView) -> Int {
        var count = 0
        var queue: [NSView] = [listView]
        while let v = queue.first {
            queue.removeFirst()
            if String(describing: type(of: v)).contains("WorkspaceRowItemView") {
                count += 1
            }
            queue.append(contentsOf: v.subviews)
        }
        return count
    }

    // MARK: tests

    func testMakeProducesListViewWithCorrectRowCount() throws {
        let store = makeStore(workspaceCount: 2)
        let (_, listView) = try materialize(store)
        XCTAssertEqual(rowCount(in: listView), 2)
    }

    func testEmptyStoreYieldsZeroRows() throws {
        let store = makeStore(workspaceCount: 0)
        let (_, listView) = try materialize(store)
        XCTAssertEqual(rowCount(in: listView), 0)
    }

    func testRowCountReflectsStoreMutations() throws {
        let store = makeStore(workspaceCount: 1)
        let (host, listView) = try materialize(store)
        XCTAssertEqual(rowCount(in: listView), 1)

        store.createWorkspace(name: "second")
        host.layout()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(rowCount(in: listView), 2)

        if let first = store.workspaces.first {
            store.deleteWorkspace(id: first.id)
        }
        host.layout()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(rowCount(in: listView), 1)
    }
}
```

- [ ] **Step 2: Regen + run tests**

```bash
xcodegen generate && xcodebuild test -project TheAll.xcodeproj -scheme TheAllTests -only-testing:TheAllTests/SidebarListBridgeTests 2>&1 | tail -20
```

Expected: `Test Suite 'SidebarListBridgeTests' passed`

If `WorkspaceListView` is internal but tests can't see it because it's not `public`, the `@testable import TheAll` already covers internal access. No change needed.

- [ ] **Step 3: Commit**

```bash
git add TheAllTests/SidebarListBridgeTests.swift project.yml
git commit -m "test(sidebar): SidebarListBridge smoke tests for row count tracking"
```

---

## Task 14: Update CLAUDE.md

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: Update Key Conventions §4**

Find this line (under `## Key Conventions`):

```
4. **AppKit 视图用 NSView subclass，SwiftUI 侧边栏用 View struct** — 不在 Canvas 层用 SwiftUI，不在侧边栏用 NSView
```

Replace with:

```
4. **Canvas / TabBar / SidebarList 用 NSView subclass；SidebarView 外壳（header / footer / alert / 通知订阅 / 元数据 refresher 生命周期）用 SwiftUI View struct** — AppKit ↔ SwiftUI 边界统一在 `*Bridge: NSViewRepresentable`
```

- [ ] **Step 2: Update Common Tasks sidebar/Tab row**

Find this row in the Common Tasks table:

```
| 侧边栏/Tab 的 rename / delete / reorder 交互 | `Sidebar/SidebarView.swift`, `Sidebar/WorkspaceRowView.swift`, `TabContent/TabBarView.swift`, `TabContent/TabContentView.swift`, `Models/WorkspaceStore.swift` |
```

Replace with:

```
| 侧边栏/Tab 的 rename / delete / reorder 交互 | `Sidebar/SidebarView.swift`, `Sidebar/WorkspaceListView.swift`, `Bridge/SidebarListBridge.swift`, `TabContent/TabBarView.swift`, `TabContent/TabContentView.swift`, `Models/WorkspaceStore.swift` |
```

- [ ] **Step 3: Commit**

```bash
git add CLAUDE.md
git commit -m "docs(claude.md): update sidebar conventions for AppKit-based list"
```

---

## Task 15: Run all tests + manual regression checklist

- [ ] **Step 1: Run the full test suite**

```bash
xcodebuild test -project TheAll.xcodeproj -scheme TheAllTests 2>&1 | tail -30
```

Expected: all tests pass.

- [ ] **Step 2: Launch the app and walk the regression checklist**

```bash
xcodebuild -project TheAll.xcodeproj -scheme TheAll -configuration Debug build 2>&1 | tail -3
open ~/Library/Developer/Xcode/DerivedData/TheAll-*/Build/Products/Debug/TheAll.app
```

Manually verify each:

| # | Action | Expected |
|---|---|---|
| 1 | Hover row → move to next row → move out of sidebar | Hover bg follows cursor; never two highlighted simultaneously |
| 2 | Click row | Selection switches; selected bg = `borderStrong`, font becomes semibold |
| 3 | Right-click row → Rename → type new name → Enter | Title updates; row leaves rename mode |
| 4 | Right-click → Rename → type → click another row | First row commits rename; second row becomes selected |
| 5 | Right-click → Rename → type → press Esc | Reverts to original title |
| 6 | Right-click row → Delete → Confirm in alert | Workspace deleted; selection moves to neighbor |
| 7 | Right-click row → Delete → Cancel | Nothing changes |
| 8 | Press and hold a row, drag down 5+pt | Row dims to 0.35 alpha; other rows slide; cursor shows move arrow (no "+" badge) |
| 9 | Release on new position | Workspace order persists; row returns to alpha 1 |
| 10 | Drag a row out of sidebar then release | Order unchanged; preview restores; no stuck ghost |
| 11 | Click a row but don't move 4+pt | Click registers as select, no drag started |
| 12 | While dragging, hover sidebar's top/bottom edge | Sidebar autoscrolls if list exceeds viewport |
| 13 | Wait for git branch refresh (5s) on a workspace pointing at a git repo | Branch label appears in row second line without manual refresh |
| 14 | Cmd+N → type → Enter | New workspace appears |
| 15 | Cmd+N → type → Esc | No workspace created |

If any item fails, file an issue or fix in a follow-up commit; do **not** revert the implementation.

- [ ] **Step 3: Final commit (only if any minor fixes were made above)**

If you made any inline fixes during regression:

```bash
git add -A
git commit -m "fix(sidebar): post-regression touch-ups"
```

Otherwise, no commit.

---

## Self-Review Notes

- All spec sections covered: pasteboard type (Task 1), row visual states (Task 2), hover via NSTrackingArea (Task 3), click+menu (Task 4), inline rename (Task 5), drag source (Task 6), id-diff update (Task 7), drag destination + live preview + autoscroll (Task 8), bridge (Task 9), MetadataRefresher onRefresh (Task 10), SidebarView refactor (Task 11), file deletion (Task 12), bridge smoke test (Task 13), CLAUDE.md (Task 14), regression (Task 15).
- Type / method consistency verified: `WorkspaceListView.update(workspaces:selectedId:metadata:theme:)`, `WorkspaceRowItemView.refresh(workspace:isSelected:metadata:theme:)`, `onSelect/onRename/onReorder/onRequestDelete/onDragEnded` callback names stay identical from declaration through wiring.
- No "TBD"/"TODO"/"similar to". Each step has the actual code or command needed.
