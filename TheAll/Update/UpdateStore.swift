import Foundation
import Observation

/// Single source of truth for the auto-update flow. Lives in the SwiftUI
/// environment; read by SidebarView (red-dot visibility) and
/// UpdateSectionView (main UI). All mutations happen here — the Sparkle
/// UserDriver calls these helpers; views never mutate state directly.
@Observable
final class UpdateStore {
    /// Current app version (MARKETING_VERSION). Read once at init.
    let currentVersion: String

    /// Current UI state.
    var state: UpdateState = .idle

    /// Whether the sidebar should show the red pulsing dot.
    /// True while an update exists in the pipeline: `.updateAvailable`,
    /// `.downloading`, or `.readyToInstall`. The `.readyToInstall` window
    /// is transient (milliseconds before Sparkle relaunches) — included so
    /// the dot stays lit continuously rather than flicker off during handoff.
    var hasUpdate: Bool {
        switch state {
        case .updateAvailable, .downloading, .readyToInstall:
            return true
        default:
            return false
        }
    }

    init(currentVersion: String) {
        self.currentVersion = currentVersion
    }

    func setChecking() { state = .checking }

    func setUpToDate() { state = .upToDate }

    func setUpdateAvailable(version: String, releaseNotes: String?) {
        state = .updateAvailable(version: version, releaseNotes: releaseNotes)
    }

    func setDownloading(progress: Double) {
        state = .downloading(progress: progress)
    }

    func setReadyToInstall() { state = .readyToInstall }

    func setError(_ message: String) { state = .error(message) }

    func resetToIdle() { state = .idle }
}
