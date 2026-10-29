import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum AIChatAttachmentImport: Sendable {
    case file(URL)
    case imageData(Data, name: String)

    struct Batch: Sendable {
        var images: [AIChatImage] = []
        var files: [AIChatFile] = []
        func validate() throws {
            guard images.count <= AIChatImageStore.maximumCount else { throw AIChatImageStore.ImageError.tooMany }
            try AIChatFileStore.validate(files)
        }
        func discard(imageStore: AIChatImageStore, fileStore: AIChatFileStore) {
            images.forEach { try? imageStore.remove($0) }
            files.forEach { try? fileStore.remove($0) }
        }
    }

    static func isPhoto(_ url: URL) -> Bool {
        ["jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "avif", "bmp", "tif", "tiff"].contains(url.pathExtension.lowercased())
    }

    static func containsAttachments(_ pasteboard: NSPasteboard) -> Bool {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty { return true }
        return AIChatPhotoImport.containsImages(pasteboard)
    }

    static func read(_ pasteboard: NSPasteboard) -> [Self]? {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            guard urls.count == pasteboard.pasteboardItems?.count else { return nil }
            return urls.map(Self.file)
        }
        return AIChatPhotoImport.read(pasteboard)?.map {
            switch $0 { case .file(let url): return .file(url); case .data(let data, let name): return .imageData(data, name: name) }
        }
    }

    static func importBatch(_ sources: [Self], imageStore: AIChatImageStore, fileStore: AIChatFileStore) throws -> Batch {
        guard sources.count <= AIChatImageStore.maximumCount + AIChatFileStore.maximumCount else { throw AIChatFileStore.FileError.tooMany }
        var result = Batch()
        do {
            for source in sources {
                switch source {
                case .file(let url):
                    if isPhoto(url) { result.images.append(try imageStore.importImage(at: url)) }
                    else { result.files.append(try fileStore.importFile(at: url)) }
                case .imageData(let data, let name): result.images.append(try imageStore.importImage(data: data, name: name))
                }
                try result.validate()
            }
            return result
        } catch { result.discard(imageStore: imageStore, fileStore: fileStore); throw error }
    }

    static func importProviders(_ providers: [NSItemProvider], imageStore: AIChatImageStore, fileStore: AIChatFileStore) async throws -> Batch {
        guard providers.count <= AIChatImageStore.maximumCount + AIChatFileStore.maximumCount else { throw AIChatFileStore.FileError.tooMany }
        var result = Batch()
        do {
            for provider in providers {
                if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                    let url: URL = try await withCheckedThrowingContinuation { continuation in
                        provider.loadObject(ofClass: NSURL.self) { object, error in
                            guard error == nil, let url = object as? URL, url.isFileURL else { continuation.resume(throwing: AIChatFileStore.FileError.invalid); return }
                            continuation.resume(returning: url)
                        }
                    }
                    let imported = try await Task.detached(priority: .userInitiated) {
                        try importBatch([.file(url)], imageStore: imageStore, fileStore: fileStore)
                    }.value
                    result.images += imported.images; result.files += imported.files
                } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier),
                          !provider.hasItemConformingToTypeIdentifier(UTType.svg.identifier) {
                    result.images += try await AIChatPhotoImport.importProviders([provider], store: imageStore)
                } else {
                    guard let type = provider.registeredTypeIdentifiers.first(where: { UTType($0)?.conforms(to: .data) == true }) else { throw AIChatFileStore.FileError.invalid }
                    let file: AIChatFile = try await withCheckedThrowingContinuation { continuation in
                        provider.loadFileRepresentation(forTypeIdentifier: type) { url, error in
                            guard let url, error == nil else { continuation.resume(throwing: AIChatFileStore.FileError.invalid); return }
                            // File-provider temporary URLs expire after this callback.
                            continuation.resume(with: Result { try fileStore.importFile(at: url, name: provider.suggestedName) })
                        }
                    }
                    result.files.append(file)
                }
                try result.validate()
            }
            return result
        } catch { result.discard(imageStore: imageStore, fileStore: fileStore); throw error }
    }
}

struct AIChatFiles: View {
    let files: [AIChatFile]
    let store: AIChatFileStore
    let theme: AppTheme
    var onRemove: ((AIChatFile) -> Void)?
    @State private var unavailable = false

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 180, maximum: 300), alignment: .leading)], alignment: .leading, spacing: 6) {
            ForEach(files) { file in
                HStack(spacing: 8) {
                    Button {
                        do { NSWorkspace.shared.activateFileViewerSelecting([try store.url(for: file)]) }
                        catch { unavailable = true }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "doc")
                            VStack(alignment: .leading, spacing: 2) {
                                Text(file.name).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                                Text(ByteCountFormatter.string(fromByteCount: Int64(file.byteCount), countStyle: .file))
                                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(Color(nsColor: theme.textSecondary))
                            }
                            Spacer(minLength: 0)
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain).help(L10n.string("ai.files.reveal"))
                    if let onRemove {
                        Button { onRemove(file) } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).help(L10n.string("ai.files.remove"))
                            .accessibilityLabel(L10n.string("ai.files.remove") + " " + file.name)
                    }
                }.padding(8).frame(maxWidth: 300, alignment: .leading)
                    .background(Color(nsColor: theme.sidebar), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: theme.border), lineWidth: 1))
            }
        }.foregroundStyle(Color(nsColor: theme.textPrimary))
            .alert(L10n.string("ai.files.unavailable"), isPresented: $unavailable) {
                Button(L10n.string("ai.images.close"), role: .cancel) {}
            }
    }
}
