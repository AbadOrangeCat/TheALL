import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// Only image clipboard contents are intercepted; text and ordinary file pastes
/// remain native. Imports run away from the UI thread and commit as one batch.
enum AIChatPhotoImport: Sendable {
    case file(URL)
    case data(Data, name: String)

    static let draggedTypes: [NSPasteboard.PasteboardType] = [.fileURL, .png, .tiff,
        .init(UTType.jpeg.identifier), .init(UTType.heic.identifier)]

    /// Inspect types and file names only while hovering; decoding happens on drop.
    static func containsImages(_ pasteboard: NSPasteboard) -> Bool {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            if urls.contains(where: { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .image) == true }) { return true }
        }
        return pasteboard.availableType(from: Array(draggedTypes.dropFirst())) != nil
    }

    static func read(_ pasteboard: NSPasteboard) -> [Self]? {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            guard urls.count == pasteboard.pasteboardItems?.count,
                  urls.allSatisfy({ UTType(filenameExtension: $0.pathExtension)?.conforms(to: .image) == true }) else { return nil }
            return urls.map(Self.file)
        }
        let items = pasteboard.pasteboardItems ?? []
        let images: [Self] = items.compactMap { item in
            guard let type = item.availableType(from: Array(draggedTypes.dropFirst())),
                  let data = item.data(forType: type) else { return nil }
            return .data(data, name: L10n.string("ai.images.defaultName"))
        }
        return !images.isEmpty && images.count == items.count ? images : nil
    }

    /// Preserve drop order and roll back the entire selection on any failure.
    /// Import temporary file representations before their callback returns.
    static func importProviders(_ providers: [NSItemProvider], store: AIChatImageStore) async throws -> [AIChatImage] {
        guard providers.count <= AIChatImageStore.maximumCount else { throw AIChatImageStore.ImageError.tooMany }
        var images: [AIChatImage] = []
        do {
            for provider in providers {
                if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                    let url: URL = try await withCheckedThrowingContinuation { continuation in
                        provider.loadObject(ofClass: NSURL.self) { object, error in
                            guard error == nil, let url = object as? URL, url.isFileURL,
                                  UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true
                            else { continuation.resume(throwing: AIChatImageStore.ImageError.invalid); return }
                            continuation.resume(returning: url)
                        }
                    }
                    images.append(try await Task.detached(priority: .userInitiated) {
                        try store.importImage(at: url)
                    }.value)
                } else {
                    guard let type = provider.registeredTypeIdentifiers.first(where: {
                        UTType($0)?.conforms(to: .image) == true
                    }) else { throw AIChatImageStore.ImageError.invalid }
                    let image: AIChatImage = try await withCheckedThrowingContinuation { continuation in
                        provider.loadFileRepresentation(forTypeIdentifier: type) { url, error in
                            if let url, error == nil {
                                continuation.resume(with: Result { try store.importImage(at: url) })
                            } else {
                                provider.loadDataRepresentation(forTypeIdentifier: type) { data, error in
                                    guard error == nil, let data else {
                                        continuation.resume(throwing: AIChatImageStore.ImageError.invalid); return
                                    }
                                    continuation.resume(with: Result {
                                        try store.importImage(data: data, name: provider.suggestedName ?? "Photo")
                                    })
                                }
                            }
                        }
                    }
                    images.append(image)
                }
            }
            return images
        } catch {
            for image in images { try? store.remove(image) }
            throw error
        }
    }

    static func importBatch(_ sources: [Self], store: AIChatImageStore) throws -> [AIChatImage] {
        var imported: [AIChatImage] = []
        do {
            for source in sources {
                switch source {
                case .file(let url):
                    imported.append(try store.importImage(at: url))
                case .data(let data, let name):
                    imported.append(try store.importImage(data: data, name: name))
                }
            }
            return imported
        } catch {
            for image in imported { try? store.remove(image) }
            throw error
        }
    }
}

struct AIChatPhotos: View {
    let images: [AIChatImage]
    let store: AIChatImageStore
    let theme: AppTheme
    var onOpen: (AIChatImage) -> Void
    var onRemove: ((AIChatImage) -> Void)? = nil

    var body: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 10) {
                ForEach(images) { image in
                    VStack(alignment: .leading, spacing: 4) {
                        Button { onOpen(image) } label: {
                            AIChatPhotoBitmap(image: image, store: store, theme: theme, maximumPixel: 256)
                                .frame(width: 112, height: 80)
                                .background(Color(nsColor: theme.canvas))
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: theme.border)))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(L10n.string("ai.images.preview") + ": " + image.name)
                        HStack(spacing: 4) {
                            Text(image.name).font(.caption2).lineLimit(1).truncationMode(.middle)
                            if let onRemove {
                                Button { onRemove(image) } label: { Image(systemName: "xmark.circle.fill") }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel(L10n.string("ai.images.remove") + ": " + image.name)
                                    .help(L10n.string("ai.images.remove"))
                            }
                        }
                        .foregroundStyle(Color(nsColor: theme.textSecondary)).frame(width: 112)
                    }
                }
            }.padding(.vertical, 2)
        }.scrollIndicators(.hidden).fixedSize(horizontal: false, vertical: true)
    }
}

private struct AIChatPhotoBitmap: View {
    let image: AIChatImage
    let store: AIChatImageStore
    let theme: AppTheme
    let maximumPixel: Int
    @State private var bitmap: CGImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let bitmap {
                Image(decorative: bitmap, scale: 1).resizable().scaledToFit()
            } else if failed {
                Label(L10n.string("ai.images.unavailable"), systemImage: "photo")
                    .font(.caption).foregroundStyle(Color(nsColor: theme.textSecondary)).padding(6)
            } else { ProgressView().controlSize(.small) }
        }
        .task(id: image.id) {
            let result = await Task.detached(priority: .utility) {
                guard let data = try? store.data(for: image),
                      let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil as CGImage? }
                return CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: maximumPixel
                ] as CFDictionary)
            }.value
            guard !Task.isCancelled else { return }
            bitmap = result
            failed = result == nil
        }
    }
}

struct AIChatPhotoPreview: View {
    let image: AIChatImage
    let store: AIChatImageStore
    let theme: AppTheme
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text(image.name).font(.headline).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button(L10n.string("ai.images.close")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
            AIChatPhotoBitmap(image: image, store: store, theme: theme,
                maximumPixel: AIChatImageStore.maximumDimension)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(16).frame(minWidth: 480, idealWidth: 720, maxWidth: 900, minHeight: 360, idealHeight: 540, maxHeight: 700)
        .background(Color(nsColor: theme.canvas)).foregroundStyle(Color(nsColor: theme.textPrimary))
        .tint(Color(nsColor: theme.accent)).environment(\.colorScheme, theme.isDark ? .dark : .light)
    }
}
