# Terminal Status v2 — Agent Hook Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Replace shell-level OSC 133 heuristics with per-agent wrapper+hook IPC over Unix domain socket, giving precise running/idle/needsInput state for Claude Code, opencode, and Codex CLI.

**Architecture:** Per-surface env vars (`THEALL_HOOK_SOCK`, `THEALL_TERMINAL_ID`) → shell startup sources our shell-hooks and installs agent command overrides → agent wrappers inject lifecycle hooks → hooks emit JSON lines to Unix socket → app listener routes to `TerminalStatusStore`.

**Tech Stack:** Swift (socket listener, env injection), zsh/bash/fish (shell hooks), bash (wrappers), JavaScript (opencode plugin), TOML (codex config overlay).

**Spec:** `docs/superpowers/specs/2026-04-17-terminal-status-v2-agent-hooks.md`

---

## File Structure

**New files:**
- `TheAll/Models/HookMessage.swift` — JSON decode struct
- `TheAll/Models/HookSocketListener.swift` — `DispatchSourceRead` + newline-delimited JSON parser
- `Resources/agent-hooks/hook-emit.sh` — small utility all wrappers use
- `Resources/agent-hooks/shell-hooks.zsh` — preexec/precmd for zsh
- `Resources/agent-hooks/shell-hooks.bash` — DEBUG trap + PROMPT_COMMAND for bash
- `Resources/agent-hooks/shell-hooks.fish` — fish_preexec/fish_prompt events
- `Resources/agent-hooks/agent-functions.zsh` — defines `claude()`/`opencode()`/`codex()` overrides
- `Resources/agent-hooks/agent-functions.bash` — same, bash syntax
- `Resources/agent-hooks/agent-functions.fish` — same, fish syntax
- `Resources/agent-hooks/claude-wrapper.sh` — injects `--settings` hooks JSON
- `Resources/agent-hooks/opencode-wrapper.sh` — installs theall opencode plugin
- `Resources/agent-hooks/opencode-plugin/theall-status.js` — the plugin
- `Resources/agent-hooks/codex-wrapper.sh` — injects notify + optional hooks.json
- `TheAllTests/TerminalStatusV2Tests.swift` — extends priority + tooltip tests for new states
- `TheAllTests/HookMessageTests.swift` — JSON decoding tests
- `TheAllTests/HookSocketListenerTests.swift` — end-to-end socket message roundtrip

**Modified files:**
- `TheAll/Models/TerminalStatus.swift` — +`idle(since:)`, +`needsInput(since:)`, new priority
- `TheAll/Models/TerminalStatusStore.swift` — +`setIdle(terminalId:at:)`, +`setNeedsInput(terminalId:at:)`
- `TheAll/Theme/TerminalStatusIconView.swift` — +2 render branches, +2 tooltip cases, pulse animation
- `TheAll/Ghostty/GhosttyBridge.swift` — rip `onCommandFinished`/`onEnterKey`/`onPromptStart`; router no-op; inject env vars at surface creation
- `TheAll/Ghostty/GhosttyTerminalView.swift` — rip Return-key branch in `keyDown`
- `TheAll/ContentView.swift` — rip v1 onAppear wiring; start socket listener; wire listener → statusStore
- `project.yml` — add `agent-hooks/` to the existing resource copy phase
- `TheAllTests/TerminalStatusTests.swift` — update existing aggregation tests for new priority chain

---

## Task 1: Extend `TerminalStatus` with `idle` and `needsInput`

**Files:**
- Modify: `TheAll/Models/TerminalStatus.swift`
- Modify: `TheAllTests/TerminalStatusTests.swift`

- [ ] **Step 1: Update existing tests for new priority chain before changing production code**

In `TheAllTests/TerminalStatusTests.swift`, locate `testAggregateFailedBeatsSuccessAndNeverRan` and insert right after it:

```swift
    func testIdleBeatsNeverRanButLosesToSuccess() {
        let now = Date()
        // idle + neverRan → idle
        XCTAssertEqual(TerminalStatus.aggregate([.idle(since: now), .neverRan]).priorityCaseName, "idle")
        // success + idle → success
        XCTAssertEqual(
            TerminalStatus.aggregate([.success(exitCode: 0, duration: 1, finishedAt: now), .idle(since: now)]).priorityCaseName,
            "success")
    }

    func testNeedsInputBeatsEverything() {
        let now = Date()
        let inputs: [TerminalStatus] = [
            .running(startedAt: now),
            .failed(exitCode: 1, duration: 1, finishedAt: now),
            .success(exitCode: 0, duration: 1, finishedAt: now),
            .needsInput(since: now),
            .idle(since: now),
            .neverRan
        ]
        XCTAssertEqual(TerminalStatus.aggregate(inputs).priorityCaseName, "needsInput")
    }

    func testFullPriorityChain() {
        // Exhaustive: each state beats everything strictly below it
        let now = Date()
        let order: [(TerminalStatus, String)] = [
            (.needsInput(since: now), "needsInput"),
            (.running(startedAt: now), "running"),
            (.failed(exitCode: 1, duration: 1, finishedAt: now), "failed"),
            (.success(exitCode: 0, duration: 1, finishedAt: now), "success"),
            (.idle(since: now), "idle"),
            (.neverRan, "neverRan")
        ]
        for (i, (high, expected)) in order.enumerated() {
            for j in (i + 1)..<order.count {
                let low = order[j].0
                XCTAssertEqual(TerminalStatus.aggregate([low, high]).priorityCaseName, expected,
                               "\(expected) should beat \(order[j].1)")
            }
        }
    }
```

Also add one helper at the bottom of the test class:

```swift
private extension TerminalStatus {
    var priorityCaseName: String {
        switch self {
        case .neverRan:   return "neverRan"
        case .running:    return "running"
        case .idle:       return "idle"
        case .needsInput: return "needsInput"
        case .success:    return "success"
        case .failed:     return "failed"
        }
    }
}
```

- [ ] **Step 2: Run tests — expect compile failure**

Run: `xcodebuild test -project TheAll.xcodeproj -scheme TheAllTests -only-testing:TheAllTests/TerminalStatusTests 2>&1 | tail -20`
Expected: compile error "type 'TerminalStatus' has no member 'idle'" or similar.

- [ ] **Step 3: Extend the enum and priority**

Replace the enum body in `TheAll/Models/TerminalStatus.swift`:

```swift
enum TerminalStatus: Equatable {
    case neverRan
    case running(startedAt: Date)
    case idle(since: Date)
    case needsInput(since: Date)
    case success(exitCode: Int32, duration: TimeInterval, finishedAt: Date)
    case failed(exitCode: Int32, duration: TimeInterval, finishedAt: Date)

    /// Aggregation priority (higher wins):
    /// needsInput > running > failed > success > idle > neverRan
    fileprivate var priority: Int {
        switch self {
        case .needsInput: return 5
        case .running:    return 4
        case .failed:     return 3
        case .success:    return 2
        case .idle:       return 1
        case .neverRan:   return 0
        }
    }

    static func aggregate(_ statuses: [TerminalStatus]) -> TerminalStatus {
        statuses.reduce(TerminalStatus.neverRan) { current, next in
            next.priority > current.priority ? next : current
        }
    }
}
```

Update the doc-comment at the top to list all six states.

- [ ] **Step 4: Run tests — all pass**

Run: `xcodebuild test -project TheAll.xcodeproj -scheme TheAllTests -only-testing:TheAllTests/TerminalStatusTests 2>&1 | tail -20`
Expected: existing + 3 new tests all PASS.

- [ ] **Step 5: Commit**

