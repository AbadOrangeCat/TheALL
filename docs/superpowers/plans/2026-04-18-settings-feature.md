# Settings Feature Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在 theall 内加入一个 GUI 设置界面，把常用 ghostty 配置项（主题 / 字体 / 光标 / padding / shell 集成 等）通过分类 tab + Form 暴露给用户；写回独立的 `~/Library/Application Support/theall/config` override 文件；菜单栏提供 `Settings…` 与 `Edit Config File…` 两入口；改动重启 theall 后生效。

**Architecture:** 数据层 `SettingsConfigStore`（@Observable，持久化到 theall override 文件，保留注释 / 未识别字段）独立于 `WorkspaceStore`。`GhosttyBridge.initialize()` 在 `ghostty_config_finalize` 前加载 override 文件作最高优先级配置。UI 层 `SettingsView` 复用右侧内容区（与 `TabBridge` 互斥渲染），内部采用硬编码四分类的只读水平 tab + SwiftUI Form，受控于 `ContentView` 的 `showSettings` 状态。

**Tech Stack:** Swift 5 / AppKit + SwiftUI, Observation (@Observable), libghostty C API (现有 bridging header), XCTest, xcodegen。

---

## 文件结构

### 新增

```
TheAll/Settings/
├── SettingsConfigStore.swift         # @Observable，读写 theall config 文件
├── SettingsSection.swift             # enum SettingsSection (四项)
├── SettingsView.swift                # 根视图：header + SettingsTabBarView + section 切换
├── SettingsTabBarView.swift          # SwiftUI 只读水平 tab
├── ThemeCatalog.swift                # 扫描 bundle 内主题列表
├── Sections/
│   ├── AppearanceSectionView.swift
│   ├── FontSectionView.swift
│   ├── TerminalSectionView.swift
│   └── ShellSectionView.swift
└── Components/
    ├── BoundControls.swift           # 通用 Toggle/Slider/Stepper/NumberField 绑 store
    ├── FontPickerView.swift
    └── ThemePickerView.swift

TheAllTests/
├── SettingsConfigStoreTests.swift
└── ThemeCatalogTests.swift
```

### 修改

| 文件 | 改动 |
|---|---|
| `TheAll/Ghostty/GhosttyBridge.swift` | `initialize()` 在 `ghostty_config_finalize` 前加载 theall override |
| `TheAll/ContentView.swift` | `showSettings` 状态 + `settingsStore` 实例 + 右侧条件渲染 + 2 个新 Notification 订阅 |
| `TheAll/Sidebar/SidebarView.swift` | VStack 末尾新增 footer 区，齿轮 IconButton post `.theAllOpenSettings` |
| `TheAll/TheAllApp.swift` | App menu 插入 `Settings…` / `Edit Config File…` 并 post Notification |
| `docs/testing.md`（可选） | 如被修改则一并更新；本计划不硬编码修改 |

`project.yml` 不改（xcodegen 自动 glob `TheAll/**/*.swift`，新建目录直接被包含）。

---

## Task 1: SettingsConfigStore — 数据层

**Files:**
- Create: `TheAll/Settings/SettingsConfigStore.swift`
- Test: `TheAllTests/SettingsConfigStoreTests.swift`

### 职责

- 解析 `key = value` + 注释 + 空行，保留原顺序
- `get(_ key:)` / `set(_ key:, _ value:)` 内存操作
- `set` 后 debounce 200 ms 异步写回磁盘；`save()` 同步写（测试用）
- `openInEditor()`：文件不存在则创建空文件，`NSWorkspace.shared.open(url)`

- [ ] **Step 1: 写失败测试 `SettingsConfigStoreTests`**

创建文件 `TheAllTests/SettingsConfigStoreTests.swift`：

```swift
import XCTest
@testable import TheAll

final class SettingsConfigStoreTests: XCTestCase {

    private var tmpPath: String!

    override func setUp() {
        super.setUp()
        let dir = NSTemporaryDirectory()
        tmpPath = (dir as NSString).appendingPathComponent(
            "theall-settings-\(UUID().uuidString).conf"
        )
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: tmpPath)
        super.tearDown()
    }

    func testLoadsMissingFileAsEmpty() {
        let store = SettingsConfigStore(filePath: tmpPath)
        store.reload()
        XCTAssertNil(store.get("font-size"))
    }

    func testParsesKvCommentsBlankAndUnknown() throws {
        let contents = """
        # top comment

        font-size = 13
        theme = Catppuccin Mocha
        # trailing comment
        garbage-no-equals
        """
        try contents.write(toFile: tmpPath, atomically: true, encoding: .utf8)

        let store = SettingsConfigStore(filePath: tmpPath)
        store.reload()

        XCTAssertEqual(store.get("font-size"), "13")
        XCTAssertEqual(store.get("theme"), "Catppuccin Mocha")

        // 保留注释 / 空行 / unknown row 的个数
        let (comments, blanks, unknowns, kvs) = store.debugCounts()
        XCTAssertEqual(comments, 2)
        XCTAssertEqual(blanks, 1)
        XCTAssertEqual(unknowns, 1)
        XCTAssertEqual(kvs, 2)
    }

    func testSetExistingKeyUpdatesInPlace() throws {
        try "font-size = 13\ntheme = A\n".write(toFile: tmpPath, atomically: true, encoding: .utf8)
        let store = SettingsConfigStore(filePath: tmpPath)
        store.reload()

        store.set("font-size", "15")
        store.save()

        let roundTrip = try String(contentsOfFile: tmpPath, encoding: .utf8)
        XCTAssertTrue(roundTrip.contains("font-size = 15"))
        XCTAssertTrue(roundTrip.contains("theme = A"))
        XCTAssertFalse(roundTrip.contains("font-size = 13"))
    }

    func testSetNewKeyAppendsAtEnd() throws {
        try "# user comment\n\ntheme = A\n".write(toFile: tmpPath, atomically: true, encoding: .utf8)
        let store = SettingsConfigStore(filePath: tmpPath)
        store.reload()

        store.set("font-size", "15")
        store.save()

        let roundTrip = try String(contentsOfFile: tmpPath, encoding: .utf8)
        // append 到尾部，注释原样保留
        XCTAssertTrue(roundTrip.hasPrefix("# user comment"))
        XCTAssertTrue(roundTrip.contains("theme = A"))
        XCTAssertTrue(roundTrip.contains("font-size = 15"))
        // font-size 必须在 theme 之后
        let themeIdx = roundTrip.range(of: "theme = A")!.lowerBound
        let fontIdx  = roundTrip.range(of: "font-size = 15")!.lowerBound
        XCTAssertLessThan(themeIdx, fontIdx)
    }

    func testSetNilDeletesLine() throws {
        try "font-size = 13\ntheme = A\n".write(toFile: tmpPath, atomically: true, encoding: .utf8)
        let store = SettingsConfigStore(filePath: tmpPath)
        store.reload()

        store.set("font-size", nil)
        store.save()

        let roundTrip = try String(contentsOfFile: tmpPath, encoding: .utf8)
        XCTAssertFalse(roundTrip.contains("font-size"))
        XCTAssertTrue(roundTrip.contains("theme = A"))
    }

    func testPreservesDuplicateKeys() throws {
        let contents = """
        palette = 0=#000000
        palette = 1=#ffffff
        """
        try contents.write(toFile: tmpPath, atomically: true, encoding: .utf8)
        let store = SettingsConfigStore(filePath: tmpPath)
        store.reload()

        // get 返回第一个匹配
        XCTAssertEqual(store.get("palette"), "0=#000000")

        // save 不写坏
        store.save()
        let roundTrip = try String(contentsOfFile: tmpPath, encoding: .utf8)
        XCTAssertTrue(roundTrip.contains("palette = 0=#000000"))
        XCTAssertTrue(roundTrip.contains("palette = 1=#ffffff"))
    }

    func testQuotedValueStripped() throws {
        try #"theme = "Catppuccin Latte""#.write(toFile: tmpPath, atomically: true, encoding: .utf8)
        let store = SettingsConfigStore(filePath: tmpPath)
        store.reload()
        XCTAssertEqual(store.get("theme"), "Catppuccin Latte")
    }
}
```

- [ ] **Step 2: 跑测试确认全部失败**

