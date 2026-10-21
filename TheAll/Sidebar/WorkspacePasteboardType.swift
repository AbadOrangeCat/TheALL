import AppKit

extension NSPasteboard.PasteboardType {
    /// theall sidebar workspace 拖拽类型。仅用于 WorkspaceListView 自身内部重排——
    /// 不跨进程、不支持外部拖入。与 .theAllTab 命名对称。
    static let theAllWorkspace = NSPasteboard.PasteboardType("com.theall.workspace")
}
