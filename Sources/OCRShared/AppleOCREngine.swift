import Foundation
import CoreML
import os
@preconcurrency import Vision

/// Accurate OCR hosted in MoePeek's long-lived process so Vision can reuse its initialized models.
public enum AppleOCREngine: Sendable {
    fileprivate static let logger = Logger(subsystem: "com.nahida.MoePeek", category: "OCR")
    private static let recognitionSlot = RecognitionSlot()
    private static let recognizer = VisionTextRecognizer()

    public enum RecognitionError: LocalizedError, Sendable {
        case timeout
        case alreadyInProgress
        case failed(any Error)

        public var errorDescription: String? {
            switch self {
            case .timeout: String(localized: "Text recognition timed out")
            case .alreadyInProgress: String(localized: "Text recognition is still in progress")
            case .failed(let error):
                String(localized: "Vision recognition failed: \(error.localizedDescription)")
            }
        }
    }

    public static func recognizeText(
        in image: CGImage,
        timeout: TimeInterval = 20
    ) async throws -> String {
        guard recognitionSlot.claim() else {
            throw RecognitionError.alreadyInProgress
        }
        let lease = RecognitionLease(slot: recognitionSlot)

        let started = Date()
        logger.info("Starting Apple OCR (\(image.width)x\(image.height) px)")
        let observations: [RecognizedLine]
        do {
            observations = try await Task<Never, Never>.withTimeout(seconds: timeout) {
                guard lease.markStarted() else { throw CancellationError() }
                defer { lease.release() }
                return try await performVisionOCR(on: image)
            }
        } catch is TaskTimeoutError {
            lease.releaseIfNotStarted()
            logger.error("Apple OCR timed out after \(timeout, privacy: .public) seconds")
            throw RecognitionError.timeout
        } catch {
            lease.releaseIfNotStarted()
            logger.error("Apple OCR failed after \(Date().timeIntervalSince(started), privacy: .public) seconds: \(String(describing: error), privacy: .public)")
            throw error
        }
        let text = observations
            .map(\.text)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n")
        logger.info("Apple OCR finished in \(Date().timeIntervalSince(started), privacy: .public) seconds with \(observations.count, privacy: .public) observations")
        return text
    }

    private static func performVisionOCR(on cgImage: CGImage) async throws -> [RecognizedLine] {
        try await recognizer.recognize(cgImage)
    }
}

private struct RecognizedLine: Sendable {
    let text: String
}

/// The queue owns the request and the processing session that keeps its models alive.
private final class VisionTextRecognizer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.nahida.MoePeek.OCR", qos: .userInitiated)
    private var handler = VNSequenceRequestHandler()
    private var request: VNRecognizeTextRequest?

    func recognize(_ image: CGImage) async throws -> [RecognizedLine] {
        let requestController = VisionRequestController()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    let request = self.request ?? Self.makeRequest()
                    self.request = request
                    if requestController.install(request) {
                        self.request = nil
                        continuation.resume(throwing: CancellationError())
                        return
                    }

                    do {
                        try self.handler.perform([request], on: image)

                        // A completion callback can run before perform returns.
                        // Keep the recognition slot until Vision has fully unwound.
                        // Detach cancellation before this request can be reused.
                        guard !requestController.finish() else {
                            self.request = nil
                            continuation.resume(throwing: CancellationError())
                            return
                        }
                        let lines: [RecognizedLine] = (request.results ?? []).compactMap { observation in
                            guard let candidate = observation.topCandidates(1).first else { return nil }
                            return RecognizedLine(text: candidate.string)
                        }
                        continuation.resume(returning: lines)
                    } catch {
                        // Cancelled and failed requests must not become the next
                        // capture's warmed request.
                        self.request = nil
                        let wasCancelled = requestController.finish()
                        if !wasCancelled {
                            self.handler = VNSequenceRequestHandler()
                        }
                        continuation.resume(throwing: wasCancelled
                            ? CancellationError()
                            : AppleOCREngine.RecognitionError.failed(error))
                    }
                }
            }
        } onCancel: {
            requestController.cancel()
        }
    }

    private static func makeRequest() -> VNRecognizeTextRequest {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.revision = VNRecognizeTextRequest.currentRevision
        request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US", "ja-JP", "ko-KR"]
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        request.preferBackgroundProcessing = true
        if #available(macOS 27.0, *) {
            preferGPUWhenAvailable(for: request)
        }
        return request
    }

    /// Avoid the macOS 27 E5/ANE cache failure while keeping hardware-accelerated OCR.
    private static func preferGPUWhenAvailable(for request: VNRecognizeTextRequest) {
        guard let devicesByStage = try? request.supportedComputeStageDevices else { return }

        var selectedStages = 0
        for (stage, devices) in devicesByStage {
            guard let gpu = devices.first(where: { device in
                if case .gpu = device { return true }
                return false
            }) else { continue }
            request.setComputeDevice(gpu, for: stage)
            selectedStages += 1
        }

        if selectedStages > 0 {
            AppleOCREngine.logger.info(
                "Selected GPU compute for \(selectedStages, privacy: .public) Vision stage(s)"
            )
        }
    }
}

private final class RecognitionSlot: @unchecked Sendable {
    private let lock = NSLock()
    private var isClaimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isClaimed else { return false }
        isClaimed = true
        return true
    }

    func release() {
        lock.lock()
        isClaimed = false
        lock.unlock()
    }
}

private final class RecognitionLease: @unchecked Sendable {
    private let lock = NSLock()
    private let slot: RecognitionSlot
    private var started = false
    private var released = false

    init(slot: RecognitionSlot) {
        self.slot = slot
    }

    func markStarted() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !released else { return false }
        started = true
        return true
    }

    func releaseIfNotStarted() {
        lock.lock()
        guard !started, !released else {
            lock.unlock()
            return
        }
        released = true
        lock.unlock()
        slot.release()
    }

    func release() {
        lock.lock()
        guard !released else {
            lock.unlock()
            return
        }
        released = true
        lock.unlock()
        slot.release()
    }
}

/// Bridges Swift task cancellation to the callback-based Vision request.
final class VisionRequestController: @unchecked Sendable {
    private let lock = NSLock()
    private var request: VNRequest?
    private var isCancelled = false

    /// Returns whether the request was already cancelled before installation.
    func install(_ request: VNRequest) -> Bool {
        lock.lock()
        self.request = request
        let wasCancelled = isCancelled
        lock.unlock()

        if wasCancelled {
            request.cancel()
        }
        return wasCancelled
    }

    func cancel() {
        lock.lock()
        isCancelled = true
        request?.cancel()
        lock.unlock()
    }

    /// Stop a late cancellation from reaching the next use of the same request.
    func finish() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        request = nil
        return isCancelled
    }
}
