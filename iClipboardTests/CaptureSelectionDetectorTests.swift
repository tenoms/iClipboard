import AppKit
import ApplicationServices
import XCTest
@testable import iClipboard

final class CaptureSelectionDetectorTests: XCTestCase {
    private final class Resolver: CaptureElementResolving {
        private let lock = NSLock()
        private var requests: [CaptureElementRequest] = []
        private var active = 0
        private var peak = 0
        private let handler: (CaptureElementRequest, () -> Bool) -> CaptureDetectionCandidate?

        init(_ handler: @escaping (CaptureElementRequest, () -> Bool) -> CaptureDetectionCandidate? = { request, _ in
            CaptureDetectionCandidate(rect: CGRect(x: request.point.x - 5, y: request.point.y - 5,
                                                     width: 20, height: 20),
                                      windowID: request.window.windowID, ownerPID: request.window.ownerPID, kind: .element)
        }) {
            self.handler = handler
        }

        var calls: [CaptureElementRequest] {
            lock.lock()
            defer { lock.unlock() }
            return requests
        }

        var maximumActive: Int {
            lock.lock()
            defer { lock.unlock() }
            return peak
        }

        func resolve(_ request: CaptureElementRequest, shouldContinue: () -> Bool) -> CaptureDetectionCandidate? {
            lock.lock()
            requests.append(request)
            active += 1
            peak = max(peak, active)
            lock.unlock()
            defer {
                lock.lock()
                active -= 1
                lock.unlock()
            }
            return handler(request, shouldContinue)
        }
    }

    private let coordinates = CaptureDetectionCoordinates(primaryHeight: 1_000)
    private let display = CGRect(x: -100, y: 0, width: 1_100, height: 1_000)
    private let window = CaptureDetectionWindow(frame: CGRect(x: -50, y: 50, width: 600, height: 600),
                                                 windowID: 71, ownerPID: 42)
    private let point = CGPoint(x: 100, y: 200)

    private func description(id: Int = 1, pid: Int = 42, layer: Int = 0, alpha: Double = 1,
                             quartz: CGRect = CGRect(x: -200, y: 100, width: 400, height: 300)) -> [String: Any] {
        [kCGWindowNumber as String: id, kCGWindowOwnerPID as String: pid,
         kCGWindowLayer as String: layer, kCGWindowAlpha as String: alpha,
         kCGWindowBounds as String: quartz.dictionaryRepresentation]
    }

    func testFrozenCoordinatesRoundTripNegativeAndUpperDisplays() {
        XCTAssertEqual(coordinates.quartzPoint(fromGlobalAppKit: CGPoint(x: -20, y: 1_200)),
                       CGPoint(x: -20, y: -200))
        let rect = CGRect(x: -800, y: 1_100, width: 500, height: 200)
        XCTAssertEqual(coordinates.quartzRect(fromGlobalAppKit: rect),
                       CGRect(x: -800, y: -300, width: 500, height: 200))
        XCTAssertEqual(coordinates.globalAppKitRect(fromQuartz: coordinates.quartzRect(fromGlobalAppKit: rect)), rect)
    }

    func testInventoryPreservesFrontToBackIncludingFloatingLayersAndNegativeCoordinates() {
        var front = description(id: 9, layer: 8)
        front[kCGWindowName as String] = "Not needed by detection"
        let back = description(id: 4, layer: 0)
        let windows = CaptureDetectionWindow.parse([front, back], excludingPID: 100, coordinates: coordinates)
        XCTAssertEqual(windows.map(\.windowID), [9, 4])
        XCTAssertEqual(windows.map(\.layer), [8, 0])
        XCTAssertEqual(windows.first?.frame, CGRect(x: -200, y: 600, width: 400, height: 300))
    }

