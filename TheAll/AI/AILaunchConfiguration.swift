import Foundation

/// Secrets are passed only through Ghostty's per-surface environment, never as
/// shell input, arguments, configuration files, or changes to the host process.
struct AILaunchConfiguration {
    let command: String
    var environment: [String: String]
    var executable: String? = nil
    var arguments: [String] = []

    static var claudeConfigurationDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.theall.app.dev")
            .appendingPathComponent("claude")
    }

    static func make(provider: AIProvider, connection: AIConnection,
                     executable: String? = nil,
                     inheritedPath: String = ProcessInfo.processInfo.environment["PATH"] ?? "") throws -> Self {
        let connection = try connection.validated(for: provider)
        let searchPaths = ([NSHomeDirectory() + "/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"]
            + inheritedPath.components(separatedBy: ":") + ["/usr/bin", "/bin", "/usr/sbin", "/sbin"])
            .filter { $0.hasPrefix("/") }
        guard let binary = executable ?? searchPaths.map({ $0 + "/" + provider.executable })
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) })
        else { throw AIConnectionError.missingCLI(provider.executable) }

        // Empty overrides prevent inherited credentials / alternate Claude cloud
        // backends from silently taking priority over the user's selection.
        var environment = Dictionary(uniqueKeysWithValues: [
            "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL",
            "CLAUDE_CODE_OAUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR",
            "CLAUDE_CODE_API_KEY_FILE_DESCRIPTOR", "ANTHROPIC_CUSTOM_HEADERS", "ANTHROPIC_UNIX_SOCKET",
            // These inherited overrides win over SDK effort settings, even
            // when apply_flag_settings acknowledges the selected level.
            "CLAUDE_CODE_EFFORT_LEVEL", "CLAUDE_CODE_EXTRA_BODY",
            "OPENAI_API_KEY", "OPENAI_BASE_URL", "THEALL_OPENAI_API_KEY",
        ].map { ($0, "") })
        environment["PATH"] = ([URL(fileURLWithPath: binary).deletingLastPathComponent().path] + searchPaths)
            .joined(separator: ":")
        environment["CLAUDE_CODE_USE_BEDROCK"] = "0"
        environment["CLAUDE_CODE_USE_VERTEX"] = "0"
        environment["CLAUDE_CODE_USE_FOUNDRY"] = "0"
        environment["CLAUDE_CODE_USE_ANTHROPIC_AWS"] = "0"
        environment["CLAUDE_CODE_USE_ANTHROPIC_GOOGLE_CLOUD"] = "0"
        environment["CLAUDE_CODE_USE_MANTLE"] = "0"
        environment["CLAUDE_CODE_USE_GATEWAY"] = "0"

        var arguments = [binary]
        switch provider {
        case .claude:
            // Claude settings.env overrides process.env. Keep the app's CLI
            // state separate from an existing login/gateway, and do not load
            // user/project settings that could reroute this connection's key.
            environment["CLAUDE_CONFIG_DIR"] = claudeConfigurationDirectory.path
            environment[connection.useBearerToken ? "ANTHROPIC_AUTH_TOKEN" : "ANTHROPIC_API_KEY"] = connection.apiKey
            environment["ANTHROPIC_BASE_URL"] = connection.baseURL
            // A saved apiKeyHelper or login must not override this session's key.
            arguments += ["--setting-sources", "", "--settings", "{\"apiKeyHelper\":\"\"}"]
            if !connection.model.isEmpty { arguments += ["--model", connection.model] }
        case .openai:
            // A shared background daemon may have been started with another
            // session's environment. Keep authentication with this CLI process.
            arguments += ["--no-daemon"]
            environment["THEALL_OPENAI_API_KEY"] = connection.apiKey
            // A separate provider uses env_key even if ~/.codex contains a
            // ChatGPT login. No `codex login` and no writes to the user's auth.json.
            let overrides = [
                "model_provider": tomlString("theall"),
                "model_providers.theall.name": tomlString("OpenAI"),
                "model_providers.theall.base_url": tomlString(connection.baseURL),
                "model_providers.theall.env_key": tomlString("THEALL_OPENAI_API_KEY"),
                "model_providers.theall.wire_api": tomlString("responses"),
                "model_providers.theall.requires_openai_auth": "false",
            ]
            for key in overrides.keys.sorted() { arguments += ["-c", key + "=" + overrides[key]!] }
            if !connection.model.isEmpty { arguments += ["--model", connection.model] }
        }
        // Ghostty on macOS already wraps this in `exec -l`; adding another
        // exec would try to execute a binary literally named "exec".
        return Self(command: arguments.map(shellQuote).joined(separator: " "), environment: environment,
                    executable: binary, arguments: Array(arguments.dropFirst()))
    }

    func chatConfiguration(for provider: AIProvider) -> Self {
        var result = self
        switch provider {
        case .claude:
            result.arguments += ["--print", "--input-format", "stream-json", "--output-format", "stream-json",
                                 "--verbose", "--include-partial-messages", "--permission-prompt-tool", "stdio",
                                 "--dangerously-skip-permissions"]
        case .openai:
            result.arguments += ["-c", "approval_policy=\"never\"", "-c", "sandbox_mode=\"danger-full-access\"",
                                 "app-server", "--listen", "stdio://"]
        }
        return result
    }

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    private static func tomlString(_ value: String) -> String {
        // TOML does not recognize JSON's optional escaped forward slash.
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        return String(data: try! encoder.encode(value), encoding: .utf8)!
    }
}
