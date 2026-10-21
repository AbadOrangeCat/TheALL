# Terminal Status Icon Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add per-terminal status indicators (neverRan/running/success/failed) to tab items and sidebar rows, aggregated up the hierarchy, sourced from ghostty's OSC 133 shell integration.

**Architecture:** New `TerminalStatus` enum + `@Observable TerminalStatusStore` (in-memory only). Ghostty runtime action callback routes `GHOSTTY_ACTION_COMMAND_FINISHED` to the store via a `ghostty_surface_t → UUID` reverse map on `GhosttyTerminalView`. New `TerminalStatusIconView` NSView renders four states (static dot / spinning arc) and mounts into `TabItemView` (left of title) and `WorkspaceRowItemView` (top-right). Bridges subscribe to the store the same way they already subscribe to `WorkspaceMetadata`.

**Tech Stack:** Swift / AppKit / SwiftUI / ghostty C API / XCTest. Depends on ghostty shell-integration scripts being injected into the user's shell — requires one-time Vendor + project.yml changes.

**Design spec:** `docs/superpowers/specs/2026-04-17-terminal-status-icon-design.md`

---

## File Structure

**New files:**
- `TheAll/Models/TerminalStatus.swift` — enum + aggregation reduce
- `TheAll/Models/TerminalStatusStore.swift` — @Observable store
- `TheAll/Theme/TerminalStatusIconView.swift` — NSView (10pt icon, 4 states)
- `TheAllTests/TerminalStatusTests.swift` — enum state transitions + aggregation
- `TheAllTests/TerminalStatusStoreTests.swift` — store mutations

**Modified files:**
- `TheAll/Theme/AppTheme.swift` — add `success` and `danger` tokens
- `TheAll/Ghostty/GhosttyTerminalView.swift` — add `terminalId: UUID?` field + surface→view lookup
- `TheAll/Ghostty/GhosttyBridge.swift` — load resources-dir, route actions through a Swift handler
- `TheAll/TabContent/TabContentView.swift` — assign `terminalId` when minting a `GhosttyTerminalView`
- `TheAll/TabContent/TabBarView.swift` — insert icon into `TabItemView`, extend `update/refresh` signatures with `[UUID: TerminalStatus]`
- `TheAll/Sidebar/WorkspaceListView.swift` — insert icon into `WorkspaceRowItemView`, extend `update/refresh` signatures
- `TheAll/Bridge/TabBridge.swift` — accept `statusStore`, push status dict on `updateNSView`
- `TheAll/Bridge/SidebarListBridge.swift` — accept `statusStore`, push status dict
- `TheAll/Sidebar/SidebarView.swift` — thread `statusStore` through
- `TheAll/ContentView.swift` — own a `@State` `TerminalStatusStore` and inject
- `TheAll/TheAllApp.swift` — nothing to change if store lives in ContentView

**Infrastructure (user-gated):**
- `scripts/build-vendor.sh` — copy `share/ghostty/shell-integration/` out of ghostty build
- `project.yml` — copy-resources phase for the shell-integration dir

---

## Task 1: `TerminalStatus` enum + state-transition tests

**Files:**
- Create: `TheAll/Models/TerminalStatus.swift`
- Create: `TheAllTests/TerminalStatusTests.swift`

- [ ] **Step 1: Write failing tests for four-state model and aggregation reduce**

```swift
// TheAllTests/TerminalStatusTests.swift
import XCTest
@testable import TheAll

final class TerminalStatusTests: XCTestCase {

    func testNeverRanIsDefault() {
        let s: TerminalStatus = .neverRan
        XCTAssertEqual(s, .neverRan)
    }

    func testEqualityIgnoresTimestampDetailsOfRunningStart() {
        let t1 = Date(timeIntervalSince1970: 1000)
        let t2 = Date(timeIntervalSince1970: 2000)
        // Different startedAt values are NOT equal — Equatable is strict
        XCTAssertNotEqual(TerminalStatus.running(startedAt: t1),
                          TerminalStatus.running(startedAt: t2))
    }

    func testAggregateEmptyIsNeverRan() {
        XCTAssertEqual(TerminalStatus.aggregate([]), .neverRan)
    }

    func testAggregateAllNeverRanIsNeverRan() {
        let inputs: [TerminalStatus] = [.neverRan, .neverRan, .neverRan]
        XCTAssertEqual(TerminalStatus.aggregate(inputs), .neverRan)
    }

    func testAggregateAnyRunningBeatsEverything() {
        let now = Date()
        let inputs: [TerminalStatus] = [
            .success(exitCode: 0, duration: 1, finishedAt: now),
            .failed(exitCode: 1, duration: 2, finishedAt: now),
            .running(startedAt: now),
            .neverRan,
        ]
        if case .running = TerminalStatus.aggregate(inputs) { /* pass */ } else {
            XCTFail("Expected running to win aggregation")
        }
    }

    func testAggregateFailedBeatsSuccessAndNeverRan() {
        let now = Date()
        let inputs: [TerminalStatus] = [
            .success(exitCode: 0, duration: 1, finishedAt: now),
            .failed(exitCode: 2, duration: 3, finishedAt: now),
            .neverRan,
        ]
        if case .failed = TerminalStatus.aggregate(inputs) { /* pass */ } else {
            XCTFail("Expected failed to win over success+neverRan")
        }
    }

    func testAggregateSuccessBeatsNeverRan() {
        let now = Date()
        let inputs: [TerminalStatus] = [
            .success(exitCode: 0, duration: 1, finishedAt: now),
            .neverRan,
        ]
        if case .success = TerminalStatus.aggregate(inputs) { /* pass */ } else {
            XCTFail("Expected success over neverRan")
        }
    }

    func testAggregateTwoSuccessPicksOneSuccess() {
        let now = Date()
        let s1 = TerminalStatus.success(exitCode: 0, duration: 1, finishedAt: now)
        let s2 = TerminalStatus.success(exitCode: 0, duration: 2, finishedAt: now)
        if case .success = TerminalStatus.aggregate([s1, s2]) { /* pass */ } else {
            XCTFail("Expected success when multiple successes present")
        }
    }
}
```

- [ ] **Step 2: Run tests — expect compile failure (type does not exist)**

Run: `xcodebuild test -project TheAll.xcodeproj -scheme TheAllTests -only-testing:TheAllTests/TerminalStatusTests 2>&1 | tail -30`
Expected: compile error "cannot find type 'TerminalStatus' in scope".

- [ ] **Step 3: Implement `TerminalStatus` enum and `aggregate(_:)`**

```swift
// TheAll/Models/TerminalStatus.swift
import Foundation

/// Per-terminal running state.
///
/// - `neverRan`: freshly opened terminal, no command has started yet.
/// - `running`: shell is executing a command (signalled by ghostty OSC 133).
/// - `success` / `failed`: last command's result. Latched until the next command starts.
///
/// State is in-memory only. App restart → shell relaunches → all terminals reset to `.neverRan`.
enum TerminalStatus: Equatable {
    case neverRan
    case running(startedAt: Date)
    case success(exitCode: Int32, duration: TimeInterval, finishedAt: Date)
    case failed(exitCode: Int32, duration: TimeInterval, finishedAt: Date)

    /// Priority for aggregation: running > failed > success > neverRan.
    /// Higher number wins. Used by `aggregate(_:)`.
    fileprivate var priority: Int {
        switch self {
        case .running:  return 3
        case .failed:   return 2
        case .success:  return 1
        case .neverRan: return 0
        }
    }

    /// Reduce a bag of per-terminal statuses into one aggregate status using the
    /// priority running > failed > success > neverRan. Ties keep the first member
    /// (e.g. two successes → the first). Empty input → `.neverRan`.
    static func aggregate(_ statuses: [TerminalStatus]) -> TerminalStatus {
        statuses.reduce(TerminalStatus.neverRan) { current, next in
            next.priority > current.priority ? next : current
        }
    }
}
```

