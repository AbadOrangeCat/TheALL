import AppKit

/// Wraps a `GhosttyTerminalView` in an `NSScrollView` to provide native macOS
/// scrollbar support. Architecture ported from ghostty upstream's SurfaceScrollView:
///
/// - `scrollView`: outer NSScrollView, overlay scrollers only, transparent background.
/// - `documentView`: blank NSView whose height == total scrollback rows × cell height.
/// - `terminalView`: the actual Metal-backed ghostty renderer, a subview of
///   `documentView` whose frame is kept pinned to the current `visibleRect` so
///   ghostty only ever renders the viewport.
///
/// Coordinate inversion: terminal rows count from the top (row 0 = oldest),
/// AppKit y grows upward, so offsetY = (total - offset - len) × cellHeight.
///
/// State comes from ghostty via `GhosttyTerminalView.scrollbarDidChangeNotification`;
/// user drags are converted to row numbers and sent back via the `scroll_to_row:N`
/// binding action.
final class SurfaceScrollView: NSView {
    private let scrollView = NSScrollView()
    private let documentView = NSView(frame: .zero)
    private let terminalView: GhosttyTerminalView

    private var observers: [NSObjectProtocol] = []
    private var isLiveScrolling = false
    /// Last row we sent via `scroll_to_row:N`. Skips redundant actions when the
    /// cursor drags within the same cell.
    private var lastSentRow: Int?

    init(terminalView: GhosttyTerminalView) {
        self.terminalView = terminalView
        super.init(frame: .zero)

        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.usesPredominantAxisScrolling = true
        // Always overlay style: legacy (always-visible) scrollers would eat
        // horizontal pt from the ghostty surface every time they toggle on/off,
        // triggering PTY reflow storms. Overlay floats above the surface and the
        // surface never reflows just because the scrollbar appeared.
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = false
        scrollView.contentView.clipsToBounds = false

        documentView.frame.size = .zero
        scrollView.documentView = documentView

        // Terminal is a child of documentView. Its frame origin follows the
        // clip view's visibleRect so the rendered viewport stays pinned in place
        // while documentView "scrolls" underneath it visually.
        terminalView.removeFromSuperview()
        documentView.addSubview(terminalView)

        addSubview(scrollView)

        wireObservers()
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    private func wireObservers() {
        // Clip view bounds change → re-pin terminal frame to visible rect.
        scrollView.contentView.postsBoundsChangedNotifications = true
        observers.append(NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { [weak self] _ in self?.synchronizeTerminalFrame() })

        observers.append(NotificationCenter.default.addObserver(
            forName: NSScrollView.willStartLiveScrollNotification,
            object: scrollView,
            queue: .main
        ) { [weak self] _ in self?.isLiveScrolling = true })

        observers.append(NotificationCenter.default.addObserver(
            forName: NSScrollView.didEndLiveScrollNotification,
            object: scrollView,
            queue: .main
        ) { [weak self] _ in self?.isLiveScrolling = false })

        observers.append(NotificationCenter.default.addObserver(
            forName: NSScrollView.didLiveScrollNotification,
            object: scrollView,
            queue: .main
        ) { [weak self] _ in self?.handleLiveScroll() })

        // Force overlay even if user changes system pref to "Always".
        observers.append(NotificationCenter.default.addObserver(
            forName: NSScroller.preferredScrollerStyleDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in self?.scrollView.scrollerStyle = .overlay })

        observers.append(NotificationCenter.default.addObserver(
            forName: GhosttyTerminalView.scrollbarDidChangeNotification,
            object: terminalView,
            queue: .main
        ) { [weak self] _ in self?.synchronizeScrollView() })

        observers.append(NotificationCenter.default.addObserver(
            forName: GhosttyTerminalView.cellSizeDidChangeNotification,
            object: terminalView,
            queue: .main
        ) { [weak self] _ in self?.synchronizeScrollView() })
    }

    override var safeAreaInsets: NSEdgeInsets { NSEdgeInsetsZero }

    override func layout() {
        super.layout()
        scrollView.frame = bounds
        // Terminal always fills the visible viewport. setFrameSize cascades the
        // new size into ghostty via `ghostty_surface_set_size`.
        terminalView.frame.size = scrollView.bounds.size
        documentView.frame.size.width = scrollView.bounds.width
        synchronizeScrollView()
        synchronizeTerminalFrame()
    }

    // MARK: - Sync

    /// Re-size the blank document view to reflect total scrollback rows, then
    /// (unless the user is actively dragging) scroll so that the visible portion
    /// matches ghostty's current offset.
    private func synchronizeScrollView() {
        documentView.frame.size.height = documentHeight()

        if !isLiveScrolling {
            let cellHeight = terminalView.cellSize.height
            if cellHeight > 0, let sb = terminalView.scrollbarState {
                // Invert: ghostty offset is rows-from-top; AppKit scrolls +Y up.
                let bottomRows = Int64(sb.total) - Int64(sb.offset) - Int64(sb.len)
                let offsetY = CGFloat(max(0, bottomRows)) * cellHeight
                scrollView.contentView.scroll(to: CGPoint(x: 0, y: offsetY))
                lastSentRow = Int(sb.offset)
            }
        }

        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    /// Pin the terminal subview to wherever the clip view's visible rect is
    /// currently located inside the document coordinate space, so the Metal
    /// content stays perfectly aligned with the viewport during scrolling.
    private func synchronizeTerminalFrame() {
        let visible = scrollView.contentView.documentVisibleRect
        terminalView.frame.origin = visible.origin
    }

    /// During a live drag: convert the current scroll position back into a
    /// terminal row index and send `scroll_to_row:N` (only when the row actually
    /// changes, to avoid IPC spam).
    private func handleLiveScroll() {
        let cellHeight = terminalView.cellSize.height
        guard cellHeight > 0 else { return }
        let visible = scrollView.contentView.documentVisibleRect
        let docH = documentView.frame.height
        let offsetFromTop = docH - visible.origin.y - visible.height
        let row = max(0, Int(offsetFromTop / cellHeight))
        guard row != lastSentRow else { return }
        lastSentRow = row
        terminalView.performBindingAction("scroll_to_row:\(row)")
    }

    /// Height (in pt) the document view must take to make the scroller thumb
    /// represent the correct slice of scrollback.
    private func documentHeight() -> CGFloat {
        let contentH = scrollView.contentSize.height
        let cellH = terminalView.cellSize.height
        guard cellH > 0, let sb = terminalView.scrollbarState else { return contentH }
        // Keep the same vertical padding the viewport has around the terminal
        // grid, otherwise the document grid slides out of cell-row alignment.
        let gridH = CGFloat(sb.total) * cellH
        let padding = contentH - (CGFloat(sb.len) * cellH)
        return gridH + padding
    }

    // MARK: - Mouse

    /// When the OS pref is set to "legacy" scrollers, users expect the scroller
    /// to stay visible while the mouse is near it. Since we force overlay, flash
    /// the scroller on hover so a drag target is still clickable.
    override func mouseMoved(with event: NSEvent) {
        guard NSScroller.preferredScrollerStyle == .legacy else { return }
        scrollView.flashScrollers()
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach { removeTrackingArea($0) }
        super.updateTrackingAreas()
        guard let scroller = scrollView.verticalScroller else { return }
        addTrackingArea(NSTrackingArea(
            rect: convert(scroller.bounds, from: scroller),
            options: [.mouseMoved, .activeInKeyWindow],
            owner: self,
            userInfo: nil
        ))
    }
}