```bash
git add TheAll/Models/TerminalStatus.swift TheAllTests/TerminalStatusTests.swift
git commit -m "$(cat <<'EOF'
feat(models): add idle and needsInput to TerminalStatus

Extends the four-state enum to six states for agent-level semantics
(idle = back at prompt after running, needsInput = awaiting tool-use
approval). New priority chain: needsInput > running > failed >
success > idle > neverRan.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Extend `TerminalStatusStore` with new setters

**Files:**
- Modify: `TheAll/Models/TerminalStatusStore.swift`
- Modify: `TheAllTests/TerminalStatusStoreTests.swift`

- [ ] **Step 1: Add failing tests**

Append to `TheAllTests/TerminalStatusStoreTests.swift` (inside the class):

```swift
    func testSetIdle() {
        let store = TerminalStatusStore()
        let id = UUID()
        let t = Date(timeIntervalSince1970: 3000)
        store.setIdle(terminalId: id, at: t)
        XCTAssertEqual(store.status(for: id), .idle(since: t))
    }

    func testSetNeedsInput() {
        let store = TerminalStatusStore()
        let id = UUID()
        let t = Date(timeIntervalSince1970: 4000)
        store.setNeedsInput(terminalId: id, at: t)
        XCTAssertEqual(store.status(for: id), .needsInput(since: t))
    }

    func testIdleOverwritesRunning() {
        let store = TerminalStatusStore()
        let id = UUID()
        store.setRunning(terminalId: id, at: Date())
        let t = Date(timeIntervalSince1970: 5000)
        store.setIdle(terminalId: id, at: t)
        XCTAssertEqual(store.status(for: id), .idle(since: t))
    }
```

- [ ] **Step 2: Run, verify compile failure, then implement**

Add to `TerminalStatusStore`:

```swift
    func setIdle(terminalId: UUID, at since: Date) {
        storage[terminalId] = .idle(since: since)
    }

    func setNeedsInput(terminalId: UUID, at since: Date) {
        storage[terminalId] = .needsInput(since: since)
    }
```

- [ ] **Step 3: Tests pass**

Run: `xcodebuild test -project TheAll.xcodeproj -scheme TheAllTests -only-testing:TheAllTests/TerminalStatusStoreTests 2>&1 | tail -10`

- [ ] **Step 4: Commit**

```bash
git add TheAll/Models/TerminalStatusStore.swift TheAllTests/TerminalStatusStoreTests.swift
git commit -m "$(cat <<'EOF'
feat(models): add setIdle and setNeedsInput to TerminalStatusStore

Matches the new TerminalStatus cases. Same main-queue semantics,
overwrites prior state.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Rip v1 shell-level signals

**Files:**
- Modify: `TheAll/Ghostty/GhosttyBridge.swift`
- Modify: `TheAll/Ghostty/GhosttyTerminalView.swift`
- Modify: `TheAll/ContentView.swift`

- [ ] **Step 1: Remove closures from `GhosttyBridge`**

In `GhosttyBridge.swift`, delete these properties:
```swift
    var onCommandFinished: ...
    var onPromptStart: ...
    var onEnterKey: ...
```

- [ ] **Step 2: Simplify `actionCallback`**

Replace the router body with a no-op that preserves the signature and returns false (we may use the router again for other action types later). In `actionCallback`:

```swift
    private static let actionCallback: ghostty_runtime_action_cb = { _, _, _ in
        // Intentionally inert: v2 uses Unix-socket IPC from wrapper hooks, not
        // ghostty runtime actions. Preserved here so future additions (title
        // changes, clipboard, etc.) have an obvious place to plug in.
        return false
    }
```

- [ ] **Step 3: Remove Return-key detection from `GhosttyTerminalView.keyDown`**

Find and delete:
```swift
        if event.keyCode == 36, let tid = terminalId {
            GhosttyBridge.shared.onEnterKey?(tid, Date())
        }
```

- [ ] **Step 4: Remove wiring in `ContentView.onAppear`**

Delete the entire block setting `GhosttyBridge.shared.onCommandFinished = ...` and `onEnterKey = ...`. Keep `themeManager.loadFromGhosttyConfig()` and the `onChange(of: store.workspaces)` handler that forgets dead terminal IDs.

Also remove the unused `let store = self.statusStore` if it's no longer referenced anywhere in `onAppear` after this deletion.

- [ ] **Step 5: Build + full test suite**

```
xcodebuild -project TheAll.xcodeproj -scheme TheAll -configuration Debug build 2>&1 | tail -5
xcodebuild test -project TheAll.xcodeproj -scheme TheAllTests 2>&1 | grep -E "(Executed|SUCCEEDED|FAILED)" | tail -5
```

Expected: BUILD SUCCEEDED and test suite still passes (may have slightly fewer tests if any tested the ripped hooks; none do currently).

- [ ] **Step 6: Commit**

```bash
git add TheAll/Ghostty/GhosttyBridge.swift \
        TheAll/Ghostty/GhosttyTerminalView.swift \
        TheAll/ContentView.swift
git commit -m "$(cat <<'EOF'
refactor(status): rip v1 shell-level signal heuristics

Removes the Return-key running-state trigger and OSC 133
COMMAND_FINISHED → onCommandFinished pipeline. These only reflected
outer shell state and were useless for long-running TUI agents.
Replacement is a Unix-socket IPC from agent-specific wrapper hooks
(next tasks).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Render new states in `TerminalStatusIconView`

**Files:**
- Modify: `TheAll/Theme/TerminalStatusIconView.swift`
- Modify: `TheAllTests/TerminalStatusTests.swift`

- [ ] **Step 1: Extend `render()` with idle + needsInput branches**

In `TerminalStatusIconView.render()`, after the existing `.failed` case, add:

```swift
        case .idle:
            // Nearly identical to neverRan visually — distinguishable only via tooltip.
            // Slight opacity tweak to hint "this has history" vs fresh terminal.
            shapeLayer.path = CGPath(ellipseIn: rect, transform: nil)
            shapeLayer.fillColor = NSColor.clear.cgColor
            shapeLayer.strokeColor = theme.textTertiary.withAlphaComponent(0.6).cgColor
            shapeLayer.lineWidth = 1
        case .needsInput:
            // Amber solid fill with a pulse animation. Priority status — draws attention.
            shapeLayer.path = CGPath(ellipseIn: rect, transform: nil)
            shapeLayer.fillColor = theme.accent.cgColor          // ghostty accent; amber-ish in default theme
            shapeLayer.strokeColor = NSColor.clear.cgColor
            shapeLayer.lineWidth = 0
```

- [ ] **Step 2: Extend `update(status:theme:)` animation control**

Replace the existing animation-toggle with a switch:

```swift
        if changedStatusKind {
            stopSpinAnimation()
            stopPulseAnimation()
            switch status {
            case .running:     startSpinAnimation()
            case .needsInput:  startPulseAnimation()
            default:           break
            }
        }
```

Add helpers:

```swift
    private func startPulseAnimation() {
        guard shapeLayer.animation(forKey: "pulse") == nil else { return }
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1.0
        pulse.toValue = 0.35
        pulse.duration = 0.625   // 0.8 Hz breathing (down, then spring back via autoreverse)
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        shapeLayer.add(pulse, forKey: "pulse")
    }

    private func stopPulseAnimation() {
        shapeLayer.removeAnimation(forKey: "pulse")
        shapeLayer.opacity = 1.0
    }
```

And `sameKind` needs new cases:
```swift
    private static func sameKind(_ a: TerminalStatus, _ b: TerminalStatus) -> Bool {
        switch (a, b) {
        case (.neverRan,   .neverRan),
             (.running,    .running),
             (.idle,       .idle),
             (.needsInput, .needsInput),
             (.success,    .success),
             (.failed,     .failed):
            return true
        default:
            return false
        }
    }
