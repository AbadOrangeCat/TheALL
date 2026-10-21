# theall Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build theall, a macOS terminal app using libghostty that features a 180px SwiftUI sidebar (workspace tabs with git/PR/port/notification info) and an AppKit free-floating whiteboard canvas where multiple terminal windows can be dragged, overlapped, and arranged freely.

**Architecture:** SwiftUI handles the sidebar (WorkspaceListView), AppKit handles the whiteboard canvas (NSScrollView + NSView-based draggable TerminalWindowViews), bridged via NSViewRepresentable. Each TerminalWindowView holds a `ghostty_surface_t` from libghostty. A ThemeManager reads ghostty's config file and macOS system appearance to drive a single AppTheme token struct used by all views.

**Tech Stack:** Swift 5.9+, AppKit, SwiftUI, libghostty (C API), Metal, XCTest, xcodegen

---

## File Map

```
TheAll/
├── project.yml                              — xcodegen config
├── Vendor/ghostty/
│   ├── include/ghostty.h                   — libghostty C header (from ghostty build)
│   └── lib/libghostty.dylib                — libghostty dynamic library
├── TheAll/
│   ├── TheAllApp.swift                        — @main entry, ghostty_init, AppDelegate
│   ├── ContentView.swift                    — root HStack(SidebarView + CanvasBridge)
│   ├── Ghostty/
│   │   ├── ghostty-bridging-header.h        — #import "ghostty.h"
│   │   ├── GhosttyBridge.swift              — GhosttyApp singleton: config + app_t lifecycle
│   │   └── GhosttyTerminalView.swift        — NSView: surface + Metal layer + input forwarding
│   ├── Theme/
│   │   ├── AppTheme.swift                   — AppTheme struct: background/foreground/border/accent tokens
│   │   └── ThemeManager.swift               — @Observable: parse ghostty config + system appearance
│   ├── Models/
│   │   ├── Workspace.swift                  — Workspace + TerminalState structs (Codable)
│   │   └── WorkspaceStore.swift             — @Observable store: CRUD + UserDefaults persistence
│   ├── Metadata/
│   │   ├── WorkspaceMetadata.swift          — WorkspaceMetadata observable struct
│   │   └── MetadataRefresher.swift          — background 5s poll: git branch + lsof ports
│   ├── Canvas/
│   │   ├── TitleBarView.swift               — NSView: traffic lights + drag handle
│   │   ├── TerminalWindowView.swift         — NSView: TitleBar + GhosttyTerminalView, cornerRadius=12
│   │   ├── CanvasContentView.swift          — NSView: infinite canvas, double-click creates terminal
│   │   └── CanvasScrollView.swift           — NSScrollView wrapping CanvasContentView
│   ├── Sidebar/
│   │   ├── SidebarView.swift                — SwiftUI WorkspaceListView (180px)
│   │   └── WorkspaceRowView.swift           — SwiftUI row: name, branch, PR badge, ports, notification
│   └── Bridge/
│       └── CanvasBridge.swift               — NSViewRepresentable wrapping CanvasScrollView
└── TheAllTests/
    ├── ThemeManagerTests.swift
    ├── WorkspaceStoreTests.swift
    └── MetadataRefresherTests.swift
```

---

## Task 1: Project scaffold + libghostty linking

**Files:**
- Create: `project.yml`
- Create: `TheAll/Ghostty/ghostty-bridging-header.h`
- Create: `TheAll/TheAllApp.swift` (stub)

- [ ] **Step 1: Install xcodegen**

```bash
brew install xcodegen
```

Expected: `xcodegen version 2.x.x`

- [ ] **Step 2: Build libghostty from ghostty source**

```bash
git clone https://github.com/ghostty-org/ghostty /tmp/ghostty-src
cd /tmp/ghostty-src
zig build -Doptimize=ReleaseFast 2>&1 | tail -5
mkdir -p /Users/chengtu/Documents/repos/TheAll/Vendor/ghostty/include
mkdir -p /Users/chengtu/Documents/repos/TheAll/Vendor/ghostty/lib
cp /tmp/ghostty-src/zig-out/include/ghostty.h /Users/chengtu/Documents/repos/TheAll/Vendor/ghostty/include/
cp /tmp/ghostty-src/zig-out/lib/libghostty.dylib /Users/chengtu/Documents/repos/TheAll/Vendor/ghostty/lib/
```

Expected: files exist at `Vendor/ghostty/include/ghostty.h` and `Vendor/ghostty/lib/libghostty.dylib`.

- [ ] **Step 3: Create bridging header**

Create `TheAll/Ghostty/ghostty-bridging-header.h`:

```c
#ifndef ghostty_bridging_header_h
#define ghostty_bridging_header_h
#include "../../Vendor/ghostty/include/ghostty.h"
#endif
```

- [ ] **Step 4: Create xcodegen project.yml**

Create `project.yml`:

```yaml
name: TheAll
options:
  bundleIdPrefix: com.theall
  deploymentTarget:
    macOS: "14.0"
  xcodeVersion: "15"

targets:
  TheAll:
    type: application
    platform: macOS
    sources:
      - theall
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.theall.app
        SWIFT_OBJC_BRIDGING_HEADER: TheAll/Ghostty/ghostty-bridging-header.h
        LIBRARY_SEARCH_PATHS: $(PROJECT_DIR)/Vendor/ghostty/lib
        HEADER_SEARCH_PATHS: $(PROJECT_DIR)/Vendor/ghostty/include
        OTHER_LDFLAGS: -lghostty -rpath @executable_path/../Frameworks
        MACOSX_DEPLOYMENT_TARGET: "14.0"
        LD_RUNPATH_SEARCH_PATHS: "@executable_path/../Frameworks $(inherited)"
    dependencies:
      - sdk: Metal.framework
      - sdk: QuartzCore.framework
      - sdk: AppKit.framework
    preBuildScripts:
      - name: Copy libghostty
        script: |
          FRAMEWORKS="$BUILT_PRODUCTS_DIR/$FRAMEWORKS_FOLDER_PATH"
          mkdir -p "$FRAMEWORKS"
          cp "$PROJECT_DIR/Vendor/ghostty/lib/libghostty.dylib" "$FRAMEWORKS/libghostty.dylib"
          install_name_tool -change @rpath/libghostty.dylib @rpath/libghostty.dylib "$FRAMEWORKS/libghostty.dylib" || true

  TheAllTests:
    type: bundle.unit-test
    platform: macOS
    sources:
      - TheAllTests
    settings:
      base:
        MACOSX_DEPLOYMENT_TARGET: "14.0"
    dependencies:
      - target: TheAll
```

- [ ] **Step 5: Create minimal app stub**

Create `TheAll/TheAllApp.swift`:

```swift
import SwiftUI

@main
struct TheAllApp: App {
    var body: some Scene {
        WindowGroup {
            Text("theall loading...")
        }
    }
}
```

- [ ] **Step 6: Generate Xcode project and verify build**

```bash
cd /Users/chengtu/Documents/repos/theall
mkdir -p TheAllTests
xcodegen generate
xcodebuild build -scheme TheAll -destination 'platform=macOS' 2>&1 | grep -E 'error:|BUILD SUCCEEDED|BUILD FAILED'
```

Expected: `BUILD SUCCEEDED`

- [ ] **Step 7: Commit**

