import AppKit
import Foundation
import SwiftUI
import Testing
@testable import MoePeek

@MainActor
@Suite struct TranslationActionOutcomeTests {
    @Test func overlappingSelectionWaitsAndLatestRequestPresents() async {
        let gate = ClipboardAccessGate()
        var started = 0
        var firstCapture: CheckedContinuation<Void, Never>?
        let coordinator = makeCoordinator(grabSelection: {
            started += 1
            let index = started
            guard await gate.acquire() else { return nil }
            defer { gate.release() }
            if index == 1 {
                await withCheckedContinuation { firstCapture = $0 }
            }
            return .plain("selection \(index)")
        })
        let first = Task { await coordinator.translateSelection() }
        while firstCapture == nil { await Task.yield() }
        let second = Task { await coordinator.translateSelection() }
        while started < 2 { await Task.yield() }
        firstCapture?.resume()
        #expect(!(await first.value).shouldPresent)
        #expect((await second.value).shouldPresent)
        #expect(coordinator.sourceText == "selection 2")
    }

    @Test func missingSelectionPreservesIdleWithoutShowingAnError() async {
        let coordinator = makeCoordinator(grabSelection: { nil })

        let outcome = await coordinator.translateSelection()

        #expect(outcome == .preserve)
        #expect(!outcome.shouldPresent)
        expectIdle(coordinator)
        #expect(coordinator.globalError == nil)
        #expect(coordinator.sourceText.isEmpty)
    }

    @Test func blankSelectionPreservesIdleWithoutShowingAnError() async {
        let coordinator = makeCoordinator(grabSelection: { .plain(" \n\t") })

        let outcome = await coordinator.translateSelection()

        #expect(outcome == .preserve)
        #expect(!outcome.shouldPresent)
        expectIdle(coordinator)
        #expect(coordinator.globalError == nil)
    }

    @Test func cancelledOCRPreservesIdleWithoutShowingAnError() async {
        let coordinator = makeCoordinator(captureOCR: { throw OCRError.captureCancelled })

        let outcome = await coordinator.ocrAndTranslate()

        #expect(outcome == .preserve)
        #expect(!outcome.shouldPresent)
        expectIdle(coordinator)
        #expect(coordinator.globalError == nil)
    }

    @Test func cancelledOCRPreservesExistingResultAndAttachments() async {
        let coordinator = makeCoordinator(captureOCR: { throw OCRError.captureCancelled })
        let attachment = SourceImageAttachment(id: "img-1", data: Data([1, 2, 3]))
        let document = RichSourceDocument(
            markdown: "existing source",
            attachments: [attachment.id: attachment]
        )

        coordinator.translate(document: document)
        for _ in 0 ..< 100 where !coordinator.hasAnyResult {
            await Task.yield()
        }

        #expect(coordinator.hasAnyResult)
        let sourceText = coordinator.sourceText
        let sourceAttachments = coordinator.sourceAttachments
        let providerStates = coordinator.providerStates

        let missingSelectionOutcome = await coordinator.translateSelection()

        #expect(missingSelectionOutcome == .preserve)
        #expect(!missingSelectionOutcome.shouldPresent)
        expectActive(coordinator)
        #expect(coordinator.sourceText == sourceText)
        #expect(coordinator.sourceAttachments == sourceAttachments)
        #expect(coordinator.providerStates == providerStates)
        #expect(coordinator.globalError == nil)

        let cancelledOCROutcome = await coordinator.ocrAndTranslate()

        #expect(cancelledOCROutcome == .preserve)
        #expect(!cancelledOCROutcome.shouldPresent)
        expectActive(coordinator)
        #expect(coordinator.sourceText == sourceText)
        #expect(coordinator.sourceAttachments == sourceAttachments)
        #expect(coordinator.providerStates == providerStates)
        #expect(coordinator.globalError == nil)
    }

    @Test func staleSelectionDoesNotRestoreOverNewInputSession() async {
        var finishGrab: CheckedContinuation<RichSourceDocument?, Never>?
        let coordinator = makeCoordinator(
            grabSelection: {
                await withCheckedContinuation { continuation in
                    finishGrab = continuation
                }
                return nil
            }
        )

        let staleTask = Task { @MainActor in
            await coordinator.translateSelection()
        }

        for _ in 0 ..< 100 where finishGrab == nil {
            await Task.yield()
        }
        guard let finishGrab else {
            Issue.record("Selection grab did not reach its continuation")
            staleTask.cancel()
            _ = await staleTask.value
            return
        }

        coordinator.prepareInputMode()
        coordinator.translate("new translation")
        for _ in 0 ..< 100 where !coordinator.hasAnyResult {
            await Task.yield()
        }
        #expect(coordinator.hasAnyResult)
        let newSourceText = coordinator.sourceText
        let newProviderStates = coordinator.providerStates

        finishGrab.resume(returning: nil)
        let outcome = await staleTask.value

        #expect(outcome == .preserve)
        expectActive(coordinator)
        #expect(coordinator.sourceText == newSourceText)
        #expect(coordinator.providerStates == newProviderStates)
    }