```

- [ ] **Step 3: Extend tooltip helpers**

In `TerminalStatusIconView.tooltipText(for:)`, insert cases:

```swift
        case .idle(let since):
            let elapsed = max(0, Date().timeIntervalSince(since))
            return "Idle for \(Self.formatDuration(elapsed))"
        case .needsInput(let since):
            let elapsed = max(0, Date().timeIntervalSince(since))
            return "Needs input (\(Self.formatDuration(elapsed)) ago)"
```

- [ ] **Step 4: Add tooltip-formatter tests**

In `TheAllTests/TerminalStatusTests.swift` (inside the existing tests class), append:

```swift
    func testTooltipIdleAndNeedsInput() {
        let now = Date()
        XCTAssertTrue(TerminalStatusIconView.tooltipText(for: .idle(since: now))?.hasPrefix("Idle for") == true)
        XCTAssertTrue(TerminalStatusIconView.tooltipText(for: .needsInput(since: now))?.hasPrefix("Needs input") == true)
    }
```

- [ ] **Step 5: Build + test**

```
xcodebuild -project TheAll.xcodeproj -scheme TheAll -configuration Debug build 2>&1 | tail -5
xcodebuild test -project TheAll.xcodeproj -scheme TheAllTests -only-testing:TheAllTests/TerminalStatusTests 2>&1 | tail -10
```

Expected: BUILD SUCCEEDED, all tests pass.

- [ ] **Step 6: Commit**

```bash
git add TheAll/Theme/TerminalStatusIconView.swift TheAllTests/TerminalStatusTests.swift
git commit -m "$(cat <<'EOF'
feat(ui): render idle and needsInput status icons

idle uses a dimmer variant of the neverRan outline; needsInput is a
solid amber dot with 0.8 Hz pulse animation to draw attention.
Tooltips updated to cover all six states.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Hook message data model + parser

**Files:**
- Create: `TheAll/Models/HookMessage.swift`
- Create: `TheAllTests/HookMessageTests.swift`

- [ ] **Step 1: Write failing tests for JSON decoding**

```swift
// TheAllTests/HookMessageTests.swift
import XCTest
@testable import TheAll

final class HookMessageTests: XCTestCase {

    func testDecodeRunning() throws {
        let json = """
        {"terminalId":"550E8400-E29B-41D4-A716-446655440000","event":"running","agent":"claude","at":1713345678.5}
        """.data(using: .utf8)!
        let msg = try JSONDecoder().decode(HookMessage.self, from: json)
        XCTAssertEqual(msg.terminalId, UUID(uuidString: "550E8400-E29B-41D4-A716-446655440000"))
        XCTAssertEqual(msg.event, .running)
        XCTAssertEqual(msg.agent, .claude)
    }

    func testDecodeIdleShell() throws {
        let json = #"{"terminalId":"550E8400-E29B-41D4-A716-446655440000","event":"idle","agent":"shell","at":1}"#.data(using: .utf8)!
        let msg = try JSONDecoder().decode(HookMessage.self, from: json)
        XCTAssertEqual(msg.event, .idle)
        XCTAssertEqual(msg.agent, .shell)
    }

    func testDecodeUnknownAgentFails() {
        let json = #"{"terminalId":"550E8400-E29B-41D4-A716-446655440000","event":"idle","agent":"cursor","at":1}"#.data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(HookMessage.self, from: json))
    }

    func testDecodeNeedsInput() throws {
        let json = #"{"terminalId":"550E8400-E29B-41D4-A716-446655440000","event":"needsInput","agent":"opencode","at":2}"#.data(using: .utf8)!
        let msg = try JSONDecoder().decode(HookMessage.self, from: json)
        XCTAssertEqual(msg.event, .needsInput)
    }

    func testDecodeWithOptionalMeta() throws {
        let json = #"{"terminalId":"550E8400-E29B-41D4-A716-446655440000","event":"running","agent":"codex","at":1,"meta":{"tool":"shell"}}"#.data(using: .utf8)!
        let msg = try JSONDecoder().decode(HookMessage.self, from: json)
        XCTAssertEqual(msg.agent, .codex)
    }
}
```

- [ ] **Step 2: Implement `HookMessage`**

```swift
// TheAll/Models/HookMessage.swift
import Foundation

/// Message sent by a shell/agent hook to the theall Unix socket.
/// Format: one message per newline, UTF-8 JSON.
struct HookMessage: Decodable, Equatable {
    enum Event: String, Decodable {
        case running
        case idle
        case needsInput
    }

    enum Agent: String, Decodable {
        case shell
        case claude
        case opencode
        case codex
    }

    let terminalId: UUID
    let event: Event
    let agent: Agent
    let at: TimeInterval

    var timestamp: Date { Date(timeIntervalSince1970: at) }
}
```

- [ ] **Step 3: Run tests — all pass**

Run: `xcodebuild test -project TheAll.xcodeproj -scheme TheAllTests -only-testing:TheAllTests/HookMessageTests 2>&1 | tail -10`

- [ ] **Step 4: Commit**

```bash
git add TheAll/Models/HookMessage.swift TheAllTests/HookMessageTests.swift
git commit -m "$(cat <<'EOF'
feat(models): add HookMessage for Unix-socket hook IPC

Three events (running/idle/needsInput) × four agents (shell/claude/
opencode/codex). Newline-delimited JSON on the wire.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: `HookSocketListener` — Unix socket server

**Files:**
- Create: `TheAll/Models/HookSocketListener.swift`
- Create: `TheAllTests/HookSocketListenerTests.swift`

- [ ] **Step 1: Write a test that sends a message over a real Unix socket and expects the listener callback to fire**

```swift
// TheAllTests/HookSocketListenerTests.swift
import XCTest
@testable import TheAll

final class HookSocketListenerTests: XCTestCase {

    func testReceivesSingleMessage() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("theall-test-\(UUID().uuidString).sock")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let listener = try HookSocketListener(path: tmp.path)
        let received = XCTestExpectation(description: "message delivered")
        listener.onMessage = { msg in
            XCTAssertEqual(msg.event, .running)
            XCTAssertEqual(msg.agent, .claude)
            received.fulfill()
        }
        try listener.start()
        defer { listener.stop() }

        // Connect + write one line
        let client = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThan(client, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        _ = tmp.path.withCString { src in
            withUnsafeMutablePointer(to: &addr.sun_path) {
                $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: $0.pointee)) { dst in
                    strncpy(dst, src, MemoryLayout.size(ofValue: $0.pointee) - 1)
                }
            }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(client, $0, size)
            }
        }
        XCTAssertEqual(ok, 0)
        let tid = UUID()
        let payload = #"{"terminalId":"\#(tid.uuidString)","event":"running","agent":"claude","at":1}"# + "\n"
        _ = payload.withCString { Darwin.send(client, $0, strlen($0), 0) }
        close(client)

        wait(for: [received], timeout: 2)
    }

    func testMultipleMessagesOnSameConnection() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("theall-test-\(UUID().uuidString).sock")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let listener = try HookSocketListener(path: tmp.path)
        var count = 0
        let done = XCTestExpectation(description: "two messages")
        listener.onMessage = { _ in
            count += 1
            if count == 2 { done.fulfill() }
        }
        try listener.start()
        defer { listener.stop() }

        let client = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        _ = tmp.path.withCString { src in
            withUnsafeMutablePointer(to: &addr.sun_path) {
                $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: $0.pointee)) { dst in
                    strncpy(dst, src, MemoryLayout.size(ofValue: $0.pointee) - 1)
                }
            }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        _ = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(client, $0, size)
            }
        }
        let tid = UUID().uuidString
        let two = #"{"terminalId":"\#(tid)","event":"running","agent":"shell","at":1}"# + "\n"
                + #"{"terminalId":"\#(tid)","event":"idle","agent":"shell","at":2}"# + "\n"
        _ = two.withCString { Darwin.send(client, $0, strlen($0), 0) }
        close(client)

        wait(for: [done], timeout: 2)
        XCTAssertEqual(count, 2)
    }
}
```

- [ ] **Step 2: Implement `HookSocketListener`**

```swift
// TheAll/Models/HookSocketListener.swift
import Foundation
import Darwin

