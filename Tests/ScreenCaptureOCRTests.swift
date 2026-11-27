import Dispatch
import Foundation
import Testing
@testable import MoePeek

struct ScreenCaptureOCRTests {
    private enum TestFailure: Error { case expected }

    @Test func accurateTextReturnsDirectly() async throws {
        let text = try await ScreenCaptureOCR.recognize(accurate: { "recognized accurately" })
        #expect(text == "recognized accurately")
    }

    @Test func accurateFailureIsPropagatedWithoutRetry() async throws {
        var attempts = 0
        do {
            _ = try await ScreenCaptureOCR.recognize {
                attempts += 1
                throw TestFailure.expected
            }
            Issue.record("Expected OCR failure")
        } catch TestFailure.expected {}
        #expect(attempts == 1)
    }

    @Test func emptyResultIsReportedWithoutRetry() async throws {
        var attempts = 0
        do {
            _ = try await ScreenCaptureOCR.recognize {
                attempts += 1
                return " \n "
            }
            Issue.record("Expected an empty OCR result to fail")
        } catch OCRError.noTextRecognized {}
        #expect(attempts == 1)
    }

    @Test func cancellationIsPropagated() async throws {
        do {
            _ = try await ScreenCaptureOCR.recognize { throw CancellationError() }
            Issue.record("Expected cancellation")
        } catch is CancellationError {}
    }

    @Test func cancelledTaskDoesNotStartRecognition() async throws {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await ScreenCaptureOCR.recognize {
                Issue.record("Cancelled work must not start recognition")
                return "unexpected"
            }
        }
        do {
            _ = try await task.value
            Issue.record("Expected cancellation")
        } catch is CancellationError {}
    }

    @Test func cancelledRecognitionDoesNotReturnALateResult() async throws {
        let task = Task {
            try await ScreenCaptureOCR.recognize {
                withUnsafeCurrentTask { $0?.cancel() }
                return "late text"
            }
        }
        do {
            _ = try await task.value
            Issue.record("Expected cancellation instead of late text")
        } catch is CancellationError {}
    }

    @Test(arguments: ["/usr/bin/true", "/usr/bin/false"])
    func captureProcessReturnsItsStatusAndDetachesItsHandler(_ executable: String) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)

        let status = try await ScreenCaptureOCR.runCaptureProcess(process)

        #expect(status == (executable.hasSuffix("/true") ? 0 : 1))
        #expect(!process.isRunning)
        #expect(process.terminationHandler == nil)
    }

    @Test func captureLaunchFailureIsPropagatedAndDetachesItsHandler() async {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/nonexistent-moepeek-capture")
        do {
            _ = try await ScreenCaptureOCR.runCaptureProcess(process)
            Issue.record("Expected process launch failure")
        } catch {
            #expect(!(error is CancellationError))
        }
        #expect(!process.isRunning)
        #expect(process.terminationHandler == nil)
    }

    @Test func cancelledCaptureDoesNotLaunchAProcess() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await ScreenCaptureOCR.runCaptureProcess(process)
        }
        do {
            _ = try await task.value
            Issue.record("Expected cancellation")
        } catch is CancellationError {}
        #expect(!process.isRunning)
        #expect(process.terminationHandler == nil)
    }

    @Test func cancellationDuringLaunchWaitsForTheChildToExit() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["10"]
        let launchStarted = AsyncStream<Void>.makeStream()
        let allowLaunch = DispatchSemaphore(value: 0)
        defer {
            allowLaunch.signal()
            if process.isRunning { process.terminate() }
        }
        let task = Task {
            try await ScreenCaptureOCR.runCaptureProcess(process) { child in
                launchStarted.continuation.yield(())
                launchStarted.continuation.finish()
                guard allowLaunch.wait(timeout: .now() + 3) == .success else {
                    throw CocoaError(.userCancelled)
                }
                try child.run()
            }
        }
        for await _ in launchStarted.stream { break }

        // The cancellation handler runs before Process has actually launched.
        task.cancel()
        allowLaunch.signal()

        do {
            _ = try await task.value
            Issue.record("Expected cancellation after child cleanup")
        } catch is CancellationError {}
        #expect(!process.isRunning)
        #expect(process.terminationHandler == nil)
    }

    @Test func cancellationTerminatesAnAlreadyRunningCapture() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["10"]
        defer { if process.isRunning { process.terminate() } }
        let task = Task { try await ScreenCaptureOCR.runCaptureProcess(process) }
        let deadline = ContinuousClock.now + .seconds(3)
        while !process.isRunning, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(process.isRunning)
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("Expected cancellation after child cleanup")
        } catch is CancellationError {}
        #expect(!process.isRunning)
        #expect(process.terminationHandler == nil)
    }
}
