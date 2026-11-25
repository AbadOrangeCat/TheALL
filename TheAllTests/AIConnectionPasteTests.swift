import XCTest
@testable import TheAll

/// Pasting a whole settings block into the connection form. Every key below
/// is a fixture, not a real credential.
final class AIConnectionPasteTests: XCTestCase {
    private let fakeKey = "sk-test-0000000000000000000000000000000000000000"

    func testClaudeCodeSettingsJSON() throws {
        let text = """
        {
          "$schema": "https://json.schemastore.org/claude-code-settings.json",
          "env": {
            "ANTHROPIC_BASE_URL": "https://relay.example.test",
            "ANTHROPIC_AUTH_TOKEN": "\(fakeKey)",
            "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1"
          }
        }
        """
        let parsed = try XCTUnwrap(AIConnectionPaste.parse(text))
        XCTAssertEqual(parsed.apiKey, fakeKey)
        XCTAssertEqual(parsed.baseURL, "https://relay.example.test")
        XCTAssertNil(parsed.model)
        XCTAssertEqual(parsed.useBearerToken, true)
        XCTAssertEqual(parsed.provider, .claude)
        XCTAssertEqual(parsed.ignored, ["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"])
        XCTAssertEqual(parsed.fields, [.apiKey, .baseURL])

        var connection = AIConnection(apiKey: "old")
        parsed.apply(to: &connection, provider: .claude)
        XCTAssertEqual(connection, AIConnection(apiKey: fakeKey, baseURL: "https://relay.example.test", useBearerToken: true))
        // Bearer is a Claude-only setting.
        var openAI = AIConnection(apiKey: "old")
        parsed.apply(to: &openAI, provider: .openai)
        XCTAssertFalse(openAI.useBearerToken)
    }

    func testBrokenJSONFallsBackToScanning() throws {
        // A fragment copied from the middle of settings.json, with a trailing comma.
        let text = """
            "ANTHROPIC_API_KEY": "\(fakeKey)",
            "ANTHROPIC_MODEL": "claude-fixture-1",
        """
        let parsed = try XCTUnwrap(AIConnectionPaste.parse(text))
        XCTAssertEqual(parsed.apiKey, fakeKey)
        XCTAssertEqual(parsed.model, "claude-fixture-1")
        XCTAssertEqual(parsed.useBearerToken, false)
    }

    func testShellExportsPowerShellAndCmdLines() throws {
        for text in [
            "export OPENAI_BASE_URL=https://gateway.example.test/v1\nexport OPENAI_API_KEY='\(fakeKey)'",
            "$env:OPENAI_API_KEY=\"\(fakeKey)\"\r\n$env:OPENAI_BASE_URL=\"https://gateway.example.test/v1\"",
            "set OPENAI_API_KEY=\(fakeKey)\nset OPENAI_BASE_URL=https://gateway.example.test/v1",
            "setx OPENAI_API_KEY \"\(fakeKey)\"\nsetx OPENAI_BASE_URL https://gateway.example.test/v1",
            // Line breaks collapsed into spaces by a single-line field.
            "OPENAI_API_KEY=\(fakeKey) OPENAI_BASE_URL=https://gateway.example.test/v1",
        ] {
            let parsed = try XCTUnwrap(AIConnectionPaste.parse(text), text)
            XCTAssertEqual(parsed.apiKey, fakeKey, text)
            XCTAssertEqual(parsed.baseURL, "https://gateway.example.test/v1", text)
            XCTAssertEqual(parsed.provider, .openai, text)
            XCTAssertNil(parsed.useBearerToken, text)
        }
    }

    func testCodexTomlAndLooseNotes() throws {
        let toml = """
        model = "gpt-fixture"
        model_provider = "relay"
        [model_providers.relay]
        base_url = "https://codex.example.test/v1"
        env_key = "OPENAI_API_KEY"
        """
        let parsed = try XCTUnwrap(AIConnectionPaste.parse(toml))
        XCTAssertEqual(parsed.model, "gpt-fixture")
        XCTAssertEqual(parsed.baseURL, "https://codex.example.test/v1")
        XCTAssertNil(parsed.apiKey, "env_key names a variable; it is not the key")

        let notes = "Base URL: https://notes.example.test\nAPI Key: \(fakeKey)"
        let loose = try XCTUnwrap(AIConnectionPaste.parse(notes))
        XCTAssertEqual(loose.apiKey, fakeKey)
        XCTAssertEqual(loose.baseURL, "https://notes.example.test")
        XCTAssertNil(loose.provider)
    }

    func testSpecificNamesWinOverGenericOnesInAnyOrder() throws {
        let text = "API_KEY=generic-fixture-key\nANTHROPIC_AUTH_TOKEN=\(fakeKey)\nURL=https://generic.example.test\nANTHROPIC_BASE_URL=https://specific.example.test"
        let parsed = try XCTUnwrap(AIConnectionPaste.parse(text))
        XCTAssertEqual(parsed.apiKey, fakeKey)
        XCTAssertEqual(parsed.baseURL, "https://specific.example.test")
        XCTAssertEqual(parsed.useBearerToken, true)
    }

    func testBareKeysAndPlaceholdersAreLeftAlone() throws {
        // Typing or pasting just a key keeps working as before.
        XCTAssertNil(AIConnectionPaste.parse(fakeKey))
        XCTAssertNil(AIConnectionPaste.parse("c2stdGVzdC1maXh0dXJlLWtleQ=="))
        XCTAssertNil(AIConnectionPaste.parse("sk-ant-api03-fixture"))
        XCTAssertNil(AIConnectionPaste.parse(""))
        XCTAssertNil(AIConnectionPaste.parse("OPENAI_API_KEY=${OPENAI_API_KEY}\nANTHROPIC_API_KEY=<your key>"))
        XCTAssertNil(AIConnectionPaste.parse("{\"env\": {\"CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC\": \"1\"}}"))
        // The explicit paste button also accepts a single key or URL.
        XCTAssertEqual(AIConnectionPaste.parseClipboard("  \(fakeKey)\n"), AIConnectionPaste(apiKey: fakeKey))
        XCTAssertEqual(AIConnectionPaste.parseClipboard("https://relay.example.test"), AIConnectionPaste(baseURL: "https://relay.example.test"))
        XCTAssertNil(AIConnectionPaste.parseClipboard("two words"))
    }
}
