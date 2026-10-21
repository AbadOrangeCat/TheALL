import Foundation
import Observation

/// Per-terminal working directory keyed by the terminal UUID. Populated by
/// `GhosttyBridge.onPwdChanged` → main-queue callback; each PTY shell emits OSC 7
/// (`kitty-shell-cwd://`) on startup and every `chpwd`, which ghostty forwards as
/// `GHOSTTY_ACTION_PWD`.
///
/// Persisted to UserDefaults under `theall.pwds.v1` so that on app restart each
/// terminal can reopen in its previous directory. Writes are debounced (300 ms)
/// because `cd`-heavy workflows would otherwise trigger hundreds of writes per
/// second. `GhosttyTerminalView.viewDidMoveToWindow` reads this store to seed
/// `ghostty_surface_config.working_directory` — that's how both "inherit from
/// source pane" (new tab / split / new workspace) and "restore on relaunch"
/// resolve through a single mechanism.
@Observable
final class TerminalPwdStore {
    private var storage: [String: String] = [:]
    private let persistenceKey: String
    private var saveWorkItem: DispatchWorkItem?

    init(persistenceKey: String = "theall.pwds.v1") {
        self.persistenceKey = persistenceKey
        load()
    }

    func pwd(for terminalId: UUID) -> String? {
        storage[terminalId.uuidString]
    }

    func setPwd(_ pwd: String, for terminalId: UUID) {
        storage[terminalId.uuidString] = pwd
        scheduleSave()
    }

    /// Copy `source`'s pwd onto `dest` so the next surface created for `dest`
    /// spawns its shell in that directory. No-op when source has no record
    /// (first-run / shell hasn't emitted OSC 7 yet).
    func inherit(from source: UUID, to dest: UUID) {
        guard let src = storage[source.uuidString] else { return }
        storage[dest.uuidString] = src
        scheduleSave()
    }

    func forget(terminalId: UUID) {
        storage.removeValue(forKey: terminalId.uuidString)
        scheduleSave()
    }

    func pwdsSnapshot() -> [UUID: String] {
        var out: [UUID: String] = [:]
        for (k, v) in storage {
            if let id = UUID(uuidString: k) { out[id] = v }
        }
        return out
    }

    // MARK: - Persistence

    #if DEBUG
    /// Immediately flush any pending debounced save. Used only in tests.
    func flushSaveForTesting() {
        saveWorkItem?.cancel()
        saveWorkItem = nil
        save()
    }
    #endif

    private func scheduleSave() {
        saveWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.save() }
        saveWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: item)
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(storage) else { return }
        UserDefaults.standard.set(data, forKey: persistenceKey)
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: persistenceKey),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data)
        else { return }
        storage = decoded
    }
}