    func testInventoryFiltersSelfTransparentInvalidIDsAndBadFramesWithoutSorting() {
        var notOnScreen = description(id: 5)
        notOnScreen[kCGWindowIsOnscreen as String] = false
        var fractionalID = description(id: 6)
        fractionalID[kCGWindowNumber as String] = 6.5
        var missingBounds = description(id: 7)
        missingBounds.removeValue(forKey: kCGWindowBounds as String)
        var boolPID = description(id: 8)
        boolPID[kCGWindowOwnerPID as String] = true
        var malformedBounds = description(id: 10)
        malformedBounds[kCGWindowBounds as String] = ["X": "not a number"]
        let descriptions = [description(id: 1, pid: 99), description(id: 2, alpha: 0),
                            description(id: 0), description(id: 3, pid: -1), notOnScreen, fractionalID,
                            missingBounds, boolPID, malformedBounds,
                            description(id: 11, quartz: CGRect(x: 0, y: 0, width: 0, height: 10)),
                            description(id: 12, quartz: CGRect(x: CGFloat.nan, y: 0, width: 10, height: 10)),
                            description(id: 13, quartz: CGRect(x: 0, y: 0, width: -10, height: 10)),
                            description(id: 14)]
        XCTAssertEqual(CaptureDetectionWindow.parse(descriptions, excludingPID: 99,
                                                    coordinates: coordinates).map(\.windowID), [14])
    }

    private var externalPrimaryDisplays: [CGRect] {
        [CGRect(x: 0, y: 0, width: 2_560, height: 1_440),
         CGRect(x: -1_728, y: 323, width: 1_728, height: 1_117)]
    }

    private func externalPrimaryInventory() -> [CaptureDetectionWindow] {
        let descriptions = [
            description(id: 90, pid: 100, layer: 1_000, quartz: CGRect(x: 0, y: 0, width: 2_560, height: 1_440)),
            description(id: 85, pid: 12, layer: Int(CGWindowLevelForKey(.dockWindow)),
                        quartz: CGRect(x: 0, y: 0, width: 2_560, height: 1_440)),
            description(id: 20, pid: 42, quartz: CGRect(x: 562, y: 275, width: 1_489, height: 994)),
            description(id: 21, pid: 43, quartz: CGRect(x: -1_728, y: 38, width: 1_728, height: 982))
        ]
        return CaptureDetectionWindow.parse(descriptions, excludingPID: 100,
                                             coordinates: CaptureDetectionCoordinates(primaryHeight: 1_440),
                                             displayFrames: externalPrimaryDisplays,
                                             ownerBundleIdentifier: { $0 == 12 ? "com.apple.dock" : "example.app" })
    }

    func testInventoryRejectsLocalizedFullDisplayDockSurfaceBeforeApplicationWindows() {
        for owner in ["Dock", "程序坞", "Dock localized differently"] {
            var surface = description(id: 85, pid: 12, layer: Int(CGWindowLevelForKey(.dockWindow)),
                                      quartz: CGRect(x: 0, y: 0, width: 2_560, height: 1_440))
            surface[kCGWindowOwnerName as String] = owner
            // A name/title and sharing-state heuristic must not be required.
            let windows = CaptureDetectionWindow.parse([surface, description(id: 20)], excludingPID: 100,
                                                         coordinates: CaptureDetectionCoordinates(primaryHeight: 1_440),
                                                         displayFrames: externalPrimaryDisplays,
                                                         ownerBundleIdentifier: { $0 == 12 ? "com.apple.dock" : nil })
            XCTAssertEqual(windows.map(\.windowID), [20], owner)
        }
    }

