import Foundation

struct TaskTimeoutError: Error {}

extension Task where Success == Never, Failure == Never {
    static func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        guard seconds.isFinite, seconds > 0 else { throw TaskTimeoutError() }

        let race = TimeoutRace<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                race.start(continuation: continuation, seconds: seconds, operation: operation)
            }
        } onCancel: {
            race.cancel()
        }
    }
}

private final class TimeoutRace<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var operationTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var cancelledBeforeStart = false

    func start(
        continuation: CheckedContinuation<Value, Error>,
        seconds: TimeInterval,
        operation: @escaping @Sendable () async throws -> Value
    ) {
        lock.lock()
        guard !cancelledBeforeStart else {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return
        }
        self.continuation = continuation

        operationTask = Task {
            do {
                self.finish(.success(try await operation()))
            } catch {
                self.finish(.failure(error))
            }
        }
        timeoutTask = Task {
            do {
                // Bound before multiplying: a finite TimeInterval can still
                // overflow an integer conversion. Preserve submillisecond input.
                let nanoseconds: UInt64 = seconds >= TimeInterval(UInt64.max / 1_000_000_000)
                    ? .max
                    : UInt64(max(1, seconds * 1_000_000_000))
                try await Task.sleep(for: .nanoseconds(nanoseconds))
                self.finish(.failure(TaskTimeoutError()))
            } catch {
                // The operation completed or the caller cancelled first.
            }
        }
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        guard let continuation else {
            cancelledBeforeStart = true
            lock.unlock()
            return
        }
        self.continuation = nil
        let operationTask = self.operationTask
        let timeoutTask = self.timeoutTask
        self.operationTask = nil
        self.timeoutTask = nil
        lock.unlock()

        operationTask?.cancel()
        timeoutTask?.cancel()
        continuation.resume(throwing: CancellationError())
    }

    private func finish(_ result: Result<Value, Error>) {
        lock.lock()
        guard let continuation else {
            lock.unlock()
            return
        }
        self.continuation = nil
        let operationTask = self.operationTask
        let timeoutTask = self.timeoutTask
        self.operationTask = nil
        self.timeoutTask = nil
        lock.unlock()

        switch result {
        case .success:
            timeoutTask?.cancel()
        case .failure:
            operationTask?.cancel()
            timeoutTask?.cancel()
        }
        continuation.resume(with: result)
    }
}
