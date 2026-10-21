import XCTest
@testable import TheAll

final class TerminalPwdStoreTests: XCTestCase {

    func testDefaultIsEmpty() {
        let store = TerminalPwdStore(persistenceKey: "test-\(UUID())")
        XCTAssertNil(store.pwd(for: UUID()))
    }

    func testSetPwdPersists() {
        let key = "test-\(UUID())"
        let id = UUID()
        let store = TerminalPwdStore(persistenceKey: key)
        store.setPwd("/tmp/foo", for: id)
        store.flushSaveForTesting()

        let store2 = TerminalPwdStore(persistenceKey: key)
        XCTAssertEqual(store2.pwd(for: id), "/tmp/foo")

        UserDefaults.standard.removeObject(forKey: key)
    }

    func testSetPwdPersistsViaDebounce() {
        let key = "test-\(UUID())"
        let id = UUID()
        let store = TerminalPwdStore(persistenceKey: key)
        store.setPwd("/tmp/debounce-test", for: id)
        // Wait for the real debounce timer to fire (0.3s) instead of flushing.
        let exp = expectation(description: "debounce fires after 300ms")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)

        let store2 = TerminalPwdStore(persistenceKey: key)
        XCTAssertEqual(store2.pwd(for: id), "/tmp/debounce-test")
        UserDefaults.standard.removeObject(forKey: key)
        // Reference `store` so the compiler keeps it alive past the wait; otherwise
        // ARC could deallocate it before the debounce fires, cancelling the save.
        _ = store
    }

    func testInheritCopiesPwd() {
        let store = TerminalPwdStore(persistenceKey: "test-\(UUID())")
        let src = UUID(); let dst = UUID()
        store.setPwd("/tmp/bar", for: src)
        store.inherit(from: src, to: dst)
        XCTAssertEqual(store.pwd(for: dst), "/tmp/bar")
    }

    func testInheritWithoutSourceIsNoop() {
        let store = TerminalPwdStore(persistenceKey: "test-\(UUID())")
        let src = UUID(); let dst = UUID()
        store.inherit(from: src, to: dst)
        XCTAssertNil(store.pwd(for: dst))
    }

    func testForgetRemovesEntry() {
        let store = TerminalPwdStore(persistenceKey: "test-\(UUID())")
        let id = UUID()
        store.setPwd("/tmp/baz", for: id)
        store.forget(terminalId: id)
        XCTAssertNil(store.pwd(for: id))
    }

    func testPwdsSnapshotReturnsAll() {
        let store = TerminalPwdStore(persistenceKey: "test-\(UUID())")
        let a = UUID(); let b = UUID()
        store.setPwd("/tmp/a", for: a)
        store.setPwd("/tmp/b", for: b)
        let snap = store.pwdsSnapshot()
        XCTAssertEqual(snap.count, 2)
        XCTAssertEqual(snap[a], "/tmp/a")
        XCTAssertEqual(snap[b], "/tmp/b")
    }
}