    func testSystemSurfaceFilterPreservesRealFullscreenAppsFloatingPanelsMenusAndSmallDock() {
        let full = CGRect(x: 0, y: 0, width: 2_560, height: 1_440)
        let dockLayer = Int(CGWindowLevelForKey(.dockWindow))
        let descriptions = [
            description(id: 1, pid: 42, layer: 25, quartz: CGRect(x: 0, y: 0, width: 2_560, height: 24)),
            description(id: 2, pid: 42, layer: 8, quartz: CGRect(x: 500, y: 200, width: 300, height: 200)),
            description(id: 3, pid: 12, layer: dockLayer, quartz: CGRect(x: 500, y: 1_350, width: 900, height: 90)),
            description(id: 4, pid: 42, layer: dockLayer, quartz: full),
            description(id: 5, pid: 42, layer: 0, quartz: full),
            description(id: 6, pid: 12, layer: 8, quartz: full),
            description(id: 7, pid: 99, layer: dockLayer, quartz: full),
            description(id: 8, pid: 12, layer: dockLayer, quartz: full.insetBy(dx: 0, dy: 10))
        ]
        let windows = CaptureDetectionWindow.parse(descriptions, excludingPID: 100,
                                                     coordinates: CaptureDetectionCoordinates(primaryHeight: 1_440),
                                                     displayFrames: externalPrimaryDisplays,
                                                     ownerBundleIdentifier: { $0 == 12 ? "com.apple.dock" : nil })
        XCTAssertEqual(windows.map(\.windowID), Array(1...8).map { CGWindowID($0) })
    }

    @MainActor
    func testExternalPrimaryDisplayFindsApplicationInsteadOfWholeScreenAndKeepsInternalDisplay() {
        let detector = CaptureSelectionDetector(mode: .window, windows: externalPrimaryInventory(),
                                                 coordinates: CaptureDetectionCoordinates(primaryHeight: 1_440))
        XCTAssertEqual(detector.updatePointer(CGPoint(x: 1_000, y: 800), displayFrame: externalPrimaryDisplays[0]),
                       CaptureDetectionCandidate(rect: CGRect(x: 562, y: 171, width: 1_489, height: 994),
                                                  windowID: 20, ownerPID: 42, kind: .window))
        XCTAssertEqual(detector.updatePointer(CGPoint(x: -1_000, y: 800), displayFrame: externalPrimaryDisplays[1]),
                       CaptureDetectionCandidate(rect: CGRect(x: -1_728, y: 420, width: 1_728, height: 982),
                                                  windowID: 21, ownerPID: 43, kind: .window))
        XCTAssertNil(detector.updatePointer(CGPoint(x: 2_500, y: 100), displayFrame: externalPrimaryDisplays[0]),
                     "Empty desktop must not retain an invisible full-display Dock candidate")
        detector.cancel()
    }

    @MainActor
    func testExternalDisplayElementQueryTargetsVisibleApplicationNotDock() async {
        let resolver = Resolver()
        let detector = CaptureSelectionDetector(mode: .element, windows: externalPrimaryInventory(),
                                                 coordinates: CaptureDetectionCoordinates(primaryHeight: 1_440),
                                                 hasAccessibility: { true }, resolver: resolver, debounceInterval: 0)
        let refined = expectation(description: "external application element")
        detector.onCandidateChange = { candidate in
            XCTAssertEqual(candidate?.kind, .element)
            XCTAssertEqual(candidate?.ownerPID, 42)
            XCTAssertEqual(candidate?.windowID, 20)
            refined.fulfill()
        }
        XCTAssertEqual(detector.updatePointer(CGPoint(x: 1_000, y: 800), displayFrame: externalPrimaryDisplays[0])?.windowID, 20)
        await fulfillment(of: [refined], timeout: 1)
        XCTAssertEqual(resolver.calls.first?.window.ownerPID, 42)
        XCTAssertEqual(resolver.calls.first?.coordinates.quartzPoint(fromGlobalAppKit: CGPoint(x: 1_000, y: 800)),
                       CGPoint(x: 1_000, y: 640))
        detector.cancel()
    }

