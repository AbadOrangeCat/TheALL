import AppKit

enum TabCloseConfirmationPolicy {
    static func needsConfirmation(setting rawSetting: String?,
                                  statuses: [TerminalStatus],
                                  surfaceNeedsConfirmation: Bool = false) -> Bool {
        let setting = rawSetting?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        switch setting {
        case "false":
            return false
        case "always":
            return true
        default:
            return surfaceNeedsConfirmation || statuses.contains { status in
                switch status {
                case .running, .needsInput:
                    return true
                case .neverRan, .idle, .success, .failed:
                    return false
                }
            }
        }
    }
}

/// Top-level content view that combines the tab bar and the active tab's split pane.
///
/// ## Caching strategy
///
/// The whole point of this view is to make terminals *survive* workspace/tab switches
/// and divider drags. Naive rebuild-on-every-update destroys the SplitPaneView tree,
/// re-parents every GhosttyTerminalView, which in turn briefly resizes each ghostty
/// surface to 0×0 — and that's enough to leave the Metal renderer blank.
///
/// The globally keyed caches preserve both setup forms and running sessions:
///   - `aiPanes`: setup/native chat containers keyed by terminal UUID.
///   - `terminalViews`: retained for legacy Ghostty focus and close checks.
///   - `tabPanes`: the entire SplitPaneView for each tab, keyed by tab UUID. Along with
///     `tabPaneLayouts`, a structural snapshot used to decide whether the cached pane
///     is still valid.
///
/// On every `loadWorkspace` call we prune both caches using live-IDs gathered across
/// ALL workspaces (not just the current one), then swap the visible pane. The cached
/// pane is reused whenever the tab's layout is structurally identical (ignoring ratio
/// values); only true structural changes (split/close/new terminal) rebuild it.
final class TabContentView: NSView {
    var store: WorkspaceStore?
    var pwdStore: TerminalPwdStore?
    var chatHistoryStore: AIChatHistoryStore = .shared
    var sessionRegistry: AIChatSessionRegistry?
    var makeAIPane: () -> AITerminalPaneView = { AITerminalPaneView() }
    /// Per-terminal agent status store. Used by `buildSplitPane` to wire
    /// `GhosttyTerminalView.onUserActivity` → `markRead`, so clicking or
    /// typing in a pane clears its solid status dot (same effect as switching
    /// tabs, but scoped to just the interacted pane).
    var statusStore: TerminalStatusStore?
    /// Supplies terminal close-confirmation preferences.
    var settingsStore: SettingsConfigStore?
    /// Retained for legacy tab titles and icons. New terminals use AI selection.
    var quickActionsStore: QuickActionsStore? {
        didSet { tabBar.quickActionsStore = quickActionsStore }
    }
    /// Agent session titles keyed by terminal UUID. Snapshot is forwarded to
    /// `TabBarView.update` on every `loadWorkspace` call so the tab strip shows
    /// agent-generated titles without requiring Observable tracking on the AppKit side.
    var sessionTitleStore: TerminalSessionTitleStore?

    private var theme: AppTheme = .systemFallback(isDark: true)
    /// Mirror of ghostty `background-opacity`. Applied to paneContainer's layer so
    /// ghostty_surface's alpha can actually punch through.
    private var backgroundOpacity: CGFloat = 1.0
    private let tabBar: TabBarView
    /// Rounded wrapper holding the currently visible SplitPaneView. Keeping the
    /// pane inside a dedicated clipping container lets it read as its own floating
    /// card — separate from the tab strip above — so the gap between tab bar and
    /// pane shows the window's translucent sidebar backing instead of canvas.
    private let paneContainer = NSView()

    /// Persistent cache: GhosttyTerminalView instances survive tab / workspace switches.
    private var terminalViews: [UUID: GhosttyTerminalView] = [:]
    private var aiPanes: [UUID: AITerminalPaneView] = [:]
    /// Persistent cache: SplitPaneView instances survive tab / workspace switches so
    /// that switching never re-parents terminal NSViews.
    private var tabPanes: [UUID: SplitPaneView] = [:]
    /// Last layout snapshot per tab; used with SplitNode.sameStructure to decide whether
    /// the cached pane is still valid.
    private var tabPaneLayouts: [UUID: SplitNode] = [:]
    /// 上次 activateTab 真正给该 tab 聚焦过的终端 id。用来识别同 tab 内
    /// `tab.focusedTerminalId` 是否被外部（split/close/⌘⌥→/SplitPaneView.onFocus）
    /// 改过，以便决定要不要重抓 first responder。详见 activateTab 末尾。
    private var lastFocusedTerminalByTab: [UUID: UUID] = [:]
    /// The tab whose pane is currently installed as a subview.
    private var visibleTabId: UUID?
    private var keyMonitor: Any?
    private var lastStatuses: [UUID: TerminalStatus] = [:]
    private var lastShowStatusIndicators: Bool = false

