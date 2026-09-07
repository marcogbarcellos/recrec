import Foundation

struct TestFailure: Error, CustomStringConvertible {
    let message: String
    let file: String
    let line: UInt
    var description: String { "\(file):\(line): \(message)" }
}

func expect(_ condition: @autoclosure () -> Bool, _ message: String = "expected condition to be true",
            file: StaticString = #filePath, line: UInt = #line) throws {
    if !condition() { throw TestFailure(message: message, file: "\(file)", line: line) }
}

func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String = "",
                               file: StaticString = #filePath, line: UInt = #line) throws {
    if actual != expected {
        throw TestFailure(message: "expected \(expected), got \(actual). \(message)", file: "\(file)", line: line)
    }
}

func expectNear(_ actual: Double, _ expected: Double, tolerance: Double, _ message: String = "",
                file: StaticString = #filePath, line: UInt = #line) throws {
    if abs(actual - expected) > tolerance {
        throw TestFailure(message: "expected \(expected) ± \(tolerance), got \(actual). \(message)", file: "\(file)", line: line)
    }
}

func expectThrows(_ body: () async throws -> Void, _ message: String = "expected an error",
                  file: StaticString = #filePath, line: UInt = #line) async throws {
    do { try await body() } catch { return }
    throw TestFailure(message: message, file: "\(file)", line: line)
}

final class TestRunner {
    private var tests: [(name: String, body: () async throws -> Void)] = []

    func test(_ name: String, _ body: @escaping () async throws -> Void) {
        tests.append((name, body))
    }

    /// Runs every test (optionally filtered by the TEST_FILTER environment variable); returns the failure count.
    func run() async -> Int {
        var failures = 0
        var ran = 0
        let filter = ProcessInfo.processInfo.environment["TEST_FILTER"]
        for t in tests where filter == nil || t.name.contains(filter!) {
            ran += 1
            let start = Date()
            do {
                try await t.body()
                print("PASS  \(t.name) (\(String(format: "%.2f", Date().timeIntervalSince(start)))s)")
            } catch {
                failures += 1
                print("FAIL  \(t.name)\n      \(error)")
            }
        }
        print("\n\(ran - failures) passed, \(failures) failed")
        return failures
    }
}
