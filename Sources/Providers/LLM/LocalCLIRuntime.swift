import Foundation
import os

private let logger = Logger(subsystem: "team.yourorbit.OrbitDictation", category: "LocalCLI")

/// A locally-installed AI CLI that Comet can drive as a subprocess, using the
/// user's existing CLI login instead of an API key.
enum LocalCLITool: String, CaseIterable {
    case claude
    case codex

    var binaryName: String {
        switch self {
        case .claude: "claude"
        case .codex: "codex"
        }
    }

    var displayName: String {
        switch self {
        case .claude: "Claude Code CLI"
        case .codex: "Codex CLI"
        }
    }

    /// The one-liner a user runs in Terminal to sign in.
    var loginHint: String {
        switch self {
        case .claude: "Run `claude` once in Terminal and sign in."
        case .codex: "Run `codex` once in Terminal and sign in."
        }
    }
}

/// Result of a one-shot CLI invocation.
struct LocalCLIResult {
    let exitCode: Int32
    let stdout: String
    let stderr: String
}

/// Whether a local CLI can be used right now.
enum LocalCLIAvailability: Equatable {
    /// Binary found on PATH at `path`. We deliberately do not hard-gate on a
    /// login probe — a stale or unrecognised `--version`/auth output should
    /// not block a working install. Login failures surface at run time with a
    /// clear, actionable message instead.
    case available(path: String)
    case notInstalled

    var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }
}

enum LocalCLIError: LocalizedError {
    case notInstalled(tool: LocalCLITool)
    case timedOut(tool: LocalCLITool)
    case failed(tool: LocalCLITool, exitCode: Int32, stderr: String)
    case launchFailed(tool: LocalCLITool, underlying: String)

    var errorDescription: String? {
        switch self {
        case let .notInstalled(tool):
            "\(tool.displayName) isn't installed or isn't on your PATH. \(tool.loginHint)"
        case let .timedOut(tool):
            "\(tool.displayName) took too long to respond."
        case let .failed(tool, code, stderr):
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            let hint = Self.looksLikeAuthFailure(detail) ? " \(tool.loginHint)" : ""
            return "\(tool.displayName) exited with code \(code).\(hint)\(detail.isEmpty ? "" : " (\(detail.prefix(200)))")"
        case let .launchFailed(tool, underlying):
            "Couldn't launch \(tool.displayName): \(underlying)"
        }
    }

    static func looksLikeAuthFailure(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("not logged in")
            || lower.contains("login required")
            || lower.contains("unauthorized")
            || lower.contains("authenticate")
    }
}

/// Shared machinery for running the user's locally-installed AI CLI as a
/// subprocess. Ported from Orion's `ClaudeSession` backend: resolve the login
/// shell environment once (to inherit the real PATH), locate the binary, and
/// run a single non-interactive turn.
enum LocalCLIRuntime {
    // MARK: - Shell environment (cached)

    private static let lock = NSLock()
    private static var cachedEnvironment: [String: String]?

    /// Resolves the user's login+interactive shell environment so we inherit
    /// their real PATH (Homebrew, nvm, asdf, volta…). A GUI app launched from
    /// Finder gets a minimal PATH that usually lacks these CLIs, so we ask a
    /// `zsh -l -i` for its `env` once and cache the result for the session.
    static func shellEnvironment() -> [String: String] {
        lock.lock()
        if let cached = cachedEnvironment {
            lock.unlock()
            return cached
        }
        lock.unlock()

        var environment = ProcessInfo.processInfo.environment

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        proc.arguments = ["-l", "-i", "-c", "echo '---ENV_START---' && env && echo '---ENV_END---'"]
        let stdout = Pipe()
        proc.standardOutput = stdout
        proc.standardError = Pipe()

        do {
            try proc.run()
            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            let output = String(data: data, encoding: .utf8) ?? ""
            if let start = output.range(of: "---ENV_START---\n"),
               let end = output.range(of: "\n---ENV_END---") {
                let envString = String(output[start.upperBound ..< end.lowerBound])
                for line in envString.components(separatedBy: "\n") {
                    guard let eq = line.range(of: "=") else { continue }
                    let key = String(line[..<eq.lowerBound])
                    let value = String(line[eq.upperBound...])
                    environment[key] = value
                }
            }
        } catch {
            logger.error("Failed to resolve login shell environment: \(error.localizedDescription)")
        }

        lock.lock()
        cachedEnvironment = environment
        lock.unlock()
        return environment
    }