Run: `xcodebuild test -project TheAll.xcodeproj -scheme TheAllTests -only-testing:TheAllTests/SettingsConfigStoreTests 2>&1 | tail -30`

Expected: 编译失败，提示找不到 `SettingsConfigStore` 类型。

- [ ] **Step 3: 实现 `SettingsConfigStore`**

创建文件 `TheAll/Settings/SettingsConfigStore.swift`：

```swift
import Foundation
import AppKit
import Observation

/// 行级模型：保留注释、空行、未识别字段，写回时原样回填。
enum ConfigLine: Equatable {
    case comment(String)       // 完整原始行（含 # 前缀与空白）
    case blank
    case kv(key: String, value: String)
    case unknown(String)       // 无 = 号等无法解析的行
}

/// theall 独立 override 配置文件读写。位置：
/// `~/Library/Application Support/theall/config`
/// 语法与 ghostty config 完全一致：`key = value`，支持注释行。
@Observable
final class SettingsConfigStore {
    private(set) var lines: [ConfigLine] = []
    private let filePath: String
    private var writeTask: Task<Void, Never>?

    /// 默认路径。`~/Library/Application Support/theall/config`
    static var defaultPath: String {
        let home = NSHomeDirectory()
        return "\(home)/Library/Application Support/theall/config"
    }

    init(filePath: String = SettingsConfigStore.defaultPath) {
        self.filePath = filePath
        reload()
    }

    /// 从磁盘重新读入。文件不存在时 lines 被清空，不抛错。
    func reload() {
        guard let contents = try? String(contentsOfFile: filePath, encoding: .utf8) else {
            lines = []
            return
        }
        lines = Self.parse(contents)
    }

    /// 获取首个匹配 key 的 value；无返回 nil。
    func get(_ key: String) -> String? {
        for line in lines {
            if case .kv(let k, let v) = line, k == key { return v }
        }
        return nil
    }

    /// 写入 key。value == nil 表示删除该 key 行。
    /// 存在则原地替换，不存在则 append（前面空一行分隔）。
    /// 多次调用内部 debounce 200 ms 异步落盘。
    func set(_ key: String, _ value: String?) {
        if let idx = lines.firstIndex(where: {
            if case .kv(let k, _) = $0 { return k == key }
            return false
        }) {
            if let value {
                lines[idx] = .kv(key: key, value: value)
            } else {
                lines.remove(at: idx)
            }
        } else if let value {
            if let last = lines.last, case .blank = last {
                // 尾已空行，直接 append
            } else if !lines.isEmpty {
                lines.append(.blank)
            }
            lines.append(.kv(key: key, value: value))
        }
        scheduleWrite()
    }

    /// 同步写盘（测试用；取消 pending debounced 写，立刻落盘）。
    func save() {
        writeTask?.cancel()
        writeTask = nil
        writeToDisk()
    }

    /// 文件不存在则 touch，然后以默认 editor 打开。
    func openInEditor() {
        let url = URL(fileURLWithPath: filePath)
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: filePath) {
            FileManager.default.createFile(atPath: filePath, contents: Data())
        }
        NSWorkspace.shared.open(url)
    }

    /// 测试专用：返回各类 line 数量。
    func debugCounts() -> (comments: Int, blanks: Int, unknowns: Int, kvs: Int) {
        var c = 0, b = 0, u = 0, k = 0
        for line in lines {
            switch line {
            case .comment: c += 1
            case .blank:   b += 1
            case .unknown: u += 1
            case .kv:      k += 1
            }
        }
        return (c, b, u, k)
    }

    // MARK: - Parse / serialize

    static func parse(_ contents: String) -> [ConfigLine] {
        var result: [ConfigLine] = []
        let rawLines = contents.components(separatedBy: "\n")
        // contents 以 \n 结尾会多出一个尾部空串，丢弃
        let effective: [String] = rawLines.last == "" ? Array(rawLines.dropLast()) : rawLines
        for rawLine in effective {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                result.append(.blank)
            } else if trimmed.hasPrefix("#") {
                result.append(.comment(rawLine))
            } else if let eq = rawLine.firstIndex(of: "=") {
                let key = String(rawLine[..<eq]).trimmingCharacters(in: .whitespaces)
                var value = String(rawLine[rawLine.index(after: eq)...])
                    .trimmingCharacters(in: .whitespaces)
                if value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2 {
                    value = String(value.dropFirst().dropLast())
                }
                result.append(.kv(key: key, value: value))
            } else {
                result.append(.unknown(rawLine))
            }
        }
        return result
    }

    static func serialize(_ lines: [ConfigLine]) -> String {
        let rendered: [String] = lines.map { line in
            switch line {
            case .comment(let raw): return raw
            case .blank:            return ""
            case .kv(let k, let v): return "\(k) = \(v)"
            case .unknown(let raw): return raw
            }
        }
        return rendered.joined(separator: "\n") + "\n"
    }

    // MARK: - Disk IO

    private func scheduleWrite() {
        writeTask?.cancel()
        writeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard let self, !Task.isCancelled else { return }
            self.writeToDisk()
        }
    }

    private func writeToDisk() {
        let url = URL(fileURLWithPath: filePath)
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let output = Self.serialize(lines)
        try? output.write(toFile: filePath, atomically: true, encoding: .utf8)
    }
}
```

- [ ] **Step 4: 跑测试确认全部通过**

Run: `xcodebuild test -project TheAll.xcodeproj -scheme TheAllTests -only-testing:TheAllTests/SettingsConfigStoreTests 2>&1 | tail -30`

Expected: `** TEST SUCCEEDED **`，7 个 case 全 pass。

- [ ] **Step 5: 提交**

```bash
git add TheAll/Settings/SettingsConfigStore.swift TheAllTests/SettingsConfigStoreTests.swift
git commit -m "$(cat <<'EOF'
feat(settings): add SettingsConfigStore for theall override config

@Observable 数据层，读写 ~/Library/Application Support/theall/config；保留注释/未识别行，debounce 200ms 落盘。

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: GhosttyBridge 加载 theall override

**Files:**
- Modify: `TheAll/Ghostty/GhosttyBridge.swift` (在 `ghostty_config_finalize(cfg)` 前)

### 职责

在 app 启动时，如果 theall override 文件存在，把它作为**最后一层** config 灌给 libghostty，语义上覆盖默认文件、递归文件、theme 主题文件等所有前面加载的来源。

- [ ] **Step 1: 在 `initialize()` 的 finalize 之前加载 override**

打开 `TheAll/Ghostty/GhosttyBridge.swift`，找到：

```swift
        if let themePath = GhosttyConfigReader.resolvedThemePath() {
            themePath.withCString { ghostty_config_load_file(cfg, $0) }
        }
        ghostty_config_finalize(cfg)
```

把这段改为：

```swift
        if let themePath = GhosttyConfigReader.resolvedThemePath() {
            themePath.withCString { ghostty_config_load_file(cfg, $0) }
        }

        // theall override: 写在 GUI 设置里的字段覆盖以上所有来源。
        // 文件由 SettingsConfigStore 维护；不存在即跳过。
        let theAllConfigPath = SettingsConfigStore.defaultPath
        if FileManager.default.fileExists(atPath: theAllConfigPath) {
            theAllConfigPath.withCString { ghostty_config_load_file(cfg, $0) }
        }

        ghostty_config_finalize(cfg)
```

- [ ] **Step 2: 编译通过**

Run: `xcodebuild -project TheAll.xcodeproj -scheme TheAll -configuration Debug build 2>&1 | tail -10`

Expected: `** BUILD SUCCEEDED **`。

- [ ] **Step 3: 手动验证（写一个 override 并重启）**

```bash
mkdir -p ~/Library/Application\ Support/theall
cat > ~/Library/Application\ Support/theall/config <<EOF
font-size = 18
EOF
```

然后启动 app，新建 workspace/tab 验证字号变大。手动清空：

```bash
rm ~/Library/Application\ Support/theall/config
```

（后续 step 5 会自动验证，手动这步可选但推荐做一次把通路打通。）

- [ ] **Step 4: 跑全量测试确认无回归**

Run: `xcodebuild test -project TheAll.xcodeproj -scheme TheAllTests 2>&1 | tail -20`

Expected: 全绿。

- [ ] **Step 5: 提交**

```bash
git add TheAll/Ghostty/GhosttyBridge.swift
git commit -m "$(cat <<'EOF'
feat(ghostty): load theall override config at highest priority

