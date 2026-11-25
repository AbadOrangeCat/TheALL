import XCTest
@testable import TheAll

/// Which Lot Map station a tool call lights. Same cases as desktop/test/activity-map.test.mjs.
final class AIActivityStationTests: XCTestCase {
    func testMemoryIncludesTheAllsOwnConfigDirectoriesAndInstructionFiles() {
        for path in ["/Users/u/Library/Application Support/com.mux0.app.dev/claude/projects/-Users-u-app/memory/MEMORY.md",
                     "/home/u/.claude/projects/p/memory/notes.md",
                     "C:\\Users\\u\\AppData\\Roaming\\TheAll\\claude\\projects\\p\\memory\\a.md",
                     "C:\\Users\\u\\AppData\\Roaming\\TheAll\\codex\\memories\\m.md",
                     "/Users/u/.codex/memories/m.md", "/repo/CLAUDE.md", "/repo/CLAUDE.local.md", "/repo/AGENTS.md"] {
            XCTAssertEqual(AIActivityStation.fileStation(path), "memory", path)
        }
        for path in ["/repo/src/memory/cache.swift", "/repo/docs/CLAUDE.md.bak", "/repo/projects/p/memory/x", nil] {
            XCTAssertEqual(AIActivityStation.fileStation(path), "files", path ?? "nil")
        }
        XCTAssertEqual(AIActivityStation.claudeTool("Write", input: ["file_path": "/x/claude/projects/p/memory/a.md"]), "memory")
    }

    func testShellCommandsThatGoOnlineOrDriveABrowser() {
        let cases: [(String, String)] = [
            ("cd app && git push origin main", "network"), ("curl -s https://example.test", "network"),
            ("GH_TOKEN=$(gh auth token) gh pr list", "network"), ("npm install left-pad", "network"),
            ("python3 -m pip install requests", "network"), ("sudo apt-get update", "network"),
            ("go mod download", "network"), ("Invoke-WebRequest https://example.test", "network"),
            ("open https://example.test", "browser"), ("npx playwright test", "browser"),
            ("start https://example.test", "browser"),
            ("osascript -e 'tell application \"Safari\" to activate'", "browser"),
            ("npm test", "shell"), ("git status && git diff", "shell"), ("ls -la", "shell"), ("open .", "shell"), ("", "shell"),
        ]
        for (command, station) in cases {
            XCTAssertEqual(AIActivityStation.commandStation(command), station, command)
            XCTAssertEqual(AIActivityStation.claudeTool("Bash", input: ["command": command]), station, command)
        }
        XCTAssertEqual(AIActivityStation.claudeTool("Bash", input: nil), "shell", "Streaming start before the input arrives")
        XCTAssertEqual(AIActivityStation.codexItem(["type": "commandExecution", "command": "curl https://example.test",
                                                    "commandActions": [["type": "unknown"]]]), "network")
        XCTAssertEqual(AIActivityStation.codexItem(["type": "commandExecution", "command": "cat a",
                                                    "commandActions": [["type": "read", "path": "/repo/a"]]]), "files")
    }

    func testBrowserAndMemoryMCPServersByName() {
        XCTAssertEqual(AIActivityStation.claudeTool("mcp__puppeteer__navigate", input: [:]), "browser")
        XCTAssertEqual(AIActivityStation.claudeTool("mcp__MyChrome__open", input: [:]), "browser")
        XCTAssertEqual(AIActivityStation.claudeTool("mcp__team-memory__recall", input: [:]), "memory")
        XCTAssertEqual(AIActivityStation.claudeTool("mcp__github__list_issues", input: [:]), "network")
        XCTAssertEqual(AIActivityStation.codexItem(["type": "mcpToolCall", "server": "playwright-mcp", "tool": "click"]), "browser")
    }
}