- [ ] **Step 4: Run tests — all pass**

Run: `xcodebuild test -project TheAll.xcodeproj -scheme TheAllTests -only-testing:TheAllTests/TerminalStatusTests 2>&1 | tail -20`
Expected: 7 tests, all PASS.

- [ ] **Step 5: Commit**

```bash
git add TheAll/Models/TerminalStatus.swift TheAllTests/TerminalStatusTests.swift
git commit -m "$(cat <<'EOF'
feat(models): add TerminalStatus enum with priority aggregation

Four-state model (neverRan/running/success/failed) for per-terminal
state, with a reduce-based aggregate used by tab/workspace rollups.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

If the test target file needs to be added to `project.yml` / regenerated, run `xcodegen generate` afterwards — but the `TheAllTests/` target already globs that directory so it should pick up automatically.

---

## Task 2: `TerminalStatusStore` with store mutation tests

**Files:**
- Create: `TheAll/Models/TerminalStatusStore.swift`
- Create: `TheAllTests/TerminalStatusStoreTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
// TheAllTests/TerminalStatusStoreTests.swift
import XCTest
@testable import TheAll

final class TerminalStatusStoreTests: XCTestCase {

    func testDefaultStatusIsNeverRan() {
        let store = TerminalStatusStore()
        let id = UUID()
        XCTAssertEqual(store.status(for: id), .neverRan)
    }

    func testSetRunningMakesItRunning() {
        let store = TerminalStatusStore()
        let id = UUID()
        let t = Date(timeIntervalSince1970: 1000)
        store.setRunning(terminalId: id, at: t)
        XCTAssertEqual(store.status(for: id), .running(startedAt: t))
    }

    func testSetFinishedExitZeroIsSuccess() {
        let store = TerminalStatusStore()
        let id = UUID()
        let t1 = Date(timeIntervalSince1970: 1000)
        let t2 = Date(timeIntervalSince1970: 1005)
        store.setRunning(terminalId: id, at: t1)
        store.setFinished(terminalId: id, exitCode: 0, duration: 5, at: t2)
        XCTAssertEqual(
            store.status(for: id),
            .success(exitCode: 0, duration: 5, finishedAt: t2)
        )
    }

    func testSetFinishedExitNonZeroIsFailed() {
        let store = TerminalStatusStore()
        let id = UUID()
        let t = Date(timeIntervalSince1970: 2000)
        store.setFinished(terminalId: id, exitCode: 1, duration: 3, at: t)
        XCTAssertEqual(
            store.status(for: id),
            .failed(exitCode: 1, duration: 3, finishedAt: t)
        )
    }

    func testNewRunningAfterFinishOverwrites() {
        let store = TerminalStatusStore()
        let id = UUID()
        let t1 = Date(timeIntervalSince1970: 1000)
        store.setFinished(terminalId: id, exitCode: 0, duration: 1, at: t1)
        let t2 = Date(timeIntervalSince1970: 2000)
        store.setRunning(terminalId: id, at: t2)
        XCTAssertEqual(store.status(for: id), .running(startedAt: t2))
    }

    func testForgetClearsEntry() {
        let store = TerminalStatusStore()
        let id = UUID()
        store.setRunning(terminalId: id, at: Date())
        store.forget(terminalId: id)
        XCTAssertEqual(store.status(for: id), .neverRan)
    }

    func testAggregateForIdsUsesPriority() {
        let store = TerminalStatusStore()
        let a = UUID(); let b = UUID(); let c = UUID()
        let now = Date()
        store.setRunning(terminalId: a, at: now)
        store.setFinished(terminalId: b, exitCode: 1, duration: 1, at: now)
        // c left as neverRan
        if case .running = store.aggregateStatus(terminalIds: [a, b, c]) {
            // pass
        } else {
            XCTFail("Expected running to win aggregation")
        }
    }

    func testStatusesSnapshotReturnsAllSetEntries() {
        let store = TerminalStatusStore()
        let a = UUID(); let b = UUID()
        let t = Date()
        store.setRunning(terminalId: a, at: t)
        store.setFinished(terminalId: b, exitCode: 0, duration: 1, at: t)
        let snap = store.statusesSnapshot()
        XCTAssertEqual(snap.count, 2)
        XCTAssertEqual(snap[a], .running(startedAt: t))
        XCTAssertEqual(snap[b], .success(exitCode: 0, duration: 1, finishedAt: t))
    }
}
```

- [ ] **Step 2: Run tests — expect compile failure**

Run: `xcodebuild test -project TheAll.xcodeproj -scheme TheAllTests -only-testing:TheAllTests/TerminalStatusStoreTests 2>&1 | tail -30`
Expected: compile error "cannot find 'TerminalStatusStore' in scope".

- [ ] **Step 3: Implement `TerminalStatusStore`**

```swift
// TheAll/Models/TerminalStatusStore.swift
import Foundation
import Observation

/// In-memory-only per-terminal status. Lives for app session; app restart → shell
/// relaunches → all entries gone. Mutations happen on the main queue (signal path
/// from ghostty action callback hops back to main before calling these setters).
@Observable
final class TerminalStatusStore {
    private var storage: [UUID: TerminalStatus] = [:]

    init() {}

    func status(for terminalId: UUID) -> TerminalStatus {
        storage[terminalId] ?? .neverRan
    }

    func setRunning(terminalId: UUID, at startedAt: Date) {
        storage[terminalId] = .running(startedAt: startedAt)
    }

    func setFinished(terminalId: UUID, exitCode: Int32, duration: TimeInterval, at finishedAt: Date) {
        if exitCode == 0 {
            storage[terminalId] = .success(exitCode: exitCode, duration: duration, finishedAt: finishedAt)
        } else {
            storage[terminalId] = .failed(exitCode: exitCode, duration: duration, finishedAt: finishedAt)
        }
    }

    /// Drop the entry (e.g. when the terminal is closed). Subsequent reads return `.neverRan`.
    func forget(terminalId: UUID) {
        storage.removeValue(forKey: terminalId)
    }

    /// Aggregate over a bag of ids using priority running > failed > success > neverRan.
    func aggregateStatus(terminalIds: [UUID]) -> TerminalStatus {
        TerminalStatus.aggregate(terminalIds.map { status(for: $0) })
    }

    /// Copy of the whole map. Used by bridges to push status dicts into AppKit views.
    func statusesSnapshot() -> [UUID: TerminalStatus] {
        storage
    }
}
```

- [ ] **Step 4: Run tests — all pass**

Run: `xcodebuild test -project TheAll.xcodeproj -scheme TheAllTests -only-testing:TheAllTests/TerminalStatusStoreTests 2>&1 | tail -20`
Expected: 8 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add TheAll/Models/TerminalStatusStore.swift TheAllTests/TerminalStatusStoreTests.swift
git commit -m "$(cat <<'EOF'
feat(models): add TerminalStatusStore @Observable for session-lived status

In-memory store keyed by terminal UUID. Exposes setRunning/setFinished
plus aggregateStatus(terminalIds:) for tab/workspace rollups.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Add `success` / `danger` theme tokens

**Files:**
- Modify: `TheAll/Theme/AppTheme.swift`

No new tests here — these tokens are data; visual verification comes later. Keep the change minimal: accent already exists; add two sibling fields.

- [ ] **Step 1: Extend `AppTheme` struct with two new colour fields**

Open `TheAll/Theme/AppTheme.swift`. After the existing `let accentMuted: NSColor` line add:

```swift
    // Status (terminal status icon)
    let success: NSColor         // 命令成功退出 (exit 0) 的点色
    let danger: NSColor          // 命令失败 (exit != 0) 的点色
