import AppKit
import SwiftUI

enum TabMiddleClickClosePolicy {
    static func shouldClose(buttonNumber: Int, canClose: Bool) -> Bool {
        canClose && buttonNumber == 2
    }
}

/// NSView 子类，点击不触发窗口拖动。tab 栏上移进顶部标题栏拖拽区后，透明 NSView
/// 默认 `mouseDownCanMoveWindow=true`，点击会被 titlebar 拖窗行为吞掉而不触发选中。
private final class NonDraggableView: NSView {
    override var mouseDownCanMoveWindow: Bool { false }
}

/// 同理，承载 "+" 按钮的 NSHostingView 子类——让它在标题栏区内可点击而非拖窗。
private final class NonDraggableHostingView<Content: View>: NSHostingView<Content> {
    override var mouseDownCanMoveWindow: Bool { false }
}

/// NSClipView 子类，点击不拖窗——窗口拖拽区是「所有 mouseDownCanMoveWindow=true
/// 视图区域的并集」，pill 下方的 clip/scroll/container 视图若仍可拖，pill 所在区域
/// 照样落进拖拽区，于是点 tab 变成拖窗。整条链路都要置为不可拖。
private final class NonDraggableClipView: NSClipView {
    override var mouseDownCanMoveWindow: Bool { false }
}

/// NSScrollView 子类，点击不拖窗，并用 NonDraggableClipView 作为内容视图。
private final class NonDraggableScrollView: NSScrollView {
    override var mouseDownCanMoveWindow: Bool { false }
    override init(frame: NSRect) {
        super.init(frame: frame)
        contentView = NonDraggableClipView()
    }
    required init?(coder: NSCoder) { fatalError() }
}

/// NSImageView 子类，点击不拖窗——pill 上的图标也压在标题栏拖拽区里。
private final class NonDraggableImageView: NSImageView {
    override var mouseDownCanMoveWindow: Bool { false }
}

// MARK: - TabBarView

/// Horizontal tab strip. Notifies via callbacks; never touches the store directly.
final class TabBarView: NSView {
    var onSelectTab: ((UUID) -> Void)?
    var onAddTab: (() -> Void)?
    /// Invoked when a Quick Action item is chosen in the "+" dropdown. Carries
    /// the QuickActionId; TabContentView turns it into a new quick-action tab.
    var onAddQuickActionTab: ((QuickActionId) -> Void)?
    var onCloseTab: ((UUID) -> Void)?
    var onRenameTab: ((UUID, String) -> Void)?
    /// (fromIndex, toIndex) 采用 insertion-index 语义（0…count），
    /// 与 `WorkspaceStore.moveTab(fromIndex:toIndex:in:)` 对齐
    var onReorderTab: ((Int, Int) -> Void)?
    var onResetAutoTitle: ((UUID) -> Void)?
    /// 若 tab 总数 ≤ 1，TabItemView 禁用 × 按钮与菜单 Close 项
    private var canClose: Bool { tabs.count > 1 }

    /// strip 的固有高度——外层由 TabContentView 统一负责 4pt 内缩。
    /// 32：tab 栏上方留 4pt 间距（四边对称），pill 行中心 = cardInset(4)+上间距(4)+32/2 = 24。
    /// 注：标题栏 ~28pt 只能把交通灯压到中心 ~21，故交通灯会比 24 的 tab 行偏高 ~3pt——
    /// 这是「保留上间距 + 全高 32」必然的取舍（详见 ContentView.headerControlsTop）。
    static let height: CGFloat = 32
    /// 单位间距：同时用于 (1) pill 到 strip 顶/底 (2) tab 之间 (3) 首尾 tab 到 strip 左右
    static let pillInset: CGFloat = 3
    /// 同心圆角：外层 card 的半径减去 TabContentView 统一提供的内缩。
    static var stripRadius: CGFloat { DT.Radius.card - DT.Space.xs }
    /// 同心圆角：strip 半径减去 pill 到 strip 的内缩
    static var pillRadius: CGFloat { max(0, stripRadius - pillInset) }
    /// 单个 tab pill 的固定宽度。SettingsTabBarView 复用同一常数以保持视觉对齐。
    static let tabItemWidth: CGFloat = 140

    private var theme: AppTheme = .systemFallback(isDark: true)
    /// Mirror of ghostty `background-opacity`. Applied to tab pill fills so
    /// selected/hovered pills don't paint an opaque canvas slab when the rest
    /// of the window is transparent.
    private var backgroundOpacity: CGFloat = 1.0
    private var tabs: [TerminalTab] = []
    private var selectedTabId: UUID?
    private var statuses: [UUID: TerminalStatus] = [:]
    private var sessionTitles: [UUID: String] = [:]
    private var showStatusIndicators: Bool = false
    /// Source for tab pill icon rendering (Quick Action ids → SF Symbol /
    /// asset / letter). TabContentView wires this in via setter; TabItemView
    /// reads it through a weak ref so the view never outlives its container.
    weak var quickActionsStore: QuickActionsStore? {
        didSet {
            tabsContainer.subviews
                .compactMap { $0 as? TabItemView }
                .forEach { $0.quickActionsStore = quickActionsStore }
        }
    }
    /// Current locale forwarded from LanguageStore via TabContentView → TabBridge.
    /// Used to resolve LocalizedStringResource in makeAddButton() so the "+" tooltip
    /// tracks the user's in-app language choice rather than Locale.current.
    var locale: Locale = .current

    private let stripContainer = NonDraggableView()
    private let scrollView = NonDraggableScrollView()
    private let tabsContainer = NonDraggableView()
    private var addHost: NSHostingView<AnyView>!
    private static let addHostSize: CGFloat = 22

