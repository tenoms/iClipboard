import AppKit
import CoreMedia
import CoreVideo
import ScreenCaptureKit

enum ScreenCaptureError: LocalizedError {
    case alreadyRunning
    case noDisplays
    case displayConfigurationChanged
    case tooManyPixels
    case timedOut
    case invalidFrame

    var errorDescription: String? {
        switch self {
        case .alreadyRunning: return "已有截图或取色操作正在进行，请先完成或取消。"
        case .noDisplays: return "没有可用于截图的显示器。"
        case .displayConfigurationChanged: return "显示器配置已改变，请重新截图。"
        case .tooManyPixels: return "所有屏幕的总像素超过 6400 万，请降低分辨率或断开部分显示器后重试。"
        case .timedOut: return "读取屏幕画面超时，请重试并检查屏幕录制权限。"
        case .invalidFrame: return "无法读取完整的屏幕画面，请重试。"
        }
    }
}

struct ScreenCaptureSnapshot {
    let displayID: CGDirectDisplayID
    let frame: CGRect
    let image: CGImage

    var geometry: ScreenCaptureGeometry {
        ScreenCaptureGeometry(displayFrame: frame,
                              imageSize: CGSize(width: image.width, height: image.height))
    }
}

@MainActor
protocol ScreenCaptureProviding: AnyObject {
    func snapshots() async throws -> [ScreenCaptureSnapshot]
    func cancel()
}

/// The callback is removed under a lock before invoking it. Cancellation, timeout,
/// delegate failure and a complete frame may race, but only one can win.
final class ScreenCaptureOnce<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var callback: ((Value) -> Void)?

    init(_ callback: @escaping (Value) -> Void) { self.callback = callback }

    var isPending: Bool {
        lock.lock()
        defer { lock.unlock() }
        return callback != nil
    }

    @discardableResult
    func resolve(_ value: Value) -> Bool {
        lock.lock()
        let callback = self.callback
        self.callback = nil
        lock.unlock()
        callback?(value)
        return callback != nil
    }

    func invalidate() {
        lock.lock()
        callback = nil
        lock.unlock()
    }
}

/// Kept independent from SCStream so late-start cancellation can be tested without TCC.
@MainActor
final class ScreenCaptureStreamLifetime {
    private var removeOutput: (() -> Void)?
    private var stopStream: (() -> Void)?
    private var startCompleted = false
    private var stopRequested = false

    init(removeOutput: @escaping () -> Void, stopStream: @escaping () -> Void) {
        self.removeOutput = removeOutput
        self.stopStream = stopStream
    }

    func didCompleteStart() {
        guard !startCompleted else { return }
        startCompleted = true
        if stopRequested {
            let stop = stopStream
            stopStream = nil
            // A pending start may finish after the initial stop. Stop that late
            // start too; duplicate callbacks and repeated cancellation are no-ops.
            stop?()
        }
    }

    func stop() {
        guard !stopRequested else { return }
        stopRequested = true
        let remove = removeOutput
        removeOutput = nil
        remove?()
        let stop = stopStream
        if startCompleted { stopStream = nil }
        // Detach the output and issue a stop even if startCapture never calls back.
        stop?()
    }
}

@MainActor
private final class ScreenCaptureContentRequest {
    private var gate: ScreenCaptureOnce<Swift.Result<SCShareableContent, Error>>?
    private var timeout: Task<Void, Never>?
    private var cancelled = false

    func content() async throws -> SCShareableContent {
        guard !cancelled else { throw CancellationError() }
        defer { timeout?.cancel(); timeout = nil; gate = nil }
        return try await withCheckedThrowingContinuation { continuation in
            let gate = ScreenCaptureOnce<Swift.Result<SCShareableContent, Error>> {
                continuation.resume(with: $0)
            }
            self.gate = gate
            timeout = Task {
                do { try await Task.sleep(nanoseconds: 8_000_000_000) } catch { return }
                gate.resolve(.failure(ScreenCaptureError.timedOut))
            }
            SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, error in
                if let error = error { gate.resolve(.failure(error)) }
                else if let content = content { gate.resolve(.success(content)) }
                else { gate.resolve(.failure(ScreenCaptureError.noDisplays)) }
            }
        }
    }

    func cancel() {
        cancelled = true
        gate?.resolve(.failure(CancellationError()))
        timeout?.cancel()
    }
}

private final class ScreenCaptureFrameSink: NSObject, SCStreamOutput, SCStreamDelegate {
    let gate: ScreenCaptureOnce<Swift.Result<CGImage, Error>>

    init(completion: @escaping (Swift.Result<CGImage, Error>) -> Void) {
        gate = ScreenCaptureOnce(completion)
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .screen, gate.isPending, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer,
                                                                         createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? NSNumber,
              SCFrameStatus(rawValue: rawStatus.intValue) == .complete else { return }
        // Never retain CMSampleBuffer / CVPixelBuffer / IOSurface past this callback.
        do { gate.resolve(.success(try Self.copyPixels(from: sampleBuffer))) }
        catch { gate.resolve(.failure(error)) }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        gate.resolve(.failure(error))
    }

