import AppKit
import SwiftUI
import ImageIO

/// Message text remains Markdown in history. Only its presentation changes.
struct AIChatMarkdown: View, Equatable {
    let text: String
    let directory: String
    let theme: AppTheme

    var body: some View {
        let groups = AIChatMarkdownDocument(text).selectionGroups
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                switch group[0] {
                case .text: AIChatSelectableProse(blocks: group, theme: theme)
                case .code(let code, let language): AIChatCodeBlock(code: code, language: language, theme: theme)
                case .table(let headers, let rows, let alignments):
                    AIChatMarkdownTable(headers: headers, rows: rows, alignments: alignments, theme: theme)
                case .image(let alt, let destination):
                    AIChatMarkdownImage(alt: alt, destination: destination, directory: directory, theme: theme)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .tint(Color(nsColor: theme.accent))
        .environment(\.openURL, OpenURLAction { url in
            AIChatMarkdownDocument.isWebLink(url) ? .systemAction : .discarded
        })
    }
}

/// One text storage for adjacent paragraphs, headings and list items: selection
/// belongs to AppKit and can cross their boundaries, including wrapped lines.
struct AIChatSelectableProse: NSViewRepresentable {
    let blocks: [AIChatMarkdownDocument.Content]
    let theme: AppTheme

    final class TextView: NSTextView, NSTextViewDelegate {
        func synchronize(_ content: NSAttributedString) {
            guard textStorage?.isEqual(to: content) != true else { return }
            let ranges = selectedRanges.map(\.rangeValue)
            textStorage?.setAttributedString(content)
            selectedRanges = ranges.map { range in
                let start = min(range.location, content.length)
                return NSValue(range: NSRange(location: start, length: min(range.length, content.length - start)))
            }
        }
        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            guard let url = link as? URL, AIChatMarkdownDocument.isWebLink(url) else { return true }
            return false
        }
    }

    func makeNSView(context: Context) -> TextView {
        let view = TextView(frame: .zero)
        view.isEditable = false; view.isSelectable = true; view.isRichText = true
        view.drawsBackground = false; view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = false
        view.isVerticallyResizable = false; view.isHorizontallyResizable = false
        view.isAutomaticLinkDetectionEnabled = false
        view.delegate = view
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }

    func updateNSView(_ view: TextView, context: Context) {
        view.linkTextAttributes = [.foregroundColor: theme.accent, .underlineStyle: NSUnderlineStyle.single.rawValue]
        view.synchronize(Self.attributedText(blocks, theme: theme))
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: TextView, context: Context) -> NSSize? {
        let width = max(1, proposal.width ?? 320)
        guard let container = nsView.textContainer, let layout = nsView.layoutManager else { return nil }
        container.size = NSSize(width: width, height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        return NSSize(width: width, height: ceil(layout.usedRect(for: container).height))
    }

    static func attributedText(_ blocks: [AIChatMarkdownDocument.Content], theme: AppTheme) -> NSAttributedString {
        let result = NSMutableAttributedString(string: "")
        for block in blocks {
            guard case let .text(content, style) = block else { continue }
            if result.length > 0 { result.append(NSAttributedString(string: "\n", attributes: result.attributes(at: result.length - 1, effectiveRange: nil))) }
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 4; paragraph.paragraphSpacing = 14
            var prefix = "", size: CGFloat = 14, weight = NSFont.Weight.regular, color = theme.textPrimary
            switch style {
            case .heading(let level): size = level <= 2 ? 18 : 16; weight = .semibold; paragraph.paragraphSpacingBefore = 6
            case .list(let marker, let depth):
                let indent = CGFloat(min(depth, 8)) * 16
                prefix = marker.isEmpty ? "" : marker + "\t"
                paragraph.firstLineHeadIndent = marker.isEmpty ? indent + 22 : indent
                paragraph.headIndent = indent + max(22, (marker as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: size)]).width + 8)
                paragraph.tabStops = [NSTextTab(textAlignment: .left, location: paragraph.headIndent)]
            case .quote:
                color = theme.textSecondary
                let border = NSTextBlock()
                border.setWidth(3, type: .absoluteValueType, for: .border, edge: .minX)
                border.setBorderColor(theme.borderStrong, for: .minX)
                border.setWidth(12, type: .absoluteValueType, for: .padding, edge: .minX)
                paragraph.textBlocks = [border]
            case .paragraph: break
            }
            let base: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color, .paragraphStyle: paragraph]
            result.append(NSAttributedString(string: prefix, attributes: base))
            for run in content.runs {
                var attributes = base
                let intent = run.inlinePresentationIntent ?? []
                var font = intent.contains(.code) ? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular) : NSFont.systemFont(ofSize: size, weight: weight)
                if intent.contains(.stronglyEmphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
                if intent.contains(.emphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
                attributes[.font] = font
                if intent.contains(.code) { attributes[.backgroundColor] = theme.surface }
                if intent.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
                if let url = run.link, AIChatMarkdownDocument.isWebLink(url) { attributes[.link] = url }
                result.append(NSAttributedString(string: String(content[run.range].characters), attributes: attributes))
            }
        }
        return result
    }
}