    /// 整条 tab 栏都不参与窗口拖拽（连同上面的容器/滚动视图链）——见各子类说明。
    override var mouseDownCanMoveWindow: Bool { false }

    // Drag preview 状态：让 tabs 在拖拽中实时重排到 "若此刻松手会变成的顺序"。
    /// 当前被拖的 tab id（由 pasteboard 在 draggingEntered 时读出）。
    private var draggingTabId: UUID?
    /// 当前鼠标对应的 insertion index（0…tabs.count）。
    private var previewInsertionIndex: Int?

    /// 标题栏拖窗锁。tab 栏落在顶部 ~28pt 标题栏拖拽区内，拖 tab 时窗口会被「拖标题栏移窗」
    /// 一起拖走（与 tab 同向运动 → tab 相对没动、拖不动）。根因：WindowServer 是独立进程，
    /// 在 mouseDown 那一刻按它**缓存的** window.isMovable 决定要不要拖窗——同一轮事件里再改
    /// isMovable 太晚（这正是 mouseDownCanMoveWindow / mouseDown 时关锁都无效的原因）。
    /// 对策：用覆盖整条 tab 栏的 tracking area，光标**一进入就**把 isMovable 关掉（早于按下，
    /// 让 WindowServer 缓存到 false），离开再复原。空白区拖窗不受影响。
    ///
    /// 复原必须对准**当初被锁的那个窗口实例**（`lockedWindow`），而非 `self.window`：detach /
    /// 全屏切换后 `self.window` 可能已是 nil 或换了窗口，靠它复原会把锁永久留在原窗口上。
    /// 除 mouseExited 外，detach / 脱离窗口 / Settings 覆盖（用键盘 ⌘, 打开时不产生 mouseExited）
    /// 都要显式调 `releaseTitlebarDragLock()`，否则窗口会卡在不可拖动。
    private var savedWindowIsMovable: Bool?
    private weak var lockedWindow: NSWindow?
    private var dragLockTrackingArea: NSTrackingArea?

    override init(frame: NSRect) {
        super.init(frame: frame)
        setup()
    }
    required init?(coder: NSCoder) { fatalError() }

    deinit { releaseTitlebarDragLock() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // 换窗口 / 脱离窗口：先复原老窗口的锁（用 lockedWindow，不是已变化的 self.window）。
        if window !== lockedWindow { releaseTitlebarDragLock() }
    }