    private static func copyPixels(from sampleBuffer: CMSampleBuffer) throws -> CGImage {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA else {
            throw ScreenCaptureError.invalidFrame
        }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        guard width > 0, height > 0, width <= ToolImage.maximumPixelCount / height else {
            throw ScreenCaptureError.tooManyPixels
        }
        guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else {
            throw ScreenCaptureError.invalidFrame
        }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let source = CVPixelBufferGetBaseAddress(buffer),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue |
                                        CGBitmapInfo.byteOrder32Little.rawValue),
              let destination = context.data else { throw ScreenCaptureError.invalidFrame }
        let sourceStride = CVPixelBufferGetBytesPerRow(buffer)
        guard sourceStride >= width * 4 else { throw ScreenCaptureError.invalidFrame }
        for row in 0..<height {
            memcpy(destination.advanced(by: row * context.bytesPerRow),
                   source.advanced(by: row * sourceStride), width * 4)
        }
        guard let image = context.makeImage() else { throw ScreenCaptureError.invalidFrame }
        return image
    }
}

@MainActor
private final class ScreenCaptureFrameRequest {
    private var continuation: CheckedContinuation<CGImage, Error>?
    private var sink: ScreenCaptureFrameSink?
    private var lifetime: ScreenCaptureStreamLifetime?
    private var timeout: Task<Void, Never>?
    private var cancelled = false

    func image(filter: SCContentFilter, width: Int, height: Int) async throws -> CGImage {
        guard !cancelled else { throw CancellationError() }
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let sink = ScreenCaptureFrameSink { [weak self] result in
                Task { @MainActor [weak self] in self?.finish(result) }
            }
            self.sink = sink
            let configuration = SCStreamConfiguration()
            configuration.width = width
            configuration.height = height
            configuration.pixelFormat = kCVPixelFormatType_32BGRA
            configuration.colorSpaceName = CGColorSpace.sRGB
            configuration.queueDepth = 3
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 15)
            configuration.showsCursor = false
            configuration.capturesAudio = false
            let stream = SCStream(filter: filter, configuration: configuration, delegate: sink)
            let lifetime = ScreenCaptureStreamLifetime(removeOutput: {
                try? stream.removeStreamOutput(sink, type: .screen)
            }, stopStream: {
                // Keep the stream alive through stop completion, but no image buffers.
                stream.stopCapture { [stream] _ in _ = stream }
            })
            self.lifetime = lifetime
            do {
                try stream.addStreamOutput(sink, type: .screen,
                                           sampleHandlerQueue: DispatchQueue(label: "iClipboard.capture.frame"))
            } catch {
                lifetime.didCompleteStart()
                finish(.failure(error))
                return
            }
            timeout = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { return }
                self?.finish(.failure(ScreenCaptureError.timedOut))
            }
            stream.startCapture { [weak self, lifetime] error in
                Task { @MainActor [weak self] in
                    lifetime.didCompleteStart()
                    if let error = error { self?.finish(.failure(error)) }
                }
            }
        }
    }

    func cancel() {
        cancelled = true
        finish(.failure(CancellationError()))
    }

    private func finish(_ result: Swift.Result<CGImage, Error>) {
        guard let continuation = continuation else { return }
        self.continuation = nil
        timeout?.cancel()
        timeout = nil
        sink?.gate.invalidate()
        sink = nil
        lifetime?.stop()
        lifetime = nil
        continuation.resume(with: result)
    }
}

@MainActor
final class ScreenCaptureKitProvider: ScreenCaptureProviding {
    private var contentRequest: ScreenCaptureContentRequest?
    private var frameRequest: ScreenCaptureFrameRequest?
    private var cancelled = false

    func snapshots() async throws -> [ScreenCaptureSnapshot] {
        guard !cancelled else { throw CancellationError() }
        let screens = NSScreen.screens
        guard !screens.isEmpty else { throw ScreenCaptureError.noDisplays }
        // Snapshot all geometry before the first suspension. NSScreen is AppKit-only.
        let descriptors = try screens.map { screen -> (CGDirectDisplayID, CGRect, Int, Int) in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                throw ScreenCaptureError.noDisplays
            }
            return (id.uint32Value, screen.frame,
                    max(1, Int((screen.frame.width * screen.backingScaleFactor).rounded())),
                    max(1, Int((screen.frame.height * screen.backingScaleFactor).rounded())))
        }
        var budget = ToolImage.maximumPixelCount
        for (_, _, width, height) in descriptors {
            guard height > 0, width <= budget / height else { throw ScreenCaptureError.tooManyPixels }
            budget -= width * height
        }
        let contentRequest = ScreenCaptureContentRequest()
        self.contentRequest = contentRequest
        defer { self.contentRequest = nil; frameRequest = nil }
        let content = try await contentRequest.content()
        guard !cancelled else { throw CancellationError() }
        let ownApplications = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        var results = [ScreenCaptureSnapshot]()
        budget = ToolImage.maximumPixelCount
        for (id, frame, width, height) in descriptors {
            guard !cancelled else { throw CancellationError() }
            guard let display = content.displays.first(where: { $0.displayID == id }) else {
                throw ScreenCaptureError.displayConfigurationChanged
            }
            let filter = SCContentFilter(display: display, excludingApplications: ownApplications,
                                         exceptingWindows: [])
            let request = ScreenCaptureFrameRequest()
            frameRequest = request
            let image = try await request.image(filter: filter, width: width, height: height)
            frameRequest = nil
            guard !cancelled else { throw CancellationError() }
            guard image.height > 0, image.width <= budget / image.height else {
                throw ScreenCaptureError.tooManyPixels
            }
            budget -= image.width * image.height
            results.append(ScreenCaptureSnapshot(displayID: id, frame: frame, image: image))
        }
        return results
    }

    func cancel() {
        cancelled = true
        contentRequest?.cancel()
        frameRequest?.cancel()
        contentRequest = nil
        frameRequest = nil
    }
}
