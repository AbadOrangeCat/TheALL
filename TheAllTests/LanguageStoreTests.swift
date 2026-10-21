import XCTest
import SwiftUI
@testable import TheAll

final class LanguageStoreTests: XCTestCase {
    private let testKey = "theall.language.test"

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: testKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: testKey)
        super.tearDown()
    }

    func testDefaultPreferenceIsSystem() {
        let store = LanguageStore(storageKey: testKey, defaults: .standard)
        XCTAssertEqual(store.preference, .system)
    }

    func testPreferencePersists() {
        let store1 = LanguageStore(storageKey: testKey, defaults: .standard)
        store1.preference = .zh
        let store2 = LanguageStore(storageKey: testKey, defaults: .standard)
        XCTAssertEqual(store2.preference, .zh)
    }

    func testInvalidStoredValueFallsBackToSystem() {
        UserDefaults.standard.set("bogus", forKey: testKey)
        let store = LanguageStore(storageKey: testKey, defaults: .standard)
        XCTAssertEqual(store.preference, .system)
    }

    func testTickIncrementsOnPreferenceChange() {
        let store = LanguageStore(storageKey: testKey, defaults: .standard)
        let before = store.tick
        store.preference = .zh
        XCTAssertEqual(store.tick, before &+ 1)
    }

    func testTickDoesNotIncrementOnSameValue() {
        let store = LanguageStore(storageKey: testKey, defaults: .standard)
        store.preference = .zh
        let mid = store.tick
        store.preference = .zh
        XCTAssertEqual(store.tick, mid)
    }

    func testLocaleForZh() {
        let store = LanguageStore(storageKey: testKey, defaults: .standard)
        store.preference = .zh
        XCTAssertEqual(store.locale.identifier, "zh-Hans")
    }

    func testLocaleForEn() {
        let store = LanguageStore(storageKey: testKey, defaults: .standard)
        store.preference = .en
        XCTAssertEqual(store.locale.identifier, "en")
    }

    func testLocaleForSystemMatchesCurrent() {
        let store = LanguageStore(storageKey: testKey, defaults: .standard)
        store.preference = .system
        XCTAssertEqual(store.locale, Locale.current)
    }

    func testEffectiveBundleForZhReturnsZhHansLproj() {
        let store = LanguageStore(storageKey: testKey, defaults: .standard)
        store.preference = .zh
        let value = store.effectiveBundle.localizedString(forKey: "sidebar.title", value: nil, table: nil)
        XCTAssertFalse(value.isEmpty)
        XCTAssertTrue(store.effectiveBundle.bundlePath.contains("zh-Hans.lproj"),
                      "bundlePath = \(store.effectiveBundle.bundlePath)")
    }

    func testEffectiveBundleForEnReturnsEnLproj() {
        let store = LanguageStore(storageKey: testKey, defaults: .standard)
        store.preference = .en
        XCTAssertTrue(store.effectiveBundle.bundlePath.contains("en.lproj"),
                      "bundlePath = \(store.effectiveBundle.bundlePath)")
    }

    func testAdditionalLanguagesPersistAndResolveTheirBundles() {
        for preference in [LanguageStore.Preference.fr, .ja, .ko] {
            let store = LanguageStore(storageKey: testKey, defaults: .standard)
            store.preference = preference
            let restored = LanguageStore(storageKey: testKey, defaults: .standard)
            XCTAssertEqual(restored.preference, preference)
            XCTAssertEqual(restored.locale.identifier, preference.rawValue)
            XCTAssertTrue(restored.effectiveBundle.bundlePath.contains(preference.rawValue + ".lproj"))
            let translated = restored.effectiveBundle.localizedString(forKey: "settings.appearance.language", value: nil, table: nil)
            XCTAssertNotEqual(translated, "settings.appearance.language")
            XCTAssertNotEqual(translated, "Language")
        }
    }

    func testRegionalLanguageMappingAndFallback() {
        for (identifier, expected) in [("fr_CA", "fr"), ("ja-JP", "ja"), ("ko_KR", "ko"), ("zh-Hant-TW", "zh-Hans"), ("en-NZ", "en"), ("de-DE", "en")] {
            XCTAssertEqual(LanguageStore.supportedLanguage(for: identifier), expected)
        }
    }

    @MainActor func testAppearanceRendersAfterSwitchingAllSupportedLanguages() async throws {
        let store = LanguageStore(storageKey: testKey, defaults: .standard)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("TheAll-language-preview-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let settings = SettingsConfigStore(filePath: folder.appendingPathComponent("config").path)
        struct Preview: View {
            let store: LanguageStore
            let settings: SettingsConfigStore
            var body: some View {
                AppearanceSectionView(theme: .systemFallback(isDark: false), settings: settings)
                    .environment(store).environment(\.locale, store.locale)
                    .background(Color(AppTheme.systemFallback(isDark: false).canvas))
                    .preferredColorScheme(.light)
            }
        }
        let hosting = NSHostingView(rootView: Preview(store: store, settings: settings))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 720), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = hosting; window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        func scrollViews(_ view: NSView) -> [NSScrollView] {
            (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
        }
        for preference in [LanguageStore.Preference.en, .zh, .fr, .ja, .ko] {
            store.preference = preference
            try await Task.sleep(nanoseconds: 150_000_000)
            hosting.layoutSubtreeIfNeeded()
            let scroll = try XCTUnwrap(scrollViews(hosting).first)
            let document = try XCTUnwrap(scroll.documentView)
            XCTAssertLessThanOrEqual(document.bounds.width, hosting.bounds.width + 2)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, document.bounds.height - scroll.contentView.bounds.height)))
            scroll.reflectScrolledClipView(scroll.contentView)
            hosting.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
            attachment.name = "appearance-" + preference.rawValue; attachment.lifetime = .keepAlways; add(attachment)
            try png.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("theall-appearance-" + preference.rawValue + ".png"))
        }
    }
}
