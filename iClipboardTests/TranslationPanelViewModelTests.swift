import XCTest
@testable import iClipboard

@MainActor
final class TranslationPanelViewModelTests: XCTestCase {
    private let context = SelectedTextContext(
        text: "hello",
        anchorRect: .init(x: 20, y: 20, width: 40, height: 18),
        cursorPoint: .init(x: 40, y: 30),
        sourceApplicationName: "Tests",
        sourceBundleIdentifier: "com.example.tests"
    )

    func testPinStateCanBeToggledWithoutChangingTranslation() {
        let model = TranslationPanelViewModel()
        model.beginTranslation(context, provider: .doubaoAI)

        model.togglePin()

        XCTAssertTrue(model.isPinned)
        XCTAssertEqual(model.presentation?.context.text, "hello")
    }

    func testTranslationTransitionsPreservePresentation() async {
        let model = TranslationPanelViewModel()
        model.beginTranslation(context, provider: .microsoft)
        model.setDetectedDirection(targetLanguage: "zh")
        model.updatePartialText("你好")
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(model.presentation?.provider, .microsoft)
        XCTAssertEqual(model.presentation?.directionLabel, "其他语言 → 中文")
        XCTAssertEqual(model.presentation?.translatedText, "你好")

        let result = TranslationResult(
            sourceText: "hello",
            translatedText: "你好",
            detectedLanguage: "en",
            targetLanguage: "zh",
            provider: .microsoft
        )
        await model.finish(with: result)

        guard case .translated = model.phase else {
            return XCTFail("Expected translated phase")
        }
    }
}