    override init(frame: NSRect) {
        tabBar = TabBarView(frame: .zero)
        super.init(frame: frame)
        setup()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        wantsLayer = true

        paneContainer.wantsLayer = true
        // 参考 tab strip 的圆角，让终端区看起来像嵌在卡片里的一块"小圆角面板"。
        paneContainer.layer?.cornerRadius = TabBarView.stripRadius
        paneContainer.layer?.masksToBounds = true
        addSubview(paneContainer)

        tabBar.autoresizingMask = [.width]
        addSubview(tabBar)

        tabBar.onSelectTab = { [weak self] tabId in
            guard let self, let wsId = self.store?.selectedId else { return }
            self.store?.selectTab(id: tabId, in: wsId)
            self.reloadFromStore()
        }
        tabBar.onAddTab = { [weak self] in
            self?.addNewTab()
        }
        tabBar.onAddQuickActionTab = { [weak self] id in
            self?.addQuickActionTab(id: id)
        }
        tabBar.onCloseTab = { [weak self] tabId in
            self?.confirmCloseTab(tabId)
        }
        tabBar.onRenameTab = { [weak self] tabId, newTitle in
            guard let self, let wsId = self.store?.selectedId else { return }
            self.store?.renameTab(id: tabId, in: wsId, to: newTitle)
            self.reloadFromStore()
        }
        tabBar.onReorderTab = { [weak self] fromIndex, toIndex in
            guard let self, let wsId = self.store?.selectedId else { return }
            self.store?.moveTab(fromIndex: fromIndex, toIndex: toIndex, in: wsId)
            self.reloadFromStore()
        }
        tabBar.onResetAutoTitle = { [weak self] tabId in
            guard let self, let ws = self.store?.selectedWorkspace else { return }
            self.store?.resetTabToAutoTitle(tabId: tabId, in: ws.id)
            self.reloadFromStore()
        }

        subscribeNotifications()
        installKeyMonitor()
    }

    /// Constant window-space x for the tab strip's left edge: the expanded
    /// sidebar's right edge + the standard inset. The strip anchors here in both
    /// states — when expanded it lines up with the content card's left; when the
    /// sidebar collapses, *this view* slides left while the strip stays put, so
    /// the freed top-left space takes the brand / settings / toggle controls
    /// without the tabs lurching. Since both endpoints map the strip to the same
    /// window x, the transition has no horizontal jump.
    private static let tabStripLeadingWindowX: CGFloat = DT.Layout.sidebarWidth + DT.Space.xs

    override func layout() {
        super.layout()
        let inset = DT.Space.xs
        let gap = DT.Space.xs
        let tbH = TabBarView.height
        let contentW = max(0, bounds.width - inset * 2)

        // Tab strip: keep a constant window-x left edge (see tabStripLeadingWindowX).
        // Before the view is in a window, fall back to the plain inset.
        let stripLeft: CGFloat
        if window != nil {
            let originXWindow = convert(NSPoint.zero, to: nil).x
            stripLeft = max(inset, Self.tabStripLeadingWindowX - originXWindow)
        } else {
            stripLeft = inset
        }
        let stripW = max(0, bounds.width - inset - stripLeft)
        // tab 栏上方留 inset(4pt)，与左右 / 下方对称（卡片四边一致）。tbH 已收到 24，
        // 故 pill 中心 = cardInset(4) + inset(4) + tbH/2(12) = 20，仍与 macOS 交通灯能
        // 下探到的位置对齐（见 ContentView.headerControlsTop / alignTrafficLights）。
        tabBar.frame = NSRect(
            x: stripLeft, y: bounds.height - tbH - inset,
            width: stripW, height: tbH)

        let paneH = max(0, bounds.height - tbH - inset * 2 - gap)
        paneContainer.frame = NSRect(x: inset, y: inset, width: contentW, height: paneH)
        // Pane's autoresizingMask keeps it filling paneContainer on layout passes.
    }

    // MARK: - Workspace loading (called by TabBridge)