/// Unix domain socket server that receives newline-delimited JSON hook messages
/// from shell/agent wrappers and dispatches them to `onMessage`.
///
/// Lifetime: create once per app, call `start()` at launch, `stop()` at termination.
/// The listener runs on its own background queue; `onMessage` is called on main.
final class HookSocketListener {
    let path: String
    var onMessage: ((HookMessage) -> Void)?

    private var listenFd: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var clientSources: [Int32: DispatchSourceRead] = [:]
    private var clientBuffers: [Int32: Data] = [:]
    private let queue = DispatchQueue(label: "theall.hookSocket", qos: .userInitiated)

    init(path: String) throws {
        self.path = path
    }

    func start() throws {
        // Ensure parent dir exists
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        // Remove stale socket file
        unlink(path)

        listenFd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFd >= 0 else {
            throw NSError(domain: "HookSocketListener", code: Int(errno),
                          userInfo: [NSLocalizedDescriptionKey: "socket() failed"])
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        _ = path.withCString { src in
            withUnsafeMutablePointer(to: &addr.sun_path) {
                $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: $0.pointee)) { dst in
                    strncpy(dst, src, MemoryLayout.size(ofValue: $0.pointee) - 1)
                }
            }
        }

        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bindOK = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listenFd, $0, size)
            }
        }
        guard bindOK == 0 else {
            close(listenFd); listenFd = -1
            throw NSError(domain: "HookSocketListener", code: Int(errno),
                          userInfo: [NSLocalizedDescriptionKey: "bind() failed"])
        }

        guard Darwin.listen(listenFd, 32) == 0 else {
            close(listenFd); listenFd = -1
            throw NSError(domain: "HookSocketListener", code: Int(errno),
                          userInfo: [NSLocalizedDescriptionKey: "listen() failed"])
        }

        let source = DispatchSource.makeReadSource(fileDescriptor: listenFd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptClient() }
        source.setCancelHandler { [weak self] in
            if let self, self.listenFd >= 0 { close(self.listenFd); self.listenFd = -1 }
        }
        source.resume()
        acceptSource = source
    }

    func stop() {
        acceptSource?.cancel()
        acceptSource = nil
        clientSources.values.forEach { $0.cancel() }
        clientSources.removeAll()
        clientBuffers.removeAll()
        unlink(path)
    }

    private func acceptClient() {
        let client = Darwin.accept(listenFd, nil, nil)
        guard client >= 0 else { return }
        clientBuffers[client] = Data()

        let src = DispatchSource.makeReadSource(fileDescriptor: client, queue: queue)
        src.setEventHandler { [weak self] in self?.readClient(fd: client) }
        src.setCancelHandler { [weak self] in
            close(client)
            self?.clientBuffers.removeValue(forKey: client)
            self?.clientSources.removeValue(forKey: client)
        }
        clientSources[client] = src
        src.resume()
    }

    private func readClient(fd: Int32) {
        var buf = [UInt8](repeating: 0, count: 4096)
        let n = read(fd, &buf, buf.count)
        if n <= 0 {
            clientSources[fd]?.cancel()
            return
        }
        clientBuffers[fd, default: Data()].append(buf, count: n)
        flushBuffer(fd: fd)
    }

    private func flushBuffer(fd: Int32) {
        guard var buf = clientBuffers[fd] else { return }
        while let newlineIdx = buf.firstIndex(of: 0x0a) {
            let line = buf.subdata(in: 0..<newlineIdx)
            buf.removeSubrange(0...newlineIdx)
            guard !line.isEmpty else { continue }
            if let msg = try? JSONDecoder().decode(HookMessage.self, from: line) {
                DispatchQueue.main.async { [weak self] in self?.onMessage?(msg) }
            }
            // On decode failure: silently drop. Hook scripts are our own code;
            // garbled input means someone else is writing to our socket → ignore.
        }
        clientBuffers[fd] = buf
    }

    deinit { stop() }
}
```

- [ ] **Step 3: Run tests**

```
xcodebuild test -project TheAll.xcodeproj -scheme TheAllTests -only-testing:TheAllTests/HookSocketListenerTests 2>&1 | tail -15
```

Expected: 2 tests pass within 2s timeout each. If they flake, increase the timeout and investigate — but socket accept + read on a local Unix socket should be ~1ms.

- [ ] **Step 4: Commit**

```bash
git add TheAll/Models/HookSocketListener.swift TheAllTests/HookSocketListenerTests.swift
git commit -m "$(cat <<'EOF'
feat(models): Unix-socket listener for hook IPC

DispatchSourceRead on AF_UNIX stream socket. Parses newline-delimited
JSON, dispatches HookMessage to onMessage on main queue. Handles
multiple clients and multi-message connections.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: Wire listener in `ContentView` + inject env vars on surface creation

**Files:**
- Modify: `TheAll/ContentView.swift`
- Modify: `TheAll/Ghostty/GhosttyBridge.swift`
- Modify: `TheAll/Ghostty/GhosttyTerminalView.swift`

- [ ] **Step 1: Decide the socket path**

We use `~/Library/Caches/theall/hooks.sock`. Put a static helper on `HookSocketListener`:

```swift
extension HookSocketListener {
    static var defaultPath: String {
        let cache = (NSHomeDirectory() as NSString).appendingPathComponent("Library/Caches/theall")
        return (cache as NSString).appendingPathComponent("hooks.sock")
    }
}
```

- [ ] **Step 2: Start listener in `ContentView.onAppear`**

Add to `ContentView`:

```swift
    @State private var hookListener: HookSocketListener?
```

Extend `.onAppear`:

```swift
        .onAppear {
            themeManager.loadFromGhosttyConfig()
            if hookListener == nil {
                let path = HookSocketListener.defaultPath
                setenv("THEALL_HOOK_SOCK", path, 1)
                do {
                    let listener = try HookSocketListener(path: path)
                    listener.onMessage = { [weak statusStore = self.statusStore] msg in
                        guard let statusStore else { return }
                        switch msg.event {
                        case .running:    statusStore.setRunning(terminalId: msg.terminalId, at: msg.timestamp)
                        case .idle:       statusStore.setIdle(terminalId: msg.terminalId, at: msg.timestamp)
                        case .needsInput: statusStore.setNeedsInput(terminalId: msg.terminalId, at: msg.timestamp)
                        }
                    }
                    try listener.start()
                    hookListener = listener
                } catch {
                    print("[theall] Failed to start hook socket listener: \(error)")
                }
            }
        }
```

