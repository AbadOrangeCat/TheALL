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
    private var liveThrottleLastFire: Date = .distantPast
    private var liveTrailingTask: Task<Void, Never>?
    /// setLive 的 throttle 间隔。滑杆拖动常在 60Hz 触发 setter —— 50ms(20Hz) 已经
    /// 足够平滑、又把 reloadConfig 的 CPU 成本压在合理水位。
    private static let liveThrottleInterval: TimeInterval = 0.05

    /// Fired on the main actor after each debounced write lands on disk.
    /// ContentView wires this to GhosttyBridge.reloadConfig + ThemeManager.refresh
    /// so every GUI edit propagates to live terminals without restarting theall.
    /// Not invoked by `save()` (test path) — tests don't drive a live app.
    var onChange: (() -> Void)?

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
    ///
    /// 若本次调用不会改变 `lines`（设同值 / 删不存在的 key），直接返回，不排写盘、
    /// 不触发 onChange。原因：SwiftUI 的 `Binding(get:set:)` TextField 在焦点切换时
    /// 会以当前值回调一次 setter；如果不早返回，每次 focus 都会触发 reloadConfig →
    /// theme refresh → 视图重建 → TextField 焦点丢失，输入框形同不可聚焦。
    func set(_ key: String, _ value: String?) {
        guard updateLines(key: key, value: value) else { return }
        scheduleWrite()
    }

    /// 与 `set` 语义相同，但以 throttle 取代 debounce（leading edge 立即 flush，
    /// 然后 trailing edge 在 `liveThrottleInterval` 后收尾）。给滑杆这类期望连续
    /// 视觉反馈的控件用，让用户拖动过程中 blur / opacity 等能持续跟随，而不是
    /// 全部攒到 debounce 结束后再 snap 一下。
    ///
    /// 文本框 / 下拉选择仍应用 `set`：typing 与 focus 切换对"每次设值都立即写盘并
    /// 触发 reloadConfig"比较敏感（会破坏 TextField 焦点与中文输入合成），而且
    /// 没有实时反馈需求。
    func setLive(_ key: String, _ value: String?) {
        guard updateLines(key: key, value: value) else { return }
        scheduleLiveWrite()
    }

    @discardableResult
    private func updateLines(key: String, value: String?) -> Bool {
        let existingIdx = lines.firstIndex(where: {
            if case .kv(let k, _) = $0 { return k == key }
            return false
        })

        if let idx = existingIdx {
            guard case .kv(_, let existing) = lines[idx] else { return false }
            if let value {
                if existing == value { return false }
                lines[idx] = .kv(key: key, value: value)
            } else {
                lines.remove(at: idx)
            }
        } else {
            guard let value else { return false }
            if let last = lines.last, case .blank = last {
                // 尾已空行，直接 append
            } else if !lines.isEmpty {
                lines.append(.blank)
            }
            lines.append(.kv(key: key, value: value))
        }
        return true
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
        // setLive 路径的 trailing 若正等着，也要一并 cancel —— 两条写路径共用
        // `lines` 状态，保留其中一个即可。
        liveTrailingTask?.cancel()
        liveTrailingTask = nil
        writeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard let self, !Task.isCancelled else { return }
            self.writeToDisk()
            self.liveThrottleLastFire = Date()
            self.onChange?()
        }
    }

    /// leading + trailing throttle：首次（或距上次 fire 超过 interval）立即写盘 +
    /// 触发 onChange；interval 内后续调用只排一次 trailing task，让它 fire 时
    /// 拿到最新 `lines` 落盘。
    private func scheduleLiveWrite() {
        let now = Date()
        let elapsed = now.timeIntervalSince(liveThrottleLastFire)

        if elapsed >= Self.liveThrottleInterval {
            writeTask?.cancel()
            writeTask = nil
            liveTrailingTask?.cancel()
            liveTrailingTask = nil
            writeToDisk()
            liveThrottleLastFire = Date()
            onChange?()
            return
        }

        if liveTrailingTask == nil {
            let delay = Self.liveThrottleInterval - elapsed
            liveTrailingTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard let self, !Task.isCancelled else { return }
                self.writeTask?.cancel()
                self.writeTask = nil
                self.liveTrailingTask = nil
                self.writeToDisk()
                self.liveThrottleLastFire = Date()
                self.onChange?()
            }
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