    func loadWorkspace(_ workspace: Workspace,
                       statuses: [UUID: TerminalStatus] = [:],
                       showStatusIndicators: Bool = false) {
        self.lastStatuses = statuses
        self.lastShowStatusIndicators = showStatusIndicators
        // Prune caches using live IDs collected across EVERY workspace. This is what
        // keeps state alive when the sidebar navigates away from a workspace: its
        // terminals and its cached pane stay in the dictionaries, just temporarily
        // without a superview.
        let allWorkspaces = store?.workspaces ?? [workspace]
        let liveTerms = Set(allWorkspaces.flatMap { ws in
            ws.tabs.flatMap { $0.layout.allTerminalIds() }
        })
        let liveTabs = Set(allWorkspaces.flatMap { $0.tabs.map { $0.id } })

        for id in aiPanes.keys where !liveTerms.contains(id) {
            aiPanes[id]?.removeFromSuperview()
            aiPanes.removeValue(forKey: id)
        }
        for id in terminalViews.keys where !liveTerms.contains(id) {
            terminalViews[id]?.removeFromSuperview()
            terminalViews.removeValue(forKey: id)
        }
        for id in tabPanes.keys where !liveTabs.contains(id) {
            tabPanes[id]?.removeFromSuperview()
            tabPanes.removeValue(forKey: id)
            tabPaneLayouts.removeValue(forKey: id)
            lastFocusedTerminalByTab.removeValue(forKey: id)
        }

        // Update tab bar with status dict
        tabBar.update(tabs: workspace.tabs,
                      selectedTabId: workspace.selectedTabId,
                      theme: theme,
                      statuses: self.lastStatuses,
                      sessionTitles: sessionTitleStore?.titlesSnapshot() ?? [:],
                      backgroundOpacity: backgroundOpacity,
                      showStatusIndicators: self.lastShowStatusIndicators)

        // Install the pane for the workspace's current tab (reusing the cache whenever
        // possible so we never re-parent terminal NSViews on ordinary switches).
        if let tab = workspace.selectedTab {
            activateTab(tab)
        }
    }

    private func reloadFromStore() {
        guard let ws = store?.selectedWorkspace else { return }
        loadWorkspace(ws,
                      statuses: lastStatuses,
                      showStatusIndicators: lastShowStatusIndicators)
    }

    /// Ensure the given tab's SplitPaneView is built/up-to-date, install it as the
    /// single visible pane, and focus its selected terminal. Only rebuilds the pane
    /// when the tab's layout has structurally changed (splits/closes/new terminals);
    /// a pure ratio change reuses the cached pane without touching the tree.
    private func activateTab(_ tab: TerminalTab) {
        let cachedLayout = tabPaneLayouts[tab.id]
        let structureMatches = cachedLayout.map { SplitNode.sameStructure($0, tab.layout) } ?? false
        let pane: SplitPaneView
        if structureMatches, let existing = tabPanes[tab.id] {
            pane = existing
        } else {
            // Old pane for this tab (if any) is detached and dropped; a new one is built.
            // The children it referenced — the GhosttyTerminalView instances — remain
            // alive in `terminalViews`, so no ghostty surface is freed here.
            tabPanes[tab.id]?.removeFromSuperview()
            pane = buildSplitPane(for: tab)
            tabPanes[tab.id] = pane
        }
        // Always refresh the snapshot so the next comparison has the latest ratios on
        // hand (ratios are ignored by sameStructure, but we keep the snapshot honest).
        tabPaneLayouts[tab.id] = tab.layout

        // Swap visible pane: detach whichever pane is currently installed, then make
        // sure `pane` is parented to self with the right frame.
        let didSwitchTab = visibleTabId != tab.id
        let didFocusedTerminalChange = lastFocusedTerminalByTab[tab.id] != tab.focusedTerminalId
        if let currentId = visibleTabId, currentId != tab.id {
            tabPanes[currentId]?.removeFromSuperview()
        }
        visibleTabId = tab.id
        if pane.superview !== paneContainer {
            // pane 填满 paneContainer，paneContainer 只负责 cornerRadius 裁切。
            // 终端内容到圆角边的"呼吸感"靠 ghostty 自己的 window-padding 实现，
            // 不再在 theall 侧套一层额外 inset / canvas 层。
            pane.frame = paneContainer.bounds
            pane.autoresizingMask = [.width, .height]
            paneContainer.addSubview(pane)
        }
        pane.applyTheme(theme)

        // 三类需要主动把 first responder 拽到终端的"用户行为驱动"路径：
        //   1. 真切 tab（含首次安装：visibleTabId 旧值 nil → tab.id）
        //   2. layout 结构变了（split / close 让 SplitPaneView 整棵被替换，
        //      旧 GhosttyTerminalView 已 removeFromSuperview，window.firstResponder
        //      若指向它会失效）
        //   3. focusedTerminalId 变了（split 落到新 pane / close 退到兄弟 pane /
        //      ⌘⌥→ 切窗格 / SplitPaneView.onFocus 程序焦点切换）—— 这种情况下
        //      要么用户已经手动让目标 view 当 firstResponder（再调 makeFirstResponder
        //      是 idempotent），要么 store 单方面切了 focus 我们必须跟上
        //
        // 其余场景（status / pwd / metadata / workspace 列表 / 设置面板状态等任一
        // @Observable 变化触发的 SwiftUI 重渲）不会让上述三个值变化——保持当前
        // first responder 不动，避免把侧栏 / 标签的内联 rename 字段（NSText 子类）
        // 强行 resign，触发 controlTextDidEndEditing 把用户没编辑完的内容当成
        // 确认提交并关掉 rename UI。
        if didSwitchTab || !structureMatches || didFocusedTerminalChange {
            focusTerminal(tab.focusedTerminalId)
        }
        lastFocusedTerminalByTab[tab.id] = tab.focusedTerminalId
    }

