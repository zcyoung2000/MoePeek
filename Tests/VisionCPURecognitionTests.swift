import AppKit
import CoreML
import CoreText
import Foundation
import Testing
@preconcurrency import Vision
@testable import MoePeek

@Suite(.timeLimit(.minutes(3)))
struct VisionCPURecognitionTests {
    @Test func cpuRequestPinsEverySupportedStage() throws {
        guard #available(macOS 27.0, *) else { return }

        let request = try VisionTextRecognizer.makeCPURequest()
        let supportedStages = try request.supportedComputeStageDevices
        #expect(!supportedStages.isEmpty)

        for stage in supportedStages.keys {
            let selectedDevice = request.computeDevice(for: stage)
            if case .cpu? = selectedDevice {
                continue
            }
            Issue.record("Vision stage \(stage) was not pinned to CPU")
        }
    }

    @Test func cpuPinnedVisionRecognizesScreenCapture() throws {
        guard #available(macOS 27.0, *) else { return }

        let request = try VisionTextRecognizer.makeCPURequest()
        let image = try makeScreenCaptureSample()
        let handler = VNSequenceRequestHandler()

        try handler.perform([request], on: image)

        let text = (request.results ?? [])
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
        #expect(text.contains("234"))
        #expect(text.contains("文字识别"))
    }

    private func makeScreenCaptureSample() throws -> CGImage {
        let width = 1720
        let height = 470
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }

        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String):
                CTFontCreateWithName("PingFangSC-Regular" as CFString, 36, nil),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1),
        ]

        for (index, lineText) in ["Hello OCR 234", "文字识别测试"].enumerated() {
            let line = CTLineCreateWithAttributedString(
                NSAttributedString(string: lineText, attributes: attributes)
            )
            context.textPosition = CGPoint(x: 80, y: height - 90 - index * 70)
            CTLineDraw(line, context)
        }

        guard let image = context.makeImage() else { throw CocoaError(.fileWriteUnknown) }
        return image
    }
}