GhosttyBridge.initialize() 在 finalize 前加载 ~/Library/Application Support/theall/config (如存在)，按 ghostty 语义最后写入的 config 生效，使 theall GUI 设置覆盖用户 ghostty 主 config。

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: ThemeCatalog — 主题列表扫描

**Files:**
- Create: `TheAll/Settings/ThemeCatalog.swift`
- Test: `TheAllTests/ThemeCatalogTests.swift`

### 职责

- 扫描 `Bundle.main.resourcePath/ghostty/themes/` 得到 486 个主题文件名（排序、去点文件）
- 提供 `scan(atPath:)` 入口供测试注入

- [ ] **Step 1: 写失败测试**

创建 `TheAllTests/ThemeCatalogTests.swift`：

```swift
import XCTest
@testable import TheAll

final class ThemeCatalogTests: XCTestCase {

    private var tmpDir: URL!

    override func setUp() {
        super.setUp()
        tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("theall-themes-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmpDir)
        super.tearDown()
    }

    func testReturnsEmptyForMissingDirectory() {
        let result = ThemeCatalog.scan(atPath: "/no/such/dir/theall-nonexistent")
        XCTAssertEqual(result, [])
    }

    func testReturnsSortedFileNamesAndSkipsDotFiles() throws {
        for name in ["Catppuccin Mocha", "Dracula", "Apple Classic", ".DS_Store"] {
            let url = tmpDir.appendingPathComponent(name)
            FileManager.default.createFile(atPath: url.path, contents: Data())
        }
        let result = ThemeCatalog.scan(atPath: tmpDir.path)
        XCTAssertEqual(result, ["Apple Classic", "Catppuccin Mocha", "Dracula"])
    }

    func testBundledThemesIfPresentIncludeKnownName() {
        // 运行 host 带上的 bundle 里应有 486 个；测试 host 可能不带，宽松断言
        let all = ThemeCatalog.all
        if !all.isEmpty {
            XCTAssertTrue(all.contains("Catppuccin Mocha") || all.contains("Dracula"),
                          "bundle themes present but missing well-known names")
        }
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `xcodebuild test -project TheAll.xcodeproj -scheme TheAllTests -only-testing:TheAllTests/ThemeCatalogTests 2>&1 | tail -20`

Expected: 编译失败，缺 `ThemeCatalog`。

- [ ] **Step 3: 实现 `ThemeCatalog`**

创建 `TheAll/Settings/ThemeCatalog.swift`：

```swift
import Foundation

/// ghostty vendor 主题目录的只读扫描。结果按文件名字母序排序、忽略点文件。
/// 主题文件随 bundle 由 xcodegen 的 postBuildScript 拷贝到
/// `Bundle.main.resourcePath/ghostty/themes/`。
enum ThemeCatalog {

    /// 扫描任意目录，返回文件名（非 `.` 开头）排序列表。
    static func scan(atPath path: String) -> [String] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: path) else {
            return []
        }
        return names.filter { !$0.hasPrefix(".") }.sorted()
    }

    /// 运行时 bundle 内的所有主题名。懒求值，首次访问后缓存。
    static let all: [String] = {
        guard let base = Bundle.main.resourcePath else { return [] }
        let themesDir = (base as NSString).appendingPathComponent("ghostty/themes")
        return scan(atPath: themesDir)
    }()
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `xcodebuild test -project TheAll.xcodeproj -scheme TheAllTests -only-testing:TheAllTests/ThemeCatalogTests 2>&1 | tail -20`

Expected: 3 个 case pass。

- [ ] **Step 5: 提交**

```bash
git add TheAll/Settings/ThemeCatalog.swift TheAllTests/ThemeCatalogTests.swift
git commit -m "$(cat <<'EOF'
feat(settings): add ThemeCatalog to enumerate bundled ghostty themes

扫描 Bundle.main.resourcePath/ghostty/themes，排序、忽略点文件；单测通过 scan(atPath:) 注入临时目录。

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: SettingsSection + SettingsTabBarView

**Files:**
- Create: `TheAll/Settings/SettingsSection.swift`
- Create: `TheAll/Settings/SettingsTabBarView.swift`

### 职责

- `SettingsSection` 枚举：四分类、label 字符串
- `SettingsTabBarView`：水平只读 tab 条，视觉向 `TabContent/TabBarView` 看齐（pill 形状、相同圆角、相同 theme token），但无 `+` 按钮、无 `×` 按钮、无右键菜单、无拖拽

- [ ] **Step 1: 实现 `SettingsSection`**

创建 `TheAll/Settings/SettingsSection.swift`：

```swift
import Foundation

/// 设置视图的四个硬编码分类。顺序即 tab 条显示顺序，不可重排。
enum SettingsSection: String, CaseIterable, Identifiable {
    case appearance
    case font
    case terminal
    case shell

    var id: String { rawValue }

    var label: String {
        switch self {
        case .appearance: return "Appearance"
        case .font:       return "Font"
        case .terminal:   return "Terminal"
        case .shell:      return "Shell"
        }
    }
}
```

- [ ] **Step 2: 实现 `SettingsTabBarView`**

创建 `TheAll/Settings/SettingsTabBarView.swift`：

```swift
import SwiftUI

/// 只读水平 tab 条。视觉复刻 TabContent/TabBarView（pill 形状 + 同圆角 + AppTheme token），
/// 但无关闭 / 拖拽 / 增加 / 重命名交互。
struct SettingsTabBarView: View {
    let theme: AppTheme
    @Binding var selection: SettingsSection

