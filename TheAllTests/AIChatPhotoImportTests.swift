import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
import SwiftUI
@testable import TheAll

final class AIChatPhotoImportTests: XCTestCase {
    private func png() throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 12, pixelsHigh: 8,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let teal = NSColor(deviceRed: 0.08, green: 0.7, blue: 0.65, alpha: 1)
        let blue = NSColor(deviceRed: 0.15, green: 0.4, blue: 0.9, alpha: 1)
        for y in 0..<8 {
            for x in 0..<12 { bitmap.setColor(x < 6 ? teal : blue, atX: x, y: y) }
        }
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }

    func testImageClipboardIsRecognizedWithoutInterceptingOrdinaryText() throws {
        let board = NSPasteboard(name: .init("TheAllPhotoImportTests-" + UUID().uuidString))
        defer { board.releaseGlobally() }
        board.setString("Keep this draft", forType: .string)
        XCTAssertNil(AIChatPhotoImport.read(board))
        board.clearContents()
        board.setData(try png(), forType: .png)
        let images = try XCTUnwrap(AIChatPhotoImport.read(board))
        XCTAssertEqual(images.count, 1)
        guard case .data(let data, _) = images[0] else { return XCTFail("Expected image bytes") }
        XCTAssertNotNil(CGImageSourceCreateWithData(data as CFData, nil))
    }

    func testFailedBatchDoesNotKeepEarlierImportedPhotos() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AIChatImageStore(directory: directory)
        XCTAssertThrowsError(try AIChatPhotoImport.importBatch([
            .data(try png(), name: "first.png"), .data(Data("not an image".utf8), name: "second.png")
        ], store: store))
        let remaining = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        XCTAssertTrue(remaining.isEmpty, "A failed selection must not leave an orphaned first attachment")
    }

    func testFinderDropKeepsOrderAndPrefersFilesOverDuplicateImageRepresentation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AIChatImageStore(directory: directory.appendingPathComponent("Attachments"))
        let urls = ["first.png", "second.png"].map { directory.appendingPathComponent($0) }
        let providers = try urls.map { url -> NSItemProvider in
            try png().write(to: url)
            let provider = NSItemProvider(item: url as NSURL, typeIdentifier: UTType.fileURL.identifier)
            provider.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) { completion in
                XCTFail("File URL must take precedence over the same image's alternate representation")
                completion(nil, CocoaError(.fileReadUnknown)); return nil
            }
            return provider
        }
        let images = try await AIChatPhotoImport.importProviders(providers, store: store)
        XCTAssertEqual(images.map(\.name), ["first.png", "second.png"])
        XCTAssertEqual(images.count, 2)
        for image in images { XCTAssertFalse(try store.data(for: image).isEmpty) }
    }

    func testTemporaryImageRepresentationSurvivesProviderFileRemoval() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("temporary-photo.png")
        try png().write(to: source)
        let provider = NSItemProvider()
        provider.registerFileRepresentation(forTypeIdentifier: UTType.png.identifier, fileOptions: [], visibility: .all) { completion in
            completion(source, false, nil)
            try? FileManager.default.removeItem(at: source)
            return nil
        }
        let store = AIChatImageStore(directory: directory.appendingPathComponent("Attachments"))
        let images = try await AIChatPhotoImport.importProviders([provider], store: store)
        XCTAssertEqual(images.count, 1)
        XCTAssertFalse(try store.data(for: images[0]).isEmpty)
    }

    func testMixedDropRollsBackPhotosAndTooManyProvidersAreNotLoaded() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AIChatImageStore(directory: directory)
        let data = try png()
        let photo = NSItemProvider(item: data as NSData, typeIdentifier: UTType.png.identifier)
        let text = NSItemProvider(item: "not a photo" as NSString, typeIdentifier: UTType.utf8PlainText.identifier)
        do {
            _ = try await AIChatPhotoImport.importProviders([photo, text], store: store)
            XCTFail("Mixed photo/text drop must fail as a batch")
        } catch {}
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [], [])
        let unread = NSItemProvider()
        unread.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) { completion in
            XCTFail("Count must be checked before requesting data")
            completion(data, nil); return nil
        }
        do {
            _ = try await AIChatPhotoImport.importProviders(Array(repeating: unread, count: 5), store: store)
            XCTFail("More than four photos must fail")
        } catch AIChatImageStore.ImageError.tooMany {} catch { XCTFail("Unexpected error: \(error)") }
    }

    @MainActor
    func testNativeEditorDropAddsPhotosWithoutChangingTextSelectionOrSending() throws {
        let board = NSPasteboard(name: .init("TheAllPhotoDropTests-" + UUID().uuidString))
        defer { board.releaseGlobally() }
        board.setData(try png(), forType: .png)
        let editor = AIChatComposer.Editor(frame: NSRect(x: 0, y: 0, width: 420, height: 88))
        editor.isRichText = false
        let window = NSWindow(contentRect: editor.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = editor
        window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        editor.updateDragTypeRegistration()
        editor.string = "Keep my draft 🐈"
        let selection = NSRange(location: 5, length: 2)
        editor.setSelectedRange(selection)
        var imports = 0, sends = 0
        var highlights: [Bool] = []
        editor.onSend = { sends += 1 }
        editor.onPhotoDragTargeted = { highlights.append($0) }
        editor.onPasteImages = { pasteboard in
            XCTAssertEqual(AIChatPhotoImport.read(pasteboard)?.count, 1)
            imports += 1; return true
        }
        let drag = PhotoDragInfo(board)
        drag.draggingDestinationWindow = window
        XCTAssertTrue(editor.acceptableDragTypes.contains(.fileURL))
        XCTAssertEqual(editor.draggingEntered(drag), .copy)
        XCTAssertEqual(editor.draggingUpdated(drag), .copy)
        XCTAssertTrue(editor.prepareForDragOperation(drag))
        XCTAssertTrue(editor.performDragOperation(drag))
        XCTAssertEqual(imports, 1)
        XCTAssertEqual(sends, 0)
        XCTAssertEqual(editor.string, "Keep my draft 🐈")
        XCTAssertEqual(editor.selectedRange(), selection)
        XCTAssertEqual(highlights.first, true)
        XCTAssertEqual(highlights.last, false)
        editor.acceptsPhotoDrops = false
        XCTAssertEqual(editor.dragOperation(for: drag, type: .png), [])
        XCTAssertFalse(editor.performDragOperation(drag))
        XCTAssertEqual(imports, 1)
        board.clearContents()
        board.setString("ordinary text", forType: .string)
        XCTAssertFalse(AIChatPhotoImport.containsImages(board))
        editor.acceptsPhotoDrops = true
        XCTAssertEqual(editor.draggingEntered(drag), .copy)
        XCTAssertTrue(editor.prepareForDragOperation(drag))
        XCTAssertTrue(editor.performDragOperation(drag))
        XCTAssertTrue(editor.string.contains("ordinary text"))
        XCTAssertEqual(imports, 1)
        XCTAssertEqual(sends, 0)
    }

    @MainActor
    func testPhotoHistoryAndFourDraftThumbnailsKeepComposerVisibleInNarrowWindow() async throws {
        final class Credentials: AICredentialStore {
            func load(for provider: AIProvider) throws -> AIConnection? { nil }
            func save(_ connection: AIConnection, for provider: AIProvider) throws {}
            func delete(for provider: AIProvider) throws {}
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AIChatImageStore(directory: directory)
        let photo = try store.importImage(data: png(), name: "color-study.png")
        let draft = try (1...4).map { try store.importImage(data: png(), name: "photo-\($0).png") }
        let snapshot = AIChatSnapshot(provider: .claude, directory: "/tmp/example-project", model: "model-a",
            input: "Compare these photos.", messages: [AIChatMessage(id: "question", role: .user,
            text: "What colors are in this photo?", images: [photo])], conversationID: "fixture", draftImages: draft)
        let chat = AIChatSession(provider: .claude, model: "model-a", directory: snapshot.directory,
            restoring: snapshot, imageStore: store)
        let session = AITerminalSession(credentials: Credentials(), loadModels: { _, _ in [] })
        let hosting = NSHostingView(rootView: AIChatView(session: session, chat: chat, onFocus: {}, onEdit: {}))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 640),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        try await Task.sleep(nanoseconds: 500_000_000)
        hosting.layoutSubtreeIfNeeded()
        func editors(_ view: NSView) -> [NSTextView] {
            (view as? NSTextView).map { [$0] } ?? view.subviews.flatMap(editors)
        }
        let editor = try XCTUnwrap(editors(hosting).first(where: \.isEditable))
        let rect = editor.convert(editor.bounds, to: hosting)
        XCTAssertGreaterThanOrEqual(rect.minX, 0)
        XCTAssertLessThanOrEqual(rect.maxX, hosting.bounds.width)
        XCTAssertGreaterThan(rect.minY, 0)
        XCTAssertLessThan(rect.maxY, hosting.bounds.height)
        XCTAssertEqual(editor.string, snapshot.input)
        XCTAssertEqual(chat.draftImages.count, 4)
        let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let attachment = XCTAttachment(data: try XCTUnwrap(bitmap.representation(using: .png, properties: [:])),
            uniformTypeIdentifier: "public.png")
        attachment.name = "TheAll photo history and four draft attachments at 420px"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

@MainActor
private final class PhotoDragInfo: NSObject, NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    init(_ pasteboard: NSPasteboard) { draggingPasteboard = pasteboard }
    var draggingDestinationWindow: NSWindow?
    var draggingSourceOperationMask: NSDragOperation { .copy }
    var draggingLocation: NSPoint { NSPoint(x: 20, y: 20) }
    var draggedImageLocation: NSPoint { .zero }
    var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
    func resetSpringLoading() {}
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?,
        classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
        using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {
        let objects = draggingPasteboard.readObjects(forClasses: classArray, options: searchOptions) ?? []
        var stop = ObjCBool(false)
        for (index, object) in objects.enumerated() {
            guard let writer = object as? NSPasteboardWriting else { continue }
            block(NSDraggingItem(pasteboardWriter: writer), index, &stop)
            if stop.boolValue { break }
        }
    }
}