```

- [ ] **Step 2: Populate the two fields in `derive(...)`**

In `AppTheme.swift`, inside `static func derive(...)`, immediately above the `return AppTheme(...)` block, insert:

```swift
        // status colours: tuned for both dark and light canvases
        let success = isDark
            ? NSColor(srgbRed: 0.247, green: 0.729, blue: 0.314, alpha: 1)  // #3FBA50
            : NSColor(srgbRed: 0.180, green: 0.600, blue: 0.235, alpha: 1)
        let danger = isDark
            ? NSColor(srgbRed: 0.973, green: 0.318, blue: 0.286, alpha: 1)  // #F85149
            : NSColor(srgbRed: 0.827, green: 0.184, blue: 0.184, alpha: 1)
```

Then in the `return AppTheme(...)` initializer call append `success: success, danger: danger` as the last two arguments.

- [ ] **Step 3: Compile**

Run: `xcodebuild -project TheAll.xcodeproj -scheme TheAll -configuration Debug build 2>&1 | tail -20`
Expected: BUILD SUCCEEDED. (If not, the likely issue is a missing comma in the initializer list — fix inline.)

- [ ] **Step 4: Commit**

```bash
git add TheAll/Theme/AppTheme.swift
git commit -m "$(cat <<'EOF'
feat(theme): add success and danger tokens for status icon

Derived from palette-neutral sRGB values (GitHub-style) tuned for
dark/light canvases; consumed by TerminalStatusIconView.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4 (HUMAN-GATED): Vendor shell-integration scripts

⚠️ This task modifies `scripts/build-vendor.sh` which CLAUDE.md marks as human-confirmation-required. **STOP here and ask the user before proceeding.** User either runs it themselves or explicitly authorises the agent.

**Files:**
- Modify: `scripts/build-vendor.sh`

- [ ] **Step 0: Ask user for confirmation**

> "About to modify `scripts/build-vendor.sh` to also vendor the ghostty shell-integration scripts into `Vendor/ghostty/share/`. OK to proceed, or would you rather run this manually?"

- [ ] **Step 1: After confirmation, patch the script**

Append to `scripts/build-vendor.sh` immediately after the existing copy-lib block (before the final `echo` line):

```bash
# Shell integration scripts (OSC 133 injection for zsh/bash/fish).
# Ghostty builds its "share/" dir via a separate step; run it and copy the tree.
mkdir -p "$PROJECT_DIR/Vendor/ghostty/share"
if [ -d "$GHOSTTY_SRC/zig-out/share/ghostty" ]; then
  rsync -a --delete "$GHOSTTY_SRC/zig-out/share/ghostty/" "$PROJECT_DIR/Vendor/ghostty/share/ghostty/"
elif [ -d "$GHOSTTY_SRC/src/shell-integration" ]; then
  # Fallback: copy source tree directly (same content, unprocessed)
  mkdir -p "$PROJECT_DIR/Vendor/ghostty/share/ghostty"
  rsync -a --delete "$GHOSTTY_SRC/src/shell-integration/" "$PROJECT_DIR/Vendor/ghostty/share/ghostty/shell-integration/"
else
  echo "WARN: no shell-integration dir found in $GHOSTTY_SRC" >&2
fi
```

- [ ] **Step 2: Re-run the vendor script and verify payload**

Run: `./scripts/build-vendor.sh 2>&1 | tail -5`
Then: `ls Vendor/ghostty/share/ghostty/shell-integration 2>/dev/null`
Expected: `bash  fish  zsh` (or similar — presence of shell subdirs confirms it worked).

If the directory is empty, try the fallback path manually by inspecting `$GHOSTTY_SRC` and adjusting the glob.

- [ ] **Step 3: Commit**

```bash
git add scripts/build-vendor.sh
git commit -m "$(cat <<'EOF'
build(vendor): copy ghostty shell-integration scripts into Vendor/

Needed for OSC 133 command-finished signal: libghostty auto-injects
these scripts into the user's shell at surface creation time, but only
if it can find them via resources-dir.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

(Do NOT commit the actual `Vendor/ghostty/share/` contents — it's gitignored like `lib/`. If that's not the case, check `.gitignore` and flag to the user.)

---

## Task 5 (HUMAN-GATED): App-bundle copy phase + bridging header include

⚠️ This task modifies `project.yml`. CLAUDE.md marks it human-gated. **STOP and ask the user before proceeding.**

**Files:**
- Modify: `project.yml`

- [ ] **Step 0: Ask user for confirmation**

> "About to add a resources copy phase to `project.yml` so ghostty shell-integration scripts ship inside the app bundle. After editing I'll run `xcodegen generate`. OK?"

- [ ] **Step 1: Patch project.yml**

Under the `targets.theall` block, after `sources:`, insert a `copyFiles:` phase. The final target block should look like:

```yaml
  TheAll:
    type: application
    platform: macOS
    sources:
      - path: TheAll
        excludes:
          - "**/*.md"
    copyFiles:
      - destination: resources
        subpath: ghostty
        files:
          - Vendor/ghostty/share/ghostty
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.theall.app
        ...
```

The exact xcodegen key for "copy resources into `$(BUILT_PRODUCTS_DIR)/$(CONTENTS_FOLDER_PATH)/Resources/ghostty/`" is `copyFiles` with `destination: resources`. Confirm against xcodegen docs before running; if the syntax is wrong `xcodegen generate` will error and we revert.

- [ ] **Step 2: Regenerate the Xcode project**

Run: `xcodegen generate 2>&1 | tail -10`
Expected: "Created project at ..." and no warnings about the new section.

- [ ] **Step 3: Build and verify the bundle contains the dir**

Run: `xcodebuild -project TheAll.xcodeproj -scheme TheAll -configuration Debug build 2>&1 | tail -5`

Find the built app and check its Resources:
```bash
find ~/Library/Developer/Xcode/DerivedData -name "TheAll.app" -type d 2>/dev/null | head -1 | xargs -I {} ls "{}/Contents/Resources/ghostty/shell-integration" 2>/dev/null
```
Expected: `bash  fish  zsh`.

- [ ] **Step 4: Commit**

```bash
git add project.yml
git commit -m "$(cat <<'EOF'
build(project): copy ghostty/ dir into app bundle Resources

Ships shell-integration scripts alongside the binary so libghostty can
discover them via resources-dir at surface creation.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: Point libghostty at the bundled resources-dir

**Files:**
- Modify: `TheAll/Ghostty/GhosttyBridge.swift`

- [ ] **Step 1: Load resources-dir before `ghostty_config_finalize`**

In `GhosttyBridge.initialize()`, find the section where the theme path is loaded (around `ghostty_config_load_file(cfg, $0)` inside the `if let themePath = ...` block). Immediately above that block, insert:

```swift
        // Tell libghostty where to find bundled resources (shell-integration scripts,
        // terminfo, etc). Without this, OSC 133 injection can't happen: ghostty won't
        // auto-inject the shell hooks into zsh/bash/fish on surface start.
        if let resourcesPath = Bundle.main.resourcePath {
            let ghosttyDir = (resourcesPath as NSString).appendingPathComponent("ghostty")
            if FileManager.default.fileExists(atPath: ghosttyDir) {
                let arg = "--resources-dir=\(ghosttyDir)"
                arg.withCString { ghostty_config_load_string(cfg, $0, UInt(arg.utf8.count)) }
            } else {
                print("[GhosttyBridge] bundled resources-dir not found at \(ghosttyDir)")
            }
        }
```

NOTE on API: ghostty's C API for loading a single config key-value is `ghostty_config_load_string`. If the function name in your `ghostty.h` is different (check with `grep ghostty_config_load_string Vendor/ghostty/include/ghostty.h`), use the matching one — candidates are `ghostty_config_load_argv` or the C equivalent of CLI `--key=value`.

- [ ] **Step 2: Verify API name actually exists**

Grep `Vendor/ghostty/include/ghostty.h` for `ghostty_config_load_string`. If it isn't there, grep for `ghostty_config_load_` to find the actual family of load functions (candidates: `_string`, `_cstring`, `_arg`, `_argv`).

