import Foundation

/// Transcript-cleanup provider backed by the user's locally-installed
/// `claude` CLI — no API key, auth rides the existing CLI login (like Orion).
struct ClaudeCLILLM: LLMProvider {
    static let providerID: LLMProviderID = .claudeCLI

    /// Cleanup is a tiny, constrained transform — Haiku is plenty and keeps
    /// latency down. Users signed into the CLI pay nothing per call.
    private let model: String
    private let timeoutSeconds: TimeInterval

    init(model: String = "haiku", timeoutSeconds: TimeInterval = 45) {
        self.model = model
        self.timeoutSeconds = timeoutSeconds
    }

    func complete(request: LLMRequest) async throws -> LLMResponse {
        try await LocalCLICompletion.complete(
            tool: .claude,
            request: request,
            model: model,
            timeoutSeconds: timeoutSeconds
        )
    }
}

/// Transcript-cleanup provider backed by the user's locally-installed
/// `codex` CLI. Best-effort sibling to `ClaudeCLILLM`.
struct CodexCLILLM: LLMProvider {
    static let providerID: LLMProviderID = .codexCLI

    private let timeoutSeconds: TimeInterval

    init(timeoutSeconds: TimeInterval = 45) {
        self.timeoutSeconds = timeoutSeconds
    }

    func complete(request: LLMRequest) async throws -> LLMResponse {
        try await LocalCLICompletion.complete(
            tool: .codex,
            request: request,
            model: nil,
            timeoutSeconds: timeoutSeconds
        )
    }
}

/// Shared implementation for CLI-backed cleanup. Runs the CLI once,
/// non-interactively, on a background thread and maps failures to `LLMError`.
enum LocalCLICompletion {
    static func complete(
        tool: LocalCLITool,
        request: LLMRequest,
        model: String?,
        timeoutSeconds: TimeInterval
    ) async throws -> LLMResponse {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let response = try runCleanup(
                        tool: tool,
                        request: request,
                        model: model,
                        timeout: timeoutSeconds
                    )
                    continuation.resume(returning: response)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func runCleanup(
        tool: LocalCLITool,
        request: LLMRequest,
        model: String?,
        timeout: TimeInterval
    ) throws -> LLMResponse {
        let providerID = tool.llmProviderID
        let (arguments, stdin) = invocation(tool: tool, request: request, model: model)

        let result: LocalCLIResult
        do {
            result = try LocalCLIRuntime.run(
                tool: tool,
                arguments: arguments,
                stdin: stdin,
                timeout: timeout
            )
        } catch let error as LocalCLIError {
            // Map the CLI-layer error onto the pipeline's LLMError vocabulary.
            switch error {
            case .timedOut:
                throw LLMError.timeout(provider: providerID)
            case .notInstalled:
                throw LLMError.missingAPIKey(provider: providerID)
            default:
                throw LLMError.apiError(
                    provider: providerID,
                    message: error.localizedDescription,
                    statusCode: nil
                )
            }
        }

        guard result.exitCode == 0 else {
            throw LLMError.apiError(
                provider: providerID,
                message: LocalCLIError.failed(
                    tool: tool,
                    exitCode: result.exitCode,
                    stderr: result.stderr
                ).localizedDescription,
                statusCode: nil
            )
        }

        let text = sanitize(result.stdout)
        guard !text.isEmpty else {
            throw LLMError.emptyResponse(provider: providerID)
        }

        return LLMResponse(
            text: text,
            model: model.map { "\(tool.displayName) (\($0))" } ?? tool.displayName,
            promptTokens: nil,
            completionTokens: nil
        )
    }

    /// Builds the non-interactive invocation for each CLI. The user message is
    /// passed as a trailing positional prompt; no shell is involved, so the
    /// transcript is never interpreted.
    private static func invocation(
        tool: LocalCLITool,
        request: LLMRequest,
        model: String?
    ) -> (arguments: [String], stdin: String?) {
        switch tool {
        case .claude:
            // `claude --print --output-format text --model <m>
            //   --append-system-prompt <rules> "<transcript>"`
            var args = ["--print", "--output-format", "text"]
            if let model { args += ["--model", model] }
            args += ["--append-system-prompt", request.systemPrompt]
            args.append(request.userMessage)
            return (args, nil)

        case .codex:
            // `codex exec --skip-git-repo-check "<system>\n\n<transcript>"`.
            // Codex exec has no system-prompt flag, so fold the cleanup rules
            // into the prompt.
            let combined = "\(request.systemPrompt)\n\n---\n\n\(request.userMessage)"
            let args = ["exec", "--skip-git-repo-check", combined]
            return (args, nil)
        }
    }

    /// CLIs occasionally wrap output in a code fence or add a trailing newline.
    /// Strip an enclosing ``` fence if the whole payload is fenced, then trim.
    private static func sanitize(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```"), text.hasSuffix("```") {
            var lines = text.components(separatedBy: "\n")
            if lines.count >= 2 {
                lines.removeFirst() // opening ``` (possibly ```lang)
                lines.removeLast()  // closing ```
                text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return text
    }
}

private extension LocalCLITool {
    var llmProviderID: LLMProviderID {
        switch self {
        case .claude: .claudeCLI
        case .codex: .codexCLI
        }
    }
}
