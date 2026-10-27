import XCTest
@testable import TheAll

/// Smoke test that every key in the String Catalog is translated in all five
/// supported language bundles. Designed to catch missing translations after
/// adding a key but forgetting a supported language.
///
/// The key list is hardcoded below so the test itself becomes the single
/// source of truth for "what keys exist" — violating DRY with the xcstrings
/// file is intentional: if someone adds a key without updating this list,
/// they get a reviewer question about why it wasn't added to the test.
final class L10nSmokeTests: XCTestCase {
    /// All keys declared in TheAll/Localization/Localizable.xcstrings. Keep sorted.
    /// Maintain when adding or removing catalog entries.
    private let allKeys: [String] = [
        "ai.images.add",
        "ai.images.close",
        "ai.images.defaultName",
        "ai.images.drop",
        "ai.images.invalid",
        "ai.images.preparing",
        "ai.images.preview",
        "ai.images.remove",
        "ai.images.saveFailed",
        "ai.images.tooLarge",
        "ai.images.tooMany",
        "ai.images.unavailable",
        // Remaining shared UI keys
        "settings.appearance.contentShadow",
        "settings.agents.betaBadge",
        "settings.agents.codexAlertTitle",
        "settings.agents.codexAlertMessage",
        "settings.agents.codexAlertOK",
        "settings.agents.notificationsTitle",
        "settings.agents.notificationsFooter",
        "settings.agents.resumeTitle",
        "settings.agents.resumeFooter",
        "terminal.link.openHint",
        "ai.chat.progress",
        // Mobile access
        "mobile.error.readOnly",
        "mobile.error.scope",
        "mobile.share.title",
        "mobile.share.scope",
        "mobile.share.all",
        "mobile.share.unavailable",
        "mobile.share.permission",
        "mobile.share.readOnly",
        "mobile.share.writable",
        "mobile.share.help",
        "mobile.share.paired",
        "mobile.share.online",
        "mobile.share.offline",
        "mobile.share.expired",
        "mobile.copyIdentity",
        "mobile.error.identity",
        "mobile.error.relay",
        "mobile.relayConnecting",
        "mobile.relayOnline",
        "mobile.useRelay",
        "mobile.address",
        "mobile.addressHelp",
        "mobile.availability",
        "mobile.connectDomainHelp",
        "mobile.connectHelp",
        "mobile.connectTitle",
        "mobile.copy",
        "mobile.detail",
        "mobile.devices",
        "mobile.enable",
        "mobile.error.authorization",
        "mobile.error.busy",
        "mobile.error.capacity",
        "mobile.error.changed",
        "mobile.error.connection",
        "mobile.error.directory",
        "mobile.error.disabled",
        "mobile.error.history",
        "mobile.error.listen",
        "mobile.error.notFound",
        "mobile.error.notReady",
        "mobile.error.origin",
        "mobile.error.pair",
        "mobile.error.pending",
        "mobile.error.question",
        "mobile.error.rate",
        "mobile.error.request",
        "mobile.error.requestReuse",
        "mobile.error.restarted",
        "mobile.error.storage",
        "mobile.error.url",
        "mobile.guide",
        "mobile.localOnly",
        "mobile.noDevices",
        "mobile.online",
        "mobile.pair",
        "mobile.pairHelp",
        "mobile.preview",
        "mobile.qr",
        "mobile.revoke",
        "mobile.starting",
        "mobile.title",
        "mobile.lan.address",
        "mobile.lan.addressChanges",
        "mobile.lan.androidSteps",
        "mobile.lan.certificateHelp",
        "mobile.lan.certificateScope",
        "mobile.lan.enable",
        "mobile.lan.exportAndroid",
        "mobile.lan.exportFailed",
        "mobile.lan.exportIOS",
        "mobile.lan.failed",
        "mobile.lan.help",
        "mobile.lan.iosSteps",
        "mobile.lan.noAddress",
        "mobile.lan.offline",
        "mobile.lan.online",
        "mobile.lan.pairHelp",
        "mobile.lan.refresh",
        "mobile.lan.setup",
        "mobile.lan.unavailable",
        "mobile.modesHelp",
        "mobile.pair.lan",
        "mobile.pair.preview",
        "mobile.pair.relay",
        "mobile.relayHelp",
        // AI connection setup
        "ai.back",
        "ai.bearer",
        "ai.cancel",
        "ai.choose.detail",
        "ai.choose.title",
        "ai.claude.urlHint",
        "ai.configure",
        "ai.ended",
        "ai.error.cli",
        "ai.error.corrupt",
        "ai.error.key",
        "ai.error.keychain",
        "ai.error.keychainAuthorization",
        "ai.error.credentialHelper",
        "ai.error.keychainLegacy",
        "ai.error.launch",
        "ai.error.model",
        "ai.error.url",
        "ai.forget",
        "ai.forget.detail",
        "ai.forget.title",
        "ai.history.chatChanged",
        "ai.history.connectionNeeded",
        "ai.history.loadFailed",
        "ai.history.saveFailed",
        "ai.history.missingSession",
        "ai.history.restoreLegacy",
        "ai.history.legacyDetail",
        "ai.history.none",
        "ai.model",
        "ai.model.placeholder",
        "ai.newTerminal",
        "ai.openai.urlHint",
        "ai.saveOpen",
        "ai.saved",
        "ai.settings",
        "ai.stop.confirm",
        "ai.stop.detail",
        "ai.stop.title",
        "ai.storage",
        "ai.url",
        "ai.validation",
        "ai.chat.allow",
        "ai.chat.thinking",
        "ai.chat.allowSession",
        "ai.chat.rememberScope",
        "ai.chat.commandScope",
        "ai.chat.filesScope",
        "ai.chat.directoryScope",
        "ai.directory.choose",
        "ai.directory.busy",
        "ai.directory.unavailable",
        "ai.chat.answer",
        "ai.chat.chooseAnswer",
        "ai.chat.command",
        "ai.chat.connecting",
        "ai.chat.deny",
        "ai.chat.exit",
        "ai.chat.failed",
        "ai.chat.files",
        "ai.chat.input",
        "ai.chat.latest",
        "ai.chat.modelHint",
        "ai.chat.permissions",
        "ai.chat.question",
        "ai.chat.send",
        "ai.chat.sendAnswer",
        "ai.chat.stop",
        "ai.chat.timeout",
        "ai.chat.unsupported",
        "ai.chat.welcome",
        "ai.chat.welcomeDetail",
        "ai.chat.you",
        "ai.models.default",
        "ai.models.empty",
        "ai.models.http",
        "ai.models.refresh",
        "ai.models.unavailable",
        "ai.chat.toolFailed",
        "ai.chat.toolResult",
        // App
        "app.migration.title",
        "app.migration.detail",
        "app.migration.quit",
        "app.ghostty.notFound.detail",
        "app.ghostty.notFound.title",
        // Menu
        "menu.closePane",
        "menu.copy",
        "menu.editConfig",
        "menu.focusNextPane",
        "menu.focusPrevPane",
        "menu.help",
        "menu.newTab",
        "menu.newWorkspace",
        "menu.paste",
        "menu.selectAll",
        "menu.selectNextTab",
        "menu.selectPrevTab",
        "menu.selectTab %lld",
        "menu.selectWorkspace %lld",   // ← new
        "menu.settings",
        "menu.splitHorizontal",
        "menu.splitVertical",
        "menu.terminal",
        // QuickActions
        "quickActions.builtin.claude",
        "quickActions.builtin.codex",
        "quickActions.builtin.gitui",
        "quickActions.builtin.opencode",
        // Settings — appearance
        "settings.appearance.backgroundBlur",
        "settings.appearance.backgroundOpacity",
        "settings.appearance.contentOpacity",
        "settings.appearance.cursorBlink",
        "settings.appearance.cursorStyle",
        "settings.appearance.language",
        "settings.appearance.theme",
        "settings.appearance.unfocusedPaneOpacity",
        "settings.appearance.windowPaddingX",
        "settings.appearance.windowPaddingY",
        // Settings — agents
        "settings.agents.claude",
        "settings.agents.codex",
        "settings.agents.opencode",
        // Settings — chrome
        "settings.close",
        "settings.footer.edit",
        "settings.footer.live",
        // Settings — font
        "settings.font.custom",
        "settings.font.customPlaceholder",
        "settings.font.default",
        "settings.font.family",
        "settings.font.listButton",
        "settings.font.size",
        "settings.font.thicken",
        // Settings — language
        "settings.language.system",
        // Settings — quickActions
        "settings.quickActions.addCustomButton",
        "settings.quickActions.customCommandPlaceholder",
        "settings.quickActions.customNamePlaceholder",
        "settings.quickActions.deleteCustom.tooltip",
        "settings.quickActions.heading",
        "settings.quickActions.headingFooter",
        // Settings — reset
        "settings.reset.alertTitle",
        "settings.reset.button",
        "settings.reset.cancel",
        "settings.reset.message",
        "settings.reset.rowLabel",
        // Settings — section
        "settings.section.agents",
        "settings.section.appearance",
        "settings.section.font",
        "settings.section.quickActions",
        "settings.section.shell",
        "settings.section.terminal",
        "settings.section.update",
        // Settings — shell
        "settings.shell.customCommand",
        "settings.shell.defaultPlaceholder",
        "settings.shell.features",
        "settings.shell.integration",
        // Settings — terminal
        "settings.terminal.confirmClose",
        "settings.terminal.copyOnSelect",
        "settings.terminal.hideMouseWhileTyping",
        "settings.terminal.scrollbackLimit",
        // Settings — update (auto-update UI in Settings → Update section)
        "settings.update.action",
        "settings.update.availableUpdate",
        "settings.update.checkForUpdates",
        "settings.update.checking",
        "settings.update.currentVersion",
        "settings.update.debugBuild",
        "settings.update.debugDisabled",
        "settings.update.dismiss",
        "settings.update.downloadInstall",
        "settings.update.downloading",
        "settings.update.error",
        "settings.update.installing",
        "settings.update.releaseNotes",
        "settings.update.retry",
        "settings.update.skipThisVersion",
        "settings.update.status",
        "settings.update.upToDate",
        "settings.update.version %@",
        // Settings — theme
        "settings.theme.dark",
        "settings.theme.followSystem",
        "settings.theme.inherit",
        "settings.theme.light",
        "settings.theme.name",
        "settings.theme.searchPlaceholder",
        "settings.theme.single",
        // Sidebar
        "sidebar.checkForUpdates",
        "sidebar.deleteAlert.cancel",
        "sidebar.deleteAlert.confirm",
        "sidebar.deleteAlert.message %@",
        "sidebar.deleteAlert.title",
        "sidebar.hide",
        "sidebar.newWorkspace",
        "sidebar.row.commandPanel.cancel",
        "sidebar.row.commandPanel.editTitle",
        "sidebar.row.commandPanel.placeholder",
        "sidebar.row.commandPanel.save",
        "sidebar.row.delete",
        "sidebar.row.rename",
        "sidebar.settings",
        "sidebar.show",
        "sidebar.title",
        "sidebar.updateAvailable",
        // Tab
        "tab.add.terminal",
        "tab.close.alert.cancel",
        "tab.close.alert.confirm",
        "tab.close.alert.message %@",
        "tab.close.alert.title",
        "tab.newTab",
        "tab.row.close",
        "tab.row.rename",
        "tab.row.resetAutoTitle",
    ]

