import Foundation
import Observation

@Observable
final class WorkspaceMetadata {
    var gitBranch: String?
    var prStatus: String?          // "open", "merged", "closed", nil = unknown
    var workingDirectory: String?
    var latestNotification: String?
}
