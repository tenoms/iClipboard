import XCTest
import CoreGraphics
import CoreText
import AppKit
@testable import iClipboard

@MainActor
final class ImageTextRecognizerTests: XCTestCase {
    func testFixedEnglishImageUsesRealOfflineVision() async throws {
        // One real OCR test, drawn deterministically with a system font. No fixture
        // download, authorization request, network toggle, or external service.
        let result = try await ImageTextRecognizer().recognize(makeImage(withText: true))

        XCTAssertEqual(result.text, "OFFLINE TEXT\nHELLO WORLD")
        XCTAssertEqual(result.lines.count, 2)
        let top = try XCTUnwrap(result.lines.first?.boundingBox)
        let bottom = try XCTUnwrap(result.lines.last?.boundingBox)
        XCTAssertGreaterThan(top.midY, bottom.midY)
        XCTAssertTrue(CGRect(x: 0, y: 0, width: 1, height: 1).contains(top))
    }

    func testReadingOrderGroupsRowsBeforeSortingLeftToRight() {
        let bottom = line("bottom", x: 0.1, y: 0.2)
        let right = line("right", x: 0.6, y: 0.805)
        let left = line("left", x: 0.1, y: 0.8)
        let middle = line("middle", x: 0.1, y: 0.5)
        let input = [bottom, right, middle, left]

        XCTAssertEqual(ImageTextRecognitionResult(lines: input).text, "left\nright\nmiddle\nbottom")
        XCTAssertEqual(ImageTextRecognitionResult(lines: input.reversed()).text, "left\nright\nmiddle\nbottom")
    }

    func testMissingAndInvalidBoxesKeepStableInputOrderAtEnd() {
        let missing = ImageTextLine(text: "missing")
        let invalid = ImageTextLine(text: "invalid", boundingBox: CGRect(x: 0, y: 0, width: 0, height: 0))
        let positioned = line("first", x: 0.2, y: 0.6)
        let result = ImageTextRecognitionResult(lines: [missing, positioned, invalid])
        XCTAssertEqual(result.text, "first\nmissing\ninvalid")
        XCTAssertEqual(ImageTextRecognitionResult(lines: []).text, "")
    }

    func testBoundingBoxesCanBeOmittedWithoutLosingReadingOrder() async throws {
        let request = ImmediateOCRRequest(lines: [line("second", x: 0.1, y: 0.2), line("first", x: 0.1, y: 0.8)])
        let recognizer = ImageTextRecognizer(includeBoundingBoxes: false, requestFactory: { request })
        let result = try await recognizer.recognize(makeImage())
        XCTAssertEqual(result.text, "first\nsecond")
        XCTAssertTrue(result.lines.allSatisfy { $0.boundingBox == nil })
    }

    func testLanguageSelectionUsesOnlyRuntimeSupportedIdentifiers() {
        XCTAssertEqual(ImageTextRecognizer.recognitionLanguages(from: ["fr-FR", "en-GB", "zh-Hans", "en-US", "zh-Hant"]),
                       ["zh-Hans", "zh-Hant", "en-US"])
        XCTAssertEqual(ImageTextRecognizer.recognitionLanguages(from: ["en_GB", "zh_CN"]), ["zh_CN", "en_GB"])
        XCTAssertEqual(ImageTextRecognizer.recognitionLanguages(from: ["en-US"]), ["en-US"])
        XCTAssertEqual(ImageTextRecognizer.recognitionLanguages(from: ["zh-Hans"]), ["zh-Hans"])
        XCTAssertTrue(ImageTextRecognizer.recognitionLanguages(from: ["fr-FR"]).isEmpty)
    }