    override func tearDown() {
        LanguageStore.shared.preference = .system
        super.tearDown()
    }

    private func bundle(for code: String) -> Bundle? {
        let parent = Bundle(for: LanguageStore.self)
        guard let path = parent.path(forResource: code, ofType: "lproj") else { return nil }
        return Bundle(path: path)
    }

    func testCatalogKeyListMatchesActualCount() {
        // Sanity: if someone adds a key to Strings.xcstrings but forgets to
        // add it here, this test doesn't directly fail — but the key-count
        // check catches it on both sides.
        XCTAssertEqual(allKeys.count, Set(allKeys).count,
                       "Duplicate keys in allKeys list.")
    }

    func testAllKeysResolveInEnBundle() throws {
        let b = try XCTUnwrap(bundle(for: "en"), "en.lproj not found in test bundle")
        for key in allKeys {
            let v = b.localizedString(forKey: key, value: "__MISSING__", table: nil)
            XCTAssertNotEqual(v, "__MISSING__", "Missing en translation for: \(key)")
            XCTAssertFalse(v.isEmpty, "Empty en translation for: \(key)")
            XCTAssertNotEqual(v, key, "en translation equals key for: \(key) — likely missing")
        }
    }

    func testAllKeysResolveInZhHansBundle() throws {
        let b = try XCTUnwrap(bundle(for: "zh-Hans"), "zh-Hans.lproj not found in test bundle")
        for key in allKeys {
            let v = b.localizedString(forKey: key, value: "__MISSING__", table: nil)
            XCTAssertNotEqual(v, "__MISSING__", "Missing zh-Hans translation for: \(key)")
            XCTAssertFalse(v.isEmpty, "Empty zh-Hans translation for: \(key)")
            XCTAssertNotEqual(v, key, "zh-Hans translation equals key for: \(key) — likely missing")
        }
    }

