import Foundation
import CoreGraphics
import Vision

struct ImageTextLine: Equatable {
    let text: String
    /// Vision-normalized coordinates: origin at the image's lower-left, range 0...1.
    let boundingBox: CGRect?
    let confidence: Float

    init(text: String, boundingBox: CGRect? = nil, confidence: Float = 1) {
        self.text = text
        self.boundingBox = boundingBox
        self.confidence = confidence
    }
}

struct ImageTextRecognitionResult: Equatable {
    let lines: [ImageTextLine]
    var text: String { lines.map(\.text).joined(separator: "\n") }

    init(lines: [ImageTextLine], includeBoundingBoxes: Bool = true) {
        let ordered = Self.sortedInReadingOrder(lines)
        self.lines = includeBoundingBoxes ? ordered : ordered.map {
            ImageTextLine(text: $0.text, confidence: $0.confidence)
        }
    }

    /// Horizontal Chinese/English reading order. Cluster against a fixed row anchor
    /// rather than using a non-transitive, tolerance-based sort comparator.
    /// Fragments on a row go left to right; unpositioned lines retain input order last.
    static func sortedInReadingOrder(_ lines: [ImageTextLine]) -> [ImageTextLine] {
        let positioned = lines.enumerated().filter { usableBox($0.element.boundingBox) }
            .sorted { lhs, rhs in
                let left = lhs.element.boundingBox!, right = rhs.element.boundingBox!
                if left.midY != right.midY { return left.midY > right.midY }
                if left.minX != right.minX { return left.minX < right.minX }
                return lhs.offset < rhs.offset
            }
        var rows: [[(offset: Int, element: ImageTextLine)]] = []
        for line in positioned {
            if let anchor = rows.last?.first?.element.boundingBox,
               let box = line.element.boundingBox,
               abs(anchor.midY - box.midY) <= min(anchor.height, box.height) * 0.5 {
                rows[rows.count - 1].append(line)
            } else {
                rows.append([line])
            }
        }
        let ordered = rows.flatMap { row in
            row.sorted { lhs, rhs in
                let left = lhs.element.boundingBox!, right = rhs.element.boundingBox!
                if left.minX != right.minX { return left.minX < right.minX }
                return lhs.offset < rhs.offset
            }.map(\.element)
        }
        return ordered + lines.filter { !usableBox($0.boundingBox) }
    }

    private static func usableBox(_ box: CGRect?) -> Bool {
        guard let box else { return false }
        return box.origin.x.isFinite && box.origin.y.isFinite
            && box.width.isFinite && box.height.isFinite && box.width > 0 && box.height > 0
    }
}

protocol TextRecognizer {
    func recognize(_ image: ToolImage) async throws -> ImageTextRecognitionResult
}

/// Synchronous adapter boundary so cancellation and late completions can be tested
/// without invoking Vision or requiring permissions. Each invocation gets a new request.
protocol ImageTextRecognitionRequest: AnyObject {
    func perform(on image: CGImage) throws -> [ImageTextLine]
    func cancel()
}

enum ImageTextRecognitionError: LocalizedError {
    case unsupportedLanguages

    var errorDescription: String? {
        "当前系统没有可用的中英文识别语言，请检查系统后重试。"
    }
}