    func testCancellationReachesBlockedRequestBeforePerformReturns() async throws {
        let started = expectation(description: "Adapter is blocked in perform")
        let cancelled = expectation(description: "Underlying request cancelled without waiting for worker")
        let finished = expectation(description: "Late adapter completion drained")
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let request = BlockingOCRRequest(gate: gate, onStart: { started.fulfill() },
                                         onCancel: { cancelled.fulfill() }, onFinish: { finished.fulfill() })
        let recognizer = ImageTextRecognizer(requestFactory: { request })
        let image = try makeImage()
        let task = Task { try await recognizer.recognize(image) }
        await fulfillment(of: [started], timeout: 3)

        task.cancel()
        await fulfillment(of: [cancelled], timeout: 1)
        do {
            _ = try await task.value
            XCTFail("Cancellation must not wait for the blocked perform or return its late success")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        gate.signal()
        await fulfillment(of: [finished], timeout: 3)
    }

    func testAlreadyCancelledTaskNeverCreatesRequest() async throws {
        let tracker = OCRConcurrencyTracker()
        let recognizer = ImageTextRecognizer(requestFactory: {
            tracker.enter()
            return ImmediateOCRRequest(lines: [])
        })
        let image = try makeImage()
        // Inherits MainActor, so cancel runs before this task can start.
        let task = Task { try await recognizer.recognize(image) }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("An already-cancelled task must throw")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(tracker.snapshot.started, 0)
    }

    func testConcurrencyIsBoundedAcrossRecognizerInstances() async throws {
        let firstTwoStarted = expectation(description: "Both worker slots occupied")
        let tracker = OCRConcurrencyTracker()
        let gate = DispatchSemaphore(value: 0)
        let image = try makeImage()
        let tasks = (0..<6).map { _ in
            let recognizer = ImageTextRecognizer(requestFactory: {
                BlockingOCRRequest(gate: gate, onStart: {
                    if tracker.enter() == 2 { firstTwoStarted.fulfill() }
                }, onFinish: { tracker.leave() })
            })
            return Task { try await recognizer.recognize(image) }
        }
        defer { for _ in tasks { gate.signal() } }
        await fulfillment(of: [firstTwoStarted], timeout: 3)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(tracker.snapshot.started, 2, "Other windows must queue, not launch more Vision work")
        for _ in tasks { gate.signal() }
        for task in tasks { _ = try await task.value }
        XCTAssertEqual(tracker.snapshot.maximum, 2)
        XCTAssertEqual(tracker.snapshot.started, 6)
    }

    private func line(_ text: String, x: CGFloat, y: CGFloat) -> ImageTextLine {
        ImageTextLine(text: text, boundingBox: CGRect(x: x, y: y, width: 0.2, height: 0.08))
    }

    private func makeImage(withText: Bool = false) throws -> ToolImage {
        let width = withText ? 900 : 16, height = withText ? 260 : 16
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height,
                                            bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        if withText {
            let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 60, nil)
            for (text, y) in [("OFFLINE TEXT", 165.0), ("HELLO WORLD", 65.0)] {
                let attributes: [NSAttributedString.Key: Any] = [
                    NSAttributedString.Key(kCTFontAttributeName as String): font,
                    NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)
                ]
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
                context.textPosition = CGPoint(x: 60, y: y)
                CTLineDraw(line, context)
            }
        }
        return ToolImage(cgImage: try XCTUnwrap(context.makeImage()), title: "OCR unit test")
    }
}

private enum TestOCRError: Error { case failed }

private final class ImmediateOCRRequest: ImageTextRecognitionRequest {
    let lines: [ImageTextLine]
    init(lines: [ImageTextLine]) { self.lines = lines }
    func perform(on image: CGImage) throws -> [ImageTextLine] { lines }
    func cancel() {}
}

/// Deliberately ignores cancellation and eventually succeeds, exercising the
/// recognizer's exactly-once continuation ownership rather than Vision timing.
private final class BlockingOCRRequest: ImageTextRecognitionRequest {
    let gate: DispatchSemaphore
    let onStart: () -> Void
    let onCancel: () -> Void
    let onFinish: () -> Void

    init(gate: DispatchSemaphore, onStart: @escaping () -> Void,
         onCancel: @escaping () -> Void = {}, onFinish: @escaping () -> Void = {}) {
        self.gate = gate
        self.onStart = onStart
        self.onCancel = onCancel
        self.onFinish = onFinish
    }

    func perform(on image: CGImage) throws -> [ImageTextLine] {
        onStart()
        defer { onFinish() }
        guard gate.wait(timeout: .now() + 8) == .success else { throw TestOCRError.failed }
        return [ImageTextLine(text: "late adapter success")]
    }

    func cancel() { onCancel() }
}

private final class OCRConcurrencyTracker {
    private let lock = NSLock()
    private var running = 0
    private var started = 0
    private var maximum = 0

    @discardableResult
    func enter() -> Int {
        lock.lock()
        defer { lock.unlock() }
        running += 1
        started += 1
        maximum = max(maximum, running)
        return started
    }

    func leave() {
        lock.lock()
        running -= 1
        lock.unlock()
    }

    var snapshot: (started: Int, maximum: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (started, maximum)
    }
}
