import Foundation
import Testing
@preconcurrency import Vision
@testable import MoePeek

struct VisionRequestControllerTests {
    @Test func cancellationBeforeRecognitionPreventsStartingTheRequest() {
        let controller = VisionRequestController()
        let request = RecordingVisionRequest()

        controller.cancel()

        #expect(controller.install(request))
        #expect(request.cancellationCount == 1)
    }

    @Test func cancellationDuringRecognitionReachesVision() {
        let controller = VisionRequestController()
        let request = RecordingVisionRequest()
        #expect(!controller.install(request))

        controller.cancel()

        #expect(request.cancellationCount == 1)
        #expect(controller.finish())
    }

    @Test func completedCaptureCannotCancelTheNextUseOfItsRequest() {
        let request = RecordingVisionRequest()
        let completedCapture = VisionRequestController()
        #expect(!completedCapture.install(request))
        #expect(!completedCapture.finish())

        let nextCapture = VisionRequestController()
        #expect(!nextCapture.install(request))
        completedCapture.cancel()

        #expect(request.cancellationCount == 0)
        #expect(!nextCapture.finish())
    }
}

private final class RecordingVisionRequest: VNRequest, @unchecked Sendable {
    private let lock = NSLock()
    private var cancellations = 0

    var cancellationCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return cancellations
    }

    override func cancel() {
        lock.lock()
        cancellations += 1
        lock.unlock()
    }
}
