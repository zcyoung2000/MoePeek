import Foundation
import Testing
@testable import MoePeek

struct ScreenCaptureOCRTests {
    @Test func accurateTextReturnsWithoutRecovery() async throws {
        let text = try await ScreenCaptureOCR.recognize(
            accurate: { "recognized accurately" },
            recovery: { throw OCRError.workerUnavailable }
        )
        #expect(text == "recognized accurately")
    }

    @Test func accurateFailureUsesRecovery() async throws {
        let text = try await ScreenCaptureOCR.recognize(
            accurate: { throw OCRError.timeout },
            recovery: { "recovered" }
        )
        #expect(text == "recovered")
    }

    @Test func emptyAccurateResultUsesRecovery() async throws {
        let text = try await ScreenCaptureOCR.recognize(
            accurate: { " \n " },
            recovery: { "recovered" }
        )
        #expect(text == "recovered")
    }

    @Test func recoveryMustReturnNonemptyText() async throws {
        do {
            _ = try await ScreenCaptureOCR.recognize(
                accurate: { "" },
                recovery: { " \n " }
            )
            Issue.record("Expected an empty recovery result to fail")
        } catch OCRError.noTextRecognized {}
    }

    @Test(arguments: [false, true])
    func cancellationDoesNotStartRecovery(captureCancellation: Bool) async throws {
        do {
            _ = try await ScreenCaptureOCR.recognize(
                accurate: {
                    if captureCancellation { throw OCRError.captureCancelled }
                    throw CancellationError()
                },
                recovery: { throw OCRError.workerUnavailable }
            )
            Issue.record("Expected cancellation")
        } catch is CancellationError {
            #expect(!captureCancellation)
        } catch OCRError.captureCancelled {
            #expect(captureCancellation)
        }
    }
}
