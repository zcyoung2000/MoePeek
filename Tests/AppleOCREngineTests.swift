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
        try #require(OCRWarmupCoordinator.isReady)

        // Change both image size and content to catch stale model resources and
        // accidentally returning the preceding request's observations.
        for (width, height, marker, script) in [
            (530, 112, "123", "文字识别测试"),
            (1718, 204, "456", "文字识别测试"),
            (960, 240, "789", "日本語の認識"),
            (960, 240, "852", "한국어 인식"),
            (530, 112, "123", "文字识别测试"),
        ] {
            let image = try makeMixedLanguageImage(width: width, height: height, marker: marker, script: script)
            let text = try await AppleOCREngine.recognizeText(in: image, timeout: 20)
            #expect(text.contains("Hello"))
            #expect(text.contains(marker))
            #expect(text.contains(script))
        }
    }

    private func makeMixedLanguageImage(width: Int, height: Int, marker: String, script: String) throws -> CGImage {
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
        // Vision scales wide inputs for detection; keep their text legible at
        // that scale instead of testing a tiny, language-corrected acronym.
        let fontSize: CGFloat = width >= 1500 ? 44 : 28
        let lineSpacing = width >= 1500 ? 64 : 44
        let lines = ["Hello world \(marker)", script]
        for (index, text) in lines.enumerated() {
            let fontName = index == 0 ? "Helvetica" : "PingFangSC-Regular"
            let attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String):
                    CTFontCreateWithName(fontName as CFString, fontSize, nil),
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1),
            ]
            let line = CTLineCreateWithAttributedString(
                NSAttributedString(string: text, attributes: attributes)
            )
            context.textPosition = CGPoint(x: 28, y: height - Int(fontSize) - 8 - index * lineSpacing)
            CTLineDraw(line, context)
        }

        guard let image = context.makeImage() else { throw CocoaError(.fileWriteUnknown) }
        return image
    }
}
