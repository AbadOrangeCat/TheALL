import AppKit

// MARK: - ThemedSplitView

/// NSSplitView subclass that renders a 1-px hairline divider in theme.border colour.
private final class ThemedSplitView: NSSplitView {
    var themeDividerColor: NSColor = .separatorColor
    /// Ratio to apply once the view has a non-zero size (applied once in layout).
    var pendingRatio: CGFloat?

    override var dividerThickness: CGFloat { 1 }

    override func drawDivider(in rect: NSRect) {
        themeDividerColor.setFill()
        NSBezierPath.fill(rect)
    }

    override func layout() {
        super.layout()
        guard let ratio = pendingRatio else { return }
        let total = isVertical ? bounds.width : bounds.height
        guard total > 0 else { return }
        pendingRatio = nil
        setPosition(total * ratio, ofDividerAt: 0)
    }
}

// MARK: - SplitPaneView

/// Recursively renders a SplitNode tree.
/// - For `.terminal(id)`: hosts the AI pane returned by `terminalViewForId`.
/// - For `.split(...)`: creates a ThemedSplitView containing two child SplitPaneViews.
///
/// Terminal views are NOT owned here — they live in TabContentView's cache.
/// Callbacks are injected at init time so they propagate correctly through multi-level trees.
final class SplitPaneView: NSView {
    /// Called when the user drags an NSSplitView divider. (splitId, newRatio 0…1)
    let onRatioChanged: ((UUID, CGFloat) -> Void)?
    /// Called when the user clicks a terminal pane to focus it.
    let onFocus: ((UUID) -> Void)?

    private let node: SplitNode
    private let terminalViewForId: (UUID) -> NSView

    private var splitView: ThemedSplitView?
    private var children: [SplitPaneView] = []
    private var splitDelegate: SplitDelegate?  // strong ref prevents dealloc
    private var terminalId: UUID?              // set for .terminal leaves only

    init(node: SplitNode,
         terminalViewForId: @escaping (UUID) -> NSView,
         onRatioChanged: ((UUID, CGFloat) -> Void)? = nil,
         onFocus: ((UUID) -> Void)? = nil) {
        self.node = node
        self.terminalViewForId = terminalViewForId
        self.onRatioChanged = onRatioChanged
        self.onFocus = onFocus
        super.init(frame: .zero)
        wantsLayer = true
        buildLayout()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func buildLayout() {
        switch node {
        case .terminal(let id):
            terminalId = id
            let tv = terminalViewForId(id)
            tv.removeFromSuperview()
            // The cached AI pane owns setup and the optional terminal/scroller.
            tv.frame = bounds
            tv.autoresizingMask = [.width, .height]
            addSubview(tv)

        case .split(let splitId, let direction, let ratio, let first, let second):
            let sv = ThemedSplitView(frame: bounds)
            sv.isVertical = (direction == .vertical)
            sv.autoresizingMask = [.width, .height]
            sv.pendingRatio = ratio   // applied in ThemedSplitView.layout() once bounds are non-zero

            let firstPane  = makeChild(node: first)
            let secondPane = makeChild(node: second)
            sv.addArrangedSubview(firstPane)
            sv.addArrangedSubview(secondPane)

            // Delegate stored strongly to avoid dealloc while sv is alive
            let delegate = SplitDelegate(splitId: splitId, isVertical: sv.isVertical) { [weak self] sid, r in
                self?.onRatioChanged?(sid, r)
            }
            sv.delegate = delegate
            self.splitDelegate = delegate

            addSubview(sv)
            self.splitView = sv
            self.children  = [firstPane, secondPane]
        }
    }

    private func makeChild(node: SplitNode) -> SplitPaneView {
        SplitPaneView(node: node,
                      terminalViewForId: terminalViewForId,
                      onRatioChanged: onRatioChanged,
                      onFocus: onFocus)
    }

    // MARK: - Theme

    func applyTheme(_ theme: AppTheme) {
        splitView?.themeDividerColor = theme.border
        splitView?.needsDisplay = true
        children.forEach { $0.applyTheme(theme) }
        // GhosttyTerminalView manages its own colours via Ghostty config; no call needed here.
    }

    // MARK: - Focus

    /// Terminal leaf click → notify TabContentView to update focus.
    /// Consistent with TabItemView.mouseDown pattern; no gesture recognizer needed.
    override func mouseDown(with event: NSEvent) {
        if let id = terminalId {
            onFocus?(id)
        }
        super.mouseDown(with: event)
    }
}

// MARK: - SplitDelegate

/// Separate NSSplitViewDelegate object so SplitPaneView does not need to be a delegate.
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
        // Use bounds (content space) rather than frame (parent space) for correct measurement.
        let total = isVertical ? sv.bounds.width : sv.bounds.height
        guard total > 0 else { return }
        let first = isVertical ? sv.subviews[0].frame.width : sv.subviews[0].frame.height
        onRatioChanged(splitId, first / total)
    }
}
