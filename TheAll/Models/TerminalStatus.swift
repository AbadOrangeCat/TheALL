import Foundation

/// Per-terminal running state driven by agent hooks (Claude / Codex / OpenCode).
///
/// - `neverRan`: freshly opened terminal, no agent turn has started yet.
/// - `running`: agent turn is in progress. `detail` optionally carries a live
///   label ("Edit Foo.swift") captured by the tool-start hook.
/// - `idle`: agent has returned control (turn ended, awaiting next prompt).
/// - `needsInput`: agent is awaiting user confirmation before proceeding.
/// - `success` / `failed`: last agent turn's result. `exitCode` is a sentinel —
///   `0` means clean turn, `1` means at least one tool errored. `agent` records
///   which source produced the state; `summary` carries an optional human-readable
///   last-assistant message for tooltip display.
///
/// State is in-memory only. App restart → all terminals reset to `.neverRan`.
enum TerminalStatus: Equatable {
    case neverRan
    case running(startedAt: Date, detail: String? = nil)
    case idle(since: Date)
    case needsInput(since: Date)
    case success(exitCode: Int32, duration: TimeInterval, finishedAt: Date,
                 agent: HookMessage.Agent, summary: String? = nil,
                 readAt: Date? = nil)
    case failed(exitCode: Int32, duration: TimeInterval, finishedAt: Date,
                agent: HookMessage.Agent, summary: String? = nil,
                readAt: Date? = nil)

    /// Aggregation priority (higher wins):
    /// needsInput > running > failed > success > idle > neverRan, where any
    /// unread finished turn outranks every read one. A tab whose other pane
    /// already showed a failure must still surface a pane that just finished.
    fileprivate var priority: Int {
        switch self {
        case .needsInput: return 7
        case .running:    return 6
        case .failed:     return isRead ? 3 : 5
        case .success:    return isRead ? 2 : 4
        case .idle:       return 1
        case .neverRan:   return 0
        }
    }

    /// Reduce a bag of per-terminal statuses into one aggregate status using the
    /// priority above. Ties keep the first member (e.g. two successes → the
    /// first). Empty input → `.neverRan`.
    static func aggregate(_ statuses: [TerminalStatus]) -> TerminalStatus {
        statuses.reduce(TerminalStatus.neverRan) { current, next in
            next.priority > current.priority ? next : current
        }
    }

    /// Worth an icon even when the hook-based indicators are switched off:
    /// a running turn, a pending question, or a finished turn nobody has seen.
    var wantsAttention: Bool {
        switch self {
        case .running, .needsInput: return true
        case .success, .failed:     return !isRead
        case .neverRan, .idle:      return false
        }
    }

    /// Whether a tab or sidebar row shows this status. `hookIndicators` is the
    /// Settings → Agents gate for terminal hooks; AI chats always report
    /// attention states.
    func showsIndicator(hookIndicators: Bool) -> Bool {
        hookIndicators || wantsAttention
    }

    /// True when this status has been acknowledged by the user.
    /// Only `.success` / `.failed` can be read; other kinds return `false`.
    var isRead: Bool {
        switch self {
        case .success(_, _, _, _, _, let readAt): return readAt != nil
        case .failed(_, _, _, _, _, let readAt):  return readAt != nil
        default: return false
        }
    }
}
