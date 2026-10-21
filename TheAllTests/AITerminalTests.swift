import XCTest
import AppKit
import Security
@testable import TheAll

final class AITerminalTests: XCTestCase {
    private final class Credentials: AICredentialStore {
        var values: [AIProvider: AIConnection] = [:]
        var failRead = false
        var failSave = false
        var writes = 0
        func load(for provider: AIProvider) throws -> AIConnection? {
            if failRead { throw AIConnectionError.keychain(-1) }
            return values[provider]
        }
        func save(_ connection: AIConnection, for provider: AIProvider) throws {
            if failSave { throw AIConnectionError.keychain(-1) }
            values[provider] = connection
            writes += 1
        }
        func delete(for provider: AIProvider) throws { values[provider] = nil }
    }

    private func session(_ store: Credentials) -> AITerminalSession {
        AITerminalSession(credentials: store) {
            try AILaunchConfiguration.make(provider: $0, connection: $1, executable: "/usr/bin/true")
        }
    }

    func testProviderChoiceGatesLaunchAndReusesCredentialAcrossSessions() {
        let store = Credentials()
        let first = session(store)
        var launches = 0
        first.onLaunch = { _ in launches += 1 }
        XCTAssertNil(first.provider)
        first.choose(.claude)
        XCTAssertFalse(first.isRunning)
        XCTAssertEqual(launches, 0)
        first.draft = AIConnection(apiKey: "test-key", baseURL: "https://gateway.example", model: "my-model")
        first.saveAndLaunch()
        XCTAssertTrue(first.isRunning)
        XCTAssertEqual(launches, 1)
        XCTAssertTrue(first.draft.apiKey.isEmpty)
        XCTAssertEqual(store.writes, 1)
        // Repeated events while running must not spawn a second process.
        first.saveAndLaunch()
        first.choose(.openai)
        XCTAssertEqual(launches, 1)

        let second = session(store)
        second.onLaunch = { launch in
            launches += 1
            XCTAssertEqual(launch.environment["ANTHROPIC_API_KEY"], "test-key")
            XCTAssertEqual(launch.environment["ANTHROPIC_BASE_URL"], "https://gateway.example")
        }
        second.choose(.claude)
        XCTAssertTrue(second.isRunning)
        XCTAssertEqual(launches, 2)
        XCTAssertEqual(store.writes, 1)
        let third = session(store)
        third.choose(.openai)
        XCTAssertFalse(third.isRunning)
        XCTAssertTrue(third.draft.apiKey.isEmpty)
    }

    func testReadAndSaveFailuresKeepFormAndNeverLaunch() {
        let store = Credentials()
        let subject = session(store)
        var launches = 0
        subject.onLaunch = { _ in launches += 1 }
        store.failRead = true
        subject.choose(.openai)
        XCTAssertNotNil(subject.errorMessage)
        store.failRead = false
        subject.draft.apiKey = "fake-new-key"
        store.failSave = true
        subject.saveAndLaunch()
        XCTAssertFalse(subject.isRunning)
        XCTAssertNotNil(subject.errorMessage)
        XCTAssertEqual(subject.draft.apiKey, "fake-new-key")
        XCTAssertNil(store.values[.openai])
        XCTAssertEqual(launches, 0)
    }

    func testEditDoesNotAutolaunchAndDeleteOnlyAffectsSelectedProvider() {
        let store = Credentials()
        store.values = [.claude: AIConnection(apiKey: "claude-test"), .openai: AIConnection(apiKey: "openai-test")]
        let subject = session(store)
        subject.choose(.claude, edit: true)
        XCTAssertFalse(subject.isRunning)
        XCTAssertTrue(subject.hasSavedConnection)
        subject.forgetConnection()
        XCTAssertNil(store.values[.claude])
        XCTAssertEqual(store.values[.openai]?.apiKey, "openai-test")
        subject.back()
        XCTAssertNil(subject.provider)
        XCTAssertTrue(subject.draft.apiKey.isEmpty)
    }

    func testInvalidInputDoesNotReplaceSavedConnection() {
        let store = Credentials()
        store.values[.openai] = AIConnection(apiKey: "old-key")
        let subject = session(store)
        subject.choose(.openai, edit: true)
        subject.draft.baseURL = "https://user:password@example.com/v1"
        subject.saveAndLaunch()
        XCTAssertFalse(subject.isRunning)
        XCTAssertEqual(store.values[.openai]?.apiKey, "old-key")
        XCTAssertEqual(store.writes, 0)
    }

