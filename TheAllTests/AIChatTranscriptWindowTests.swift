import XCTest
@testable import TheAll

/// Long conversations show their newest page of rows, like the phone app, so
/// memory stays bounded by the page size rather than the whole history.
final class AIChatTranscriptWindowTests: XCTestCase {
    private final class Transport: AIChatTransport {
        var onMessage: (([String: Any]) -> Void)?
        var onExit: ((Int32) -> Void)?
        func start(_ configuration: AILaunchConfiguration, directory: String) throws {}
        func send(_ message: [String: Any]) throws {}
        func stop() {}
    }

    /// `rounds` questions, each followed by `steps` replies and one answer (one row each).
    private func messages(rounds: Int, steps: Int) -> [AIChatMessage] {
        (0..<rounds).flatMap { round -> [AIChatMessage] in
            [AIChatMessage(id: "q\(round)", role: .user, text: "Question \(round)")]
                + (0..<steps).map { AIChatMessage(id: "t\(round)-\($0)", role: .assistant, text: "Step \($0)") }
                + [AIChatMessage(id: "a\(round)", role: .assistant, text: "Answer \(round)")]
        }
    }

    func testShortConversationsShowEverything() {
        XCTAssertEqual(AIChatTranscriptWindow.latestStart(messages(rounds: 3, steps: 10)), 0)
        XCTAssertEqual(AIChatTranscriptWindow.latestStart([]), 0)
    }

    func testLatestPageStartsAtTheQuestionOpeningItsRound() {
        let all = messages(rounds: 30, steps: 18) // 20 rows per round, 600 rows
        let start = AIChatTranscriptWindow.latestStart(all)
        XCTAssertEqual(all[start].role, .user)
        XCTAssertGreaterThanOrEqual(all.count - start, AIChatTranscriptWindow.page)
        XCTAssertLessThanOrEqual(all.count - start, AIChatTranscriptWindow.page * 3 / 2)
        let earlier = AIChatTranscriptWindow.earlierStart(all, before: start)
        XCTAssertEqual(all[earlier].role, .user)
        XCTAssertLessThan(earlier, start)
        XCTAssertEqual(AIChatTranscriptWindow.earlierStart(all, before: 50), 0)
    }

    func testOneHugeRoundIsStillCutToAPage() {
        let all = messages(rounds: 1, steps: 2_000)
        XCTAssertEqual(AIChatTranscriptWindow.latestStart(all), all.count - AIChatTranscriptWindow.page)
    }

    @MainActor func testPaneHostsOnlyTheNewestPageAndLoadsEarlierOnes() throws {
        let all = messages(rounds: 20, steps: 18) // 400 rows
        let snapshot = AIChatSnapshot(provider: .claude, directory: "/tmp", model: "", input: "",
                                      messages: all, conversationID: "transcript-window-fixture")
        let chat = AIChatSession(provider: .claude, model: "", directory: "/tmp", transport: Transport(), restoring: snapshot)
        let pane = AIChatNativePane(session: AITerminalSession(), chat: chat, onFocus: {}, onEdit: {})
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 600), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = pane
        defer { window.close() }
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        func find<T: NSView>(_ type: T.Type, in view: NSView, where match: (T) -> Bool = { _ in true }) -> T? {
            if let view = view as? T, match(view) { return view }
            for child in view.subviews { if let found = find(type, in: child, where: match) { return found } }
            return nil
        }
        let earlier = try XCTUnwrap(find(NSButton.self, in: pane) { $0.accessibilityIdentifier() == "chat-show-earlier" })
        let stack = try XCTUnwrap(earlier.superview as? NSStackView)
        let firstPage = stack.arrangedSubviews.count - 1
        XCTAssertEqual(firstPage, all.count - AIChatTranscriptWindow.latestStart(all))
        XCTAssertTrue(earlier.title.contains("\(all.count - firstPage)"))
        earlier.performClick(nil)
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        XCTAssertGreaterThan(stack.arrangedSubviews.count - 1, firstPage)
        while stack.arrangedSubviews.contains(earlier) { earlier.performClick(nil) }
        XCTAssertEqual(stack.arrangedSubviews.count, all.count, "Every row is reachable")
    }
}

/// Thinking and progress fold into one row per run of steps; only the display changes.
final class AIChatTranscriptLayoutTests: XCTestCase {
    private func message(_ id: String, _ role: AIChatMessage.Role, _ text: String = "text",
                         intermediate: Bool = false, error: Bool = false) -> AIChatMessage {
        var message = AIChatMessage(id: id, role: role, text: text, isError: error)
        message.isIntermediate = intermediate
        return message
    }

    func testFinishedTurnFoldsItsStepsIntoOneRowBeforeTheAnswer() {
        let messages = [message("q", .user), message("n1", .assistant, intermediate: true), message("th", .thinking),
                        message("n2", .assistant, intermediate: true), message("a", .assistant), message("q2", .user)]
        let items = AIChatTranscriptLayout.items(messages, notes: [])
        XCTAssertEqual(items.map(\.id), ["q", "steps:n1", "a", "q2"])
        guard case .steps(_, let steps) = items[1] else { return XCTFail("Expected a step row") }
        XCTAssertEqual(steps.map(\.id), ["n1", "th", "n2"], "Every step stays available, in order")
    }

    func testRunningTurnFoldsNotesThatAlreadyHaveLaterSteps() {
        let all = [message("q0", .user), message("old", .assistant), message("q", .user),
                   message("n1", .assistant), message("tool", .tool), message("th", .thinking), message("live", .assistant)]
        let notes = AIChatTranscriptLayout.runningNotes(all, isBusy: true)
        XCTAssertEqual(notes, ["n1"], "The newest reply may be the answer; earlier turns are untouched")
        XCTAssertEqual(AIChatTranscriptLayout.runningNotes(all, isBusy: false), [])
        let visible = all.filter(\.isVisibleInTranscript)
        XCTAssertEqual(AIChatTranscriptLayout.items(visible, notes: notes).map(\.id), ["q0", "old", "q", "steps:n1", "live"])
    }

    func testErrorsAndSteeringStayVisible() {
        let messages = [message("q", .user), message("th", .thinking), message("err", .assistant, error: true),
                        message("tool", .tool, error: true), message("th2", .thinking)]
        XCTAssertEqual(AIChatTranscriptLayout.items(messages, notes: []).map(\.id), ["q", "steps:th", "err", "tool", "steps:th2"])
        var steer = message("steer", .user)
        steer.isSteering = true
        let all = [message("q", .user), message("n1", .assistant), steer, message("n2", .assistant)]
        XCTAssertEqual(AIChatTranscriptLayout.runningNotes(all, isBusy: true), ["n1"])
    }

    func testPreviewIsTheNewestLineWithoutMarkdown() {
        XCTAssertEqual(AIChatTranscriptLayout.preview(message("p", .thinking, "First idea\n\n## Checking **tests**\n")), "Checking tests")
        XCTAssertEqual(AIChatTranscriptLayout.preview(message("p", .thinking, String(repeating: "a", count: 200))).count, 161)
        XCTAssertEqual(AIChatTranscriptLayout.preview(nil), "")
    }
}