    @MainActor
    func testDockDisplaySurfacesAreFilteredForLeftRightUpperAndLowerDisplayLayouts() {
        let primary = CGRect(x: 0, y: 0, width: 1_600, height: 900)
        let arrangements: [(CGRect, CGRect)] = [
            (CGRect(x: -1_920, y: 120, width: 1_920, height: 1_080),
             CGRect(x: -1_920, y: -300, width: 1_920, height: 1_080)),
            (CGRect(x: 1_600, y: -180, width: 1_920, height: 1_080),
             CGRect(x: 1_600, y: 0, width: 1_920, height: 1_080)),
            (CGRect(x: 100, y: 900, width: 1_440, height: 900),
             CGRect(x: 100, y: -900, width: 1_440, height: 900)),
            (CGRect(x: -200, y: -1_080, width: 1_920, height: 1_080),
             CGRect(x: -200, y: 900, width: 1_920, height: 1_080))
        ]
        let coordinates = CaptureDetectionCoordinates(primaryHeight: 900)
        for (display, quartz) in arrangements {
            let expectedWindow = display.insetBy(dx: 100, dy: 100)
            let windows = CaptureDetectionWindow.parse([
                description(id: 1, pid: 12, layer: Int(CGWindowLevelForKey(.dockWindow)), quartz: quartz),
                description(id: 2, pid: 42, quartz: quartz.insetBy(dx: 100, dy: 100))
            ], excludingPID: 100, coordinates: coordinates, displayFrames: [primary, display],
                ownerBundleIdentifier: { $0 == 12 ? "com.apple.dock" : nil })
            let detector = CaptureSelectionDetector(mode: .window, windows: windows, coordinates: coordinates)
            let candidate = detector.updatePointer(CGPoint(x: display.midX, y: display.midY), displayFrame: display)
            XCTAssertEqual(candidate?.windowID, 2)
            XCTAssertEqual(candidate?.rect, expectedWindow)
            detector.cancel()
        }
    }

    func testDockSurfaceMaySpanDisplaysButUncertainIdentityOrGeometryIsPreserved() {
        let coordinates = CaptureDetectionCoordinates(primaryHeight: 1_440)
        let span = externalPrimaryDisplays.reduce(CGRect.null) { $0.union($1) }
        let descriptions = [description(id: 1, pid: 12, layer: Int(CGWindowLevelForKey(.dockWindow)),
                                        quartz: coordinates.quartzRect(fromGlobalAppKit: span)),
                            description(id: 2, pid: 42)]
        XCTAssertEqual(CaptureDetectionWindow.parse(descriptions, excludingPID: 100, coordinates: coordinates,
                                                     displayFrames: externalPrimaryDisplays,
                                                     ownerBundleIdentifier: { $0 == 12 ? "com.apple.dock" : nil }).map(\.windowID), [2])
        XCTAssertEqual(CaptureDetectionWindow.parse(descriptions, excludingPID: 100, coordinates: coordinates,
                                                     displayFrames: externalPrimaryDisplays).map(\.windowID), [1, 2])
        XCTAssertEqual(CaptureDetectionWindow.parse(descriptions, excludingPID: 100, coordinates: coordinates,
                                                     displayFrames: [.null],
                                                     ownerBundleIdentifier: { _ in "com.apple.dock" }).map(\.windowID), [1, 2])
    }

    @MainActor
    func testNoneAndWindowModesNeverQueryAccessibilityOrResolver() {
        let resolver = Resolver { _, _ in XCTFail("No element query expected"); return nil }
        var accessibilityChecks = 0
        let hasAccessibility = { accessibilityChecks += 1; return true }
        let none = CaptureSelectionDetector(mode: .none, windows: [window], coordinates: coordinates,
                                            hasAccessibility: hasAccessibility, resolver: resolver)
        XCTAssertNil(none.updatePointer(point, displayFrame: display))
        let windowOnly = CaptureSelectionDetector(mode: .window, windows: [window], coordinates: coordinates,
                                                  hasAccessibility: hasAccessibility, resolver: resolver)
        XCTAssertEqual(windowOnly.updatePointer(point, displayFrame: display)?.kind, .window)
        XCTAssertEqual(accessibilityChecks, 0)
        XCTAssertTrue(resolver.calls.isEmpty)
        none.cancel()
        windowOnly.cancel()
    }