    func testEndpointsAndControlCharacters() throws {
        XCTAssertEqual(try AIConnection(apiKey: " key ").validated(for: .openai).baseURL, "https://api.openai.com/v1")
        XCTAssertEqual(try AIConnection(apiKey: "key", baseURL: "http://127.0.0.1:1234/v1/").validated(for: .openai).baseURL, "http://127.0.0.1:1234/v1")
        for endpoint in ["http://remote.example/v1", "file:///tmp/api", "https://example.com/?key=secret", "https://example.com/#secret", "https://user@example.com", "https://example.com/\npath"] {
            XCTAssertThrowsError(try AIConnection(apiKey: "key", baseURL: endpoint).validated(for: .openai), endpoint)
        }
        XCTAssertThrowsError(try AIConnection(apiKey: "key\nother").validated(for: .claude))
        XCTAssertThrowsError(try AIConnection(apiKey: "key", model: "model\0other").validated(for: .claude))
    }

    func testSecretsNeverAppearInCommandAndProvidersHaveSeparateEnvironment() throws {
        let key = "test-secret-'$(do-not-execute)"
        let claude = try AILaunchConfiguration.make(provider: .claude, connection: AIConnection(apiKey: key), executable: "/usr/bin/true")
        let openai = try AILaunchConfiguration.make(provider: .openai, connection: AIConnection(apiKey: key), executable: "/usr/bin/true")
        XCTAssertFalse(claude.command.contains(key))
        XCTAssertFalse(openai.command.contains(key))
        XCTAssertEqual(claude.environment["THEALL_OPENAI_API_KEY"], "")
        XCTAssertEqual(openai.environment["ANTHROPIC_API_KEY"], "")
        XCTAssertEqual(openai.environment["THEALL_OPENAI_API_KEY"], key)
        XCTAssertTrue(openai.command.contains("model_provider=\"theall\""))
        XCTAssertTrue(openai.command.contains("requires_openai_auth=false"))
        XCTAssertTrue(openai.command.contains("base_url=\"https://api.openai.com/v1\""))
        XCTAssertTrue(openai.command.contains("--no-daemon"))
        XCTAssertTrue(claude.command.contains("'--setting-sources' ''"))
        XCTAssertTrue(claude.environment["CLAUDE_CONFIG_DIR"]?.contains("/Library/Application Support/") == true)
        XCTAssertFalse(openai.command.contains(" login "))
        let chatArguments = openai.chatConfiguration(for: .openai).arguments
        XCTAssertTrue(chatArguments.contains("approval_policy=\"never\""))
        XCTAssertTrue(chatArguments.contains("sandbox_mode=\"danger-full-access\""))
        let bearer = try AILaunchConfiguration.make(provider: .claude, connection: AIConnection(apiKey: key, useBearerToken: true), executable: "/usr/bin/true")
        XCTAssertEqual(bearer.environment["ANTHROPIC_AUTH_TOKEN"], key)
        XCTAssertEqual(bearer.environment["ANTHROPIC_API_KEY"], "")
    }

    func testShellQuotingPassesModelAsSingleLiteralArgument() throws {
        let model = "model'with spaces;$HOME`whoami`$(printf hacked)"
        let configuration = try AILaunchConfiguration.make(provider: .claude,
            connection: AIConnection(apiKey: "fake", model: model), executable: "/usr/bin/printf")
        // printf as a fake CLI reports argv verbatim; no network or real key.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "printf '%s' " + AILaunchConfiguration.shellQuote(model)]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8), model)
        XCTAssertTrue(configuration.command.contains(AILaunchConfiguration.shellQuote(model)))
    }

    @MainActor func testEveryNewLeafIsGatedAndCachedWithoutCreatingSurface() {
        let persistenceKey = "AITerminalTests." + UUID().uuidString
        defer { UserDefaults.standard.removeObject(forKey: persistenceKey) }
        let store = WorkspaceStore(persistenceKey: persistenceKey)
        store.createWorkspace(name: "AI Test")
        let view = TabContentView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        view.store = store
        guard let workspace = store.selectedWorkspace else { return XCTFail("missing initial workspace") }
        view.loadWorkspace(workspace)
        func panes(_ view: NSView) -> [AITerminalPaneView] {
            (view as? AITerminalPaneView).map { [$0] } ?? view.subviews.flatMap(panes)
        }
        let original = panes(view).first!
        XCTAssertNil(original.session.chat)
        view.loadWorkspace(workspace)
        XCTAssertTrue(panes(view).first === original)
        store.splitTerminal(id: workspace.selectedTab!.focusedTerminalId, in: workspace.id,
                            tabId: workspace.selectedTab!.id, direction: .vertical)
        view.loadWorkspace(store.selectedWorkspace!)
        XCTAssertEqual(panes(view).count, 2)
        XCTAssertTrue(panes(view).contains { $0 === original })
        XCTAssertTrue(panes(view).allSatisfy { $0.session.chat == nil && $0.session.provider == nil })
    }

