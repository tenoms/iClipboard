import AppKit
import XCTest
@testable import iClipboard

final class ScreenCaptureSessionTests: XCTestCase {
    func testReverseDragOnNegativeCoordinateRetinaDisplay() {
        let geometry = ScreenCaptureGeometry(displayFrame: CGRect(x: -1_440, y: -200, width: 1_440, height: 900),
                                             imageSize: CGSize(width: 2_880, height: 1_800))
        let selection = geometry.selection(from: CGPoint(x: -100, y: 600), to: CGPoint(x: -400, y: 400))
        XCTAssertEqual(selection, CGRect(x: -400, y: 400, width: 300, height: 200))
        XCTAssertEqual(geometry.pixelRect(for: selection), CGRect(x: 2_080, y: 200, width: 600, height: 400))
    }

    func testMappingUsesActualImageDimensionsInsteadOfAssumedRetinaScale() {
        let geometry = ScreenCaptureGeometry(displayFrame: CGRect(x: -100, y: 500, width: 1_000, height: 500),
                                             imageSize: CGSize(width: 1_500, height: 1_250))
        XCTAssertEqual(geometry.pixelRect(for: CGRect(x: 0, y: 600, width: 200, height: 100)),
                       CGRect(x: 150, y: 750, width: 300, height: 250))
    }

    func testDragCannotCrossStartingDisplay() {
        let geometry = ScreenCaptureGeometry(displayFrame: CGRect(x: -100, y: -100, width: 100, height: 100),
                                             imageSize: CGSize(width: 200, height: 200))
        let selection = geometry.selection(from: CGPoint(x: -50, y: -50), to: CGPoint(x: 500, y: 500))
        XCTAssertEqual(selection, CGRect(x: -50, y: -50, width: 50, height: 50))
        XCTAssertEqual(geometry.pixelRect(for: selection), CGRect(x: 100, y: 0, width: 100, height: 100))
    }

    func testColorSamplingClampsExactFarEdgesToLastPixel() {
        let geometry = ScreenCaptureGeometry(displayFrame: CGRect(x: -100, y: -50, width: 100, height: 50),
                                             imageSize: CGSize(width: 200, height: 150))
        XCTAssertEqual(geometry.pixelPoint(at: CGPoint(x: 0, y: -50)), CGPoint(x: 199, y: 149))
        XCTAssertEqual(geometry.pixelPoint(at: CGPoint(x: -100, y: 0)), .zero)
    }

    func testFractionalSelectionRoundsOutwardsAndAnchorMatchesPixels() throws {
        let geometry = ScreenCaptureGeometry(displayFrame: CGRect(x: -10, y: 20, width: 100, height: 100),
                                             imageSize: CGSize(width: 200, height: 200))
        let selection = CGRect(x: -9.9, y: 20.1, width: 0.2, height: 0.2)
        let pixels = try XCTUnwrap(geometry.pixelRect(for: selection))
        XCTAssertEqual(pixels, CGRect(x: 0, y: 199, width: 1, height: 1))
        let anchor = geometry.appKitRect(forPixels: pixels)
        XCTAssertEqual(anchor, CGRect(x: -10, y: 20, width: 0.5, height: 0.5))
        XCTAssertTrue(anchor.contains(selection))
    }

    func testMovingSelectionKeepsSizeAndClampsAtDisplayBoundary() {
        let geometry = ScreenCaptureGeometry(displayFrame: CGRect(x: -100, y: -50, width: 100, height: 100),
                                             imageSize: CGSize(width: 200, height: 200))
        let moved = geometry.moving(CGRect(x: -80, y: -20, width: 30, height: 40),
                                    by: CGSize(width: 200, height: -200))
        XCTAssertEqual(moved, CGRect(x: -30, y: -50, width: 30, height: 40))
    }

    func testInvalidAndEmptySelectionsDoNotProducePixels() {
        let geometry = ScreenCaptureGeometry(displayFrame: CGRect(x: 0, y: 0, width: 100, height: 100),
                                             imageSize: CGSize(width: 200, height: 200))
        XCTAssertNil(geometry.pixelRect(for: .zero))
        XCTAssertNil(geometry.pixelRect(for: CGRect(x: 200, y: 0, width: 10, height: 10)))
        XCTAssertNil(geometry.pixelRect(for: CGRect(x: CGFloat.nan, y: 0, width: 10, height: 10)))
        XCTAssertNil(geometry.pixelPoint(at: CGPoint(x: CGFloat.infinity, y: 0)))
    }

