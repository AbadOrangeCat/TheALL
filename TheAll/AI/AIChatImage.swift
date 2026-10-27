import Foundation
import ImageIO
import UniformTypeIdentifiers
import Darwin

/// History stores references only; image bytes live in the app's private store.
struct AIChatImage: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let name: String
    let mimeType: String
    let width: Int
    let height: Int
}

/// Converts user-selected images to bounded, oriented, metadata-free images.
/// Safe to import on a worker: each file has an independent random identifier.
final class AIChatImageStore: @unchecked Sendable {
    static let maximumCount = 4
    static let maximumInputBytes = 20 * 1024 * 1024
    static let maximumStoredBytes = 2 * 1024 * 1024
    static let maximumDimension = 2048
    static let shared = AIChatImageStore()
    let directory: URL

    init(directory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.theall.app.dev")
        .appendingPathComponent("ChatHistory/Attachments")) {
        self.directory = directory
    }

    func importImage(at url: URL) throws -> AIChatImage {
        guard url.isFileURL else { throw ImageError.invalid }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let data = try readBounded(url, maximum: Self.maximumInputBytes, error: .invalid)
        return try importImage(data: data, name: url.lastPathComponent)
    }

    func importImage(data: Data, name: String) throws -> AIChatImage {
        guard !data.isEmpty else { throw ImageError.invalid }
        guard data.count <= Self.maximumInputBytes else { throw ImageError.tooLarge }
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let type = CGImageSourceGetType(source), UTType(type as String)?.conforms(to: .image) == true,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { throw ImageError.invalid }
        // Reject decompression bombs before creating any raster or thumbnail.
        guard width <= 50_000, height <= 50_000, Int64(width) * Int64(height) <= 100_000_000
        else { throw ImageError.tooLarge }
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Self.maximumDimension,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary) else { throw ImageError.invalid }
        let hasAlpha = [.first, .last, .premultipliedFirst, .premultipliedLast].contains(thumbnail.alphaInfo)
        let mimeType = hasAlpha ? "image/png" : "image/jpeg"
        var dimension = max(thumbnail.width, thumbnail.height)
        var encoded: Data?
        var raster: CGImage?
        // PNG screenshots with alpha can still be large; reduce dimensions to
        // meet the same bound without silently dropping transparency.
        while true {
            let scale = min(1, Double(dimension) / Double(max(thumbnail.width, thumbnail.height)))
            let w = max(1, Int(Double(thumbnail.width) * scale)), h = max(1, Int(Double(thumbnail.height) * scale))
            let bitmapInfo = hasAlpha ? CGImageAlphaInfo.premultipliedLast.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
            guard let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: bitmapInfo)
            else { throw ImageError.invalid }
            context.interpolationQuality = .high
            context.draw(thumbnail, in: CGRect(x: 0, y: 0, width: w, height: h))
            guard let image = context.makeImage() else { throw ImageError.invalid }
            let bytes = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(bytes, (hasAlpha ? UTType.png : UTType.jpeg).identifier as CFString, 1, nil)
            else { throw ImageError.invalid }
            // Drawing into a fresh raster and providing only encoder options
            // excludes original EXIF, GPS, IPTC and camera metadata.
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { throw ImageError.invalid }
            if bytes.length <= Self.maximumStoredBytes { encoded = bytes as Data; raster = image; break }
            guard dimension > 128 else { throw ImageError.tooLarge }
            dimension = max(128, Int(Double(dimension) * 0.75))
        }
        guard let encoded, let raster else { throw ImageError.tooLarge }
        let displayName = String((name as NSString).lastPathComponent
            .unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.map(String.init).joined().prefix(160))
        let attachment = AIChatImage(id: UUID(), name: displayName.isEmpty ? "Photo" : displayName,
            mimeType: mimeType, width: raster.width, height: raster.height)
        do {
            try prepareDirectory()
            let url = try file(for: attachment)
            try encoded.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch { throw ImageError.saveFailed }
        return attachment
    }

    func url(for image: AIChatImage) throws -> URL {
        let url = try file(for: image)
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size > 0, size <= Self.maximumStoredBytes else { throw ImageError.unavailable }
        guard (try? directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true
        else { throw ImageError.unavailable }
        return url
    }

    func data(for image: AIChatImage) throws -> Data {
        let data = try readBounded(url(for: image), maximum: Self.maximumStoredBytes, error: .unavailable)
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let type = CGImageSourceGetType(source),
              (type as String) == (image.mimeType == "image/png" ? UTType.png.identifier : UTType.jpeg.identifier),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              properties[kCGImagePropertyPixelWidth] as? Int == image.width,
              properties[kCGImagePropertyPixelHeight] as? Int == image.height else { throw ImageError.unavailable }
        return data
    }

    /// The caller must own this unreferenced import. Never delete attachments
    /// belonging to accepted or uncertain submissions, drafts or saved history.
    func remove(_ image: AIChatImage) throws {
        try FileManager.default.removeItem(at: url(for: image))
    }

    private func file(for image: AIChatImage) throws -> URL {
        guard ["image/jpeg", "image/png"].contains(image.mimeType), image.width > 0, image.height > 0,
              image.width <= Self.maximumDimension, image.height <= Self.maximumDimension else { throw ImageError.invalid }
        return directory.appendingPathComponent(image.id.uuidString + (image.mimeType == "image/png" ? ".png" : ".jpg"))
    }

    private func prepareDirectory() throws {
        let manager = FileManager.default
        if manager.fileExists(atPath: directory.path) {
            let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { throw ImageError.saveFailed }
        } else {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    private func readBounded(_ url: URL, maximum: Int, error: ImageError) throws -> Data {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw error }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var attributes = stat()
        guard fstat(descriptor, &attributes) == 0, (attributes.st_mode & S_IFMT) == S_IFREG,
              attributes.st_size > 0 else { throw error }
        guard attributes.st_size <= maximum else { throw ImageError.tooLarge }
        guard let data = try? handle.read(upToCount: maximum + 1), !data.isEmpty else { throw error }
        guard data.count <= maximum else { throw ImageError.tooLarge }
        return data
    }

    enum ImageError: LocalizedError {
        case invalid, tooLarge, tooMany, unavailable, saveFailed
        var errorDescription: String? {
            switch self {
            case .invalid: return L10n.string("ai.images.invalid")
            case .tooLarge: return L10n.string("ai.images.tooLarge")
            case .tooMany: return L10n.string("ai.images.tooMany")
            case .unavailable: return L10n.string("ai.images.unavailable")
            case .saveFailed: return L10n.string("ai.images.saveFailed")
            }
        }
    }
}
