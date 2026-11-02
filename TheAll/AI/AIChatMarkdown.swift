import AppKit
import SwiftUI
import ImageIO

struct AIChatMarkdownDocument {
    enum Style: Equatable {
        case paragraph, heading(Int), quote, list(marker: String, depth: Int)
    }
    enum Content: Equatable {
        case text(AttributedString, Style)
        case code(String, language: String)
        case table(headers: [AttributedString], rows: [[AttributedString]], alignments: [ColumnAlignment])
        case image(alt: String, destination: URL)
    }
    enum ColumnAlignment: Equatable { case left, center, right }
    var blocks: [Content]

    init(_ source: String) {
        guard let parsed = try? AttributedString(markdown: Self.joinSpacedTableRows(source),
            options: .init(interpretedSyntax: .full, failurePolicy: .returnPartiallyParsedIfPossible)) else {
            blocks = [.text(AttributedString(source), .paragraph)]
            return
        }
        var groups: [(id: Int, text: AttributedString)] = []
        for run in parsed.runs {
            let components = run.presentationIntent?.components ?? []
            let table = components.first { if case .table = $0.kind { return true }; return false }
            let id = table?.identity ?? components.first?.identity ?? -1
            let fragment = AttributedString(parsed[run.range])
            if groups.last?.id == id { groups[groups.count - 1].text.append(fragment) }
            else { groups.append((id, fragment)) }
        }
        var seenListItems = Set<Int>()
        blocks = groups.flatMap { Self.blocks(for: $0.text, seenListItems: &seenListItems) }
    }

    private static func blocks(for text: AttributedString, seenListItems: inout Set<Int>) -> [Content] {
        let components = text.runs.first?.presentationIntent?.components ?? []
        for component in components {
            switch component.kind {
            case .table(let columns): return [table(text, columns: columns)]
            case .codeBlock(let language): return [.code(String(text.characters), language: language ?? "")]
            default: break
            }
        }
        var style = style(for: components, seenListItems: &seenListItems)
        var result: [Content] = []
        var paragraph = AttributedString()
        var image: (alt: String, url: URL)?
        func appendParagraph() {
            guard !paragraph.characters.isEmpty else { return }
            result.append(.text(paragraph, style)); paragraph = AttributedString()
            if case .list(_, let depth) = style { style = .list(marker: "", depth: depth) }
        }
        for run in text.runs {
            if let url = run.imageURL {
                appendParagraph()
                if image?.url == url { image?.alt += String(text[run.range].characters) }
                else {
                    if let image { result.append(.image(alt: image.alt, destination: image.url)) }
                    image = (String(text[run.range].characters), url)
                }
            } else {
                if let current = image { result.append(.image(alt: current.alt, destination: current.url)); image = nil }
                paragraph.append(inline(AttributedString(text[run.range])))
            }
        }
        if let image { result.append(.image(alt: image.alt, destination: image.url)) }
        appendParagraph()
        return result
    }

    private static func style(for components: [PresentationIntent.IntentType], seenListItems: inout Set<Int>) -> Style {
        for component in components {
            if case .header(let level) = component.kind { return .heading(level) }
        }
        let items = components.compactMap { component -> Int? in
            if case .listItem(let ordinal) = component.kind { return ordinal }; return nil
        }
        if let ordinal = items.first {
            let list = components.first { $0.kind == .orderedList || $0.kind == .unorderedList }
            let item = components.first { if case .listItem = $0.kind { return true }; return false }
            let firstParagraph = item.map { seenListItems.insert($0.identity).inserted } ?? true
            return .list(marker: firstParagraph ? (list?.kind == .orderedList ? "\(ordinal)." : "•") : "", depth: items.count - 1)
        }
        return components.contains { $0.kind == .blockQuote } ? .quote : .paragraph
    }