(`@State private var statusStore = TerminalStatusStore()` already exists; the `weak` capture is illustrative — since TerminalStatusStore is a class held by `@State`, strong capture is fine and there's no retain cycle here. Drop the `[weak ...]` if Swift warns.)

- [ ] **Step 3: Inject `THEALL_TERMINAL_ID` per surface via ghostty_surface_config_s**

In `GhosttyBridge.newSurface(nsView:scaleFactor:workingDirectory:)`, the current code sets `working_directory`. We need to add a UUID string env var. First check whether `ghostty_surface_config_s` exposes an env-var field.

Grep: `grep -A 20 'ghostty_surface_config_s ' Vendor/ghostty/include/ghostty.h`

If the struct has `env_vars` (array) or similar, use it. If not, **fall back** to setenv before calling newSurface (within a serial critical section so two concurrent surface creations don't race):

```swift
    private static let envLock = NSLock()

    func newSurface(nsView: NSView, scaleFactor: Double, workingDirectory: String?, terminalId: UUID) -> ghostty_surface_t? {
        guard isInitialized, let appHandle = app else { return nil }
        Self.envLock.lock()
        defer { Self.envLock.unlock() }

        setenv("THEALL_TERMINAL_ID", terminalId.uuidString, 1)

        var surfCfg = ghostty_surface_config_new()
        surfCfg.scale_factor = scaleFactor
        if let wd = workingDirectory {
            surfCfg.working_directory = (wd as NSString).utf8String
        }
        surfCfg.platform_tag = GHOSTTY_PLATFORM_MACOS
        surfCfg.platform.macos.nsview = Unmanaged.passUnretained(nsView).toOpaque()

        return ghostty_surface_new(appHandle, &surfCfg)
    }
```

- [ ] **Step 4: Update the caller**

In `GhosttyTerminalView.viewDidMoveToWindow`, change the `newSurface` call to pass `terminalId`:

```swift
            surface = GhosttyBridge.shared.newSurface(
                nsView: self,
                scaleFactor: scale,
                workingDirectory: nil,
                terminalId: terminalId ?? UUID()
            )
```

(`terminalId` property was added in v1 Task 7.)

- [ ] **Step 5: Build + test**

```
xcodebuild -project TheAll.xcodeproj -scheme TheAll -configuration Debug build 2>&1 | tail -5
xcodebuild test -project TheAll.xcodeproj -scheme TheAllTests 2>&1 | grep -E "(Executed|SUCCEEDED|FAILED)" | tail -3
```

Expected: BUILD SUCCEEDED, all tests pass.

- [ ] **Step 6: Manual sanity: open the app, open a terminal, `env | grep THEALL` should show both variables.**

(User will do this after all tasks merge; don't block on it here.)

- [ ] **Step 7: Commit**

```bash
git add TheAll/ContentView.swift \
        TheAll/Ghostty/GhosttyBridge.swift \
        TheAll/Ghostty/GhosttyTerminalView.swift \
        TheAll/Models/HookSocketListener.swift
git commit -m "$(cat <<'EOF'
feat(status): wire hook socket listener and inject env vars per surface

ContentView starts HookSocketListener at startup and routes messages
to TerminalStatusStore. Each new ghostty surface inherits
THEALL_HOOK_SOCK and THEALL_TERMINAL_ID so child shells/agents know
where to send and how to identify themselves.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 8: Hook emit utility + shell-level preexec/precmd hooks

**Files:**
- Create: `Resources/agent-hooks/hook-emit.sh`
- Create: `Resources/agent-hooks/shell-hooks.zsh`
- Create: `Resources/agent-hooks/shell-hooks.bash`
- Create: `Resources/agent-hooks/shell-hooks.fish`
- Modify: `project.yml` (extend the postBuildScripts copy phase)

All scripts are written from scratch.

- [ ] **Step 1: `Resources/agent-hooks/hook-emit.sh`**

```bash
#!/bin/bash
# hook-emit.sh — emit a hook JSON line to $THEALL_HOOK_SOCK
# Usage: hook-emit.sh <event> <agent> [key=val ...]
# event:  running | idle | needsInput
# agent:  shell | claude | opencode | codex

set -e

if [ -z "$THEALL_HOOK_SOCK" ] || [ -z "$THEALL_TERMINAL_ID" ]; then
    exit 0   # silently no-op outside theall
fi

event="$1"
agent="$2"
shift 2 || true

# epoch seconds with fractional part (date %s.%N is Linux-only; use python for portability)
now=$(python3 -c 'import time; print(time.time())' 2>/dev/null || echo "$(date +%s).0")

payload="{\"terminalId\":\"$THEALL_TERMINAL_ID\",\"event\":\"$event\",\"agent\":\"$agent\",\"at\":$now}"

# Deliver via /dev/tcp is not supported for AF_UNIX; use python to open a Unix socket.
python3 - "$THEALL_HOOK_SOCK" "$payload" <<'PY' 2>/dev/null || true
import sys, socket
sock_path, payload = sys.argv[1], sys.argv[2]
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.settimeout(0.5)
try:
    s.connect(sock_path)
    s.sendall((payload + "\n").encode())
finally:
    s.close()
PY
```

Make executable:
```
chmod +x Resources/agent-hooks/hook-emit.sh
```

- [ ] **Step 2: `Resources/agent-hooks/shell-hooks.zsh`**

```zsh
# shell-hooks.zsh — theall shell-level status hooks for zsh
# Source this from your zshrc (or from theall's shell-integration bootstrap).

# Guard: only run inside theall
[ -z "$THEALL_HOOK_SOCK" ] && return 0
[ -z "$THEALL_TERMINAL_ID" ] && return 0

_THEALL_HOOK_EMIT="${THEALL_AGENT_HOOKS_DIR:-$(dirname "${(%):-%x}")}/hook-emit.sh"

# Idempotent guard against double-sourcing
[ -n "$_THEALL_SHELL_HOOKS_INSTALLED" ] && return 0
_THEALL_SHELL_HOOKS_INSTALLED=1

_theall_preexec() {
    "$_THEALL_HOOK_EMIT" running shell &!
}

_theall_precmd() {
    "$_THEALL_HOOK_EMIT" idle shell &!
}

autoload -Uz add-zsh-hook
add-zsh-hook preexec _theall_preexec
add-zsh-hook precmd _theall_precmd
```

- [ ] **Step 3: `Resources/agent-hooks/shell-hooks.bash`**

```bash
# shell-hooks.bash — theall shell-level status hooks for bash
# Source this from your bashrc (or theall's bootstrap).

[ -z "$THEALL_HOOK_SOCK" ] && return 0
[ -z "$THEALL_TERMINAL_ID" ] && return 0

_THEALL_HOOK_EMIT="${THEALL_AGENT_HOOKS_DIR:-$(dirname "${BASH_SOURCE[0]}")}/hook-emit.sh"

[ -n "$_THEALL_SHELL_HOOKS_INSTALLED" ] && return 0
_THEALL_SHELL_HOOKS_INSTALLED=1

_theall_preexec() {
    # $BASH_COMMAND is the command about to be executed
    # Only fire for interactive commands, not PROMPT_COMMAND itself
    [[ "$BASH_COMMAND" == "$PROMPT_COMMAND" ]] && return
    "$_THEALL_HOOK_EMIT" running shell >/dev/null 2>&1 &
}

_theall_precmd() {
    "$_THEALL_HOOK_EMIT" idle shell >/dev/null 2>&1 &
}

trap '_theall_preexec' DEBUG
PROMPT_COMMAND="_theall_precmd${PROMPT_COMMAND:+; $PROMPT_COMMAND}"
```

- [ ] **Step 4: `Resources/agent-hooks/shell-hooks.fish`**

```fish
# shell-hooks.fish — theall shell-level status hooks for fish
# Source this from config.fish (or theall's bootstrap).

test -z "$THEALL_HOOK_SOCK"; and return 0
test -z "$THEALL_TERMINAL_ID"; and return 0

if not set -q THEALL_AGENT_HOOKS_DIR
    set -g THEALL_AGENT_HOOKS_DIR (dirname (status -f))
end
set -g _THEALL_HOOK_EMIT "$THEALL_AGENT_HOOKS_DIR/hook-emit.sh"

if set -q _THEALL_SHELL_HOOKS_INSTALLED
    return 0
end
set -g _THEALL_SHELL_HOOKS_INSTALLED 1

function _theall_preexec --on-event fish_preexec
    $_THEALL_HOOK_EMIT running shell >/dev/null 2>&1 &; disown
end

function _theall_precmd --on-event fish_prompt
    $_THEALL_HOOK_EMIT idle shell >/dev/null 2>&1 &; disown
end
```

- [ ] **Step 5: Extend `project.yml` copy phase**

The existing postBuildScripts copies `Vendor/ghostty/share/ghostty`. Add a second script (or extend the existing one) to also copy `Resources/agent-hooks/`:

```yaml
    postBuildScripts:
      - name: Copy ghostty resources
        script: |
          mkdir -p "$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/ghostty"
          cp -R "$SRCROOT/Vendor/ghostty/share/ghostty/" "$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/ghostty/"
      - name: Copy theall agent hooks
        script: |
          mkdir -p "$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/agent-hooks"
          cp -R "$SRCROOT/Resources/agent-hooks/" "$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/agent-hooks/"
          chmod +x "$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/agent-hooks/"*.sh
```

(The exact existing script name may differ — open project.yml, identify the existing phase, extend appropriately.)

Run: `xcodegen generate`

- [ ] **Step 6: Build; inspect bundle**

```
xcodebuild -project TheAll.xcodeproj -scheme TheAll -configuration Debug build 2>&1 | tail -5
APP=$(find ~/Library/Developer/Xcode/DerivedData -name "TheAll.app" -type d 2>/dev/null | head -1)
ls "$APP/Contents/Resources/agent-hooks/"
```

Expected: `hook-emit.sh shell-hooks.bash shell-hooks.fish shell-hooks.zsh` listed.

- [ ] **Step 7: Commit**

```bash
git add Resources/agent-hooks/hook-emit.sh \
        Resources/agent-hooks/shell-hooks.zsh \
        Resources/agent-hooks/shell-hooks.bash \
        Resources/agent-hooks/shell-hooks.fish \
        project.yml \
        TheAll.xcodeproj/project.pbxproj
git commit -m "$(cat <<'EOF'
feat(hooks): shell-level preexec/precmd hooks + emit utility

zsh/bash/fish each install their native command-start / prompt-return
hooks that emit running/idle JSON via a Python-based Unix-socket
writer. Ships alongside the app in Contents/Resources/agent-hooks/.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 9: Bootstrap shell-integration to source our hooks

**Files:**
- Create: `Resources/agent-hooks/bootstrap.zsh`
- Create: `Resources/agent-hooks/bootstrap.bash`
- Create: `Resources/agent-hooks/bootstrap.fish`
- Modify: `TheAll/Ghostty/GhosttyBridge.swift`

The user's shell needs to source our bootstrap at startup. ghostty's shell-integration already does its own startup injection — we add ours via env var `ZDOTDIR` / `BASH_ENV` / `XDG_CONFIG_HOME`, or more simply by having ghostty's shell-integration chain-source ours.

Simpler approach: exploit ghostty's own shell-integration, which is loaded if `resources-dir` is set. Ghostty runs its zsh hook from `share/ghostty/shell-integration/zsh/ghostty-integration`. We'd need to either fork that file or inject via a separate mechanism.

Cleanest mechanism without modifying ghostty's scripts: **`ENV`/`ZDOTDIR` override**. Set per-surface env var `THEALL_BOOTSTRAP` to the path of our bootstrap, and have ghostty's startup script source it. Since we can't modify ghostty's script, go with **prepend to BASH_ENV / use a zdotdir shim**:

Safer & simpler: **patch our own shell integration layer**. Create `Resources/agent-hooks/zshrc-shim.zsh` that is a zsh startup that sources both ghostty's integration AND ours, then point `ZDOTDIR` to a temp dir containing this shim.

Actually, simplest and most reliable: set `THEALL_AGENT_HOOKS_DIR` env var, and have every user either (a) source it manually in their rc (undesirable) or (b) we inject via PROMPT_COMMAND / equivalent at ghostty's surface creation.

Given the complexity, the pragmatic path is:
1. Copy our bootstrap scripts to `Contents/Resources/agent-hooks/`
2. Set per-surface env var `THEALL_AGENT_HOOKS_DIR=<bundle path>`
3. Ask the user to add ONE line to their rc (document this in the README): `source "$THEALL_AGENT_HOOKS_DIR/bootstrap.zsh" 2>/dev/null`

This is acceptable for a v2 feature — fully automatic injection is a separate refactor.

- [ ] **Step 1: Create bootstrap scripts**

`Resources/agent-hooks/bootstrap.zsh`:
```zsh
# bootstrap.zsh — source this from ~/.zshrc to enable theall status hooks:
#   source "$THEALL_AGENT_HOOKS_DIR/bootstrap.zsh" 2>/dev/null
[ -z "$THEALL_AGENT_HOOKS_DIR" ] && return 0
source "$THEALL_AGENT_HOOKS_DIR/shell-hooks.zsh"
source "$THEALL_AGENT_HOOKS_DIR/agent-functions.zsh"
```

`Resources/agent-hooks/bootstrap.bash`:
```bash
# bootstrap.bash — source this from ~/.bashrc.
[ -z "$THEALL_AGENT_HOOKS_DIR" ] && return 0
source "$THEALL_AGENT_HOOKS_DIR/shell-hooks.bash"
source "$THEALL_AGENT_HOOKS_DIR/agent-functions.bash"
```

`Resources/agent-hooks/bootstrap.fish`:
```fish
# bootstrap.fish — source this from ~/.config/fish/config.fish
test -z "$THEALL_AGENT_HOOKS_DIR"; and return 0
source "$THEALL_AGENT_HOOKS_DIR/shell-hooks.fish"
source "$THEALL_AGENT_HOOKS_DIR/agent-functions.fish"
```

- [ ] **Step 2: Wire `THEALL_AGENT_HOOKS_DIR` in `GhosttyBridge.initialize()`**

After the resources-dir load block, add:

```swift
        // Also export the theall agent-hooks dir so child shells can bootstrap our hooks
        // (user must source "$THEALL_AGENT_HOOKS_DIR/bootstrap.{zsh,bash,fish}" from their rc).
        if let resourcesPath = Bundle.main.resourcePath {
            let hooksDir = (resourcesPath as NSString).appendingPathComponent("agent-hooks")
            if FileManager.default.fileExists(atPath: hooksDir) {
                setenv("THEALL_AGENT_HOOKS_DIR", hooksDir, 1)
            }
        }
```

- [ ] **Step 3: Build + verify env in a running shell**

```
xcodebuild -project TheAll.xcodeproj -scheme TheAll -configuration Debug build 2>&1 | tail -3
```

Manual verify step (user does):
```
# In a theall terminal
env | grep THEALL
# Should show THEALL_HOOK_SOCK, THEALL_TERMINAL_ID, THEALL_AGENT_HOOKS_DIR
```

- [ ] **Step 4: Commit bootstrap + export**

```bash
git add Resources/agent-hooks/bootstrap.zsh \
        Resources/agent-hooks/bootstrap.bash \
        Resources/agent-hooks/bootstrap.fish \
        TheAll/Ghostty/GhosttyBridge.swift
git commit -m "$(cat <<'EOF'
feat(hooks): bootstrap scripts + THEALL_AGENT_HOOKS_DIR env export

User sources "$THEALL_AGENT_HOOKS_DIR/bootstrap.zsh" (or .bash/.fish)
from their shell rc. Bootstrap chains to shell-hooks + agent-functions.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 10: Claude Code wrapper + agent-functions overrides

**Files:**
- Create: `Resources/agent-hooks/claude-wrapper.sh`
- Create: `Resources/agent-hooks/agent-functions.zsh`
- Create: `Resources/agent-hooks/agent-functions.bash`
- Create: `Resources/agent-hooks/agent-functions.fish`

- [ ] **Step 1: `claude-wrapper.sh`**

Written from scratch:

```bash
#!/bin/bash
# claude-wrapper.sh — launch Claude Code with theall lifecycle hooks injected.
# Reads THEALL_AGENT_HOOKS_DIR, THEALL_HOOK_SOCK, THEALL_TERMINAL_ID from env.

set -e

# Find the real claude binary: skip any shell function / wrapper; pick the first
# filesystem claude that isn't our own wrapper.
REAL_CLAUDE=""
for candidate in $(which -a claude 2>/dev/null); do
    # Resolve symlinks; skip if the resolved path is this file
    resolved=$(readlink -f "$candidate" 2>/dev/null || echo "$candidate")
    case "$resolved" in
        *theall*agent-hooks*claude-wrapper*) continue ;;
    esac
    REAL_CLAUDE="$candidate"
    break
done

if [ -z "$REAL_CLAUDE" ]; then
    echo "theall: real 'claude' binary not found in PATH" >&2
    exit 127
fi

# If theall env is missing, just passthrough — no hook injection.
if [ -z "$THEALL_AGENT_HOOKS_DIR" ] || [ -z "$THEALL_HOOK_SOCK" ] || [ -z "$THEALL_TERMINAL_ID" ]; then
    exec "$REAL_CLAUDE" "$@"
fi

EMIT="$THEALL_AGENT_HOOKS_DIR/hook-emit.sh"

# Build Claude Code --settings JSON. Hooks run the emit script with event+agent args.
SETTINGS_JSON=$(cat <<EOF
{
  "hooks": {
    "UserPromptSubmit": [{"command": "$EMIT running claude"}],
    "PreToolUse":       [{"command": "$EMIT running claude"}],
    "Stop":             [{"command": "$EMIT idle claude"}],
    "Notification":     [{"command": "$EMIT needsInput claude"}],
    "SessionEnd":       [{"command": "$EMIT idle claude"}]
  }
}
EOF
)

exec "$REAL_CLAUDE" --settings "$SETTINGS_JSON" "$@"
```

chmod +x.

- [ ] **Step 2: `agent-functions.zsh`**

```zsh
# agent-functions.zsh — override agent CLI names to point at our wrappers.
[ -z "$THEALL_AGENT_HOOKS_DIR" ] && return 0

claude()   { command "$THEALL_AGENT_HOOKS_DIR/claude-wrapper.sh"   "$@" }
opencode() { command "$THEALL_AGENT_HOOKS_DIR/opencode-wrapper.sh" "$@" }
codex()    { command "$THEALL_AGENT_HOOKS_DIR/codex-wrapper.sh"    "$@" }
```

- [ ] **Step 3: `agent-functions.bash`**

```bash
# agent-functions.bash
[ -z "$THEALL_AGENT_HOOKS_DIR" ] && return 0

claude()   { command "$THEALL_AGENT_HOOKS_DIR/claude-wrapper.sh"   "$@"; }
opencode() { command "$THEALL_AGENT_HOOKS_DIR/opencode-wrapper.sh" "$@"; }
codex()    { command "$THEALL_AGENT_HOOKS_DIR/codex-wrapper.sh"    "$@"; }
```

- [ ] **Step 4: `agent-functions.fish`**

```fish
# agent-functions.fish
test -z "$THEALL_AGENT_HOOKS_DIR"; and return 0

function claude
    command "$THEALL_AGENT_HOOKS_DIR/claude-wrapper.sh" $argv
end

function opencode
    command "$THEALL_AGENT_HOOKS_DIR/opencode-wrapper.sh" $argv
end

function codex
    command "$THEALL_AGENT_HOOKS_DIR/codex-wrapper.sh" $argv
end
```

- [ ] **Step 5: Build + bundle check**

```
xcodebuild -project TheAll.xcodeproj -scheme TheAll -configuration Debug build 2>&1 | tail -3
APP=$(find ~/Library/Developer/Xcode/DerivedData -name "TheAll.app" -type d 2>/dev/null | head -1)
ls "$APP/Contents/Resources/agent-hooks/"
```

Expected list: `agent-functions.bash bootstrap.bash claude-wrapper.sh ... shell-hooks.zsh`.

- [ ] **Step 6: Commit**

```bash
git add Resources/agent-hooks/claude-wrapper.sh \
        Resources/agent-hooks/agent-functions.zsh \
        Resources/agent-hooks/agent-functions.bash \
        Resources/agent-hooks/agent-functions.fish
git commit -m "$(cat <<'EOF'
feat(hooks): Claude Code wrapper + shell function overrides

claude-wrapper.sh injects --settings JSON with UserPromptSubmit /
PreToolUse / Stop / Notification / SessionEnd hooks mapped to our
emit script. agent-functions.{zsh,bash,fish} hijack the `claude`
command name at shell-function resolution time.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 11: opencode wrapper + plugin

**Files:**
- Create: `Resources/agent-hooks/opencode-wrapper.sh`
- Create: `Resources/agent-hooks/opencode-plugin/theall-status.js`

- [ ] **Step 1: `opencode-plugin/theall-status.js`** (written from scratch):

```javascript
// theall-status.js — opencode plugin that forwards lifecycle events to theall via Unix socket.
// Subscribes to session.idle / tool.execute.before / permission.asked.

const net = require("net");

const SOCK  = process.env.THEALL_HOOK_SOCK;
const TID   = process.env.THEALL_TERMINAL_ID;

function emit(event) {
    if (!SOCK || !TID) return;
    const payload = JSON.stringify({
        terminalId: TID,
        event,
        agent: "opencode",
        at: Date.now() / 1000,
    }) + "\n";
    const client = net.createConnection(SOCK);
    client.on("error", () => {});
    client.on("connect", () => {
        client.end(payload);
    });
}

// opencode plugin entry point
module.exports = {
    async init({ bus }) {
        bus.on("tool.execute.before",    () => emit("running"));
        bus.on("permission.asked",       () => emit("needsInput"));
        bus.on("permission.replied",     () => emit("running"));
        bus.on("session.idle",           () => emit("idle"));
        bus.on("session.error",          () => emit("idle"));
    }
};
```

**Note:** The exact plugin API shape (module.exports vs default export, bus.on vs an `events` subscription object) depends on the opencode version you're targeting. Cross-check against current opencode docs at implementation time — if the subscribe mechanism differs, adapt the code structure but keep the event-name → emit-call mapping unchanged.

- [ ] **Step 2: `opencode-wrapper.sh`**:

```bash
#!/bin/bash
# opencode-wrapper.sh — launch opencode with theall status plugin installed.

set -e

REAL_OPENCODE=""
for candidate in $(which -a opencode 2>/dev/null); do
    resolved=$(readlink -f "$candidate" 2>/dev/null || echo "$candidate")
    case "$resolved" in
        *theall*agent-hooks*opencode-wrapper*) continue ;;
    esac
    REAL_OPENCODE="$candidate"
    break
done

if [ -z "$REAL_OPENCODE" ]; then
    echo "theall: real 'opencode' binary not found in PATH" >&2
    exit 127
fi

if [ -z "$THEALL_AGENT_HOOKS_DIR" ] || [ -z "$THEALL_HOOK_SOCK" ] || [ -z "$THEALL_TERMINAL_ID" ]; then
    exec "$REAL_OPENCODE" "$@"
fi

# Create a session-scoped plugin dir that layers on top of whatever the user has.
# Prefer project-local .opencode/plugins if present; else a temp dir.
PLUGIN_SRC="$THEALL_AGENT_HOOKS_DIR/opencode-plugin/theall-status.js"
SESSION_DIR=$(mktemp -d -t theall-opencode.XXXXXX)
mkdir -p "$SESSION_DIR/.opencode/plugins"
cp "$PLUGIN_SRC" "$SESSION_DIR/.opencode/plugins/theall-status.js"

# opencode discovers plugins via ~/.config/opencode/plugins or cwd/.opencode/plugins.
# Force this session to see our plugin by running from SESSION_DIR unless user specified -C.
# However, that would change the agent's working dir — too invasive. Instead, use the
# env var path if opencode supports it (OPENCODE_PLUGIN_DIR or similar).
# Check docs: if present, set it; otherwise symlink into ~/.config/opencode/plugins/.

USER_PLUGINS="$HOME/.config/opencode/plugins"
mkdir -p "$USER_PLUGINS"
LINK="$USER_PLUGINS/theall-status.js"
if [ ! -e "$LINK" ]; then
    ln -s "$PLUGIN_SRC" "$LINK"
fi

exec "$REAL_OPENCODE" "$@"
```

chmod +x.

**Caveat:** this installs our plugin globally for all opencode sessions on this machine, not just from within theall. For v2 MVP that's acceptable — the plugin is a no-op when `THEALL_HOOK_SOCK` is unset.

- [ ] **Step 3: Build + verify**

```
xcodebuild -project TheAll.xcodeproj -scheme TheAll -configuration Debug build 2>&1 | tail -3
APP=$(find ~/Library/Developer/Xcode/DerivedData -name "TheAll.app" -type d 2>/dev/null | head -1)
ls "$APP/Contents/Resources/agent-hooks/opencode-plugin/"
```

Expected: `theall-status.js` present.

- [ ] **Step 4: Commit**

```bash
git add Resources/agent-hooks/opencode-wrapper.sh \
        Resources/agent-hooks/opencode-plugin/theall-status.js
git commit -m "$(cat <<'EOF'
feat(hooks): opencode wrapper + status plugin

opencode-plugin/theall-status.js subscribes to session.idle /
tool.execute.before / permission.asked and emits via Unix socket.
Wrapper installs the plugin to ~/.config/opencode/plugins on first
invocation.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 12: Codex CLI wrapper

**Files:**
- Create: `Resources/agent-hooks/codex-wrapper.sh`

- [ ] **Step 1: `codex-wrapper.sh`** (written from scratch):

```bash
#!/bin/bash
# codex-wrapper.sh — launch OpenAI Codex CLI with theall notify + optional hooks.json.

set -e

REAL_CODEX=""
for candidate in $(which -a codex 2>/dev/null); do
    resolved=$(readlink -f "$candidate" 2>/dev/null || echo "$candidate")
    case "$resolved" in
        *theall*agent-hooks*codex-wrapper*) continue ;;
    esac
    REAL_CODEX="$candidate"
    break
done

if [ -z "$REAL_CODEX" ]; then
    echo "theall: real 'codex' binary not found in PATH" >&2
    exit 127
fi

if [ -z "$THEALL_AGENT_HOOKS_DIR" ] || [ -z "$THEALL_HOOK_SOCK" ] || [ -z "$THEALL_TERMINAL_ID" ]; then
    exec "$REAL_CODEX" "$@"
fi

EMIT="$THEALL_AGENT_HOOKS_DIR/hook-emit.sh"

# Codex reads config from $CODEX_HOME or ~/.codex/config.toml. To avoid clobbering
# the user's existing config we layer an overlay directory.
OVERLAY=$(mktemp -d -t theall-codex.XXXXXX)

# Copy existing user config if present, else seed a minimal file.
USER_HOME="${CODEX_HOME:-$HOME/.codex}"
if [ -f "$USER_HOME/config.toml" ]; then
    cp "$USER_HOME/config.toml" "$OVERLAY/config.toml"
else
    : > "$OVERLAY/config.toml"
fi

# Append notify command. This is the stable interface (turn completion → idle).
cat >> "$OVERLAY/config.toml" <<EOF

# --- theall hooks (added by codex-wrapper.sh) ---
notify = ["$EMIT", "idle", "codex"]
EOF

# Optionally layer hooks.json (experimental). If the user has enabled it, we can
# inject pre-tool-use / user-prompt-submit via $OVERLAY/hooks.json.
cat > "$OVERLAY/hooks.json" <<EOF
{
  "hooks": {
    "UserPromptSubmit": [{"command": "$EMIT running codex"}],
    "PreToolUse":       [{"command": "$EMIT running codex"}],
    "Stop":             [{"command": "$EMIT idle codex"}]
  }
}
EOF

# Point Codex at our overlay
export CODEX_HOME="$OVERLAY"

# Clean up when the wrapped codex exits
cleanup() { rm -rf "$OVERLAY"; }
trap cleanup EXIT

exec "$REAL_CODEX" "$@"
```

chmod +x.

**Notes on Codex mechanics:**
- `notify` is stable and fires once per turn completion → idle transition.
- `hooks.json` is experimental — only fires if the user has enabled the feature flag (`features.codex_hooks = true`). If they haven't, the hooks.json file is silently ignored — no harm done.
- We don't get `needsInput` for Codex without official hook support. Acceptable limitation for v2.

- [ ] **Step 2: Build + verify**

```
xcodebuild -project TheAll.xcodeproj -scheme TheAll -configuration Debug build 2>&1 | tail -3
APP=$(find ~/Library/Developer/Xcode/DerivedData -name "TheAll.app" -type d 2>/dev/null | head -1)
ls "$APP/Contents/Resources/agent-hooks/codex-wrapper.sh"
```

- [ ] **Step 3: Commit**

```bash
git add Resources/agent-hooks/codex-wrapper.sh
git commit -m "$(cat <<'EOF'
feat(hooks): Codex CLI wrapper

Layers a CODEX_HOME overlay that sets notify = [emit, idle, codex]
(stable) and hooks.json with UserPromptSubmit/PreToolUse/Stop
(experimental, only honored when feature flag is on). Cleans up on
exit. needsInput is not available for Codex without official hook
support — known v2 limitation.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Final verification

- [ ] **Step 1: Full test suite**

```
xcodebuild test -project TheAll.xcodeproj -scheme TheAllTests 2>&1 | grep -E "(Executed|SUCCEEDED|FAILED)" | tail -3
```

Expected: all suites pass; new tests count ≥ previous.

- [ ] **Step 2: End-to-end smoke test — user performs these manually**

1. Add this to `~/.zshrc` (or .bashrc / config.fish):
   ```
   source "$THEALL_AGENT_HOOKS_DIR/bootstrap.zsh" 2>/dev/null
   ```
2. Quit+relaunch theall
3. Open a terminal; verify `env | grep THEALL` shows 3 vars
4. Type `ls` + Enter → icon flips running → idle within ~0.5s
5. Type `claude` → icon flips running → idle once Claude Code banner settles → running when you submit a prompt → idle when Claude returns to its prompt → needsInput when Claude asks to run a tool
6. Same tests for `opencode` and `codex`
7. Hover icon at each stage → tooltip is coherent

- [ ] **Step 3: If the smoke test uncovers issues**: loop back to the appropriate task, fix, re-verify. If it all works, you're done.

---

## Known limitations documented for decisions log

1. **Requires user rc edit** — they have to add one line sourcing our bootstrap. Until auto-injection lands, this is the simplest mechanism that doesn't require modifying ghostty's own shell-integration scripts.
2. **Codex needsInput unavailable** — Codex has no official hook for tool-approval request. Can be retrofitted if Codex adds such a hook.
3. **opencode plugin global-installed** — first `opencode` launch symlinks plugin into `~/.config/opencode/plugins/`. Harmless outside theall (plugin no-ops when env missing), but technically a cross-session side effect.
4. **Race on concurrent surface creation** — env-var injection via `setenv` under a lock is serialized; worst case a new surface briefly delays if two open simultaneously. Acceptable.
