import AppKit
import QuartzCore

/// 10×10 dot / spinning arc showing one of four terminal states.
/// Mutates only via `update(status:theme:)` — callers hand it the latest state,
/// the view decides which CALayer trees / animations to show.
final class TerminalStatusIconView: NSView {

    static let size: CGFloat = 10

    private var status: TerminalStatus = .neverRan
    private var theme: AppTheme = .systemFallback(isDark: true)

    private let shapeLayer = CAShapeLayer()

    /// 该图标随 tab pill 一起处于顶部标题栏拖拽区——点击不应拖窗（见 TabBarView 同名说明）。
    override var mouseDownCanMoveWindow: Bool { false }

    override init(frame: NSRect) {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.size, height: Self.size))
        setup()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        wantsLayer = true
        layer?.addSublayer(shapeLayer)
        shapeLayer.frame = bounds
        render()
    }

    override func layout() {
        super.layout()
        shapeLayer.frame = bounds
        render()
    }

    func update(status: TerminalStatus, theme: AppTheme) {
        let changedStatusKind = !Self.sameKind(status, self.status)
        self.status = status
        self.theme = theme
        render()
        if changedStatusKind {
            stopSpinAnimation()
            stopPulseAnimation()
            switch status {
            case .running:     startSpinAnimation()
            default:           break
            }
        }
        toolTip = Self.tooltipText(for: status)
    }

    private static func sameKind(_ a: TerminalStatus, _ b: TerminalStatus) -> Bool {
        switch (a, b) {
        case (.neverRan, .neverRan),
             (.running,  .running),
             (.idle,     .idle),
             (.needsInput, .needsInput),
             (.success,  .success),
             (.failed,   .failed):
            return true
        default:
            return false
        }
    }

    /// Pure style function used by `render()` to paint the ellipse layer.
    /// Returns nil for kinds that draw a custom path (e.g. `.running`'s 270° arc).
    static func renderStyle(for status: TerminalStatus, theme: AppTheme)
        -> (fill: NSColor, stroke: NSColor, lineWidth: CGFloat)?
    {
        switch status {
        case .neverRan:
            return (NSColor.clear, theme.textTertiary, 1)
        case .running:
            return nil   // custom arc path; handled inline
        case .idle:
            return (NSColor.clear,
                    theme.textTertiary.withAlphaComponent(0.6), 1)
        case .needsInput:
            return (theme.accent, NSColor.clear, 0)
        case .success(_, _, _, _, _, let readAt):
            if readAt != nil {
                return (NSColor.clear, theme.textTertiary, 1)
            }
            return (theme.success, NSColor.clear, 0)
        case .failed(_, _, _, _, _, let readAt):
            if readAt != nil {
                return (NSColor.clear, theme.textTertiary, 1)
            }
            return (theme.danger, NSColor.clear, 0)
        }
    }

    private func render() {
        let rect = bounds.insetBy(dx: 1, dy: 1)
        if case .running = status {
            // 270° open arc, 1.5pt stroke, accent colour
            let center = CGPoint(x: rect.midX, y: rect.midY)
            let radius = min(rect.width, rect.height) / 2
            let path = CGMutablePath()
            path.addArc(center: center, radius: radius,
                        startAngle: 0, endAngle: CGFloat.pi * 1.5,
                        clockwise: false)
            shapeLayer.path = path
            shapeLayer.fillColor = NSColor.clear.cgColor
            shapeLayer.strokeColor = theme.accent.cgColor
            shapeLayer.lineWidth = 1.5
            shapeLayer.lineCap = .round
            return
        }
        guard let style = Self.renderStyle(for: status, theme: theme) else { return }
        shapeLayer.path = CGPath(ellipseIn: rect, transform: nil)
        shapeLayer.fillColor = style.fill.cgColor
        shapeLayer.strokeColor = style.stroke.cgColor
        shapeLayer.lineWidth = style.lineWidth
    }

    private func startSpinAnimation() {
        guard shapeLayer.animation(forKey: "spin") == nil else { return }
        // Rotate around layer centre — set anchor/position accordingly.
        shapeLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        shapeLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        shapeLayer.bounds = bounds

        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0.0
        spin.toValue = -CGFloat.pi * 2   // clockwise
        spin.duration = 1.0
        spin.repeatCount = .infinity
        spin.isRemovedOnCompletion = false
        shapeLayer.add(spin, forKey: "spin")
    }

    private func stopSpinAnimation() {
        shapeLayer.removeAnimation(forKey: "spin")
        shapeLayer.transform = CATransform3DIdentity
    }

    private func stopPulseAnimation() {
        shapeLayer.removeAnimation(forKey: "pulse")
        shapeLayer.opacity = 1.0
    }

    static func tooltipText(for status: TerminalStatus) -> String? {
        switch status {
        case .neverRan:
            return nil
        case .running(let startedAt, let detail):
            let elapsed = max(0, Date().timeIntervalSince(startedAt))
            let first = "Running for \(Self.formatDuration(elapsed))"
            return detail.map { "\(first)\n\($0)" } ?? first
        case .idle(let since):
            let elapsed = max(0, Date().timeIntervalSince(since))
            return "Idle for \(Self.formatDuration(elapsed))"
        case .needsInput(let since):
            let elapsed = max(0, Date().timeIntervalSince(since))
            return "Needs input (\(Self.formatDuration(elapsed)) ago)"
        case .success(_, let duration, _, let agent, let summary, let readAt):
            let head = "\(agent.displayName): turn finished · \(Self.formatDuration(duration))"
            let prefix = readAt != nil ? "\(head) · read" : head
            return summary.map { "\(prefix)\n\($0)" } ?? prefix
        case .failed(_, let duration, _, let agent, let summary, let readAt):
            let head = "\(agent.displayName): turn had tool errors · \(Self.formatDuration(duration))"
            let prefix = readAt != nil ? "\(head) · read" : head
            return summary.map { "\(prefix)\n\($0)" } ?? prefix
        }
    }

    static func formatDuration(_ seconds: TimeInterval) -> String {
        if seconds < 1 { return "<1s" }
        if seconds < 60 { return "\(Int(seconds))s" }
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        return s == 0 ? "\(m)m" : "\(m)m\(s)s"
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: Self.size, height: Self.size)
    }
}