    private func buildSplitPane(for tab: TerminalTab) -> SplitPaneView {
        let tabId = tab.id
        return SplitPaneView(
            node: tab.layout,
            terminalViewForId: { [weak self] id -> NSView in
                // SplitPaneView is owned by TabContentView, so self cannot be nil while
                // any SplitPaneView built by this instance is alive.
                guard let self else { fatalError("TabContentView deallocated while SplitPaneView still active") }
                return self.aiPaneFor(id: id, tabId: tabId)
            },
            onRatioChanged: { [weak self] splitId, ratio in
                guard let self, let wsId = self.store?.selectedId else { return }
                self.store?.updateSplitRatio(splitId: splitId, to: ratio, tabId: tabId, in: wsId)
            },
            onFocus: { [weak self] terminalId in
                guard let self, let wsId = self.store?.selectedId else { return }
                self.store?.updateFocusedTerminal(id: terminalId, tabId: tabId, in: wsId)
                self.focusTerminal(terminalId)
            }
        )
    }

    private func aiPaneFor(id: UUID, tabId: UUID) -> AITerminalPaneView {
        if let existing = aiPanes[id] { return existing }
        let pane: AITerminalPaneView
        if let session = sessionRegistry?.session(for: id) {
            pane = AITerminalPaneView(session: session, managesLifecycle: false)
        } else { pane = makeAIPane() }
        pane.applyTheme(theme, locale: tabBar.locale)
        pane.workingDirectory = { [weak self] in self?.pwdStore?.pwd(for: id) ?? NSHomeDirectory() }
        pane.onDirectoryChanged = { [weak self] in self?.pwdStore?.setPwd($0, for: id) }
        if sessionRegistry == nil {
            pane.session.onFirstMessageSubmitted = { [weak self] prompt in
                self?.store?.nameWorkspaceFromFirstPrompt(prompt, terminalId: id)
            }
        }
        pane.onFocusRequested = { [weak self, weak pane] in
            guard let self, pane?.window != nil, self.visibleTabId == tabId,
                  let workspace = self.store?.workspaces.first(where: { $0.tabs.contains(where: { $0.id == tabId }) })
            else { return }
            self.store?.updateFocusedTerminal(id: id, tabId: tabId, in: workspace.id)
            self.statusStore?.markRead(terminalIds: [id])
        }
        aiPanes[id] = pane
        pane.restoreHistory(for: id, store: chatHistoryStore)
        return pane
    }

    private func focusTerminal(_ id: UUID) {
        guard let tv = terminalViews[id] else {
            GhosttyTerminalView.makeFrontmost(nil)
            if window?.firstResponder is GhosttyTerminalView {
                window?.makeFirstResponder(nil)
            }
            aiPanes[id]?.focusComposer()
            // Keep an already-focused setup text field intact.
            return
        }
        GhosttyTerminalView.makeFrontmost(tv)
        window?.makeFirstResponder(tv)
    }

