import AppKit
import ApplicationServices

struct CaptureDetectionCandidate: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case window
        case element
    }

    /// Global AppKit coordinates, clipped to the display containing the pointer.
    let rect: CGRect
    let windowID: CGWindowID
    let ownerPID: pid_t
    let kind: Kind
}

/// A session snapshot. Array order, including nonzero window levels, is front to back.
struct CaptureDetectionWindow: Equatable, Sendable {
    /// The original, unclipped global AppKit window bounds.
    let frame: CGRect
    let windowID: CGWindowID
    let ownerPID: pid_t
    let layer: Int

    init(frame: CGRect, windowID: CGWindowID, ownerPID: pid_t, layer: Int = 0) {
        self.frame = frame
        self.windowID = windowID
        self.ownerPID = ownerPID
        self.layer = layer
    }

    static func readOnScreen(excludingPID: pid_t,
                             coordinates: CaptureDetectionCoordinates) -> [CaptureDetectionWindow] {
        guard let descriptions = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return [] }
        // Resolve only potential system surfaces, once per PID for this snapshot.
        // Window owner names are localized (for example, Dock is 程序坞).
        var bundleIdentifiers: [pid_t: String] = [:]
        return parse(descriptions, excludingPID: excludingPID, coordinates: coordinates,
                     displayFrames: coordinates.displayFrames, ownerBundleIdentifier: { pid in
            if let cached = bundleIdentifiers[pid] { return cached }
            let identifier = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? ""
            bundleIdentifiers[pid] = identifier
            return identifier
        })
    }

    /// Kept separate from the CG query so inventory filtering never needs a live desktop in tests.
    static func parse(_ descriptions: [[String: Any]], excludingPID: pid_t,
                      coordinates: CaptureDetectionCoordinates, displayFrames: [CGRect] = [],
                      ownerBundleIdentifier: (pid_t) -> String? = { _ in nil }) -> [CaptureDetectionWindow] {
        guard coordinates.primaryHeight.isFinite else { return [] }
        let dockLayer = Int(CGWindowLevelForKey(.dockWindow))
        return descriptions.compactMap { description in
            guard let rawID = number(description[kCGWindowNumber as String]),
                  rawID > 0, rawID <= Double(CGWindowID.max), rawID.rounded() == rawID,
                  let rawPID = number(description[kCGWindowOwnerPID as String]),
                  rawPID > 0, rawPID <= Double(pid_t.max), rawPID.rounded() == rawPID,
                  pid_t(rawPID) != excludingPID,
                  let alpha = number(description[kCGWindowAlpha as String]), alpha > 0,
                  let rawLayer = number(description[kCGWindowLayer as String]),
                  rawLayer >= Double(Int32.min), rawLayer <= Double(Int32.max),
                  rawLayer.rounded() == rawLayer,
                  let bounds = description[kCGWindowBounds as String] as? [String: Any],
                  let x = number(bounds["X"]), let y = number(bounds["Y"]),
                  let width = number(bounds["Width"]), let height = number(bounds["Height"]) else { return nil }
            // CGRect(dictionaryRepresentation:) can raise an Objective-C exception on malformed
            // values. Validate the four numeric fields before constructing a frame instead.
            let quartzFrame = CGRect(x: x, y: y, width: width, height: height)
            guard CaptureDetectionGeometry.isValid(quartzFrame) else { return nil }
            if let onScreen = description[kCGWindowIsOnscreen as String] as? NSNumber,
               !onScreen.boolValue { return nil }
            let frame = coordinates.globalAppKitRect(fromQuartz: quartzFrame)
            guard CaptureDetectionGeometry.isValid(frame) else { return nil }
            // Dock can publish an opaque, full-display hit surface above normal windows,
            // even with excludeDesktopElements. It is not the visible Dock's content.
            // Do not discard real fullscreen apps, small Dock windows, or floating UI.
            if Int(rawLayer) == dockLayer,
               displayFrames.contains(where: { CaptureDetectionGeometry.coversDisplay(frame, display: $0) }),
               ownerBundleIdentifier(pid_t(rawPID)) == "com.apple.dock" { return nil }
            // Deliberately do not inspect window titles or discard floating panels by layer.
            return CaptureDetectionWindow(frame: frame, windowID: CGWindowID(rawID),
                                          ownerPID: pid_t(rawPID), layer: Int(rawLayer))
        }
    }

    private static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else { return nil }
        return number.doubleValue
    }
}

/// Freeze the primary display height with the window/screen snapshot; never consult NSScreen here.
struct CaptureDetectionCoordinates: Equatable, Sendable {
    let primaryHeight: CGFloat
    let displayFrames: [CGRect]