    /// 悬停即锁：覆盖整条 tab 栏的 tracking area，光标一进入 / 在其上移动就把 window.isMovable
    /// 关掉（**早于**按下，让 WindowServer 在 mouseDown 那刻拿到的缓存就是 false——同一轮事件里
    /// 改太晚拦不住），离开再复原。`.mouseMoved` 让锁能在 Settings 关闭后、光标仍在条上时自愈。
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let ta = dragLockTrackingArea { removeTrackingArea(ta) }
        let ta = NSTrackingArea(rect: bounds,
                                options: [.activeAlways, .mouseEnteredAndExited, .mouseMoved, .inVisibleRect],
                                owner: self, userInfo: nil)
        addTrackingArea(ta)
        dragLockTrackingArea = ta
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        lockTitlebarDrag()
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        lockTitlebarDrag()
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        releaseTitlebarDragLock()
    }

    /// 锁住当前窗口的 isMovable（幂等，记下被锁实例与原值）。
    private func lockTitlebarDrag() {
        guard savedWindowIsMovable == nil, let window = window else { return }
        savedWindowIsMovable = window.isMovable
        lockedWindow = window
        window.isMovable = false
    }

    /// 复原临时关掉的 window.isMovable（幂等）。对准当初被锁的窗口实例，而非 self.window。
    /// 离开 tab 栏 / detach / 脱离窗口 / Settings 覆盖 tab 内容时都要调用。
    func releaseTitlebarDragLock() {
        if let saved = savedWindowIsMovable {
            lockedWindow?.isMovable = saved
        }
        savedWindowIsMovable = nil
        lockedWindow = nil
    }

    private func setup() {
        wantsLayer = true

        stripContainer.wantsLayer = true
        stripContainer.layer?.masksToBounds = true
        addSubview(stripContainer)

        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.drawsBackground = false
        scrollView.documentView = tabsContainer
        scrollView.autoresizingMask = []
        stripContainer.addSubview(scrollView)

        addHost = NonDraggableHostingView(rootView: makeAddButton())
        addSubview(addHost)
        registerForDraggedTypes([.theAllTab])
    }

    override func layout() {
        super.layout()
        let hPad = Self.pillInset
        let addW: CGFloat = 28
        // 圆角条只盖 pill 区，"+" 留在条外侧（右 addW 内），与之前一致。
        let stripW = max(0, bounds.width - addW)
        stripContainer.frame = NSRect(x: 0, y: 0, width: stripW, height: bounds.height)
        stripContainer.layer?.cornerRadius = Self.stripRadius
        scrollView.frame = NSRect(x: hPad, y: 0,
                                  width: max(0, stripW - hPad * 2), height: bounds.height)
        let hostSize = Self.addHostSize
        addHost.frame = NSRect(
            x: bounds.width - addW + (addW - hostSize) / 2,
            y: (bounds.height - hostSize) / 2,
            width: hostSize, height: hostSize)
        layoutTabItems()
    }

    func update(tabs: [TerminalTab],
                selectedTabId: UUID?,
                theme: AppTheme,
                statuses: [UUID: TerminalStatus] = [:],
                sessionTitles: [UUID: String] = [:],
                backgroundOpacity: CGFloat = 1.0,
                showStatusIndicators: Bool = false) {
        self.tabs = tabs
        self.selectedTabId = selectedTabId
        self.theme = theme
        self.statuses = statuses
        self.sessionTitles = sessionTitles
        self.backgroundOpacity = backgroundOpacity
        self.showStatusIndicators = showStatusIndicators
        rebuildTabItems()   // tab items are already initialised with correct theme
        applyTheme(theme, backgroundOpacity: backgroundOpacity)   // re-apply theme to non-tab elements (layer bg, addButton tint)
    }

    /// Display title with same 3-step priority as `TerminalTab.displayTitle(store:)`,
    /// but reads from the snapshot dictionary we receive in `update`. Kept inline
    /// so the AppKit view doesn't need to hold a store reference.
    private func displayTitle(for tab: TerminalTab) -> String {
        if tab.userRenamed { return tab.title }
        if let auto = sessionTitles[tab.focusedTerminalId], !auto.isEmpty {
            return auto
        }
        return tab.title
    }

    /// 复用现有 TabItemView——仅在 tabs 的 id 序列变化时才完整重建。
    /// 这一点对拖拽和 rename 都关键：若 mouseDown → onSelect → reloadFromStore →
    /// rebuildTabItems 销毁了刚收到 mouseDown 的 view，后续 mouseDragged 永远收不到；
    /// 同样，inline rename 中任何 reload 都会毁掉 NSTextField。改为 id-diff 后：
    ///   · 只是 selection 切换 → 所有 view 保留，只刷 isSelected 样式
    ///   · tabs 真正增删或重排 → 整体重建（用户不会在此时拖或 rename，安全）
    private func rebuildTabItems() {
        let existing = tabsContainer.subviews.compactMap { $0 as? TabItemView }
        let existingIds = existing.map(\.tabId)
        let targetIds = tabs.map(\.id)
        let canCloseNow = canClose

        if existingIds == targetIds {
            // 仅 selection / title / canClose 可能变化——原地刷新，保留 view 实例（拖拽与 rename 继续可用）
            for item in existing {
                let isSel = item.tabId == selectedTabId
                if let tab = tabs.first(where: { $0.id == item.tabId }) {
                    let tabStatus = TerminalStatus.aggregate(
                        tab.layout.allTerminalIds().map { statuses[$0] ?? .neverRan }
                    )
                    item.refresh(tab: tab, isSelected: isSel, theme: theme, canClose: canCloseNow,
                                 status: tabStatus, backgroundOpacity: backgroundOpacity,
                                 showStatusIndicators: showStatusIndicators,
                                 displayTitle: displayTitle(for: tab))
                }
            }
            updateSeparators()
            return
        }

        // 结构变化：完整重建
        existing.forEach { $0.removeFromSuperview() }
        for tab in tabs {
            let tabStatus = TerminalStatus.aggregate(
                tab.layout.allTerminalIds().map { statuses[$0] ?? .neverRan }
            )
            let item = TabItemView(tab: tab, isSelected: tab.id == selectedTabId, theme: theme,
                                   status: tabStatus, backgroundOpacity: backgroundOpacity,
                                   showStatusIndicators: showStatusIndicators,
                                   quickActionsStore: quickActionsStore,
                                   displayTitle: displayTitle(for: tab))
            item.canClose = canCloseNow
            item.onSelect = { [weak self] in self?.onSelectTab?(tab.id) }
            item.onClose  = { [weak self] in self?.onCloseTab?(tab.id) }
            item.onRename = { [weak self] newTitle in self?.onRenameTab?(tab.id, newTitle) }
            item.onResetAutoTitle = { [weak self] in self?.onResetAutoTitle?(tab.id) }
            // drop 失败（拖到 TabBarView 外）时，source 端 sessionEnded 会触发——清理 preview state
            item.onDragEnded = { [weak self] in self?.cleanupAfterDrag() }
            // hover 变化时重算相邻分割线可见性（浏览器 tab 行为）
            item.onHoverChanged = { [weak self] in self?.updateSeparators() }
            tabsContainer.addSubview(item)
        }
        layoutTabItems()
    }

    /// 默认按 self.tabs 顺序排布。拖拽中 draggingTabId/previewInsertionIndex 有值时，
    /// 按 "如果此刻松手的结果" 顺序排布——被拖 item 仍占位但视觉淡化，其他 item 平移。
    private func layoutTabItems(animated: Bool = false) {
        let items = tabsContainer.subviews.compactMap { $0 as? TabItemView }
        let ordered = previewOrdered(items: items)
        let tabW = Self.tabItemWidth
        let gap = Self.pillInset
        let h = stripContainer.bounds.height

        let apply = {
            var x: CGFloat = 0
            for (i, item) in ordered.enumerated() {
                let frame = NSRect(x: x, y: 0, width: tabW, height: h)
                if animated {
                    item.animator().frame = frame
                } else {
                    item.frame = frame
                }
                x += tabW + (i == ordered.count - 1 ? 0 : gap)
                item.isDragGhost = (item.tabId == self.draggingTabId)
            }
            self.tabsContainer.frame = NSRect(
                x: 0, y: 0,
                width: max(x, self.scrollView.frame.width),
                height: h)
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
        updateSeparators()
    }

    /// 重算每个 tab 右侧分割线的可见性（浏览器 tab 行为）。规则：仅当本 tab 与其右邻
    /// 都未选中、未 hover，且当前没有拖拽进行时，才显示二者之间的分割线；最后一个 tab
    /// 右侧紧邻 strip 边缘/"+"，不画线。
    private func updateSeparators() {
        let items = tabsContainer.subviews.compactMap { $0 as? TabItemView }
        guard !items.isEmpty else { return }
        let ordered = previewOrdered(items: items)
        let dragging = draggingTabId != nil
        for (i, item) in ordered.enumerated() {
            let next: TabItemView? = (i + 1 < ordered.count) ? ordered[i + 1] : nil
            let show = !dragging
                && next != nil
                && !item.isSelectedTab && !item.isHoveredState
                && !(next?.isSelectedTab ?? true) && !(next?.isHoveredState ?? true)
            item.showsRightSeparator = show
        }
    }

    /// 返回应当显示的 tab 顺序（考虑 drag preview）。
    private func previewOrdered(items: [TabItemView]) -> [TabItemView] {
        guard let draggingTabId,
              let insertion = previewInsertionIndex,
              let fromIdx = items.firstIndex(where: { $0.tabId == draggingTabId })
        else { return items }

        var copy = items
        let picked = copy.remove(at: fromIdx)
        // insertion 用 "before index" 语义（0…items.count，含被拖项时的原索引）；
        // 移除被拖项后需要把 > fromIdx 的 insertion 左移一位。
        let dest = insertion > fromIdx ? insertion - 1 : insertion
        copy.insert(picked, at: max(0, min(copy.count, dest)))
        return copy
    }

    func applyTheme(_ theme: AppTheme, backgroundOpacity: CGFloat = 1.0) {
        self.theme = theme
        self.backgroundOpacity = backgroundOpacity
        // The bar itself is an invisible host for the rounded strip + "+" button;
        // painting it with canvas paints a visible rectangle around the strip once
        // the window becomes transparent.
        layer?.backgroundColor = .clear
        stripContainer.layer?.backgroundColor = theme.sidebar.withAlphaComponent(backgroundOpacity).cgColor
        addHost?.rootView = makeAddButton()
        tabsContainer.subviews
            .compactMap { $0 as? TabItemView }
            .forEach { $0.applyTheme(theme, backgroundOpacity: backgroundOpacity) }
        needsDisplay = true
    }

    /// Called from TabContentView when LanguageStore.tick propagates.
    /// Tab pill labels render user-given `tab.title`, the "+" button is rebuilt via
    /// `applyTheme` → `makeAddButton()` which is already called on every `update()`
    /// (triggered by updateNSView → loadWorkspace), and the right-click NSMenu is
    /// rebuilt on each click — so there are no persistent static labels to refresh
    /// here. Method exists as a stable hook; keep it even when empty.
    func refreshLocalizedStrings() {
        // Intentionally empty — see docstring.
    }

    private func makeAddButton() -> AnyView {
        let currentTheme = theme
        let currentLocale = locale
        return AnyView(
            IconButton(theme: currentTheme, help: String(localized: L10n.Tab.newTabTooltip.withLocale(currentLocale)), action: { [weak self] in
                self?.showAddMenu()
            }) {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundColor(Color(currentTheme.textSecondary))
            }
            .environment(\.locale, currentLocale)
        )
    }

    // MARK: - Add menu ("+")

    private static let menuIconSize: CGFloat = 14

    /// Build and pop up the "+" dropdown: "Terminal" (plain new tab) followed
    /// by the enabled Quick Actions. Anchored on the current click event so it
    /// drops from the "+" button, matching the tab right-click menu mechanism.
    private func showAddMenu() {
        let menu = buildAddMenu()
        if let event = NSApp.currentEvent {
            NSMenu.popUpContextMenu(menu, with: event, for: addHost)
        } else {
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: -DT.Space.xs), in: addHost)
        }
    }

    private func buildAddMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let termItem = NSMenuItem(
            title: L10n.string("ai.newTerminal"),
            action: #selector(addTerminalMenuTapped), keyEquivalent: "")
        termItem.target = self
        let termImage = NSImage(systemSymbolName: "terminal", accessibilityDescription: nil)
        termImage?.size = NSSize(width: Self.menuIconSize, height: Self.menuIconSize)
        termItem.image = termImage
        menu.addItem(termItem)

        return menu
    }

    @objc private func addTerminalMenuTapped() { onAddTab?() }

    @objc private func quickActionMenuTapped(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? QuickActionId else { return }
        onAddQuickActionTab?(id)
    }

    /// NSImage for a Quick Action menu item — mirrors the tab-pill icon sources
    /// (SF Symbol / asset / letter) at menu icon size. Template images tint with
    /// the menu text color automatically.
    private func menuIcon(for id: QuickActionId) -> NSImage? {
        guard let source = quickActionsStore?.iconSource(for: id) else { return nil }
        let s = Self.menuIconSize
        switch source {
        case .sfSymbol(let name):
            let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)
            img?.size = NSSize(width: s, height: s)
            return img
        case .asset(let name):
            guard let raw = NSImage(named: name) else { return nil }
            let img = NSImage(size: NSSize(width: s, height: s))
            img.lockFocus()
            raw.draw(in: NSRect(x: 0, y: 0, width: s, height: s))
            img.unlockFocus()
            img.isTemplate = raw.isTemplate
            return img
        case .letter(let c):
            return Self.letterMenuImage(String(c), size: s)
        }
    }

    /// Letter glyph for custom Quick Actions without an icon. Matches the tab
    /// pill's rounded-semibold letter, minus the circle outline (clutter at
    /// menu size). Template so it tints with the menu text color.
    private static func letterMenuImage(_ string: String, size: CGFloat) -> NSImage {
        let canvas = NSSize(width: size, height: size)
        let image = NSImage(size: canvas)
        image.lockFocus()
        let baseFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
        let font: NSFont = {
            if let desc = baseFont.fontDescriptor.withDesign(.rounded),
               let rounded = NSFont(descriptor: desc, size: 11) { return rounded }
            return baseFont
        }()
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: style,
        ]
        let attr = NSAttributedString(string: string, attributes: attrs)
        let ts = attr.size()
        attr.draw(in: NSRect(x: 0, y: (canvas.height - ts.height) / 2,
                             width: canvas.width, height: ts.height))
        image.unlockFocus()
        image.isTemplate = true
        return image
    }

    // MARK: - Drag & drop

    /// 根据鼠标横坐标计算应插入的位置（0…tabs.count）。拖拽中用 self.tabs 的
    /// 原始顺序判定——preview 重排的是视图 frame，模型层 insertion 语义不变。
    private func insertionIndex(at pointInSelf: NSPoint) -> Int {
        guard !tabs.isEmpty else { return 0 }
        // 把 x 转换到 tabsContainer 坐标系
        let pointInContainer = tabsContainer.convert(pointInSelf, from: self)
        // 基于原始 tabs 顺序下每个 slot 的中线（无 preview 时的位置）
        let tabW: CGFloat = 140
        let gap = Self.pillInset
        for i in 0..<tabs.count {
            let midX = CGFloat(i) * (tabW + gap) + tabW / 2
            if pointInContainer.x < midX { return i }
        }
        return tabs.count
    }

    /// 清除 preview 状态并原地恢复布局（无动画，避免 rebuild 前的闪烁）。
    fileprivate func cleanupAfterDrag() {
        // 注意：window.isMovable 的复原交给 mouseExited（悬停生命周期），这里不碰——
        // 拖拽结束时光标可能仍在 tab 栏上，过早复原会让紧接着的下一次拖拽又锁不住。
        guard draggingTabId != nil || previewInsertionIndex != nil else { return }
        draggingTabId = nil
        previewInsertionIndex = nil
        layoutTabItems(animated: true)
    }

    // MARK: - NSDraggingDestination

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        // 把被拖的 tabId 记下来，配合 draggingUpdated 驱动 live preview
        if let idString = sender.draggingPasteboard.string(forType: .theAllTab),
           let uuid = UUID(uuidString: idString) {
            draggingTabId = uuid
        }
        return draggingUpdated(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard sender.draggingPasteboard.types?.contains(.theAllTab) == true else {
            return []
        }
        let pointInSelf = convert(sender.draggingLocation, from: nil)
        let idx = insertionIndex(at: pointInSelf)
        if idx != previewInsertionIndex {
            previewInsertionIndex = idx
            layoutTabItems(animated: true)
        }
        return .move
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        // 鼠标暂时离开 TabBarView，撤销 preview 但保留 draggingTabId（可能还会回来）
        if previewInsertionIndex != nil {
            previewInsertionIndex = nil
            layoutTabItems(animated: true)
        }
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let idString = sender.draggingPasteboard.string(forType: .theAllTab),
              let tabId = UUID(uuidString: idString),
              let fromIndex = tabs.firstIndex(where: { $0.id == tabId })
        else {
            cleanupAfterDrag()
            return false
        }
        let pointInSelf = convert(sender.draggingLocation, from: nil)
        let toIndex = insertionIndex(at: pointInSelf)
        // 保留 preview 状态到下一次 rebuildTabItems（store 更新 → rebuildTabItems 用新顺序布局）
        // 之后 cleanupAfterDrag 兜底清除任何残留。
        onReorderTab?(fromIndex, toIndex)
        cleanupAfterDrag()
        return true
    }

}

