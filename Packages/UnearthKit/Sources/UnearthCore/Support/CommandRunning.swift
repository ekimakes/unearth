import Foundation
import Synchronization

public struct CommandResult: Sendable {
    public let exitCode: Int32
    public let stdout: Data
    public let stderr: Data

    public init(exitCode: Int32, stdout: Data, stderr: Data) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

/// Runs another program. Production code uses `ProcessCommandRunner`; tests use a fake.
public protocol CommandRunning: Sendable {
    /// `environment` is added on top of the inherited environment.
    func run(_ executable: String, _ arguments: [String], environment: [String: String]) async throws -> CommandResult
}

public struct ProcessCommandRunner: CommandRunning {
    public var timeout: Duration

    public init(timeout: Duration = .seconds(60)) {
        self.timeout = timeout
    }

    public func run(_ executable: String, _ arguments: [String], environment: [String: String]) async throws -> CommandResult {
        let timeoutSeconds = Double(timeout.components.seconds)
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                if !environment.isEmpty {
                    process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
                }
                let output = Pipe()
                let errors = Pipe()
                process.standardOutput = output
                process.standardError = errors
                process.standardInput = FileHandle.nullDevice
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }

                let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds, execute: watchdog)

                // Drain both pipes at once so a chatty process can't fill one and stall.
                let errorData = Mutex(Data())
                let drained = DispatchGroup()
                drained.enter()
                DispatchQueue.global().async {
                    let data = errors.fileHandleForReading.readDataToEndOfFile()
                    errorData.withLock { $0 = data }
                    drained.leave()
                }
                let outputData = output.fileHandleForReading.readDataToEndOfFile()
                drained.wait()
                process.waitUntilExit()
                watchdog.cancel()

                continuation.resume(returning: CommandResult(
                    exitCode: process.terminationStatus, stdout: outputData, stderr: errorData.withLock { $0 }))
            }
        }
    }
}
