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
}