// MARK: - TabItemView

private final class TabItemView: NSView, NSTextFieldDelegate, NSDraggingSource {
    let tabId: UUID
    var onSelect: (() -> Void)?
    var onClose:  (() -> Void)?
    var onRename: ((String) -> Void)?
    var onResetAutoTitle: (() -> Void)?
    /// 在 drag session 结束时（无论是否成功 drop）调用——用来让 TabBarView 清除 preview 状态。
    var onDragEnded: (() -> Void)?
    /// hover 进/出时调用——让 TabBarView 重新评估相邻分割线的可见性（浏览器 tab 行为：
    /// 被 hover / 选中的 tab 两侧分割线隐藏）。
    var onHoverChanged: (() -> Void)?
    var canClose: Bool = true
    private var userRenamed: Bool = false

    /// 暴露给 TabBarView.updateSeparators 读取（分割线可见性取决于自身与右邻的选中 / hover 态）。
    fileprivate var isSelectedTab: Bool { isSelected }
    fileprivate var isHoveredState: Bool { isHovered }

    /// 右侧 gap 中央的竖直分割线（类似浏览器 tab）。可见性由 TabBarView 统一控制。
    private let separatorLayer = CALayer()
    var showsRightSeparator: Bool = false {
        didSet {
            guard oldValue != showsRightSeparator else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            separatorLayer.isHidden = !showsRightSeparator
            CATransaction.commit()
        }
    }

