import XCTest
@testable import TheAll

final class NotificationNamesTests: XCTestCase {
    func testNewMenuNotificationRawValues() {
        XCTAssertEqual(Notification.Name.theAllFocusNextPane.rawValue, "theall.focusNextPane")
        XCTAssertEqual(Notification.Name.theAllFocusPrevPane.rawValue, "theall.focusPrevPane")
        XCTAssertEqual(Notification.Name.theAllSelectWorkspaceAtIndex.rawValue,
                       "theall.selectWorkspaceAtIndex")
        // 注：theAllCopy / theAllPaste / theAllSelectAll 已删除——⌘C/⌘V/⌘A 不再走通知，
        // 改由 TheAllApp 的 pasteboard CommandGroup 通过 NSApp.sendAction(:to:nil)
        // 沿 responder chain 派发标准 selector，命中 NSText（rename / 设置 TextField）
        // 或终端 GhosttyTerminalView 的同名 selector。
    }
}