    @Test func staleOCRCancellationDoesNotRestoreOverNewInputSession() async throws {
        let capture = SuspendedOCRCapture()
        let coordinator = makeCoordinator(
            captureOCR: { try await capture.capture() }
        )

        let staleTask = Task { @MainActor in
            await coordinator.ocrAndTranslate()
        }

        var started = capture.started.makeAsyncIterator()
        let finishOCR = try #require(await started.next())

        coordinator.prepareInputMode()
        coordinator.translate("new translation")
        for _ in 0 ..< 100 where !coordinator.hasAnyResult {
            await Task.yield()
        }
        #expect(coordinator.hasAnyResult)
        let newSourceText = coordinator.sourceText
        let newProviderStates = coordinator.providerStates

        finishOCR.resume(throwing: OCRError.captureCancelled)
        let outcome = await staleTask.value

        #expect(outcome == .preserve)
        expectActive(coordinator)
        #expect(coordinator.sourceText == newSourceText)
        #expect(coordinator.providerStates == newProviderStates)
    }

    enum OCRAction: CaseIterable, Sendable {
        case translate
        case clipboard
    }

    @Test(arguments: OCRAction.allCases)
    func cancelledOCRDoesNotReportALateOrdinaryError(_ action: OCRAction) async throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("sentinel", forType: .string)
        let capture = SuspendedOCRCapture()
        let coordinator = makeCoordinator(
            captureOCR: { try await capture.capture() }, ocrPasteboard: pasteboard
        )
        coordinator.translate("existing source")
        let task = Task {
            switch action {
            case .translate: return await coordinator.ocrAndTranslate() == .preserve
            case .clipboard: return await coordinator.ocrToClipboard() == .cancelled
            }
        }
        var started = capture.started.makeAsyncIterator()
        let finish = try #require(await started.next())

        task.cancel()
        finish.resume(throwing: OCRError.captureReadFailed)

