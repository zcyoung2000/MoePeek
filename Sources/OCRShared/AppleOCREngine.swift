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
        case cpuComputeUnavailable
        case cpuFallbackFailed(primary: any Error, fallback: any Error)
        case failed(any Error)

        public var errorDescription: String? {
            switch self {
            case .timeout: String(localized: "Text recognition timed out")
            case .alreadyInProgress: String(localized: "Text recognition is still in progress")
            case .cpuComputeUnavailable: String(localized: "CPU text recognition is unavailable")
            case .cpuFallbackFailed(let primary, let fallback):
                String(localized: "Vision recognition failed: \(primary.localizedDescription); CPU fallback failed: \(fallback.localizedDescription)")
            case .failed(let error):
                String(localized: "Vision recognition failed: \(error.localizedDescription)")
            }
        }
    }

    public static func recognizeText(
        in image: CGImage,
        timeout: TimeInterval = 20
    ) async throws -> String {
        try Task.checkCancellation()
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
            try Task.checkCancellation()
        } catch is TaskTimeoutError {
            lease.releaseIfNotStarted()
            logger.error("Apple OCR timed out after \(timeout, privacy: .public) seconds")
            throw RecognitionError.timeout
        } catch is CancellationError {
            lease.releaseIfNotStarted()
            logger.info("Apple OCR was cancelled")
            throw CancellationError()
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
final class VisionTextRecognizer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.nahida.MoePeek.OCR", qos: .userInitiated)
    private var handler = VNSequenceRequestHandler()
    private var request: VNRecognizeTextRequest?
    private var prefersCPUAfterFailure = false

    fileprivate func recognize(_ image: CGImage) async throws -> [RecognizedLine] {
        try Task.checkCancellation()
        let requestController = VisionRequestController()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    guard !requestController.cancellationRequested else {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    do {
                        let request = try self.request ?? self.makeNextRequest()
                        self.request = request
                        guard !requestController.install(request) else {
                            self.request = nil
                            continuation.resume(throwing: CancellationError())
                            return
                        }
                        let completedRequest = try self.perform(
                            request,
                            on: image,
                            controller: requestController
                        )

                        // Resume only after perform has returned so the recognition
                        // slot stays occupied until Vision has fully unwound.
                        // Detach cancellation before this request can be reused.
                        guard !requestController.finish() else {
                            self.request = nil
                            continuation.resume(throwing: CancellationError())
                            return
                        }
                        let lines: [RecognizedLine] = (completedRequest.results ?? []).compactMap { observation in
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
                        if wasCancelled || error is CancellationError {
                            continuation.resume(throwing: CancellationError())
                        } else if let recognitionError = error as? AppleOCREngine.RecognitionError {
                            continuation.resume(throwing: recognitionError)
                        } else {
                            continuation.resume(throwing: AppleOCREngine.RecognitionError.failed(error))
                        }
                    }
                }
            }
        } onCancel: {
            requestController.cancel()
        }
    }

    private func makeNextRequest() throws -> VNRecognizeTextRequest {
        if prefersCPUAfterFailure, #available(macOS 27.0, *) {
            AppleOCREngine.logger.info("Using CPU after an accelerated Vision OCR failure")
            return try Self.makeCPURequest()
        }
        let request = Self.makeBaseRequest()
        if #available(macOS 27.0, *) {
            Self.preferGPUWhenAvailable(for: request)
        }
        return request
    }

    private func perform(
        _ request: VNRecognizeTextRequest,
        on image: CGImage,
        controller: VisionRequestController
    ) throws -> VNRecognizeTextRequest {
        guard #available(macOS 27.0, *), !prefersCPUAfterFailure else {
            try handler.perform([request], on: image)
            return request
        }

        return try VisionCPUFallback.run(
            isCancelled: { controller.cancellationRequested },
            accelerated: {
                try self.handler.perform([request], on: image)
                return request
            },
            cpuFallback: {
                let cpuRequest = try Self.makeCPURequest()
                self.handler = VNSequenceRequestHandler()
                guard !controller.install(cpuRequest) else { throw CancellationError() }
                self.request = cpuRequest
                try self.handler.perform([cpuRequest], on: image)
                self.prefersCPUAfterFailure = true
                AppleOCREngine.logger.info("Apple OCR CPU fallback succeeded")
                return cpuRequest
            }
        )
    }

    private static func makeBaseRequest() -> VNRecognizeTextRequest {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.revision = VNRecognizeTextRequest.currentRevision
        request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US", "ja-JP", "ko-KR"]
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        request.preferBackgroundProcessing = true
        return request
    }

    @available(macOS 27.0, *)
    static func makeCPURequest() throws -> VNRecognizeTextRequest {
        let request = makeBaseRequest()
        let devicesByStage = try request.supportedComputeStageDevices
        guard !devicesByStage.isEmpty else {
            throw AppleOCREngine.RecognitionError.cpuComputeUnavailable
        }

        for (stage, devices) in devicesByStage {
            guard let cpu = devices.first(where: { device in
                if case .cpu = device { return true }
                return false
            }) else {
                throw AppleOCREngine.RecognitionError.cpuComputeUnavailable
            }
            request.setComputeDevice(cpu, for: stage)
        }

        AppleOCREngine.logger.info(
            "Selected CPU compute for all \(devicesByStage.count, privacy: .public) Vision stage(s)"
        )
        return request
    }

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

enum VisionCPUFallback {
    static func run<T>(
        isCancelled: () -> Bool,
        accelerated: () throws -> T,
        cpuFallback: () throws -> T
    ) throws -> T {
        do {
            return try accelerated()
        } catch {
            guard !(error is CancellationError), !isCancelled() else { throw CancellationError() }
            let primaryError = error
            AppleOCREngine.logger.error(
                "Accelerated Vision OCR failed; retrying on CPU: \(String(describing: primaryError), privacy: .public)"
            )
            do {
                return try cpuFallback()
            } catch {
                guard !(error is CancellationError), !isCancelled() else { throw CancellationError() }
                throw AppleOCREngine.RecognitionError.cpuFallbackFailed(
                    primary: primaryError,
                    fallback: error
                )
            }
        }
    }
}

final class RecognitionSlot: @unchecked Sendable {
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

final class RecognitionLease: @unchecked Sendable {
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

/// Bridges Swift task cancellation to synchronous Vision execution.
final class VisionRequestController: @unchecked Sendable {
    private let lock = NSLock()
    private var request: VNRequest?
    private var isCancelled = false

    var cancellationRequested: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isCancelled
    }

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
        let request = self.request
        lock.unlock()
        // finish() observes isCancelled before the caller can reuse this request.
        // Do not call into Vision while holding our own lock.
        request?.cancel()
    }

    /// Stop a late cancellation from reaching the next use of the same request.
    func finish() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        request = nil
        return isCancelled
    }
}
