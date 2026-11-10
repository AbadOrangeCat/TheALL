import AppKit
import SwiftUI
import XCTest
@testable import TheAll

final class AIChatMarkdownTests: XCTestCase {
    func testBenchmarkTableWithBlankLinesKeepsValuesAndFormatting() throws {
        let document = AIChatMarkdownDocument("""
        ## 1. 耗时和调用次数

        | 场景 | Titan 调用（旧 → 新） | 耗时（旧 → 新） |

        |---|---:|:---:|

        | S1 建 KB | 49,191 → 13,864（**−71.8%**） | 52.2 → 12.9 分钟 |

        | S2 第一次扫描 | 12,448 → 3,249 | 13.6 → 3.4 分钟 |

        | **合计** | **74,087 → 17,113（−76.9%）** | |

        **节省主要来自哪里**：说明文字。
        """)
        XCTAssertEqual(document.blocks.count, 3)
        guard case let .table(headers, rows, alignment) = document.blocks[safe: 1] else {
            return XCTFail("Expected a readable table between heading and explanation")
        }
        XCTAssertEqual(headers.map { String($0.characters) }, ["场景", "Titan 调用（旧 → 新）", "耗时（旧 → 新）"])
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(String(rows[0][1].characters), "49,191 → 13,864（−71.8%）")
        XCTAssertTrue(rows[0][1].runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true })
        XCTAssertEqual(String(rows[2][2].characters), "")
        XCTAssertEqual(alignment, [.left, .right, .center])
    }

    func testFencedCodePreservesWhitespaceAndDoesNotBecomeATable() {
        let code = "  let x = \"<script>\"\n\n| a | b |\n\n|---|---|\n\tprint(x)\n"
        let document = AIChatMarkdownDocument("```swift\n" + code + "```\n\nDone.")
        XCTAssertEqual(document.blocks.first, .code(code, language: "swift"))
        XCTAssertEqual(document.blocks.count, 2)
    }

    func testIncompleteStreamingFenceAndEscapedMarkdownStayReadable() {
        XCTAssertEqual(AIChatMarkdownDocument("```python\n  print(42)").blocks.first,
                       .code("  print(42)\n", language: "python"))
        let escaped = AIChatMarkdownDocument("\\| literal \\| text \\|\n\n\\|---\\|---\\|")
        XCTAssertFalse(escaped.blocks.contains { if case .table = $0 { return true }; return false })
    }

    func testInlineCodeEscapedPipesAndImagesAreRetained() throws {
        let document = AIChatMarkdownDocument("| Name | Value |\n|---|---|\n| `a\\|b` | **yes** |\n\nBefore ![Chart](images/chart.png) after.")
        guard case let .table(_, rows, _) = document.blocks.first else { return XCTFail("Missing table") }
        XCTAssertEqual(String(rows[0][0].characters), "a|b")
        XCTAssertEqual(rows[0][0].runs.first?.inlinePresentationIntent, .code)
        XCTAssertTrue(document.blocks.contains(.image(alt: "Chart", destination: URL(string: "images/chart.png")!)))
        XCTAssertTrue(document.blocks.contains { if case let .text(text, _) = $0 { return String(text.characters).contains("after.") }; return false })
    }

    func testHeadingsListsQuotesAndParagraphsStaySeparated() {
        let document = AIChatMarkdownDocument("## Results\n\n- one\n- two\n\n> note\n\nLast **line**.")
        XCTAssertEqual(document.blocks.count, 5)
        guard case .text(_, .heading(2)) = document.blocks.first else { return XCTFail("Missing heading") }
        guard case .text(_, .list(marker: "•", depth: 0)) = document.blocks[safe: 1] else { return XCTFail("Missing list") }
        guard case .text(_, .quote) = document.blocks[safe: 3] else { return XCTFail("Missing quote") }
    }

    func testUnsafeLinksAreInertAndAdjacentTablesRemainSeparate() {
        let document = AIChatMarkdownDocument("[bad](javascript:alert(1)) [safe](https://example.com)\n\n| A | B |\n\n|---|---|\n\n| 1 | 2 |\n\n| C | D |\n\n|---|---|\n\n| 3 | 4 |")
        guard case let .text(text, _) = document.blocks.first else { return XCTFail("Missing text") }
        XCTAssertEqual(text.runs.compactMap(\.link), [URL(string: "https://example.com")!])
        XCTAssertEqual(document.blocks.filter { if case .table = $0 { return true }; return false }.count, 2)
    }

    func testTableNormalizationDoesNotSwallowFollowingProseOrRepeatListMarkers() {
        let document = AIChatMarkdownDocument("| A | B |\n|---|---|\n| one | two |\n\n| NOTE | fallback | DO NOT LOSE |")
        guard case let .text(text, _) = document.blocks.last else { return XCTFail("Following prose was consumed by the table") }
        XCTAssertTrue(String(text.characters).contains("DO NOT LOSE"))
        let list = AIChatMarkdownDocument("- First.\n\n  Second paragraph.\n\n- Next.")
        guard case .text(_, .list(marker: "", depth: 0)) = list.blocks[safe: 1] else { return XCTFail("Continuation must not add another bullet") }
        let imageList = AIChatMarkdownDocument("- Before ![Chart](chart.png) after.")
        guard case .text(_, .list(marker: "", depth: 0)) = imageList.blocks.last else { return XCTFail("Image must not split one list item into two bullets") }
    }

    func testCopyRetainsCodeBytesAndImageResolutionDoesNotFetchURLs() throws {
        let clipboard = NSPasteboard(name: .init("TheAllMarkdownTests-" + UUID().uuidString))
        defer { clipboard.releaseGlobally() }
        let code = "\tlet name = \"中文\"\n\n  print(name)  \n"
        AIChatCodeBlock.copy(code, to: clipboard)
        XCTAssertEqual(clipboard.string(forType: .string), code)
        XCTAssertEqual(AIChatMarkdownImageSource.localURL(URL(string: "images/test%20chart.png")!, directory: "/tmp/project")?.path,
                       "/tmp/project/images/test chart.png")
        for raw in ["https://example.com/photo.png", "//example.com/photo.png", "file://server/share/photo.png", "javascript:alert(1)"] {
            let url = try XCTUnwrap(URL(string: raw))
            XCTAssertNil(AIChatMarkdownImageSource.localURL(url, directory: "/tmp"))
            XCTAssertNil(AIChatMarkdownImageSource.bitmap(url, directory: "/tmp"))
        }
        let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScLttAAAAABJRU5ErkJggg=="
        XCTAssertNotNil(AIChatMarkdownImageSource.bitmap(URL(string: "data:image/png;base64," + png)!, directory: "/tmp"))
        XCTAssertNil(AIChatMarkdownImageSource.bitmap(URL(string: "data:image/svg+xml;base64,PHN2Zy8+")!, directory: "/tmp"))
    }

    @MainActor func testRichContentLayoutFitsNarrowAndWideWindows() throws {
        let source = """
        ## 耗时和调用次数
        Titan 调用减少约 **77%**，embedding 耗时减少约 **75%**。

        | 场景 | Titan 调用（旧 → 新） | 耗时（旧 → 新） |

        |---|---:|---:|

        | S1 建 KB | 49,191 → 13,864（**−71.8%**） | 52.2 → 12.9 分钟（**−75.2%**） |

        | S2 第一次扫描 | 12,448 → 3,249（**−73.9%**） | 13.6 → 3.4 分钟（**−75.2%**） |

        | **合计** | **74,087 → 17,113（−76.9%）** | |

        ```python
        for company in companies:
            result = compare_embeddings(company, baseline="previous_version", repeated_scan=True)
            print(result)
        ```

        **准确率和覆盖率保持不变。**
        """
        func scrollViews(_ view: NSView) -> [NSScrollView] {
            (view as? NSScrollView).map { [$0] + view.subviews.flatMap(scrollViews) } ?? view.subviews.flatMap(scrollViews)
        }
        for (width, dark) in [(320.0, true), (420.0, false), (880.0, true)] {
            let theme = AppTheme.systemFallback(isDark: dark)
            let view = AIChatMarkdown(text: source, directory: "/tmp", theme: theme)
                .padding(16).foregroundStyle(Color(nsColor: theme.textPrimary)).background(Color(nsColor: theme.canvas))
                .environment(\.colorScheme, dark ? .dark : .light)
            let host = NSHostingView(rootView: view)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 720), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
            defer { window.contentView = nil; window.close() }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            host.layoutSubtreeIfNeeded()
            XCTAssertEqual(host.bounds.width, width, accuracy: 1)
            let horizontal = scrollViews(host).filter { $0.documentView != nil }
            XCTAssertEqual(horizontal.count, width == 880 ? 0 : 2,
                "Only overflowing content needs independent horizontal scrolling")
            for scroll in horizontal {
                let frame = scroll.convert(scroll.bounds, to: host)
                XCTAssertGreaterThanOrEqual(frame.minX, 0)
                XCTAssertLessThanOrEqual(frame.maxX, width + 1)
                XCTAssertGreaterThan(scroll.bounds.height, 25)
                if width == 320 {
                    XCTAssertGreaterThan(scroll.documentView!.bounds.width, scroll.contentView.bounds.width)
                    scroll.contentView.scroll(to: NSPoint(x: 50, y: 0))
                    scroll.reflectScrolledClipView(scroll.contentView)
                    XCTAssertGreaterThan(scroll.contentView.bounds.minX, 0)
                }
            }
            if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
                attachment.name = "Markdown \(Int(width)) \(dark ? "dark" : "light")"
                attachment.lifetime = .keepAlways; add(attachment)
            }
        }
    }

    @MainActor func testOverflowAdaptsToResizingAndRoutesWheelInput() throws {
        let source = """
        ```swift
        let result = compareEmbeddings(company, baseline: "previous_version")
        print(result)
        ```

        | Company | Before | After |
        |---|---:|---:|
        | Example | 12,448 | 3,249 |
        """
        let view = ScrollView {
            VStack {
                Color.clear.frame(height: 600)
                AIChatMarkdown(text: source, directory: "/tmp", theme: .systemFallback(isDark: false))
                Color.clear.frame(height: 600)
            }.padding(16)
        }
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 880, height: 640),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        func settle() { RunLoop.current.run(until: Date().addingTimeInterval(0.2)) }
        func scrollViews(_ view: NSView) -> [NSScrollView] {
            (view as? NSScrollView).map { [$0] + view.subviews.flatMap(scrollViews) } ?? view.subviews.flatMap(scrollViews)
        }
        func wheel(over point: NSPoint, vertical: Int32 = 0, horizontal: Int32 = 0) throws {
            let target = try XCTUnwrap(host.hitTest(host.convert(point, to: host.superview)))
            let cgEvent = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                wheelCount: 2, wheel1: vertical, wheel2: horizontal, wheel3: 0))
            let screen = window.convertPoint(toScreen: host.convert(point, to: nil))
            cgEvent.location = CGPoint(x: screen.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - screen.y)
            // Hit-test the actual content, then deliver only to this test window.
            let event = try XCTUnwrap(NSEvent(cgEvent: cgEvent))
            target.scrollWheel(with: event)
            settle()
        }
        settle()
        let outer = try XCTUnwrap(scrollViews(host).first)
        for width in [880.0, 320.0, 880.0, 320.0] {
            window.setContentSize(NSSize(width: width, height: 640)); settle()
            outer.contentView.scroll(to: NSPoint(x: 0, y: 500))
            outer.reflectScrolledClipView(outer.contentView); settle()
            let inner = scrollViews(host).filter { $0 !== outer }
            XCTAssertEqual(inner.count, width == 880 ? 0 : 2)
            if inner.isEmpty {
                let before = outer.contentView.bounds.minY
                try wheel(over: NSPoint(x: 100, y: 200), vertical: -30)
                XCTAssertGreaterThan(outer.contentView.bounds.minY, before)
            }
            for scroll in inner {
                let visible = scroll.convert(scroll.bounds, to: host).intersection(host.bounds)
                XCTAssertGreaterThan(visible.height, 20)
                let point = NSPoint(x: visible.midX, y: visible.midY)
                let beforeY = outer.contentView.bounds.minY
                let beforeX = scroll.contentView.bounds.minX
                try wheel(over: point, vertical: -30)
                XCTAssertGreaterThan(outer.contentView.bounds.minY, beforeY,
                    "Vertical wheel input over code and tables must reach the transcript")
                XCTAssertEqual(scroll.contentView.bounds.minX, beforeX, accuracy: 1)
                let afterY = outer.contentView.bounds.minY
                let moved = scroll.convert(scroll.bounds, to: host).intersection(host.bounds)
                try wheel(over: NSPoint(x: moved.midX, y: moved.midY), horizontal: -30)
                XCTAssertGreaterThan(scroll.contentView.bounds.minX, beforeX,
                    "Overflowing content must still scroll horizontally")
                XCTAssertEqual(outer.contentView.bounds.minY, afterY, accuracy: 1)
                try wheel(over: NSPoint(x: moved.midX, y: moved.midY), vertical: 30)
                XCTAssertLessThan(outer.contentView.bounds.minY, afterY)
            }
        }
    }

    @MainActor func testLocalImageFitsMessageAndOpensPreview() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("theall-markdown-image-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let theme = AppTheme.systemFallback(isDark: true)
        let context = try XCTUnwrap(CGContext(data: nil, width: 640, height: 320, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(theme.accent.cgColor); context.fill(CGRect(x: 0, y: 0, width: 640, height: 320))
        context.setFillColor(theme.sidebar.cgColor); context.fill(CGRect(x: 20, y: 20, width: 600, height: 280))
        let bitmap = try XCTUnwrap(context.makeImage())
        let png = try XCTUnwrap(NSBitmapImageRep(cgImage: bitmap).representation(using: .png, properties: [:]))
        try png.write(to: directory.appendingPathComponent("chart.png"))
        let decoded = try XCTUnwrap(AIChatMarkdownImageSource.bitmap(URL(string: "chart.png")!, directory: directory.path))
        XCTAssertEqual(decoded.width, decoded.height * 2)
        let view = AIChatMarkdown(text: "![Image keeps its full border](chart.png)", directory: directory.path, theme: theme)
            .padding(16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .foregroundStyle(Color(nsColor: theme.textPrimary)).background(Color(nsColor: theme.canvas))
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 480), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
        defer { for sheet in window.sheets { window.endSheet(sheet) }; window.contentView = nil; window.close() }
        RunLoop.current.run(until: Date().addingTimeInterval(0.5)); host.layoutSubtreeIfNeeded()
        if let preview = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: preview)
            let attachment = XCTAttachment(data: try XCTUnwrap(preview.representation(using: .png, properties: [:])), uniformTypeIdentifier: "public.png")
            attachment.name = "Markdown image fit"; attachment.lifetime = .keepAlways; add(attachment)
        }
        let point = host.convert(NSPoint(x: 210, y: host.isFlipped ? 180 : host.bounds.height - 180), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            window.sendEvent(try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 0)))
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(window.sheets.count, 1, "Clicking the rendered local image opens a preview")
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