    /// Clears the cached environment — call after the user says they've just
    /// installed or signed into a CLI so detection re-scans.
    static func invalidateEnvironmentCache() {
        lock.lock()
        cachedEnvironment = nil
        lock.unlock()
    }

    // MARK: - Binary resolution

    static func executablePath(for tool: LocalCLITool, environment: [String: String]) -> String? {
        let rawPath = environment["PATH"] ?? ProcessInfo.processInfo.environment["PATH"] ?? ""
        for directory in rawPath.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(directory))
                .appendingPathComponent(tool.binaryName).path
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    /// Fast availability check. After the first call (which may spawn a login
    /// shell to resolve PATH) this is a pure filesystem scan.
    static func availability(for tool: LocalCLITool) -> LocalCLIAvailability {
        let env = shellEnvironment()
        if let path = executablePath(for: tool, environment: env) {
            return .available(path: path)
        }
        return .notInstalled
    }

    // MARK: - One-shot run

    /// Runs `tool` with `arguments`, optionally feeding `stdin`, in a neutral
    /// working directory (so it doesn't inherit a project's config), and
    /// returns once it exits or `timeout` elapses (SIGTERM on timeout).
    static func run(
        tool: LocalCLITool,
        arguments: [String],
        stdin: String?,
        timeout: TimeInterval
    ) throws -> LocalCLIResult {
        let environment = shellEnvironment()
        guard let executable = executablePath(for: tool, environment: environment) else {
            throw LocalCLIError.notInstalled(tool: tool)
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = arguments
        proc.environment = environment
        // Neutral cwd so the CLI doesn't pick up a nearby project's CLAUDE.md /
        // AGENTS.md and start behaving like a coding agent on our transcript.
        proc.currentDirectoryURL = URL(fileURLWithPath: NSTemporaryDirectory())

        let outPipe = Pipe()
        let errPipe = Pipe()
        let inPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        proc.standardInput = inPipe

        // Drain both pipes concurrently to avoid a full-buffer deadlock.
        var outData = Data()
        var errData = Data()
        let ioQueue = DispatchQueue(label: "team.yourorbit.OrbitDictation.localcli.io", attributes: .concurrent)
        let readGroup = DispatchGroup()
        readGroup.enter()
        ioQueue.async {
            outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            readGroup.leave()
        }
        readGroup.enter()
        ioQueue.async {
            errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            readGroup.leave()
        }

        do {
            try proc.run()
        } catch {
            throw LocalCLIError.launchFailed(tool: tool, underlying: error.localizedDescription)
        }

        if let stdin, let data = stdin.data(using: .utf8) {
            inPipe.fileHandleForWriting.write(data)
        }
        try? inPipe.fileHandleForWriting.close()

        let exitSemaphore = DispatchSemaphore(value: 0)
        ioQueue.async {
            proc.waitUntilExit()
            exitSemaphore.signal()
        }

        if exitSemaphore.wait(timeout: .now() + timeout) == .timedOut {
            proc.terminate()
            _ = exitSemaphore.wait(timeout: .now() + 2)
            readGroup.wait()
            throw LocalCLIError.timedOut(tool: tool)
        }

        readGroup.wait()
        return LocalCLIResult(
            exitCode: proc.terminationStatus,
            stdout: String(data: outData, encoding: .utf8) ?? "",
            stderr: String(data: errData, encoding: .utf8) ?? ""
        )
    }
}