struct AIChatCopyButton: View {
    let text: String
    let label: String
    let identifier: String
    @State private var copied = false

    static func copy(_ text: String, to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
    var body: some View {
        Button {
            Self.copy(text, to: .general); copied = true
        } label: {
            Label(L10n.string(copied ? "ai.markdown.copied" : label), systemImage: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 11))
        }.buttonStyle(.plain).accessibilityIdentifier(identifier)
            .task(id: copied) {
                guard copied else { return }
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                copied = false
            }
    }
}

struct AIChatCodeBlock: View {
    let code: String
    let language: String
    let theme: AppTheme
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(language.isEmpty ? L10n.string("ai.markdown.code") : language)
                    .font(.system(size: 11, weight: .medium, design: .monospaced)).lineLimit(1)
                Spacer(minLength: 4)
                AIChatCopyButton(text: code, label: "ai.markdown.copyCode", identifier: "chat-copy-code")
            }
            .foregroundStyle(Color(nsColor: theme.textSecondary)).padding(.horizontal, 12).padding(.vertical, 9)
            .background(Color(nsColor: theme.sidebar))
            Rectangle().fill(Color(nsColor: theme.border)).frame(height: 1)
            AIChatHorizontalOverflow {
                Text(verbatim: code).font(.system(size: 13, design: .monospaced)).lineSpacing(4)
                    .textSelection(.enabled).fixedSize(horizontal: true, vertical: true).padding(12)
            }.fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("chat-code-scroll")
        }
        .background(Color(nsColor: theme.surface))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: theme.border), lineWidth: 1))
    }
}

struct AIChatMarkdownTable: View {
    let headers: [AttributedString]
    let rows: [[AttributedString]]
    let alignments: [AIChatMarkdownDocument.ColumnAlignment]
    let theme: AppTheme
    @State private var availableWidth: CGFloat = 0

    private var widths: [CGFloat] {
        let natural = headers.indices.map { column in
            let values = [headers[column]] + rows.map { $0[column] }
            let natural = values.map { (String($0.characters) as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13)]).width }.max() ?? 0
            return min(310, max(120, natural + 24))
        }
        let extra = max(0, availableWidth - natural.reduce(0, +)) / CGFloat(max(1, headers.count))
        return natural.map { $0 + extra }
    }

    var body: some View {
        let widths = widths
        AIChatHorizontalOverflow {
            VStack(spacing: 0) {
                row(headers, widths: widths, header: true)
                    .background(Color(nsColor: theme.sidebar))
                ForEach(rows.indices, id: \.self) { index in
                    Rectangle().fill(Color(nsColor: theme.border)).frame(height: 1)
                    row(rows[index], widths: widths, header: false)
                        .background(Color(nsColor: index.isMultiple(of: 2) ? theme.surface : theme.sidebar))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: theme.border), lineWidth: 1))
            .padding(.bottom, 5)
        }.fixedSize(horizontal: false, vertical: true)
            .background {
                GeometryReader { geometry in
                    Color.clear.onAppear { availableWidth = geometry.size.width }
                        .onChange(of: geometry.size.width) { _, width in availableWidth = width }
                }
            }
            .accessibilityLabel(L10n.string("ai.markdown.table"))
            .accessibilityIdentifier("chat-table-scroll")
    }

    private func row(_ cells: [AttributedString], widths: [CGFloat], header: Bool) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(cells.indices, id: \.self) { index in
                Text(cells[index]).font(.system(size: 13, weight: header ? .semibold : .regular))
                    .lineSpacing(3).textSelection(.enabled)
                    .multilineTextAlignment(alignments[index] == .right ? .trailing : alignments[index] == .center ? .center : .leading)
                    .frame(width: widths[index] - 24, alignment: alignments[index] == .right ? .trailing : alignments[index] == .center ? .center : .leading)
                    .fixedSize(horizontal: false, vertical: true).padding(12)
            }
        }
    }
}

