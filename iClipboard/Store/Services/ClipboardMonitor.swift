import AppKit

final class ClipboardMonitor {
    private var timer: Timer?
    private var lastChangeCount: Int
    private var ignoredChangeCount: Int?
    private let onChange: () -> Void

    init(interval: TimeInterval = 0.8, onChange: @escaping () -> Void) {
        self.onChange = onChange
        let pasteboard = NSPasteboard.general
        lastChangeCount = pasteboard.changeCount

        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.checkPasteboard() }
        }

        if let timer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    @MainActor
    private func checkPasteboard() {
        let pasteboard = NSPasteboard.general
        let changeCount = pasteboard.changeCount
        guard changeCount != lastChangeCount,
              !SelectionCopyFallback.shared.shouldIgnoreClipboardChange(changeCount) else { return }
        lastChangeCount = changeCount

        if let ignored = ignoredChangeCount, ignored == changeCount {
            ignoredChangeCount = nil
            return
        }
        ignoredChangeCount = nil
        onChange()
    }

    func ignoreNextChangeSnapshot() {
        ignoredChangeCount = NSPasteboard.general.changeCount
        lastChangeCount = ignoredChangeCount ?? lastChangeCount
    }

    deinit {
        timer?.invalidate()
    }
}