    var body: some View {
        HStack(spacing: TabBarView.pillInset) {
            ForEach(SettingsSection.allCases) { section in
                pill(for: section)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, TabBarView.pillInset)
        .frame(height: TabBarView.height)
        .background(
            RoundedRectangle(cornerRadius: TabBarView.stripRadius, style: .continuous)
                .fill(Color(theme.sidebar))
        )
    }

    private func pill(for section: SettingsSection) -> some View {
        let isSelected = selection == section
        return Button {
            selection = section
        } label: {
            Text(section.label)
                .font(Font(DT.Font.body))
                .foregroundColor(Color(isSelected ? theme.textPrimary : theme.textSecondary))
                .padding(.horizontal, DT.Space.sm)
                .frame(height: TabBarView.height - 2 * TabBarView.pillInset)
                .background(
                    RoundedRectangle(cornerRadius: TabBarView.pillRadius, style: .continuous)
                        .fill(Color(isSelected ? theme.canvas : .clear))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
```

- [ ] **Step 3: 编译通过**

Run: `xcodebuild -project TheAll.xcodeproj -scheme TheAll -configuration Debug build 2>&1 | tail -10`

Expected: `** BUILD SUCCEEDED **`。

- [ ] **Step 4: 提交**

```bash
git add TheAll/Settings/SettingsSection.swift TheAll/Settings/SettingsTabBarView.swift
git commit -m "$(cat <<'EOF'
feat(settings): add SettingsSection enum and read-only SettingsTabBarView

四分类硬编码 enum + 水平 pill tab 条，视觉复刻 TabBarView 但无编辑交互。

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: SettingsView 根壳（占位 section）

**Files:**
- Create: `TheAll/Settings/SettingsView.swift`
- Create: `TheAll/Settings/Sections/AppearanceSectionView.swift` (占位)
- Create: `TheAll/Settings/Sections/FontSectionView.swift` (占位)
- Create: `TheAll/Settings/Sections/TerminalSectionView.swift` (占位)
- Create: `TheAll/Settings/Sections/ShellSectionView.swift` (占位)

### 职责

- `SettingsView`：header + tab 条 + section switcher + footer 提示
- 四个 section 先占位（显示 "Coming soon"），后续任务逐个填充

- [ ] **Step 1: 实现四个占位 section**

创建 `TheAll/Settings/Sections/AppearanceSectionView.swift`：

```swift
import SwiftUI

struct AppearanceSectionView: View {
    let theme: AppTheme
    let settings: SettingsConfigStore

    var body: some View {
        Text("Appearance — coming soon")
            .font(Font(DT.Font.body))
            .foregroundColor(Color(theme.textSecondary))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}
```

创建 `TheAll/Settings/Sections/FontSectionView.swift`：

```swift
import SwiftUI

struct FontSectionView: View {
    let theme: AppTheme
    let settings: SettingsConfigStore

    var body: some View {
        Text("Font — coming soon")
            .font(Font(DT.Font.body))
            .foregroundColor(Color(theme.textSecondary))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}
```

创建 `TheAll/Settings/Sections/TerminalSectionView.swift`：

```swift
import SwiftUI

struct TerminalSectionView: View {
    let theme: AppTheme
    let settings: SettingsConfigStore

    var body: some View {
        Text("Terminal — coming soon")
            .font(Font(DT.Font.body))
            .foregroundColor(Color(theme.textSecondary))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}
```

创建 `TheAll/Settings/Sections/ShellSectionView.swift`：

```swift
import SwiftUI

struct ShellSectionView: View {
    let theme: AppTheme
    let settings: SettingsConfigStore

    var body: some View {
        Text("Shell — coming soon")
            .font(Font(DT.Font.body))
            .foregroundColor(Color(theme.textSecondary))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}
```

- [ ] **Step 2: 实现 `SettingsView` 根壳**

创建 `TheAll/Settings/SettingsView.swift`：

```swift
import SwiftUI

struct SettingsView: View {
    let theme: AppTheme
    let settings: SettingsConfigStore
    let onClose: () -> Void

    @State private var section: SettingsSection = .appearance

    var body: some View {
        VStack(spacing: 0) {
            header
            SettingsTabBarView(theme: theme, selection: $section)
                .padding(.horizontal, DT.Space.xs)
            sectionBody
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            footer
        }
        .background(Color(theme.canvas))
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("Settings")
                .font(Font(DT.Font.title))
                .foregroundColor(Color(theme.textPrimary))
            Spacer()
            IconButton(theme: theme, help: "Close settings", action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundColor(Color(theme.textSecondary))
            }
        }
        .padding(.horizontal, DT.Space.md)
        .padding(.vertical, DT.Space.sm)
    }

    // MARK: - Section switcher

    @ViewBuilder
    private var sectionBody: some View {
        switch section {
        case .appearance: AppearanceSectionView(theme: theme, settings: settings)
        case .font:       FontSectionView(theme: theme, settings: settings)
        case .terminal:   TerminalSectionView(theme: theme, settings: settings)
        case .shell:      ShellSectionView(theme: theme, settings: settings)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Button("Edit Config File…") {
                settings.openInEditor()
            }
            .buttonStyle(.link)
            .foregroundColor(Color(theme.textSecondary))
            Spacer()
            Text("Restart theall to apply changes.")
                .font(Font(DT.Font.small))
                .foregroundColor(Color(theme.textTertiary))
        }
        .padding(.horizontal, DT.Space.md)
        .padding(.vertical, DT.Space.sm)
        .background(Color(theme.sidebar))
    }
}
```

- [ ] **Step 3: 编译通过**

Run: `xcodebuild -project TheAll.xcodeproj -scheme TheAll -configuration Debug build 2>&1 | tail -10`

Expected: `** BUILD SUCCEEDED **`。

- [ ] **Step 4: 提交**

```bash
git add TheAll/Settings/SettingsView.swift TheAll/Settings/Sections/
git commit -m "$(cat <<'EOF'
feat(settings): add SettingsView shell with placeholder sections

根视图 header + tab 条 + section switch + footer，四个 section 暂为占位，后续任务逐个填充。

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: ContentView 切换 + Sidebar footer 齿轮按钮

**Files:**
- Modify: `TheAll/ContentView.swift`
- Modify: `TheAll/Sidebar/SidebarView.swift`

### 职责

- `ContentView`：新增 `showSettings` 状态 + `settingsStore` 实例；右侧条件渲染；声明两个 Notification name；订阅；store.selectedWorkspaceId 变化时清除 `showSettings`
- `SidebarView`：VStack 末尾加 footer 齿轮按钮，点击 post `.theAllOpenSettings`

- [ ] **Step 1: 在 ContentView.swift 声明两个 Notification name**

打开 `TheAll/ContentView.swift`，在文件末尾的 `extension Notification.Name` 里加两行。找到：

```swift
    // Edit menu → focused GhosttyTerminalView (routes to ghostty_surface_binding_action).
    static let theAllCopy                 = Notification.Name("theall.copy")
    static let theAllPaste                = Notification.Name("theall.paste")
    static let theAllSelectAll            = Notification.Name("theall.selectAll")
}
```

替换为：

```swift
    // Edit menu → focused GhosttyTerminalView (routes to ghostty_surface_binding_action).
    static let theAllCopy                 = Notification.Name("theall.copy")
    static let theAllPaste                = Notification.Name("theall.paste")
    static let theAllSelectAll            = Notification.Name("theall.selectAll")

    // Settings
    static let theAllOpenSettings         = Notification.Name("theall.openSettings")
    static let theAllEditConfigFile       = Notification.Name("theall.editConfigFile")
}
```

- [ ] **Step 2: 在 ContentView 里新增 `showSettings` + `settingsStore` + 条件渲染 + 订阅**

打开 `TheAll/ContentView.swift`，修改 struct 顶部字段。找到：

```swift
struct ContentView: View {
    @State private var store = WorkspaceStore()
    @State private var statusStore = TerminalStatusStore()
    @State private var sidebarCollapsed: Bool = false
    @State private var hookListener: HookSocketListener?
    @Environment(ThemeManager.self) private var themeManager
```

替换为：

```swift
struct ContentView: View {
    @State private var store = WorkspaceStore()
    @State private var statusStore = TerminalStatusStore()
    @State private var settingsStore = SettingsConfigStore()
    @State private var sidebarCollapsed: Bool = false
    @State private var showSettings: Bool = false
    @State private var hookListener: HookSocketListener?
    @Environment(ThemeManager.self) private var themeManager
```

然后修改 body 内部右侧渲染。找到：

```swift
                TabBridge(store: store, statusStore: statusStore, theme: themeManager.theme)
                    .background(Color(themeManager.theme.canvas))
                    .clipShape(RoundedRectangle(cornerRadius: cardRadius, style: .continuous))
                    .padding(.top, trafficLightInset)
                    .padding(.leading, sidebarCollapsed ? cardInset : 0)
                    .padding(.trailing, cardInset)
                    .padding(.bottom, cardInset)
```

替换为：

```swift
                Group {
                    if showSettings {
                        SettingsView(
                            theme: themeManager.theme,
                            settings: settingsStore,
                            onClose: { showSettings = false }
                        )
                    } else {
                        TabBridge(store: store, statusStore: statusStore, theme: themeManager.theme)
                    }
                }
                .background(Color(themeManager.theme.canvas))
                .clipShape(RoundedRectangle(cornerRadius: cardRadius, style: .continuous))
                .padding(.top, trafficLightInset)
                .padding(.leading, sidebarCollapsed ? cardInset : 0)
                .padding(.trailing, cardInset)
                .padding(.bottom, cardInset)
```

然后在现有的 `.onAppear`、`.onChange(of: store.workspaces)` 链后面，加入两个 Notification 订阅 + 一个 selectedWorkspaceId 变化清理 showSettings。找到 body 最末的：

```swift
        .onChange(of: store.workspaces) { _, workspaces in
            let live = Set(workspaces.flatMap { ws in
                ws.tabs.flatMap { $0.layout.allTerminalIds() }
            })
            for (id, _) in statusStore.statusesSnapshot() where !live.contains(id) {
                statusStore.forget(terminalId: id)
            }
        }
    }
```

替换为：

```swift
        .onChange(of: store.workspaces) { _, workspaces in
            let live = Set(workspaces.flatMap { ws in
                ws.tabs.flatMap { $0.layout.allTerminalIds() }
            })
            for (id, _) in statusStore.statusesSnapshot() where !live.contains(id) {
                statusStore.forget(terminalId: id)
            }
        }
        .onChange(of: store.selectedId) { _, _ in
            // 选中 workspace 时自动离开设置视图（点 sidebar 行 → 跳到该 workspace）
            if showSettings { showSettings = false }
        }
        .onReceive(NotificationCenter.default.publisher(for: .theAllOpenSettings)) { _ in
            showSettings = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .theAllEditConfigFile)) { _ in
            settingsStore.openInEditor()
        }
    }
```

- [ ] **Step 3: 在 `SidebarView.swift` 底部加 footer 齿轮按钮**

打开 `TheAll/Sidebar/SidebarView.swift`，修改 body。找到：

```swift
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            SidebarListBridge(
                store: store,
                statusStore: statusStore,
                theme: theme,
                metadata: metadataMap,
                metadataTick: metadataTicker.tick,    // 读取触发 @Observable 跟踪
                onRequestDelete: { workspaceToDelete = $0 }
            )
        }
        .frame(width: DT.Layout.sidebarWidth)
```

替换为：

```swift
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            SidebarListBridge(
                store: store,
                statusStore: statusStore,
                theme: theme,
                metadata: metadataMap,
                metadataTick: metadataTicker.tick,    // 读取触发 @Observable 跟踪
                onRequestDelete: { workspaceToDelete = $0 }
            )
            footer
        }
        .frame(width: DT.Layout.sidebarWidth)
