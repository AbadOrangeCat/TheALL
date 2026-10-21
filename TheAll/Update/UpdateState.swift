import Foundation

/// Drives the entire UpdateSectionView UI and the sidebar red-dot visibility.
/// Single source of truth for the user-visible auto-update flow.
enum UpdateState: Equatable {
    /// Default. Shows current version + "Check for Updates" button.
    case idle

    /// Network request in flight.
    case checking

    /// Confirmed no update. Auto-transitions back to `.idle` after 3 s.
    case upToDate

    /// Update found and ready to download.
    /// - version: e.g. "0.2.0"
    /// - releaseNotes: plain text body from appcast `<description>` CDATA; may be nil.
    case updateAvailable(version: String, releaseNotes: String?)

    /// Download in progress.
    /// - progress: 0.0 ... 1.0
    case downloading(progress: Double)

    /// Transient (milliseconds) between download-complete and app relaunch.
    case readyToInstall

    /// Any failure. Shows red card + Retry.
    case error(String)
}
