import Foundation
import Observation

struct AIQuotaWindow: Codable, Equatable {
    let windowMinutes: Int
    let remainingPercent: Int
    let resetsAt: Int?
}

/// Only station names and counters leave the live session.
struct AIActivityStation: Codable, Equatable {
    let station: String
    var active = 0
    var completed = 0
    var failed = 0

    static let displayOrder = ["you", "model", "memory", "files", "shell", "network", "browser", "agents", "skills", "hooks"]

    // Mirrored by desktop/src/activity-map.mjs; keep both in sync.
    private static func mcpStation(_ server: String?, tool: String?) -> String {
        switch server {
        case "memory": return "memory"
        case "Claude_Browser", "claude-in-chrome", "playwright", "browser", "chrome-devtools": return "browser"
        case "remote-devices" where tool?.hasPrefix("Claude_Browser__") == true: return "browser"
        case "plugin-authoring": return "skills"
        case "terminal": return "shell"
        default:
            let name = server?.lowercased() ?? ""
            if ["browser", "chrome", "playwright", "puppeteer", "safari"].contains(where: name.contains) { return "browser" }
            if name.contains("memory") { return "memory" }
            return "network"
        }
    }

    /// Auto memory and instruction files. TheAll gives Claude Code its own config
    /// directory (`…/claude/projects/<project>/memory/`, no leading dot) and Windows
    /// gives Codex `…\codex\`, so both the dotted and undotted folders count.
    static func fileStation(_ path: String?) -> String {
        let path = path?.replacingOccurrences(of: "\\", with: "/") ?? ""
        return path.range(of: #"/\.?claude/projects/[^/]+/memory(/|$)|/\.?codex/memories(/|$)|(^|/)(CLAUDE|CLAUDE\.local|AGENTS)\.md$"#,
                          options: .regularExpression) == nil ? "files" : "memory"
    }

    private static let networkPrograms: Set<String> = ["curl", "wget", "http", "https", "xh", "httpie", "aria2c", "gh", "ssh", "scp",
        "sftp", "rsync", "ftp", "telnet", "nc", "ping", "dig", "nslookup", "host", "invoke-webrequest", "iwr", "invoke-restmethod", "irm"]
    private static let networkSubcommands: [String: Set<String>] = [
        "git": ["clone", "fetch", "pull", "push", "ls-remote"],
        "npm": ["install", "i", "add", "ci", "update", "upgrade", "publish", "view", "info", "outdated", "audit"],
        "pnpm": ["install", "i", "add", "update", "upgrade", "publish", "outdated", "audit", "dlx"],
        "yarn": ["install", "add", "upgrade", "publish", "info", "dlx"],
        "bun": ["install", "i", "add", "update", "upgrade", "publish"],
        "pip": ["install", "download"], "pip3": ["install", "download"], "pipx": ["install", "run"],
        "uv": ["add", "sync", "lock"], "poetry": ["add", "install", "update", "lock", "publish"],
        "brew": ["install", "update", "upgrade", "fetch", "tap", "reinstall"],
        "cargo": ["install", "fetch", "update", "publish", "search"],
        "go": ["get", "install"], "gem": ["install", "update"],
        "apt": ["install", "update", "upgrade"], "apt-get": ["install", "update", "upgrade"],
        "dnf": ["install", "update", "upgrade"], "yum": ["install", "update"],
        "docker": ["pull", "push", "login", "search"], "podman": ["pull", "push", "login", "search"],
        "winget": ["install", "upgrade", "search"], "choco": ["install", "upgrade", "search"], "scoop": ["install", "update", "search"],
    ]