If no string-load function exists, fall back: write a temp file like `~/Library/Caches/theall/resources-dir.conf` containing the single line `resources-dir = <path>` and pass its path to `ghostty_config_load_file(cfg, $0)` instead. Delete the file on successful load or leave it — it's small and idempotent.

- [ ] **Step 3: Build and run the app; look for boot-time log**

Run: `xcodebuild -project TheAll.xcodeproj -scheme TheAll -configuration Debug build 2>&1 | tail -5`
Then launch the app (from Xcode or `open ~/Library/Developer/Xcode/DerivedData/.../TheAll.app`).
Expected: no "[GhosttyBridge] bundled resources-dir not found" warning; terminal opens normally.

- [ ] **Step 4: Commit**

```bash
git add TheAll/Ghostty/GhosttyBridge.swift
git commit -m "$(cat <<'EOF'
feat(ghostty): load bundled resources-dir for shell integration

Enables OSC 133 command boundary detection by letting libghostty
auto-inject its shell integration scripts into user shells.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: Add `terminalId` to `GhosttyTerminalView` + reverse lookup

**Files:**
- Modify: `TheAll/Ghostty/GhosttyTerminalView.swift`
- Modify: `TheAll/TabContent/TabContentView.swift`

- [ ] **Step 1: Add `terminalId` property and a static reverse lookup**

In `GhosttyTerminalView.swift`, immediately after the existing `private static weak var currentFrontmost: GhosttyTerminalView?` line add:

```swift
    /// The model-layer UUID this view represents. Set by TabContentView right after
    /// construction. Used by GhosttyBridge.actionCallback to route ghostty action
    /// callbacks (e.g. COMMAND_FINISHED) back to TerminalStatusStore.
    var terminalId: UUID?

    /// Map from the opaque ghostty_surface_t pointer back to the owning view.
    /// The action callback only has a ghostty_target_s with the surface handle; this
    /// lookup is how we get back to Swift-land. Weak references so a freed surface
    /// won't keep its view alive.
    private static var viewBySurface: [OpaquePointer: Weak<GhosttyTerminalView>] = [:]

    /// Lookup by raw ghostty_surface_t. Returns nil if the view has been deallocated.
    static func view(forSurface surface: ghostty_surface_t) -> GhosttyTerminalView? {
        viewBySurface[OpaquePointer(surface)]?.value
    }

    private final class Weak<T: AnyObject> {
        weak var value: T?
        init(_ value: T) { self.value = value }
    }
```

Note: `ghostty_surface_t` in the bridging header is defined as `typedef void *ghostty_surface_t;` — `OpaquePointer` wraps it cleanly as a dictionary key. If the Swift-imported type is different (e.g. `UnsafeMutableRawPointer`), use that as the key type instead.

- [ ] **Step 2: Populate the map when a surface is created, remove on free**

In `GhosttyTerminalView.viewDidMoveToWindow`, inside the existing `if let s = surface { ... }` block (which currently sets size/scale), add one line as the first statement:

```swift
            if let s = surface {
                GhosttyTerminalView.viewBySurface[OpaquePointer(s)] = Weak(self)   // NEW
                let w = UInt32(bounds.width * scale)
                let h = UInt32(bounds.height * scale)
                ghostty_surface_set_size(s, w, h)
                ghostty_surface_set_content_scale(s, scale, scale)
            }
```

In `GhosttyTerminalView.deinit`, before `ghostty_surface_free(s)`:

```swift
        if let s = surface {
            GhosttyTerminalView.viewBySurface.removeValue(forKey: OpaquePointer(s))
            ghostty_surface_free(s)
        }
```

(Replace the existing simpler free block.)

- [ ] **Step 3: Assign `terminalId` from `TabContentView.terminalViewFor(id:)`**

In `TheAll/TabContent/TabContentView.swift`, edit `terminalViewFor(id:)`:

```swift
    private func terminalViewFor(id: UUID) -> GhosttyTerminalView {
        if let existing = terminalViews[id] { return existing }
        let tv = GhosttyTerminalView(frame: .zero)
        tv.terminalId = id
        terminalViews[id] = tv
        return tv
    }
```

- [ ] **Step 4: Build**

Run: `xcodebuild -project TheAll.xcodeproj -scheme TheAll -configuration Debug build 2>&1 | tail -10`
Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Commit**

```bash
git add TheAll/Ghostty/GhosttyTerminalView.swift TheAll/TabContent/TabContentView.swift
git commit -m "$(cat <<'EOF'
feat(ghostty): add terminalId and surface→view reverse lookup

Required by the action callback router: ghostty action payloads carry
only the opaque surface handle, so we map back to Swift-land + UUID.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 8: Route `GHOSTTY_ACTION_COMMAND_FINISHED` to a Swift handler

**Files:**
- Modify: `TheAll/Ghostty/GhosttyBridge.swift`

- [ ] **Step 1: Add a handler closure and a `terminalId→duration start time` fallback**

In `GhosttyBridge`, immediately after `private(set) var isInitialized = false`, add:

```swift
    /// Called when ghostty reports the current command is running / has finished.
    /// Set once at startup by ContentView (after the TerminalStatusStore is wired).
    /// Runs on the main queue.
    var onCommandFinished: ((_ terminalId: UUID, _ exitCode: Int32, _ duration: TimeInterval, _ at: Date) -> Void)?

    /// Called when ghostty reports a new prompt started (OSC 133 A).
    /// Absent today in all ghostty builds; wired for forward-compat. Main queue.
    var onPromptStart: ((_ terminalId: UUID, _ at: Date) -> Void)?
```

- [ ] **Step 2: Rewrite `actionCallback` as a router**

Replace the existing stub:

```swift
    // ghostty_runtime_action_cb: (ghostty_app_t, ghostty_target_s, ghostty_action_s) -> bool
    private static let actionCallback: ghostty_runtime_action_cb = { _, _, _ in
        return false
    }
```

with:

```swift
    // ghostty_runtime_action_cb: (ghostty_app_t, ghostty_target_s, ghostty_action_s) -> bool
    private static let actionCallback: ghostty_runtime_action_cb = { _, target, action in
        // Only surface-targeted actions carry the per-terminal signals we want.
        // Other targets (app, none) → ignore; return false to let ghostty handle defaults.
        guard target.tag == GHOSTTY_TARGET_SURFACE,
              let surface = target.target.surface else { return false }

        switch action.tag {
        case GHOSTTY_ACTION_COMMAND_FINISHED:
            let payload = action.action.command_finished
            // duration field is nanoseconds
            let durationSec = Double(payload.duration) / 1_000_000_000
            let exit = Int32(payload.exit_code)
            let finishedAt = Date()
            DispatchQueue.main.async {
                guard let view = GhosttyTerminalView.view(forSurface: surface),
                      let tid = view.terminalId else { return }
                GhosttyBridge.shared.onCommandFinished?(tid, exit, durationSec, finishedAt)
            }
            return true

        default:
            return false
        }
    }
```

- [ ] **Step 3: Build**

Run: `xcodebuild -project TheAll.xcodeproj -scheme TheAll -configuration Debug build 2>&1 | tail -20`

If the build fails because `target.tag` / `action.tag` / `target.target.surface` names differ from the header, `Grep` for `ghostty_target_s` / `ghostty_action_s` in the header and adjust. The idea is: `target` is a tagged union with a `surface` field; `action` is a tagged union whose `command_finished` case holds `exit_code` + `duration`.

If `GHOSTTY_TARGET_SURFACE` is the `tag` enum value, great. If ghostty uses a different naming, substitute it.

- [ ] **Step 4: Sanity-check the callback fires — add a temporary print and run the app**

Temporarily inside `DispatchQueue.main.async { ... }` of the COMMAND_FINISHED branch, BEFORE the `onCommandFinished` call, add:

```swift
                print("[ghostty] cmd finished exit=\(exit) dur=\(durationSec)s tid=\(GhosttyTerminalView.view(forSurface: surface)?.terminalId?.uuidString ?? "nil")")
```

Build and run the app. Open a terminal, run `ls` and hit enter. Check Console / Xcode output for the print. If nothing appears, OSC 133 isn't working — **halt here and report back**: the most likely causes are (a) the resources-dir path isn't valid, (b) the user's shell isn't zsh/bash/fish, (c) the user has `shell-integration = none` in their ghostty config. Re-check each.

Once confirmed, remove the print.

- [ ] **Step 5: Commit**

```bash
git add TheAll/Ghostty/GhosttyBridge.swift
git commit -m "$(cat <<'EOF'
feat(ghostty): route COMMAND_FINISHED action to a Swift handler

Surface-targeted actions get mapped back to the originating terminal
UUID via GhosttyTerminalView.view(forSurface:). Handler is main-queue.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 9: `TerminalStatusIconView` NSView

**Files:**
- Create: `TheAll/Theme/TerminalStatusIconView.swift`

No unit tests — rendering goes through manual verification.

- [ ] **Step 1: Implement the icon view**

```swift
// TheAll/Theme/TerminalStatusIconView.swift
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
            if case .running = status { startSpinAnimation() } else { stopSpinAnimation() }
        }
    }

    private static func sameKind(_ a: TerminalStatus, _ b: TerminalStatus) -> Bool {
        switch (a, b) {
        case (.neverRan, .neverRan),
             (.running,  .running),
             (.success,  .success),
             (.failed,   .failed):
            return true
        default:
            return false
        }
    }

    private func render() {
        let rect = bounds.insetBy(dx: 1, dy: 1)
        switch status {
        case .neverRan:
            shapeLayer.path = CGPath(ellipseIn: rect, transform: nil)
            shapeLayer.fillColor = NSColor.clear.cgColor
            shapeLayer.strokeColor = theme.textTertiary.cgColor
            shapeLayer.lineWidth = 1
        case .running:
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
        case .success:
            shapeLayer.path = CGPath(ellipseIn: rect, transform: nil)
            shapeLayer.fillColor = theme.success.cgColor
            shapeLayer.strokeColor = NSColor.clear.cgColor
            shapeLayer.lineWidth = 0
        case .failed:
            shapeLayer.path = CGPath(ellipseIn: rect, transform: nil)
            shapeLayer.fillColor = theme.danger.cgColor
            shapeLayer.strokeColor = NSColor.clear.cgColor
            shapeLayer.lineWidth = 0
        }
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

    override var intrinsicContentSize: NSSize {
        NSSize(width: Self.size, height: Self.size)
    }
}
```

- [ ] **Step 2: Build**

Run: `xcodebuild -project TheAll.xcodeproj -scheme TheAll -configuration Debug build 2>&1 | tail -10`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add TheAll/Theme/TerminalStatusIconView.swift
git commit -m "$(cat <<'EOF'
feat(theme): add TerminalStatusIconView for four-state terminal status

10pt NSView rendering static dot (neverRan/success/failed) or spinning
270° arc (running). Colours sourced from AppTheme tokens.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 10: Insert icon into `TabItemView`

**Files:**
- Modify: `TheAll/TabContent/TabBarView.swift`

- [ ] **Step 1: Add icon property, thread status through `update(...)` / `refresh(...)`**

Find in `TabBarView` the `update(tabs:selectedTabId:theme:)` function. Change its signature and body:

```swift
    func update(tabs: [TerminalTab],
                selectedTabId: UUID?,
                theme: AppTheme,
                statuses: [UUID: TerminalStatus]) {
        self.tabs = tabs
        self.selectedTabId = selectedTabId
        self.theme = theme
        self.statuses = statuses
        rebuildTabItems()
        applyTheme(theme)
    }
```

And add a stored property near `private var tabs: [TerminalTab] = []`:

```swift
    private var statuses: [UUID: TerminalStatus] = [:]
```

In `rebuildTabItems()`, in the id-matching branch that calls `item.refresh(...)`, compute the per-tab aggregated status and pass it:

```swift
            for item in existing {
                let isSel = item.tabId == selectedTabId
                if let tab = tabs.first(where: { $0.id == item.tabId }) {
                    let tabStatus = TerminalStatus.aggregate(
                        tab.layout.allTerminalIds().map { statuses[$0] ?? .neverRan }
                    )
                    item.refresh(tab: tab, isSelected: isSel, theme: theme, canClose: canCloseNow, status: tabStatus)
                }
            }