    func testKeychainRoundTripAcrossStoreInstances() throws {
        let service = "TheAllTests." + UUID().uuidString
        let first = KeychainAICredentialStore(service: service)
        defer {
            try? first.delete(for: .claude)
            try? first.delete(for: .openai)
        }
        XCTAssertNil(try first.load(for: .claude))
        let connection = AIConnection(apiKey: "fake-key-for-keychain-test", baseURL: "https://gateway.example", model: "custom")
        try first.save(connection, for: .claude)
        let reopened = KeychainAICredentialStore(service: service)
        XCTAssertEqual(try reopened.load(for: .claude), connection)
        XCTAssertNil(try reopened.load(for: .openai))
        let replacement = AIConnection(apiKey: "fake-replacement")
        try reopened.save(replacement, for: .claude)
        XCTAssertEqual(try first.load(for: .claude), replacement)
        try first.delete(for: .claude)
        XCTAssertNil(try reopened.load(for: .claude))
    }

    func testPersistentHelperMigratesAndReopensWithoutReplacingItsExecutable() throws {
        try withIsolatedKeychain(modern: true) { keychain, defaults in
            let installation = FileManager.default.temporaryDirectory.appendingPathComponent("TheAllHelperTest-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: installation) }
            var path = [CChar](repeating: 0, count: 4096)
            var length = UInt32(path.count)
            XCTAssertEqual(SecKeychainGetPath(keychain, &length, &path), errSecSuccess)
            let keychainPath = String(cString: path)
            let legacy = Credentials()
            let connection = AIConnection(apiKey: "fake-persistent-helper-key", baseURL: "https://fixture.example", model: "fixture")
            legacy.values[.claude] = connection
            func store() -> PersistentAICredentialStore {
                PersistentAICredentialStore(legacy: legacy, defaults: defaults, installationRoot: installation, keychainPath: keychainPath)
            }
            XCTAssertEqual(try store().load(for: .claude), connection)
            let helper = try XCTUnwrap(FileManager.default.enumerator(at: installation, includingPropertiesForKeys: nil)?
                .allObjects.compactMap { $0 as? URL }.first { $0.lastPathComponent == "TheAllCredentialHelper" })
            let original = try Data(contentsOf: helper)
            legacy.values.removeAll()
            // Every call launches a new helper process, using the same installed executable.
            XCTAssertEqual(try store().load(for: .claude), connection)
            XCTAssertEqual(try store().load(for: .claude), connection)
            XCTAssertNil(try store().load(for: .openai))
            var updated = connection; updated.model = "changed"
            try store().save(updated, for: .claude)
            XCTAssertEqual(try store().load(for: .claude), updated)
            XCTAssertEqual(try Data(contentsOf: helper), original)
            // Modern keychains contain a partition ACL; old /tmp fixtures do not.
            var item: CFTypeRef?
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: Bundle.main.bundleIdentifier! + ".ai-connections.v3",
                kSecAttrAccount as String: "claude", kSecMatchSearchList as String: [keychain], kSecReturnRef as String: true]
            XCTAssertEqual(SecItemCopyMatching(query as CFDictionary, &item), errSecSuccess)
            var access: SecAccess?, acls: CFArray?
            XCTAssertEqual(SecKeychainItemCopyAccess(try XCTUnwrap(item) as! SecKeychainItem, &access), errSecSuccess)
            XCTAssertEqual(SecAccessCopyACLList(try XCTUnwrap(access), &acls), errSecSuccess)
            XCTAssertTrue((acls as? [SecACL] ?? []).contains { (SecACLCopyAuthorizations($0) as? [String] ?? []).contains("ACLAuthorizationPartitionID") })
            try store().delete(for: .claude)
            legacy.values[.claude] = connection
            XCTAssertNil(try store().load(for: .claude)) // Forget must not migrate again.
            try store().save(connection, for: .openai)
            XCTAssertEqual(SecKeychainLock(keychain), errSecSuccess)
            XCTAssertThrowsError(try store().load(for: .openai)) { error in
                guard case AIConnectionError.credentialAuthorizationRequired = error else { return XCTFail("Unexpected error: \(error)") }
            }
        }
    }