final class ImageTextRecognizer: TextRecognizer {
    // Shared across windows/instances, not one unbounded worker per window.
    private static let workers: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.iclipboard.image-text-recognition"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 2
        return queue
    }()

    private let includeBoundingBoxes: Bool
    private let makeRequest: () -> ImageTextRecognitionRequest

    init(includeBoundingBoxes: Bool = true) {
        self.includeBoundingBoxes = includeBoundingBoxes
        makeRequest = { VisionImageTextRequest() }
    }

    /// Internal injection point; production always uses the real VNRecognizeTextRequest.
    init(includeBoundingBoxes: Bool = true, requestFactory: @escaping () -> ImageTextRecognitionRequest) {
        self.includeBoundingBoxes = includeBoundingBoxes
        makeRequest = requestFactory
    }

    func recognize(_ image: ToolImage) async throws -> ImageTextRecognitionResult {
        let job = ImageTextRecognitionJob(image: image.cgImage, includeBoundingBoxes: includeBoundingBoxes)
        let factory = makeRequest
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                guard job.install(continuation) else { return }
                Self.workers.addOperation {
                    autoreleasepool { job.perform(using: factory) }
                }
            }
        }, onCancel: {
            // Never dispatch cancellation behind a blocking perform() on the worker queue.
            job.cancel()
        })
    }

    /// Use the identifiers actually supported by this request/revision, not a fixed
    /// list that can fail on older systems. Prefer US English when available.
    static func recognitionLanguages(from supported: [String]) -> [String] {
        func code(_ value: String) -> String {
            value.replacingOccurrences(of: "_", with: "-").lowercased()
        }
        let chinese = supported.filter { code($0) == "zh" || code($0).hasPrefix("zh-") }
        let english = supported.first { code($0) == "en-us" }
            ?? supported.first { code($0) == "en" || code($0).hasPrefix("en-") }
        return chinese + (english.map { [$0] } ?? [])
    }
}

private final class VisionImageTextRequest: ImageTextRecognitionRequest {
    private let request = VNRecognizeTextRequest()
    private let lock = NSLock()
    private var cancelled = false

    init() {
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        request.preferBackgroundProcessing = true
    }

    func perform(on image: CGImage) throws -> [ImageTextLine] {
        try checkCancellation()
        let languages = ImageTextRecognizer.recognitionLanguages(from: try request.supportedRecognitionLanguages())
        guard !languages.isEmpty else { throw ImageTextRecognitionError.unsupportedLanguages }
        request.recognitionLanguages = languages
        try checkCancellation()
        // ToolImage.decode already normalizes EXIF orientation. No NSImage/UIImage
        // conversion, network request, authorization, or image upload is involved.
        try VNImageRequestHandler(cgImage: image, orientation: .up, options: [:]).perform([request])
        try checkCancellation()
        return (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first, !candidate.string.isEmpty else { return nil }
            return ImageTextLine(text: candidate.string, boundingBox: observation.boundingBox,
                                 confidence: candidate.confidence)
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
        request.cancel()
    }

    private func checkCancellation() throws {
        lock.lock()
        let value = cancelled
        lock.unlock()
        if value { throw CancellationError() }
    }
}

/// The lock protects continuation ownership only; Vision work and cancel() never
/// run under it. A terminal job drops queued image ownership and resumes exactly once.
/// All mutable state is guarded by `lock`; cancellation may arrive from any thread.
private final class ImageTextRecognitionJob: @unchecked Sendable {
    private let lock = NSLock()
    private let includeBoundingBoxes: Bool
    private var image: CGImage?
    private var request: ImageTextRecognitionRequest?
    private var continuation: CheckedContinuation<ImageTextRecognitionResult, Error>?
    private var finished = false

    init(image: CGImage, includeBoundingBoxes: Bool) {
        self.image = image
        self.includeBoundingBoxes = includeBoundingBoxes
    }

    func install(_ continuation: CheckedContinuation<ImageTextRecognitionResult, Error>) -> Bool {
        lock.lock()
        guard !finished else {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return false
        }
        self.continuation = continuation
        lock.unlock()
        return true
    }

    func perform(using factory: () -> ImageTextRecognitionRequest) {
        lock.lock()
        guard !finished, let image else { lock.unlock(); return }
        self.image = nil
        lock.unlock()

        let request = factory()
        lock.lock()
        guard !finished else { lock.unlock(); request.cancel(); return }
        self.request = request
        lock.unlock()

        do {
            let lines = try request.perform(on: image)
            finish(.success(ImageTextRecognitionResult(lines: lines, includeBoundingBoxes: includeBoundingBoxes)))
        } catch {
            finish(.failure(error))
        }
    }

    func cancel() {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let request = self.request
        let continuation = self.continuation
        self.request = nil
        self.continuation = nil
        image = nil
        lock.unlock()

        request?.cancel()
        continuation?.resume(throwing: CancellationError())
    }

    private func finish(_ result: Result<ImageTextRecognitionResult, Error>) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let continuation = self.continuation
        self.continuation = nil
        request = nil
        image = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}
