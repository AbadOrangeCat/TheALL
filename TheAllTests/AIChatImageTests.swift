import AppKit
import ImageIO
import CryptoKit
import UniformTypeIdentifiers
import XCTest
@testable import TheAll

final class AIChatImageTests: XCTestCase {
    private final class Transport: AIChatTransport {
        var onMessage: (([String: Any]) -> Void)?
        var onExit: ((Int32) -> Void)?
        var sent: [[String: Any]] = []
        var rejectWrites = false
        var deferUserWrites = false
        var pendingWrites: [(Result<Void, Error>) -> Void] = []
        func start(_ configuration: AILaunchConfiguration, directory: String) throws {}
        func send(_ message: [String: Any]) throws {
            if rejectWrites { throw CocoaError(.fileWriteUnknown) }
            sent.append(message)
            respondToClaudeEffortControl(message, sent: sent) { onMessage?($0) }
        }
        func send(_ message: [String: Any], completion: @escaping (Result<Void, Error>) -> Void) throws {
            try send(message)
            if deferUserWrites, message["type"] as? String == "user" { pendingWrites.append(completion) }
            else { completion(.success(())) }
        }
        func finishWrite(_ result: Result<Void, Error> = .success(())) { pendingWrites.removeFirst()(result) }
        func stop() {}
        func respond(_ value: [String: Any] = [:]) {
            guard let request = sent.last else { return }
            if let id = request["request_id"] {
                onMessage?(["type": "control_response", "response": ["subtype": "success", "request_id": id, "response": value]])
            } else if let id = request["id"] { onMessage?(["id": id, "result": value]) }
        }
        func reject() {
            guard let request = sent.last else { return }
            if let id = request["request_id"] {
                onMessage?(["type": "control_response", "response": ["subtype": "error", "request_id": id, "error": "Unavailable model"]])
            } else if let id = request["id"] { onMessage?(["id": id, "error": ["message": "Unavailable model"]]) }
        }
    }

    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("TheAllImages-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func fixture(width: Int = 48, height: Int = 32, orientation: Int = 1, alpha: Bool = false,
                         type: UTType? = nil) throws -> Data {
        let info = alpha ? CGImageAlphaInfo.premultipliedLast.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: alpha ? 0.5 : 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, (type ?? (alpha ? UTType.png : UTType.jpeg)).identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), [
            kCGImagePropertyOrientation: orientation,
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 30.0, kCGImagePropertyGPSLatitudeRef: "N"],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "Private camera note"]
        ] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func store() throws -> AIChatImageStore { AIChatImageStore(directory: try root().appendingPathComponent("Attachments")) }
    private func ready(_ provider: AIProvider, store: AIChatImageStore) -> (AIChatSession, Transport) {
        let pipe = Transport()
        let chat = AIChatSession(provider: provider, model: "model-a", directory: "/tmp", transport: pipe, imageStore: store)
        chat.start(AILaunchConfiguration(command: "fixture", environment: [:], executable: "/usr/bin/true"))
        pipe.respond()
        if provider == .openai { pipe.respond(["data": []]); pipe.respond(["thread": ["id": "same-thread"]]) }
        XCTAssertTrue(chat.isReady)
        return (chat, pipe)
    }

    func testNormalizationOrientsAndRemovesMetadataWithoutChangingOriginal() throws {
        let store = try store(), data = try fixture(orientation: 6)
        let original = try root().appendingPathComponent("photo.jpg")
        try data.write(to: original)
        let image = try store.importImage(at: original)
        XCTAssertEqual(image.width, 32)
        XCTAssertEqual(image.height, 48)
        XCTAssertEqual(image.mimeType, "image/jpeg")
        XCTAssertEqual(try Data(contentsOf: original), data)
        let saved = try store.data(for: image)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(saved as CFData, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertNil(properties[kCGImagePropertyGPSDictionary])
        XCTAssertNil((properties[kCGImagePropertyExifDictionary] as? [CFString: Any])?[kCGImagePropertyExifUserComment])
        XCTAssertNotEqual(properties[kCGImagePropertyOrientation] as? Int, 6)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: store.directory.path)[.posixPermissions] as? Int, 0o700)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: store.url(for: image).path)[.posixPermissions] as? Int, 0o600)
    }

    func testLargePhotoIsDownsampledAndAlphaScreenshotRemainsPNG() throws {
        let store = try store()
        let image = try store.importImage(data: fixture(width: 3000, height: 1500), name: "photo.jpg")
        XCTAssertEqual(image.width, 2048)
        XCTAssertEqual(image.height, 1024)
        XCTAssertLessThanOrEqual(try store.data(for: image).count, AIChatImageStore.maximumStoredBytes)
        let screenshot = try store.importImage(data: fixture(alpha: true), name: "screen.png")
        XCTAssertEqual(screenshot.mimeType, "image/png")
        XCTAssertEqual(try store.url(for: screenshot).pathExtension, "png")
        let tiny = try store.importImage(data: fixture(width: 12, height: 8), name: "tiny.jpg")
        XCTAssertEqual(tiny.width, 12)
        XCTAssertEqual(tiny.height, 8)
    }

    func testHEICPhotoIsConvertedToProviderCompatibleFormat() throws {
        let encoders = CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []
        guard encoders.contains(UTType.heic.identifier) else { throw XCTSkip("System HEIC encoder is unavailable") }
        let store = try store()
        let image = try store.importImage(data: fixture(width: 128, height: 96, type: .heic), name: "phone.heic")
        XCTAssertTrue(["image/jpeg", "image/png"].contains(image.mimeType))
        XCTAssertEqual(image.width, 128); XCTAssertEqual(image.height, 96)
        XCTAssertEqual(try store.url(for: image).pathExtension, image.mimeType == "image/png" ? "png" : "jpg")
        XCTAssertFalse(try store.data(for: image).isEmpty)
    }

    func testInvalidOversizedAndSymlinkInputsFailWithoutCreatingStoredImages() throws {
        let store = try store()
        XCTAssertThrowsError(try store.importImage(data: Data("not a picture".utf8), name: "fake.jpg"))
        XCTAssertThrowsError(try store.importImage(data: Data(repeating: 0, count: AIChatImageStore.maximumInputBytes + 1), name: "huge.png"))
        let source = try root().appendingPathComponent("source.png")
        try fixture().write(to: source)
        let link = source.deletingLastPathComponent().appendingPathComponent("link.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        XCTAssertThrowsError(try store.importImage(at: link))
        XCTAssertThrowsError(try store.importImage(at: source.deletingLastPathComponent()))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.directory.path))
    }

    func testAttachmentPathsIgnoreDisplayNameAndRejectTamperedMetadataAndSymlinks() throws {
        let store = try store()
        let image = try store.importImage(data: fixture(), name: "../../outside.jpg")
        XCTAssertEqual(image.name, "outside.jpg")
        let url = try store.url(for: image)
        XCTAssertEqual(url.deletingLastPathComponent().path, store.directory.path)
        XCTAssertEqual(url.lastPathComponent, image.id.uuidString + ".jpg")
        let wrongMime = AIChatImage(id: image.id, name: image.name, mimeType: "text/html", width: image.width, height: image.height)
        XCTAssertThrowsError(try store.data(for: wrongMime))
        let wrongSize = AIChatImage(id: image.id, name: image.name, mimeType: image.mimeType, width: 1, height: 1)
        XCTAssertThrowsError(try store.data(for: wrongSize))
        let original = try root().appendingPathComponent("source.jpg")
        try fixture().write(to: original)
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: original)
        XCTAssertThrowsError(try store.data(for: image))
    }

    func testStoreDirectoryCannotBeSymlinkAndUnreferencedImageCanBeRemoved() throws {
        let root = try root(), destination = root.appendingPathComponent("target"), link = root.appendingPathComponent("link")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: destination)
        XCTAssertThrowsError(try AIChatImageStore(directory: link).importImage(data: fixture(), name: "photo.jpg"))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
        let store = try store(), image = try store.importImage(data: fixture(), name: "photo.jpg")
        try store.remove(image)
        XCTAssertThrowsError(try store.data(for: image))
    }

    func testClaudeImageOnlyUsesImageBlockAndPersistsVisibleUserMessage() throws {
        let store = try store(), image = try store.importImage(data: fixture(), name: "photo.jpg")
        let (chat, pipe) = ready(.claude, store: store)
        var title: String?
        chat.onFirstMessageSubmitted = { title = $0 }
        chat.draftImages = [image]
        XCTAssertTrue(chat.canSend)
        XCTAssertTrue(chat.needsConfirmClose)
        chat.send()
        let message = try XCTUnwrap(pipe.sent.last?["message"] as? [String: Any])
        let content = try XCTUnwrap(message["content"] as? [[String: Any]])
        XCTAssertEqual(content.count, 1)
        XCTAssertEqual(content[0]["type"] as? String, "image")
        let source = try XCTUnwrap(content[0]["source"] as? [String: Any])
        XCTAssertEqual(source["type"] as? String, "base64")
        XCTAssertEqual(source["media_type"] as? String, "image/jpeg")
        XCTAssertEqual(Data(base64Encoded: try XCTUnwrap(source["data"] as? String)), try store.data(for: image))
        XCTAssertEqual(chat.visibleMessages.last?.images, [image])
        XCTAssertTrue(chat.draftImages.isEmpty)
        XCTAssertNotNil(title)
    }

    func testClaudeModelAcknowledgementCapturesPhotosAndKeepsLaterDraft() throws {
        let store = try store(), first = try store.importImage(data: fixture(), name: "first.jpg")
        let second = try store.importImage(data: fixture(alpha: true), name: "later.png")
        let (chat, pipe) = ready(.claude, store: store)
        chat.model = "model-b"; chat.input = "Describe this"; chat.draftImages = [first]
        chat.send()
        XCTAssertEqual(chat.draftImages, [first])
        chat.input = "Next draft"; chat.draftImages.append(second)
        pipe.respond()
        XCTAssertEqual(chat.messages.last?.images, [first])
        XCTAssertEqual(chat.messages.last?.text, "Describe this")
        XCTAssertEqual(chat.draftImages, [second])
        XCTAssertEqual(chat.input, "Next draft")
    }

    func testClaudeFailedModelAndTransportKeepPhotoDraft() throws {
        let store = try store(), image = try store.importImage(data: fixture(), name: "photo.jpg")
        let (chat, pipe) = ready(.claude, store: store)
        chat.model = "unavailable"; chat.draftImages = [image]
        chat.send(); pipe.reject()
        XCTAssertEqual(chat.draftImages, [image]); XCTAssertTrue(chat.messages.isEmpty)
        chat.model = "model-a"; pipe.rejectWrites = true; chat.send()
        XCTAssertEqual(chat.draftImages, [image]); XCTAssertTrue(chat.messages.isEmpty)
        XCTAssertFalse(chat.isBusy)
    }

    func testClaudeWaitsForActualWriteAndOrdersEarlyReplyAfterUserPhoto() throws {
        let store = try store(), photo = try store.importImage(data: fixture(), name: "photo.jpg")
        let later = try store.importImage(data: fixture(alpha: true), name: "later.png")
        let (chat, pipe) = ready(.claude, store: store)
        pipe.deferUserWrites = true
        chat.input = "First"; chat.draftImages = [photo]; chat.send()
        XCTAssertTrue(chat.isBusy); XCTAssertFalse(chat.canInterrupt)
        XCTAssertTrue(chat.messages.isEmpty)
        XCTAssertEqual(chat.input, "First"); XCTAssertEqual(chat.draftImages, [photo])
        chat.input = "Later draft"; chat.draftImages.append(later)
        // The process can answer before the main queue handles write completion.
        pipe.onMessage?(["type": "assistant", "message": ["id": "early-reply", "content": [["type": "text", "text": "Photo received"]]]])
        pipe.onMessage?(["type": "result", "is_error": false, "session_id": "photo-session"])
        XCTAssertTrue(chat.messages.isEmpty); XCTAssertTrue(chat.isBusy)
        pipe.finishWrite()
        XCTAssertEqual(chat.messages.map(\.role), [.user, .assistant])
        XCTAssertEqual(chat.messages.first?.images, [photo])
        XCTAssertEqual(chat.input, "Later draft"); XCTAssertEqual(chat.draftImages, [later])
        XCTAssertFalse(chat.isBusy); XCTAssertFalse(chat.canInterrupt)
        XCTAssertEqual(chat.conversationID, "photo-session")
    }

    func testClaudeAsyncWriteFailureKeepsPhotosAndRemoteOutcomeIsUncertain() throws {
        let store = try store(), photo = try store.importImage(data: fixture(), name: "photo.jpg")
        let (chat, pipe) = ready(.claude, store: store)
        pipe.deferUserWrites = true
        chat.input = "Keep"; chat.draftImages = [photo]; chat.send()
        pipe.finishWrite(.failure(CocoaError(.fileWriteUnknown)))
        XCTAssertEqual(chat.input, "Keep"); XCTAssertEqual(chat.draftImages, [photo])
        XCTAssertTrue(chat.messages.isEmpty); XCTAssertFalse(chat.isBusy)
        var outcome: AIChatSession.RemoteSubmissionResult?
        XCTAssertTrue(chat.sendRemote("", images: [photo], completion: { outcome = $0 }))
        XCTAssertNil(outcome)
        pipe.finishWrite(.failure(CocoaError(.fileWriteUnknown)))
        XCTAssertEqual(outcome, .uncertain, "A queued write may have partially reached the process")
        XCTAssertEqual(chat.input, "Keep"); XCTAssertEqual(chat.draftImages, [photo])
    }

    func testStoppedOrExitedClaudeWriteCannotPolluteRestartedSession() throws {
        for ending in ["stop", "exit", "restart"] {
            let store = try store(), photo = try store.importImage(data: fixture(), name: "photo.jpg")
            let (chat, pipe) = ready(.claude, store: store)
            pipe.deferUserWrites = true
            var outcome: AIChatSession.RemoteSubmissionResult?
            XCTAssertTrue(chat.sendRemote("", images: [photo], completion: { outcome = $0 }))
            if ending == "exit" { pipe.onExit?(1) }
            else if ending == "stop" { chat.stop() }
            chat.start(AILaunchConfiguration(command: "fixture", environment: [:], executable: "/usr/bin/true"))
            XCTAssertEqual(outcome, .uncertain)
            pipe.respond()
            chat.input = "New process draft"
            pipe.finishWrite()
            XCTAssertTrue(chat.messages.isEmpty)
            XCTAssertEqual(chat.input, "New process draft")
            XCTAssertTrue(chat.isReady); XCTAssertFalse(chat.isBusy)
        }
    }

    func testCodexPhotosUsePersistentLocalImageAndFailureRestoresDraft() throws {
        let store = try store(), image = try store.importImage(data: fixture(), name: "photo.jpg")
        let (chat, pipe) = ready(.openai, store: store)
        chat.input = "Inspect"; chat.draftImages = [image]
        chat.send()
        let params = try XCTUnwrap(pipe.sent.last?["params"] as? [String: Any])
        let content = try XCTUnwrap(params["input"] as? [[String: Any]])
        XCTAssertEqual(content.count, 2)
        XCTAssertEqual(content[0]["text"] as? String, "Inspect")
        XCTAssertEqual(content[1]["type"] as? String, "localImage")
        XCTAssertEqual(content[1]["path"] as? String, try store.url(for: image).path)
        XCTAssertTrue(chat.input.isEmpty); XCTAssertTrue(chat.draftImages.isEmpty)
        pipe.reject()
        XCTAssertEqual(chat.input, "Inspect"); XCTAssertEqual(chat.draftImages, [image])
        XCTAssertFalse(chat.isBusy)
    }

    func testRemotePhotoOnlyPreservesDesktopDraftForBothProviders() throws {
        for provider in AIProvider.allCases {
            let store = try store(), desktop = try store.importImage(data: fixture(), name: "desktop.jpg")
            let remote = try store.importImage(data: fixture(), name: "phone.jpg")
            let (chat, pipe) = ready(provider, store: store)
            chat.input = "Desktop draft"; chat.draftImages = [desktop]
            var result: AIChatSession.RemoteSubmissionResult?
            XCTAssertTrue(chat.sendRemote("", images: [remote], completion: { result = $0 }))
            if provider == .openai { pipe.respond(["turn": ["id": "photo-turn"]]) }
            XCTAssertEqual(result, .accepted)
            XCTAssertEqual(chat.input, "Desktop draft")
            XCTAssertEqual(chat.draftImages, [desktop])
            XCTAssertEqual(chat.visibleMessages.last?.images, [remote])
        }
    }

    func testMissingOrExcessAttachmentsDoNotSendTextOrClearDraft() throws {
        let store = try store(), image = try store.importImage(data: fixture(), name: "photo.jpg")
        let (chat, pipe) = ready(.claude, store: store)
        chat.input = "Keep"; chat.draftImages = [image, image, image, image, image]
        let initial = pipe.sent.count
        chat.send()
        XCTAssertEqual(pipe.sent.count, initial)
        XCTAssertEqual(chat.draftImages.count, 5)
        chat.draftImages = [image]
        try store.remove(image)
        chat.send()
        XCTAssertEqual(pipe.sent.count, initial)
        XCTAssertEqual(chat.input, "Keep"); XCTAssertEqual(chat.draftImages, [image])
        XCTAssertNotNil(chat.errorMessage); XCTAssertFalse(chat.isBusy)
    }

    @MainActor func testImagesAndDraftSurviveHistoryRoundTripWithoutEmbeddingData() throws {
        let history = AIChatHistoryStore(directory: try root()), id = UUID()
        let first = try history.imageStore.importImage(data: fixture(), name: "first.jpg")
        let draft = try history.imageStore.importImage(data: fixture(alpha: true), name: "draft.png")
        let saved = AIChatSnapshot(provider: .claude, directory: "/tmp", model: "model-a", input: "Unsent",
            messages: [AIChatMessage(id: "user-photo", role: .user, text: "", images: [first])],
            conversationID: "saved-photo-session", draftImages: [draft])
        history.save(saved, for: id) { _ in }; history.flush()
        let encoded = try Data(contentsOf: history.directory.appendingPathComponent(id.uuidString + ".json"))
        XCTAssertLessThan(encoded.count, 2000)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("base64"))
        let reopenedStore = AIChatHistoryStore(directory: history.directory)
        let loaded = try XCTUnwrap(reopenedStore.load(for: id))
        XCTAssertEqual(loaded.version, 2, "Older builds must refuse to overwrite photo history")
        let reopened = AIChatSession(provider: .claude, model: "", directory: "/tmp", restoring: loaded, imageStore: reopenedStore.imageStore)
        XCTAssertEqual(reopened.visibleMessages.last?.images, [first])
        XCTAssertEqual(reopened.draftImages, [draft])
        XCTAssertEqual(try reopened.imageStore.data(for: first), try history.imageStore.data(for: first))
        XCTAssertEqual(try reopened.imageStore.data(for: draft), try history.imageStore.data(for: draft))
    }

    func testLegacyHistoryWithoutImageFieldsStillDecodes() throws {
        let json = #"{"version":1,"provider":"claude","directory":"/tmp","model":"a","input":"draft","messages":[{"id":"one","role":"user","text":"old question"}],"conversationID":"old-session"}"#
        let saved = try JSONDecoder().decode(AIChatSnapshot.self, from: Data(json.utf8))
        XCTAssertTrue(saved.draftImages.isEmpty)
        XCTAssertEqual(saved.version, 1)
        XCTAssertTrue(saved.messages[0].images.isEmpty)
        XCTAssertEqual(saved.messages[0].text, "old question")
        XCTAssertTrue(saved.messages[0].isVisibleInTranscript)
    }

    @MainActor func testAddingImageToOldSnapshotPromotesVersionAndUnknownVersionIsRejected() throws {
        let history = AIChatHistoryStore(directory: try root()), id = UUID()
        var snapshot = AIChatSnapshot(provider: .claude, directory: "/tmp", model: "a", input: "",
            messages: [], conversationID: nil)
        history.save(snapshot, for: id) { _ in }; history.flush()
        XCTAssertEqual(try history.load(for: id)?.version, 1)
        snapshot.draftImages = [try history.imageStore.importImage(data: fixture(), name: "photo.jpg")]
        XCTAssertEqual(snapshot.version, 1)
        history.save(snapshot, for: id) { _ in }; history.flush()
        XCTAssertEqual(try history.load(for: id)?.version, 2)
        snapshot.version = 99
        try JSONEncoder().encode(snapshot).write(to: history.directory.appendingPathComponent(id.uuidString + ".json"))
        XCTAssertThrowsError(try history.load(for: id))
    }

    @MainActor func testInstalledCLIsSendPhotosToOfflineGateway() throws {
        for provider in AIProvider.allCases {
            let binary = "/opt/homebrew/bin/" + provider.executable
            guard FileManager.default.isExecutableFile(atPath: binary) else {
                throw XCTSkip("Install Claude Code and Codex for offline protocol coverage")
            }
            let directory = try root()
            let gateway = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/ai_gateway.py")
            let server = Process()
            server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            server.arguments = [gateway.path, directory.path]
            server.standardOutput = FileHandle.nullDevice; server.standardError = FileHandle.nullDevice
            try server.run()
            defer { server.terminate(); server.waitUntilExit() }
            func wait(_ seconds: Double, until predicate: () -> Bool) {
                let deadline = Date().addingTimeInterval(seconds)
                while !predicate(), Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.03)) }
            }
            let portFile = directory.appendingPathComponent("port")
            wait(5) { FileManager.default.fileExists(atPath: portFile.path) }
            let port = try String(contentsOf: portFile, encoding: .utf8)
            let endpoint = "http://127.0.0.1:" + port + (provider == .openai ? "/v1" : "")
            var configuration = try AILaunchConfiguration.make(provider: provider,
                connection: AIConnection(apiKey: "fake-local-photo-key", baseURL: endpoint, model: "fixture-one"), executable: binary)
            configuration.environment["HOME"] = directory.path
            configuration.environment["CLAUDE_CONFIG_DIR"] = directory.appendingPathComponent("claude").path
            let codexDirectory = directory.appendingPathComponent("codex")
            try FileManager.default.createDirectory(at: codexDirectory, withIntermediateDirectories: true)
            configuration.environment["CODEX_HOME"] = codexDirectory.path
            configuration.environment["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"] = "1"
            configuration.environment["DISABLE_AUTOUPDATER"] = "1"
            let store = AIChatImageStore(directory: directory.appendingPathComponent("images"))
            let photo = try store.importImage(data: fixture(), name: "offline.jpg")
            let expectedHash = SHA256.hash(data: try store.data(for: photo)).map { String(format: "%02x", $0) }.joined()
            let chat = AIChatSession(provider: provider, model: "fixture-one", directory: directory.path, imageStore: store)
            defer { chat.stop() }
            chat.start(configuration)
            wait(20) { chat.isReady || chat.errorMessage != nil }
            XCTAssertTrue(chat.isReady, chat.errorMessage ?? "Protocol not ready")
            guard chat.isReady else { continue }
            for prompt in ["Describe this offline image", ""] {
                chat.input = prompt; chat.draftImages = [photo]; chat.send()
                wait(25) { !chat.isBusy }
                XCTAssertFalse(chat.isBusy); XCTAssertNil(chat.errorMessage)
                XCTAssertEqual(chat.messages.last(where: { $0.role == .user })?.images, [photo])
                let lines = try String(contentsOf: directory.appendingPathComponent("requests.jsonl"), encoding: .utf8)
                let requests = try lines.split(separator: "\n").map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
                let images = try XCTUnwrap(requests.last?["images"] as? [[String: Any]])
                XCTAssertTrue(images.contains { $0["sha256"] as? String == expectedHash }, "\(provider): actual provider request must contain normalized image bytes")
            }
        }
    }
}
