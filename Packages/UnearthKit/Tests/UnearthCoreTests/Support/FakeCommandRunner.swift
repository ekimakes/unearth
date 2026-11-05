import Foundation
import Synchronization
import Testing
@testable import UnearthCore

/// Answers commands from a table and records every call. Never runs anything.
final class FakeCommandRunner: CommandRunning, Sendable {
    struct Call: Equatable {
        let executable: String
        let arguments: [String]
        let environment: [String: String]
    }

    private let responses: [String: CommandResult]
    private let recorded = Mutex<[Call]>([])

    /// Keys are the executable followed by its arguments, separated by single spaces.
    init(_ responses: [String: CommandResult] = [:]) {
        self.responses = responses
    }

    var calls: [Call] { recorded.withLock { $0 } }

    func run(_ executable: String, _ arguments: [String], environment: [String: String]) async throws -> CommandResult {
        recorded.withLock { $0.append(Call(executable: executable, arguments: arguments, environment: environment)) }
        let key = ([executable] + arguments).joined(separator: " ")
        return responses[key] ?? CommandResult(exitCode: 127, stdout: Data(), stderr: Data("unexpected: \(key)".utf8))
    }
}

extension CommandResult {
    static func success(_ stdout: Data) -> CommandResult { CommandResult(exitCode: 0, stdout: stdout, stderr: Data()) }
    static func success(_ stdout: String) -> CommandResult { success(Data(stdout.utf8)) }
}

enum Fixtures {
    static func data(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }
}