```bash
git add project.yml TheAll/ TheAllTests/ .gitignore
git commit -m "chore: scaffold Xcode project with libghostty linking"
```

---

## Task 2: AppTheme + ThemeManager

**Files:**
- Create: `TheAll/Theme/AppTheme.swift`
- Create: `TheAll/Theme/ThemeManager.swift`
- Create: `TheAllTests/ThemeManagerTests.swift`

- [ ] **Step 1: Write failing test**

Create `TheAllTests/ThemeManagerTests.swift`:

```swift
import XCTest
@testable import TheAll

final class ThemeManagerTests: XCTestCase {

    func testDefaultThemeIsNotNil() {
        let manager = ThemeManager()
        XCTAssertNotNil(manager.theme)
    }

    func testDarkSchemeHasDarkBackground() {
        let manager = ThemeManager()
        manager.applyScheme(.dark)
        // background should be darker than 0.3 brightness
        let brightness = manager.theme.background.brightnessComponent
        XCTAssertLessThan(Double(brightness), 0.3)
    }

    func testLightSchemeHasLightBackground() {
        let manager = ThemeManager()
        manager.applyScheme(.light)
        let brightness = manager.theme.background.brightnessComponent
        XCTAssertGreaterThan(Double(brightness), 0.7)
    }

    func testParseGhosttyConfigExtractsTheme() {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("ghostty-test-config")
        try! "theme = dark\n".write(to: tmp, atomically: true, encoding: .utf8)
        let manager = ThemeManager()
        let result = manager.parseThemeFromConfig(at: tmp.path)
        XCTAssertEqual(result, "dark")
        try? FileManager.default.removeItem(at: tmp)
    }

    func testParseGhosttyConfigReturnNilWhenMissing() {
        let manager = ThemeManager()
        let result = manager.parseThemeFromConfig(at: "/nonexistent/path")
        XCTAssertNil(result)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
xcodebuild test -scheme TheAllTests -destination 'platform=macOS' 2>&1 | grep -E 'error:|FAILED|PASSED|ThemeManager'
```

Expected: compile error — `ThemeManager` not defined.

- [ ] **Step 3: Create AppTheme.swift**

Create `TheAll/Theme/AppTheme.swift`:

```swift
import AppKit

struct AppTheme {
    var background: NSColor
    var foreground: NSColor
    var border: NSColor
    var accent: NSColor
    var selection: NSColor
    var sidebarBackground: NSColor
    var sidebarText: NSColor

    static let dark = AppTheme(
        background: NSColor(red: 0.11, green: 0.11, blue: 0.12, alpha: 1),
        foreground: NSColor(red: 0.82, green: 0.82, blue: 0.82, alpha: 1),
        border: NSColor(red: 0.17, green: 0.17, blue: 0.18, alpha: 1),
        accent: NSColor(red: 0.37, green: 0.70, blue: 0.94, alpha: 1),
        selection: NSColor(red: 0.25, green: 0.45, blue: 0.65, alpha: 1),
        sidebarBackground: NSColor(red: 0.09, green: 0.09, blue: 0.10, alpha: 1),
        sidebarText: NSColor(red: 0.65, green: 0.65, blue: 0.67, alpha: 1)
    )

    static let light = AppTheme(
        background: NSColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 1),
        foreground: NSColor(red: 0.11, green: 0.11, blue: 0.12, alpha: 1),
        border: NSColor(red: 0.87, green: 0.87, blue: 0.89, alpha: 1),
        accent: NSColor(red: 0.00, green: 0.48, blue: 1.00, alpha: 1),
        selection: NSColor(red: 0.78, green: 0.90, blue: 1.00, alpha: 1),
        sidebarBackground: NSColor(red: 0.93, green: 0.93, blue: 0.95, alpha: 1),
        sidebarText: NSColor(red: 0.35, green: 0.35, blue: 0.38, alpha: 1)
    )
}
```

- [ ] **Step 4: Create ThemeManager.swift**

Create `TheAll/Theme/ThemeManager.swift`:

```swift
import AppKit
import Observation

enum ColorSchemePreference {
    case dark, light, system
}

@Observable
final class ThemeManager {
    private(set) var theme: AppTheme = .dark
    private var currentScheme: ColorSchemePreference = .system

    init() {
        applyScheme(.system)
        observeSystemAppearance()
    }

    func applyScheme(_ scheme: ColorSchemePreference) {
        currentScheme = scheme
        switch scheme {
        case .dark:
            theme = .dark
        case .light:
            theme = .light
        case .system:
            let isDark = NSApp?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            theme = isDark ? .dark : .light
        }
    }

    /// Read `theme =` value from ghostty config file. Returns nil if not found or file unreadable.
    func parseThemeFromConfig(at path: String) -> String? {
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        for line in contents.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("#"), trimmed.hasPrefix("theme") else { continue }
            let parts = trimmed.components(separatedBy: "=")
            guard parts.count == 2 else { continue }
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            if !value.isEmpty { return value }
        }
        return nil
    }

    /// Load theme from ghostty default config location. Falls back to system appearance.
    func loadFromGhosttyConfig() {
        let defaultPath = (NSHomeDirectory() as NSString).appendingPathComponent(".config/ghostty/config")
        if let themeName = parseThemeFromConfig(at: defaultPath) {
            // Map known ghostty theme names to our schemes
            let lower = themeName.lowercased()
            if lower.contains("light") {
                applyScheme(.light)
            } else {
                applyScheme(.dark)
            }
        } else {
            applyScheme(.system)
        }
    }

    private func observeSystemAppearance() {
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self, self.currentScheme == .system else { return }
            self.applyScheme(.system)
        }
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

```bash
xcodebuild test -scheme TheAllTests -destination 'platform=macOS' 2>&1 | grep -E 'Test.*passed|Test.*failed|PASSED|FAILED'
```

Expected: all 5 ThemeManager tests pass.

- [ ] **Step 6: Commit**

```bash
git add TheAll/Theme/ TheAllTests/ThemeManagerTests.swift
git commit -m "feat: add AppTheme tokens and ThemeManager with ghostty config parsing"
```

---

## Task 3: Workspace model + WorkspaceStore

**Files:**
- Create: `TheAll/Models/Workspace.swift`
- Create: `TheAll/Models/WorkspaceStore.swift`
- Create: `TheAllTests/WorkspaceStoreTests.swift`

- [ ] **Step 1: Write failing tests**

Create `TheAllTests/WorkspaceStoreTests.swift`:

```swift
import XCTest
@testable import TheAll

final class WorkspaceStoreTests: XCTestCase {

