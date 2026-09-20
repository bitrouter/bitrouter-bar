import Darwin
import Foundation

enum BroClientError: LocalizedError, Equatable {
    case executableNotFound
    case timedOut
    case outputTooLarge
    case commandFailed(code: String, message: String)
    case invalidResponse
    case incompatibleSchema

    var errorDescription: String? {
        switch self {
        case .executableNotFound:
            "BitRouter CLI was not found. Install or upgrade BitRouter."
        case .timedOut:
            "BitRouter did not respond in time."
        case .outputTooLarge:
            "BitRouter returned more data than the app can safely read."
        case let .commandFailed(_, message):
            message
        case .invalidResponse:
            "BitRouter returned an unreadable panel response."
        case .incompatibleSchema:
            "This BitRouter panel format is not supported. Upgrade BitRouter Bar."
        }
    }
}

struct BroExecutableLocator: Sendable {
    let environment: [String: String]

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.environment = environment
    }

    func locate() -> URL? {
        if let override = environment["BITROUTER_BAR_BRO_PATH"], isExecutable(override) {
            return URL(fileURLWithPath: override)
        }

        let home = environment["HOME"]
        let common = [
            "/opt/homebrew/bin/bro",
            "/usr/local/bin/bro",
            home.map { "\($0)/.local/bin/bro" },
            home.map { "\($0)/.cargo/bin/bro" },
        ].compactMap { $0 }

        let pathCandidates = (environment["PATH"] ?? "")
            .split(separator: ":")
            .map { "\($0)/bro" }

        return (common + pathCandidates).first(where: isExecutable).map(URL.init(fileURLWithPath:))
    }

    private func isExecutable(_ path: String) -> Bool {
        FileManager.default.isExecutableFile(atPath: path)
    }
}

struct BroPanelClient: Sendable {
    var locator = BroExecutableLocator()
    var timeout: Duration = .seconds(8)
    var maximumOutputBytes = 1_048_576

    func fetch(since: Date, until: Date, sessionLimit: Int, sessionOffset: Int = 0) async throws -> PanelSnapshot {
        guard let executable = locator.locate() else { throw BroClientError.executableNotFound }
        let formatter = ISO8601DateFormatter()
        let arguments = [
            "panel",
            "--since", formatter.string(from: since),
            "--until", formatter.string(from: until),
            "--session-limit", String(sessionLimit),
            "--session-offset", String(sessionOffset),
        ]

        let result = try await ProcessExecutor.run(
            executable: executable,
            arguments: arguments,
            timeout: timeout,
            maximumBytes: maximumOutputBytes
        )

        if result.status != 0 {
            if let envelope = try? PanelDecoding.decoder.decode(CommandErrorEnvelope.self, from: result.stdout) {
                let message = friendlyMessage(for: envelope.error)
                throw BroClientError.commandFailed(code: envelope.error.kind, message: message)
            }
            let stderr = String(data: result.stderr, encoding: .utf8) ?? ""
            let unsupported = stderr.localizedCaseInsensitiveContains("unrecognized subcommand")
            throw BroClientError.commandFailed(
                code: unsupported ? "unsupported_daemon" : "command_failed",
                message: unsupported ? "This BitRouter version does not support the menu bar app. Upgrade BitRouter and try again." : "BitRouter could not load panel data."
            )
        }

        do {
            let snapshot = try PanelDecoding.decoder.decode(PanelSnapshot.self, from: result.stdout)
            guard snapshot.schemaVersion == 1 else { throw BroClientError.incompatibleSchema }
            try validate(snapshot)
            return snapshot
        } catch let error as BroClientError {
            throw error
        } catch {
            throw BroClientError.invalidResponse
        }
    }

    private func friendlyMessage(for payload: CommandErrorPayload) -> String {
        if payload.message.hasPrefix("panel_daemon_unavailable") {
            return "BitRouter is not running. Start it, then refresh."
        }
        if payload.message.hasPrefix("panel_unsupported_daemon") {
            return "This BitRouter version does not support the menu bar app. Upgrade BitRouter and try again."
        }
        if payload.message.hasPrefix("panel_timeout") {
            return "BitRouter did not respond in time."
        }
        return "BitRouter could not load panel data."
    }

    private func validate(_ snapshot: PanelSnapshot) throws {
        guard Set(snapshot.clients.map(\.id)).count == snapshot.clients.count else {
            throw BroClientError.invalidResponse
        }
        for client in snapshot.clients {
            guard Set(client.sessions.map(\.id)).count == client.sessions.count else {
                throw BroClientError.invalidResponse
            }
        }
    }
}

protocol PanelClientFetching: Sendable {
    func fetch(since: Date, until: Date, sessionLimit: Int, sessionOffset: Int) async throws -> PanelSnapshot
}

extension BroPanelClient: PanelClientFetching {}

private struct ProcessResult: Sendable {
    let status: Int32
    let stdout: Data
    let stderr: Data
}

private enum ProcessExecutor {
    static func run(executable: URL, arguments: [String], timeout: Duration, maximumBytes: Int) async throws -> ProcessResult {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = FileHandle.nullDevice

        let termination = terminationStream(of: process)
        do {
            try process.run()
        } catch {
            throw BroClientError.commandFailed(code: "launch_failed", message: error.localizedDescription)
        }

        return try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: ProcessResult.self) { group in
                group.addTask {
                    async let stdout = read(stdoutPipe.fileHandleForReading, maximumBytes: maximumBytes)
                    async let stderr = read(stderrPipe.fileHandleForReading, maximumBytes: maximumBytes)
                    guard let status = await termination.first(where: { _ in true }) else {
                        throw BroClientError.invalidResponse
                    }
                    return try await ProcessResult(status: status, stdout: stdout, stderr: stderr)
                }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    throw BroClientError.timedOut
                }

                do {
                    guard let first = try await group.next() else {
                        throw BroClientError.invalidResponse
                    }
                    group.cancelAll()
                    if process.isRunning { process.terminate() }
                    return first
                } catch {
                    group.cancelAll()
                    await stop(process)
                    throw error
                }
            }
        } onCancel: {
            if process.isRunning {
                process.terminate()
                Darwin.kill(process.processIdentifier, SIGKILL)
            }
        }
    }

    private static func read(_ handle: FileHandle, maximumBytes: Int) async throws -> Data {
        var data = Data()
        for try await byte in handle.bytes {
            if data.count >= maximumBytes { throw BroClientError.outputTooLarge }
            data.append(byte)
        }
        return data
    }

    private static func terminationStream(of process: Process) -> AsyncStream<Int32> {
        AsyncStream { continuation in
            process.terminationHandler = { terminated in
                continuation.yield(terminated.terminationStatus)
                continuation.finish()
            }
        }
    }

    private static func stop(_ process: Process) async {
        guard process.isRunning else { return }
        process.terminate()
        try? await Task.sleep(for: .milliseconds(250))
        if process.isRunning {
            Darwin.kill(process.processIdentifier, SIGKILL)
        }
    }
}
