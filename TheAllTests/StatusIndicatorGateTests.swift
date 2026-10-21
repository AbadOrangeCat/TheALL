import XCTest
@testable import TheAll

final class StatusIndicatorGateTests: XCTestCase {

    private var tmpPath: String!
    private var settings: SettingsConfigStore!

    override func setUpWithError() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("theall-gate-\(UUID().uuidString).conf")
        tmpPath = tmp.path
        settings = SettingsConfigStore(filePath: tmpPath)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: tmpPath)
    }

    func testGateFalseWhenAllAgentsOff() {
        XCTAssertFalse(StatusIndicatorGate.anyAgentEnabled(settings))
    }

    func testGateFalseWhenAgentsExplicitlyFalse() {
        for agent in HookMessage.Agent.allCases {
            settings.set(agent.settingsKey, "false")
        }
        settings.save()
        XCTAssertFalse(StatusIndicatorGate.anyAgentEnabled(settings))
    }

    func testGateTrueWhenClaudeOn() {
        settings.set(HookMessage.Agent.claude.settingsKey, "true"); settings.save()
        XCTAssertTrue(StatusIndicatorGate.anyAgentEnabled(settings))
    }

    func testGateTrueWhenCodexOn() {
        settings.set(HookMessage.Agent.codex.settingsKey, "true"); settings.save()
        XCTAssertTrue(StatusIndicatorGate.anyAgentEnabled(settings))
    }

    func testGateTrueWhenOpenCodeOn() {
        settings.set(HookMessage.Agent.opencode.settingsKey, "true"); settings.save()
        XCTAssertTrue(StatusIndicatorGate.anyAgentEnabled(settings))
    }

    func testGateTrueWhenAllAgentsOn() {
        for agent in HookMessage.Agent.allCases {
            settings.set(agent.settingsKey, "true")
        }
        settings.save()
        XCTAssertTrue(StatusIndicatorGate.anyAgentEnabled(settings))
    }

    func testGateIgnoresRemovedMasterKey() {
        // Old `theall-status-indicators=true` in a user's config must not
        // resurrect the feature — only per-agent keys count.
        settings.set("theall-status-indicators", "true"); settings.save()
        XCTAssertFalse(StatusIndicatorGate.anyAgentEnabled(settings))
    }
}