```

And in the rebuild branch:

```swift
        for tab in tabs {
            let tabStatus = TerminalStatus.aggregate(
                tab.layout.allTerminalIds().map { statuses[$0] ?? .neverRan }
            )
            let item = TabItemView(tab: tab, isSelected: tab.id == selectedTabId, theme: theme, status: tabStatus)
            ...
```

- [ ] **Step 2: Update `TabItemView` to host the icon**

In the `private final class TabItemView` definition:

- Add a new stored property:
  ```swift
      private let statusIcon = TerminalStatusIconView(frame: .zero)
      private var status: TerminalStatus
  ```

- Change `init(tab:isSelected:theme:)` to `init(tab:isSelected:theme:status:)` and store `status`:
  ```swift
      init(tab: TerminalTab, isSelected: Bool, theme: AppTheme, status: TerminalStatus) {
          self.tabId = tab.id
          self.isSelected = isSelected
          self.theme = theme
          self.status = status
          super.init(frame: .zero)
          titleLabel.stringValue = tab.title
          setup()
          updateStyle()
          statusIcon.update(status: status, theme: theme)
      }
  ```

- In `setup()`, after `addSubview(pillView)` add:
  ```swift
          addSubview(statusIcon)
  ```

- In `layout()`, adjust the title layout to reserve leading space for the 10pt icon + 6pt gap:
  ```swift
      override func layout() {
          super.layout()
          let h = bounds.height
          let vInset = TabBarView.pillInset
          let pillH = h - vInset * 2
          pillView.frame = NSRect(x: 0, y: vInset, width: bounds.width, height: pillH)
          pillView.layer?.cornerRadius = TabBarView.pillRadius

          let margin: CGFloat = 10
          let iconSize: CGFloat = TerminalStatusIconView.size
          let iconGap: CGFloat = 6
          statusIcon.frame = NSRect(
              x: margin, y: (h - iconSize) / 2,
              width: iconSize, height: iconSize)

          let closeW: CGFloat = 16
          closeBtn.frame = NSRect(x: bounds.width - closeW - margin,
                                  y: (h - 14) / 2, width: closeW, height: 14)
          let textH = ceil(titleLabel.intrinsicContentSize.height)
          let textX = margin + iconSize + iconGap
          let textFrame = NSRect(x: textX, y: (h - textH) / 2,
                                 width: bounds.width - closeW - margin - textX,
                                 height: textH)
          titleLabel.frame = textFrame
          renameField.frame = textFrame
      }
  ```

- Change `refresh(tab:isSelected:theme:canClose:)` to include `status`:
  ```swift
      func refresh(tab: TerminalTab, isSelected: Bool, theme: AppTheme,
                   canClose: Bool, status: TerminalStatus) {
          self.theme = theme
          self.isSelected = isSelected
          self.canClose = canClose
          self.status = status
          if titleLabel.stringValue != tab.title && !isRenaming {
              titleLabel.stringValue = tab.title
          }
          statusIcon.update(status: status, theme: theme)
          updateStyle()
      }
  ```

- In `applyTheme(_:)` on `TabItemView`, after `updateStyle()`, add one line so a pure theme switch repaints the icon too:
  ```swift
      statusIcon.update(status: status, theme: theme)
  ```

- [ ] **Step 3: Build**

Run: `xcodebuild -project TheAll.xcodeproj -scheme TheAll -configuration Debug build 2>&1 | tail -20`
Expected: compile will break at the `TabBridge.swift` call site of `view.update(...)` because it passes only 3 args. That's OK — Task 11 fixes it. Note the error and proceed.

- [ ] **Step 4: Do NOT commit yet**

The build will be broken after Task 10 because `TabBridge` still passes 3 args to `view.update(...)`. Wait until Task 12's combined commit to restore the build and commit Tasks 10, 11, 12 together.

---

## Task 11: Insert icon into `WorkspaceRowItemView`

**Files:**
- Modify: `TheAll/Sidebar/WorkspaceListView.swift`

- [ ] **Step 1: Thread status through `WorkspaceListView.update(...)`**

Change `update(workspaces:selectedId:metadata:theme:)` to:

```swift
    func update(workspaces: [Workspace],
                selectedId: UUID?,
                metadata: [UUID: WorkspaceMetadata],
                statuses: [UUID: TerminalStatus],
                theme: AppTheme) {
        self.workspaces = workspaces
        self.selectedId = selectedId
        self.metadataMap = metadata
        self.statusMap = statuses
        self.theme = theme
        rebuildRows()
        applyTheme(theme)
    }
```

Add stored property:
```swift
    private var statusMap: [UUID: TerminalStatus] = [:]
```

Compute the per-workspace aggregate:
```swift
    private func workspaceStatus(_ ws: Workspace) -> TerminalStatus {
        let ids = ws.tabs.flatMap { $0.layout.allTerminalIds() }
        return TerminalStatus.aggregate(ids.map { statusMap[$0] ?? .neverRan })
    }
```

In `rebuildRows()` id-match branch:
```swift
            for item in existing {
                guard let ws = workspaces.first(where: { $0.id == item.workspaceId }) else { continue }
                let meta = metadataMap[item.workspaceId] ?? WorkspaceMetadata()
                item.refresh(workspace: ws,
                             isSelected: ws.id == selectedId,
                             metadata: meta,
                             status: workspaceStatus(ws),
                             theme: theme)
            }
```

And in the rebuild branch:
```swift
        for ws in workspaces {
            let meta = metadataMap[ws.id] ?? WorkspaceMetadata()
            let item = WorkspaceRowItemView(
                workspace: ws,
                isSelected: ws.id == selectedId,
                metadata: meta,
                status: workspaceStatus(ws),
                theme: theme)
            wireRowCallbacks(item)
            rowsContainer.addSubview(item)
        }
```

- [ ] **Step 2: Add icon to `WorkspaceRowItemView`**

Add stored property alongside existing fields:
```swift
    private let statusIcon = TerminalStatusIconView(frame: .zero)
    private var status: TerminalStatus
```

Change init signature:
```swift
    init(workspace: Workspace, isSelected: Bool,
         metadata: WorkspaceMetadata,
         status: TerminalStatus,
         theme: AppTheme) {
        self.workspaceId = workspace.id
        self.workspace = workspace
        self.isSelected = isSelected
        self.metadata = metadata
        self.status = status
        self.theme = theme
        super.init(frame: .zero)
        setup()
        updateContent()
        updateStyle()
        statusIcon.update(status: status, theme: theme)
    }
```

In `setup()`, after `addSubview(prBadge)` add:
```swift
        addSubview(statusIcon)
```

In `layout()`, position the icon at top-right (10pt size, right-aligned with `DT.Space.md` from the edge, vertically aligned with title):

```swift
    override func layout() {
        super.layout()
        backgroundLayerView.frame = bounds

        let hPad = DT.Space.md
        let topPad = DT.Space.xs
        let titleH = ceil(titleLabel.intrinsicContentSize.height)
        let branchH = ceil(branchLabel.intrinsicContentSize.height)

        // Status icon at top-right of the row, aligned to title baseline
        let iconSize = TerminalStatusIconView.size
        statusIcon.frame = NSRect(
            x: bounds.width - hPad - iconSize,
            y: bounds.height - topPad - titleH + (titleH - iconSize) / 2,
            width: iconSize, height: iconSize)

        // PR badge, if present, sits to the LEFT of the icon
        let prW: CGFloat = prBadge.isHidden
            ? 0
            : ceil(prBadge.intrinsicContentSize.width) + DT.Space.xs
        let iconReservedW = iconSize + DT.Space.xs   // space the title must avoid

        let titleFrame = NSRect(
            x: hPad,
            y: bounds.height - topPad - titleH,
            width: bounds.width - hPad * 2 - prW - iconReservedW,
            height: titleH)
        titleLabel.frame = titleFrame
        renameField.frame = titleFrame
        renameField.font = titleLabel.font

        if !prBadge.isHidden {
            prBadge.frame = NSRect(
                x: bounds.width - hPad - iconSize - DT.Space.xs - prW + DT.Space.xs,
                y: bounds.height - topPad - titleH,
                width: prW, height: titleH)
        }

        branchLabel.frame = NSRect(
            x: hPad, y: topPad,
            width: bounds.width - hPad * 2, height: branchH)
    }
```

Change `refresh(workspace:isSelected:metadata:theme:)` to add status:

```swift
    func refresh(workspace: Workspace, isSelected: Bool,
                 metadata: WorkspaceMetadata,
                 status: TerminalStatus,
                 theme: AppTheme) {
        self.workspace = workspace
        self.isSelected = isSelected
        self.metadata = metadata
        self.status = status
        self.theme = theme
        if !isRenaming, titleLabel.stringValue != workspace.name {
            titleLabel.stringValue = workspace.name
        }
        updateContent()
        updateStyle()
        statusIcon.update(status: status, theme: theme)
        needsLayout = true
    }
```

- [ ] **Step 2: Build** (will fail at bridges — fix in Task 12)

---

## Task 12: Bridges + SidebarView + ContentView — wire `TerminalStatusStore`

**Files:**
- Modify: `TheAll/Bridge/TabBridge.swift`
- Modify: `TheAll/Bridge/SidebarListBridge.swift`
- Modify: `TheAll/Sidebar/SidebarView.swift`
- Modify: `TheAll/ContentView.swift`

- [ ] **Step 1: `TabBridge` — accept store and forward status dict**

Replace `TabBridge.swift`:

```swift
import SwiftUI
import AppKit

struct TabBridge: NSViewRepresentable {
    @Bindable var store: WorkspaceStore
    @Bindable var statusStore: TerminalStatusStore
    var theme: AppTheme

    func makeNSView(context: Context) -> TabContentView {
        let view = TabContentView(frame: .zero)
        view.store = store
        view.applyTheme(theme)
        if let ws = store.selectedWorkspace {
            view.loadWorkspace(ws, statuses: statusStore.statusesSnapshot())
        }
        return view
    }

    func updateNSView(_ nsView: TabContentView, context: Context) {
        nsView.store = store
        nsView.applyTheme(theme)
        if let ws = store.selectedWorkspace {
            nsView.loadWorkspace(ws, statuses: statusStore.statusesSnapshot())
        }
    }

    static func dismantleNSView(_ nsView: TabContentView, coordinator: ()) {
        nsView.detach()
    }
}
```

Inside `TabContentView`, change `loadWorkspace(_:)` to take the statuses dict:

```swift
    func loadWorkspace(_ workspace: Workspace, statuses: [UUID: TerminalStatus] = [:]) {
        ... // existing prune logic unchanged ...

        // Update tab bar with status dict
        tabBar.update(tabs: workspace.tabs,
                      selectedTabId: workspace.selectedTabId,
                      theme: theme,
                      statuses: statuses)

        if let tab = workspace.selectedTab {
            activateTab(tab)
        }
    }
```

Also update `reloadFromStore()` to pass statuses — but since TabContentView doesn't directly know the store, add a `lastStatuses` cache:

```swift
    private var lastStatuses: [UUID: TerminalStatus] = [:]

    func loadWorkspace(_ workspace: Workspace, statuses: [UUID: TerminalStatus] = [:]) {
        self.lastStatuses = statuses
        // ... rest unchanged but use self.lastStatuses instead of statuses in the tabBar.update call
        tabBar.update(tabs: workspace.tabs, selectedTabId: workspace.selectedTabId,
                      theme: theme, statuses: self.lastStatuses)
        if let tab = workspace.selectedTab { activateTab(tab) }
    }

    private func reloadFromStore() {
        guard let ws = store?.selectedWorkspace else { return }
        loadWorkspace(ws, statuses: lastStatuses)
    }
```

- [ ] **Step 2: `SidebarListBridge` — accept status store and forward**

Replace `SidebarListBridge.swift`:

```swift
import SwiftUI
import AppKit

struct SidebarListBridge: NSViewRepresentable {
    @Bindable var store: WorkspaceStore
    @Bindable var statusStore: TerminalStatusStore
    var theme: AppTheme
    var metadata: [UUID: WorkspaceMetadata]
    var metadataTick: Int
    var onRequestDelete: (UUID) -> Void

    func makeNSView(context: Context) -> WorkspaceListView {
        let view = WorkspaceListView()
        wire(view)
        view.update(workspaces: store.workspaces,
                    selectedId: store.selectedId,
                    metadata: metadata,
                    statuses: statusStore.statusesSnapshot(),
                    theme: theme)
        return view
    }

    func updateNSView(_ view: WorkspaceListView, context: Context) {
        _ = metadataTick
        wire(view)
        view.update(workspaces: store.workspaces,
                    selectedId: store.selectedId,
                    metadata: metadata,
                    statuses: statusStore.statusesSnapshot(),
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

- [ ] **Step 3: `SidebarView` — thread status store through**

```swift
// In SidebarView signature
struct SidebarView: View {
    @Bindable var store: WorkspaceStore
    @Bindable var statusStore: TerminalStatusStore
    var theme: AppTheme
    // ... rest unchanged ...

// In the body's SidebarListBridge call
SidebarListBridge(
    store: store,
    statusStore: statusStore,
    theme: theme,
    metadata: metadataMap,
    metadataTick: metadataTicker.tick,
    onRequestDelete: { workspaceToDelete = $0 }
)
```

- [ ] **Step 4: `ContentView` — own the store and pass it**

In `ContentView.swift`:

```swift
struct ContentView: View {
    @State private var store = WorkspaceStore()
    @State private var statusStore = TerminalStatusStore()
    @State private var sidebarCollapsed: Bool = false
    @Environment(ThemeManager.self) private var themeManager
    ...

    var body: some View {
        ZStack(alignment: .topLeading) {
            HStack(spacing: 0) {
                if !sidebarCollapsed {
                    SidebarView(store: store, statusStore: statusStore, theme: themeManager.theme)
                        .padding(.top, trafficLightInset)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }

                TabBridge(store: store, statusStore: statusStore, theme: themeManager.theme)
                    ...
            }
            ...
        }
        ...
        .onAppear {
            themeManager.loadFromGhosttyConfig()
            // Wire ghostty command-finished events to our status store
            GhosttyBridge.shared.onCommandFinished = { [weak statusStore = self.statusStore] tid, code, dur, at in
                guard let statusStore = statusStore else { return }
                statusStore.setFinished(terminalId: tid, exitCode: code, duration: dur, at: at)
            }
        }
    }
```

Note: `@State` wraps the store in a non-optional. The weak capture trick won't work on value-typed @State — just capture directly:

```swift
        .onAppear {
            themeManager.loadFromGhosttyConfig()
            let store = self.statusStore
            GhosttyBridge.shared.onCommandFinished = { tid, code, dur, at in
                store.setFinished(terminalId: tid, exitCode: code, duration: dur, at: at)
            }
        }
```

- [ ] **Step 5: Build**

Run: `xcodebuild -project TheAll.xcodeproj -scheme TheAll -configuration Debug build 2>&1 | tail -20`
Expected: BUILD SUCCEEDED.

If there are tests that reference `SidebarListBridge` with the old signature (`TheAllTests/SidebarListBridgeTests.swift`), fix them inline — typically just add `statusStore: TerminalStatusStore()` to the test's `SidebarListBridge(...)` initializer.

- [ ] **Step 6: Commit (Tasks 10, 11, 12 together)**

```bash
git add TheAll/TabContent/TabBarView.swift \
        TheAll/TabContent/TabContentView.swift \
        TheAll/Sidebar/WorkspaceListView.swift \
        TheAll/Bridge/TabBridge.swift \
        TheAll/Bridge/SidebarListBridge.swift \
        TheAll/Sidebar/SidebarView.swift \
        TheAll/ContentView.swift \
        TheAllTests/SidebarListBridgeTests.swift
git commit -m "$(cat <<'EOF'
feat(ui): render terminal status icon in tab items and sidebar rows

Tab icon sits left of title; sidebar row icon sits top-right next to
PR badge. Aggregation follows running > failed > success > neverRan.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 13: Emit "running" on fallback (since ghostty may not have prompt-start action)

**Files:**
- Modify: `TheAll/Ghostty/GhosttyBridge.swift`
- Modify: `TheAll/ContentView.swift`

Rationale: `COMMAND_FINISHED` alone doesn't tell us when a command *starts*. We need to flip a terminal to `.running` between prompt A-start and the C → D flow. Options explored in spec; here we take the pragmatic approach: treat the terminal as `.running` at the moment the first non-zero-length data is received from the shell after a prompt — which in practice we approximate by: **set `.running` whenever we receive a user key-down after a prompt-idle state**.

Actually, a simpler-and-correct approach that avoids guessing: **on every `setFinished`, we know a command ended; a new one starts when the user hits Enter after typing**. Since the only ghostty actions we have are `COMMAND_FINISHED` + (probably) `PROMPT_TITLE`, we accept that the "running" state only becomes visible at the *end* of the first command.

For MVP, we pragmatically do: **when a key-down reaches `GhosttyTerminalView.keyDown` and the key is `Return` (keycode 36), mark the associated terminal as `.running`.** This is crude but functional. When `COMMAND_FINISHED` arrives, it flips to success/failed. If the shell shows a prompt briefly (no command entered), the user barely sees the running flash — acceptable.

- [ ] **Step 1: Add an `onEnterKey` hook to `GhosttyBridge` called from `GhosttyTerminalView.keyDown`**

In `GhosttyBridge.swift`, alongside `onCommandFinished`, add:

```swift
    /// Called on Return keydown in a surface — heuristic used to flip status to running.
    /// Main queue.
    var onEnterKey: ((_ terminalId: UUID, _ at: Date) -> Void)?
```

In `GhosttyTerminalView.keyDown(with:)`, at the top, before `interpretKeyEvents`:

```swift
        if event.keyCode == 36, let tid = terminalId {   // Return key
            GhosttyBridge.shared.onEnterKey?(tid, Date())
        }
```

- [ ] **Step 2: Wire `onEnterKey` in `ContentView.onAppear`**

```swift
            GhosttyBridge.shared.onEnterKey = { tid, at in
                // Only flip to running if NOT already running (avoid resetting startedAt every keypress cycle)
                if case .running = store.status(for: tid) { return }
                store.setRunning(terminalId: tid, at: at)
            }
```

(Rename `store` in the capture to avoid shadowing; the local `let store = self.statusStore` already exists.)

- [ ] **Step 3: Build, run, and manually test the lifecycle**

Build. Launch. Open a terminal, type `sleep 3 && echo done`, hit Enter:
- Tab icon should switch to spinning arc immediately
- ~3s later should flip to solid green dot (success)

Then type `false`, Enter:
- Spinner briefly → solid red dot (failed)

If spinner doesn't appear at all, check `keyCode == 36` — some keyboards emit different codes for Enter (especially numpad Enter is 76).

- [ ] **Step 4: Commit**

```bash
git add TheAll/Ghostty/GhosttyBridge.swift \
        TheAll/Ghostty/GhosttyTerminalView.swift \
        TheAll/ContentView.swift
git commit -m "$(cat <<'EOF'
feat(ghostty): heuristic running-state trigger on Return keydown

OSC 133 gives us COMMAND_FINISHED but no reliable STARTED. Approximate
by flipping status to .running on Return key. Cheap, good enough for
the common case of 'user types command + Enter'.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 14: Tooltips

**Files:**
- Modify: `TheAll/Theme/TerminalStatusIconView.swift`

- [ ] **Step 1: Set `toolTip` based on status at end of `update(status:theme:)`**

At the end of `TerminalStatusIconView.update(status:theme:)`:

```swift
        toolTip = Self.tooltipText(for: status)
```

Add to the class:

```swift
    static func tooltipText(for status: TerminalStatus) -> String? {
        switch status {
        case .neverRan:
            return nil
        case .running(let startedAt):
            let elapsed = max(0, Date().timeIntervalSince(startedAt))
            return "Running for \(Self.formatDuration(elapsed))"
        case .success(let exit, let duration, _):
            return "Succeeded in \(Self.formatDuration(duration)) · exit \(exit)"
        case .failed(let exit, let duration, _):
            return "Failed after \(Self.formatDuration(duration)) · exit \(exit)"
        }
    }

    static func formatDuration(_ seconds: TimeInterval) -> String {
        if seconds < 1 { return "<1s" }
        if seconds < 60 { return "\(Int(seconds))s" }
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        return s == 0 ? "\(m)m" : "\(m)m\(s)s"
    }
```

- [ ] **Step 2: Build and manually verify**

Build, launch, run a long `sleep 30`, hover the tab icon. Tooltip should read e.g. `"Running for 12s"`. After finish, should show `"Succeeded in 30s · exit 0"`.

- [ ] **Step 3: Unit test the formatter**

Append to `TheAllTests/TerminalStatusTests.swift`:

```swift
    func testTooltipFormatDuration() {
        XCTAssertEqual(TerminalStatusIconView.formatDuration(0.2), "<1s")
        XCTAssertEqual(TerminalStatusIconView.formatDuration(5), "5s")
        XCTAssertEqual(TerminalStatusIconView.formatDuration(59), "59s")
        XCTAssertEqual(TerminalStatusIconView.formatDuration(60), "1m")
        XCTAssertEqual(TerminalStatusIconView.formatDuration(151), "2m31s")
    }

    func testTooltipTextForEachState() {
        XCTAssertNil(TerminalStatusIconView.tooltipText(for: .neverRan))
        let now = Date()
        XCTAssertEqual(
            TerminalStatusIconView.tooltipText(for: .success(exitCode: 0, duration: 151, finishedAt: now)),
            "Succeeded in 2m31s · exit 0")
        XCTAssertEqual(
            TerminalStatusIconView.tooltipText(for: .failed(exitCode: 1, duration: 5, finishedAt: now)),
            "Failed after 5s · exit 1")
        // running tooltip text varies with time, so just check prefix
        let rt = TerminalStatusIconView.tooltipText(for: .running(startedAt: now)) ?? ""
        XCTAssertTrue(rt.hasPrefix("Running for"))
    }
```

- [ ] **Step 4: Run tests**

Run: `xcodebuild test -project TheAll.xcodeproj -scheme TheAllTests -only-testing:TheAllTests/TerminalStatusTests 2>&1 | tail -20`
Expected: all TerminalStatus tests pass (including new tooltip ones).

- [ ] **Step 5: Commit**

```bash
git add TheAll/Theme/TerminalStatusIconView.swift TheAllTests/TerminalStatusTests.swift
git commit -m "$(cat <<'EOF'
feat(ui): tooltip on status icon showing duration and exit code

Hover a running icon to see "Running for 1m23s"; finished icons show
"Succeeded in 2m31s · exit 0" or "Failed after 5s · exit 1".

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 15: Forget terminal status on close

**Files:**
- Modify: `TheAll/ContentView.swift`
- Modify: `TheAll/Models/WorkspaceStore.swift` (add change observation hook)

Garbage collect store entries when a terminal is removed (`closeTerminal` / `removeTab` / `deleteWorkspace`). Avoid a growing-forever map across long sessions.

- [ ] **Step 1: Simplest approach — purge on every `ContentView` change**

After the `onAppear` hook, add an `.onChange(of: store.workspaces)` handler that syncs the status store:

```swift
        .onChange(of: store.workspaces) { _, workspaces in
            let live = Set(workspaces.flatMap { ws in
                ws.tabs.flatMap { $0.layout.allTerminalIds() }
            })
            for (id, _) in statusStore.statusesSnapshot() where !live.contains(id) {
                statusStore.forget(terminalId: id)
            }
        }
```

(Needs `statusesSnapshot()` which we already added in Task 2.)

- [ ] **Step 2: Build**

Run: `xcodebuild -project TheAll.xcodeproj -scheme TheAll -configuration Debug build 2>&1 | tail -10`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Manually verify**

Launch, run a command in a terminal to set its state to success. Close the tab. Open a new one — it should be neverRan (empty outline), not inherit the previous terminal's success dot.

- [ ] **Step 4: Commit**

```bash
git add TheAll/ContentView.swift
git commit -m "$(cat <<'EOF'
feat(status): forget status entries for terminals that no longer exist

Prevents the in-memory store from accumulating stale entries across
long-running app sessions.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Final verification

- [ ] **Step 1: Full test suite**

Run: `xcodebuild test -project TheAll.xcodeproj -scheme TheAllTests 2>&1 | tail -30`
Expected: all tests pass (including pre-existing and new suites).

- [ ] **Step 2: Full build**

Run: `xcodebuild -project TheAll.xcodeproj -scheme TheAll -configuration Debug build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: End-to-end manual verification**

Launch app. Verify:

1. Fresh tab → empty outline icon on both sidebar row and tab item.
2. Type `sleep 2` + Enter → both icons spin for ~2s.
3. After `sleep` finishes → both icons become solid green.
4. Type `false` + Enter → briefly spin → both become solid red.
5. Create a second tab with `sleep 30` running → sidebar row shows spinning (running wins over any success in first tab).
6. Kill the `sleep 30` with Ctrl+C → sidebar row flips to red (failed > success).
7. Hover tab icon → tooltip shows "Running for Xs" / "Succeeded in Xs · exit 0".
8. Close the failing tab → remaining tabs' status unaffected.
9. Quit and relaunch the app → all terminals back to empty outline (state is session-only).

- [ ] **Step 4: If everything passes, summarize**

Report to user:
> "All 15 tasks complete, full test suite green, end-to-end flow verified. Four-state status indicator live on tabs and sidebar, sourced from ghostty OSC 133 with Return-key heuristic for running-state detection."

---

## Known Limitations Worth Documenting

These should be captured in `docs/decisions/YYYY-MM-DD-terminal-status-icon.md` as a single decision note after merging. The plan doesn't include authoring that file — the user can decide whether to.

1. **Running-state detection relies on Enter keycode 36**. Numpad Enter, some international layouts, and commands pasted + auto-submitted via shell extensions may not trigger it. Acceptable MVP tradeoff — a follow-up can add `GHOSTTY_ACTION_PROMPT_TITLE` or OSC 133 C parsing if ghostty exposes it.

2. **Background commands, subshells, pipelines**: OSC 133 COMMAND_FINISHED fires once per logical command. `(sleep 3 &); ls` behaves as "ls finished" → success, even though `sleep` is still backgrounded. Matches typical terminal-user mental model; no attempt to model job control.

3. **SSH / tmux**: shell integration doesn't propagate through SSH or tmux by default. A terminal running `ssh host` will stay `.running` until the SSH session ends. Acceptable — users typically treat the SSH session itself as "the command".
