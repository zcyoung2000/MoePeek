import Foundation
import Testing
@testable import MoePeek

struct TaskTimeoutTests {
    private enum TestFailure: Error { case expected }

    @Test func successfulOperationReturnsItsValue() async throws {
        let value = try await Task<Never, Never>.withTimeout(seconds: 1) { "recognized" }
        #expect(value == "recognized")
    }

    @Test func operationErrorIsNotReplacedWithATimeout() async throws {
        do {
            _ = try await Task<Never, Never>.withTimeout(seconds: 1) { () -> String in
                throw TestFailure.expected
            }
            Issue.record("Expected the operation's error")
        } catch TestFailure.expected {}
    }

    @Test(arguments: [0.0, -1, .nan, .infinity, -.infinity])
    func invalidTimeoutNeverStartsTheOperation(_ seconds: TimeInterval) async throws {
        do {
            _ = try await Task<Never, Never>.withTimeout(seconds: seconds) {
                Issue.record("An invalid timeout must not start work")
                return "unexpected"
            }
            Issue.record("Expected an invalid timeout to fail")
        } catch is TaskTimeoutError {}
    }

    @Test func veryLargeFiniteTimeoutDoesNotOverflow() async throws {
        let value = try await Task<Never, Never>.withTimeout(seconds: .greatestFiniteMagnitude) {
            try await Task.sleep(for: .milliseconds(20))
            return "recognized"
        }
        #expect(value == "recognized")
    }

    @Test func cancelledCallerDoesNotStartTheOperation() async throws {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await Task<Never, Never>.withTimeout(seconds: 1) {
                Issue.record("An already cancelled caller must not start work")
                return "unexpected"
            }
        }
        do {
            _ = try await task.value
            Issue.record("Expected cancellation")
        } catch is CancellationError {}
    }

    @Test func parentCancellationReachesTheOperation() async throws {
        let started = AsyncStream<Void>.makeStream()
        let cancellation = CancellationFlag()
        let task = Task {
            try await Task<Never, Never>.withTimeout(seconds: 10) {
                started.continuation.yield(())
                started.continuation.finish()
                do {
                    try await Task.sleep(for: .seconds(10))
                } catch is CancellationError {
                    await cancellation.mark()
                    throw CancellationError()
                }
                return "unexpected"
            }
        }
        for await _ in started.stream { break }
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("Expected cancellation")
        } catch is CancellationError {}
        try await waitForCancellation(cancellation)
    }

    @Test func timeoutReturnsBeforeUncooperativeWorkAndIgnoresItsLateResult() async throws {
        let started = AsyncStream<CheckedContinuation<String, Never>>.makeStream()
        let finished = AsyncStream<Void>.makeStream()
        let task = Task {
            try await Task<Never, Never>.withTimeout(seconds: 0.1) {
                let result = await withCheckedContinuation {
                    started.continuation.yield($0)
                    started.continuation.finish()
                }
                finished.continuation.yield(())
                finished.continuation.finish()
                return result
            }
        }
        var captures = started.stream.makeAsyncIterator()
        let continuation = try #require(await captures.next())
        do {
            _ = try await task.value
            Issue.record("Expected the timeout without waiting for the operation")
        } catch is TaskTimeoutError {}

        continuation.resume(returning: "late result")
        for await _ in finished.stream { break }
    }

    @Test func timeoutCancelsTheOperationTask() async throws {
        let cancellation = CancellationFlag()

        do {
            _ = try await Task<Never, Never>.withTimeout(seconds: 0.01) {
                do {
                    try await Task.sleep(for: .seconds(10))
                } catch is CancellationError {
                    await cancellation.mark()
                    throw CancellationError()
                }
                return "unexpected"
            }
            Issue.record("Expected the timeout to win the race")
        } catch is TaskTimeoutError {
            // Expected.
        }

        try await waitForCancellation(cancellation)
    }

    private func waitForCancellation(_ cancellation: CancellationFlag) async throws {
        let deadline = ContinuousClock.now + .seconds(1)
        while !(await cancellation.value) && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await cancellation.value)
    }
}

private actor CancellationFlag {
    private(set) var value = false

    func mark() {
        value = true
    }
}