    init(primaryHeight: CGFloat, displayFrames: [CGRect] = []) {
        self.primaryHeight = primaryHeight
        self.displayFrames = displayFrames
    }

    func quartzPoint(fromGlobalAppKit point: CGPoint) -> CGPoint {
        CGPoint(x: point.x, y: primaryHeight - point.y)
    }

    func globalAppKitRect(fromQuartz rect: CGRect) -> CGRect {
        CGRect(x: rect.origin.x, y: primaryHeight - rect.origin.y - rect.size.height,
               width: rect.size.width, height: rect.size.height)
    }

    func quartzRect(fromGlobalAppKit rect: CGRect) -> CGRect {
        globalAppKitRect(fromQuartz: rect)
    }
}

// Shared only by the detection/resolution implementation, not the existing capture geometry.
enum CaptureDetectionGeometry {
    static func isValid(_ rect: CGRect) -> Bool {
        rect.origin.x.isFinite && rect.origin.y.isFinite &&
            rect.size.width.isFinite && rect.size.height.isFinite &&
            rect.size.width > 0 && rect.size.height > 0 &&
            rect.maxX.isFinite && rect.maxY.isFinite
    }

    static func contains(_ point: CGPoint, in rect: CGRect) -> Bool {
        point.x.isFinite && point.y.isFinite && isValid(rect) && rect.contains(point)
    }

    static func coversDisplay(_ rect: CGRect, display: CGRect) -> Bool {
        // Global logical points, not backing pixels. Allow only edge-rounding error.
        let tolerance: CGFloat = 1
        return isValid(rect) && isValid(display) &&
            rect.minX <= display.minX + tolerance && rect.minY <= display.minY + tolerance &&
            rect.maxX >= display.maxX - tolerance && rect.maxY >= display.maxY - tolerance
    }
}

@MainActor
final class CaptureSelectionDetector {
    var onCandidateChange: ((CaptureDetectionCandidate?) -> Void)?
    private(set) var statusText = ""

    private let mode: CaptureDetectionMode
    private let windows: [CaptureDetectionWindow]
    private let coordinates: CaptureDetectionCoordinates
    private let hasAccessibility: () -> Bool
    private let resolver: CaptureElementResolving
    private let debounceInterval: TimeInterval
    private let cacheTTL: TimeInterval
    private let now: () -> TimeInterval
    private let worker = DispatchQueue(label: "com.iclipboard.capture.element-detection", qos: .userInitiated)

    private var generation: UInt64 = 0
    private var pointerStage: UInt64 = 0
    private var isCancelled = false
    private var current: Context?
    private var debounce: DispatchWorkItem?
    private var inFlight: Flight?
    private var pending: Context?
    private var cache: CacheEntry?

    init(mode: CaptureDetectionMode, windows: [CaptureDetectionWindow],
         coordinates: CaptureDetectionCoordinates,
         hasAccessibility: @escaping () -> Bool = { AXIsProcessTrusted() },
         resolver: CaptureElementResolving = SystemCaptureElementResolver(),
         debounceInterval: TimeInterval = 0.06, cacheTTL: TimeInterval = 0.25,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.mode = mode
        self.windows = windows
        self.coordinates = coordinates
        self.hasAccessibility = hasAccessibility
        self.resolver = resolver
        self.debounceInterval = max(0, debounceInterval)
        self.cacheTTL = max(0, cacheTTL)
        self.now = now
    }

    deinit {
        debounce?.cancel()
        inFlight?.cancellation.cancel()
    }

    /// Synchronous window/cache result; only a later element refinement uses the callback.
    func updatePointer(_ point: CGPoint, displayFrame: CGRect) -> CaptureDetectionCandidate? {
        guard !isCancelled, mode != .none else { return nil }
        guard coordinates.primaryHeight.isFinite,
              CaptureDetectionGeometry.contains(point, in: displayFrame),
              let window = windows.first(where: {
                  $0.ownerPID > 0 && $0.windowID != kCGNullWindowID &&
                      CaptureDetectionGeometry.contains(point, in: $0.frame)
              }) else {
            clearPointer()
            return nil
        }
        let clipped = window.frame.intersection(displayFrame)
        guard CaptureDetectionGeometry.contains(point, in: clipped) else {
            clearPointer()
            return nil
        }
        let fallback = CaptureDetectionCandidate(rect: clipped, windowID: window.windowID,
                                                 ownerPID: window.ownerPID, kind: .window)
        guard mode == .element else { return fallback }

        if current?.request.window != window || current?.request.point != point ||
            current?.request.displayFrame != displayFrame {
            clearPointer()
            current = Context(generation: generation, stage: pointerStage,
                              request: CaptureElementRequest(window: window, point: point,
                                                             displayFrame: displayFrame,
                                                             coordinates: coordinates))
        }
        guard hasAccessibility() else {
            statusText = "元素检测需要辅助功能权限，当前使用窗口检测。"
            debounce?.cancel()
            debounce = nil
            pending = nil
            inFlight?.cancellation.cancel()
            cache = nil
            return fallback
        }
        statusText = ""
        guard let context = current else { return fallback }
        let key = CacheKey(request: context.request)
        if let cache, cache.key == key, now() - cache.createdAt >= 0,
           now() - cache.createdAt < cacheTTL,
           CaptureDetectionGeometry.contains(point, in: cache.candidate.rect) {
            return cache.candidate
        }
        if debounce == nil && pending?.stage != context.stage &&
            !(inFlight?.context.stage == context.stage && inFlight?.cancellation.isValid == true) {
            schedule(context)
        }
        return fallback
    }

