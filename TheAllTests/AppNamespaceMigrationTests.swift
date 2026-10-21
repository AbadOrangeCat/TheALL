import XCTest
@testable import TheAll

final class AppNamespaceMigrationTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let defaults: UserDefaults
        var source: URL { root.appendingPathComponent("previousapp/config") }
        var destination: URL { root.appendingPathComponent("theall/config") }

        func migrate() throws -> AppNamespaceMigration.Outcome {
            try AppNamespaceMigration.migrate(previousNamespace: "previousapp", defaults: defaults,
                                              applicationSupportRoot: root)
        }
        func write(_ text: String, to url: URL) throws {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
    }

    private func fixture() throws -> Fixture {
        let name = "TheAllNamespaceTests." + UUID().uuidString
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock {
            defaults.removePersistentDomain(forName: name)
            try? FileManager.default.removeItem(at: root)
        }
        return Fixture(root: root, defaults: defaults)
    }

    func testCopiesOnlyMissingPrefixedPreferencesWithoutChangingValues() throws {
        let f = try fixture()
        let data = Data("{\"id\":\"\(UUID())\",\"directory\":\"/previousapp/project\"}".utf8)
        f.defaults.set(data, forKey: "previousapp.workspaces.v2")
        f.defaults.set("fr", forKey: "previousapp.language")
        f.defaults.set("ko", forKey: "theall.language")
        f.defaults.set(true, forKey: "previousapp.enabled")
        f.defaults.set(false, forKey: "theall.enabled")
        f.defaults.set("unrelated", forKey: "previousappOther.value")
        f.defaults.set("unrelated", forKey: "previousapp")
        XCTAssertEqual(try f.migrate(), .migrated)
        XCTAssertEqual(f.defaults.data(forKey: "theall.workspaces.v2"), data)
        XCTAssertEqual(f.defaults.data(forKey: "previousapp.workspaces.v2"), data)
        XCTAssertEqual(f.defaults.string(forKey: "theall.language"), "ko")
        XCTAssertFalse(f.defaults.bool(forKey: "theall.enabled"))
        XCTAssertNil(f.defaults.object(forKey: "theallOther.value"))
        XCTAssertNil(f.defaults.object(forKey: "theall"))
    }

    func testConfigurationChangesKeysOnlyAndKeepsPrivatePermissions() throws {
        let f = try fixture()
        let input = "# previousapp-flag = retained comment\r\n  previousapp-flag = previousapp-value # previousapp-comment\r\ncommand = echo previousapp-value\n\tpreviousapp-other=\"previousapp-string\"\npreviousapp-not-an-assignment\n"
        let expected = "# previousapp-flag = retained comment\r\n  theall-flag = previousapp-value # previousapp-comment\r\ncommand = echo previousapp-value\n\ttheall-other=\"previousapp-string\"\npreviousapp-not-an-assignment\n"
        try f.write(input, to: f.source)
        XCTAssertEqual(try f.migrate(), .migrated)
        XCTAssertEqual(try Data(contentsOf: f.destination), Data(expected.utf8))
        XCTAssertEqual(try Data(contentsOf: f.source), Data(input.utf8))
        let file = try FileManager.default.attributesOfItem(atPath: f.destination.path)
        let folder = try FileManager.default.attributesOfItem(atPath: f.destination.deletingLastPathComponent().path)
        XCTAssertEqual((file[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual((folder[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    }

    func testExistingConfigurationWinsEvenWhenOldConfigurationCannotBeDecoded() throws {
        let f = try fixture()
        try f.write("", to: f.source)
        try Data([0xff, 0xfe]).write(to: f.source)
        try f.write("theall-flag = current\n", to: f.destination)
        XCTAssertEqual(try f.migrate(), .migrated)
        XCTAssertEqual(try String(contentsOf: f.destination, encoding: .utf8), "theall-flag = current\n")
    }

    func testCompletedMigrationNeverRestoresUserDeletedPreferencesOrConfiguration() throws {
        let f = try fixture()
        f.defaults.set("fr", forKey: "previousapp.language")
        try f.write("previousapp-flag = true\n", to: f.source)
        XCTAssertEqual(try f.migrate(), .migrated)
        f.defaults.removeObject(forKey: "theall.language")
        try FileManager.default.removeItem(at: f.destination)
        XCTAssertEqual(try f.migrate(), .alreadyCompleted)
        XCTAssertNil(f.defaults.object(forKey: "theall.language"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.destination.path))
    }

    func testMissingConfigurationIsSuccessfulAndDoesNotImportLaterOldChanges() throws {
        let f = try fixture()
        XCTAssertEqual(try f.migrate(), .migrated)
        try f.write("previousapp-flag = later\n", to: f.source)
        f.defaults.set("later", forKey: "previousapp.new")
        XCTAssertEqual(try f.migrate(), .alreadyCompleted)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.destination.path))
        XCTAssertNil(f.defaults.object(forKey: "theall.new"))
    }

    func testInvalidNamespacesFailBeforeChangingAnyData() throws {
        let f = try fixture()
        f.defaults.set("fr", forKey: "previousapp.language")
        for invalid in ["", ".", "..", "../escape", "/absolute", "old.name", " old", "old ", "old\n", "old\nname", "old\\name", "OLD", String(repeating: "a", count: 65)] {
            XCTAssertThrowsError(try AppNamespaceMigration.migrate(previousNamespace: invalid, defaults: f.defaults,
                                                                   applicationSupportRoot: f.root), invalid)
            XCTAssertThrowsError(try AppNamespaceMigration.migrate(previousNamespace: "previousapp", newNamespace: invalid,
                                                                   defaults: f.defaults, applicationSupportRoot: f.root), invalid)
        }
        XCTAssertNil(f.defaults.object(forKey: "theall.language"))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: f.root.path).isEmpty)
    }

    func testInvalidConfigurationDoesNotCommitMarkerOrPreferencesAndCanBeRetried() throws {
        let f = try fixture()
        f.defaults.set("fr", forKey: "previousapp.language")
        try f.write("", to: f.source)
        try Data([0xff]).write(to: f.source)
        XCTAssertThrowsError(try f.migrate())
        XCTAssertNil(f.defaults.object(forKey: "theall.language"))
        try f.write("previousapp-flag = repaired\n", to: f.source)
        XCTAssertEqual(try f.migrate(), .migrated)
        XCTAssertEqual(f.defaults.string(forKey: "theall.language"), "fr")
    }

    func testSymbolicLinksAreRejectedWithoutWritingThroughThem() throws {
        let f = try fixture()
        let outside = f.root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: f.destination.deletingLastPathComponent(), withDestinationURL: outside)
        try f.write("previousapp-flag = true\n", to: f.source)
        XCTAssertThrowsError(try f.migrate())
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }

    func testConcurrentPublicationChoosesOneWholeFileAndNeverOverwritesIt() throws {
        let f = try fixture()
        let destination = f.root.appendingPathComponent("theall/config")
        let first = Data(repeating: 65, count: 128 * 1024)
        let second = Data(repeating: 66, count: 128 * 1024)
        let lock = NSLock()
        var successes: [Data] = [], errors: [Error] = []
        DispatchQueue.concurrentPerform(iterations: 2) { index in
            let data = index == 0 ? first : second
            do {
                let published = try AppNamespaceMigration.publishConfigurationIfAbsent(data, at: destination)
                lock.lock(); defer { lock.unlock() }
                if published { successes.append(data) }
            } catch {
                lock.lock(); errors.append(error); lock.unlock()
            }
        }
        XCTAssertTrue(errors.isEmpty)
        XCTAssertEqual(successes.count, 1)
        XCTAssertEqual(try Data(contentsOf: destination), try XCTUnwrap(successes.first))
        XCTAssertFalse(try AppNamespaceMigration.publishConfigurationIfAbsent(Data("later".utf8), at: destination))
        XCTAssertEqual(try Data(contentsOf: destination), successes.first)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.deletingLastPathComponent().path), ["config"])
    }

    func testCompletionIsScopedToNamespacePair() throws {
        let f = try fixture()
        f.defaults.set("first", forKey: "previousapp.first")
        f.defaults.set("second", forKey: "anotherapp.second")
        XCTAssertEqual(try f.migrate(), .migrated)
        XCTAssertEqual(try AppNamespaceMigration.migrate(previousNamespace: "anotherapp", defaults: f.defaults,
                                                        applicationSupportRoot: f.root), .migrated)
        XCTAssertEqual(f.defaults.string(forKey: "theall.first"), "first")
        XCTAssertEqual(f.defaults.string(forKey: "theall.second"), "second")
    }
}
