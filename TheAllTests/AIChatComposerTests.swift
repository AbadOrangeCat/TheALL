import AppKit
import SwiftUI
import XCTest
@testable import TheAll

@MainActor
final class AIChatComposerTests: XCTestCase {
    private final class Transport: AIChatTransport {
        var onMessage: (([String: Any]) -> Void)?
        var onExit: ((Int32) -> Void)?
        var sent: [[String: Any]] = []
        func start(_ configuration: AILaunchConfiguration, directory: String) throws {}
        func send(_ message: [String: Any]) throws { sent.append(message); respondToClaudeEffortControl(message, sent: sent) { onMessage?($0) } }
        func stop() {}
        func ready() {
            onMessage?(["type": "control_response", "response": ["subtype": "success",
                "request_id": sent.last!["request_id"]!, "response": [:]]])
        }
    }

    private struct Host: View {
        @Bindable var chat: AIChatSession
        var onSend: () -> Void
        var body: some View {
            AIChatComposer(text: $chat.input, conversation: ObjectIdentifier(chat),
                history: { chat.messages.filter { $0.role == .user }.map(\.text) },
                theme: .systemFallback(isDark: true), onFocus: {}, onSend: onSend)
        }
    }

    private func chat(_ prompts: [String], draft: String = "", transport: Transport = Transport()) throws -> AIChatSession {
        var messages: [AIChatMessage] = []
        for prompt in prompts {
            messages.append(AIChatMessage(id: UUID().uuidString, role: .user, text: prompt))
            messages.append(AIChatMessage(id: UUID().uuidString, role: .assistant, text: "Not an input"))
            messages.append(AIChatMessage(id: UUID().uuidString, role: .thinking, text: "Not an input either"))
        }
        // Exercise the same persisted snapshot decode used on relaunch.
        let snapshot = AIChatSnapshot(provider: .claude, directory: "/tmp", model: "", input: draft,
            messages: messages, conversationID: "composer-fixture")
        let decoded = try JSONDecoder().decode(AIChatSnapshot.self, from: JSONEncoder().encode(snapshot))
        return AIChatSession(provider: .claude, model: "", directory: "/tmp", transport: transport, restoring: decoded)
    }