    func testCreateWorkspace() {
        let store = WorkspaceStore(persistenceKey: "test-\(UUID())")
        store.createWorkspace(name: "my-project")
        XCTAssertEqual(store.workspaces.count, 1)
        XCTAssertEqual(store.workspaces[0].name, "my-project")
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

    func testAddTerminalState() {
        let store = WorkspaceStore(persistenceKey: "test-\(UUID())")
        store.createWorkspace(name: "ws")
        let wsId = store.workspaces[0].id
        let termId = store.addTerminal(to: wsId, frame: CGRect(x: 10, y: 20, width: 600, height: 400))
        XCTAssertNotNil(termId)
        XCTAssertEqual(store.workspaces[0].terminalStates.count, 1)
    }

    func testUpdateTerminalFrame() {
        let store = WorkspaceStore(persistenceKey: "test-\(UUID())")
        store.createWorkspace(name: "ws")
        let wsId = store.workspaces[0].id
        let termId = store.addTerminal(to: wsId, frame: CGRect(x: 0, y: 0, width: 600, height: 400))!
        let newFrame = CGRect(x: 100, y: 150, width: 700, height: 500)
        store.updateTerminalFrame(id: termId, in: wsId, frame: newFrame)
        let saved = store.workspaces[0].terminalStates[0].frame
        XCTAssertEqual(saved, newFrame)
    }

    func testPersistenceRoundTrip() {
        let key = "test-persist-\(UUID())"
        let store1 = WorkspaceStore(persistenceKey: key)
        store1.createWorkspace(name: "persistent")
        let id1 = store1.workspaces[0].id

        let store2 = WorkspaceStore(persistenceKey: key)
        XCTAssertEqual(store2.workspaces.count, 1)
        XCTAssertEqual(store2.workspaces[0].id, id1)
        XCTAssertEqual(store2.workspaces[0].name, "persistent")

        UserDefaults.standard.removeObject(forKey: key)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
xcodebuild test -scheme TheAllTests -destination 'platform=macOS' 2>&1 | grep -E 'error:|WorkspaceStore'
```

Expected: compile error — `WorkspaceStore` not defined.

- [ ] **Step 3: Create Workspace.swift**

Create `TheAll/Models/Workspace.swift`:

```swift
import Foundation
import CoreGraphics

struct TerminalState: Codable, Identifiable {
    let id: UUID
    var frame: CGRect

    init(id: UUID = UUID(), frame: CGRect) {
        self.id = id
        self.frame = frame
    }
}

struct Workspace: Codable, Identifiable {
    let id: UUID
    var name: String
    var terminalStates: [TerminalState]

    init(id: UUID = UUID(), name: String) {
        self.id = id
        self.name = name
        self.terminalStates = []
    }
}
```

- [ ] **Step 4: Create WorkspaceStore.swift**

Create `TheAll/Models/WorkspaceStore.swift`:

```swift
import Foundation
import Observation

@Observable
final class WorkspaceStore {
    private(set) var workspaces: [Workspace] = []
    private(set) var selectedId: UUID?
    private let persistenceKey: String

    init(persistenceKey: String = "theall.workspaces") {
        self.persistenceKey = persistenceKey
        load()
        if workspaces.isEmpty {
            createWorkspace(name: "Default")
        }
        if selectedId == nil {
            selectedId = workspaces.first?.id
        }
    }

    var selectedWorkspace: Workspace? {
        workspaces.first { $0.id == selectedId }
    }

    func createWorkspace(name: String) {
        let ws = Workspace(name: name)
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

    @discardableResult
    func addTerminal(to workspaceId: UUID, frame: CGRect) -> UUID? {
        guard let idx = workspaces.firstIndex(where: { $0.id == workspaceId }) else { return nil }
        let state = TerminalState(frame: frame)
        workspaces[idx].terminalStates.append(state)
        save()
        return state.id
    }

    func removeTerminal(id: UUID, from workspaceId: UUID) {
        guard let idx = workspaces.firstIndex(where: { $0.id == workspaceId }) else { return }
        workspaces[idx].terminalStates.removeAll { $0.id == id }
        save()
    }

    func updateTerminalFrame(id: UUID, in workspaceId: UUID, frame: CGRect) {
        guard let wsIdx = workspaces.firstIndex(where: { $0.id == workspaceId }),
              let tIdx = workspaces[wsIdx].terminalStates.firstIndex(where: { $0.id == id })
        else { return }
        workspaces[wsIdx].terminalStates[tIdx].frame = frame
        save()
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

- [ ] **Step 5: Run tests to verify they pass**

```bash
xcodebuild test -scheme TheAllTests -destination 'platform=macOS' 2>&1 | grep -E 'Test.*passed|Test.*failed|PASSED|FAILED'
```

Expected: all 6 WorkspaceStore tests pass.

- [ ] **Step 6: Commit**

```bash
git add TheAll/Models/ TheAllTests/WorkspaceStoreTests.swift
git commit -m "feat: add Workspace model and WorkspaceStore with persistence"
```

---

## Task 4: GhosttyBridge (libghostty Swift wrapper)

**Files:**
- Create: `TheAll/Ghostty/GhosttyBridge.swift`

No unit tests for this task — libghostty requires a running process; tested via integration in Task 5.

- [ ] **Step 1: Create GhosttyBridge.swift**

Create `TheAll/Ghostty/GhosttyBridge.swift`:

```swift
import Foundation
import AppKit

/// Singleton wrapper around the libghostty app instance.
/// Must call `GhosttyBridge.shared.initialize()` once at app startup.
final class GhosttyBridge {
    static let shared = GhosttyBridge()

    private(set) var app: ghostty_app_t?
    private(set) var config: ghostty_config_t?
    private(set) var isInitialized = false

    private init() {}

    /// Returns true on success. Call once from TheAllApp.init().
    @discardableResult
    func initialize() -> Bool {
        // ghostty_init must be called before anything else
        let argc = CommandLine.argc
        var args = CommandLine.unsafeArgv
        guard ghostty_init(UInt(argc), &args) == 0 else {
            print("[GhosttyBridge] ghostty_init failed")
            return false
        }

        // Build config from default ghostty files
        guard let cfg = ghostty_config_new() else {
            print("[GhosttyBridge] ghostty_config_new failed")
            return false
        }
        ghostty_config_load_default_files(cfg)
        ghostty_config_load_recursive_files(cfg)
        ghostty_config_finalize(cfg)
        self.config = cfg

        // Build runtime callbacks — use @convention(c) static functions
        var rtConfig = ghostty_runtime_config_s()
        rtConfig.userdata = Unmanaged.passUnretained(self).toOpaque()
        rtConfig.supports_selection_clipboard = false
        rtConfig.wakeup_cb = GhosttyBridge.wakeupCallback
        rtConfig.action_cb = GhosttyBridge.actionCallback
        rtConfig.close_surface_cb = GhosttyBridge.closeSurfaceCallback
        rtConfig.read_clipboard_cb = GhosttyBridge.readClipboardCallback
        rtConfig.confirm_read_clipboard_cb = GhosttyBridge.confirmReadClipboardCallback
        rtConfig.write_clipboard_cb = GhosttyBridge.writeClipboardCallback

        guard let appHandle = ghostty_app_new(&rtConfig, cfg) else {
            print("[GhosttyBridge] ghostty_app_new failed")
            return false
        }
        self.app = appHandle
        self.isInitialized = true
        return true
    }

    func teardown() {
        if let a = app { ghostty_app_free(a) }
        if let c = config { ghostty_config_free(c) }
        app = nil
        config = nil
        isInitialized = false
    }

    // MARK: - Surface factory

    /// Create a new terminal surface. Caller is responsible for calling ghostty_surface_free().
    func newSurface(metalLayer: CAMetalLayer, scaleFactor: Double, workingDirectory: String?) -> ghostty_surface_t? {
        guard isInitialized, let appHandle = app else { return nil }

        var surfCfg = ghostty_surface_config_new()
        surfCfg.scale_factor = scaleFactor
        if let wd = workingDirectory {
            surfCfg.working_directory = (wd as NSString).utf8String
        }

        // Platform: macOS Metal
        // ghostty_platform_e value for macOS Metal — verify exact enum name in ghostty.h
        surfCfg.platform_tag = GHOSTTY_PLATFORM_MACOS_METAL
        surfCfg.platform.macos_metal.layer = Unmanaged.passRetained(metalLayer).toOpaque()

        return ghostty_surface_new(appHandle, &surfCfg)
    }

    // MARK: - Color scheme

    func applyColorScheme(_ isDark: Bool) {
        guard let appHandle = app else { return }
        let scheme: ghostty_color_scheme_e = isDark ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT
        ghostty_app_set_color_scheme(appHandle, scheme)
    }

    // MARK: - C callbacks (@convention(c) static functions)

    private static let wakeupCallback: ghostty_runtime_wakeup_cb = { userdata in
        guard let ptr = userdata else { return }
        let bridge = Unmanaged<GhosttyBridge>.fromOpaque(ptr).takeUnretainedValue()
        DispatchQueue.main.async { ghostty_app_tick(bridge.app!) }
    }

    private static let actionCallback: ghostty_runtime_action_cb = { _, _, _ in
        return false
    }

    private static let closeSurfaceCallback: ghostty_runtime_close_surface_cb = { _, _ in }

    private static let readClipboardCallback: ghostty_runtime_read_clipboard_cb = { userdata, _, requestCtx in
        let text = NSPasteboard.general.string(forType: .string) ?? ""
        // ghostty expects the result passed back via complete_clipboard_request
        // actual implementation wires through the surface — no-op here is safe for v1
        return false
    }

    private static let confirmReadClipboardCallback: ghostty_runtime_confirm_read_clipboard_cb = { _, _, _, _ in }

    private static let writeClipboardCallback: ghostty_runtime_write_clipboard_cb = { _, _, content, count, _ in
        guard let content = content else { return }
        for i in 0..<count {
            let item = content[i]
            if let ptr = item.data, let str = String(cString: ptr, encoding: .utf8) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(str, forType: .string)
            }
        }
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

```bash
xcodebuild build -scheme TheAll -destination 'platform=macOS' 2>&1 | grep -E 'error:|BUILD SUCCEEDED|BUILD FAILED'
```

Expected: `BUILD SUCCEEDED`. If `GHOSTTY_PLATFORM_MACOS_METAL` or `platform.macos_metal` don't match exact names in `ghostty.h`, grep the header and fix:

```bash
grep -i "macos_metal\|platform_tag\|ghostty_platform" Vendor/ghostty/include/ghostty.h | head -20
```

- [ ] **Step 3: Commit**

```bash
git add TheAll/Ghostty/
git commit -m "feat: add GhosttyBridge singleton wrapping libghostty C API"
```

---

## Task 5: GhosttyTerminalView (NSView + surface rendering)

**Files:**
- Create: `TheAll/Ghostty/GhosttyTerminalView.swift`

- [ ] **Step 1: Create GhosttyTerminalView.swift**

Create `TheAll/Ghostty/GhosttyTerminalView.swift`:

```swift
import AppKit
import QuartzCore

/// NSView that owns a ghostty_surface_t and renders via Metal.
final class GhosttyTerminalView: NSView {
    private var surface: ghostty_surface_t?
    private var metalLayer: CAMetalLayer?
    private var displayLink: CVDisplayLink?

    override init(frame: NSRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        wantsLayer = true
        let ml = CAMetalLayer()
        ml.frame = bounds
        ml.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        layer?.addSublayer(ml)
        self.metalLayer = ml

        let scale = window?.backingScaleFactor ?? 2.0
        surface = GhosttyBridge.shared.newSurface(
            metalLayer: ml,
            scaleFactor: scale,
            workingDirectory: nil
        )
        if let s = surface {
            ghostty_surface_set_size(s, UInt32(bounds.width * scale), UInt32(bounds.height * scale))
        }
        startDisplayLink()
    }

    deinit {
        stopDisplayLink()
        if let s = surface { ghostty_surface_free(s) }
    }

    // MARK: - Display link

    private func startDisplayLink() {
        CVDisplayLinkCreateWithActiveCGDisplays(&displayLink)
        guard let dl = displayLink else { return }
        CVDisplayLinkSetOutputCallback(dl, { _, _, _, _, _, ctx -> CVReturn in
            let view = Unmanaged<GhosttyTerminalView>.fromOpaque(ctx!).takeUnretainedValue()
            DispatchQueue.main.async {
                if let s = view.surface { ghostty_surface_draw(s) }
            }
            return kCVReturnSuccess
        }, Unmanaged.passUnretained(self).toOpaque())
        CVDisplayLinkStart(dl)
    }

    private func stopDisplayLink() {
        if let dl = displayLink { CVDisplayLinkStop(dl) }
    }

    // MARK: - Layout

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        let scale = window?.backingScaleFactor ?? 2.0
        metalLayer?.frame = bounds
        if let s = surface {
            ghostty_surface_set_size(s, UInt32(newSize.width * scale), UInt32(newSize.height * scale))
            ghostty_surface_set_content_scale(s, scale, scale)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let s = surface {
            let scale = window?.backingScaleFactor ?? 2.0
            ghostty_surface_set_content_scale(s, scale, scale)
        }
    }

    // MARK: - Focus

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        if let s = surface { ghostty_surface_set_focus(s, true) }
        return true
    }

    override func resignFirstResponder() -> Bool {
        if let s = surface { ghostty_surface_set_focus(s, false) }
        return true
    }

    // MARK: - Keyboard input

    override func keyDown(with event: NSEvent) {
        guard let s = surface else { return }
        var input = ghostty_input_key_s()
        input.action = GHOSTTY_INPUT_ACTION_PRESS
        input.mods = modsFromEvent(event)
        input.keycode = event.keyCode
        if let chars = event.characters {
            input.text = (chars as NSString).utf8String
        }
        if !ghostty_surface_key(s, input) {
            super.keyDown(with: event)
        }
    }

    override func keyUp(with event: NSEvent) {
        guard let s = surface else { return }
        var input = ghostty_input_key_s()
        input.action = GHOSTTY_INPUT_ACTION_RELEASE
        input.mods = modsFromEvent(event)
        input.keycode = event.keyCode
        _ = ghostty_surface_key(s, input)
    }

    // MARK: - Mouse input

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard let s = surface else { return }
        let pt = convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(s, pt.x, bounds.height - pt.y, modsFromEvent(event))
        _ = ghostty_surface_mouse_button(s, GHOSTTY_INPUT_MOUSE_STATE_PRESS,
                                          GHOSTTY_INPUT_MOUSE_BUTTON_LEFT, modsFromEvent(event))
    }

    override func mouseUp(with event: NSEvent) {
        guard let s = surface else { return }
        let pt = convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(s, pt.x, bounds.height - pt.y, modsFromEvent(event))
        _ = ghostty_surface_mouse_button(s, GHOSTTY_INPUT_MOUSE_STATE_RELEASE,
                                          GHOSTTY_INPUT_MOUSE_BUTTON_LEFT, modsFromEvent(event))
    }

    override func mouseMoved(with event: NSEvent) {
        guard let s = surface else { return }
        let pt = convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(s, pt.x, bounds.height - pt.y, modsFromEvent(event))
    }

    override func scrollWheel(with event: NSEvent) {
        guard let s = surface else { return }
        ghostty_surface_mouse_scroll(s, event.scrollingDeltaX, event.scrollingDeltaY, 0)
    }

    // MARK: - Helpers

    private func modsFromEvent(_ event: NSEvent) -> ghostty_input_mods_e {
        var mods = ghostty_input_mods_e(rawValue: 0)
        if event.modifierFlags.contains(.shift)   { mods.insert(GHOSTTY_INPUT_MODS_SHIFT) }
        if event.modifierFlags.contains(.control) { mods.insert(GHOSTTY_INPUT_MODS_CTRL) }
        if event.modifierFlags.contains(.option)  { mods.insert(GHOSTTY_INPUT_MODS_ALT) }
        if event.modifierFlags.contains(.command) { mods.insert(GHOSTTY_INPUT_MODS_SUPER) }
        return mods
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

```bash
xcodebuild build -scheme TheAll -destination 'platform=macOS' 2>&1 | grep -E 'error:|BUILD SUCCEEDED|BUILD FAILED'
```

If enum constant names (`GHOSTTY_INPUT_ACTION_PRESS`, `GHOSTTY_INPUT_MODS_SHIFT`, etc.) don't match, grep `ghostty.h`:

```bash
grep -E "GHOSTTY_INPUT_ACTION|GHOSTTY_INPUT_MODS|GHOSTTY_INPUT_MOUSE" Vendor/ghostty/include/ghostty.h | head -30
```

- [ ] **Step 3: Commit**

```bash
git add TheAll/Ghostty/GhosttyTerminalView.swift
git commit -m "feat: add GhosttyTerminalView with Metal rendering and input forwarding"
```

---

## Task 6: TitleBarView + TerminalWindowView

**Files:**
- Create: `TheAll/Canvas/TitleBarView.swift`
- Create: `TheAll/Canvas/TerminalWindowView.swift`

- [ ] **Step 1: Create TitleBarView.swift**

Create `TheAll/Canvas/TitleBarView.swift`:

```swift
import AppKit

final class TitleBarView: NSView {
    private var dragOffset: CGPoint = .zero
    var onClose: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        wantsLayer = true

        // Traffic light buttons (close only for v1)
        let closeBtn = makeTrafficLight(color: NSColor(red: 1.0, green: 0.37, blue: 0.34, alpha: 1), x: 10)
        closeBtn.target = self
        closeBtn.action = #selector(closeTapped)
        addSubview(closeBtn)

        let minBtn = makeTrafficLight(color: NSColor(red: 1.0, green: 0.74, blue: 0.18, alpha: 1), x: 28)
        addSubview(minBtn)

        let maxBtn = makeTrafficLight(color: NSColor(red: 0.16, green: 0.78, blue: 0.25, alpha: 1), x: 46)
        addSubview(maxBtn)
    }

    private func makeTrafficLight(color: NSColor, x: CGFloat) -> NSButton {
        let btn = NSButton(frame: NSRect(x: x, y: (frame.height - 12) / 2, width: 12, height: 12))
        btn.bezelStyle = .circular
        btn.isBordered = false
        btn.wantsLayer = true
        btn.layer?.backgroundColor = color.cgColor
        btn.layer?.cornerRadius = 6
        return btn
    }

    @objc private func closeTapped() {
        onClose?()
    }

    // MARK: - Drag support

    override func mouseDown(with event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)
        dragOffset = loc
    }

    override func mouseDragged(with event: NSEvent) {
        guard let parent = superview else { return }
        var origin = parent.frame.origin
        origin.x += event.deltaX
        origin.y -= event.deltaY
        parent.frame.origin = origin
    }

    override func mouseUp(with event: NSEvent) {
        // Notify canvas to persist the new frame
        if let win = superview as? TerminalWindowView {
            win.didFinishDrag()
        }
    }
}
```

- [ ] **Step 2: Create TerminalWindowView.swift**

Create `TheAll/Canvas/TerminalWindowView.swift`:

```swift
import AppKit

final class TerminalWindowView: NSView {
    let terminalId: UUID
    private let titleBar: TitleBarView
    private let terminalView: GhosttyTerminalView
    var onClose: ((UUID) -> Void)?
    var onFrameChanged: ((UUID, CGRect) -> Void)?

    static let titleBarHeight: CGFloat = 32

    init(id: UUID, frame: NSRect, theme: AppTheme) {
        self.terminalId = id
        self.titleBar = TitleBarView(frame: NSRect(x: 0, y: frame.height - Self.titleBarHeight,
                                                    width: frame.width, height: Self.titleBarHeight))
        self.terminalView = GhosttyTerminalView(frame: NSRect(x: 0, y: 0,
                                                               width: frame.width,
                                                               height: frame.height - Self.titleBarHeight))
        super.init(frame: frame)
        setup(theme: theme)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setup(theme: AppTheme) {
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.masksToBounds = true
        layer?.shadowOpacity = 0
        applyTheme(theme)

        titleBar.autoresizingMask = [.width, .minYMargin]
        terminalView.autoresizingMask = [.width, .height]

        addSubview(terminalView)
        addSubview(titleBar)

        titleBar.onClose = { [weak self] in
            guard let self else { return }
            self.onClose?(self.terminalId)
        }
    }

    func applyTheme(_ theme: AppTheme) {
        layer?.backgroundColor = theme.background.cgColor
        layer?.borderColor = theme.border.withAlphaComponent(0.15).cgColor
        layer?.borderWidth = 1
    }

    func applyFocusStyle(focused: Bool, theme: AppTheme) {
        layer?.borderColor = focused
            ? theme.accent.withAlphaComponent(0.5).cgColor
            : theme.border.withAlphaComponent(0.08).cgColor
        layer?.borderWidth = focused ? 1.5 : 1
    }

    func didFinishDrag() {
        onFrameChanged?(terminalId, frame)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        titleBar.frame = NSRect(x: 0, y: newSize.height - Self.titleBarHeight,
                                width: newSize.width, height: Self.titleBarHeight)
        terminalView.frame = NSRect(x: 0, y: 0,
                                    width: newSize.width, height: newSize.height - Self.titleBarHeight)
    }
}
```

- [ ] **Step 3: Build to verify**

```bash
xcodebuild build -scheme TheAll -destination 'platform=macOS' 2>&1 | grep -E 'error:|BUILD SUCCEEDED|BUILD FAILED'
```

Expected: `BUILD SUCCEEDED`

- [ ] **Step 4: Commit**

```bash
git add TheAll/Canvas/TitleBarView.swift TheAll/Canvas/TerminalWindowView.swift
git commit -m "feat: add TitleBarView and TerminalWindowView with rounded corners and drag support"
```

---

## Task 7: CanvasContentView + CanvasScrollView

**Files:**
- Create: `TheAll/Canvas/CanvasContentView.swift`
- Create: `TheAll/Canvas/CanvasScrollView.swift`

- [ ] **Step 1: Create CanvasContentView.swift**

Create `TheAll/Canvas/CanvasContentView.swift`:

```swift
import AppKit

/// Infinite canvas that hosts freely-floating TerminalWindowViews.
final class CanvasContentView: NSView {
    var store: WorkspaceStore?
    var theme: AppTheme = .dark
    private var terminalViews: [UUID: TerminalWindowView] = [:]

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Workspace management

    /// Differential update: add views for new terminal states, remove views no longer present.
    /// Does NOT tear down existing views to avoid destroying ghostty surfaces (terminal sessions).
    func loadWorkspace(_ workspace: Workspace) {
        let newIds = Set(workspace.terminalStates.map { $0.id })
        let existingIds = Set(terminalViews.keys)

        // Remove views for terminals that were deleted
        for removedId in existingIds.subtracting(newIds) {
            terminalViews[removedId]?.removeFromSuperview()
            terminalViews.removeValue(forKey: removedId)
        }

        // Add views for terminals that are new
        for state in workspace.terminalStates where !existingIds.contains(state.id) {
            addTerminalView(id: state.id, frame: state.frame)
        }
    }

    /// Call when switching away from a workspace — hides views without destroying surfaces.
    func detachWorkspace() {
        terminalViews.values.forEach { $0.isHidden = true }
    }

    /// Call when switching to a workspace — restores views.
    func attachWorkspace(_ workspace: Workspace) {
        terminalViews.values.forEach { $0.isHidden = false }
        loadWorkspace(workspace)
    }

    func addTerminalView(id: UUID, frame: CGRect) {
        let view = TerminalWindowView(id: id, frame: frame, theme: theme)
        view.onClose = { [weak self] termId in
            self?.removeTerminalView(id: termId)
        }
        view.onFrameChanged = { [weak self] termId, newFrame in
            guard let self, let wsId = self.store?.selectedId else { return }
            self.store?.updateTerminalFrame(id: termId, in: wsId, frame: newFrame)
        }
        addSubview(view)
        terminalViews[id] = view
    }

    func removeTerminalView(id: UUID) {
        terminalViews[id]?.removeFromSuperview()
        terminalViews.removeValue(forKey: id)
        if let wsId = store?.selectedId {
            store?.removeTerminal(id: id, from: wsId)
        }
    }

    func applyTheme(_ theme: AppTheme) {
        self.theme = theme
        layer?.backgroundColor = NSColor(red: 0.067, green: 0.067, blue: 0.073, alpha: 1).cgColor
        terminalViews.values.forEach { $0.applyTheme(theme) }
    }

    // MARK: - Create terminal on double-click

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            let pt = convert(event.locationInWindow, from: nil)
            createTerminal(at: pt)
        }
    }

    func createTerminal(at point: CGPoint) {
        guard let wsId = store?.selectedId else { return }
        let defaultSize = CGSize(width: 640, height: 400)
        let frame = CGRect(
            x: point.x - defaultSize.width / 2,
            y: point.y - defaultSize.height / 2,
            width: defaultSize.width,
            height: defaultSize.height
        )
        let termId = store?.addTerminal(to: wsId, frame: frame)
        if let id = termId {
            addTerminalView(id: id, frame: frame)
        }
    }
}
```

- [ ] **Step 2: Create CanvasScrollView.swift**

Create `TheAll/Canvas/CanvasScrollView.swift`:

```swift
import AppKit

final class CanvasScrollView: NSScrollView {
    let canvas: CanvasContentView
    private static let canvasSize: CGFloat = 10_000

    override init(frame: NSRect) {
        canvas = CanvasContentView(frame: NSRect(
            x: 0, y: 0,
            width: Self.canvasSize, height: Self.canvasSize
        ))
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        documentView = canvas
        hasVerticalScroller = true
        hasHorizontalScroller = true
        autohidesScrollers = true
        drawsBackground = false
        // Start scrolled to center of the canvas
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let center = CGPoint(
                x: (Self.canvasSize - self.bounds.width) / 2,
                y: (Self.canvasSize - self.bounds.height) / 2
            )
            self.contentView.scroll(to: center)
        }
    }
}
```

- [ ] **Step 3: Build to verify**

```bash
xcodebuild build -scheme TheAll -destination 'platform=macOS' 2>&1 | grep -E 'error:|BUILD SUCCEEDED|BUILD FAILED'
```

Expected: `BUILD SUCCEEDED`

- [ ] **Step 4: Commit**

```bash
git add TheAll/Canvas/CanvasContentView.swift TheAll/Canvas/CanvasScrollView.swift
git commit -m "feat: add CanvasContentView and CanvasScrollView infinite whiteboard"
```

---

## Task 8: CanvasBridge (NSViewRepresentable)

**Files:**
- Create: `TheAll/Bridge/CanvasBridge.swift`

- [ ] **Step 1: Create CanvasBridge.swift**

Create `TheAll/Bridge/CanvasBridge.swift`:

```swift
import SwiftUI
import AppKit

struct CanvasBridge: NSViewRepresentable {
    @Bindable var store: WorkspaceStore
    var theme: AppTheme

    func makeNSView(context: Context) -> CanvasScrollView {
        let scrollView = CanvasScrollView(frame: .zero)
        scrollView.canvas.store = store
        scrollView.canvas.applyTheme(theme)
        if let ws = store.selectedWorkspace {
            scrollView.canvas.loadWorkspace(ws)
        }
        return scrollView
    }

    func updateNSView(_ nsView: CanvasScrollView, context: Context) {
        nsView.canvas.store = store
        nsView.canvas.applyTheme(theme)
        if let ws = store.selectedWorkspace {
            // Use differential update — does not destroy existing surfaces
            nsView.canvas.loadWorkspace(ws)
        }
    }

    class Coordinator {
        var lastWorkspaceId: UUID?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    // Workspace switch: detach old views, attach new workspace views
    static func dismantleNSView(_ nsView: CanvasScrollView, coordinator: Coordinator) {
        nsView.canvas.detachWorkspace()
    }
}
```

- [ ] **Step 2: Build to verify**

```bash
xcodebuild build -scheme TheAll -destination 'platform=macOS' 2>&1 | grep -E 'error:|BUILD SUCCEEDED|BUILD FAILED'
```

Expected: `BUILD SUCCEEDED`

- [ ] **Step 3: Commit**

```bash
git add TheAll/Bridge/CanvasBridge.swift
git commit -m "feat: add CanvasBridge NSViewRepresentable for SwiftUI/AppKit boundary"
```

---

## Task 9: WorkspaceMetadata + MetadataRefresher

**Files:**
- Create: `TheAll/Metadata/WorkspaceMetadata.swift`
- Create: `TheAll/Metadata/MetadataRefresher.swift`
- Create: `TheAllTests/MetadataRefresherTests.swift`

- [ ] **Step 1: Write failing tests**

Create `TheAllTests/MetadataRefresherTests.swift`:

```swift
import XCTest
@testable import TheAll

final class MetadataRefresherTests: XCTestCase {

    func testParseBranchFromGitOutput() {
        let output = "main\n"
        let branch = MetadataRefresher.parseBranch(from: output)
        XCTAssertEqual(branch, "main")
    }

    func testParseBranchTrimsWhitespace() {
        let output = "  feat/sidebar  \n"
        let branch = MetadataRefresher.parseBranch(from: output)
        XCTAssertEqual(branch, "feat/sidebar")
    }

    func testParseBranchReturnsNilOnEmpty() {
        let branch = MetadataRefresher.parseBranch(from: "")
        XCTAssertNil(branch)
    }

    func testParsePortsFromLsofOutput() {
        let lsofOutput = """
        node    1234 user   21u  IPv4 0x0  0t0  TCP *:3000 (LISTEN)
        python  5678 user   4u   IPv4 0x0  0t0  TCP *:8080 (LISTEN)
        """
        let ports = MetadataRefresher.parsePorts(from: lsofOutput)
        XCTAssertEqual(ports.sorted(), [3000, 8080])
    }

    func testParsePortsEmptyOnNoListening() {
        let ports = MetadataRefresher.parsePorts(from: "")
        XCTAssertTrue(ports.isEmpty)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
xcodebuild test -scheme TheAllTests -destination 'platform=macOS' 2>&1 | grep -E 'error:|MetadataRefresher'
```

Expected: compile error.

- [ ] **Step 3: Create WorkspaceMetadata.swift**

Create `TheAll/Metadata/WorkspaceMetadata.swift`:

```swift
import Foundation
import Observation

@Observable
final class WorkspaceMetadata {
    var gitBranch: String?
    var prStatus: String?          // "open", "merged", "closed", nil = unknown
    var workingDirectory: String?
    var listeningPorts: [Int] = []
    var latestNotification: String?
}
```

- [ ] **Step 4: Create MetadataRefresher.swift**

Create `TheAll/Metadata/MetadataRefresher.swift`:

```swift
import Foundation

final class MetadataRefresher {
    private let metadata: WorkspaceMetadata
    private let workingDirectory: String
    private var timer: Timer?

    init(metadata: WorkspaceMetadata, workingDirectory: String) {
        self.metadata = metadata
        self.workingDirectory = workingDirectory
    }

    func start() {
        metadata.workingDirectory = workingDirectory
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func refresh() {
        DispatchQueue.global(qos: .background).async { [weak self] in
            guard let self else { return }
            let branch = self.fetchGitBranch()
            let ports = self.fetchListeningPorts()
            DispatchQueue.main.async {
                self.metadata.gitBranch = branch
                self.metadata.listeningPorts = ports
            }
        }
    }

    private func fetchGitBranch() -> String? {
        let output = shell("git rev-parse --abbrev-ref HEAD", cwd: workingDirectory)
        return MetadataRefresher.parseBranch(from: output ?? "")
    }

    private func fetchListeningPorts() -> [Int] {
        let output = shell("lsof -nP -iTCP -sTCP:LISTEN", cwd: nil)
        return MetadataRefresher.parsePorts(from: output ?? "")
    }

    private func shell(_ command: String, cwd: String?) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", command]
        if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try? process.run()
        process.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
    }

    // MARK: - Parsers (static for testability)

    static func parseBranch(from output: String) -> String? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func parsePorts(from lsofOutput: String) -> [Int] {
        var ports: [Int] = []
        for line in lsofOutput.components(separatedBy: .newlines) {
            guard line.contains("LISTEN") else { continue }
            // Match "*:PORT" or "127.0.0.1:PORT"
            if let range = line.range(of: #":\d+"#, options: .regularExpression) {
                let portStr = String(line[range].dropFirst())
                if let port = Int(portStr) { ports.append(port) }
            }
        }
        return ports
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

```bash
xcodebuild test -scheme TheAllTests -destination 'platform=macOS' 2>&1 | grep -E 'Test.*passed|Test.*failed|PASSED|FAILED'
```

Expected: all 5 MetadataRefresher tests pass.

- [ ] **Step 6: Commit**

```bash
git add TheAll/Metadata/ TheAllTests/MetadataRefresherTests.swift
git commit -m "feat: add WorkspaceMetadata and MetadataRefresher with git branch and port polling"
```

---

## Task 10: SidebarView + WorkspaceRowView

**Files:**
- Create: `TheAll/Sidebar/WorkspaceRowView.swift`
- Create: `TheAll/Sidebar/SidebarView.swift`

- [ ] **Step 1: Create WorkspaceRowView.swift**

Create `TheAll/Sidebar/WorkspaceRowView.swift`:

```swift
import SwiftUI

struct WorkspaceRowView: View {
    let workspace: Workspace
    let metadata: WorkspaceMetadata
    let isSelected: Bool
    let theme: AppTheme

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle()
                    .fill(isSelected ? Color(theme.accent) : Color(theme.border))
                    .frame(width: 7, height: 7)
                Text(workspace.name)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                    .foregroundColor(Color(isSelected ? theme.foreground : theme.sidebarText))
                    .lineLimit(1)
            }

            if let branch = metadata.gitBranch {
                HStack(spacing: 4) {
                    Text("⎇")
                        .font(.system(size: 10))
                    Text(branch)
                        .font(.system(size: 10))
                }
                .foregroundColor(Color(theme.sidebarText).opacity(0.7))
                .padding(.leading, 13)
            }

            if !metadata.listeningPorts.isEmpty {
                HStack(spacing: 4) {
                    ForEach(metadata.listeningPorts.prefix(3), id: \.self) { port in
                        Text(":\(port)")
                            .font(.system(size: 9, design: .monospaced))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color(theme.border).opacity(0.4))
                            .cornerRadius(4)
                    }
                }
                .padding(.leading, 13)
            }

            if let note = metadata.latestNotification {
                Text(note)
                    .font(.system(size: 10))
                    .foregroundColor(Color(theme.accent).opacity(0.8))
                    .lineLimit(1)
                    .padding(.leading, 13)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected
                    ? Color(theme.accent).opacity(0.12)
                    : Color.clear)
        )
        .contentShape(Rectangle())
    }
}
```

- [ ] **Step 2: Create SidebarView.swift**

Create `TheAll/Sidebar/SidebarView.swift`:

```swift
import SwiftUI

struct SidebarView: View {
    @Bindable var store: WorkspaceStore
    var theme: AppTheme
    @State private var metadataMap: [UUID: WorkspaceMetadata] = [:]
    @State private var refreshers: [UUID: MetadataRefresher] = [:]
    @State private var showNewWorkspaceSheet = false
    @State private var newWorkspaceName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            Text("WORKSPACES")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(Color(theme.sidebarText).opacity(0.5))
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 8)

            // Workspace list
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(store.workspaces) { ws in
                        WorkspaceRowView(
                            workspace: ws,
                            metadata: metadataMap[ws.id, default: WorkspaceMetadata()],
                            isSelected: store.selectedId == ws.id,
                            theme: theme
                        )
                        .onTapGesture {
                            store.select(id: ws.id)
                        }
                    }
                }
                .padding(.horizontal, 8)
            }

            Divider()
                .background(Color(theme.border).opacity(0.3))

            // New workspace button
            Button(action: { showNewWorkspaceSheet = true }) {
                HStack {
                    Image(systemName: "plus")
                        .font(.system(size: 11))
                    Text("New Workspace")
                        .font(.system(size: 12))
                }
                .foregroundColor(Color(theme.sidebarText).opacity(0.6))
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
            .buttonStyle(.plain)
        }
        .frame(width: 180)
        .background(Color(theme.sidebarBackground))
        .onAppear { startRefreshers() }
        .onChange(of: store.workspaces) { _, _ in startRefreshers() }
        .sheet(isPresented: $showNewWorkspaceSheet) {
            newWorkspaceSheet
        }
    }

    private var newWorkspaceSheet: some View {
        VStack(spacing: 16) {
            Text("New Workspace")
                .font(.headline)
            TextField("Name", text: $newWorkspaceName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
            HStack {
                Button("Cancel") {
                    showNewWorkspaceSheet = false
                    newWorkspaceName = ""
                }
                Button("Create") {
                    if !newWorkspaceName.isEmpty {
                        store.createWorkspace(name: newWorkspaceName)
                    }
                    showNewWorkspaceSheet = false
                    newWorkspaceName = ""
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
    }

    private func startRefreshers() {
        for ws in store.workspaces where refreshers[ws.id] == nil {
            let meta = WorkspaceMetadata()
            metadataMap[ws.id] = meta
            let dir = ws.terminalStates.isEmpty
                ? NSHomeDirectory()
                : (ws.terminalStates.first.flatMap { _ in nil } ?? NSHomeDirectory())
            let refresher = MetadataRefresher(metadata: meta, workingDirectory: dir)
            refreshers[ws.id] = refresher
            refresher.start()
        }
    }
}
```

- [ ] **Step 3: Build to verify**

```bash
xcodebuild build -scheme TheAll -destination 'platform=macOS' 2>&1 | grep -E 'error:|BUILD SUCCEEDED|BUILD FAILED'
```

Expected: `BUILD SUCCEEDED`

- [ ] **Step 4: Commit**

```bash
git add TheAll/Sidebar/
git commit -m "feat: add SidebarView and WorkspaceRowView with git/port/notification display"
```

---

## Task 11: ContentView + App entry + toolbar

**Files:**
- Modify: `TheAll/TheAllApp.swift`
- Create: `TheAll/ContentView.swift`

- [ ] **Step 1: Create ContentView.swift**

Create `TheAll/ContentView.swift`:

```swift
import SwiftUI

struct ContentView: View {
    @State private var store = WorkspaceStore()
    @State private var themeManager = ThemeManager()

    var body: some View {
        HStack(spacing: 0) {
            SidebarView(store: store, theme: themeManager.theme)

            Divider()
                .background(Color(themeManager.theme.border).opacity(0.3))

            CanvasBridge(store: store, theme: themeManager.theme)
        }
        .frame(minWidth: 900, minHeight: 600)
        .background(Color(themeManager.theme.background))
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button(action: addTerminal) {
                    Image(systemName: "plus.rectangle")
                }
                .help("New Terminal (⌘T)")
                .keyboardShortcut("t", modifiers: .command)
            }
        }
        .onAppear {
            themeManager.loadFromGhosttyConfig()
        }
    }

    private func addTerminal() {
        // Add terminal at canvas center
        // The canvas is 10,000×10,000; center is 5000,5000
        // We place near center of the visible area
        guard let wsId = store.selectedId else { return }
        let center = CGPoint(x: 5000, y: 5000)
        let frame = CGRect(x: center.x - 320, y: center.y - 200, width: 640, height: 400)
        store.addTerminal(to: wsId, frame: frame)
    }
}
```

- [ ] **Step 2: Update TheAllApp.swift**

Replace `TheAll/TheAllApp.swift`:

```swift
import SwiftUI

@main
struct TheAllApp: App {
    init() {
        // Initialize libghostty before any window appears
        let ok = GhosttyBridge.shared.initialize()
        if !ok {
            // Show error — handled by ContentView checking isInitialized
            print("[theall] Warning: libghostty initialization failed")
        }
    }

    var body: some Scene {
        WindowGroup {
            if GhosttyBridge.shared.isInitialized {
                ContentView()
            } else {
                GhosttyMissingView()
            }
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) { }
        }
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
            Text("theall requires Ghostty to be installed.\nInstall it from ghostty.org, then relaunch theall.")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
            Link("ghostty.org", destination: URL(string: "https://ghostty.org")!)
        }
        .padding(40)
        .frame(width: 400, height: 280)
    }
}
```

- [ ] **Step 3: Build and verify**

```bash
xcodebuild build -scheme TheAll -destination 'platform=macOS' 2>&1 | grep -E 'error:|BUILD SUCCEEDED|BUILD FAILED'
```

Expected: `BUILD SUCCEEDED`

- [ ] **Step 4: Commit**

```bash
git add TheAll/TheAllApp.swift TheAll/ContentView.swift
git commit -m "feat: wire ContentView with sidebar + canvas bridge, add Cmd+T shortcut"
```

---

## Task 12: Theme propagation + color scheme sync

**Files:**
- Modify: `TheAll/ContentView.swift`
- Modify: `TheAll/Ghostty/GhosttyBridge.swift`

- [ ] **Step 1: Wire ThemeManager to GhosttyBridge color scheme**

In `TheAll/Theme/ThemeManager.swift`, add a method to sync with libghostty:

```swift
// Add inside ThemeManager class, after applyScheme():
func syncWithGhosttyBridge() {
    let isDark = theme.background.brightnessComponent < 0.5
    GhosttyBridge.shared.applyColorScheme(isDark)
}
```

- [ ] **Step 2: Call syncWithGhosttyBridge from applyScheme**

In `ThemeManager.applyScheme(_:)`, add at the end of the function body:

```swift
// At end of each case in applyScheme, after theme = .dark / .light:
if GhosttyBridge.shared.isInitialized {
    syncWithGhosttyBridge()
}
```

Full updated `applyScheme`:

```swift
func applyScheme(_ scheme: ColorSchemePreference) {
    currentScheme = scheme
    switch scheme {
    case .dark:
        theme = .dark
    case .light:
        theme = .light
    case .system:
        let isDark = NSApp?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        theme = isDark ? .dark : .light
    }
    if GhosttyBridge.shared.isInitialized {
        syncWithGhosttyBridge()
    }
}
```

- [ ] **Step 3: Add theme toggle menu to ContentView**

In `TheAll/ContentView.swift`, add to `.commands`:

```swift
// Replace the empty CommandGroup with:
.commands {
    CommandGroup(replacing: .newItem) { }
    CommandMenu("Appearance") {
        Button("Dark") { themeManager.applyScheme(.dark) }
            .keyboardShortcut("1", modifiers: [.command, .shift])
        Button("Light") { themeManager.applyScheme(.light) }
            .keyboardShortcut("2", modifiers: [.command, .shift])
        Button("Follow System") { themeManager.applyScheme(.system) }
            .keyboardShortcut("0", modifiers: [.command, .shift])
    }
}
```

- [ ] **Step 4: Build final verification**

```bash
xcodebuild build -scheme TheAll -destination 'platform=macOS' 2>&1 | grep -E 'error:|BUILD SUCCEEDED|BUILD FAILED'
```

Expected: `BUILD SUCCEEDED`

- [ ] **Step 5: Run all tests**

```bash
xcodebuild test -scheme TheAllTests -destination 'platform=macOS' 2>&1 | grep -E 'Test.*passed|Test.*failed|PASSED|FAILED'
```

Expected: all tests pass.

- [ ] **Step 6: Final commit**

```bash
git add TheAll/Theme/ThemeManager.swift TheAll/ContentView.swift
git commit -m "feat: wire theme manager to ghostty color scheme and add appearance menu"
```

---

## Manual Acceptance Tests

After all tasks complete, verify these by running the app (`xcodebuild run` or open in Xcode):

- [ ] App launches, sidebar shows "Default" workspace
- [ ] Double-clicking canvas creates a new terminal window
- [ ] Cmd+T creates a terminal at canvas center
- [ ] Terminal windows can be freely dragged and overlap
- [ ] Closing a terminal (red button) removes it from canvas and store
- [ ] Creating a second workspace in sidebar and switching preserves first workspace's terminals
- [ ] Appearance > Dark / Light / Follow System updates sidebar and terminal chrome colors
- [ ] `~/.config/ghostty/config` with `theme = light` causes light theme on launch
- [ ] `ghostty_surface_draw` renders terminal content (cursor visible, text input works)
