import AppKit
import CryptoKit
import UniformTypeIdentifiers
import XCTest
@testable import TheAll

final class AIChatFileTests: XCTestCase {
    private final class Transport: AIChatTransport {
        var onMessage: (([String: Any]) -> Void)?
        var onExit: ((Int32) -> Void)?
        var sent: [[String: Any]] = []
        var deferUserWrites = false
        var pendingWrites: [(Result<Void, Error>) -> Void] = []
        func start(_ configuration: AILaunchConfiguration, directory: String) throws {}
        func stop() {}
        func send(_ message: [String: Any]) throws {
            sent.append(message)
            respondToClaudeEffortControl(message, sent: sent) { onMessage?($0) }
        }
        func send(_ message: [String: Any], completion: @escaping (Result<Void, Error>) -> Void) throws {
            try send(message)
            if deferUserWrites, message["type"] as? String == "user" { pendingWrites.append(completion) }
            else { completion(.success(())) }
        }
        func respond(_ value: [String: Any] = [:]) {
            guard let request = sent.last else { return }
            if let id = request["request_id"] {
                onMessage?(["type": "control_response", "response": ["subtype": "success", "request_id": id, "response": value]])
            } else if let id = request["id"] { onMessage?(["id": id, "result": value]) }
        }
        func reject() {
            guard let id = sent.last?["id"] else { return }
            onMessage?(["id": id, "error": ["message": "Unavailable model"]])
        }
    }

    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("TheAllFiles-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func png() throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        for x in 0..<2 { for y in 0..<2 { bitmap.setColor(.blue, atX: x, y: y) } }
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }

    @MainActor private func ready(_ provider: AIProvider, store: AIChatFileStore) -> (AIChatSession, Transport) {
        let pipe = Transport()
        let chat = AIChatSession(provider: provider, model: "model-a", directory: "/tmp", transport: pipe,
            imageStore: AIChatImageStore(directory: store.directory.deletingLastPathComponent().appendingPathComponent("Images")), fileStore: store)
        chat.start(AILaunchConfiguration(command: "fixture", environment: [:], executable: "/usr/bin/true"))
        pipe.respond()
        if provider == .openai { pipe.respond(["data": []]); pipe.respond(["thread": ["id": "file-thread"]]) }
        XCTAssertTrue(chat.isReady)
        return (chat, pipe)
    }