/// Most replies fit the pane. Avoid giving every code block and table its own
/// scroll view (and scroll geometry updates) when there is nothing to scroll.
private struct AIChatHorizontalOverflow<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        ViewThatFits(in: .horizontal) {
            content().fixedSize(horizontal: true, vertical: true)
            ScrollView(.horizontal) { content() }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

enum AIChatMarkdownImageSource {
    static let maximumBytes = 10 * 1024 * 1024

    static func localURL(_ destination: URL, directory: String) -> URL? {
        if destination.isFileURL {
            guard destination.host == nil || destination.host == "" || destination.host == "localhost" else { return nil }
            return destination
        }
        guard destination.scheme == nil, !destination.relativeString.hasPrefix("//"),
              let path = destination.relativeString.removingPercentEncoding, !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: directory, isDirectory: true)).standardizedFileURL
    }

    /// Decode raster images only, off the UI thread. Remote URLs remain explicit links.
    static func bitmap(_ destination: URL, directory: String) -> CGImage? {
        let data: Data
        if let file = localURL(destination, directory: directory) {
            guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true, let size = values.fileSize, size <= maximumBytes,
                  let bytes = try? Data(contentsOf: file, options: .mappedIfSafe), bytes.count <= maximumBytes else { return nil }
            data = bytes
        } else {
            let raw = destination.absoluteString
            guard raw.utf8.count <= maximumBytes * 4 / 3 + 100,
                  let comma = raw.firstIndex(of: ","),
                  ["data:image/png;base64", "data:image/jpeg;base64", "data:image/gif;base64", "data:image/webp;base64"].contains(String(raw[..<comma]).lowercased()),
                  let bytes = Data(base64Encoded: String(raw[raw.index(after: comma)...])), bytes.count <= maximumBytes else { return nil }
            data = bytes
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 2048
        ] as CFDictionary)
    }
}

private struct AIChatMarkdownImage: View {
    let alt: String
    let destination: URL
    let directory: String
    let theme: AppTheme
    @State private var bitmap: CGImage?
    @State private var loaded = false
    @State private var preview = false
    @State private var availableWidth: CGFloat = 320

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let bitmap {
                Button { preview = true } label: {
                    Image(decorative: bitmap, scale: 1).resizable().scaledToFit()
                        .frame(height: min(360, max(1, availableWidth - 24) * CGFloat(bitmap.height) / CGFloat(bitmap.width)))
                }.buttonStyle(.plain).accessibilityLabel(L10n.string("ai.images.preview") + ": " + alt)
                    .accessibilityIdentifier("chat-markdown-image")
            } else if AIChatMarkdownDocument.isWebLink(destination), destination.scheme != "mailto" {
                Link(destination: destination) {
                    Label(alt.isEmpty ? L10n.string("ai.markdown.openImage") : alt, systemImage: "photo")
                }
            } else if loaded {
                Label(L10n.string("ai.markdown.imageUnavailable"), systemImage: "photo")
                    .foregroundStyle(Color(nsColor: theme.textSecondary))
            } else { ProgressView().controlSize(.small) }
            if !alt.isEmpty, bitmap != nil || loaded {
                Text(alt).font(.caption).textSelection(.enabled).foregroundStyle(Color(nsColor: theme.textSecondary))
            }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background {
            GeometryReader { geometry in
                Color.clear.onAppear { availableWidth = geometry.size.width }
                    .onChange(of: geometry.size.width) { _, width in availableWidth = width }
            }
        }
        .background(Color(nsColor: theme.surface))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: theme.border), lineWidth: 1))
        .task(id: destination.relativeString + "\n" + directory) {
            bitmap = nil; loaded = false
            let result = await Task.detached(priority: .utility) {
                AIChatMarkdownImageSource.bitmap(destination, directory: directory)
            }.value
            guard !Task.isCancelled else { return }
            bitmap = result; loaded = true
        }
        .sheet(isPresented: $preview) {
            VStack(spacing: 12) {
                HStack {
                    Text(alt).font(.headline).lineLimit(2)
                    Spacer()
                    Button(L10n.string("ai.images.close")) { preview = false }.keyboardShortcut(.cancelAction)
                }
                if let bitmap { Image(decorative: bitmap, scale: 1).resizable().scaledToFit() }
            }.padding(16).frame(minWidth: 320, idealWidth: 720, maxWidth: 1000, minHeight: 240, idealHeight: 540, maxHeight: 800)
                .background(Color(nsColor: theme.canvas)).foregroundStyle(Color(nsColor: theme.textPrimary))
        }
    }
}
