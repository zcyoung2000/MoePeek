import Foundation
import Testing
@testable import MoePeek

struct TaskTimeoutTests {
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