    /// 拖拽 preview 中被拖 item 的 "占位" 显示——淡化 alpha 暗示它会被移走。
    var isDragGhost: Bool = false {
        didSet {
            guard oldValue != isDragGhost else { return }
            alphaValue = isDragGhost ? 0.35 : 1
        }
    }

    private let pillView   = NonDraggableView()
    private let kindIcon   = NonDraggableImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let renameField = NSTextField()
    private let statusIcon = TerminalStatusIconView(frame: .zero)

    /// 当前显示的 quick action id —— 用来在 refresh() 时判断是否需要换 image。
    private var displayedQuickActionId: String?
    private var originalTitle: String = ""
    private var isRenaming: Bool = false
    private var isSelected: Bool
    private var isHovered  = false
    private var theme: AppTheme
    /// See TabBarView.backgroundOpacity — the pill fill uses alpha so it doesn't
    /// over-paint the translucent tab strip below.
    private var backgroundOpacity: CGFloat
    private var status: TerminalStatus
    fileprivate var showStatusIndicators: Bool = false
    /// Look up icon source for the current tab's `quickActionId`. Setter
    /// re-renders the icon image so changes to enabled/custom actions in
    /// Settings propagate without rebuilding the whole TabItemView.
    weak var quickActionsStore: QuickActionsStore? {
        didSet { applyQuickActionImage(displayedQuickActionId) }
    }