    /// Owners call this for drag/ready/mouse-leave/reselection. An existing IPC may finish, but is discarded.
    func invalidate() {
        generation &+= 1
        clearPointer()
        cache = nil
    }

    /// Terminal for a session; unlike invalidate(), subsequent pointer updates cannot restart it.
    func cancel() {
        invalidate()
        isCancelled = true
        onCandidateChange = nil
    }

    private func clearPointer() {
        pointerStage &+= 1
        current = nil
        debounce?.cancel()
        debounce = nil
        pending = nil
        inFlight?.cancellation.cancel()
    }

    private func schedule(_ context: Context) {
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.isCurrent(context) else { return }
            self.debounce = nil
            // The previous C call is not interruptible. Keep just the newest debounced request.
            if self.inFlight != nil {
                self.pending = context
            } else {
                self.start(context)
            }
        }
        debounce = item
        DispatchQueue.main.asyncAfter(deadline: .now() + debounceInterval, execute: item)
    }

    private func start(_ context: Context) {
        guard isCurrent(context), hasAccessibility() else { return }
        let cancellation = CaptureDetectionCancellation()
        inFlight = Flight(context: context, cancellation: cancellation)
        let resolver = self.resolver
        worker.async { [weak self] in
            // Bound all real AX work, and discard an injected resolver's late result as well.
            let deadline = ProcessInfo.processInfo.systemUptime + 0.2
            let shouldContinue = {
                cancellation.isValid && ProcessInfo.processInfo.systemUptime < deadline
            }
            let result = shouldContinue() ? resolver.resolve(context.request, shouldContinue: shouldContinue) : nil
            let timelyResult = shouldContinue() ? result : nil
            DispatchQueue.main.async { [weak self] in
                self?.complete(context, cancellation: cancellation, result: timelyResult)
            }
        }
    }

    private func complete(_ context: Context, cancellation: CaptureDetectionCancellation,
                          result: CaptureDetectionCandidate?) {
        guard inFlight?.cancellation === cancellation else { return }
        inFlight = nil
        if isCurrent(context), cancellation.isValid, hasAccessibility(),
           let result, result.kind == .element,
           result.windowID == context.request.window.windowID,
           result.ownerPID == context.request.window.ownerPID,
           CaptureDetectionGeometry.isValid(result.rect) {
            let clipped = result.rect.intersection(context.request.window.frame)
                .intersection(context.request.displayFrame)
            if CaptureDetectionGeometry.contains(context.request.point, in: clipped) {
                let candidate = CaptureDetectionCandidate(rect: clipped, windowID: result.windowID,
                                                          ownerPID: result.ownerPID, kind: .element)
                cache = CacheEntry(key: CacheKey(request: context.request), candidate: candidate, createdAt: now())
                onCandidateChange?(candidate)
            }
        }
        // A callback may invalidate/cancel this detector. Recheck after invoking it.
        let next = pending
        pending = nil
        if let next, isCurrent(next), hasAccessibility() { start(next) }
    }

    private func isCurrent(_ context: Context) -> Bool {
        !isCancelled && context.generation == generation && context.stage == current?.stage &&
            context.request == current?.request
    }

    private struct Context {
        let generation: UInt64
        let stage: UInt64
        let request: CaptureElementRequest
    }

    private struct Flight {
        let context: Context
        let cancellation: CaptureDetectionCancellation
    }

    private struct CacheKey: Equatable {
        let window: CaptureDetectionWindow
        let display: CGRect
        let point: CGPoint

        init(request: CaptureElementRequest) {
            window = request.window
            display = request.displayFrame
            // No integer conversion: even hostile finite coordinates cannot overflow an Int.
            point = CGPoint(x: floor(request.point.x / 4), y: floor(request.point.y / 4))
        }
    }

    private struct CacheEntry {
        let key: CacheKey
        let candidate: CaptureDetectionCandidate
        let createdAt: TimeInterval
    }
}

private final class CaptureDetectionCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isValid: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}