```

然后在文件内的 `// MARK: - Header` 上方 / 之前加一段 footer 视图。找到：

```swift
    // MARK: - Header

    private var header: some View {
```

在其上方加入：

```swift
    // MARK: - Footer

    private var footer: some View {
        HStack {
            IconButton(theme: theme, help: "Settings") {
                NotificationCenter.default.post(name: .theAllOpenSettings, object: nil)
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundColor(Color(theme.textSecondary))
            }
            Spacer()
        }
        .padding(.horizontal, DT.Space.sm)
        .padding(.vertical, DT.Space.sm)
    }

    // MARK: - Header

    private var header: some View {
```

- [ ] **Step 4: 编译通过**

Run: `xcodebuild -project TheAll.xcodeproj -scheme TheAll -configuration Debug build 2>&1 | tail -10`

Expected: `** BUILD SUCCEEDED **`。

- [ ] **Step 5: 手动冒烟**

启动 app，点 sidebar 左下角齿轮按钮 → 右侧切换到 Settings 视图（显示四个 tab + "Appearance — coming soon"）；点 tab 切换分类；点 × 或点任一 workspace row → 返回原终端视图。

- [ ] **Step 6: 提交**

```bash
git add TheAll/ContentView.swift TheAll/Sidebar/SidebarView.swift
git commit -m "$(cat <<'EOF'
feat(settings): wire Settings view into ContentView and sidebar footer

ContentView 增加 showSettings/settingsStore 状态和 Notification 订阅；sidebar 加 footer 齿轮按钮；选中 workspace 时自动退出设置。

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: App menu `Settings…` / `Edit Config File…`

**Files:**
- Modify: `TheAll/TheAllApp.swift`

### 职责

- App menu（`theall > …`）加两项；Settings 绑 ⌘,；Edit Config File 无快捷键
- 两者 post 已在 Task 6 声明的 Notification

- [ ] **Step 1: 在 commands builder 中插入 App menu 组**

打开 `TheAll/TheAllApp.swift`，找到 `var body: some Scene` 的 `.commands { ... }` 开头。找到：

```swift
        .commands {
            // ── File ──────────────────────────────────────────────────
            CommandGroup(replacing: .newItem) {
                Button("New Workspace") {
                    post(.theAllBeginCreateWorkspace)
                }
                .keyboardShortcut("n", modifiers: .command)
            }

            // Strip default macOS items that don't apply to a terminal workspace app.
            strippedDefaultCommands
```

替换为：

```swift
        .commands {
            // ── App menu (theall > …) ───────────────────────────────────
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    post(.theAllOpenSettings)
                }
                .keyboardShortcut(",", modifiers: .command)

                Button("Edit Config File…") {
                    post(.theAllEditConfigFile)
                }
            }

            // ── File ──────────────────────────────────────────────────
            CommandGroup(replacing: .newItem) {
                Button("New Workspace") {
                    post(.theAllBeginCreateWorkspace)
                }
                .keyboardShortcut("n", modifiers: .command)
            }

            // Strip default macOS items that don't apply to a terminal workspace app.
            strippedDefaultCommands
```

- [ ] **Step 2: 编译通过**

Run: `xcodebuild -project TheAll.xcodeproj -scheme TheAll -configuration Debug build 2>&1 | tail -10`

Expected: `** BUILD SUCCEEDED **`。

- [ ] **Step 3: 手动验证菜单**

启动 app，点菜单栏 `theall > Settings…`（⌘,）→ 打开设置；再点 `theall > Edit Config File…` → 默认编辑器打开 `~/Library/Application Support/theall/config`（首次调用会创建空文件）。

- [ ] **Step 4: 提交**

```bash
git add TheAll/TheAllApp.swift
git commit -m "$(cat <<'EOF'
feat(menu): add Settings… (⌘,) and Edit Config File… to App menu

CommandGroup(replacing: .appSettings) 注入两项，分别 post theAllOpenSettings / theAllEditConfigFile。

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 8: BoundControls — 绑 SettingsConfigStore 的通用控件

**Files:**
- Create: `TheAll/Settings/Components/BoundControls.swift`

### 职责

提供通用 SwiftUI 控件包装，每个控件直接读写 `SettingsConfigStore.get/set`；值等于 default 时写 `nil`（删除该行）。涵盖：
- `BoundToggle` — Toggle ↔ "true"/"false"
- `BoundSlider` — Slider ↔ Double 序列化
- `BoundStepper` — Stepper ↔ Int
- `BoundTextField` — 文本输入 ↔ String
- `BoundSegmented` — 枚举下拉 ↔ String
- `BoundMultiSelect` — 多项 toggle 集合 ↔ "a,b,c"

每个控件的 API 形如：
```swift
BoundToggle(settings: settings, key: "cursor-style-blink", default: false, label: "Cursor Blink")
```

- [ ] **Step 1: 创建 `BoundControls.swift`**

创建 `TheAll/Settings/Components/BoundControls.swift`：

