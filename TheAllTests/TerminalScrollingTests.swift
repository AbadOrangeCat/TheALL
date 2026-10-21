import AppKit
import XCTest
@testable import TheAll

final class TerminalScrollingTests: XCTestCase {
    private final class WheelEvent: NSEvent {
        var point = NSPoint.zero
        var flags: NSEvent.ModifierFlags = []
        override var locationInWindow: NSPoint { point }
        override var modifierFlags: NSEvent.ModifierFlags { flags }
        override var scrollingDeltaX: CGFloat { 0 }
        override var scrollingDeltaY: CGFloat { 1 }
        override var hasPreciseScrollingDeltas: Bool { false }
        override var momentumPhase: NSEvent.Phase { [] }
    }

    @MainActor func testHoverThenScrollReportsRealModifiersWithoutClickAndKeepsFocus() throws {
        var displayCount: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &displayCount) == .success, displayCount > 0 else {
            throw XCTSkip("Requires an active display for Ghostty rendering")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TheAllScrollTest-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("mouse.py")
        let ready = directory.appendingPathComponent("ready")
        let output = directory.appendingPathComponent("mouse-events")
        // Exercise the real PTY and libghostty mouse encoder. No AI, real keys,
        // clipboard access, or physical pointer movement is involved.
        try """
        import os, sys, tty
        tty.setraw(0)
        os.write(1, b'\\x1b[?1000h\\x1b[?1006h')
        open(sys.argv[1], 'w').close()
        with open(sys.argv[2], 'ab', buffering=0) as log:
            while True:
                data = os.read(0, 4096)
                if not data: break
                log.write(data)
        """.write(to: script, atomically: true, encoding: .utf8)
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 700, height: 500))
        let terminal = GhosttyTerminalView(frame: NSRect(x: 0, y: 50, width: 700, height: 450))
        terminal.aiLaunchConfiguration = AILaunchConfiguration(command:
            ["/usr/bin/python3", script.path, ready.path, output.path].map(AILaunchConfiguration.shellQuote).joined(separator: " "), environment: [:])
        let input = NSTextField(frame: NSRect(x: 20, y: 10, width: 200, height: 24))
        root.addSubview(input)
        root.addSubview(terminal)
        let window = NSWindow(contentRect: root.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = root
        window.makeKeyAndOrderFront(nil)
        defer {
            GhosttyTerminalView.makeFrontmost(nil)
            window.contentView = nil
            window.close()
        }
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: ready.path) { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: ready.path))
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        XCTAssertNotNil(terminal.rawSurface)
        GhosttyTerminalView.makeFrontmost(terminal)
        window.makeFirstResponder(terminal)
        let point = terminal.convert(NSPoint(x: 100, y: 100), to: nil)
        guard let hover = NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: [], timestamp: 0,
                                             windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)
        else { return XCTFail("Could not construct hover event") }
        terminal.mouseMoved(with: hover)
        let wheel = WheelEvent()
        wheel.point = point
        terminal.scrollWheel(with: wheel)
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        var captured = (try? String(contentsOf: output, encoding: .utf8)) ?? ""
        XCTAssertTrue(captured.contains("\u{1B}[<64;"), "Ordinary wheel must reach the TUI without synthetic Shift: \(captured.debugDescription)")
        XCTAssertFalse(captured.contains("\u{1B}[<68;"))
        // Real Shift invokes Ghostty mouse-shift-capture (local scrolling),
        // rather than leaking a synthetic Shift wheel report to the TUI.
        wheel.flags = [.shift]
        terminal.scrollWheel(with: wheel)
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        captured = (try? String(contentsOf: output, encoding: .utf8)) ?? ""
        XCTAssertFalse(captured.contains("\u{1B}[<68;"))
        // Scrolling under the pointer must not steal a native input's focus.
        GhosttyTerminalView.makeFrontmost(nil)
        window.makeFirstResponder(input)
        let responder = window.firstResponder
        wheel.flags = []
        terminal.scrollWheel(with: wheel)
        XCTAssertTrue(window.firstResponder === responder)
        _ = terminal.performBindingAction("scroll_to_top")
        XCTAssertTrue(window.firstResponder === responder)
    }
}