    private static func table(_ text: AttributedString, columns: [PresentationIntent.TableColumn]) -> Content {
        var cells: [Int: [Int: AttributedString]] = [:]
        for run in text.runs {
            var row = 0
            var column = 0
            for component in run.presentationIntent?.components ?? [] {
                if case .tableRow(let index) = component.kind { row = index }
                if case .tableCell(let index) = component.kind { column = index }
            }
            cells[row, default: [:]][column, default: AttributedString()].append(inline(AttributedString(text[run.range])))
        }
        func values(_ row: Int) -> [AttributedString] {
            columns.indices.map { cells[row]?[$0] ?? AttributedString() }
        }
        let alignments: [ColumnAlignment] = columns.map {
            switch $0.alignment {
            case .right: return .right
            case .center: return .center
            default: return .left
            }
        }
        let lastRow = cells.keys.max() ?? 0
        return .table(headers: values(0), rows: lastRow > 0 ? (1...lastRow).map(values) : [], alignments: alignments)
    }

    /// SwiftUI renders inline emphasis; block layout belongs to the containing view.
    private static func inline(_ value: AttributedString) -> AttributedString {
        var result = value
        result.presentationIntent = nil
        result.imageURL = nil
        for run in value.runs {
            if let link = run.link, !isWebLink(link) { result[run.range].link = nil }
            if run.inlinePresentationIntent?.contains(.code) == true {
                result[run.range].font = .system(size: 13, design: .monospaced)
            }
        }
        return result
    }

    static func isWebLink(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return ["https", "http", "mailto"].contains(scheme)
    }

    /// Some model responses insert empty lines into otherwise valid pipe tables.
    /// Only join a confirmed table, outside fenced/indented code; never unescape text.
    static func joinSpacedTableRows(_ source: String) -> String {
        let lines = source.components(separatedBy: "\n")
        var output: [String] = []
        var index = 0
        var fence: (character: Character, count: Int)?
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let marker = trimmed.first, marker == "`" || marker == "~" {
                let count = trimmed.prefix { $0 == marker }.count
                if count >= 3 {
                    if let active = fence {
                        if active.character == marker && count >= active.count && trimmed.dropFirst(count).trimmingCharacters(in: .whitespaces).isEmpty { fence = nil }
                    } else { fence = (marker, count) }
                    output.append(line); index += 1; continue
                }
            }
            if fence == nil, isPipeRow(line) {
                var separator = index + 1
                while separator < lines.count && lines[separator].trimmingCharacters(in: .whitespaces).isEmpty { separator += 1 }
                if separator < lines.count, isTableSeparator(lines[separator]), columnCount(line) == columnCount(lines[separator]) {
                    output.append(line); output.append(lines[separator]); index = separator + 1
                    while index < lines.count {
                        var next = index
                        while next < lines.count && lines[next].trimmingCharacters(in: .whitespaces).isEmpty { next += 1 }
                        guard next < lines.count, isPipeRow(lines[next]), !isTableSeparator(lines[next]) else { break }
                        if next > index && columnCount(lines[next]) != columnCount(line) { break }
                        // A second header starts a new table, even if separated only by blank lines.
                        var following = next + 1
                        while following < lines.count && lines[following].trimmingCharacters(in: .whitespaces).isEmpty { following += 1 }
                        if next > index, following < lines.count, isTableSeparator(lines[following]) { break }
                        output.append(lines[next]); index = next + 1
                    }
                    continue
                }
            }
            output.append(line); index += 1
        }
        return output.joined(separator: "\n")
    }

    private static func isPipeRow(_ line: String) -> Bool {
        !line.hasPrefix("    ") && !line.hasPrefix("\t") && line.trimmingCharacters(in: .whitespaces).hasPrefix("|")
    }

    private static func columnCount(_ line: String) -> Int {
        let value = line.trimmingCharacters(in: .whitespaces)
        var pipes = 0, escaped = false, trailingPipe = false
        for character in value {
            trailingPipe = false
            if escaped { escaped = false; continue }
            if character == "\\" { escaped = true; continue }
            if character == "|" { pipes += 1; trailingPipe = true }
        }
        return pipes - (trailingPipe ? 1 : 0)
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        guard isPipeRow(line) else { return false }
        var cells = line.trimmingCharacters(in: .whitespaces).split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        cells.removeFirst()
        if cells.last == "" { cells.removeLast() }
        return !cells.isEmpty && cells.allSatisfy { $0.range(of: "^:?-{3,}:?$", options: .regularExpression) != nil }
    }
}