    init(tab: TerminalTab, isSelected: Bool, theme: AppTheme, status: TerminalStatus = .neverRan,
         backgroundOpacity: CGFloat = 1.0, showStatusIndicators: Bool = false,
         quickActionsStore: QuickActionsStore? = nil, displayTitle: String) {
        self.tabId = tab.id
        self.isSelected = isSelected
        self.theme = theme
        self.backgroundOpacity = backgroundOpacity
        self.status = status
        self.displayedQuickActionId = tab.quickActionId
        self.quickActionsStore = quickActionsStore
        super.init(frame: .zero)
        self.showStatusIndicators = showStatusIndicators
        self.userRenamed = tab.userRenamed
        titleLabel.stringValue = displayTitle
        setup()
        applyToolTip(displayTitle)
        applyQuickActionImage(tab.quickActionId)
        updateStyle()
        statusIcon.isHidden = !showStatusIndicators
        statusIcon.update(status: status, theme: theme)
    }
    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        wantsLayer = true

        // 分割线挂在 view 自身 layer 上（而非 pillView，pillView masksToBounds 会裁掉
        // 落在右侧 gap 中的线）。默认隐藏，由 TabBarView.updateSeparators 控制可见性。
        separatorLayer.isHidden = true
        layer?.addSublayer(separatorLayer)

        pillView.wantsLayer = true
        pillView.layer?.masksToBounds = true
        addSubview(pillView)

        kindIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        kindIcon.imageScaling = .scaleProportionallyUpOrDown
        addSubview(kindIcon)

        addSubview(statusIcon)

        titleLabel.isBezeled = false
        titleLabel.drawsBackground = false
        titleLabel.isEditable = false
        titleLabel.isSelectable = false
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.font = DT.Font.small
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(titleLabel)