    @MainActor private func eventually(_ predicate: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<200 {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for attachment submission", file: file, line: line)
    }

    func testStoredFilesPreserveExactBytesEmptyFilesUnicodeAndSourceIndependence() throws {
        let root = try root(), store = AIChatFileStore(directory: root.appendingPathComponent("Files"))
        let bytes = Data((0...255).map(UInt8.init)), source = root.appendingPathComponent("报告 🐈.ZIP")
        try bytes.write(to: source)
        let file = try store.importFile(at: source)
        try FileManager.default.removeItem(at: source)
        XCTAssertEqual(file.name, "报告 🐈.ZIP")
        XCTAssertEqual(file.byteCount, bytes.count)
        XCTAssertEqual(file.sha256, SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
        XCTAssertEqual(try store.data(for: file), bytes)
        let stored = try store.url(for: file)
        XCTAssertEqual(stored.lastPathComponent, file.id.uuidString + ".zip")
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: store.directory.path)[.posixPermissions] as? Int, 0o700)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: stored.path)[.posixPermissions] as? Int, 0o600)
        let empty = try store.importFile(data: Data(), name: "empty.txt")
        XCTAssertEqual(empty.byteCount, 0)
        XCTAssertEqual(try store.data(for: empty), Data())
        let unsafe = try store.importFile(data: bytes, name: "../../bad\n\u{202E}name.脚本")
        XCTAssertEqual(unsafe.name, "badname.脚本")
        XCTAssertEqual(try store.url(for: unsafe).lastPathComponent, unsafe.id.uuidString + ".file")
        XCTAssertLessThanOrEqual(AIChatFileStore.displayName(String(repeating: "猫", count: 200)).utf8.count, 255)
    }

    func testSourceAndStoredSymlinksDirectoriesOversizedAndTamperedFilesAreRejected() throws {
        let root = try root(), store = AIChatFileStore(directory: root.appendingPathComponent("Files"))
        let source = root.appendingPathComponent("source.txt"), link = root.appendingPathComponent("link.txt")
        try Data("original".utf8).write(to: source)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        XCTAssertThrowsError(try store.importFile(at: link))
        XCTAssertThrowsError(try store.importFile(at: root))
        XCTAssertThrowsError(try store.importFile(data: Data(repeating: 0, count: AIChatFileStore.maximumBytes + 1), name: "huge.bin"))
        let file = try store.importFile(at: source), stored = try store.url(for: file)
        try Data("modified".utf8).write(to: stored)
        XCTAssertThrowsError(try store.data(for: file), "Same-length changes must fail the digest check")
        try FileManager.default.removeItem(at: stored)
        try FileManager.default.createSymbolicLink(at: stored, withDestinationURL: source)
        XCTAssertThrowsError(try store.data(for: file))
        let linkedStore = root.appendingPathComponent("LinkedFiles")
        try FileManager.default.createSymbolicLink(at: linkedStore, withDestinationURL: store.directory)
        XCTAssertThrowsError(try AIChatFileStore(directory: linkedStore).importFile(data: Data(), name: "empty.txt"))
    }

    func testBatchLimitsRejectDuplicateIDsTooManyAndAggregateBytes() throws {
        func metadata(_ count: Int) -> AIChatFile {
            AIChatFile(id: UUID(), name: "data.bin", mimeType: "application/octet-stream", byteCount: count, sha256: String(repeating: "a", count: 64))
        }
        let large = metadata(AIChatFileStore.maximumBytes)
        XCTAssertNoThrow(try AIChatFileStore.validate([large, metadata(AIChatFileStore.maximumBytes)]))
        XCTAssertThrowsError(try AIChatFileStore.validate([large, metadata(AIChatFileStore.maximumBytes), metadata(1)]))
        XCTAssertThrowsError(try AIChatFileStore.validate([large, large]))
        XCTAssertThrowsError(try AIChatFileStore.validate((0..<6).map { _ in metadata(0) }))
        XCTAssertThrowsError(try AIChatFileStore.validate([metadata(-1)]))
    }

    func testMixedClipboardRoutesRasterAndSVGSeparatelyAndFailedBatchRollsBack() throws {
        let root = try root(), images = AIChatImageStore(directory: root.appendingPathComponent("Images"))
        let files = AIChatFileStore(directory: root.appendingPathComponent("Files"))
        let imageURL = root.appendingPathComponent("screen.png"), fileURL = root.appendingPathComponent("vector.svg")
        try png().write(to: imageURL)
        let svg = Data("<svg><script>doNotExecute()</script></svg>".utf8)
        try svg.write(to: fileURL)
        let board = NSPasteboard(name: .init("TheAllFiles-" + UUID().uuidString))
        defer { board.releaseGlobally() }
        board.writeObjects([imageURL as NSURL, fileURL as NSURL])
        XCTAssertTrue(AIChatAttachmentImport.containsAttachments(board))
        let sources = try XCTUnwrap(AIChatAttachmentImport.read(board))
        let batch = try AIChatAttachmentImport.importBatch(sources, imageStore: images, fileStore: files)
        XCTAssertEqual(batch.images.map(\.name), ["screen.png"])
        XCTAssertEqual(batch.files.map(\.name), ["vector.svg"])
        XCTAssertEqual(try files.data(for: batch.files[0]), svg)
        let beforeImages = try FileManager.default.contentsOfDirectory(atPath: images.directory.path)
        let beforeFiles = try FileManager.default.contentsOfDirectory(atPath: files.directory.path)
        XCTAssertThrowsError(try AIChatAttachmentImport.importBatch([
            .file(fileURL), .file(imageURL), .imageData(Data("broken".utf8), name: "broken.png")
        ], imageStore: images, fileStore: files))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: images.directory.path), beforeImages)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: files.directory.path), beforeFiles)
        board.clearContents(); board.setString("ordinary text", forType: .string)
        XCTAssertNil(AIChatAttachmentImport.read(board))
    }

    func testMixedDropAndTemporaryFileRepresentationKeepIndependentCopies() async throws {
        let root = try root(), images = AIChatImageStore(directory: root.appendingPathComponent("Images"))
        let files = AIChatFileStore(directory: root.appendingPathComponent("Files"))
        let source = root.appendingPathComponent("temporary.txt"), bytes = Data("Exact source bytes\n".utf8)
        try bytes.write(to: source)
        let provider = NSItemProvider()
        provider.suggestedName = "报告.txt"
        provider.registerFileRepresentation(forTypeIdentifier: UTType.plainText.identifier, fileOptions: [], visibility: .all) { completion in
            completion(source, false, nil)
            try? FileManager.default.removeItem(at: source)
            return nil
        }
        let photo = NSItemProvider(item: try png() as NSData, typeIdentifier: UTType.png.identifier)
        let batch = try await AIChatAttachmentImport.importProviders([photo, provider], imageStore: images, fileStore: files)
        XCTAssertEqual(batch.images.count, 1)
        XCTAssertEqual(batch.files.map(\.name), ["报告.txt"])
        XCTAssertEqual(try files.data(for: batch.files[0]), bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
    }

    @MainActor func testBothProvidersSendFileOnlyAsQuotedLocalPathsWithoutPollutingHistory() async throws {
        for provider in AIProvider.allCases {
            for text in ["", "Inspect this file"] {
                let store = AIChatFileStore(directory: try root().appendingPathComponent("Files"))
                let file = try store.importFile(data: Data("document".utf8), name: "quote \" $(never-run).txt")
                let (chat, pipe) = ready(provider, store: store)
                defer { chat.stop() }
                chat.input = text; chat.draftFiles = [file]
                XCTAssertTrue(chat.canSend); XCTAssertTrue(chat.needsConfirmClose)
                chat.send()
                try await eventually { pipe.sent.contains { $0["type"] as? String == "user" || $0["method"] as? String == "turn/start" } }
                let prompt: String
                if provider == .claude {
                    let message = try XCTUnwrap(pipe.sent.last?["message"] as? [String: Any])
                    prompt = try XCTUnwrap(message["content"] as? String)
                } else {
                    let params = try XCTUnwrap(pipe.sent.last?["params"] as? [String: Any])
                    let input = try XCTUnwrap(params["input"] as? [[String: Any]])
                    XCTAssertEqual(input.count, 1); XCTAssertEqual(input[0]["type"] as? String, "text")
                    prompt = try XCTUnwrap(input[0]["text"] as? String)
                }
                let json = try XCTUnwrap(prompt.components(separatedBy: "\n").last).data(using: .utf8)!
                let references = try XCTUnwrap(JSONSerialization.jsonObject(with: json) as? [[String: Any]])
                XCTAssertEqual(references[0]["name"] as? String, file.name)
                XCTAssertEqual(references[0]["path"] as? String, try store.url(for: file).path)
                XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: references[0]["path"] as! String)), Data("document".utf8))
                XCTAssertEqual(chat.visibleMessages.last?.text, text)
                XCTAssertEqual(chat.visibleMessages.last?.files, [file])
                XCTAssertFalse(chat.snapshot.messages.last?.text.contains(store.directory.path) ?? true)
                XCTAssertTrue(chat.draftFiles.isEmpty)
            }
        }
    }

    @MainActor func testCodexRejectionRestoresSubmittedFilesWithoutReplacingLaterDraft() async throws {
        let store = AIChatFileStore(directory: try root().appendingPathComponent("Files"))
        let first = try store.importFile(data: Data("first".utf8), name: "first.txt")
        let later = try store.importFile(data: Data("later".utf8), name: "later.txt")
        let (chat, pipe) = ready(.openai, store: store)
        defer { chat.stop() }
        chat.input = "First"; chat.draftFiles = [first]; chat.send()
        try await eventually { pipe.sent.last?["method"] as? String == "turn/start" }
        chat.input = "Later draft"; chat.draftFiles = [later]
        pipe.reject()
        XCTAssertEqual(chat.input, "Later draft")
        XCTAssertEqual(Set(chat.draftFiles.map(\.id)), Set([first.id, later.id]))
        XCTAssertEqual(chat.messages.first?.files, [first], "The written turn retains its attachment reference")
        XCTAssertFalse(chat.isBusy)
    }

    @MainActor func testClaudeUnknownWriteRetainsLocalDraftAndRemoteFileCopy() async throws {
        let store = AIChatFileStore(directory: try root().appendingPathComponent("Files"))
        let file = try store.importFile(data: Data("keep".utf8), name: "keep.txt")
        let (chat, pipe) = ready(.claude, store: store)
        defer { chat.stop() }
        pipe.deferUserWrites = true
        chat.input = "Keep draft"; chat.draftFiles = [file]; chat.send()
        try await eventually { pipe.pendingWrites.count == 1 }
        pipe.pendingWrites.removeFirst()(.failure(CocoaError(.fileWriteUnknown)))
        XCTAssertEqual(chat.input, "Keep draft"); XCTAssertEqual(chat.draftFiles, [file])
        XCTAssertTrue(chat.messages.isEmpty)
        var outcome: AIChatSession.RemoteSubmissionResult?
        XCTAssertTrue(chat.sendRemote("", files: [file], completion: { outcome = $0 }))
        try await eventually { pipe.pendingWrites.count == 1 }
        pipe.pendingWrites.removeFirst()(.failure(CocoaError(.fileWriteUnknown)))
        XCTAssertEqual(outcome, .uncertain)
        XCTAssertEqual(chat.input, "Keep draft"); XCTAssertEqual(chat.draftFiles, [file])
        XCTAssertEqual(try store.data(for: file), Data("keep".utf8))
    }

    @MainActor func testMissingFileDoesNotSendTextOnlyOrLoseDraft() async throws {
        let store = AIChatFileStore(directory: try root().appendingPathComponent("Files"))
        let file = try store.importFile(data: Data("gone".utf8), name: "gone.txt")
        let (chat, pipe) = ready(.claude, store: store)
        defer { chat.stop() }
        try store.remove(file)
        chat.input = "Read this"; chat.draftFiles = [file]; chat.send()
        try await eventually { !chat.isBusy && chat.errorMessage != nil }
        XCTAssertFalse(pipe.sent.contains { $0["type"] as? String == "user" })
        XCTAssertEqual(chat.input, "Read this"); XCTAssertEqual(chat.draftFiles, [file])
    }

    @MainActor func testVersionThreeHistoryKeepsFilesAndDraftAfterReopenAndReadsOlderVersions() throws {
        let history = AIChatHistoryStore(directory: try root()), id = UUID()
        let bytes = Data(repeating: 0xA5, count: 4096)
        let sent = try history.fileStore.importFile(data: bytes, name: "sent.bin")
        let draft = try history.fileStore.importFile(data: Data(), name: "draft.txt")
        var snapshot = AIChatSnapshot(provider: .claude, directory: "/tmp", model: "a", input: "Unsent",
            messages: [], conversationID: "saved-thread")
        snapshot.messages = [AIChatMessage(id: "file-user", role: .user, text: "", files: [sent])]
        snapshot.draftFiles = [draft]
        history.save(snapshot, for: id) { _ in }; history.flush()
        let encoded = try Data(contentsOf: history.directory.appendingPathComponent(id.uuidString + ".json"))
        XCTAssertLessThan(encoded.count, 3000)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains(bytes.base64EncodedString()))
        let reopenedStore = AIChatHistoryStore(directory: history.directory)
        let loaded = try XCTUnwrap(reopenedStore.load(for: id))
        XCTAssertEqual(loaded.version, 3)
        let reopened = AIChatSession(provider: .claude, model: "", directory: "/tmp", restoring: loaded,
            imageStore: reopenedStore.imageStore, fileStore: reopenedStore.fileStore)
        XCTAssertEqual(reopened.visibleMessages.first?.files, [sent])
        XCTAssertEqual(reopened.draftFiles, [draft]); XCTAssertEqual(reopened.input, "Unsent")
        XCTAssertEqual(try reopened.fileStore.data(for: sent), bytes)
        XCTAssertEqual(try reopened.fileStore.data(for: draft), Data())
        for version in [1, 2] {
            let json = "{\"version\":\(version),\"provider\":\"claude\",\"directory\":\"/tmp\",\"model\":\"a\",\"input\":\"old draft\",\"messages\":[{\"id\":\"one\",\"role\":\"user\",\"text\":\"old question\"}]}"
            let oldID = UUID()
            try Data(json.utf8).write(to: history.directory.appendingPathComponent(oldID.uuidString + ".json"))
            let old = try XCTUnwrap(reopenedStore.load(for: oldID))
            XCTAssertEqual(old.version, version); XCTAssertEqual(old.input, "old draft")
            XCTAssertTrue(old.draftFiles.isEmpty); XCTAssertTrue(old.messages[0].files.isEmpty)
        }
    }
    @MainActor func testUpdateWaitsForAttachmentImportAndSavesCompletedDraft() throws {
        let files = AIChatFileStore(directory: try root().appendingPathComponent("FileAttachments"))
        let (chat, _) = ready(.claude, store: files)
        let store = UpdateStore(currentVersion: "0.1.6")
        var flushed = false, installed = false
        let file = try files.importFile(data: Data("imported".utf8), name: "report.txt")
        XCTAssertTrue(chat.beginAttachmentImport())
        XCTAssertTrue(chat.beginAttachmentImport())
        let coordinator = UpdateInstallCoordinator(store: store, isBusy: { chat.hasPendingWorkForUpdate }, flush: {
            XCTAssertEqual(chat.snapshot.draftFiles, [file]); flushed = true
        })
        coordinator.ready(install: { installed = true }, cancel: { XCTFail("Unexpected cancellation") })
        XCTAssertFalse(flushed); XCTAssertFalse(installed)
        chat.endAttachmentImport(); coordinator.continueWhenIdle()
        XCTAssertFalse(installed)
        chat.draftFiles = [file]; chat.endAttachmentImport(); coordinator.continueWhenIdle()
        XCTAssertTrue(flushed); XCTAssertTrue(installed)
        chat.stop()
    }

}