    @MainActor
    func testFrontmostFloatingWindowWinsAndIsClippedOnlyToPointerDisplay() {
        let front = CaptureDetectionWindow(frame: CGRect(x: -200, y: 100, width: 600, height: 500),
                                            windowID: 99, ownerPID: 55, layer: 25)
        let detector = CaptureSelectionDetector(mode: .window, windows: [front, window], coordinates: coordinates)
        let rightDisplay = CGRect(x: 0, y: 0, width: 1_000, height: 1_000)
        XCTAssertEqual(detector.updatePointer(point, displayFrame: rightDisplay),
                       CaptureDetectionCandidate(rect: CGRect(x: 0, y: 100, width: 400, height: 500),
                                                  windowID: 99, ownerPID: 55, kind: .window))
        XCTAssertNil(detector.updatePointer(CGPoint(x: -10, y: 200), displayFrame: rightDisplay))
        XCTAssertNil(detector.updatePointer(CGPoint(x: CGFloat.nan, y: 200), displayFrame: rightDisplay))
        detector.cancel()
    }

    @MainActor
    func testNoAccessibilityFallsBackToWindowWithExplanationAndNoPrompt() {
        let resolver = Resolver { _, _ in XCTFail("Missing permission must not start AX work"); return nil }
        let detector = CaptureSelectionDetector(mode: .element, windows: [window], coordinates: coordinates,
                                                hasAccessibility: { false }, resolver: resolver, debounceInterval: 0)
        XCTAssertEqual(detector.updatePointer(point, displayFrame: display)?.kind, .window)
        XCTAssertFalse(detector.statusText.isEmpty)
        XCTAssertTrue(resolver.calls.isEmpty)
        detector.cancel()
    }

    @MainActor
    func testImmediateWindowThenAsynchronousElementAndShortQuantizedCache() async {
        let clock: TimeInterval = 100
        let resolver = Resolver()
        let detector = CaptureSelectionDetector(mode: .element, windows: [window], coordinates: coordinates,
                                                hasAccessibility: { true }, resolver: resolver,
                                                debounceInterval: 0, cacheTTL: 0.25, now: { clock })
        let refined = expectation(description: "element refined")
        detector.onCandidateChange = { candidate in
            XCTAssertEqual(candidate?.kind, .element)
            refined.fulfill()
        }
        XCTAssertEqual(detector.updatePointer(point, displayFrame: display)?.kind, .window)
        await fulfillment(of: [refined], timeout: 1)
        XCTAssertEqual(detector.updatePointer(CGPoint(x: 101, y: 201), displayFrame: display)?.kind, .element)
        XCTAssertEqual(resolver.calls.count, 1)
        // Inside the same large parent rect is insufficient: moving to a different point cell rechecks AX.
        XCTAssertEqual(detector.updatePointer(CGPoint(x: 105, y: 201), displayFrame: display)?.kind, .window)
        detector.invalidate()
        // An invalidation also prevents reusing a still-young cached parent rect.
        XCTAssertEqual(detector.updatePointer(point, displayFrame: display)?.kind, .window)
        detector.cancel()
    }

    @MainActor
    func testCacheExpiresEvenWhilePointerRemainsInsideParent() async {
        var clock: TimeInterval = 10
        let detector = CaptureSelectionDetector(mode: .element, windows: [window], coordinates: coordinates,
                                                hasAccessibility: { true }, resolver: Resolver(),
                                                debounceInterval: 0, cacheTTL: 0.25, now: { clock })
        let refined = expectation(description: "first refinement")
        detector.onCandidateChange = { _ in refined.fulfill() }
        _ = detector.updatePointer(point, displayFrame: display)
        await fulfillment(of: [refined], timeout: 1)
        clock += 0.2
        XCTAssertEqual(detector.updatePointer(point, displayFrame: display)?.kind, .element)
        clock += 0.1
        XCTAssertEqual(detector.updatePointer(point, displayFrame: display)?.kind, .window)
        detector.cancel()
    }