        renameField.isBezeled = false
        renameField.drawsBackground = false
        renameField.isEditable = true
        renameField.isSelectable = true
        renameField.font = DT.Font.small
        renameField.focusRingType = .none
        renameField.delegate = self
        renameField.isHidden = true
        addSubview(renameField)
    }

    /// AppKit tooltips don't bubble from child to parent — the tooltip shown is the
    /// one owned by the topmost view under the cursor. Mirror the full title onto every
    /// subview that covers the pill so hovering anywhere on the tab reveals the title.
    private func applyToolTip(_ title: String) {
        self.toolTip = title
        pillView.toolTip = title
        titleLabel.toolTip = title
        kindIcon.toolTip = title
        statusIcon.toolTip = title
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect],
            owner: self))
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        let vInset = TabBarView.pillInset
        let pillH = h - vInset * 2
        pillView.frame = NSRect(x: 0, y: vInset, width: bounds.width, height: pillH)
        pillView.layer?.cornerRadius = TabBarView.pillRadius

        // 分割线落在本 tab 右边缘外侧的 gap 中央，高度取 pill 的一半并垂直居中。
        let sepW: CGFloat = 1
        let sepH = (pillH * 0.5).rounded()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        separatorLayer.frame = NSRect(
            x: bounds.width + (TabBarView.pillInset - sepW) / 2,
            y: (h - sepH) / 2,
            width: sepW, height: sepH)
        CATransaction.commit()

        let margin: CGFloat = 10
        let trailingIconSize: CGFloat = showStatusIndicators ? TerminalStatusIconView.size : 0
        let trailingGap: CGFloat = showStatusIndicators ? 6 : 0
        if showStatusIndicators {
            statusIcon.frame = NSRect(
                x: bounds.width - margin - trailingIconSize, y: (h - trailingIconSize) / 2,
                width: trailingIconSize, height: trailingIconSize)
        }

        // Leading kind icon: 13pt SF Symbol, fixed gap to title.
        let leadingIconSize: CGFloat = 13
        let leadingGap: CGFloat = 6
        kindIcon.frame = NSRect(
            x: margin, y: (h - leadingIconSize) / 2,
            width: leadingIconSize, height: leadingIconSize)

        let textH = ceil(titleLabel.intrinsicContentSize.height)
        let textX = margin + leadingIconSize + leadingGap
        let textFrame = NSRect(
            x: textX, y: (h - textH) / 2,
            width: bounds.width - margin - trailingIconSize - trailingGap - textX,
            height: textH)
        titleLabel.frame = textFrame
        renameField.frame = textFrame
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// 顶部标题栏拖拽区内，点击不拖窗——让 mouseDown 真正落到选中/拖拽逻辑上。
    override var mouseDownCanMoveWindow: Bool { false }

    /// 非重命名态：pill 内任意点击都归 TabItemView 自己处理（选中 / 拖拽重排），
    /// 避免命中透明子视图（pillView / titleLabel / kindIcon）后落到 titlebar 拖窗区。
    /// 重命名态放行，让 renameField 正常接管编辑点击。
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isRenaming else { return super.hitTest(point) }
        return super.hitTest(point) != nil ? self : nil
    }

    override func resetCursorRects() {
        // Rename 模式下让 NSTextField 用默认 I-beam 光标
        guard !isRenaming else { return }
        addCursorRect(bounds, cursor: .pointingHand)
    }

    // MARK: - Rename

    @objc private func beginRenameAction() {
        originalTitle = titleLabel.stringValue
        renameField.stringValue = originalTitle
        titleLabel.isHidden = true
        renameField.isHidden = false
        isRenaming = true
        window?.makeFirstResponder(renameField)
        renameField.currentEditor()?.selectAll(nil)
        window?.invalidateCursorRects(for: self)
    }

    private func finishRenameUI() {
        renameField.isHidden = true
        titleLabel.isHidden = false
        isRenaming = false
        window?.invalidateCursorRects(for: self)
    }

    private func commitRename() {
        guard isRenaming else { return }
        let newTitle = renameField.stringValue
        finishRenameUI()
        onRename?(newTitle)
    }

    private func cancelRename() {
        guard isRenaming else { return }
        // 恢复原始显示，不触发回调
        renameField.stringValue = originalTitle
        finishRenameUI()
    }

    // NSTextFieldDelegate —— 回车 / 失焦均触发 commit
    func control(_ control: NSControl, textView: NSTextView,
                 doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            cancelRename()
            return true
        }
        return false
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        // 回车 / 失焦都走这里；Esc 的情况已经在 doCommandBy 里被处理并提前 finish 了
        commitRename()
    }

    func applyTheme(_ theme: AppTheme, backgroundOpacity: CGFloat = 1.0) {
        self.theme = theme
        self.backgroundOpacity = backgroundOpacity
        updateStyle()
        statusIcon.update(status: status, theme: theme)
    }

    /// 原地刷新——保留 view 实例、所有 responder 状态（拖拽 mouseDown/mouseDragged 链、
    /// inline rename 的 NSTextField first responder）。只更新显示字段。
    func refresh(tab: TerminalTab, isSelected: Bool, theme: AppTheme,
                 canClose: Bool, status: TerminalStatus = .neverRan,
                 backgroundOpacity: CGFloat = 1.0,
                 showStatusIndicators: Bool = false,
                 displayTitle: String) {
        self.theme = theme
        self.backgroundOpacity = backgroundOpacity
        self.isSelected = isSelected
        self.canClose = canClose
        self.status = status
        self.userRenamed = tab.userRenamed
        if titleLabel.stringValue != displayTitle && !isRenaming {
            titleLabel.stringValue = displayTitle
        }
        applyToolTip(displayTitle)
        if displayedQuickActionId != tab.quickActionId {
            displayedQuickActionId = tab.quickActionId
            applyQuickActionImage(tab.quickActionId)
        }
        self.showStatusIndicators = showStatusIndicators
        statusIcon.isHidden = !showStatusIndicators
        statusIcon.update(status: status, theme: theme)
        updateStyle()
        needsLayout = true
    }

    private func applyQuickActionImage(_ id: String?) {
        guard let id = id else {
            kindIcon.image = NSImage(systemSymbolName: "terminal", accessibilityDescription: nil)
            return
        }
        let source = quickActionsStore?.iconSource(for: id) ?? .sfSymbol("terminal")
        switch source {
        case .sfSymbol(let name):
            kindIcon.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        case .asset(let name):
            // Pad raw asset to 13×13 with 10×10 inner content so PNG/PDF assets
            // render at the same visible ink size as a 13pt SF Symbol (which has
            // ~25% optical padding inside its 13pt box). Without padding the asset
            // fills 13×13 edge-to-edge and looks ~30% larger than neighbouring SF
            // Symbol icons.
            kindIcon.image = NSImage(named: name).map { padAssetImage($0) }
        case .letter(let c):
            kindIcon.image = makeLetterImage(String(c))
        }
    }

    /// Wrap `raw` in a 13×13 canvas with 12×12 inner content centered (0.5pt
    /// inset on every side) — leaves just enough optical breathing room so the
    /// asset doesn't bleed into the title gap, while keeping the visible ink
    /// roughly aligned with the medium-weight SF Symbol glyphs in the same row.
    /// Forwarding `isTemplate` keeps the `kindIcon.contentTintColor` recoloring
    /// path working.
    private func padAssetImage(_ raw: NSImage) -> NSImage {
        let canvas = NSSize(width: 13, height: 13)
        let inner: CGFloat = 12
        let inset = (canvas.width - inner) / 2
        let image = NSImage(size: canvas)
        image.lockFocus()
        raw.draw(in: NSRect(x: inset, y: inset, width: inner, height: inner))
        image.unlockFocus()
        image.isTemplate = raw.isTemplate
        return image
    }

    /// Render a single character as a 13×13 NSImage with a 1pt circle outline,
    /// used for custom quick action tab pills. Mirrors the SwiftUI `.letter`
    /// branch in `QuickActionIconView` so the tab pill, top-bar bar, and
    /// settings row all show the same letter-in-circle glyph at the same
    /// visual size. 11pt rounded semibold matches SF Symbol cap-height roughly,
    /// the 0.4-alpha circle stroke keeps the outline visually subordinate to
    /// the letter while staying tinted via `isTemplate = true`.
    private func makeLetterImage(_ s: String) -> NSImage {
        let size = NSSize(width: 13, height: 13)
        let image = NSImage(size: size)
        image.lockFocus()

        // Letter — 11pt rounded semibold, centered.
        let baseFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
        let letterFont: NSFont = {
            if let desc = baseFont.fontDescriptor.withDesign(.rounded),
               let rounded = NSFont(descriptor: desc, size: 11) {
                return rounded
            }
            return baseFont
        }()
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [
            .font: letterFont,
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: style,
        ]
        let attr = NSAttributedString(string: s, attributes: attrs)
        let textSize = attr.size()
        let textRect = NSRect(x: 0, y: (size.height - textSize.height) / 2,
                              width: size.width, height: textSize.height)
        attr.draw(in: textRect)

        // Circle outline at 40% alpha — preserved by template tinting.
        let circleInset: CGFloat = 0.5
        let circleRect = NSRect(x: circleInset, y: circleInset,
                                width: size.width - 2 * circleInset,
                                height: size.height - 2 * circleInset)
        let path = NSBezierPath(ovalIn: circleRect)
        path.lineWidth = 1
        NSColor.labelColor.withAlphaComponent(0.4).setStroke()
        path.stroke()

        image.unlockFocus()
        image.isTemplate = true
        return image
    }

    private func updateStyle() {
        if isSelected {
            pillView.layer?.backgroundColor = theme.canvas.withAlphaComponent(backgroundOpacity).cgColor
            titleLabel.textColor = theme.textPrimary
        } else if isHovered {
            pillView.layer?.backgroundColor = theme.canvas.withAlphaComponent(0.5 * backgroundOpacity).cgColor
            titleLabel.textColor = theme.textSecondary
        } else {
            pillView.layer?.backgroundColor = .clear
            titleLabel.textColor = theme.textSecondary
        }
        kindIcon.contentTintColor = titleLabel.textColor
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        separatorLayer.backgroundColor = theme.border.cgColor
        CATransaction.commit()
        needsDisplay = true
    }


    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        updateStyle()
        onHoverChanged?()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        updateStyle()
        onHoverChanged?()
    }

    private var mouseDownLocation: NSPoint = .zero

    override func mouseDown(with event: NSEvent) {
        mouseDownLocation = event.locationInWindow
        onSelect?()
    }

    override func otherMouseDown(with event: NSEvent) {
        guard TabMiddleClickClosePolicy.shouldClose(
            buttonNumber: event.buttonNumber,
            canClose: canClose
        ) else { return }
        onClose?()
    }

    override func mouseDragged(with event: NSEvent) {
        // Rename 中不启动拖拽
        if isRenaming { return }
        let dx = event.locationInWindow.x - mouseDownLocation.x
        let dy = event.locationInWindow.y - mouseDownLocation.y
        guard (dx * dx + dy * dy) > 16 else { return }  // 4pt 阈值

        let pbItem = NSPasteboardItem()
        pbItem.setString(tabId.uuidString, forType: .theAllTab)

        let (ghost, frame) = snapshotForDragging()
        let draggingItem = NSDraggingItem(pasteboardWriter: pbItem)
        draggingItem.setDraggingFrame(frame, contents: ghost)

        beginDraggingSession(with: [draggingItem], event: event, source: self)
    }

    private func snapshotForDragging() -> (image: NSImage, frame: NSRect) {
        // 抓 pillView 区域而非整个 bounds —— TabItemView.bounds 比 pillView 多了
        // 上下各 pillInset(=3pt) 的留白，当作 ghost 内容会让 compose 用 pillRadius
        // 裁出来的圆角矩形顶部 / 底部各多 3pt 透明带，视觉上像内容被挤在中间。
        // 截 pillView 的 frame 同时保留所有 sibling 子视图（kindIcon / titleLabel /
        // statusIcon）—— cacheDisplay 会把所有与该 rect 相交的子视图一并渲染。
        let pillFrame = pillView.frame
        guard let rep = bitmapImageRepForCachingDisplay(in: pillFrame) else {
            return (NSImage(), pillFrame)
        }
        cacheDisplay(in: pillFrame, to: rep)
        let raw = NSImage(size: pillFrame.size)
        raw.addRepresentation(rep)
        return DraggedSnapshotShadow.compose(content: raw,
                                             contentSize: pillFrame.size,
                                             cornerRadius: TabBarView.pillRadius)
    }

    // NSDraggingSource
    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        return .move
    }


    /// 松手后（drop 成功与否都触发）通知 TabBarView 清 preview state。
    /// 成功 drop 时 performDragOperation 已清理过；这里是失败路径兜底。
    func draggingSession(_ session: NSDraggingSession,
                         endedAt screenPoint: NSPoint,
                         operation: NSDragOperation) {
        onDragEnded?()
    }

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        // autoenablesItems=true 会根据 target/action 把 isEnabled=false 覆盖回 true；
        // 这里希望 "最后一个 tab 时 Close 真的 disabled"，所以关闭自动启用。
        menu.autoenablesItems = false

        let renameItem = NSMenuItem(title: L10n.string("tab.row.rename"),
                                    action: #selector(beginRenameAction),
                                    keyEquivalent: "")
        renameItem.target = self
        menu.addItem(renameItem)

        // Reset belongs visually next to Rename — it's the undo for it.
        if userRenamed {
            let resetItem = NSMenuItem(title: L10n.string("tab.row.resetAutoTitle"),
                                       action: #selector(resetAutoTitleTapped),
                                       keyEquivalent: "")
            resetItem.target = self
            menu.addItem(resetItem)
        }

        menu.addItem(.separator())

        let closeItem = NSMenuItem(title: L10n.string("tab.row.close"),
                                   action: #selector(closeTapped),
                                   keyEquivalent: "")
        closeItem.target = self
        closeItem.isEnabled = canClose
        menu.addItem(closeItem)

        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func closeTapped() { onClose?() }
    @objc private func resetAutoTitleTapped() { onResetAutoTitle?() }
}