    func applyTheme(_ theme: AppTheme, backgroundOpacity: CGFloat = 1.0, locale: Locale = .current) {
        self.theme = theme
        self.backgroundOpacity = backgroundOpacity
        // paneContainer 不再画自己的 canvas 层 —— 否则会在 ghostty surface 之外
        // 套出一圈可见的额外容器色，变成"两层 DOM"。保留 cornerRadius 作为单纯
        // 的 clip 容器，让 surface 自己成为那一块圆角终端。
        layer?.backgroundColor = .clear
        paneContainer.layer?.backgroundColor = .clear
        tabBar.locale = locale
        tabBar.applyTheme(theme, backgroundOpacity: backgroundOpacity)
        // Propagate to all cached panes — even the ones not currently visible, so
        // they're styled correctly when we swap them in on a future tab/workspace switch.
        tabPanes.values.forEach { $0.applyTheme(theme) }
        aiPanes.values.forEach { $0.applyTheme(theme, locale: locale) }
    }

    /// Called from TabBridge.updateNSView when LanguageStore.tick changes.
    /// Refreshes the tab bar and cached AI connection forms.
    func refreshLocalizedStrings(locale: Locale = .current) {
        tabBar.locale = locale
        tabBar.refreshLocalizedStrings()
        aiPanes.values.forEach { $0.session.locale = locale }
    }

    func detach() {
        for pane in aiPanes.values { pane.session.flushHistory() }
        GhosttyTerminalView.makeFrontmost(nil)
        terminalViews.values.forEach { $0.isHidden = true }
        removeKeyMonitor()
        tabBar.releaseTitlebarDragLock()
    }

    /// 由 TabBridge 在 tab 内容被隐藏（如打开 Settings 覆盖层）时调用：键盘 ⌘, 打开 Settings
    /// 不会让 tab 栏收到 mouseExited，悬停锁会把 window.isMovable 永久留在 false——这里显式解锁。
    func releaseTitlebarDragLock() {
        tabBar.releaseTitlebarDragLock()
    }

    private func removeKeyMonitor() {
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
    }

    func attach() {
        terminalViews.values.forEach { $0.isHidden = false }
        if let tab = store?.selectedWorkspace?.selectedTab {
            focusTerminal(tab.focusedTerminalId)
        }
        if keyMonitor == nil { installKeyMonitor() }
    }

    // MARK: - Notification subscriptions

    private func subscribeNotifications() {
        // 注：Edit > Copy / Paste / Select All 不在这里订阅。⌘C/⌘V/⌘A 由 TheAllApp 的
        // pasteboard CommandGroup 通过 NSApp.sendAction(_:to:nil) 沿 responder chain
        // 派发，由 NSText 子类（rename 字段 / 设置 TextField）或 GhosttyTerminalView
        // 的同名 selector 直接处理。
        let names: [Notification.Name] = [
            .theAllNewTab, .theAllClosePane,
            .theAllSplitVertical, .theAllSplitHorizontal,
            .theAllSelectNextTab, .theAllSelectPrevTab,
            .theAllSelectTabAtIndex,
            .theAllFocusNextPane, .theAllFocusPrevPane,
        ]
        for name in names {
            NotificationCenter.default.addObserver(
                self, selector: #selector(handleNotification(_:)), name: name, object: nil)
        }
    }

    @objc private func handleNotification(_ note: Notification) {
        // Ignore broadcasts targeting other windows when multiple workspaces are open.
        guard window?.isKeyWindow == true else { return }
        switch note.name {
        case .theAllNewTab:           addNewTab()
        case .theAllClosePane:        closeCurrentPane()
        case .theAllSplitVertical:    splitCurrentPane(direction: .vertical)
        case .theAllSplitHorizontal:  splitCurrentPane(direction: .horizontal)
        case .theAllSelectNextTab:    cycleTab(forward: true)
        case .theAllSelectPrevTab:    cycleTab(forward: false)
        case .theAllSelectTabAtIndex:
            if let idx = note.userInfo?["index"] as? Int { selectTab(at: idx) }
        case .theAllFocusNextPane:    focusAdjacentPane(forward: true)
        case .theAllFocusPrevPane:    focusAdjacentPane(forward: false)
        default: break
        }
    }

    // MARK: - Close confirmation

    private func confirmCloseTab(_ tabId: UUID) {
        guard let wsId = store?.selectedId,
              let ws = store?.workspaces.first(where: { $0.id == wsId }),
              let tab = ws.tabs.first(where: { $0.id == tabId }) else { return }

        let terminalStatuses = tab.layout.allTerminalIds().map { terminalId in
            statusStore?.status(for: terminalId) ?? .neverRan
        }
        let surfaceNeedsConfirmation = tab.layout.allTerminalIds().contains { terminalId in
            (aiPanes[terminalId]?.session.chat?.needsConfirmClose ?? false)
                || (terminalViews[terminalId]?.needsConfirmQuit ?? false)
        }
        let needsConfirm = TabCloseConfirmationPolicy.needsConfirmation(
            setting: settingsStore?.get("confirm-close-surface"),
            statuses: terminalStatuses,
            surfaceNeedsConfirmation: surfaceNeedsConfirmation
        )

        guard needsConfirm else {
            store?.removeTab(id: tabId, from: wsId)
            reloadFromStore()
            return
        }

        guard let window else { return }

        let alert = NSAlert()
        alert.messageText = L10n.string("tab.close.alert.title")
        alert.informativeText = L10n.string("tab.close.alert.message %@", tab.title)
        alert.addButton(withTitle: L10n.string("tab.close.alert.confirm"))
        alert.addButton(withTitle: L10n.string("tab.close.alert.cancel"))
        alert.alertStyle = .warning

        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            self.store?.removeTab(id: tabId, from: wsId)
            self.reloadFromStore()
        }
    }