    @MainActor
    func testDebounceCoalescesPointerBurstBeforeAnyWorkStarts() async {
        let resolver = Resolver()
        let detector = CaptureSelectionDetector(mode: .element, windows: [window], coordinates: coordinates,
                                                hasAccessibility: { true }, resolver: resolver, debounceInterval: 0.06)
        let refined = expectation(description: "latest point only")
        detector.onCandidateChange = { _ in refined.fulfill() }
        for x in 100..<200 { _ = detector.updatePointer(CGPoint(x: x, y: 200), displayFrame: display) }
        await fulfillment(of: [refined], timeout: 1)
        XCTAssertEqual(resolver.calls.map(\.point), [CGPoint(x: 199, y: 200)])
        detector.cancel()
    }

    @MainActor
    func testOldWindowCannotOverwriteNewWindowAndQueueHasOnlyLatestPending() async throws {
        let started = expectation(description: "old window started")
        let refined = expectation(description: "new window refined")
        let release = DispatchSemaphore(value: 0)
        let resolver = Resolver { request, _ in
            if request.window.windowID == 71 {
                started.fulfill()
                _ = release.wait(timeout: .now() + 1)
            }
            return CaptureDetectionCandidate(rect: CGRect(x: request.point.x - 2, y: request.point.y - 2,
                                                            width: 10, height: 10),
                                             windowID: request.window.windowID, ownerPID: request.window.ownerPID, kind: .element)
        }
        let second = CaptureDetectionWindow(frame: CGRect(x: 600, y: 50, width: 400, height: 600),
                                             windowID: 72, ownerPID: 43)
        let detector = CaptureSelectionDetector(mode: .element, windows: [window, second], coordinates: coordinates,
                                                hasAccessibility: { true }, resolver: resolver, debounceInterval: 0)
        var published: [CGWindowID] = []
        detector.onCandidateChange = { candidate in
            if let candidate { published.append(candidate.windowID) }
            refined.fulfill()
        }
        _ = detector.updatePointer(point, displayFrame: display)
        await fulfillment(of: [started], timeout: 1)
        // Yield between bursts so requests really reach the pending slot while the first IPC is blocked.
        for x in 610..<650 {
            _ = detector.updatePointer(CGPoint(x: x, y: 200), displayFrame: display)
            try await Task.sleep(nanoseconds: 100_000)
        }
        release.signal()
        await fulfillment(of: [refined], timeout: 1)
        XCTAssertEqual(published, [72])
        XCTAssertEqual(resolver.calls.count, 2)
        XCTAssertEqual(resolver.calls.last?.point, CGPoint(x: 649, y: 200))
        XCTAssertEqual(resolver.maximumActive, 1)
        detector.cancel()
    }

    @MainActor
    func testInvalidateDiscardsLateResultButAllowsSameWindowToRestart() async {
        let started = expectation(description: "first request started")
        let refined = expectation(description: "fresh generation refined")
        let release = DispatchSemaphore(value: 0)
        let resolver = Resolver { request, _ in
            if request.point.x == 100 {
                started.fulfill()
                _ = release.wait(timeout: .now() + 1)
            }
            return CaptureDetectionCandidate(rect: CGRect(x: request.point.x, y: 195, width: 10, height: 10),
                                             windowID: request.window.windowID, ownerPID: request.window.ownerPID, kind: .element)
        }
        let detector = CaptureSelectionDetector(mode: .element, windows: [window], coordinates: coordinates,
                                                hasAccessibility: { true }, resolver: resolver, debounceInterval: 0)
        detector.onCandidateChange = { candidate in
            XCTAssertEqual(candidate?.rect.minX, 110)
            refined.fulfill()
        }
        _ = detector.updatePointer(point, displayFrame: display)
        await fulfillment(of: [started], timeout: 1)
        detector.invalidate()
        _ = detector.updatePointer(CGPoint(x: 110, y: 200), displayFrame: display)
        release.signal()
        await fulfillment(of: [refined], timeout: 1)
        XCTAssertEqual(resolver.calls.count, 2)
        detector.cancel()
    }