        #expect(await task.value)
        #expect(coordinator.globalError == nil)
        #expect(coordinator.sourceText == "existing source")
        #expect(pasteboard.string(forType: .string) == "sentinel")
    }

    @Test(arguments: OCRAction.allCases)
    func alreadyCancelledOCRDoesNotShowAPermissionError(_ action: OCRAction) async {
        let coordinator = makeCoordinator(screenRecordingGranted: false)
        let task = Task {
            switch action {
            case .translate: return await coordinator.ocrAndTranslate() == .preserve
            case .clipboard: return await coordinator.ocrToClipboard() == .cancelled
            }
        }
        task.cancel()

        #expect(await task.value)
        expectIdle(coordinator)
        #expect(coordinator.globalError == nil)
    }

    @Test func overlappingEmptyCapturesKeepIdleState() async {
        var continuations: [CheckedContinuation<RichSourceDocument?, Never>] = []
        let coordinator = makeCoordinator(grabSelection: {
            await withCheckedContinuation { continuations.append($0) }
        })
        let first = Task { await coordinator.translateSelection() }
        while continuations.count < 1 { await Task.yield() }
        let second = Task { await coordinator.translateSelection() }
        while continuations.count < 2 { await Task.yield() }

        expectIdle(coordinator)
        continuations[0].resume(returning: nil)
        continuations[1].resume(returning: nil)
        #expect(await first.value == .preserve)
        #expect(await second.value == .preserve)
        expectIdle(coordinator)
    }

    @Test func cancelledSmartCapturePreservesExistingInput() async {
        var finish: CheckedContinuation<SmartTranslationResult, Never>?
        let coordinator = makeCoordinator(resolveSmart: {
            await withCheckedContinuation { finish = $0 }
        })
        coordinator.prepareInputMode()
        let task = Task { await coordinator.translateSmart() }
        while finish == nil { await Task.yield() }

        expectActive(coordinator)
        task.cancel()
        finish?.resume(returning: .manualInput)
        #expect(await task.value == .cancelled)
        expectActive(coordinator)
    }

    @Test func staleSmartResultCannotReplaceNewInput() async {
        var finish: CheckedContinuation<SmartTranslationResult, Never>?
        let coordinator = makeCoordinator(resolveSmart: {
            await withCheckedContinuation { finish = $0 }
        })
        let task = Task { await coordinator.translateSmart() }
        while finish == nil { await Task.yield() }

        coordinator.prepareInputMode()
        finish?.resume(returning: .selection(.plain("obsolete selection")))
        #expect(await task.value == .cancelled)
        expectActive(coordinator)
        #expect(coordinator.sourceText.isEmpty)
        #expect(coordinator.providerStates.isEmpty)
    }

    @Test func permissionErrorsRemainPresentable() async {
        let selectionCoordinator = makeCoordinator(accessibilityGranted: false)
        let selectionOutcome = await selectionCoordinator.translateSelection()

        #expect(selectionOutcome.shouldPresent)
        expectActive(selectionCoordinator)
        #expect(selectionCoordinator.globalError != nil)

        let ocrCoordinator = makeCoordinator(screenRecordingGranted: false)
        let ocrOutcome = await ocrCoordinator.ocrAndTranslate()

        #expect(ocrOutcome.shouldPresent)
        expectActive(ocrCoordinator)
        #expect(ocrCoordinator.globalError != nil)
    }

    @Test func OCRReadAndRecognitionErrorsRemainPresentable() async {
        let readFailureCoordinator = makeCoordinator(captureOCR: { throw OCRError.captureReadFailed })
        let readFailureOutcome = await readFailureCoordinator.ocrAndTranslate()

        #expect(readFailureOutcome.shouldPresent)
        expectActive(readFailureCoordinator)
        #expect(readFailureCoordinator.globalError != nil)

        let recognitionFailureCoordinator = makeCoordinator(captureOCR: { throw OCRError.noTextRecognized })
        let recognitionFailureOutcome = await recognitionFailureCoordinator.ocrAndTranslate()

        #expect(recognitionFailureOutcome.shouldPresent)
        expectActive(recognitionFailureCoordinator)
        #expect(recognitionFailureCoordinator.globalError != nil)
    }

    @Test func silentOCRCopiesTextToClipboardWithoutPresenting() async {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("sentinel", forType: .string)
        let coordinator = makeCoordinator(captureOCR: { "  recognized text  " }, ocrPasteboard: pasteboard)

        let outcome = await coordinator.ocrToClipboard()

        #expect(outcome == .copied)
        expectIdle(coordinator)
        #expect(coordinator.globalError == nil)
        #expect(coordinator.sourceText.isEmpty)
        #expect(pasteboard.string(forType: .string) == "recognized text")
    }

    @Test func silentOCRCancellationPreservesIdleWithoutTouchingClipboard() async {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("sentinel", forType: .string)
        let coordinator = makeCoordinator(captureOCR: { throw OCRError.captureCancelled }, ocrPasteboard: pasteboard)

        let outcome = await coordinator.ocrToClipboard()

        #expect(outcome == .cancelled)
        expectIdle(coordinator)
        #expect(coordinator.globalError == nil)
        #expect(pasteboard.string(forType: .string) == "sentinel")
    }

    enum SilentOCRClipboardInterruption: CaseIterable, Sendable {
        case none
        case cancellation
        case newerAction
    }

    @Test(arguments: SilentOCRClipboardInterruption.allCases)
    func silentOCRWaitsForCancelledCaptureRestoration(_ interruption: SilentOCRClipboardInterruption) async {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("original clipboard", forType: .string)

        var finishRestoration: CheckedContinuation<Void, Never>?
        let captureTask = Task { @MainActor in
            await ClipboardGrabber.withStableAccess(to: pasteboard) { clipboard -> Bool? in
                await withCheckedContinuation { finishRestoration = $0 }
                // A simulated copy completes its restoration even after cancellation.
                clipboard.clearContents()
                return clipboard.setString("original clipboard", forType: .string)
            }
        }
        while finishRestoration == nil { await Task.yield() }
        captureTask.cancel()

        let captureFinished = AsyncStream<Void>.makeStream()
        let coordinator = makeCoordinator(captureOCR: {
            captureFinished.continuation.yield(())
            captureFinished.continuation.finish()
            return "recognized text"
        }, ocrPasteboard: pasteboard)
        let ocrTask = Task { await coordinator.ocrToClipboard() }
        for await _ in captureFinished.stream { break }

        switch interruption {
        case .none:
            break
        case .cancellation:
            ocrTask.cancel()
        case .newerAction:
            coordinator.prepareInputMode()
        }

        finishRestoration?.resume()
        #expect(await captureTask.value == true)
        let outcome = await ocrTask.value
        if interruption == .none {
            #expect(outcome == .copied)
            #expect(pasteboard.string(forType: .string) == "recognized text")
        } else {
            #expect(outcome == .cancelled)
            #expect(pasteboard.string(forType: .string) == "original clipboard")
        }
    }

    @Test func silentOCRErrorsUseTransientToast() async {
        let permissionCoordinator = makeCoordinator(screenRecordingGranted: false)
        let permissionOutcome = await permissionCoordinator.ocrToClipboard()

        guard case let .failed(permissionMessage) = permissionOutcome else {
            Issue.record("Expected a silent-OCR failure, got \(permissionOutcome)")
            return
        }
        #expect(!permissionMessage.isEmpty)
        expectIdle(permissionCoordinator)
        #expect(permissionCoordinator.globalError == nil)
        #expect(permissionCoordinator.sourceText.isEmpty)

        let failureCoordinator = makeCoordinator(captureOCR: { throw OCRError.noTextRecognized })
        let failureOutcome = await failureCoordinator.ocrToClipboard()

        guard case let .failed(failureMessage) = failureOutcome else {
            Issue.record("Expected a silent-OCR failure, got \(failureOutcome)")
            return
        }
        #expect(failureMessage == String(localized: "OCR failed: \(OCRError.noTextRecognized.localizedDescription)"))
        expectIdle(failureCoordinator)
        #expect(failureCoordinator.globalError == nil)
        #expect(failureCoordinator.sourceText.isEmpty)
    }

    private func makeCoordinator(
        accessibilityGranted: Bool = true,
        screenRecordingGranted: Bool = true,
        grabSelection: @escaping @MainActor () async -> RichSourceDocument? = { nil },
        captureOCR: @escaping @Sendable () async throws -> String = { throw OCRError.captureCancelled },
        resolveSmart: @escaping @MainActor () async -> SmartTranslationResult = { .cancelled },
        ocrPasteboard: NSPasteboard = .general
    ) -> TranslationCoordinator {
        let provider = TestTranslationProvider()
        let registry = TranslationProviderRegistry(
            providers: [provider],
            enabledProviderIDs: { [provider.id] },
            providerOrder: { [] },
            onDemandProviderIDs: { [] }
        )
        let permissions = TestPermissionManager(
            accessibilityGranted: accessibilityGranted,
            screenRecordingGranted: screenRecordingGranted
        )

        return TranslationCoordinator(
            permissionManager: permissions,
            registry: registry,
            grabSelection: grabSelection,
            captureOCR: captureOCR,
            resolveSmart: resolveSmart,
            ocrPasteboard: ocrPasteboard
        )
    }

    private func expectIdle(_ coordinator: TranslationCoordinator) {
        guard case .idle = coordinator.phase else {
            Issue.record("Expected an idle coordinator phase")
            return
        }
    }

    private func expectActive(_ coordinator: TranslationCoordinator) {
        guard case .active = coordinator.phase else {
            Issue.record("Expected an active coordinator phase")
            return
        }
    }

    @Test func ocrRunsOutsideMainActorSoVisionCannotBlockUI() async {
        let coordinator = makeCoordinator(captureOCR: {
            #expect(!isRunningOnMainThread())
            return "background recognized text"
        })

        let outcome = await coordinator.ocrAndTranslate()

        #expect(outcome == .present)
        #expect(coordinator.sourceText == "background recognized text")
    }
}