    func testIndependentCropKeepsTopDownPixelOrientationAndOnlySelectedBytes() throws {
        let image = try makeImage()
        // Source rows are red/green, then blue/white, in top-down pixel coordinates.
        let crop = try ScreenCaptureImageRenderer.independentCrop(of: image,
                                                                  pixels: CGRect(x: 1, y: 0, width: 1, height: 2))
        XCTAssertEqual(crop.width, 1)
        XCTAssertEqual(crop.height, 2)
        XCTAssertEqual(ToolImage(cgImage: crop).color(at: .zero)?.hex, "#00FF00")
        XCTAssertEqual(ToolImage(cgImage: crop).color(at: CGPoint(x: 0, y: 1))?.hex, "#FFFFFF")
        let data = try XCTUnwrap(crop.dataProvider?.data)
        XCTAssertEqual(CFDataGetLength(data), crop.bytesPerRow * crop.height)
        XCTAssertLessThan(CFDataGetLength(data), image.bytesPerRow * image.height)
    }

    func testIndependentCropDoesNotRetainOriginalPixelProvider() throws {
        var released = false
        var cropped: CGImage?
        try autoreleasepool {
            let bytes = UnsafeMutableRawPointer.allocate(byteCount: 16, alignment: 4)
            bytes.initializeMemory(as: UInt8.self, repeating: 255, count: 16)
            let box = Unmanaged.passRetained(ProviderReleaseBox { released = true })
            let provider = try XCTUnwrap(CGDataProvider(dataInfo: box.toOpaque(), data: bytes, size: 16,
                                                       releaseData: { info, data, _ in
                UnsafeMutableRawPointer(mutating: data).deallocate()
                if let info = info { Unmanaged<ProviderReleaseBox>.fromOpaque(info).takeRetainedValue().release() }
            }))
            let image = try XCTUnwrap(CGImage(width: 2, height: 2, bitsPerComponent: 8, bitsPerPixel: 32,
                                              bytesPerRow: 8, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                              provider: provider, decode: nil, shouldInterpolate: false,
                                              intent: .defaultIntent))
            cropped = try ScreenCaptureImageRenderer.independentCrop(of: image,
                                                                     pixels: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        XCTAssertTrue(released, "The selected image must not retain the full-screen source provider")
        XCTAssertNotNil(cropped)
    }

    func testCompletionGateResolvesExactlyOnceUnderConcurrentCallbacks() {
        let lock = NSLock()
        var completions = 0
        let gate = ScreenCaptureOnce<Int> { _ in
            lock.lock()
            completions += 1
            lock.unlock()
        }
        DispatchQueue.concurrentPerform(iterations: 100) { gate.resolve($0) }
        XCTAssertEqual(completions, 1)
        XCTAssertFalse(gate.isPending)
        XCTAssertFalse(gate.resolve(101))
    }

    func testInvalidatedGateReleasesCallbackAndIgnoresLateCompletion() {
        weak var weakBox: ProviderReleaseBox?
        var released = false
        var gate: ScreenCaptureOnce<Int>?
        autoreleasepool {
            let box = ProviderReleaseBox { released = true }
            weakBox = box
            gate = ScreenCaptureOnce { [box] _ in box.release() }
        }
        XCTAssertNotNil(weakBox)
        gate?.invalidate()
        XCTAssertNil(weakBox)
        XCTAssertFalse(gate?.resolve(1) ?? true)
        XCTAssertFalse(released)
    }

    @MainActor
    func testStreamStopIsIdempotentAfterStarting() {
        var removed = 0, stopped = 0
        let lifetime = ScreenCaptureStreamLifetime(removeOutput: { removed += 1 }, stopStream: { stopped += 1 })
        lifetime.didCompleteStart()
        lifetime.stop()
        lifetime.stop()
        lifetime.didCompleteStart()
        XCTAssertEqual(removed, 1)
        XCTAssertEqual(stopped, 1)
    }

    @MainActor
    func testCancellationBeforeStartStopsImmediatelyAndAgainForLateStartOnlyOnce() {
        var removed = 0, stopped = 0
        let lifetime = ScreenCaptureStreamLifetime(removeOutput: { removed += 1 }, stopStream: { stopped += 1 })
        lifetime.stop()
        lifetime.stop()
        XCTAssertEqual(removed, 1)
        XCTAssertEqual(stopped, 1)
        lifetime.didCompleteStart()
        lifetime.didCompleteStart()
        lifetime.stop()
        XCTAssertEqual(removed, 1)
        XCTAssertEqual(stopped, 2)
    }

    @MainActor
    func testCancelReleasesProviderAndReturnsNilWithoutTCC() async throws {
        weak var weakProvider: ControlledCaptureProvider?
        let started = expectation(description: "Capture adapter started")
        let session = ScreenCaptureSession(providerFactory: {
            let provider = ControlledCaptureProvider { started.fulfill() }
            weakProvider = provider
            return provider
        }, accessCheck: { true }, accessRequest: { XCTFail("Must not request TCC"); return false })
        let task = Task { try await session.run(.image) }
        await fulfillment(of: [started], timeout: 1)
        session.cancel()
        session.cancel()
        let result = try await task.value
        XCTAssertNil(result)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertNil(weakProvider)
    }

    @MainActor
    func testTaskCancellationReturnsNilAndReleasesAdapter() async throws {
        let started = expectation(description: "Capture adapter started")
        var stopCount = 0
        let session = ScreenCaptureSession(providerFactory: {
            ControlledCaptureProvider(started: { started.fulfill() }, stopped: { stopCount += 1 })
        }, accessCheck: { true }, accessRequest: { XCTFail("Must not request TCC"); return false })
        let task = Task { try await session.run(.color) }
        await fulfillment(of: [started], timeout: 1)
        task.cancel()
        let result = try await task.value
        XCTAssertNil(result)
        XCTAssertEqual(stopCount, 1)
    }

    @MainActor
    func testPreparationTimeoutStillCancelsProviderAndReportsFailure() async throws {
        var stopCount = 0
        let session = ScreenCaptureSession(providerFactory: {
            ControlledCaptureProvider(started: {}, stopped: { stopCount += 1 })
        }, accessCheck: { true }, accessRequest: { false }, timeoutSleep: { nanoseconds in
            XCTAssertEqual(nanoseconds, 20_000_000_000)
            await Task.yield()
        })
        do {
            _ = try await session.run(.image)
            XCTFail("Screen preparation must remain bounded")
        } catch ScreenCaptureError.timedOut { }
        XCTAssertEqual(stopCount, 1)
        XCTAssertTrue(session.capturePanels.isEmpty)
    }

    @MainActor
    func testOnlyOneSessionCanRunAcrossInstances() async throws {
        let started = expectation(description: "First capture started")
        let first = ScreenCaptureSession(providerFactory: { ControlledCaptureProvider { started.fulfill() } },
                                         accessCheck: { true }, accessRequest: { false })
        let second = ScreenCaptureSession(providerFactory: { XCTFail("Second adapter must not start"); return ControlledCaptureProvider {} },
                                          accessCheck: { XCTFail("Second session must not check access"); return true },
                                          accessRequest: { false })
        let task = Task { try await first.run(.image) }
        await fulfillment(of: [started], timeout: 1)
        do {
            _ = try await second.run(.image)
            XCTFail("Expected alreadyRunning")
        } catch ScreenCaptureError.alreadyRunning {} catch { XCTFail("Unexpected error: \(error)") }
        first.cancel()
        let result = try await task.value
        XCTAssertNil(result)
    }

    private func makeImage() throws -> CGImage {
        let bytes: [UInt8] = [255, 0, 0, 255, 0, 255, 0, 255,
                              0, 0, 255, 255, 255, 255, 255, 255]
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        return try XCTUnwrap(CGImage(width: 2, height: 2, bitsPerComponent: 8, bitsPerPixel: 32,
                                     bytesPerRow: 8, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                     bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                     provider: provider, decode: nil, shouldInterpolate: false,
                                     intent: .defaultIntent))
    }
}

private final class ProviderReleaseBox {
    let release: () -> Void
    init(_ release: @escaping () -> Void) { self.release = release }
}

@MainActor
private final class ControlledCaptureProvider: ScreenCaptureProviding {
    private var continuation: CheckedContinuation<[ScreenCaptureSnapshot], Error>?
    private let started: () -> Void
    private let stopped: () -> Void
    private var cancelled = false

    init(started: @escaping () -> Void, stopped: @escaping () -> Void = {}) {
        self.started = started
        self.stopped = stopped
    }

    func snapshots() async throws -> [ScreenCaptureSnapshot] {
        if cancelled { throw CancellationError() }
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            started()
        }
    }

    func cancel() {
        guard !cancelled else { return }
        cancelled = true
        let continuation = continuation
        self.continuation = nil
        stopped()
        continuation?.resume(throwing: CancellationError())
    }
}