```swift
import SwiftUI

// MARK: - BoundToggle

struct BoundToggle: View {
    let settings: SettingsConfigStore
    let key: String
    let defaultValue: Bool
    let label: String

    var body: some View {
        Toggle(label, isOn: Binding(
            get: {
                guard let raw = settings.get(key) else { return defaultValue }
                return raw.lowercased() == "true"
            },
            set: { newValue in
                if newValue == defaultValue {
                    settings.set(key, nil)
                } else {
                    settings.set(key, newValue ? "true" : "false")
                }
            }
        ))
    }
}

// MARK: - BoundSlider

struct BoundSlider: View {
    let settings: SettingsConfigStore
    let key: String
    let defaultValue: Double
    let range: ClosedRange<Double>
    let step: Double
    let label: String

    var body: some View {
        let value = Binding<Double>(
            get: {
                guard let raw = settings.get(key), let v = Double(raw) else {
                    return defaultValue
                }
                return v
            },
            set: { newValue in
                let rounded = (newValue / step).rounded() * step
                if abs(rounded - defaultValue) < step / 2 {
                    settings.set(key, nil)
                } else {
                    settings.set(key, Self.format(rounded))
                }
            }
        )
        return LabeledContent(label) {
            HStack {
                Slider(value: value, in: range, step: step)
                    .frame(minWidth: 160)
                Text(Self.format(value.wrappedValue))
                    .monospacedDigit()
                    .frame(width: 48, alignment: .trailing)
            }
        }
    }

    private static func format(_ v: Double) -> String {
        if v == floor(v) { return String(Int(v)) }
        return String(format: "%.2f", v)
    }
}

// MARK: - BoundStepper (integer)

struct BoundStepper: View {
    let settings: SettingsConfigStore
    let key: String
    let defaultValue: Int
    let range: ClosedRange<Int>
    let label: String

    var body: some View {
        let value = Binding<Int>(
            get: {
                guard let raw = settings.get(key), let v = Int(raw) else {
                    return defaultValue
                }
                return v
            },
            set: { newValue in
                let clamped = min(max(newValue, range.lowerBound), range.upperBound)
                if clamped == defaultValue {
                    settings.set(key, nil)
                } else {
                    settings.set(key, String(clamped))
                }
            }
        )
        return LabeledContent(label) {
            Stepper(value: value, in: range) {
                Text("\(value.wrappedValue)")
                    .monospacedDigit()
                    .frame(minWidth: 40, alignment: .trailing)
            }
        }
    }
}

// MARK: - BoundTextField

struct BoundTextField: View {
    let settings: SettingsConfigStore
    let key: String
    let placeholder: String
    let label: String

    var body: some View {
        LabeledContent(label) {
            TextField(placeholder, text: Binding(
                get: { settings.get(key) ?? "" },
                set: { newValue in
                    let trimmed = newValue.trimmingCharacters(in: .whitespaces)
                    settings.set(key, trimmed.isEmpty ? nil : trimmed)
                }
            ))
            .textFieldStyle(.roundedBorder)
            .frame(minWidth: 220)
        }
    }
}

// MARK: - BoundSegmented (single-select dropdown)

struct BoundSegmented: View {
    let settings: SettingsConfigStore
    let key: String
    /// 首项视作默认值（存到文件会删除该 key 行）
    let options: [String]
    let label: String

    var body: some View {
        let binding = Binding<String>(
            get: { settings.get(key) ?? options.first ?? "" },
            set: { newValue in
                if newValue == options.first {
                    settings.set(key, nil)
                } else {
                    settings.set(key, newValue)
                }
            }
        )
        return LabeledContent(label) {
            Picker("", selection: binding) {
                ForEach(options, id: \.self) { opt in
                    Text(opt).tag(opt)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(minWidth: 140)
        }
    }
}

// MARK: - BoundMultiSelect (comma-joined)

struct BoundMultiSelect: View {
    let settings: SettingsConfigStore
    let key: String
    let allOptions: [String]
    let label: String

    var body: some View {
        LabeledContent(label) {
            VStack(alignment: .leading, spacing: DT.Space.xxs) {
                ForEach(allOptions, id: \.self) { opt in
                    Toggle(opt, isOn: binding(for: opt))
                        .toggleStyle(.checkbox)
                }
            }
        }
    }

    private func binding(for option: String) -> Binding<Bool> {
        Binding(
            get: { currentSet().contains(option) },
            set: { isOn in
                var set = currentSet()
                if isOn { set.insert(option) } else { set.remove(option) }
                let ordered = allOptions.filter { set.contains($0) }
                settings.set(key, ordered.isEmpty ? nil : ordered.joined(separator: ","))
            }
        )
    }

    private func currentSet() -> Set<String> {
        guard let raw = settings.get(key), !raw.isEmpty else { return [] }
        return Set(raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
    }
}
```

- [ ] **Step 2: 编译通过**

Run: `xcodebuild -project TheAll.xcodeproj -scheme TheAll -configuration Debug build 2>&1 | tail -10`

Expected: `** BUILD SUCCEEDED **`。

- [ ] **Step 3: 提交**

```bash
git add TheAll/Settings/Components/BoundControls.swift
git commit -m "$(cat <<'EOF'
feat(settings): add BoundControls bound to SettingsConfigStore

Toggle/Slider/Stepper/TextField/Segmented/MultiSelect 直接读写 store；值等于 default 自动从文件删除对应行。

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 9: TerminalSectionView — 最简单的实分类

**Files:**
- Modify: `TheAll/Settings/Sections/TerminalSectionView.swift`

### 默认值参考（来自 ghostty 官方默认）

- `scrollback-limit`: 10_000_000
- `copy-on-select`: false（首项即 default）
- `mouse-hide-while-typing`: false
- `confirm-close-surface`: true

- [ ] **Step 1: 替换 TerminalSectionView 占位为真实 Form**

打开 `TheAll/Settings/Sections/TerminalSectionView.swift`，整体替换为：

```swift
import SwiftUI

struct TerminalSectionView: View {
    let theme: AppTheme
    let settings: SettingsConfigStore

    var body: some View {
        Form {
            BoundStepper(
                settings: settings,
                key: "scrollback-limit",
                defaultValue: 10_000_000,
                range: 0...100_000_000,
                label: "Scrollback Limit"
            )

            BoundSegmented(
                settings: settings,
                key: "copy-on-select",
                options: ["false", "true", "clipboard"],
                label: "Copy On Select"
            )

            BoundToggle(
                settings: settings,
                key: "mouse-hide-while-typing",
                defaultValue: false,
                label: "Hide Mouse While Typing"
            )

            BoundSegmented(
                settings: settings,
                key: "confirm-close-surface",
                options: ["true", "false", "always"],
                label: "Confirm Close"
            )
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(Color(theme.canvas))
    }
}
```

- [ ] **Step 2: 编译 + 手动冒烟**

Run: `xcodebuild -project TheAll.xcodeproj -scheme TheAll -configuration Debug build 2>&1 | tail -10`

Expected: `** BUILD SUCCEEDED **`。

启动 app，进入设置 → Terminal tab。拖 scrollback-limit 步进器几次 → 查看：

```bash
cat ~/Library/Application\ Support/theall/config
```

应能看到 `scrollback-limit = <值>`。重置到 10000000 → 该行消失。

- [ ] **Step 3: 提交**

```bash
git add TheAll/Settings/Sections/TerminalSectionView.swift
git commit -m "$(cat <<'EOF'
feat(settings): implement Terminal section (scrollback/copy/mouse/confirm)

4 项终端行为设置；值等于 ghostty default 时自动从 override 文件删除对应行。

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 10: ShellSectionView

**Files:**
- Modify: `TheAll/Settings/Sections/ShellSectionView.swift`

### 默认值

- `shell-integration`: `detect`
- `shell-integration-features`: `cursor,sudo,title,ssh-env`（ghostty v1.0 的 default）
- `command`: 空字符串（= 用户默认 shell）

- [ ] **Step 1: 替换占位**

打开 `TheAll/Settings/Sections/ShellSectionView.swift`，整体替换为：

```swift
import SwiftUI

struct ShellSectionView: View {
    let theme: AppTheme
    let settings: SettingsConfigStore

    var body: some View {
        Form {
            BoundSegmented(
                settings: settings,
                key: "shell-integration",
                options: ["detect", "none", "fish", "zsh", "bash"],
                label: "Shell Integration"
            )

            BoundMultiSelect(
                settings: settings,
                key: "shell-integration-features",
                allOptions: ["cursor", "sudo", "title", "ssh-env"],
                label: "Integration Features"
            )

            BoundTextField(
                settings: settings,
                key: "command",
                placeholder: "(default shell)",
                label: "Custom Command"
            )
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(Color(theme.canvas))
    }
}
```

- [ ] **Step 2: 编译 + 手动冒烟**

Run: `xcodebuild -project TheAll.xcodeproj -scheme TheAll -configuration Debug build 2>&1 | tail -10`

Expected: `** BUILD SUCCEEDED **`。

启动后进入设置 → Shell tab → 切 Shell Integration 到 "zsh" → 看 `~/Library/Application Support/theall/config` 有 `shell-integration = zsh`。

- [ ] **Step 3: 提交**

```bash
git add TheAll/Settings/Sections/ShellSectionView.swift
git commit -m "$(cat <<'EOF'
feat(settings): implement Shell section (integration / features / command)

3 项 shell 集成设置；multi-select 按有序 CSV 写入。

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 11: AppearanceSectionView（不含 theme picker）

**Files:**
- Modify: `TheAll/Settings/Sections/AppearanceSectionView.swift`

### 默认值

- `background-opacity`: 1.0
- `background-blur-radius`: 0
- `window-padding-x`: 2
- `window-padding-y`: 2
- `cursor-style`: `block`
- `cursor-style-blink`: false
- `unfocused-split-opacity`: 0.7

Theme 字段留一行"(coming in next task)"占位，Task 13 填充。

- [ ] **Step 1: 替换占位**

打开 `TheAll/Settings/Sections/AppearanceSectionView.swift`，整体替换为：

```swift
import SwiftUI

struct AppearanceSectionView: View {
    let theme: AppTheme
    let settings: SettingsConfigStore