    @MainActor
    func testCancelIsTerminalAndNeverPublishesLateNoncooperativeResolver() async throws {
        let started = expectation(description: "request started")
        let release = DispatchSemaphore(value: 0)
        let resolver = Resolver { request, _ in
            started.fulfill()
            _ = release.wait(timeout: .now() + 1)
            return CaptureDetectionCandidate(rect: request.window.frame, windowID: request.window.windowID,
                                             ownerPID: request.window.ownerPID, kind: .element)
        }
        let detector = CaptureSelectionDetector(mode: .element, windows: [window], coordinates: coordinates,
                                                hasAccessibility: { true }, resolver: resolver, debounceInterval: 0)
        detector.onCandidateChange = { _ in XCTFail("Cancelled session must not publish") }
        _ = detector.updatePointer(point, displayFrame: display)
        await fulfillment(of: [started], timeout: 1)
        detector.cancel()
        detector.invalidate()
        XCTAssertNil(detector.updatePointer(point, displayFrame: display))
        release.signal()
        try await Task.sleep(nanoseconds: 40_000_000)
        XCTAssertEqual(resolver.calls.count, 1)
    }

    @MainActor
    func testFallbackForUnavailableWrongOwnerAndLateResolvers() async throws {
        let wrongOwner = Resolver { request, _ in
            CaptureDetectionCandidate(rect: request.window.frame, windowID: 999, ownerPID: 999, kind: .element)
        }
        let unavailable = Resolver { _, _ in nil }
        let slow = Resolver { request, _ in
            Thread.sleep(forTimeInterval: 0.23)
            return CaptureDetectionCandidate(rect: request.window.frame, windowID: request.window.windowID,
                                             ownerPID: request.window.ownerPID, kind: .element)
        }
        for resolver in [wrongOwner, unavailable, slow] {
            let detector = CaptureSelectionDetector(mode: .element, windows: [window], coordinates: coordinates,
                                                    hasAccessibility: { true }, resolver: resolver, debounceInterval: 0)
            detector.onCandidateChange = { _ in XCTFail("Unavailable, wrong-owner, or over-budget result must be ignored") }
            XCTAssertEqual(detector.updatePointer(point, displayFrame: display)?.kind, .window)
            try await Task.sleep(nanoseconds: 270_000_000)
            XCTAssertEqual(detector.updatePointer(point, displayFrame: display)?.kind, .window)
            detector.cancel()
        }
    }

    @MainActor
    func testMouseLeaveAndDisplayChangeDiscardOldPointerStage() async throws {
        let started = expectation(description: "old display started")
        let refined = expectation(description: "new display refined")
        let release = DispatchSemaphore(value: 0)
        let oldDisplay = display
        let resolver = Resolver { request, _ in
            if request.displayFrame == oldDisplay {
                started.fulfill()
                _ = release.wait(timeout: .now() + 1)
            }
            return CaptureDetectionCandidate(rect: request.window.frame, windowID: request.window.windowID,
                                             ownerPID: request.window.ownerPID, kind: .element)
        }
        let detector = CaptureSelectionDetector(mode: .element, windows: [window], coordinates: coordinates,
                                                hasAccessibility: { true }, resolver: resolver, debounceInterval: 0)
        detector.onCandidateChange = { candidate in
            XCTAssertEqual(candidate?.rect.minX, 0)
            refined.fulfill()
        }
        _ = detector.updatePointer(point, displayFrame: display)
        await fulfillment(of: [started], timeout: 1)
        XCTAssertNil(detector.updatePointer(CGPoint(x: -500, y: 200), displayFrame: display))
        let changedDisplay = CGRect(x: 0, y: 0, width: 1_000, height: 1_000)
        _ = detector.updatePointer(point, displayFrame: changedDisplay)
        release.signal()
        await fulfillment(of: [refined], timeout: 1)
        XCTAssertEqual(resolver.maximumActive, 1)
        detector.cancel()
    }
}
