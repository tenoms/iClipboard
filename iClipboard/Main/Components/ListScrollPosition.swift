import AppKit
import SwiftUI

/// Only the offset survives a hidden history list, never its AppKit views.
final class ListScrollPosition {
    var origin: NSPoint?
}

/// macOS 13 has no SwiftUI scrollPosition binding. Keep this bridge local to List.
struct ListScrollPositionReader: NSViewRepresentable {
    let position: ListScrollPosition

    func makeCoordinator() -> Coordinator { Coordinator(position: position) }
    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.connect(from: nsView)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.disconnect()
    }

    final class Coordinator {
        private let position: ListScrollPosition
        private weak var scrollView: NSScrollView?
        private var observer: NSObjectProtocol?
        private var generation = 0

        init(position: ListScrollPosition) { self.position = position }

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }

        func connect(from probe: NSView) {
            generation += 1
            resolve(from: probe, generation: generation, attempts: 5)
        }

        private func resolve(from probe: NSView, generation: Int, attempts: Int) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { [weak self, weak probe] in
                guard let self, let probe, self.generation == generation else { return }
                if let target = Self.findTableScrollView(from: probe),
                   (target.documentView?.frame.height ?? 0) > 0 {
                    self.attach(to: target)
                } else if attempts > 1 {
                    self.resolve(from: probe, generation: generation, attempts: attempts - 1)
                }
            }
        }

        private static func findTableScrollView(from probe: NSView) -> NSScrollView? {
            func find(in view: NSView) -> NSScrollView? {
                if let scroll = view as? NSScrollView, scroll.documentView is NSTableView {
                    return scroll
                }
                for child in view.subviews {
                    if let scroll = find(in: child) { return scroll }
                }
                return nil
            }
            var ancestor = probe.superview
            while let view = ancestor {
                if let scroll = find(in: view) { return scroll }
                ancestor = view.superview
            }
            return nil
        }

        func attach(to target: NSScrollView) {
            guard scrollView !== target else { return }
            disconnect()
            scrollView = target
            target.layoutSubtreeIfNeeded()
            if let origin = position.origin {
                var bounds = target.contentView.bounds
                bounds.origin = origin
                target.contentView.scroll(to: target.contentView.constrainBoundsRect(bounds).origin)
                target.reflectScrolledClipView(target.contentView)
            }
            target.contentView.postsBoundsChangedNotifications = true
            observer = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: target.contentView, queue: .main
            ) { [weak self] _ in
                guard let self, let scrollView = self.scrollView else { return }
                self.position.origin = scrollView.contentView.bounds.origin
            }
        }

        func disconnect() {
            generation += 1
            if let scrollView { position.origin = scrollView.contentView.bounds.origin }
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            scrollView = nil
        }
    }
}