    var body: some View {
        Form {
            LabeledContent("Theme") {
                Text("(coming)")
                    .foregroundColor(Color(theme.textTertiary))
                    .font(Font(DT.Font.small))
            }

            BoundSlider(
                settings: settings,
                key: "background-opacity",
                defaultValue: 1.0,
                range: 0.0...1.0,
                step: 0.05,
                label: "Background Opacity"
            )

            BoundSlider(
                settings: settings,
                key: "background-blur-radius",
                defaultValue: 0,
                range: 0...30,
                step: 1,
                label: "Background Blur"
            )

            BoundStepper(
                settings: settings,
                key: "window-padding-x",
                defaultValue: 2,
                range: 0...100,
                label: "Window Padding X"
            )

            BoundStepper(
                settings: settings,
                key: "window-padding-y",
                defaultValue: 2,
                range: 0...100,
                label: "Window Padding Y"
            )

            BoundSegmented(
                settings: settings,
                key: "cursor-style",
                options: ["block", "bar", "underline"],
                label: "Cursor Style"
            )

            BoundToggle(
                settings: settings,
                key: "cursor-style-blink",
                defaultValue: false,
                label: "Cursor Blink"
            )

            BoundSlider(
                settings: settings,
                key: "unfocused-split-opacity",
                defaultValue: 0.7,
                range: 0.0...1.0,
                step: 0.05,
                label: "Unfocused Split Opacity"
            )
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(Color(theme.canvas))
    }
}
```

- [ ] **Step 2: 编译 + 手动冒烟**

Run: `xcodebuild -project TheAll.xcodeproj -scheme TheAll -configuration Debug build 2>&1 | tail -10`

Expected: `** BUILD SUCCEEDED **`。

启动后进入设置 → Appearance tab。调几个滑块和 cursor-style → 查 override 文件内容正确。

- [ ] **Step 3: 提交**

```bash
git add TheAll/Settings/Sections/AppearanceSectionView.swift
git commit -m "$(cat <<'EOF'
feat(settings): implement Appearance section (padding/cursor/opacity)

7 项 ghostty 外观设置，theme 字段留占位由下一任务填入。

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 12: FontSectionView + FontPickerView

**Files:**
- Create: `TheAll/Settings/Components/FontPickerView.swift`
- Modify: `TheAll/Settings/Sections/FontSectionView.swift`

### 职责

- `FontPickerView`：Picker 列出 `NSFontManager.shared.availableFontNames(with: .fixedPitchFontMask)`，加一项 `Custom…` 切出 TextField
- `FontSectionView` 用 `FontPickerView` + `BoundStepper`(size) + `BoundToggle`(thicken)

默认值：
- `font-family`: "" → 不写
- `font-size`: 13
- `font-thicken`: false

- [ ] **Step 1: 实现 FontPickerView**

创建 `TheAll/Settings/Components/FontPickerView.swift`：

```swift
import SwiftUI
import AppKit

/// 等宽字体下拉 + "Custom…" 模式。绑 SettingsConfigStore 的 `font-family`。
struct FontPickerView: View {
    let settings: SettingsConfigStore
    let label: String

    @State private var isCustom: Bool = false

    /// 系统等宽字体列表（首次访问缓存）。
    private static let systemMonospaceFonts: [String] = {
        (NSFontManager.shared.availableFontNames(with: .fixedPitchFontMask) ?? [])
            .sorted()
    }()

    var body: some View {
        LabeledContent(label) {
            HStack {
                if isCustom {
                    TextField("Font name", text: Binding(
                        get: { settings.get("font-family") ?? "" },
                        set: { settings.set("font-family", $0.isEmpty ? nil : $0) }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 200)

                    Button("List") { isCustom = false }
                        .buttonStyle(.link)
                } else {
                    Picker("", selection: selectionBinding) {
                        Text("(default)").tag("")
                        ForEach(Self.systemMonospaceFonts, id: \.self) { name in
                            Text(name).tag(name)
                        }
                        Text("Custom…").tag("__custom__")
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(minWidth: 200)
                }
            }
        }
        .onAppear {
            // 已写入的 font-family 不在系统列表里 → 自动切换成 custom 模式
            if let current = settings.get("font-family"),
               !Self.systemMonospaceFonts.contains(current) {
                isCustom = true
            }
        }
    }

    private var selectionBinding: Binding<String> {
        Binding(
            get: { settings.get("font-family") ?? "" },
            set: { newValue in
                if newValue == "__custom__" {
                    isCustom = true
                } else if newValue.isEmpty {
                    settings.set("font-family", nil)
                } else {
                    settings.set("font-family", newValue)
                }
            }
        )
    }
}
```

- [ ] **Step 2: 替换 FontSectionView 占位**

打开 `TheAll/Settings/Sections/FontSectionView.swift`，整体替换为：

```swift
import SwiftUI

struct FontSectionView: View {
    let theme: AppTheme
    let settings: SettingsConfigStore

    var body: some View {
        Form {
            FontPickerView(settings: settings, label: "Font Family")

            BoundStepper(
                settings: settings,
                key: "font-size",
                defaultValue: 13,
                range: 6...72,
                label: "Font Size"
            )

            BoundToggle(
                settings: settings,
                key: "font-thicken",
                defaultValue: false,
                label: "Font Thicken"
            )
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(Color(theme.canvas))
    }
}
```

- [ ] **Step 3: 编译 + 手动冒烟**

Run: `xcodebuild -project TheAll.xcodeproj -scheme TheAll -configuration Debug build 2>&1 | tail -10`

Expected: `** BUILD SUCCEEDED **`。

启动 app → 设置 → Font tab。从下拉选 "Menlo" → override 文件出现 `font-family = Menlo`；size 从 13 改到 16 → 有 `font-size = 16`；选 `Custom…` 填 `MonoLisa Custom` → 写入该字符串。

- [ ] **Step 4: 提交**

```bash
git add TheAll/Settings/Components/FontPickerView.swift TheAll/Settings/Sections/FontSectionView.swift
git commit -m "$(cat <<'EOF'
feat(settings): implement Font section with system font dropdown + custom

FontPickerView 枚举 NSFontManager fixedPitch 列表 + Custom… 文本模式；size/thicken 走 BoundStepper/BoundToggle。

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 13: ThemePickerView + 接入 AppearanceSectionView

**Files:**
- Create: `TheAll/Settings/Components/ThemePickerView.swift`
- Modify: `TheAll/Settings/Sections/AppearanceSectionView.swift`

### 职责

- `ThemePickerView`：radio 切 Single / Follow-system，下面用 1 或 2 个 `ThemeDropdown` 子 picker（含搜索 TextField + 过滤列表）
- 写回 `theme` 字段：
  - Single: `theme = <name>`
  - Follow-system: `theme = light:<light>,dark:<dark>`
- 读回：根据是否含 `light:` 前缀决定模式
- 替换 Task 11 在 Appearance section 里的 `(coming)` 占位

- [ ] **Step 1: 实现 ThemePickerView**

创建 `TheAll/Settings/Components/ThemePickerView.swift`：

```swift
import SwiftUI

struct ThemePickerView: View {
    let settings: SettingsConfigStore
    let theme: AppTheme

    enum Mode: String, CaseIterable, Identifiable {
        case single, followSystem
        var id: String { rawValue }
        var label: String {
            switch self {
            case .single:       return "Single"
            case .followSystem: return "Follow system appearance"
            }
        }
    }