    /// Shell commands that reach the internet count as Network, and ones that open
    /// or drive a web browser count as Browser; everything else stays Shell.
    static func commandStation(_ command: String?) -> String {
        guard let command, !command.isEmpty, command.utf8.count <= 64 * 1024 else { return "shell" }
        var station = "shell"
        for segment in command.components(separatedBy: CharacterSet(charactersIn: ";|&\n()")) {
            var words = segment.split(whereSeparator: \.isWhitespace)
                .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`")) }.filter { !$0.isEmpty }
            while let first = words.first, (first.contains("=") && !first.hasPrefix("-"))
                    || ["sudo", "env", "time", "nohup", "command", "exec", "xargs", "npx", "bunx", "uvx"].contains(first) {
                words.removeFirst()
            }
            guard let first = words.first else { continue }
            let program = first.replacingOccurrences(of: "\\", with: "/").components(separatedBy: "/").last?.lowercased() ?? first
            let rest = words.dropFirst().map { $0.lowercased() }
            let subcommand = rest.first { !$0.hasPrefix("-") }
            let opensURL = rest.contains { $0.hasPrefix("http://") || $0.hasPrefix("https://") }
            if (["open", "xdg-open", "start", "start-process"].contains(program) && opensURL)
                || ["playwright", "puppeteer"].contains(program)
                || (program == "osascript" && ["safari", "chrome", "firefox", "edge"].contains { segment.lowercased().contains($0) }) {
                return "browser"
            }
            if networkPrograms.contains(program)
                || subcommand.map({ networkSubcommands[program]?.contains($0) ?? false }) == true
                || (program.hasPrefix("python") && rest.contains("pip") && rest.contains("install"))
                || (program == "go" && subcommand == "mod" && rest.contains("download")) {
                station = "network"
            }
        }
        return station
    }

    static func claudeTool(_ name: String?, input: [String: Any]?) -> String? {
        switch name {
        case nil, "Task", "Agent": return nil
        case "Read", "Write", "Edit", "MultiEdit", "NotebookEdit", "Glob", "Grep", "LS", "LSP":
            return fileStation((input?["file_path"] ?? input?["notebook_path"] ?? input?["path"]) as? String)
        case "AskUserQuestion", "SendUserFile", "TaskCreate", "TaskUpdate", "TaskList", "TaskGet", "TodoWrite", "EnterPlanMode", "ExitPlanMode": return "you"
        case "Skill", "ToolSearch", "ListSkills", "SearchSkills", "SuggestSkills", "ListPlugins", "SearchPlugins", "SuggestPluginInstall", "ListConnectors", "SearchMcpRegistry", "SuggestConnectors", "WaitForMcpServers": return "skills"
        case "WebFetch", "WebSearch", "Artifact": return "network"
        case "Bash", "PowerShell": return commandStation(input?["command"] as? String)
        case "ListMcpResourcesTool", "ReadMcpResourceTool", "ReadMcpResourceDirTool": return mcpStation(input?["server"] as? String, tool: nil)
        default:
            guard let name, name.hasPrefix("mcp__") else { return "shell" }
            let parts = name.dropFirst(5).components(separatedBy: "__")
            return mcpStation(parts.first, tool: parts.dropFirst().joined(separator: "__"))
        }
    }

    static func codexItem(_ item: [String: Any]) -> String? {
        switch item["type"] as? String {
        case "commandExecution":
            guard let actions = item["commandActions"] as? [[String: Any]], !actions.isEmpty,
                  actions.allSatisfy({ ["read", "listFiles", "search"].contains($0["type"] as? String ?? "") }) else { return commandStation(item["command"] as? String) }
            return actions.allSatisfy { fileStation($0["path"] as? String) == "memory" } ? "memory" : "files"
        case "fileChange", "imageView": return fileStation((item["path"] ?? (item["changes"] as? [[String: Any]])?.first?["path"]) as? String)
        case "webSearch": return "network"
        case "mcpToolCall": return mcpStation(item["server"] as? String, tool: item["tool"] as? String)
        case "dynamicToolCall": return claudeTool(item["tool"] as? String, input: item["arguments"] as? [String: Any])
        case "plan", "enteredReviewMode", "exitedReviewMode": return "you"
        case "contextCompaction": return "model"
        default: return nil
        }
    }
}

struct AIChatSubagent: Identifiable, Codable, Equatable {
    enum Status: String, Codable { case running, done, failed, stopped }
    var id: String
    var title: String
    var detail: String
    var status: Status
}

/// Runtime-only provider activity. It is deliberately absent from saved history.
private struct AIChatSubagentTracker {
    var agents: [AIChatSubagent] = []
    var background = Set<String>()
    var tools = Set<String>()
    var runs: [String: String] = [:]
    var codexCompletedItems = Set<String>()
    var codexOrigins: [String: String] = [:]
    var redact: (String) -> String = { $0 }

    private func identifier(_ value: Any?) -> String? {
        guard let value = value as? String, !value.isEmpty, value.count <= 256 else { return nil }
        return value
    }
    private func state(_ value: Any?) -> AIChatSubagent.Status? {
        switch value as? String {
        case "running", "pending", "pendingInit": .running
        case "completed": .done
        case "failed", "errored", "notFound": .failed
        case "interrupted", "shutdown", "stopped", "killed": .stopped
        default: nil
        }
    }
    private mutating func update(_ id: String, title: String? = nil, detail: String? = nil,
                                 status: AIChatSubagent.Status, restart: Bool = false) {
        if let index = agents.firstIndex(where: { $0.id == id }) {
            if agents[index].status != .running && status == .running && !restart { return }
            agents[index].status = status
            if let title, !title.isEmpty { agents[index].title = String(redact(title).prefix(500)) }
            if let detail { agents[index].detail = String(redact(detail).prefix(1000)) }
        } else if agents.count < 100 {
            agents.append(.init(id: id, title: String(redact(title ?? id).prefix(500)), detail: String(redact(detail ?? "").prefix(1000)), status: status))
        }
    }
    mutating func endTurn() {
        agents.removeAll { !background.contains($0.id) || $0.status != .running }
        let ids = Set(agents.map(\.id))
        background.formIntersection(ids); runs = runs.filter { ids.contains($0.key) }
        codexOrigins = codexOrigins.filter { ids.contains($0.key) }
        tools.removeAll(); codexCompletedItems.removeAll()
    }
    mutating func claude(_ message: [String: Any], busy: Bool, conversationID: String?) {
        if let session = message["session_id"] as? String, let conversationID, session != conversationID { return }
        guard message["ambient"] as? Bool != true else { return }
        if message["type"] as? String == "assistant", busy,
           message["parent_tool_use_id"] == nil || message["parent_tool_use_id"] is NSNull {
            for block in ((message["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []) {
                if ["Agent", "Task"].contains(block["name"] as? String ?? ""),
                   let id = identifier(block["id"]), tools.count < 256 { tools.insert(id) }
            }
        }
        if message["type"] as? String == "stream_event", busy,
           message["parent_tool_use_id"] == nil || message["parent_tool_use_id"] is NSNull,
           let event = message["event"] as? [String: Any], event["type"] as? String == "content_block_start",
           let block = event["content_block"] as? [String: Any], ["Agent", "Task"].contains(block["name"] as? String ?? ""),
           let id = identifier(block["id"]), tools.count < 256 { tools.insert(id) }
        guard message["type"] as? String == "system" else { return }
        let subtype = message["subtype"] as? String
        if subtype == "background_tasks_changed" {
            guard let tasks = message["tasks"] as? [[String: Any]], tasks.count <= 100 else { return }
            var live = Set<String>()
            for task in tasks where task["ambient"] as? Bool != true && ["local_agent", "remote_agent"].contains(task["task_type"] as? String ?? "") {
                guard let id = identifier(task["task_id"]) else { continue }
                live.insert(id)
                let run = identifier(task["run_id"])
                // Claude SDK documents run_id as lexicographically ordered by start time.
                if let old = runs[id], let run, run < old { continue }
                let restart = run != nil && run != runs[id]
                if let run { runs[id] = run }
                update(id, title: task["description"] as? String, status: .running, restart: restart)
            }
            for id in background.subtracting(live) where agents.contains(where: { $0.id == id && $0.status == .running }) {
                // Disappearance proves inactivity, not successful completion.
                update(id, status: .stopped)
            }
            background = live
            return
        }
        guard let id = identifier(message["task_id"]), busy || background.contains(id) else { return }
        let run = identifier(message["run_id"])
        if subtype == "task_started" {
            let knownTool = identifier(message["tool_use_id"]).map(tools.contains) ?? false
            guard ["local_agent", "remote_agent"].contains(message["task_type"] as? String ?? "") || knownTool else { return }
            if message["tool_use_id"] != nil && !knownTool && !background.contains(id) { return }
            if let old = runs[id], let run, run < old { return }
            let restart = run != nil && run != runs[id]
            if let run { runs[id] = run }
            if message["is_backgrounded"] as? Bool == true { background.insert(id) }
            update(id, title: message["description"] as? String, status: .running, restart: restart)
        } else {
            guard agents.contains(where: { $0.id == id }) else { return }
            if let run, let old = runs[id], run != old { return }
            switch subtype {
            case "task_progress":
                update(id, detail: message["summary"] as? String ?? message["last_tool_name"] as? String ?? message["description"] as? String, status: .running)
            case "task_updated":
                let patch = message["patch"] as? [String: Any] ?? [:]
                if patch["is_backgrounded"] as? Bool == true { background.insert(id) }
                if let status = state(patch["status"]) { update(id, detail: patch["error"] as? String, status: status) }
            case "task_notification":
                if let status = state(message["status"]), status != .running { update(id, detail: message["summary"] as? String, status: status) }
            default: break
            }
        }
    }
    mutating func codex(_ params: [String: Any], completed: Bool, busy: Bool, threadID: String?, turnID: String?) {
        guard let threadID, let origin = identifier(params["turnId"]), params["threadId"] as? String == threadID,
              let item = params["item"] as? [String: Any], let itemID = identifier(item["id"]),
              !codexCompletedItems.contains(itemID) else { return }
        let current = busy && origin == turnID
        let type = item["type"] as? String
        guard type == "subAgentActivity" || type == "collabAgentToolCall" else { return }
        if completed || type == "subAgentActivity" { guard codexCompletedItems.count < 2048 else { return }; codexCompletedItems.insert(itemID) }
        if type == "subAgentActivity" {
            guard let id = identifier(item["agentThreadId"]), id != threadID, current || codexOrigins[id] == origin else { return }
            switch item["kind"] as? String {
            case "started":
                guard current else { return }
                update(id, title: item["agentPath"] as? String, status: .running, restart: true)
                if agents.contains(where: { $0.id == id }) { codexOrigins[id] = origin; background.insert(id) }
            case "interacted": break // Sending a message does not prove the worker is running.
            case "completed":
                guard codexOrigins[id] == nil || codexOrigins[id] == origin else { return }
                update(id, title: item["agentPath"] as? String, status: .done)
            case "interrupted": update(id, title: item["agentPath"] as? String, status: .stopped)
            default: break
            }
        } else {
            guard current, item["senderThreadId"] as? String == threadID,
                  let ids = item["receiverThreadIds"] as? [String], ids.count <= 100,
                  let states = item["agentsStates"] as? [String: [String: Any]], states.count <= 100 else { return }
            let tool = item["tool"] as? String
            let restart = completed && item["status"] as? String == "completed" && ["resumeAgent", "followupTask"].contains(tool ?? "")
            for id in ids where identifier(id) != nil && id != threadID {
                if let value = states[id], let status = state(value["status"]) {
                    update(id, title: agents.contains(where: { $0.id == id }) ? nil : item["prompt"] as? String,
                           detail: value["message"] as? String, status: status, restart: restart)
                } else if completed, item["status"] as? String == "completed", tool == "spawnAgent" {
                    update(id, title: item["prompt"] as? String, status: .running)
                }
                if agents.contains(where: { $0.id == id && $0.status == .running }) {
                    if codexOrigins[id] == nil || restart { codexOrigins[id] = origin }
                    background.insert(id)
                }
            }
        }
    }
}

struct AIChatMessage: Identifiable, Codable, Equatable {
    enum Role: String, Codable { case user, assistant, thinking, tool }
    let id: String
    let role: Role
    var text: String
    var model: String = ""
    var isError = false
    /// Set only after a successful reply identifies this as turn progress.
    /// Keep the original role/text so expanding it restores the full content.
    var isIntermediate = false
    var isSteering = false
    var images: [AIChatImage] = []
    var files: [AIChatFile] = []
    var completedAt: String?
    var durationMs: Double?
    var completionStatus: String?
    var reasoningEffort: String?
    var reasoningEffortVerified = false
    var isVisibleInTranscript: Bool {
        (role != .tool || isError) && (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !images.isEmpty || !files.isEmpty)
    }

    private enum CodingKeys: String, CodingKey { case id, role, text, model, isError, isIntermediate, isSteering, images, files, completedAt, durationMs, completionStatus, reasoningEffort, reasoningEffortVerified }

    init(id: String, role: Role, text: String, model: String = "", isError: Bool = false,
         isIntermediate: Bool = false, isSteering: Bool = false, images: [AIChatImage] = [], files: [AIChatFile] = [], completedAt: String? = nil, durationMs: Double? = nil, completionStatus: String? = nil) {
        self.id = id; self.role = role; self.text = text; self.model = model
        self.isError = isError; self.isIntermediate = isIntermediate; self.isSteering = isSteering; self.images = images; self.files = files
        self.completedAt = completedAt; self.durationMs = durationMs; self.completionStatus = completionStatus
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        role = try values.decode(Role.self, forKey: .role)
        text = try values.decode(String.self, forKey: .text)
        model = try values.decodeIfPresent(String.self, forKey: .model) ?? ""
        isError = try values.decodeIfPresent(Bool.self, forKey: .isError) ?? false
        isIntermediate = try values.decodeIfPresent(Bool.self, forKey: .isIntermediate) ?? false
        isSteering = try values.decodeIfPresent(Bool.self, forKey: .isSteering) ?? false
        images = try values.decodeIfPresent([AIChatImage].self, forKey: .images) ?? []
        files = try values.decodeIfPresent([AIChatFile].self, forKey: .files) ?? []
        completedAt = try values.decodeIfPresent(String.self, forKey: .completedAt)
        completionStatus = try values.decodeIfPresent(String.self, forKey: .completionStatus)
        durationMs = try values.decodeIfPresent(Double.self, forKey: .durationMs)
        reasoningEffort = try values.decodeIfPresent(String.self, forKey: .reasoningEffort)
        reasoningEffortVerified = try values.decodeIfPresent(Bool.self, forKey: .reasoningEffortVerified) ?? false
        if let durationMs, !durationMs.isFinite || durationMs < 0 { self.durationMs = nil }
    }
}

/// What the tab strip and sidebar show for a chat. `finished` and
/// `interrupted` fire once when a turn ends.
enum AIChatActivity: Equatable {
    case running
    case needsInput
    case finished(success: Bool)
    case interrupted
}

struct AIChatApproval: Identifiable {
    let id: String
    let title: String
    var questions: [AIChatQuestion] = []
}

struct AIChatQuestion: Identifiable {
    let id: String
    let prompt: String
    let options: [String]
    var multiple = false
    var secret = false
}

/// Owns the conversation and draft independently of the selected model. Both
/// backends stay alive for the pane's lifetime; a model applies to the next turn.
@Observable
final class AIChatSession {
    let provider: AIProvider
    private(set) var directory: String { didSet { onStateChanged?() } }
    var input = "" { didSet { onStateChanged?() } }
    var draftImages: [AIChatImage] = [] { didSet { onStateChanged?() } }
    let imageStore: AIChatImageStore
    var draftFiles: [AIChatFile] = [] { didSet { onStateChanged?() } }
    let fileStore: AIChatFileStore
    var model: String {
        didSet { if model != oldValue { showsModelChangeHint = true; if !reasoningEffort.isEmpty && !reasoningEfforts(for: model).contains(reasoningEffort) { reasoningEffort = "" }; onStateChanged?() } }
    }
    var reasoningEffort = "" { didSet { onStateChanged?() } }
    private(set) var backendModels: [AIModelOption] = []
    var catalogModels: [AIModelOption] = [] { didSet { onStateChanged?() } }
    var supportedReasoningEfforts: [String] { reasoningEfforts(for: model) }
    func reasoningEfforts(for model: String) -> [String] {
        let models = AIModelOption.merge(catalog: catalogModels, backend: backendModels)
        if let option = models.first(where: { $0.id == model }) { return option.reasoningEfforts }
        let selected = model.isEmpty ? defaultModel ?? "" : model
        return models.first { $0.id == selected }?.reasoningEfforts ?? []
    }
    @ObservationIgnored private var turnReasoningEffort = ""
    @ObservationIgnored private var turnAppliedReasoningEffort: String?
    @ObservationIgnored private var turnEffortVerified = false
    @ObservationIgnored private var codexAppliedReasoningEffort: String?
    private(set) var showsModelChangeHint = false
    private(set) var messages: [AIChatMessage] = []
    private(set) var subagents: [AIChatSubagent] = []
    @ObservationIgnored private var subagentTracker = AIChatSubagentTracker()

    private var toolStations: [String: AIActivityStation] = [:]
    private(set) var activityRevision = 0
    @ObservationIgnored private var activeTools: [String: String] = [:]
    @ObservationIgnored private var completedTools = Set<String>()
    @ObservationIgnored private var previousCompletedTools = Set<String>()

    var hasLiveActivity: Bool {
        (isBusy && !turnWasInterrupted) || subagents.contains { $0.status == .running }
    }

    private var quotaWindows: [AIQuotaWindow] = []
    var accountQuota: [AIQuotaWindow] {
        let now = Int(Date().timeIntervalSince1970)
        return quotaWindows.filter { ($0.resetsAt ?? Int.max) > now }
    }

    private func recordQuota(minutes: Int, utilization: Any?, fullScale: Double, reset: Any?) {
        guard [300, 10080].contains(minutes) else { return }
        var windows = accountQuota.filter { $0.windowMinutes != minutes }
        // JSON booleans also bridge to NSNumber. Reject them as usage percentages.
        if let number = utilization as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
           (0...fullScale).contains(number.doubleValue) {
            let timestamp = reset as? NSNumber
            let seconds = timestamp.flatMap { Int(exactly: $0.doubleValue) }
            if reset == nil || reset is NSNull || (timestamp.map { CFGetTypeID($0) != CFBooleanGetTypeID() } == true
                && (seconds ?? 0) > Int(Date().timeIntervalSince1970) && (seconds ?? Int.max) <= 253402300799) {
                windows.append(.init(windowMinutes: minutes, remainingPercent: Int((100 - number.doubleValue / fullScale * 100).rounded()), resetsAt: seconds))
            }
        }
        windows.sort { $0.windowMinutes < $1.windowMinutes }
        if quotaWindows != windows { quotaWindows = windows; activityRevision += 1 }
    }

    var activityMap: [AIActivityStation] {
        guard hasLiveActivity else { return [] }
        var agents = AIActivityStation(station: "agents")
        for agent in subagents {
            switch agent.status {
            case .running: agents.active += 1
            case .done: agents.completed += 1
            case .failed, .stopped: agents.failed += 1
            }
        }
        var stations = toolStations
        if !subagents.isEmpty { stations["agents"] = agents }
        if isBusy && !stations.values.contains(where: { $0.active > 0 }) {
            stations["model", default: .init(station: "model")].active = 1
        }
        return AIActivityStation.displayOrder.compactMap { stations[$0] }.filter { $0.active + $0.completed + $0.failed > 0 }
    }

    /// A streamed start may be echoed in a full message. Some Codex items only
    /// arrive on completion. Count each ID once regardless of the event sequence.
    private func recordTool(id: String?, station: String?, finished: Bool, failed: Bool = false) {
        guard let id, !id.isEmpty, id.utf8.count <= 256, !completedTools.contains(id), !previousCompletedTools.contains(id),
              let station = finished ? (activeTools[id] ?? station) : station else { return }
        var row = toolStations[station] ?? .init(station: station)
        if finished {
            if activeTools.removeValue(forKey: id) != nil { row.active -= 1 }
            if completedTools.count >= 4096 {
                previousCompletedTools = completedTools
                completedTools.removeAll()
            }
            completedTools.insert(id)
            if failed { row.failed += 1 } else { row.completed += 1 }
        } else {
            if let previous = activeTools[id] {
                guard previous != station else { return }
                toolStations[previous]?.active -= 1
            } else if activeTools.count >= 1024 { return }
            activeTools[id] = station
            row.active += 1
        }
        toolStations[station] = row
        activityRevision += 1
    }

    private func recordHook(_ id: String?, finished: Bool, outcome: String?) {
        guard let id, !id.isEmpty else { return }
        recordTool(id: "hook:" + id, station: "hooks", finished: finished,
                   failed: ["error", "failed", "blocked", "stopped", "cancelled"].contains(outcome ?? ""))
    }

    private func recordUserActivity() {
        toolStations["you", default: .init(station: "you")].completed += 1
        activityRevision += 1
    }

    private func resetToolActivity() {
        activeTools.removeAll()
        completedTools.removeAll()
        previousCompletedTools.removeAll()
        if !toolStations.isEmpty { toolStations.removeAll(); activityRevision += 1 }
    }

    private func acceptsClaudeTool(_ message: [String: Any]) -> Bool {
        guard isBusy, !turnWasInterrupted, message["ambient"] as? Bool != true,
              message["parent_tool_use_id"] == nil || message["parent_tool_use_id"] is NSNull else { return false }
        if let session = message["session_id"] as? String, let conversationID { return session == conversationID }
        return true
    }

    private func publishSubagents() {
        let rows = subagentTracker.agents.map { AIChatSubagent(id: $0.id, title: sanitized($0.title), detail: sanitized($0.detail), status: $0.status) }
        if rows != subagents { subagents = rows; revision += 1 }
    }
    private func clearSubagents() { subagentTracker = AIChatSubagentTracker(); publishSubagents() }
    private(set) var approvals: [AIChatApproval] = [] {
        didSet {
            if isBusy, approvals.isEmpty != oldValue.isEmpty { onActivityChanged?(approvals.isEmpty ? .running : .needsInput) }
        }
    }
    private(set) var isReady = false
    private(set) var isBusy = false {
        didSet { if isBusy, !oldValue { onActivityChanged?(approvals.isEmpty ? .running : .needsInput) } }
    }
    private(set) var canInterrupt = false
    private(set) var revision = 0 { didSet { onStateChanged?() } }
    private(set) var conversationID: String? { didSet { onStateChanged?() } }
    var errorMessage: String?
    @ObservationIgnored var onFirstMessageSubmitted: ((String) -> Void)?
    @ObservationIgnored var onStateChanged: (() -> Void)?
    @ObservationIgnored var onTurnCompleted: ((UUID) -> Void)?
    @ObservationIgnored var onActivityChanged: ((AIChatActivity) -> Void)?
    /// The provider's own verdict for the turn being finished, when it sent one.
    @ObservationIgnored private var reportedTurnSuccess: Bool?
    @ObservationIgnored private var completionToken: UUID?
    @ObservationIgnored private var turnStartedAt: Date?
    @ObservationIgnored private var turnStartedUptime: TimeInterval?
    // A provider can start another turn after reporting a successful result.
    // Only a user submission owns a completion token and notification.
    @ObservationIgnored private var canResumeClaudeTurn = false
    @ObservationIgnored private var recentClaudeStarts: [String] = []
    @ObservationIgnored private var awaitingSubmittedTurn = false
    private var turnWasInterrupted = false
    @ObservationIgnored private var seenCompletionIDs: [String] = []
    var visibleMessages: [AIChatMessage] { messages.filter(\.isVisibleInTranscript) }
    var activeThinkingID: String? {
        guard isBusy, approvals.isEmpty else { return nil }
        let currentTurn = messages.suffix(from: min(thinkingStartIndex, messages.count))
        return currentTurn.last { $0.role == .thinking }?.id
    }
    var showsThinkingPlaceholder: Bool { isBusy && approvals.isEmpty && activeThinkingID == nil }
    var canChangeDirectory: Bool { !isBusy && approvals.isEmpty && responses.isEmpty }
    @ObservationIgnored private var isStartingForUpdate = false
    var hasPendingWorkForUpdate: Bool {
        isBusy || attachmentImports > 0 || steering != nil || remoteSubmission != nil || !responses.isEmpty || !approvals.isEmpty
            || pendingClaudeWrite || (isStartingForUpdate && errorMessage == nil)
    }
    private var attachmentImports = 0
    func beginAttachmentImport() -> Bool {
        guard !UpdateStore.shared.blocksNewMessages, !stopped else { return false }
        attachmentImports += 1
        return true
    }
    func endAttachmentImport() { attachmentImports = max(0, attachmentImports - 1) }
    private var taskToken: String?
    var steerToken: String? { isBusy ? taskToken : nil }
    var canSteer: Bool {
        !UpdateStore.shared.blocksNewMessages && isReady && isBusy && canInterrupt && !turnWasInterrupted
            && approvals.isEmpty && steering == nil && !steeringUncertain && remoteSubmission == nil
            && !pendingClaudeWrite && taskToken != nil && completionToken != nil
            && (provider == .claude ? claudeSupportsSteering : turnID != nil)
    }
    var canSend: Bool {
        !UpdateStore.shared.blocksNewMessages && isReady && (isBusy ? canSteer : steering == nil) && approvals.isEmpty &&
        (!input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !draftImages.isEmpty || !draftFiles.isEmpty)
    }
    var needsConfirmClose: Bool {
        isBusy || !input.isEmpty || !draftImages.isEmpty || !draftFiles.isEmpty || !messages.isEmpty || !approvals.isEmpty
    }
    @ObservationIgnored private let transport: any AIChatTransport
    @ObservationIgnored private var responses: [String: (Result<[String: Any], Error>) -> Void] = [:]
    @ObservationIgnored private var approvalReplies: [String: (Bool, [String: [String]]) throws -> Void] = [:]
    @ObservationIgnored private var configuration: AILaunchConfiguration?
    @ObservationIgnored private var reasoningSummaries: [String: [Int: String]] = [:]
    @ObservationIgnored private var reasoningContent: [String: [Int: String]] = [:]
    @ObservationIgnored private var turnID: String?
    @ObservationIgnored private var turnModel = ""
    private var thinkingStartIndex = 0
    private(set) var defaultModel: String?
    @ObservationIgnored private var appliedClaudeModel: String
    @ObservationIgnored private var claudeMessageID = ""
    @ObservationIgnored private var streamedClaudeIDs = Set<String>()
    @ObservationIgnored private var streamedClaudeThinkingIDs = Set<String>()
    @ObservationIgnored private var claudeThinkingCounts: [String: Int] = [:]
    @ObservationIgnored private var claudeStopReasons: [String: String] = [:]
    @ObservationIgnored private var codexMessagePhases: [String: String] = [:]
    @ObservationIgnored private var stopped = false
    @ObservationIgnored private var transportGeneration = UUID()
    @ObservationIgnored private var pendingClaudeWrite = false
    @ObservationIgnored private var deferredClaudeMessages: [[String: Any]] = []
    @ObservationIgnored private var deferredClaudeBytes = 0
    @ObservationIgnored private var hasSubmittedFirstMessage = false
    @ObservationIgnored private var secrets: [String] = []
    enum RemoteSubmissionResult: Equatable { case accepted, rejected, uncertain }
    @ObservationIgnored private var remoteSubmission: ((RemoteSubmissionResult) -> Void)?
    @ObservationIgnored private var remoteRequestWasWritten = false

    init(provider: AIProvider, model: String, directory: String,
         transport: any AIChatTransport = AIChatProcess(), restoring snapshot: AIChatSnapshot? = nil,
         imageStore: AIChatImageStore = .shared, fileStore: AIChatFileStore? = nil) {
        self.provider = provider
        self.model = model
        self.appliedClaudeModel = model
        self.directory = directory
        self.transport = transport
        self.imageStore = imageStore
        self.fileStore = fileStore ?? AIChatFileStore(directory: imageStore.directory.deletingLastPathComponent().appendingPathComponent("FileAttachments"))
        if let snapshot, snapshot.provider == provider {
            self.directory = snapshot.directory
            self.model = snapshot.model
            self.appliedClaudeModel = snapshot.model
            self.reasoningEffort = snapshot.reasoningEffort
            self.codexAppliedReasoningEffort = snapshot.codexAppliedReasoningEffort ?? (provider == .openai && !snapshot.reasoningEffort.isEmpty ? snapshot.reasoningEffort : nil)
            self.input = snapshot.input
            self.draftImages = snapshot.draftImages
            self.draftFiles = snapshot.draftFiles
            self.messages = snapshot.messages
            self.conversationID = snapshot.conversationID
            self.hasSubmittedFirstMessage = snapshot.messages.contains { $0.role == .user }
            self.thinkingStartIndex = snapshot.messages.count
        }
    }

    private var rawSnapshot: AIChatSnapshot {
        AIChatSnapshot(provider: provider, directory: directory, model: model, input: input,
                       messages: messages, conversationID: conversationID, draftImages: draftImages, draftFiles: draftFiles, reasoningEffort: reasoningEffort, codexAppliedReasoningEffort: codexAppliedReasoningEffort)
    }

    var snapshot: AIChatSnapshot { rawSnapshot.redacting(secrets) }

    func saveHistory(to store: AIChatHistoryStore, for terminalID: UUID, completion: @escaping (Bool) -> Void) {
        // Capture value types on the UI thread; redact and encode only the
        // coalesced checkpoint on the writer, not the whole transcript per token.
        store.save(rawSnapshot, for: terminalID, redacting: secrets, completion: completion)
    }

    func start(_ configuration: AILaunchConfiguration, resuming sessionID: String? = nil) {
        canResumeClaudeTurn = false
        recentClaudeStarts.removeAll()
        quotaWindows.removeAll()
        if let pending = steering { finishSteering(pending, result: pending.written ? .uncertain : .rejected) }
        completeRemoteSubmission(remoteRequestWasWritten ? .uncertain : .rejected)
        transportGeneration = UUID()
        clearPendingClaudeWrite()
        claudeSupportsSteering = false
        claudeInitialUserID = nil
        responses.removeAll()
        clearApprovals()
        finishTurn()
        var configuration = configuration
        // The pane's selection can differ from the shared connection default.
        if let index = configuration.arguments.firstIndex(of: "--model"), index + 1 < configuration.arguments.count {
            configuration.arguments.removeSubrange(index...index + 1)
        }
        if !model.isEmpty { configuration.arguments += ["--model", model] }
        appliedClaudeModel = model
        backendModels = []
        self.configuration = configuration
        isStartingForUpdate = true
        stopped = false
        isReady = false
        errorMessage = nil
        secrets = ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "THEALL_OPENAI_API_KEY"]
            .compactMap { configuration.environment[$0] }.filter { !$0.isEmpty }
        let sessionID = sessionID ?? conversationID
        guard sessionID != nil || messages.isEmpty else {
            errorMessage = L10n.string("ai.history.missingSession")
            return
        }
        transport.onMessage = { [weak self] in self?.receive($0) }
        transport.onExit = { [weak self] status in
            guard let self, !self.stopped else { return }
            if let pending = self.steering { self.finishSteering(pending, result: pending.written ? .uncertain : .rejected) }
            self.transportGeneration = UUID()
            self.quotaWindows.removeAll()
            self.clearPendingClaudeWrite()
            self.isReady = false
            self.isStartingForUpdate = false
            if self.errorMessage == nil, self.isBusy || status != 0 { self.errorMessage = L10n.string("ai.chat.exit", status) }
            self.completeRemoteSubmission(self.remoteRequestWasWritten ? .uncertain : .rejected)
            self.finishTurn()
            self.clearApprovals()
            let callbacks = Array(self.responses.values)
            self.responses.removeAll()
            callbacks.forEach { $0(.failure(ChatError.disconnected(self.errorMessage ?? L10n.string("ai.chat.exit", status)))) }
        }
        do {
            var launch = configuration.chatConfiguration(for: provider)
            if let sessionID, provider == .claude { launch.arguments += ["--resume", sessionID] }
            try transport.start(launch, directory: directory)
            switch provider {
            case .claude:
                try control("initialize", fields: ["hooks": NSNull()]) { [weak self] result in
                    self?.initialized(result)
                }
            case .openai:
                try rpc("initialize", params: ["clientInfo": ["name": "theall", "version": "0.1.0"]]) { [weak self] result in
                    guard let self else { return }
                    do {
                        _ = try result.get()
                        try self.transport.send(["method": "initialized"])
                        try self.rpc("model/list", params: ["limit": 100]) { [weak self] result in
                            guard let self else { return }
                            if case .success(let value) = result, let models = value["data"] as? [[String: Any]] {
                                self.backendModels = AIModelOption.cliModels(models, provider: .openai)
                                self.defaultModel = models.first { $0["isDefault"] as? Bool == true }?["model"] as? String
                            }
                            self.startCodexThread(resuming: sessionID)
                        }
                    } catch { self.fail(error) }
                }
            }
        } catch { fail(error) }
    }

    /// Claude's cwd is a process property; resume its saved session after a
    /// restart. Codex accepts cwd with each turn and keeps the existing thread.
    @discardableResult
    func changeDirectory(_ path: String) -> Bool {
        guard canChangeDirectory, var launch = configuration else { return false }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            errorMessage = L10n.string("ai.directory.unavailable")
            return false
        }
        if path == directory, isReady { return true }
        if provider == .claude {
            guard conversationID != nil || messages.isEmpty else { return false }
            transport.onMessage = nil
            transport.onExit = nil
            transport.stop()
            // A model chosen since launch also applies to the resumed process.
            if let index = launch.arguments.firstIndex(of: "--model"), index + 1 < launch.arguments.count {
                launch.arguments.removeSubrange(index...index + 1)
            }
            if !model.isEmpty { launch.arguments += ["--model", model] }
            appliedClaudeModel = model
            directory = path
            start(launch, resuming: conversationID)
        } else { directory = path }
        return true
    }

    private func startCodexThread(resuming sessionID: String?) {
        var params: [String: Any] = ["cwd": directory, "modelProvider": "theall",
            "approvalPolicy": "never", "sandbox": "danger-full-access"]
        if !model.isEmpty { params["model"] = model }
        if let sessionID { params["threadId"] = sessionID; params["excludeTurns"] = true }
        do {
            try rpc(sessionID == nil ? "thread/start" : "thread/resume", params: params) { [weak self] result in
                guard let self else { return }
                do {
                    let value = try result.get()
                    guard let thread = value["thread"] as? [String: Any], let id = thread["id"] as? String else {
                        throw ChatError.protocolError
                    }
                    guard sessionID == nil || sessionID == id else { throw ChatError.protocolError }
                    self.conversationID = id
                    if self.defaultModel == nil, self.model.isEmpty { self.defaultModel = value["model"] as? String }
                    self.isStartingForUpdate = false
                    self.isReady = true
                } catch { self.fail(error) }
            }
        } catch { fail(error) }
    }

    private func initialized(_ result: Result<[String: Any], Error>) {
        do {
            let value = try result.get()
            backendModels = AIModelOption.cliModels(value["models"] as? [[String: Any]] ?? [], provider: .claude)
            isStartingForUpdate = false
            isReady = true
        }
        catch { fail(error) }
    }

    func send() {
        guard remoteSubmission == nil else { return }
        if isBusy {
            _ = steer(input, images: draftImages, files: draftFiles, expectedToken: steerToken, clearsComposer: true)
            return
        }
        _ = submit(input, images: draftImages, files: draftFiles, clearsComposer: true)
    }

    /// Remote clients own their drafts. Never overwrite or clear the Mac composer.
    @discardableResult
    func sendRemote(_ prompt: String, images: [AIChatImage] = [], files: [AIChatFile] = [], model selectedModel: String? = nil, reasoningEffort selectedEffort: String? = nil,
                    stillAuthorized: @escaping () -> Bool = { true },
                    completion: @escaping (RemoteSubmissionResult) -> Void = { _ in }) -> Bool {
        guard !UpdateStore.shared.blocksNewMessages, stillAuthorized(), remoteSubmission == nil, isReady, !isBusy, steering == nil, approvals.isEmpty,
              (!prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !images.isEmpty || !files.isEmpty)
        else { completion(.rejected); return false }
        let nextModel = selectedModel ?? model
        let nextEffort = selectedEffort ?? (nextModel == model ? reasoningEffort : "")
        guard nextEffort.isEmpty || reasoningEfforts(for: nextModel).contains(nextEffort) else { completion(.rejected); return false }
        remoteRequestWasWritten = false
        remoteSubmission = completion
        if let selectedModel { model = selectedModel }
        reasoningEffort = nextEffort
        return submit(prompt, images: images, files: files, clearsComposer: false, stillAuthorized: stillAuthorized)
    }

    @discardableResult
    private func submit(_ prompt: String, images: [AIChatImage], files: [AIChatFile], clearsComposer: Bool,
                        stillAuthorized: @escaping () -> Bool = { true }) -> Bool {
        guard !UpdateStore.shared.blocksNewMessages, isReady, !isBusy, steering == nil, approvals.isEmpty,
              (!prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !images.isEmpty || !files.isEmpty) else { return false }
        guard reasoningEffort.isEmpty || supportedReasoningEfforts.contains(reasoningEffort) else {
            errorMessage = L10n.string("ai.effort.unsupported")
            completeRemoteSubmission(.rejected)
            return false
        }
        quotaWindows.removeAll { $0.resetsAt == nil }
        taskToken = UUID().uuidString
        turnModel = model
        turnReasoningEffort = reasoningEffort
        turnAppliedReasoningEffort = nil
        turnEffortVerified = false
        canResumeClaudeTurn = false
        awaitingSubmittedTurn = true
        turnWasInterrupted = false
        thinkingStartIndex = messages.count
        isBusy = true
        errorMessage = nil
        if !files.isEmpty {
            let generation = transportGeneration
            let store = fileStore
            Task { @MainActor [weak self] in
                do {
                    let providerPrompt = try await Task.detached(priority: .userInitiated) { try store.prompt(prompt, files: files) }.value
                    guard let self, !self.stopped, self.transportGeneration == generation else { return }
                    guard stillAuthorized() else { self.finishTurn(); self.completeRemoteSubmission(.rejected); return }
                    _ = self.writeSubmission(prompt, providerPrompt: providerPrompt, images: images, files: files,
                        clearsComposer: clearsComposer, stillAuthorized: stillAuthorized)
                } catch {
                    guard let self, !self.stopped, self.transportGeneration == generation else { return }
                    self.fail(error)
                }
            }
            return true
        }
        return writeSubmission(prompt, providerPrompt: prompt, images: images, files: [], clearsComposer: clearsComposer, stillAuthorized: stillAuthorized)
    }

    private func writeSubmission(_ prompt: String, providerPrompt: String, images: [AIChatImage], files: [AIChatFile],
                                 clearsComposer: Bool, stillAuthorized: @escaping () -> Bool) -> Bool {
        do {
            guard images.count <= AIChatImageStore.maximumCount else { throw AIChatImageStore.ImageError.tooMany }
            guard Set(images.map(\.id)).count == images.count else { throw AIChatImageStore.ImageError.invalid }
            // Validate every attachment before any provider request. A missing
            // restored file must not silently send a text-only question.
            var imageInputs: [[String: Any]] = []
            for image in images {
                let data = try imageStore.data(for: image)
                if provider == .claude {
                    imageInputs.append(["type": "image", "source": ["type": "base64", "media_type": image.mimeType,
                        "data": data.base64EncodedString()]])
                } else {
                    imageInputs.append(["type": "localImage", "path": try imageStore.url(for: image).path])
                }
            }
            if provider == .claude {
                // Wait for model acknowledgement before submitting the prompt.
                // A selection made during this turn is left for the next send.
                let selected = turnModel
                let generation = transportGeneration
                let submit: (Result<[String: Any], Error>) -> Void = { [weak self] result in
                    guard let self, !self.stopped, self.transportGeneration == generation else { return }
                    do {
                        _ = try result.get()
                        self.appliedClaudeModel = selected
                        guard stillAuthorized() else {
                            self.finishTurn()
                            self.completeRemoteSubmission(.rejected)
                            return
                        }
                        var content = imageInputs
                        if !providerPrompt.isEmpty { content.insert(["type": "text", "text": providerPrompt], at: 0) }
                        let payload: Any = images.isEmpty ? providerPrompt as Any : content
                        // The pipe writer is asynchronous for large photos. Do
                        // not clear the draft or acknowledge a remote send until
                        // the complete JSON line has actually been written.
                        if self.remoteSubmission != nil { self.remoteRequestWasWritten = true }
                        self.pendingClaudeWrite = true
                        do {
                            let messageID = UUID().uuidString
                            self.claudeInitialUserID = messageID
                            try self.transport.send(["type": "user", "uuid": messageID, "message": ["role": "user", "content": payload],
                                "parent_tool_use_id": NSNull(), "session_id": self.conversationID ?? ""]) { [weak self] result in
                                guard let self, !self.stopped, self.transportGeneration == generation else { return }
                                switch result {
                                case .success:
                                    self.didSubmit(prompt, images: images, files: files, clearsComposer: clearsComposer)
                                    self.canInterrupt = true
                                    self.completeRemoteSubmission(.accepted)
                                    let queued = self.deferredClaudeMessages
                                    self.clearPendingClaudeWrite()
                                    queued.forEach { self.receive($0) }
                                case .failure(let error):
                                    self.clearPendingClaudeWrite()
                                    self.fail(error)
                                }
                            }
                        } catch {
                            // A synchronous throw means no write was queued.
                            self.remoteRequestWasWritten = false
                            self.clearPendingClaudeWrite()
                            throw error
                        }
                    } catch { self.fail(error) }
                }
                let selectedEffort = turnReasoningEffort
                let applyEffort: (Result<[String: Any], Error>) -> Void = { [weak self] result in
                    guard let self, !self.stopped, self.transportGeneration == generation else { return }
                    do {
                        _ = try result.get()
                        self.appliedClaudeModel = selected
                        guard stillAuthorized() else { self.finishTurn(); self.completeRemoteSubmission(.rejected); return }
                        // A successful settings ACK can still be clamped by
                        // policy. Reapply (including Default) and read back
                        // every turn; cached choices cannot prove live state.
                        try self.control("apply_flag_settings", fields: ["settings": ["effortLevel": selectedEffort.isEmpty ? NSNull() : selectedEffort as Any]]) { [weak self] result in
                            guard let self, !self.stopped, self.transportGeneration == generation else { return }
                            do {
                                _ = try result.get()
                                try self.control("get_settings") { [weak self] result in
                                    guard let self, !self.stopped, self.transportGeneration == generation else { return }
                                    do {
                                        let value = try result.get()
                                        guard let applied = value["applied"] as? [String: Any],
                                              applied["effort"] is String || applied["effort"] is NSNull else {
                                            throw ChatError.backend(L10n.string("ai.effort.unverified"))
                                        }
                                        let actual = applied["effort"] as? String
                                        if let actual, actual.isEmpty || actual.count > 32 || !actual.utf8.allSatisfy({ (97...122).contains($0) }) {
                                            throw ChatError.backend(L10n.string("ai.effort.unverified"))
                                        }
                                        if !selectedEffort.isEmpty, actual != selectedEffort {
                                            throw ChatError.backend(L10n.string("ai.effort.mismatch", selectedEffort, actual ?? L10n.string("ai.effort.unknown")))
                                        }
                                        self.turnAppliedReasoningEffort = actual
                                        self.turnEffortVerified = actual != nil
                                        submit(.success([:]))
                                    } catch {
                                        if case ChatError.backend(let message) = error,
                                           message.contains("Unsupported control request"), message.contains("get_settings") {
                                            submit(.failure(ChatError.backend(L10n.string("ai.effort.unverified"))))
                                        } else { submit(.failure(error)) }
                                    }
                                }
                            } catch { submit(.failure(error)) }
                        }
                    } catch { self.fail(error) }
                }
                if appliedClaudeModel == selected { applyEffort(.success([:])) }
                else { try control("set_model", fields: ["model": selected.isEmpty ? NSNull() : selected as Any], completion: applyEffort) }
            } else {
                guard stillAuthorized() else {
                    finishTurn()
                    completeRemoteSubmission(.rejected)
                    return false
                }
                guard let conversationID else { throw ChatError.protocolError }
                var content = imageInputs
                if !providerPrompt.isEmpty { content.insert(["type": "text", "text": providerPrompt], at: 0) }
                var params: [String: Any] = ["threadId": conversationID, "cwd": directory,
                    "approvalPolicy": "never", "sandboxPolicy": ["type": "dangerFullAccess"],
                    "input": content]
                guard let selected = turnModel.isEmpty ? defaultModel : turnModel else { throw ChatError.protocolError }
                params["model"] = selected
                let selectedEffort = turnReasoningEffort
                if selectedEffort.isEmpty {
                    let fallback = AIModelOption.merge(catalog: catalogModels, backend: backendModels).first { $0.id == selected }?.defaultReasoningEffort
                    guard fallback != nil || codexAppliedReasoningEffort == nil else { throw ChatError.backend(L10n.string("ai.effort.unsupported")) }
                    params["effort"] = fallback.map { $0 as Any } ?? NSNull()
                } else { params["effort"] = selectedEffort }
                // A lost acknowledgement can still mean the backend accepted
                // the override. Preserve it independently of the editable draft.
                let previousCodexEffort = codexAppliedReasoningEffort
                turnAppliedReasoningEffort = params["effort"] as? String
                if let applied = params["effort"] as? String {
                    codexAppliedReasoningEffort = applied
                    onStateChanged?()
                }
                var written = false
                var rejectedSynchronously = false
                try rpc("turn/start", params: params) { [weak self] result in
                    guard let self else { return }
                    do {
                        let value = try result.get()
                        self.turnID = (value["turn"] as? [String: Any])?["id"] as? String
                        self.acceptSubmittedTurn()
                        if let applied = params["effort"] as? String { self.codexAppliedReasoningEffort = applied }
                        self.onStateChanged?()
                        self.notifyFirstMessage(prompt, images: images, files: files)
                        self.completeRemoteSubmission(.accepted)
                    } catch {
                        if case ChatError.backend = error {
                            self.codexAppliedReasoningEffort = previousCodexEffort
                            self.onStateChanged?()
                        }
                        rejectedSynchronously = !written
                        if clearsComposer, written {
                            if self.input.isEmpty { self.input = prompt }
                            let present = Set(self.draftImages.map(\.id))
                            self.draftImages = images.filter { !present.contains($0.id) } + self.draftImages
                            let presentFiles = Set(self.draftFiles.map(\.id))
                            self.draftFiles = files.filter { !presentFiles.contains($0.id) } + self.draftFiles
                        }
                        self.fail(error)
                    }
                }
                guard !rejectedSynchronously else { return false }
                written = true
                // A written Codex request may execute even if its reply is lost.
                // A synchronous reply may already have completed the submission.
                if remoteSubmission != nil { remoteRequestWasWritten = true }
                didSubmit(prompt, images: images, files: files, clearsComposer: clearsComposer)
            }
        } catch { fail(error); return false }
        return true
    }

    private func didSubmit(_ prompt: String, images: [AIChatImage], files: [AIChatFile], clearsComposer: Bool) {
        subagentTracker.endTurn(); publishSubagents()
        recordUserActivity()
        if provider == .claude { acceptSubmittedTurn() }
        messages.append(AIChatMessage(id: UUID().uuidString, role: .user, text: prompt, images: images, files: files))
        if clearsComposer, input == prompt { input = "" }
        if clearsComposer {
            let submitted = Set(images.map(\.id))
            draftImages.removeAll { submitted.contains($0.id) }
            let submittedFiles = Set(files.map(\.id))
            draftFiles.removeAll { submittedFiles.contains($0.id) }
        }
        // A newer selection made while waiting for the previous model's
        // acknowledgement still applies to the following message.
        if model == turnModel { showsModelChangeHint = false }
        revision += 1
        if provider == .claude { notifyFirstMessage(prompt, images: images, files: files) }
    }

    private final class SteeringSubmission {
        let id = UUID().uuidString
        let token: String
        let prompt: String
        let images: [AIChatImage]
        let files: [AIChatFile]
        let clearsComposer: Bool
        let completion: (RemoteSubmissionResult) -> Void
        var written = false
        init(token: String, prompt: String, images: [AIChatImage], files: [AIChatFile], clearsComposer: Bool,
             completion: @escaping (RemoteSubmissionResult) -> Void) {
            self.token = token; self.prompt = prompt; self.images = images; self.files = files
            self.clearsComposer = clearsComposer; self.completion = completion
        }
    }
    private var steering: SteeringSubmission?
    private var steeringUncertain = false
    private var claudeSupportsSteering = false
    @ObservationIgnored private var claudeInitialUserID: String?
    private var claudeSteerIDs = Set<String>()
    @ObservationIgnored private var deferredSteerResults: [[String: Any]] = []
    @ObservationIgnored private var claudeResultBeforeSteer: [String: Any]?

    @discardableResult
    func steerRemote(_ prompt: String, images: [AIChatImage] = [], files: [AIChatFile] = [], expectedToken: String,
                     stillAuthorized: @escaping () -> Bool = { true },
                     completion: @escaping (RemoteSubmissionResult) -> Void = { _ in }) -> Bool {
        steer(prompt, images: images, files: files, expectedToken: expectedToken, clearsComposer: false,
              stillAuthorized: stillAuthorized, completion: completion)
    }

    @discardableResult
    private func steer(_ prompt: String, images: [AIChatImage], files: [AIChatFile], expectedToken: String?,
                       clearsComposer: Bool, stillAuthorized: @escaping () -> Bool = { true },
                       completion: @escaping (RemoteSubmissionResult) -> Void = { _ in }) -> Bool {
        guard canSteer, let expectedToken, expectedToken == taskToken, stillAuthorized(),
              !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !images.isEmpty || !files.isEmpty
        else { completion(.rejected); return false }
        let pending = SteeringSubmission(token: expectedToken, prompt: prompt, images: images, files: files,
                                         clearsComposer: clearsComposer, completion: completion)
        steering = pending
        errorMessage = nil
        let generation = transportGeneration
        let imageStore = imageStore, fileStore = fileStore, provider = provider
        Task { @MainActor [weak self] in
            do {
                let content = try await Task.detached(priority: .userInitiated) {
                    let text = try fileStore.prompt(prompt, files: files)
                    guard images.count <= AIChatImageStore.maximumCount, Set(images.map(\.id)).count == images.count
                    else { throw AIChatImageStore.ImageError.invalid }
                    var content: [[String: Any]] = text.isEmpty ? [] : [["type": "text", "text": text]]
                    for image in images {
                        let data = try imageStore.data(for: image)
                        if provider == .claude {
                            content.append(["type": "image", "source": ["type": "base64", "media_type": image.mimeType, "data": data.base64EncodedString()]])
                        } else { content.append(["type": "localImage", "path": try imageStore.url(for: image).path]) }
                    }
                    return content
                }.value
                guard let self, self.steering === pending, self.transportGeneration == generation else { return }
                guard !self.stopped, self.isReady, self.isBusy, self.taskToken == pending.token,
                      !self.turnWasInterrupted, self.approvals.isEmpty, stillAuthorized(), !UpdateStore.shared.blocksNewMessages
                else { self.finishSteering(pending, result: .rejected, error: ChatError.backend(L10n.string("ai.chat.steerUnavailable"))); return }
                self.messages.append(AIChatMessage(id: pending.id, role: .user, text: prompt, isSteering: true, images: images, files: files))
                self.revision += 1
                pending.written = true
                if provider == .claude {
                    self.claudeSteerIDs.insert(pending.id)
                    // Default priority lets Claude consume the new input at its
                    // next safe boundary without interrupting an executing tool.
                    try self.transport.send(["type": "user", "uuid": pending.id,
                        "message": ["role": "user", "content": content], "parent_tool_use_id": NSNull(),
                        "session_id": self.conversationID ?? ""]) { [weak self] result in
                        guard let self, self.steering === pending else { return }
                        if case .failure(let error) = result { self.finishSteering(pending, result: .uncertain, error: error) }
                    }
                } else {
                    guard let threadID = self.conversationID, let turnID = self.turnID else { throw ChatError.protocolError }
                    self.responses[pending.id] = { [weak self] result in
                        guard let self, self.steering === pending else { return }
                        switch result {
                        case .success(let value):
                            guard value["turnId"] as? String == turnID else {
                                self.finishSteering(pending, result: .uncertain, error: ChatError.protocolError); return
                            }
                            self.finishSteering(pending, result: .accepted)
                        case .failure(let error):
                            let outcome: RemoteSubmissionResult
                            if case ChatError.backend = error { outcome = .rejected } else { outcome = .uncertain }
                            self.finishSteering(pending, result: outcome, error: error)
                        }
                    }
                    try self.transport.send(["id": pending.id, "method": "turn/steer", "params": [
                        "threadId": threadID, "expectedTurnId": turnID, "input": content, "clientUserMessageId": pending.id]])
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
                    guard let self, self.steering === pending else { return }
                    self.finishSteering(pending, result: .uncertain, error: ChatError.timeout)
                }
            } catch {
                guard let self, self.steering === pending else { return }
                // Synchronous transport throws prove that no write was queued.
                self.finishSteering(pending, result: .rejected, error: error)
            }
        }
        return true
    }

    private func finishSteering(_ pending: SteeringSubmission, result: RemoteSubmissionResult, error: Error? = nil) {
        guard steering === pending else { return }
        steering = nil
        responses[pending.id] = nil
        if result == .accepted && isBusy && !turnWasInterrupted { recordUserActivity() }
        if result == .rejected {
            messages.removeAll { $0.id == pending.id }
            claudeSteerIDs.remove(pending.id)
        } else if result == .accepted, pending.clearsComposer {
            if input == pending.prompt { input = "" }
            let images = Set(pending.images.map(\.id)), files = Set(pending.files.map(\.id))
            draftImages.removeAll { images.contains($0.id) }
            draftFiles.removeAll { files.contains($0.id) }
        }
        if result == .uncertain { steeringUncertain = true }
        if let error { errorMessage = result == .uncertain ? L10n.string("ai.chat.steerUncertain") : sanitized(error.localizedDescription) }
        revision += 1
        pending.completion(result)
        let results = deferredSteerResults
        deferredSteerResults.removeAll()
        results.forEach { receive($0) }
    }

    private func notifyFirstMessage(_ prompt: String, images: [AIChatImage] = [], files: [AIChatFile] = []) {
        guard !hasSubmittedFirstMessage else { return }
        hasSubmittedFirstMessage = true
        onFirstMessageSubmitted?(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (!images.isEmpty || !files.isEmpty)
            ? (files.first?.name ?? L10n.string("ai.images.defaultName")) : prompt)
    }

    @discardableResult
    func interrupt() -> Bool {
        guard isBusy, canInterrupt else { return false }
        turnWasInterrupted = true
        resetToolActivity()
        clearSubagents()
        do {
            if provider == .claude {
                try control("interrupt", fields: ["cancel_queued": true]) { [weak self] result in
                    guard let self else { return }
                    switch result {
                    case .success(let value):
                        for id in value["cancelled"] as? [String] ?? [] { self.cancelClaudeSteer(id) }
                    case .failure(let error): self.errorMessage = error.localizedDescription
                    }
                }
            } else if let conversationID, let turnID {
                try rpc("turn/interrupt", params: ["threadId": conversationID, "turnId": turnID]) { [weak self] result in
                    if case .failure(let error) = result { self?.errorMessage = error.localizedDescription }
                }
            }
            return true
        } catch { errorMessage = sanitized(error.localizedDescription); return false }
    }

    @discardableResult
    func answerApproval(_ id: String, allow: Bool, answers: [String: [String]] = [:]) -> Bool {
        guard let reply = approvalReplies[id] else { return false }
        do {
            try reply(allow, answers)
            approvalReplies[id] = nil
            approvals.removeAll { $0.id == id }
            return true
        } catch { errorMessage = error.localizedDescription; return false }
    }

    func stop() {
        quotaWindows.removeAll()
        if isBusy { turnWasInterrupted = true }
        if let pending = steering { finishSteering(pending, result: pending.written ? .uncertain : .rejected) }
        transportGeneration = UUID()
        clearPendingClaudeWrite()
        completeRemoteSubmission(remoteRequestWasWritten ? .uncertain : .rejected)
        onStateChanged?()
        stopped = true
        clearSubagents()
        transport.onMessage = nil
        transport.onExit = nil
        transport.stop()
        responses.removeAll()
        isReady = false
        finishTurn()
        clearApprovals()
        let saved = snapshot
        messages = saved.messages
        input = saved.input
        draftImages = saved.draftImages
        draftFiles = saved.draftFiles
        secrets.removeAll()
        isStartingForUpdate = false
        configuration = nil
    }

    deinit { if let pending = steering { pending.completion(pending.written ? .uncertain : .rejected) }; remoteSubmission?(remoteRequestWasWritten ? .uncertain : .rejected); transport.stop() }

    private func completeRemoteSubmission(_ result: RemoteSubmissionResult) {
        let completion = remoteSubmission
        remoteSubmission = nil
        remoteRequestWasWritten = false
        completion?(result)
    }

    private func control(_ subtype: String, fields: [String: Any] = [:],
                         completion: @escaping (Result<[String: Any], Error>) -> Void) throws {
        let id = UUID().uuidString
        responses[id] = completion
        timeout(id)
        do { try transport.send(["type": "control_request", "request_id": id,
                                 "request": fields.merging(["subtype": subtype]) { _, new in new }]) }
        catch { responses[id] = nil; throw error }
    }

    private func rpc(_ method: String, params: [String: Any],
                     completion: @escaping (Result<[String: Any], Error>) -> Void) throws {
        let id = UUID().uuidString
        responses[id] = completion
        timeout(id)
        do { try transport.send(["id": id, "method": method, "params": params]) }
        catch { responses[id] = nil; throw error }
    }

    private func fail(_ error: Error) {
        // Only an explicit backend rejection proves a written turn did not start.
        let rejected: Bool
        if case ChatError.backend = error { rejected = true } else { rejected = false }
        completeRemoteSubmission(remoteRequestWasWritten && !rejected ? .uncertain : .rejected)
        errorMessage = sanitized(error.localizedDescription)
        finishTurn()
    }

    private func timeout(_ id: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            guard let self, let callback = self.responses.removeValue(forKey: id) else { return }
            self.isReady = false
            self.isStartingForUpdate = false
            callback(.failure(ChatError.timeout))
        }
    }

    private func acceptSubmittedTurn() {
        guard awaitingSubmittedTurn, completionToken == nil else { return }
        completionToken = UUID()
        turnStartedAt = Date()
        turnStartedUptime = ProcessInfo.processInfo.systemUptime
    }

    private func recordTurnCompletion(success: Bool) {
        guard let token = completionToken, turnStartedAt != nil else { return }
        completionToken = nil // Consume before callbacks; duplicate results cannot notify.
        if let index = currentTurnRange.last(where: { messages[$0].role == .assistant && !messages[$0].isIntermediate && messages[$0].isVisibleInTranscript }) {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            messages[index].completedAt = formatter.string(from: Date())
            messages[index].completionStatus = turnWasInterrupted ? "interrupted" : (success ? "completed" : "failed")
            messages[index].durationMs = max(0, (ProcessInfo.processInfo.systemUptime - (turnStartedUptime ?? ProcessInfo.processInfo.systemUptime)) * 1000)
            messages[index].reasoningEffort = turnAppliedReasoningEffort
            messages[index].reasoningEffortVerified = turnEffortVerified
            revision += 1
        }
        if success, !turnWasInterrupted { onTurnCompleted?(token) }
    }

    private func finishTurn() {
        let wasBusy = isBusy
        let success = reportedTurnSuccess ?? (errorMessage == nil)
        reportedTurnSuccess = nil
        defer {
            if wasBusy { onActivityChanged?(turnWasInterrupted ? .interrupted : .finished(success: success)) }
        }
        if !isReady || turnWasInterrupted { clearSubagents() } else { subagentTracker.endTurn(); publishSubagents() }
        recordTurnCompletion(success: false)
        completionToken = nil; turnStartedAt = nil; turnStartedUptime = nil; awaitingSubmittedTurn = false
        isBusy = false
        resetToolActivity()
        canInterrupt = false
        turnID = nil
        taskToken = nil
        steeringUncertain = false
        claudeSteerIDs.removeAll()
        claudeResultBeforeSteer = nil
        if let pending = steering, !pending.written { finishSteering(pending, result: .rejected) }
    }

    private var currentTurnRange: Range<Int> {
        min(thinkingStartIndex, messages.count)..<messages.count
    }

    /// A provider with no message phases may split its final answer into several
    /// messages. Preserve every answer block after the last tool, not just the last.
    private func trailingAnswerIDs() -> Set<String> {
        let range = currentTurnRange
        let lastTool = range.last { messages[$0].role == .tool }
        let start = lastTool.map { $0 + 1 } ?? range.lowerBound
        return Set(messages[start..<range.upperBound].filter {
            $0.role == .assistant && $0.isVisibleInTranscript && !$0.isError
                && codexMessagePhases[$0.id] != "commentary"
                && claudeStopReasons[$0.id] != "tool_use"
                && claudeStopReasons[$0.id] != "max_tokens"
        }.map(\.id))
    }

    private func collapseCompletedProgress(finalAnswerIDs: Set<String>) {
        // With no actual answer, leave progress visible (for example a stopped
        // or tool-only turn). Errors never disappear into collapsed progress.
        guard !finalAnswerIDs.isEmpty else { return }
        var changed = false
        for index in currentTurnRange {
            let message = messages[index]
            if !message.isError, message.role == .thinking
                || (message.role == .assistant && !finalAnswerIDs.contains(message.id)) {
                if !messages[index].isIntermediate {
                    messages[index].isIntermediate = true
                    changed = true
                }
            }
        }
        if changed { revision += 1 }
    }

    private func completeClaudeReply(_ result: [String: Any]) -> Bool {
        guard result["is_error"] as? Bool != true,
              (result["subtype"] as? String).map({ $0 == "success" }) ?? true,
              (result["terminal_reason"] as? String).map({ $0 == "completed" }) ?? true,
              (result["stop_reason"] as? String).map({ ["end_turn", "stop_sequence"].contains($0) }) ?? true
        else { return false }
        var finalIDs = trailingAnswerIDs()
        if let text = result["result"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let finalText = sanitized(text)
            let answers = messages[currentTurnRange].filter { $0.role == .assistant }
            if let match = answers.last(where: { $0.text.trimmingCharacters(in: .whitespacesAndNewlines)
                == finalText.trimmingCharacters(in: .whitespacesAndNewlines) }) {
                finalIDs = [match.id]
            } else if answers.filter({ finalIDs.contains($0.id) }).map(\.text).joined(separator: "\n\n") != finalText {
                // A result can contain the complete answer after missing or
                // incomplete streaming events. Keep that canonical reply visible.
                let partial = answers.last.flatMap { answer in
                    finalIDs.contains(answer.id) && !answer.text.isEmpty && finalText.hasPrefix(answer.text) ? answer.id : nil
                }
                let id = partial ?? "result-\(UUID().uuidString)"
                updateMessage(id: id, role: .assistant, text: finalText)
                finalIDs = [id]
            }
        }
        collapseCompletedProgress(finalAnswerIDs: finalIDs)
        return true
    }

    private func completeCodexReply(_ turn: [String: Any]) -> Bool {
        guard turn["status"] as? String == "completed", turn["error"] == nil || turn["error"] is NSNull else { return false }
        // The completed turn may supply phases/text omitted from earlier events.
        for item in turn["items"] as? [[String: Any]] ?? [] {
            receiveCodex(["method": "item/completed", "params": ["item": item]])
        }
        let answers = messages[currentTurnRange].filter { $0.role == .assistant && $0.isVisibleInTranscript && !$0.isError }
        let explicitAnswers = Set(answers.filter { ["partial_answer", "final_answer"].contains(codexMessagePhases[$0.id] ?? "") }.map(\.id))
        collapseCompletedProgress(finalAnswerIDs: explicitAnswers.union(trailingAnswerIDs()))
        return true
    }

    private func clearApprovals() {
        approvals.removeAll()
        approvalReplies.removeAll()
    }

    private func sanitized(_ value: String) -> String {
        secrets.reduce(value) { $0.replacingOccurrences(of: $1, with: "••••") }
    }

    private func updateMessage(id: String, role: AIChatMessage.Role, text: String, append: Bool = false, isError: Bool = false) {
        if let index = messages.firstIndex(where: { $0.id == id }) {
            messages[index].text = append ? messages[index].text + text : text
            messages[index].isError = messages[index].isError || isError
        } else {
            messages.append(AIChatMessage(id: id, role: role, text: text, model: role == .assistant ? turnModel : "", isError: isError))
        }
        revision += 1
    }

    private func detail(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "" }
        return sanitized(text)
    }

    private func updateReasoning(_ id: String) {
        let summaries = reasoningSummaries[id] ?? [:]
        let source = summaries.values.contains(where: { !$0.isEmpty }) ? summaries : reasoningContent[id] ?? [:]
        let text = source.keys.sorted().compactMap { source[$0] }.joined(separator: "\n\n")
        if !text.isEmpty { updateMessage(id: "thinking-" + id, role: .thinking, text: text) }
    }

    private func receive(_ message: [String: Any]) {
        guard !stopped else { return }
        if provider == .claude, pendingClaudeWrite {
            // stdout can race the main-thread write completion. Preserve user
            // -> assistant ordering even when the CLI answers immediately.
            deferredClaudeBytes += (try? JSONSerialization.data(withJSONObject: message).count) ?? 0
            guard deferredClaudeBytes <= 16 * 1024 * 1024, deferredClaudeMessages.count < 1024 else {
                transportGeneration = UUID()
                clearPendingClaudeWrite()
                transport.stop()
                isReady = false
                fail(ChatError.protocolError)
                return
            }
            deferredClaudeMessages.append(message)
            return
        }
        if let pending = steering, pending.written,
           (provider == .claude && message["type"] as? String == "result"
            || provider == .openai && message["method"] as? String == "turn/completed") {
            if provider == .claude,
               ((message["user_message_uuids"] as? [String] ?? []).contains(pending.id) || message["user_message_uuid"] as? String == pending.id) {
                finishSteering(pending, result: .accepted)
            } else if deferredSteerResults.count < 16 {
                deferredSteerResults.append(message)
                return
            } else { finishSteering(pending, result: .uncertain, error: ChatError.protocolError) }
        }
        if provider == .claude { receiveClaude(message) } else { receiveCodex(message) }
    }

    private func clearPendingClaudeWrite() {
        pendingClaudeWrite = false
        deferredClaudeMessages.removeAll()
        deferredClaudeBytes = 0
    }

    private func cancelClaudeSteer(_ id: String) {
        guard claudeSteerIDs.remove(id) != nil else { return }
        if let pending = steering, pending.id == id {
            finishSteering(pending, result: .rejected,
                error: turnWasInterrupted ? nil : ChatError.backend(L10n.string("ai.chat.steerUnavailable")))
        } else {
            if let index = messages.firstIndex(where: { $0.id == id }) { messages[index].isError = true; revision += 1 }
            if !turnWasInterrupted { errorMessage = L10n.string("ai.chat.steerUnavailable") }
        }
        if claudeSteerIDs.isEmpty, let result = claudeResultBeforeSteer {
            claudeResultBeforeSteer = nil
            reportedTurnSuccess = completeClaudeReply(result)
            finishTurn()
        }
    }

    private func noteClaudeMessageStart(_ id: String?, session: String?) {
        guard let id, !id.isEmpty, id.utf8.count <= 256, !recentClaudeStarts.contains(id) else { return }
        recentClaudeStarts.append(id)
        if recentClaudeStarts.count > 256 { recentClaudeStarts.removeFirst() }
        guard canResumeClaudeTurn, isReady, !isBusy, !turnWasInterrupted,
              let session, session == conversationID else { return }
        canResumeClaudeTurn = false
        thinkingStartIndex = messages.count
        isBusy = true
        canInterrupt = true
    }

    private func receiveClaude(_ message: [String: Any]) {
        let kind = message["type"] as? String
        if ["assistant", "stream_event", "result"].contains(kind ?? ""),
           message["parent_tool_use_id"] == nil || message["parent_tool_use_id"] is NSNull {
            let session = message["session_id"] as? String
            guard message["ambient"] as? Bool != true, message["isReplay"] as? Bool != true,
                  message["is_replay"] as? Bool != true,
                  session == nil || conversationID == nil || session == conversationID else { return }
            if kind == "assistant" {
                noteClaudeMessageStart((message["message"] as? [String: Any])?["id"] as? String, session: session)
            } else if let event = message["event"] as? [String: Any], event["type"] as? String == "message_start" {
                noteClaudeMessageStart((event["message"] as? [String: Any])?["id"] as? String, session: session)
            }
        }
        subagentTracker.redact = { [weak self] in self?.sanitized($0) ?? "" }
        if !turnWasInterrupted { subagentTracker.claude(message, busy: isBusy, conversationID: conversationID); publishSubagents() }
        // Child output belongs to its worker, not the parent's response stream.
        if ["assistant", "stream_event", "result"].contains(message["type"] as? String ?? ""),
           message["parent_tool_use_id"] != nil && !(message["parent_tool_use_id"] is NSNull) { return }
        switch message["type"] as? String {
        case "rate_limit_event":
            guard acceptsClaudeTool(message), let info = message["rate_limit_info"] as? [String: Any],
                  let type = info["rateLimitType"] as? String,
                  let minutes = ["five_hour": 300, "seven_day": 10080][type] else { return }
            recordQuota(minutes: minutes, utilization: info["utilization"], fullScale: 1, reset: info["resetsAt"])
        case "command_lifecycle":
            guard let id = message["command_uuid"] as? String, let state = message["state"] as? String else { return }
            if id == claudeInitialUserID, ["queued", "started", "completed"].contains(state) { claudeSupportsSteering = true }
            guard claudeSteerIDs.contains(id) else { return }
            if ["queued", "started", "completed"].contains(state), let pending = steering, pending.id == id {
                finishSteering(pending, result: .accepted)
            }
            if ["refused", "cancelled", "discarded"].contains(state) {
                cancelClaudeSteer(id)
            }
        case "control_response":
            guard let response = message["response"] as? [String: Any], let id = response["request_id"] as? String,
                  let callback = responses.removeValue(forKey: id) else { return }
            if response["subtype"] as? String == "error" {
                callback(.failure(ChatError.backend(sanitized(response["error"] as? String ?? "Unknown error"))))
            } else { callback(.success(response["response"] as? [String: Any] ?? [:])) }
        case "control_request":
            guard let id = message["request_id"] as? String, let request = message["request"] as? [String: Any] else { return }
            guard request["subtype"] as? String == "can_use_tool" else {
                try? transport.send(["type": "control_response", "response": ["subtype": "error", "request_id": id,
                    "error": "Unsupported control request"]]); return
            }
            let input = request["input"] as? [String: Any] ?? [:]
            // The user chose automatic execution for every tool. Questions
            // still need an actual answer; tool inputs are forwarded unchanged.
            guard request["tool_name"] as? String == "AskUserQuestion" else {
                do {
                    try transport.send(["type": "control_response", "response": ["subtype": "success", "request_id": id,
                        "response": ["behavior": "allow", "updatedInput": input]]])
                } catch { fail(error) }
                return
            }
            let questions = (input["questions"] as? [[String: Any]] ?? []).compactMap { item -> AIChatQuestion? in
                guard let question = item["question"] as? String else { return nil }
                return AIChatQuestion(id: question, prompt: question,
                    options: (item["options"] as? [[String: Any]] ?? []).compactMap { $0["label"] as? String },
                    multiple: item["multiSelect"] as? Bool ?? false)
            }
            guard !questions.isEmpty else {
                try? transport.send(["type": "control_response", "response": ["subtype": "error", "request_id": id,
                    "error": "Question request contains no supported questions"]])
                errorMessage = L10n.string("ai.chat.unsupported", "AskUserQuestion")
                return
            }
            approvals.append(AIChatApproval(id: id, title: L10n.string("ai.chat.question"), questions: questions))
            approvalReplies[id] = { [weak self] allow, answers in
                var updated = input
                if !questions.isEmpty { updated["answers"] = answers.mapValues { $0.joined(separator: ", ") } }
                let decision: [String: Any] = allow ? ["behavior": "allow", "updatedInput": updated]
                    : ["behavior": "deny", "message": "The user declined this operation."]
                try self?.transport.send(["type": "control_response", "response": ["subtype": "success",
                    "request_id": id, "response": decision]])
            }
        case "control_cancel_request":
            if let id = message["request_id"] as? String {
                approvals.removeAll { $0.id == id }; approvalReplies[id] = nil
            }
        case "system":
            if let subtype = message["subtype"] as? String, ["hook_started", "hook_response"].contains(subtype), acceptsClaudeTool(message) {
                recordHook(message["hook_id"] as? String, finished: subtype == "hook_response", outcome: message["outcome"] as? String)
            }
            if let resolved = message["model"] as? String { defaultModel = resolved }
            if message["subtype"] == nil || message["subtype"] as? String == "init", let id = message["session_id"] as? String { conversationID = id }
        case "stream_event":
            guard let event = message["event"] as? [String: Any] else { return }
            if event["type"] as? String == "content_block_start", let block = event["content_block"] as? [String: Any],
               block["type"] as? String == "tool_use", acceptsClaudeTool(message) {
                recordTool(id: block["id"] as? String, station: AIActivityStation.claudeTool(block["name"] as? String, input: block["input"] as? [String: Any]), finished: false)
            }
            if let id = message["api_message_id"] as? String { claudeMessageID = id }
            if event["type"] as? String == "message_start", let body = event["message"] as? [String: Any], let id = body["id"] as? String {
                claudeMessageID = id
            }
            if let delta = event["delta"] as? [String: Any], let reason = delta["stop_reason"] as? String {
                claudeStopReasons[claudeMessageID] = reason
            }
            if let delta = event["delta"] as? [String: Any], delta["type"] as? String == "text_delta", let text = delta["text"] as? String {
                streamedClaudeIDs.insert(claudeMessageID)
                updateMessage(id: claudeMessageID, role: .assistant, text: text, append: true)
            }
            let thoughtID = "thinking-\(claudeMessageID)-\(event["index"] as? Int ?? 0)"
            if let delta = event["delta"] as? [String: Any], delta["type"] as? String == "thinking_delta",
               let thought = delta["thinking"] as? String, !thought.isEmpty {
                streamedClaudeThinkingIDs.insert(claudeMessageID)
                updateMessage(id: thoughtID, role: .thinking, text: thought, append: true)
            } else if event["type"] as? String == "content_block_start",
                      let block = event["content_block"] as? [String: Any], block["type"] as? String == "thinking",
                      let thought = block["thinking"] as? String, !thought.isEmpty {
                streamedClaudeThinkingIDs.insert(claudeMessageID)
                updateMessage(id: thoughtID, role: .thinking, text: thought)
            }
        case "assistant":
            guard let body = message["message"] as? [String: Any], let id = body["id"] as? String,
                  let blocks = body["content"] as? [[String: Any]] else { return }
            if let reason = body["stop_reason"] as? String { claudeStopReasons[id] = reason }
            let text = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: "\n")
            for block in blocks {
                if block["type"] as? String == "text", !text.isEmpty, !streamedClaudeIDs.contains(id) {
                    updateMessage(id: id, role: .assistant, text: text)
                } else if block["type"] as? String == "thinking", let thought = block["thinking"] as? String,
                          !thought.isEmpty, !streamedClaudeThinkingIDs.contains(id) {
                    // Claude sends each completed block as a separate assistant
                    // message, so its array index is not the stream block index.
                    let index = claudeThinkingCounts[id, default: 0]
                    claudeThinkingCounts[id] = index + 1
                    updateMessage(id: "thinking-\(id)-\(index)", role: .thinking, text: thought)
                } else if block["type"] as? String == "tool_use", let toolID = block["id"] as? String {
                    if acceptsClaudeTool(message) {
                        recordTool(id: toolID, station: AIActivityStation.claudeTool(block["name"] as? String, input: block["input"] as? [String: Any]), finished: false)
                    }
                    updateMessage(id: toolID, role: .tool, text: (block["name"] as? String ?? "Tool") + "\n" + detail(block["input"] ?? [:]))
                }
            }
        case "user":
            if let pending = steering, message["uuid"] as? String == pending.id {
                finishSteering(pending, result: .accepted)
            }
            guard let body = message["message"] as? [String: Any], let blocks = body["content"] as? [[String: Any]] else { return }
            for block in blocks where block["type"] as? String == "tool_result" {
                guard let id = block["tool_use_id"] as? String else { continue }
                if acceptsClaudeTool(message) {
                    recordTool(id: id, station: nil, finished: true, failed: block["is_error"] as? Bool == true)
                }
                let output = block["content"] as? String ?? detail(block["content"] ?? [])
                let prefix = block["is_error"] as? Bool == true ? L10n.string("ai.chat.toolFailed") : L10n.string("ai.chat.toolResult")
                updateMessage(id: id, role: .tool, text: "\n" + prefix + "\n" + sanitized(String(output.suffix(30_000))), append: true,
                              isError: block["is_error"] as? Bool == true)
            }
        case "result":
            guard message["parent_tool_use_id"] == nil || message["parent_tool_use_id"] is NSNull else { return }
            if let resultID = message["uuid"] as? String {
                guard !seenCompletionIDs.contains(resultID) else { return }
                seenCompletionIDs.append(resultID)
                if seenCompletionIDs.count > 256 { seenCompletionIDs.removeFirst() }
            }
            if let id = message["session_id"] as? String { conversationID = id }
            if message["is_error"] as? Bool == true {
                errorMessage = sanitized((message["errors"] as? [String])?.joined(separator: "\n")
                    ?? message["result"] as? String ?? L10n.string("ai.chat.failed"))
            }
            guard isBusy else { return }
            let consumed = Set((message["user_message_uuids"] as? [String] ?? []) + [message["user_message_uuid"] as? String].compactMap { $0 })
            claudeSteerIDs.subtract(consumed)
            if !claudeSteerIDs.isEmpty {
                claudeResultBeforeSteer = message
                return
            }
            claudeResultBeforeSteer = nil
            let success = completeClaudeReply(message)
            canResumeClaudeTurn = success && !turnWasInterrupted
            reportedTurnSuccess = success
            recordTurnCompletion(success: success)
            finishTurn()
        default: break
        }
    }

    private func receiveCodex(_ message: [String: Any]) {
        if let id = message["id"] as? String, let callback = responses.removeValue(forKey: id) {
            if let error = message["error"] as? [String: Any] {
                callback(.failure(ChatError.backend(sanitized(error["message"] as? String ?? "Unknown error"))))
            } else { callback(.success(message["result"] as? [String: Any] ?? [:])) }
            return
        }
        guard let method = message["method"] as? String else { return }
        let params = message["params"] as? [String: Any] ?? [:]
        if let requestID = message["id"] {
            let id = String(describing: requestID)
            if ["item/commandExecution/requestApproval", "item/fileChange/requestApproval"].contains(method) {
                do { try transport.send(["id": requestID, "result": ["decision": "accept"]]) }
                catch { fail(error) }
            } else if ["execCommandApproval", "applyPatchApproval"].contains(method) {
                do { try transport.send(["id": requestID, "result": ["decision": "approved"]]) }
                catch { fail(error) }
            } else if method == "item/tool/requestUserInput" {
                let questions = (params["questions"] as? [[String: Any]] ?? []).compactMap { item -> AIChatQuestion? in
                    guard let id = item["id"] as? String, let question = item["question"] as? String else { return nil }
                    return AIChatQuestion(id: id, prompt: question,
                        options: (item["options"] as? [[String: Any]] ?? []).compactMap { $0["label"] as? String },
                        secret: item["isSecret"] as? Bool ?? false)
                }
                guard !questions.isEmpty else {
                    try? transport.send(["id": requestID, "error": ["code": -32602,
                        "message": "Question request contains no supported questions"]])
                    errorMessage = L10n.string("ai.chat.unsupported", method)
                    return
                }
                approvals.append(AIChatApproval(id: id, title: L10n.string("ai.chat.question"), questions: questions))
                approvalReplies[id] = { [weak self] allow, answers in
                    let values = allow ? answers : [:]
                    try self?.transport.send(["id": requestID, "result": ["answers": values.mapValues { ["answers": $0] }]])
                }
            } else if method == "item/permissions/requestApproval" {
                do {
                    try transport.send(["id": requestID, "result": ["permissions": params["permissions"] as? [String: Any] ?? [:], "scope": "turn"]])
                } catch { fail(error) }
            } else {
                // Explicit rejection prevents unsupported server tools hanging
                // forever or being silently approved by the host.
                try? transport.send(["id": requestID, "error": ["code": -32601, "message": "Unsupported request: " + method]])
                errorMessage = L10n.string("ai.chat.unsupported", method)
            }
            return
        }
        // Child agents can ask for approval through this same private server.
        // Only their transcript/turn notifications are excluded from this chat;
        // requests and their resolution must always be answered/cleared.
        if method != "serverRequest/resolved", let thread = params["threadId"] as? String,
           let conversationID, thread != conversationID { return }
        switch method {
        case "account/rateLimits/updated":
            // The isolated app-server forwards upstream rate-limit events during the turn.
            // account/rateLimits/read instead uses Codex login credentials.
            guard isReady, isBusy, !turnWasInterrupted,
                  let limits = params["rateLimits"] as? [String: Any],
                  limits["limitId"] == nil || limits["limitId"] is NSNull || limits["limitId"] as? String == "codex" else { return }
            for field in ["primary", "secondary"] {
                guard let window = limits[field] as? [String: Any], let minutes = window["windowDurationMins"] as? Int else { continue }
                recordQuota(minutes: minutes, utilization: window["usedPercent"], fullScale: 100, reset: window["resetsAt"])
            }
        case "hook/started", "hook/completed":
            guard isBusy, !turnWasInterrupted, let conversationID, let turnID,
                  params["threadId"] as? String == conversationID, params["turnId"] as? String == turnID,
                  let run = params["run"] as? [String: Any] else { return }
            recordHook(run["id"] as? String, finished: method == "hook/completed", outcome: run["status"] as? String)
        case "turn/started":
            guard isReady, let id = (params["turn"] as? [String: Any])?["id"] as? String,
                  !id.isEmpty, !seenCompletionIDs.contains(id), turnID == nil || turnID == id else { return }
            acceptSubmittedTurn()
            if !isBusy { thinkingStartIndex = messages.count }
            turnID = id
            isBusy = true
            canInterrupt = true
        case "serverRequest/resolved":
            if let requestID = params["requestId"] {
                let id = String(describing: requestID)
                approvals.removeAll { $0.id == id }
                approvalReplies[id] = nil
            }
        case "item/agentMessage/delta":
            if let id = params["itemId"] as? String, let delta = params["delta"] as? String {
                updateMessage(id: id, role: .assistant, text: delta, append: true)
            }
        case "item/reasoning/summaryTextDelta", "item/reasoning/textDelta":
            if let id = params["itemId"] as? String, let delta = params["delta"] as? String {
                if method == "item/reasoning/summaryTextDelta" {
                    reasoningSummaries[id, default: [:]][params["summaryIndex"] as? Int ?? 0, default: ""] += delta
                } else {
                    reasoningContent[id, default: [:]][params["contentIndex"] as? Int ?? 0, default: ""] += delta
                }
                updateReasoning(id)
            }
        case "item/started", "item/completed":
            if isReady, !turnWasInterrupted {
                subagentTracker.redact = { [weak self] in self?.sanitized($0) ?? "" }
                subagentTracker.codex(params, completed: method == "item/completed", busy: isBusy, threadID: conversationID, turnID: turnID)
                publishSubagents()
            }
            guard let item = params["item"] as? [String: Any], let id = item["id"] as? String else { return }
            if isReady, isBusy, !turnWasInterrupted, let conversationID, let turnID,
               params["threadId"] as? String == conversationID, params["turnId"] as? String == turnID,
               let station = AIActivityStation.codexItem(item) {
                let failed = ["failed", "declined", "cancelled"].contains(item["status"] as? String ?? "")
                    || (item["exitCode"] as? Int).map { $0 != 0 } == true || item["success"] as? Bool == false
                    || item["error"] is [String: Any] || (item["result"] as? [String: Any])?["isError"] as? Bool == true
                recordTool(id: id, station: station, finished: method == "item/completed", failed: failed)
            }
            switch item["type"] as? String {
            case "agentMessage":
                if let phase = item["phase"] as? String, ["commentary", "partial_answer", "final_answer"].contains(phase) {
                    codexMessagePhases[id] = phase
                }
                if let text = item["text"] as? String, !text.isEmpty { updateMessage(id: id, role: .assistant, text: text) }
            case "reasoning":
                if let summary = item["summary"] as? [String], !summary.isEmpty {
                    reasoningSummaries[id] = Dictionary(uniqueKeysWithValues: summary.enumerated().map { ($0.offset, $0.element) })
                }
                if let content = item["content"] as? [String], !content.isEmpty {
                    reasoningContent[id] = Dictionary(uniqueKeysWithValues: content.enumerated().map { ($0.offset, $0.element) })
                }
                updateReasoning(id)
            case "commandExecution":
                let command = item["command"] as? String ?? ""
                let output = String((item["aggregatedOutput"] as? String ?? "").suffix(30_000))
                updateMessage(id: id, role: .tool, text: sanitized(command + (output.isEmpty ? "" : "\n" + output)),
                    isError: item["status"] as? String == "failed" || (item["exitCode"] as? Int).map { $0 != 0 } == true)
            case "fileChange", "mcpToolCall":
                updateMessage(id: id, role: .tool, text: detail(item), isError: item["status"] as? String == "failed")
            default: break
            }
        case "turn/completed":
            if let completedID = (params["turn"] as? [String: Any])?["id"] as? String {
                guard !seenCompletionIDs.contains(completedID), turnID == nil || turnID == completedID else { return }
                seenCompletionIDs.append(completedID)
                if seenCompletionIDs.count > 256 { seenCompletionIDs.removeFirst() }
            }
            if let turn = params["turn"] as? [String: Any], let error = turn["error"] as? [String: Any] {
                errorMessage = sanitized(error["message"] as? String ?? L10n.string("ai.chat.failed"))
            }
            if let turn = params["turn"] as? [String: Any] {
                if turn["status"] as? String == "interrupted" { turnWasInterrupted = true }
                let success = completeCodexReply(turn)
                reportedTurnSuccess = success
                recordTurnCompletion(success: success)
            }
            finishTurn()
        case "error":
            if let error = params["error"] as? [String: Any] {
                errorMessage = sanitized(error["message"] as? String ?? L10n.string("ai.chat.failed"))
            }
        default: break
        }
    }

    enum ChatError: LocalizedError {
        case protocolError, backend(String), timeout, disconnected(String)
        var errorDescription: String? {
            switch self {
            case .protocolError: return L10n.string("ai.chat.failed")
            case .backend(let message), .disconnected(let message): return message
            case .timeout: return L10n.string("ai.chat.timeout")
            }
        }
    }
}