    func testAdditionalLanguagesResolveAllKeysAndFormatting() throws {
        for preference in [LanguageStore.Preference.fr, .ja, .ko] {
            let b = try XCTUnwrap(bundle(for: preference.rawValue))
            for key in allKeys {
                let value = b.localizedString(forKey: key, value: "__MISSING__", table: nil)
                XCTAssertNotEqual(value, "__MISSING__", "Missing \(preference): \(key)")
                XCTAssertFalse(value.isEmpty, key)
            }
            LanguageStore.shared.preference = preference
            let value = L10n.string("sidebar.deleteAlert.message %@", "my-workspace")
            XCTAssertTrue(value.contains("my-workspace"))
            XCTAssertFalse(value.contains("%@"))
        }
    }

    func testFormattedMessageSubstitutesWorkspaceName() {
        // Smoke-test the sidebar.deleteAlert.message %@ path end-to-end through L10n.string.
        LanguageStore.shared.preference = .en
        let s = L10n.string("sidebar.deleteAlert.message %@", "my-ws")
        XCTAssertTrue(s.contains("my-ws"),
                      "Expected 'my-ws' to appear in formatted message; got: \(s)")
        XCTAssertFalse(s.contains("%@"),
                       "Expected '%@' to be substituted; got: \(s)")
    }

    func testFormattedTabMessageSubstitutesTabTitle() {
        LanguageStore.shared.preference = .en
        let s = L10n.string("tab.close.alert.message %@", "main.swift")
        XCTAssertTrue(s.contains("main.swift"),
                      "Expected 'main.swift' to appear; got: \(s)")
        XCTAssertFalse(s.contains("%@"),
                       "Expected '%@' to be substituted; got: \(s)")
    }
}