private func isRunningOnMainThread() -> Bool {
    Thread.isMainThread
}

private struct SuspendedOCRCapture: Sendable {
    let started: AsyncStream<CheckedContinuation<String, Error>>
    private let continuation: AsyncStream<CheckedContinuation<String, Error>>.Continuation

    init() {
        let stream = AsyncStream<CheckedContinuation<String, Error>>.makeStream()
        started = stream.stream
        continuation = stream.continuation
    }

    func capture() async throws -> String {
        try await withCheckedThrowingContinuation { capture in
            if case .terminated = continuation.yield(capture) {
                Issue.record("The test capture was unexpectedly invoked more than once")
                capture.resume(throwing: CancellationError())
            }
            continuation.finish()
        }
    }
}

@MainActor
private final class TestPermissionManager: PermissionChecking {
    let isAccessibilityGranted: Bool
    let isScreenRecordingGranted: Bool

    init(accessibilityGranted: Bool, screenRecordingGranted: Bool) {
        isAccessibilityGranted = accessibilityGranted
        isScreenRecordingGranted = screenRecordingGranted
    }
}

private struct TestTranslationProvider: TranslationProvider {
    let id = "openai"
    let displayName = "Test provider"
    let iconSystemName = "globe"
    let supportsStreaming = false
    let isAvailable = true

    @MainActor var isConfigured: Bool { true }

    func translateStream(
        _: String,
        from _: String?,
        to _: String
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield("translated")
            continuation.finish()
        }
    }

    @MainActor func makeSettingsView() -> AnyView {
        AnyView(EmptyView())
    }
}
