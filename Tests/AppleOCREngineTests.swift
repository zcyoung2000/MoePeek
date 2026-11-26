import CoreGraphics
import CoreText
import Foundation
import Testing
@testable import MoePeek

@Suite(.timeLimit(.minutes(3)))
struct AppleOCREngineTests {
    @Test @MainActor func accurateVisionReusesTheWarmedProcess() async throws {
        OCRWarmupCoordinator.warmUpIfNeeded()
        let deadline = ContinuousClock.now + .seconds(150)
        while !OCRWarmupCoordinator.isReady, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(OCRWarmupCoordinator.isReady)

        let image = try makeMixedLanguageImage()
        let text = try await AppleOCREngine.recognizeText(in: image, timeout: 20)

        #expect(text.contains("MoePeek OCR 123"))
        #expect(text.contains("文字识别"))

        let repeatedText = try await AppleOCREngine.recognizeText(in: image, timeout: 20)
        #expect(repeatedText.contains("MoePeek OCR 123"))
    }

    private func makeMixedLanguageImage() throws -> CGImage {
        let width = 530
        let height = 112
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
                CTFontCreateWithName("PingFangSC-Regular" as CFString, 22, nil),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1),
        ]

        for (index, text) in ["MoePeek OCR 123", "文字识别 日本語 한국어"].enumerated() {
            let line = CTLineCreateWithAttributedString(
                NSAttributedString(string: text, attributes: attributes)
            )
            context.textPosition = CGPoint(x: 28, y: 78 - index * 42)
            CTLineDraw(line, context)
        }

        guard let image = context.makeImage() else { throw CocoaError(.fileWriteUnknown) }
        return image
    }
}