    private func addNewTab() {
        guard let wsId = store?.selectedId,
              let ws = store?.selectedWorkspace else { return }
        // Read sourceId BEFORE addTab: addTab switches selectedTabId to the
        // new tab, after which selectedTab?.focusedTerminalId would resolve to
        // the fresh terminal and inherit would self-copy a nil.
        let sourceId = ws.selectedTab?.focusedTerminalId
        guard let result = store?.addTab(to: wsId) else { return }
        if let sourceId {
            pwdStore?.inherit(from: sourceId, to: result.terminalId)
        }
        reloadFromStore()
    }

    /// Create a Quick Action tab from the "+" dropdown. Mirrors the old top-bar
    /// quick-action button: resolve the display title, add the tab via the
    /// store, and inherit the source pane's pwd so the action launches in the
    /// cwd the user was looking at.
    private func addQuickActionTab(id: QuickActionId) {
        guard let wsId = store?.selectedId else { return }
        let title = quickActionsStore?.displayName(for: id, locale: tabBar.locale) ?? id
        guard let result = store?.addQuickActionTab(id: id, title: title, in: wsId) else { return }
        if let prev = result.sourcePwdTerminalId {
            pwdStore?.inherit(from: prev, to: result.terminalId)
        }
        reloadFromStore()
    }

    private func closeCurrentPane() {
        guard let ws = store?.selectedWorkspace,
              let wsId = store?.selectedId,
              let tab = ws.selectedTab else { return }

        let terminalIds = tab.layout.allTerminalIds()
        if terminalIds.count <= 1 {
            confirmCloseTab(tab.id)
            return
        }

        store?.closeTerminal(id: tab.focusedTerminalId, in: wsId, tabId: tab.id)
        reloadFromStore()
    }

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

    /// Returns the currently focused pane's view, or nil if the workspace has no tab/pane.
    /// Used by Edit-menu handlers to target the right surface.
    private func focusedTerminalView() -> GhosttyTerminalView? {
        guard let tab = store?.selectedWorkspace?.selectedTab else { return nil }
        return terminalViews[tab.focusedTerminalId]
    }

    // MARK: - Key monitor (hidden shortcut aliases)

    private func installKeyMonitor() {
        // 处理两组 menu 不可见的 hidden duplicate 快捷键：
        // - ⌘⌥↑/↓ 是 Terminal → Focus Next/Previous Pane 的别名（菜单展示
        //   ⌘⌥→/← 给水平 pane 直觉；↑/↓ 是常见 pane-nav 习惯）
        // - Ctrl+Tab / Ctrl+Shift+Tab 是 Terminal → Select Next/Previous Tab
        //   (⌘⇧]/[) 的浏览器/iTerm 风格别名
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }

            // 只看 ⌘⌃⌥⇧ 这四位，忽略 .numericPad / .function / .capsLock 等
            let interesting: NSEvent.ModifierFlags = [.command, .control, .option, .shift]
            let mods = event.modifierFlags.intersection(interesting)

            // ⌘⌥↑/↓ — pane 切焦点
            if mods == [.command, .option] {
                switch event.keyCode {
                case 125: self.focusAdjacentPane(forward: true);  return nil  // ↓
                case 126: self.focusAdjacentPane(forward: false); return nil  // ↑
                default: break
                }
            }

            // Ctrl+Tab / Ctrl+Shift+Tab — tab 循环（keyCode 48 = Tab）
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
        removeKeyMonitor()
    }
}