    private func mount(_ chat: AIChatSession, width: CGFloat = 440,
                       onSend: @escaping () -> Void = {}) throws -> (NSHostingView<Host>, AIChatComposer.Editor) {
        let host = NSHostingView(rootView: Host(chat: chat, onSend: onSend))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 110),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        pump()
        host.layoutSubtreeIfNeeded()
        func find(_ view: NSView) -> AIChatComposer.Editor? {
            (view as? AIChatComposer.Editor) ?? view.subviews.lazy.compactMap(find).first
        }
        let editor = try XCTUnwrap(find(host))
        window.makeFirstResponder(editor)
        editor.undoManager?.groupsByEvent = false
        editor.undoManager?.beginUndoGrouping()
        addTeardownBlock { @MainActor in
            window.contentView = nil
            window.close()
        }
        return (host, editor)
    }

    private func pump() { RunLoop.current.run(until: Date().addingTimeInterval(0.06)) }
    private func end(_ editor: NSTextView) {
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
    }
    private func key(_ code: UInt16, in editor: NSTextView,
                     flags: NSEvent.ModifierFlags = [.function, .numericPad]) throws {
        checkpointUndo(editor)
        let character = code == 126 ? "\u{F700}" : code == 125 ? "\u{F701}" : "\r"
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: editor.window?.windowNumber ?? 0,
            context: nil, characters: character, charactersIgnoringModifiers: character,
            isARepeat: false, keyCode: code))
        editor.keyDown(with: event)
        pump()
    }

    private func checkpointUndo(_ editor: NSTextView) {
        // These direct native events run inside one XCTest invocation rather
        // than separate NSApplication event-loop iterations.
        while let manager = editor.undoManager, manager.groupingLevel > 0 { manager.endUndoGrouping() }
        editor.undoManager?.beginUndoGrouping()
    }

    func testRestoredQuestionsRecallInOrderAndRestoreUnicodeDraftAndCaretWithoutSending() throws {
        let chat = try chat(["first", "最近的问题 🐈"], draft: "尚未发送 🐈")
        var sends = 0
        let (_, editor) = try mount(chat, onSend: { sends += 1 })
        let caret = NSRange(location: 2, length: 0)
        editor.setSelectedRange(caret)
        try key(126, in: editor)
        XCTAssertEqual(editor.string, "最近的问题 🐈")
        XCTAssertEqual(chat.input, editor.string)
        try key(126, in: editor)
        XCTAssertEqual(chat.input, "first")
        try key(126, in: editor) // At the oldest entry, do not wrap.
        XCTAssertEqual(chat.input, "first")
        try key(125, in: editor)
        XCTAssertEqual(chat.input, "最近的问题 🐈")
        try key(125, in: editor)
        XCTAssertEqual(chat.input, "尚未发送 🐈")
        XCTAssertEqual(editor.selectedRange(), caret)
        try key(125, in: editor)
        XCTAssertEqual(chat.input, "尚未发送 🐈")
        XCTAssertEqual(sends, 0)
        XCTAssertEqual(chat.messages.filter { $0.role == .user }.map(\.text), ["first", "最近的问题 🐈"])
    }

    func testEditingRecalledQuestionKeepsOriginalAndDraftAndSupportsUndo() throws {
        let chat = try chat(["first", "second"], draft: "unsent")
        let (_, editor) = try mount(chat)
        end(editor)
        try key(126, in: editor)
        editor.insertText(" edited", replacementRange: editor.selectedRange())
        pump()
        try key(126, in: editor)
        XCTAssertEqual(chat.input, "first")
        try key(125, in: editor)
        XCTAssertEqual(chat.input, "second edited")
        try key(125, in: editor)
        XCTAssertEqual(chat.input, "unsent")
        XCTAssertEqual(chat.messages.filter { $0.role == .user }.last?.text, "second")
        editor.breakUndoCoalescing()
        while let manager = editor.undoManager, manager.groupingLevel > 0 { manager.endUndoGrouping() }
        editor.undoManager?.undo()
        pump()
        XCTAssertEqual(chat.input, "second edited")
    }

    func testHardLinesTrailingEmptyLineAndSoftWrapKeepNativeCursorMovement() throws {
        let chat = try chat(["previous"], draft: "first line\nsecond line\n")
        let (_, editor) = try mount(chat, width: 220)
        end(editor)
        try key(126, in: editor)
        XCTAssertEqual(chat.input, "first line\nsecond line\n")
        XCTAssertLessThan(editor.selectedRange().location, (chat.input as NSString).length)
        editor.setSelectedRange(NSRange(location: 11, length: 0), affinity: .upstream, stillSelecting: false)
        try key(126, in: editor) // Start of a hard second line is not a history boundary.
        XCTAssertEqual(chat.input, "first line\nsecond line\n")
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        try key(126, in: editor)
        XCTAssertEqual(chat.input, "previous")
        try key(125, in: editor)
        XCTAssertEqual(chat.input, "first line\nsecond line\n")

        chat.input = String(repeating: "wrapped text 🐈 ", count: 20)
        pump()
        let wrapped = chat.input
        end(editor)
        try key(126, in: editor)
        XCTAssertEqual(chat.input, wrapped)
        XCTAssertLessThan(editor.selectedRange().location, (wrapped as NSString).length)
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        try key(126, in: editor)
        XCTAssertEqual(chat.input, "previous")
        try key(125, in: editor)
        XCTAssertEqual(chat.input, wrapped)
    }

    func testSelectionModifiersAndMarkedTextNeverRecallHistory() throws {
        let chat = try chat(["previous"], draft: "current")
        let (_, editor) = try mount(chat)
        editor.setSelectedRange(NSRange(location: 0, length: 3))
        try key(126, in: editor)
        XCTAssertEqual(chat.input, "current")
        for flags: NSEvent.ModifierFlags in [[.shift, .function, .numericPad], [.command, .function, .numericPad], [.option, .function, .numericPad], [.control, .function, .numericPad]] {
            end(editor)
            try key(126, in: editor, flags: flags)
            XCTAssertEqual(chat.input, "current")
        }
        end(editor)
        editor.setMarkedText("拼音", selectedRange: NSRange(location: 2, length: 0), replacementRange: editor.selectedRange())
        XCTAssertTrue(editor.hasMarkedText())
        let marked = editor.string
        try key(126, in: editor)
        XCTAssertEqual(editor.string, marked)
        XCTAssertNotEqual(editor.string, "previous")
        editor.unmarkText()
    }

    func testRemoteSubmissionAndStreamingKeepBrowsingDraftAndNextPassGetsNewHistory() throws {
        let pipe = Transport()
        let chat = try chat(["first", "second"], draft: "desktop draft", transport: pipe)
        chat.start(AILaunchConfiguration(command: "unused", environment: [:], executable: "/usr/bin/true"))
        pipe.ready()
        let (_, editor) = try mount(chat)
        end(editor)
        try key(126, in: editor)
        XCTAssertEqual(chat.input, "second")
        XCTAssertTrue(chat.sendRemote("from phone"))
        pipe.onMessage?(["type": "assistant", "message": ["id": "stream", "content": [["type": "text", "text": "A streamed reply"]]]])
        pump()
        try key(126, in: editor)
        XCTAssertEqual(chat.input, "first")
        try key(125, in: editor)
        try key(125, in: editor)
        XCTAssertEqual(chat.input, "desktop draft")
        try key(126, in: editor)
        XCTAssertEqual(chat.input, "from phone")
        chat.stop()
    }

    func testSendShortcutClearsBrowsingOnlyAfterSubmissionAndRecordsRecalledPrompt() throws {
        let pipe = Transport()
        let chat = try chat(["previous"], draft: "unsent", transport: pipe)
        chat.start(AILaunchConfiguration(command: "unused", environment: [:], executable: "/usr/bin/true"))
        pipe.ready()
        let (_, editor) = try mount(chat, onSend: { chat.send() })
        end(editor)
        try key(126, in: editor)
        try key(36, in: editor, flags: .command)
        XCTAssertEqual(chat.input, "")
        XCTAssertEqual(chat.messages.filter { $0.role == .user }.map(\.text), ["previous", "previous"])
        try key(126, in: editor)
        XCTAssertEqual(chat.input, "previous")
        try key(125, in: editor)
        XCTAssertEqual(chat.input, "") // A sent prompt must not resurrect the old unsent draft.
        chat.stop()
    }

    func testSessionSwitchAndExternalDraftReplacementResetRecallAndUndo() throws {
        let first = try chat(["first session"], draft: "old draft")
        let (host, editor) = try mount(first)
        try key(126, in: editor)
        let second = try chat(["second session"], draft: "first session")
        // Same text, different conversation: no old draft or undo may leak.
        host.rootView = Host(chat: second, onSend: {})
        pump()
        XCTAssertFalse(editor.undoManager?.canUndo ?? true)
        try key(125, in: editor)
        XCTAssertEqual(second.input, "first session")
        try key(126, in: editor)
        XCTAssertEqual(second.input, "second session")
        second.input = "external draft"
        pump()
        try key(125, in: editor)
        XCTAssertEqual(second.input, "external draft")
        try key(126, in: editor)
        try key(125, in: editor)
        XCTAssertEqual(second.input, "external draft")
    }

    func testUndoWhileBrowsingStartsFreshHistoryWithoutOverwritingEntries() throws {
        let chat = try chat(["first", "second"], draft: "unsent")
        let (_, editor) = try mount(chat)
        try key(126, in: editor)
        try key(126, in: editor)
        XCTAssertEqual(chat.input, "first")
        editor.breakUndoCoalescing()
        while let manager = editor.undoManager, manager.groupingLevel > 0 { manager.endUndoGrouping() }
        editor.undoManager?.undo()
        pump()
        XCTAssertEqual(chat.input, "second")
        try key(125, in: editor)
        XCTAssertEqual(chat.input, "second")
        try key(126, in: editor)
        try key(126, in: editor)
        XCTAssertEqual(chat.input, "first")
        try key(125, in: editor)
        try key(125, in: editor)
        XCTAssertEqual(chat.input, "second")
    }

    func testFailedModelAcknowledgementKeepsOriginalDraftDuringRecall() throws {
        let pipe = Transport()
        let chat = try chat(["previous"], draft: "unsent", transport: pipe)
        chat.start(AILaunchConfiguration(command: "unused", environment: [:], executable: "/usr/bin/true"))
        pipe.ready()
        chat.model = "unavailable-model"
        let (_, editor) = try mount(chat, onSend: { chat.send() })
        try key(126, in: editor)
        try key(36, in: editor, flags: .command)
        XCTAssertEqual(chat.input, "previous")
        pipe.onMessage?(["type": "control_response", "response": ["subtype": "error",
            "request_id": pipe.sent.last!["request_id"]!, "error": "fixture model unavailable"]])
        pump()
        XCTAssertEqual(chat.messages.filter { $0.role == .user }.count, 1)
        try key(125, in: editor)
        XCTAssertEqual(chat.input, "unsent")
        chat.stop()
    }

    func testEmptyHistoryLeavesDraftAndReturnInsertsNewline() throws {
        let chat = try chat([], draft: "current")
        let (_, editor) = try mount(chat)
        end(editor)
        try key(126, in: editor)
        XCTAssertEqual(chat.input, "current")
        end(editor)
        try key(36, in: editor, flags: [])
        XCTAssertEqual(chat.input, "current\n")
    }
}
