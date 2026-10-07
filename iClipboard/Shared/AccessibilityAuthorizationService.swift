import ApplicationServices
import Combine
import Foundation
@MainActor
final class AccessibilityAuthorizationService: ObservableObject {
    static let shared = AccessibilityAuthorizationService()

    @Published private(set) var isTrusted: Bool

    private var delayedRefreshWorkItem: DispatchWorkItem?

    private init() {
        isTrusted = AXIsProcessTrusted()
    }

    func refresh() {
        isTrusted = AXIsProcessTrusted()
    }

    func requestAccess() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        isTrusted = AXIsProcessTrustedWithOptions(options)

        delayedRefreshWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.refresh()
        }
        delayedRefreshWorkItem = item
        DispatchQueue.main.asyncAfter(
            deadline: .now() + 1,
            execute: item
        )
    }
}