    func testPersistentHelperCanReplaceInaccessibleLegacyWithoutChangingOldItem() throws {
        struct BlockedLegacy: AICredentialStore {
            func load(for provider: AIProvider) throws -> AIConnection? { throw AIConnectionError.credentialAuthorizationRequired }
            func save(_ connection: AIConnection, for provider: AIProvider) throws { XCTFail("Must not replace legacy storage") }
            func delete(for provider: AIProvider) throws { XCTFail("Must not delete legacy storage") }
        }
        try withIsolatedKeychain(modern: true) { keychain, defaults in
            let installation = FileManager.default.temporaryDirectory.appendingPathComponent("TheAllHelperTest-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: installation) }
            var path = [CChar](repeating: 0, count: 4096); var length = UInt32(path.count)
            XCTAssertEqual(SecKeychainGetPath(keychain, &length, &path), errSecSuccess)
            let store = PersistentAICredentialStore(legacy: BlockedLegacy(), defaults: defaults,
                installationRoot: installation, keychainPath: String(cString: path))
            XCTAssertThrowsError(try store.load(for: .claude)) { error in
                guard case AIConnectionError.legacyCredentialAuthorizationRequired = error else { return XCTFail("Unexpected error: \(error)") }
            }
            let connection = AIConnection(apiKey: "fake-reentry")
            try store.save(connection, for: .claude)
            XCTAssertEqual(try store.load(for: .claude), connection)
        }
    }

    private func withIsolatedKeychain(modern: Bool = false, _ body: (SecKeychain, UserDefaults) throws -> Void) throws {
        let base = modern ? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Keychains") : FileManager.default.temporaryDirectory
        let root = base.appendingPathComponent("TheAllKeychain-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = root.lastPathComponent
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var reference: SecKeychain?
        let password = Array("fake-isolated-test-password".utf8)
        let status = password.withUnsafeBytes {
            SecKeychainCreate(root.appendingPathComponent("fixture.keychain").path, UInt32(password.count), $0.baseAddress, false, nil, &reference)
        }
        XCTAssertEqual(status, errSecSuccess)
        let keychain = try XCTUnwrap(reference)
        defer { SecKeychainDelete(keychain) }
        try body(keychain, defaults)
    }

    func testLegacyCredentialMigrationAndForgetDoNotRestoreOldConnection() throws {
        try withIsolatedKeychain { keychain, defaults in
            let legacy = KeychainAICredentialStore(service: "fixture-old", defaults: defaults, keychain: keychain)
            let current = KeychainAICredentialStore(service: "fixture-new", legacyService: "fixture-old", defaults: defaults, keychain: keychain)
            let connection = AIConnection(apiKey: "fake-migration-key")
            try legacy.save(connection, for: .claude)
            XCTAssertEqual(try current.load(for: .claude), connection)
            XCTAssertEqual(try legacy.load(for: .claude), connection)
            try current.delete(for: .claude)
            XCTAssertNil(try current.load(for: .claude))
            XCTAssertEqual(try legacy.load(for: .claude), connection)
        }
    }

    func testUnauthorizedLegacyCredentialDoesNotPromptAndCanBeReplacedSeparately() throws {
        try withIsolatedKeychain { keychain, defaults in
            var access: SecAccess?
            // An empty trusted application list requires authorization. The
            // fixture contains only fake data in its own temporary keychain.
            XCTAssertEqual(SecAccessCreate("TheAll authorization fixture" as CFString, [] as CFArray, &access), errSecSuccess)
            let protected: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: "fixture-blocked", kSecAttrAccount as String: AIProvider.claude.rawValue,
                kSecUseKeychain as String: keychain, kSecAttrAccess as String: try XCTUnwrap(access),
                kSecValueData as String: try JSONEncoder().encode(AIConnection(apiKey: "fake-blocked-key"))]
            XCTAssertEqual(SecItemAdd(protected as CFDictionary, nil), errSecSuccess)
            let current = KeychainAICredentialStore(service: "fixture-new", legacyService: "fixture-blocked", defaults: defaults, keychain: keychain)
            var before = DarwinBoolean(false), after = DarwinBoolean(false)
            XCTAssertEqual(SecKeychainGetUserInteractionAllowed(&before), errSecSuccess)
            XCTAssertThrowsError(try current.load(for: .claude)) { error in
                guard case AIConnectionError.legacyCredentialAuthorizationRequired = error else { return XCTFail("Unexpected error: \(error)") }
            }
            let blockedCurrent = KeychainAICredentialStore(service: "fixture-blocked", defaults: defaults, keychain: keychain)
            XCTAssertThrowsError(try blockedCurrent.load(for: .claude)) { error in
                guard case AIConnectionError.credentialAuthorizationRequired = error else { return XCTFail("Unexpected error: \(error)") }
            }
            XCTAssertEqual(SecKeychainGetUserInteractionAllowed(&after), errSecSuccess)
            XCTAssertEqual(before.boolValue, after.boolValue)
            let replacement = AIConnection(apiKey: "fake-new-key")
            try current.save(replacement, for: .claude)
            XCTAssertEqual(try current.load(for: .claude), replacement)
            try current.delete(for: .claude)
            XCTAssertNil(try current.load(for: .claude))
            XCTAssertEqual(SecKeychainLock(keychain), errSecSuccess)
            XCTAssertThrowsError(try current.save(replacement, for: .openai))
            XCTAssertEqual(SecKeychainGetUserInteractionAllowed(&after), errSecSuccess)
            XCTAssertEqual(before.boolValue, after.boolValue)
        }
    }

    @MainActor func testSurfaceEnvironmentIsolationAndExitLifecycle() throws {
        var displayCount: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &displayCount) == .success, displayCount > 0 else {
            throw XCTSkip("Requires an active display for Ghostty rendering")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TheAllSurfaceTest-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let binary = directory.appendingPathComponent("fake-ai")
        // A real Ghostty PTY launches this harmless fixture instead of any AI
        // CLI. Read only variables the launcher explicitly supplies with fake keys.
        let script = """
        #!/bin/sh
        printf '%s\\n' "$ANTHROPIC_API_KEY" "$THEALL_OPENAI_API_KEY" "$ANTHROPIC_BASE_URL" "$THEALL_TERMINAL_ID" > \(AILaunchConfiguration.shellQuote(directory.appendingPathComponent("result").path))
        exit 7
        """
        try script.write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        let store = Credentials()
        store.values[.openai] = AIConnection(apiKey: "fake-surface-key")
        let subject = AITerminalSession(credentials: store) {
            try AILaunchConfiguration.make(provider: $0, connection: $1, executable: binary.path)
        }
        let pane = AITerminalPaneView(session: subject)
        let terminalID = UUID()
        var terminal: GhosttyTerminalView?
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 650),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = pane
        window.orderFront(nil)
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        defer {
            if subject.isRunning { subject.back() }
            window.contentView = nil
            window.close()
        }
        pane.layoutSubtreeIfNeeded()
        XCTAssertNil(terminal)
        func attachPreview(_ name: String) {
            pane.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            guard let bitmap = pane.bitmapImageRepForCachingDisplay(in: pane.bounds) else { return }
            pane.cacheDisplay(in: pane.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else { return }
            let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        attachPreview("AI provider selection")
        subject.choose(.openai, edit: true)
        attachPreview("AI connection settings")
        subject.back()
        subject.onLaunch = { configuration in
            let view = GhosttyTerminalView(frame: pane.bounds)
            view.terminalId = terminalID
            view.aiLaunchConfiguration = configuration
            view.onProcessExit = { subject.processExited($0) }
            terminal = view
            window.contentView = view
        }
        subject.choose(.openai)
        XCTAssertNotNil(terminal?.rawSurface)
        for _ in 0..<100 {
            if subject.exitCode != nil { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        let data = try? Data(contentsOf: directory.appendingPathComponent("result"))
        let result = data.flatMap { String(data: $0, encoding: .utf8) }
        XCTAssertEqual(result, "\nfake-surface-key\n\n" + terminalID.uuidString + "\n")
        // Ghostty’s macOS login wrapper does not preserve numeric exit codes.
        XCTAssertNotNil(subject.exitCode)
        // Leaving setup and coming back releases the process and clears the key.
        subject.back()
        terminal?.removeFromSuperview()
        terminal = nil
        XCTAssertFalse(subject.isRunning)
        XCTAssertNil(subject.provider)
    }
}