    @State private var mode: Mode = .single
    @State private var singleName: String = ""
    @State private var lightName: String = ""
    @State private var darkName: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: DT.Space.sm) {
            Picker("", selection: $mode) {
                ForEach(Mode.allCases) { m in
                    Text(m.label).tag(m)
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            .onChange(of: mode) { _, _ in writeBack() }

            switch mode {
            case .single:
                ThemeDropdown(title: "Theme", selection: Binding(
                    get: { singleName },
                    set: { singleName = $0; writeBack() }
                ), theme: theme)
            case .followSystem:
                VStack(alignment: .leading, spacing: DT.Space.xxs) {
                    ThemeDropdown(title: "Light", selection: Binding(
                        get: { lightName },
                        set: { lightName = $0; writeBack() }
                    ), theme: theme)
                    ThemeDropdown(title: "Dark", selection: Binding(
                        get: { darkName },
                        set: { darkName = $0; writeBack() }
                    ), theme: theme)
                }
            }
        }
        .onAppear(perform: loadFromStore)
    }

    private func loadFromStore() {
        guard let raw = settings.get("theme"), !raw.isEmpty else {
            mode = .single
            singleName = ""
            lightName = ""
            darkName = ""
            return
        }
        if raw.hasPrefix("light:") || raw.contains(",dark:") {
            // "light:A,dark:B"
            mode = .followSystem
            for part in raw.split(separator: ",") {
                let p = part.trimmingCharacters(in: .whitespaces)
                if p.hasPrefix("light:") {
                    lightName = String(p.dropFirst("light:".count))
                } else if p.hasPrefix("dark:") {
                    darkName = String(p.dropFirst("dark:".count))
                }
            }
        } else {
            mode = .single
            singleName = raw
        }
    }

    private func writeBack() {
        switch mode {
        case .single:
            let s = singleName.trimmingCharacters(in: .whitespaces)
            settings.set("theme", s.isEmpty ? nil : s)
        case .followSystem:
            let l = lightName.trimmingCharacters(in: .whitespaces)
            let d = darkName.trimmingCharacters(in: .whitespaces)
            if l.isEmpty && d.isEmpty {
                settings.set("theme", nil)
            } else {
                settings.set("theme", "light:\(l),dark:\(d)")
            }
        }
    }
}

/// 带搜索的主题下拉。
private struct ThemeDropdown: View {
    let title: String
    @Binding var selection: String
    let theme: AppTheme

    @State private var query: String = ""

    var body: some View {
        LabeledContent(title) {
            Menu {
                TextField("Search themes", text: $query)
                    .textFieldStyle(.plain)
                Divider()
                ScrollView {
                    LazyVStack(alignment: .leading) {
                        ForEach(filtered, id: \.self) { name in
                            Button(name) { selection = name }
                        }
                    }
                }
                .frame(maxHeight: 280)
            } label: {
                Text(selection.isEmpty ? "(select theme)" : selection)
                    .frame(minWidth: 200, alignment: .leading)
            }
            .menuStyle(.borderlessButton)
        }
    }

    private var filtered: [String] {
        guard !query.isEmpty else { return ThemeCatalog.all }
        let lower = query.lowercased()
        return ThemeCatalog.all.filter { $0.lowercased().contains(lower) }
    }
}
```

- [ ] **Step 2: 在 AppearanceSectionView 里替换 Theme 占位**

打开 `TheAll/Settings/Sections/AppearanceSectionView.swift`，找到：

```swift
            LabeledContent("Theme") {
                Text("(coming)")
                    .foregroundColor(Color(theme.textTertiary))
                    .font(Font(DT.Font.small))
            }
```

替换为：

```swift
            LabeledContent("Theme") {
                ThemePickerView(settings: settings, theme: theme)
            }
```

- [ ] **Step 3: 编译 + 手动冒烟**

Run: `xcodebuild -project TheAll.xcodeproj -scheme TheAll -configuration Debug build 2>&1 | tail -10`

Expected: `** BUILD SUCCEEDED **`。

启动 app → 设置 → Appearance tab → Theme：
1. Single 模式选 "Catppuccin Mocha" → override 有 `theme = Catppuccin Mocha`
2. 切 Follow system → 选 Light: "Catppuccin Latte"、Dark: "Catppuccin Mocha" → override 有 `theme = light:Catppuccin Latte,dark:Catppuccin Mocha`
3. 重启 app → 终端主题切换到新值

- [ ] **Step 4: 提交**

```bash
git add TheAll/Settings/Components/ThemePickerView.swift TheAll/Settings/Sections/AppearanceSectionView.swift
git commit -m "$(cat <<'EOF'
feat(settings): add ThemePickerView with single and follow-system modes

Single 和 follow-system 双模式；下拉支持搜索过滤；读回时根据是否含 light: 前缀自动识别模式。

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 14: 收尾 — 完整构建 / 全量测试 / 手动验证清单

**Files:**
- 无代码改动

- [ ] **Step 1: 全量构建**

Run: `xcodebuild -project TheAll.xcodeproj -scheme TheAll -configuration Debug build 2>&1 | tail -15`

Expected: `** BUILD SUCCEEDED **`。

- [ ] **Step 2: 全量单测**

Run: `xcodebuild test -project TheAll.xcodeproj -scheme TheAllTests 2>&1 | tail -30`

Expected: `** TEST SUCCEEDED **`；`SettingsConfigStoreTests` 7 case、`ThemeCatalogTests` 3 case 均 pass；其它既有 test 无回归。

- [ ] **Step 3: 手动验证 checklist**

启动 app，逐条过：

- [ ] 点 sidebar 左下角齿轮 → 进入设置；再点 → 离开
- [ ] 设置打开状态下点 sidebar 任一 workspace → 自动离开设置并选中该 workspace
- [ ] `theall > Settings…`（⌘,）快捷键 → 打开设置
- [ ] `theall > Edit Config File…` → 系统默认 editor 打开 `~/Library/Application Support/theall/config`（首次调用自动创建空文件）
- [ ] Sidebar 折叠（左上 `sidebar.left` 按钮）→ 齿轮按钮跟随隐藏
- [ ] Terminal → 改 `scrollback-limit` 到 50000 → cat override 文件见 `scrollback-limit = 50000`；改回 10000000 → 该行消失
- [ ] Shell → 勾选 `sudo` + `title` → 文件 `shell-integration-features = sudo,title`
- [ ] Appearance → 滑 opacity 到 0.85 → 文件 `background-opacity = 0.85`
- [ ] Appearance → Cursor Style 改 underline → 文件 `cursor-style = underline`
- [ ] Font → 从下拉选 Menlo → 文件 `font-family = Menlo`
- [ ] Font → Custom… 填 "FiraCode Nerd Font" → 文件 `font-family = FiraCode Nerd Font`
- [ ] Appearance Theme → Single 选 "Catppuccin Mocha" → 文件 `theme = Catppuccin Mocha`
- [ ] Appearance Theme → Follow system → Light: Catppuccin Latte / Dark: Catppuccin Mocha → 文件 `theme = light:Catppuccin Latte,dark:Catppuccin Mocha`
- [ ] 重启 app → 终端反映新字号 / 主题 / padding 等值
- [ ] 把每个字段都恢复到 default → 文件要么被删空（残留空行无所谓）要么只剩用户手写未识别行
- [ ] 手工往 `~/Library/Application Support/theall/config` 加一行 `# my comment` → 重启后 GUI 改动不破坏该注释
- [ ] 手工在文件里加 `keybind = ctrl+alt+q=new_split:right` → GUI 改其它字段后重启，该行仍在

- [ ] **Step 4: 如上述清单全过，合 PR**

Run（在 agent 分支）：

```bash
gh pr create --title "feat(settings): in-app settings view with ghostty override config" --body "$(cat <<'EOF'
## Summary
- 新增 theall GUI 设置视图（sidebar 左下角齿轮入口 + App menu Settings… ⌘,）
- 四个硬编码分类 tab：Appearance / Font / Terminal / Shell
- 写入独立 override 文件 `~/Library/Application Support/theall/config`，在 GhosttyBridge 启动时最后加载以覆盖用户原 ghostty config
- 改动重启 theall 后生效；菜单栏 Edit Config File… 直接打开 override 文件供高级字段手改

## Test plan
- [ ] 全量 xcodebuild test 通过
- [ ] 手动验证清单全部勾选（见 plan 的 Task 14 Step 3）

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

---

## 备注：实施顺序

Tasks 按硬依赖线性排列：

```
1 (ConfigStore) ──► 2 (Bridge load) ──► 3 (ThemeCatalog)
                                            │
                                            ▼
               4 (Section/TabBar) ──► 5 (Shell view) ──► 6 (wire) ──► 7 (menu)
                                                                       │
                                                                       ▼
                                              8 (BoundControls) ──► 9, 10, 11
                                                                       │
                                                                       ▼
                                                                  12 (Font) ──► 13 (Theme)
                                                                                   │
                                                                                   ▼
                                                                              14 (verify)
```

Task 9 / 10 / 11 相互独立、可并行（不依赖彼此）。Task 12、13 在 11 之后（11 留了 theme 占位槽位）。
