import AppKit
import SwiftUI
import XCTest
@testable import iClipboard

@MainActor
final class PinnedImageTests: XCTestCase {
    func testMultipleImagesCloseIndependentlyAndCloseAllReleasesContent() throws {
        let manager = PinnedImageManager()
        defer { manager.closeAll() }
        let first = try makeImage()
        let second = try makeImage(width: 60, height: 90)
        manager.open(first)
        manager.open(second)
        XCTAssertEqual(manager.count, 2)
        let firstPanel = try panel(for: first)
        let secondPanel = try panel(for: second)
        XCTAssertTrue(firstPanel.isVisible)
        XCTAssertTrue(secondPanel.isVisible)

        firstPanel.close()
        XCTAssertEqual(manager.count, 1)
        XCTAssertFalse(firstPanel.isVisible)
        XCTAssertNil(firstPanel.contentView)
        XCTAssertNil(firstPanel.delegate)
        XCTAssertTrue(secondPanel.isVisible)
        manager.closeAll()
        XCTAssertEqual(manager.count, 0)
        XCTAssertFalse(secondPanel.isVisible)
        XCTAssertNil(secondPanel.contentView)
        XCTAssertNil(secondPanel.onCloseRequested)
        manager.closeAll()
        XCTAssertEqual(manager.count, 0)
    }

    func testEscapeAndCancelOperationDoNotClosePins() throws {
        let manager = PinnedImageManager()
        defer { manager.closeAll() }
        let first = try makeImage()
        let second = try makeImage()
        manager.open(first)
        manager.open(second)
        let firstPanel = try panel(for: first)
        let secondPanel = try panel(for: second)
        secondPanel.keyDown(with: try keyEvent("\u{1b}", keyCode: 53, panel: secondPanel))
        secondPanel.cancelOperation(nil)
        XCTAssertEqual(manager.count, 2)
        XCTAssertTrue(firstPanel.isVisible)
        XCTAssertTrue(secondPanel.isVisible)
        XCTAssertNotNil(secondPanel.contentView)
    }

    func testCopyImageIgnoresCapsLockAndOtherNonShortcutFlags() throws {
        let panel = PinnedImagePanel(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        var commands: [String] = []
        panel.onCommand = { commands.append($0) }
        for flags: NSEvent.ModifierFlags in [[.command, .capsLock], [.command, .function, .numericPad]] {
            XCTAssertTrue(panel.performKeyEquivalent(with: try keyEvent("c", panel: panel, modifiers: flags)))
        }
        XCTAssertEqual(commands, ["c", "c"])
        XCTAssertFalse(panel.performKeyEquivalent(with: try keyEvent("c", panel: panel, modifiers: [.command, .shift, .capsLock])))
        XCTAssertEqual(commands.count, 2, "Real shortcut modifiers must still be respected")
    }

    func testCommandWDoesNotClosePinsAndCloseMenuHasNoBuiltInShortcut() throws {
        let manager = PinnedImageManager()
        defer { manager.closeAll() }
        let first = try makeImage()
        let second = try makeImage()
        manager.open(first)
        manager.open(second)
        let firstPanel = try panel(for: first)
        let secondPanel = try panel(for: second)
        for modifiers: NSEvent.ModifierFlags in [.command, [.command, .shift]] {
            XCTAssertFalse(firstPanel.performKeyEquivalent(with:
                try keyEvent("w", panel: firstPanel, modifiers: modifiers)))
        }
        firstPanel.onCommand?("w")
        XCTAssertFalse(firstPanel.performKeyEquivalent(with:
            try keyEvent("r", panel: firstPanel, modifiers: .command)))
        XCTAssertEqual(manager.count, 2)
        XCTAssertTrue(firstPanel.isVisible)
        XCTAssertTrue(secondPanel.isVisible)
        let content = try XCTUnwrap(firstPanel.contentView)
        let button = try XCTUnwrap(descendant(of: content, as: PinnedImageActionMenuButton.self))
        let menu = try XCTUnwrap(button.menu)
        let closeIndex = try XCTUnwrap(menu.items.firstIndex { $0.title == "关闭此贴图" })
        XCTAssertEqual(menu.items[closeIndex].keyEquivalent, "")
        XCTAssertFalse(menu.items.contains { $0.keyEquivalent == "w" || $0.keyEquivalent == "r" })
        XCTAssertFalse(menu.items.contains { $0.title.contains("识别") || $0.title.contains("OCR") })
        XCTAssertFalse(button.toolTip?.contains("识别") ?? true)
        menu.performActionForItem(at: closeIndex)
        XCTAssertEqual(manager.count, 1, "Clicking the close menu item must still close its own pin")
        XCTAssertFalse(firstPanel.isVisible)
        XCTAssertTrue(secondPanel.isVisible)
        manager.closeCurrent(mouseLocation: CGPoint(x: -100_000, y: -100_000), keyWindow: secondPanel)
        XCTAssertEqual(manager.count, 0, "The configurable global close route must remain available")
    }

    func testCloseCurrentHoverWinsOverKeyAndRecentWithoutChangingFocus() throws {
        let manager = PinnedImageManager()
        defer { manager.closeAll() }
        let images = try (0..<3).map { _ in try makeImage() }
        for image in images { manager.open(image) }
        let pins = try images.map { try panel(for: $0) }
        for (index, pin) in pins.enumerated() {
            pin.setFrame(CGRect(x: 20 + index * 300, y: 100, width: 280, height: 120), display: true)
        }
        pins[1].makeKey()
        let wasActive = NSApp.isActive
        let firstResponder = pins[1].firstResponder
        manager.closeCurrent(mouseLocation: CGPoint(x: pins[0].frame.midX, y: pins[0].frame.midY))
        XCTAssertEqual(manager.count, 2)
        XCTAssertFalse(pins[0].isVisible)
        XCTAssertNil(pins[0].contentView)
        XCTAssertTrue(pins[1].isVisible)
        XCTAssertTrue(pins[2].isVisible)
        XCTAssertTrue(pins[1].isKeyWindow)
        XCTAssertTrue(pins[1].firstResponder === firstResponder)
        XCTAssertEqual(NSApp.isActive, wasActive)
    }

    func testCloseCurrentUsesKeyPinBeforeRecentWhenPointerIsElsewhere() throws {
        let manager = PinnedImageManager()
        defer { manager.closeAll() }
        let first = try makeImage()
        let recent = try makeImage()
        manager.open(first)
        manager.open(recent)
        let firstPanel = try panel(for: first)
        let recentPanel = try panel(for: recent)
        firstPanel.makeKey()
        XCTAssertTrue(firstPanel.isKeyWindow)
        manager.closeCurrent(mouseLocation: CGPoint(x: -100_000, y: -100_000))
        XCTAssertEqual(manager.count, 1)
        XCTAssertNil(firstPanel.contentView)
        XCTAssertTrue(recentPanel.isVisible)
    }

    func testCloseCurrentUsesActualFrontOrderForOverlappingPins() throws {
        for differentLevels in [false, true] {
            let manager = PinnedImageManager()
            defer { manager.closeAll() }
            let older = try makeImage()
            let newer = try makeImage()
            manager.open(older)
            manager.open(newer)
            let olderPanel = try panel(for: older)
            let newerPanel = try panel(for: newer)
            newerPanel.setFrame(olderPanel.frame, display: true)
            if differentLevels { olderPanel.onCommand?("t") }
            olderPanel.orderFrontRegardless()
            // At equal levels, this reverses creation/presentation order. At
            // different levels the floating pin stays above the normal pin.
            let front = differentLevels ? newerPanel : olderPanel
            let back = differentLevels ? olderPanel : newerPanel
            manager.closeCurrent(mouseLocation: CGPoint(x: front.frame.midX, y: front.frame.midY),
                                 keyWindow: back)
            XCTAssertEqual(manager.count, 1)
            XCTAssertFalse(front.isVisible)
            XCTAssertNil(front.contentView)
            XCTAssertTrue(back.isVisible)
            manager.closeCurrent(mouseLocation: CGPoint(x: back.frame.midX, y: back.frame.midY),
                                 keyWindow: front)
            XCTAssertEqual(manager.count, 0, "Closed overlap candidates must not remain selectable")
        }
    }

    func testCloseCurrentRecentSkipsHiddenAndClosedPinsAndUnrelatedKeyWindow() throws {
        let manager = PinnedImageManager()
        defer { manager.closeAll() }
        let images = try (0..<4).map { _ in try makeImage() }
        for image in images { manager.open(image) }
        let pins = try images.map { try panel(for: $0) }
        pins[3].close()
        pins[2].orderOut(nil)
        let other = NSPanel(contentRect: .zero, styleMask: .nonactivatingPanel,
                            backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        defer { other.close() }
        let outside = CGPoint(x: -100_000, y: -100_000)
        manager.closeCurrent(mouseLocation: outside, keyWindow: other)
        XCTAssertEqual(manager.count, 2)
        XCTAssertNil(pins[1].contentView)
        XCTAssertTrue(pins[0].isVisible)
        XCTAssertNotNil(pins[2].contentView)
        XCTAssertFalse(other.isKeyWindow, "The global close command must not make any window key")
        manager.closeCurrent(mouseLocation: outside, keyWindow: other)
        XCTAssertEqual(manager.count, 1)
        XCTAssertNil(pins[0].contentView)
        manager.closeCurrent(mouseLocation: outside, keyWindow: pins[2])
        XCTAssertEqual(manager.count, 1, "A hidden key-window candidate must not be closed")
        manager.toggleVisibility()
        manager.closeCurrent(mouseLocation: outside, keyWindow: other)
        XCTAssertEqual(manager.count, 0)
        XCTAssertNil(pins[2].contentView)
        manager.closeAll()
        let fresh = try makeImage()
        manager.open(fresh)
        let freshPanel = try panel(for: fresh)
        manager.closeCurrent(mouseLocation: outside, keyWindow: other)
        XCTAssertEqual(manager.count, 0)
        XCTAssertNil(freshPanel.contentView)
    }

    func testCloseCurrentWithNoVisiblePinsIsNoOpAndDoesNotRevealThem() throws {
        let manager = PinnedImageManager()
        defer { manager.closeAll() }
        manager.closeCurrent()
        let image = try makeImage()
        manager.open(image)
        let pin = try panel(for: image)
        let point = CGPoint(x: pin.frame.midX, y: pin.frame.midY)
        manager.toggleVisibility()
        manager.closeCurrent(mouseLocation: point, keyWindow: pin)
        XCTAssertEqual(manager.count, 1)
        XCTAssertFalse(pin.isVisible)
        XCTAssertNotNil(pin.contentView)
        manager.toggleVisibility()
        XCTAssertTrue(pin.isVisible)
    }

    func testCloseCurrentDuringNestedCaptureDoesNotCloseOrReviveAnyPin() throws {
        let manager = PinnedImageManager()
        defer { manager.closeAll() }
        let image = try makeImage()
        manager.open(image)
        let pin = try panel(for: image)
        let point = CGPoint(x: pin.frame.midX, y: pin.frame.midY)
        let outer = manager.suspendPresentation()
        let inner = manager.suspendPresentation()
        let pending = try makeImage()
        manager.open(pending)
        let pendingPanel = try panel(for: pending)
        manager.closeCurrent(mouseLocation: point, keyWindow: pin)
        XCTAssertEqual(manager.count, 2)
        XCTAssertFalse(pin.isVisible)
        XCTAssertFalse(pendingPanel.isVisible)
        // Even if some other AppKit operation orders a pin in, suspension wins.
        pin.orderFrontRegardless()
        manager.closeCurrent(mouseLocation: point, keyWindow: pin)
        XCTAssertEqual(manager.count, 2)
        XCTAssertTrue(pin.isVisible)
        pin.orderOut(nil)
        inner()
        manager.closeCurrent(mouseLocation: point, keyWindow: pin)
        XCTAssertFalse(pin.isVisible)
        XCTAssertEqual(manager.count, 2)
        outer()
        XCTAssertTrue(pin.isVisible)
        XCTAssertFalse(pendingPanel.isVisible)
        manager.closeCurrent(mouseLocation: point, keyWindow: pin)
        XCTAssertEqual(manager.count, 1)
        XCTAssertNil(pin.contentView)
        outer()
        XCTAssertFalse(pin.isVisible)
        XCTAssertFalse(pendingPanel.isVisible)
    }

    func testCloseCurrentTearsDownPendingToolbarHideWithoutTouchingOtherPins() async throws {
        let manager = PinnedImageManager()
        defer { manager.closeAll() }
        let other = try makeImage()
        manager.open(other)
        let otherPanel = try panel(for: other)
        weak var weakImage: CGImage?
        let (pin, container) = try autoreleasepool {
            let image = try makeImage()
            weakImage = image.cgImage
            manager.open(image)
            let pin = try panel(for: image)
            moveAwayFromPointer(pin)
            let container = try XCTUnwrap(pin.contentView as? PinnedImageContainer)
            container.mouseEntered(with: try hoverEvent(.mouseEntered, panel: pin))
            container.mouseExited(with: try hoverEvent(.mouseExited, panel: pin))
            return (pin, container)
        }
        manager.closeCurrent(mouseLocation: CGPoint(x: -100_000, y: -100_000), keyWindow: pin)
        XCTAssertEqual(manager.count, 1)
        XCTAssertTrue(otherPanel.isVisible)
        XCTAssertFalse(pin.isVisible)
        XCTAssertNil(pin.contentView)
        XCTAssertNil(pin.delegate)
        XCTAssertNil(pin.onCloseRequested)
        XCTAssertNil(pin.onFirstResponderChanged)
        XCTAssertNil(container.onPointerChanged)
        XCTAssertTrue(container.trackingAreas.isEmpty)
        let deadline = Date().addingTimeInterval(2)
        while autoreleasepool(invoking: { weakImage != nil }), Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try await Task.sleep(nanoseconds: 650_000_000)
        XCTAssertNil(weakImage)
        XCTAssertFalse(pin.isVisible)
        XCTAssertNil(pin.contentView)
        XCTAssertTrue(otherPanel.isVisible)
        XCTAssertEqual(manager.count, 1)
    }

    func testCloseCurrentAfterRestoreSkipsClosedRestorationCandidate() throws {
        let manager = PinnedImageManager()
        defer { manager.closeAll() }
        let survivor = try makeImage()
        let closed = try makeImage()
        manager.open(survivor)
        manager.open(closed)
        let survivorPanel = try panel(for: survivor)
        let closedPanel = try panel(for: closed)
        let resume = manager.suspendPresentation()
        closedPanel.close()
        manager.closeCurrent(mouseLocation: .zero, keyWindow: closedPanel)
        XCTAssertEqual(manager.count, 1)
        resume()
        XCTAssertTrue(survivorPanel.isVisible)
        XCTAssertFalse(closedPanel.isVisible)
        manager.closeCurrent(mouseLocation: CGPoint(x: -100_000, y: -100_000), keyWindow: closedPanel)
        XCTAssertEqual(manager.count, 0)
        XCTAssertNil(survivorPanel.contentView)
        resume()
        XCTAssertFalse(survivorPanel.isVisible)
    }

    func testSuspendRestoresOnlyPreviouslyVisibleSurvivorsAndIsIdempotent() throws {
        let manager = PinnedImageManager()
        defer { manager.closeAll() }
        let survivor = try makeImage()
        let closed = try makeImage()
        let hidden = try makeImage()
        manager.open(survivor)
        manager.open(closed)
        manager.open(hidden)
        let survivorPanel = try panel(for: survivor)
        let closedPanel = try panel(for: closed)
        let hiddenPanel = try panel(for: hidden)
        hiddenPanel.orderOut(nil)
        let resume = manager.suspendPresentation()
        XCTAssertFalse(survivorPanel.isVisible)
        XCTAssertFalse(closedPanel.isVisible)
        closedPanel.close()
        let newImage = try makeImage()
        manager.open(newImage)
        let newPanel = try panel(for: newImage)
        XCTAssertFalse(newPanel.isVisible)
        manager.toggleVisibility()
        XCTAssertFalse(survivorPanel.isVisible)
        XCTAssertFalse(newPanel.isVisible)

        resume()
        XCTAssertEqual(manager.count, 3)
        XCTAssertTrue(survivorPanel.isVisible)
        XCTAssertFalse(closedPanel.isVisible)
        XCTAssertFalse(hiddenPanel.isVisible)
        XCTAssertFalse(newPanel.isVisible)
        survivorPanel.orderOut(nil)
        resume()
        XCTAssertFalse(survivorPanel.isVisible, "A duplicate resume must not reorder windows")
    }

    func testCloseAllDuringCaptureDoesNotReviveClosedOrNewWindows() throws {
        let manager = PinnedImageManager()
        defer { manager.closeAll() }
        let image = try makeImage()
        manager.open(image)
        let oldPanel = try panel(for: image)
        let resume = manager.suspendPresentation()
        manager.closeAll()
        let nextImage = try makeImage()
        manager.open(nextImage)
        let nextPanel = try panel(for: nextImage)
        XCTAssertFalse(nextPanel.isVisible)
        resume()
        XCTAssertEqual(manager.count, 1)
        XCTAssertFalse(oldPanel.isVisible)
        XCTAssertNil(oldPanel.contentView)
        XCTAssertFalse(nextPanel.isVisible)
        manager.toggleVisibility()
        XCTAssertTrue(nextPanel.isVisible)
    }

    func testNestedSuspensionsRestoreOnlyAfterEveryCaptureInEitherOrder() throws {
        for finishOuterFirst in [true, false] {
            let manager = PinnedImageManager()
            let image = try makeImage()
            manager.open(image)
            let pin = try panel(for: image)
            let outer = manager.suspendPresentation()
            let inner = manager.suspendPresentation()
            let first = finishOuterFirst ? outer : inner
            let last = finishOuterFirst ? inner : outer
            first()
            first()
            XCTAssertFalse(pin.isVisible)
            last()
            XCTAssertTrue(pin.isVisible)
            manager.closeAll()
        }
    }

    func testToggleVisibilityPreservesWindowsAndAllowsNewPins() throws {
        let manager = PinnedImageManager()
        defer { manager.closeAll() }
        let first = try makeImage()
        manager.open(first)
        let firstPanel = try panel(for: first)
        manager.toggleVisibility()
        XCTAssertFalse(firstPanel.isVisible)
        XCTAssertEqual(manager.count, 1)
        let second = try makeImage()
        manager.open(second)
        let secondPanel = try panel(for: second)
        XCTAssertTrue(secondPanel.isVisible)
        XCTAssertFalse(firstPanel.isVisible)
        manager.toggleVisibility()
        XCTAssertFalse(secondPanel.isVisible)
        manager.toggleVisibility()
        XCTAssertTrue(firstPanel.isVisible)
        XCTAssertTrue(secondPanel.isVisible)
    }

    func testCallbacksReceiveEachWindowsOwnImage() throws {
        let manager = PinnedImageManager()
        defer { manager.closeAll() }
        let first = try makeImage()
        let second = try makeImage(width: 25, height: 100, isOriginal: false)
        var copies: [CGImage] = []
        var saves: [CGImage] = []
        var edits: [CGImage] = []
        manager.onCopy = { copies.append($0.cgImage) }
        manager.onSave = { saves.append($0.cgImage) }
        manager.onEdit = { edits.append($0.cgImage) }
        manager.open(first)
        manager.open(second)
        let firstPanel = try panel(for: first)
        let secondPanel = try panel(for: second)
        for (key, pin) in [("c", firstPanel), ("c", secondPanel), ("s", secondPanel),
                           ("e", firstPanel), ("e", secondPanel)] {
            XCTAssertTrue(pin.performKeyEquivalent(with: try keyEvent(key, panel: pin, modifiers: .command)))
        }
        XCTAssertEqual(copies.count, 2)
        XCTAssertTrue(copies[0] === first.cgImage)
        XCTAssertTrue(copies[1] === second.cgImage)
        XCTAssertTrue(try XCTUnwrap(saves.first) === second.cgImage)
        XCTAssertTrue(try XCTUnwrap(edits.first) === first.cgImage)
        XCTAssertEqual(edits.count, 2)
        XCTAssertTrue(edits[1] === second.cgImage)
    }

    func testClosingWindowDropsItsImageEvenIfPanelIsRetained() throws {
        let manager = PinnedImageManager()
        defer { manager.closeAll() }
        var image: ToolImage? = try makeImage()
        weak var weakImage = image?.cgImage
        manager.open(try XCTUnwrap(image))
        let pin = try panel(for: XCTUnwrap(image))
        image = nil
        XCTAssertNotNil(weakImage)
        pin.close()
        XCTAssertEqual(manager.count, 0)
        XCTAssertNil(pin.contentView)
        XCTAssertNil(weakImage)
    }

    func testReleasingManagerCleansUpWhileResumeClosureIsRetained() async throws {
        var manager: PinnedImageManager? = PinnedImageManager()
        weak var weakManager = manager
        weak var weakImage: CGImage?
        // Keep synthesized ToolImage temporaries out of the async test frame.
        let pin = try autoreleasepool {
            let image = try makeImage()
            weakImage = image.cgImage
            manager?.open(image)
            return try panel(for: image)
        }
        let resume = try XCTUnwrap(manager?.suspendPresentation())
        autoreleasepool { manager = nil }
        XCTAssertNil(weakManager, "A panel or resume callback must not retain the manager")
        // Swift 5 deinit crosses to the main actor for AppKit cleanup. Detaching
        // content does not mean AppKit's drawing/teardown references have drained.
        // Wait for actual image release too; observe weak references in a scoped
        // pool so the poll itself cannot retain a loaded CGImage across an await.
        let deadline = Date().addingTimeInterval(2)
        while autoreleasepool(invoking: { pin.contentView != nil || weakImage != nil }),
              Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        resume()
        XCTAssertFalse(pin.isVisible)
        XCTAssertNil(pin.contentView)
        XCTAssertNil(pin.delegate)
        XCTAssertNil(pin.onCloseRequested)
        XCTAssertNil(pin.onCommand)
        XCTAssertNil(weakImage)
    }

    func testKeyboardOpacityClampsAndTopmostStateBelongToEachWindow() throws {
        let manager = PinnedImageManager()
        defer { manager.closeAll() }
        let first = try makeImage()
        let second = try makeImage()
        manager.open(first)
        manager.open(second)
        let firstPanel = try panel(for: first)
        let secondPanel = try panel(for: second)
        for _ in 0..<15 {
            XCTAssertTrue(firstPanel.performKeyEquivalent(with: try keyEvent("[", panel: firstPanel, modifiers: .command)))
        }
        XCTAssertEqual(firstPanel.alphaValue, 0.2, accuracy: 0.001)
        XCTAssertEqual(secondPanel.alphaValue, 1)
        for _ in 0..<15 {
            XCTAssertTrue(firstPanel.performKeyEquivalent(with: try keyEvent("]", panel: firstPanel, modifiers: .command)))
        }
        XCTAssertEqual(firstPanel.alphaValue, 1)
        XCTAssertTrue(firstPanel.performKeyEquivalent(with: try keyEvent("t", panel: firstPanel, modifiers: .command)))
        XCTAssertEqual(firstPanel.level, .normal)
        XCTAssertEqual(secondPanel.level, .floating)
        XCTAssertTrue(firstPanel.performKeyEquivalent(with: try keyEvent("t", panel: firstPanel, modifiers: .command)))
        XCTAssertEqual(firstPanel.level, .floating)
    }

    func testOpacityReadoutUsesExplicitRoundedPercentages() {
        let controls = PinnedImageControls(title: "Opacity", isOriginal: true)
        XCTAssertEqual(controls.opacityPercentage, "100%")
        controls.opacity = 0.625
        XCTAssertEqual(controls.opacityPercentage, "63%")
        controls.opacity = 0.2
        XCTAssertEqual(controls.opacityPercentage, "20%")
    }

    func testReleasingManagerClosesEveryVisibleWindow() async throws {
        var manager: PinnedImageManager? = PinnedImageManager()
        weak var weakManager = manager
        let first = try makeImage()
        let second = try makeImage()
        manager?.open(first)
        manager?.open(second)
        let panels = try [panel(for: first), panel(for: second)]
        XCTAssertTrue(panels.allSatisfy(\.isVisible))
        manager = nil
        XCTAssertNil(weakManager)
        let deadline = Date().addingTimeInterval(2)
        while panels.contains(where: { $0.contentView != nil }), Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(panels.allSatisfy { !$0.isVisible && $0.contentView == nil && $0.delegate == nil })
    }

    func testPanelBehaviorDoesNotActivateOrDependOnHistoryPanel() throws {
        let manager = PinnedImageManager()
        defer { manager.closeAll() }
        let image = try makeImage()
        manager.open(image)
        let pin = try panel(for: image)
        XCTAssertTrue(pin.styleMask.contains(.nonactivatingPanel))
        XCTAssertTrue(pin.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertTrue(pin.collectionBehavior.contains(.fullScreenAuxiliary))
        XCTAssertFalse(pin.hidesOnDeactivate)
        XCTAssertTrue(pin.canBecomeKey)
        XCTAssertFalse(pin.canBecomeMain)
        XCTAssertEqual(pin.level, .floating)
        XCTAssertFalse(pin.isReleasedWhenClosed)
    }

    func testNoAnchorInitialPlacementFitsNegativeCoordinateScreenForExtremeImages() {
        let screen = CGRect(x: -1_440, y: -800, width: 1_440, height: 780)
        for imageSize in [CGSize(width: 8_000, height: 6_000),
                          CGSize(width: 20, height: 10_000),
                          CGSize(width: 10_000, height: 20),
                          CGSize(width: 1, height: 1)] {
            let frame = PinnedImagePlacement.frame(imageSize: imageSize, anchor: nil,
                                                   visibleFrame: screen, backingScale: 2)
            XCTAssertTrue(screen.insetBy(dx: 8, dy: 8).contains(frame),
                          "Out-of-bounds initial frame: \(frame)")
            XCTAssertGreaterThanOrEqual(frame.width, 280)
            XCTAssertGreaterThanOrEqual(frame.height, 96)
        }
    }

    func testCapturePlacementRestoresPointTargetAtOneAndTwoTimesBackingScale() {
        let screen = CGRect(x: -1_920, y: -1_080, width: 1_920, height: 1_080)
        let visible = screen.insetBy(dx: 32, dy: 24)
        let targets = [CGRect(x: -1_800, y: -900, width: 900, height: 600),
                       CGRect(x: -1_700.5, y: -800.25, width: 24.5, height: 12.25),
                       CGRect(x: -1_920, y: -1_080, width: 0.5, height: 0.5),
                       screen]
        for scale: CGFloat in [1, 2] {
            for anchor in targets {
                let pixels = CGSize(width: anchor.width * scale, height: anchor.height * scale)
                XCTAssertEqual(PinnedImagePlacement.frame(imageSize: pixels, anchor: anchor,
                    visibleFrame: visible, backingScale: scale, screenFrame: screen), anchor)
            }
        }
        let anchor = targets[0]
        XCTAssertEqual(PinnedImagePlacement.frame(imageSize: CGSize(width: 2_700, height: 600),
            anchor: anchor, visibleFrame: visible, backingScale: 2, screenFrame: screen), anchor,
            "Nonuniform snapshot sampling must not override the point target")
        XCTAssertEqual(PinnedImagePlacement.frame(imageSize: anchor.size, anchor: anchor,
            visibleFrame: screen), anchor, "Existing callers need not supply screenFrame")
    }

    func testCapturePlacementTranslatesOverflowBeforeShrinkingOnlyOversizedTargets() {
        let screen = CGRect(x: -1_600, y: -900, width: 1_600, height: 900)
        let visible = screen.insetBy(dx: 40, dy: 30)
        let cases: [(CGRect, CGRect)] = [
            (CGRect(x: -1_700, y: -950, width: 900, height: 600),
             CGRect(x: -1_600, y: -900, width: 900, height: 600)),
            (CGRect(x: -400, y: -200, width: 900, height: 600),
             CGRect(x: -900, y: -600, width: 900, height: 600)),
            (CGRect(x: -1_700, y: -950, width: 3_200, height: 1_800), screen),
            (CGRect(x: -1_500, y: -850, width: 2_000, height: 500),
             CGRect(x: -1_600, y: -850, width: 1_600, height: 400)),
            (CGRect(x: -1_500, y: -850, width: 400, height: 1_200),
             CGRect(x: -1_500, y: -900, width: 300, height: 900))
        ]
        for (anchor, expected) in cases {
            let frame = PinnedImagePlacement.frame(imageSize: anchor.size, anchor: anchor,
                visibleFrame: visible, backingScale: 2, screenFrame: screen)
            XCTAssertEqual(frame, expected)
            XCTAssertTrue(screen.contains(frame))
            XCTAssertLessThanOrEqual(frame.width, anchor.width)
            XCTAssertLessThanOrEqual(frame.height, anchor.height)
            XCTAssertEqual(frame.width / frame.height, anchor.width / anchor.height, accuracy: 0.000_001)
        }
    }

    func testNoAnchorPlacementKeepsLegacyFitPaddingAndIgnoresScreenFrame() {
        let visible = CGRect(x: -1_000, y: -500, width: 900, height: 700)
        let cases: [(CGSize, CGFloat, CGRect)] = [
            (CGSize(width: 800, height: 600), 1, CGRect(x: -830, y: -360, width: 560, height: 420)),
            (CGSize(width: 800, height: 600), 2, CGRect(x: -750, y: -300, width: 400, height: 300)),
            (CGSize(width: 1, height: 1), 2, CGRect(x: -690, y: -198, width: 280, height: 96)),
            (CGSize(width: 20, height: 10_000), 2, CGRect(x: -690, y: -360, width: 280, height: 420)),
            (CGSize(width: 10_000, height: 20), 2, CGRect(x: -830, y: -198, width: 560, height: 96))
        ]
        for (pixels, scale, expected) in cases {
            XCTAssertEqual(PinnedImagePlacement.frame(imageSize: pixels, anchor: nil,
                visibleFrame: visible, backingScale: scale, screenFrame: visible.insetBy(dx: -80, dy: -80)),
                expected)
        }
        let smallVisible = CGRect(x: -300, y: -100, width: 300, height: 110)
        XCTAssertEqual(PinnedImagePlacement.frame(imageSize: CGSize(width: 1, height: 1), anchor: nil,
            visibleFrame: smallVisible), CGRect(x: -290, y: -92, width: 280, height: 94))
        for invalid in [CGRect.zero, CGRect.null, CGRect.infinite,
                        CGRect(x: 20, y: 20, width: -1, height: 2),
                        CGRect(x: CGFloat.nan, y: 0, width: 20, height: 20)] {
            XCTAssertEqual(PinnedImagePlacement.frame(imageSize: CGSize(width: 800, height: 600),
                anchor: invalid, visibleFrame: visible, backingScale: 2), cases[1].2)
        }
    }

    func testCapturedPanelsRenderActualImageAtPointTargetWithoutChangingPixels() throws {
        let screen = try XCTUnwrap(NSScreen.screens.first)
        let bounds = screen.frame
        let large = CGRect(x: bounds.minX + 40, y: bounds.minY + 40,
                           width: min(900, bounds.width - 80), height: min(600, bounds.height - 80))
        let small = CGRect(x: bounds.midX - 12, y: bounds.midY - 6, width: 24, height: 12)
        for target in [large, small, bounds] {
            for scale in [1, 2] {
                try autoreleasepool {
                    let image = try makeImage(width: Int(target.width * CGFloat(scale)),
                                              height: Int(target.height * CGFloat(scale)))
                    try assertCapturedPanel(image: image, target: target, screen: screen)
                }
            }
        }
        try autoreleasepool {
            // Its pixel aspect is deliberately unlike the 2:1 screen selection.
            let image = try makeImage(width: 240, height: 240)
            try assertCapturedPanel(image: image,
                target: CGRect(x: bounds.midX - 60, y: bounds.midY - 30, width: 120, height: 60),
                screen: screen)
        }
        for target in [CGRect(x: bounds.minX - 10, y: bounds.midY, width: 40, height: 20),
                       bounds.insetBy(dx: -bounds.width / 4, dy: -bounds.height / 4)] {
            try autoreleasepool {
                try assertCapturedPanel(image: makeImage(), target: target, screen: screen)
            }
        }
    }

    func testCaptureAnchorCenterSelectsSourceScreenIncludingReservedEdges() throws {
        for screen in NSScreen.screens {
            try autoreleasepool {
                let target = CGRect(x: screen.frame.midX - 12, y: screen.frame.maxY - 6,
                                    width: 24, height: 4)
                try assertCapturedPanel(image: makeImage(width: 48, height: 8),
                                        target: target, screen: screen)
            }
        }
    }

    func testTinyCaptureFirstWheelAndNativeResizePreserveItsOriginalMinimum() throws {
        try autoreleasepool {
            let screen = try XCTUnwrap(NSScreen.screens.first)
            let target = CGRect(x: screen.frame.midX - 20, y: screen.frame.midY - 10,
                                width: 40, height: 20)
            let controller = PinnedImageWindowController(image: try makeImage(width: 80, height: 40),
                                                         anchor: target)
            defer { controller.dispose() }
            controller.present()
            let pin = controller.panel
            let canvas = try canvas(in: pin)
            let original = pin.frame
            let pixel = 1 / max(1, pin.backingScaleFactor)
            let point = CGPoint(x: canvas.imageRect.midX, y: canvas.imageRect.midY)
            let globalPoint = pin.convertPoint(toScreen: canvas.convert(point, to: nil))
            XCTAssertEqual(pin.minSize.width, original.width, accuracy: pixel)
            XCTAssertEqual(pin.minSize.height, original.height, accuracy: pixel)
            canvas.scrollWheel(with: try scrollEvent(in: canvas, at: point, deltaY: 1))
            XCTAssertEqual(pin.frame.width, original.width * 1.1, accuracy: 2 * pixel + 0.000_001)
            XCTAssertLessThan(pin.frame.width, 60)
            let scaledCenter = CGPoint(x: canvas.imageRect.midX, y: canvas.imageRect.midY)
            let nextPoint = pin.convertPoint(toScreen: canvas.convert(scaledCenter, to: nil))
            XCTAssertEqual(nextPoint.x, globalPoint.x, accuracy: pixel + 0.000_001)
            XCTAssertEqual(nextPoint.y, globalPoint.y, accuracy: pixel + 0.000_001)
            canvas.scrollWheel(with: try scrollEvent(in: canvas, at: scaledCenter, deltaY: -1))
            XCTAssertEqual(pin.frame.width, original.width, accuracy: 2 * pixel + 0.000_001)
            canvas.scrollWheel(with: try scrollEvent(in: canvas,
                at: CGPoint(x: canvas.imageRect.midX, y: canvas.imageRect.midY), deltaY: -1))
            XCTAssertEqual(pin.frame.width, original.width, accuracy: 2 * pixel + 0.000_001)
        }
    }

    func testFullScreenCaptureNoOpResizeKeepsMenuAndDockGeometry() throws {
        try autoreleasepool {
            let screen = try XCTUnwrap(NSScreen.screens.first)
            let image = try makeImage(width: Int(screen.frame.width), height: Int(screen.frame.height))
            let controller = PinnedImageWindowController(image: image, anchor: screen.frame)
            defer { controller.dispose() }
            controller.present()
            let before = controller.panel.frame
            controller.windowWillStartLiveResize(Notification(name: NSWindow.willStartLiveResizeNotification,
                                                              object: controller.panel))
            assertRect(controller.panel.frame, equals: before, accuracy: 1)
            controller.panel.onCommand?("=")
            assertRect(controller.panel.frame, equals: before, accuracy: 1)
        }
    }

    func testRenderedCapturedImageIsReleasedWithPanelAndCanvasRetained() async throws {
        weak var weakImage: CGImage?
        weak var weakController: PinnedImageWindowController?
        let (pin, retainedCanvas) = try autoreleasepool {
            let screen = try XCTUnwrap(NSScreen.screens.first)
            let image = try makeImage(width: 240, height: 240)
            weakImage = image.cgImage
            let target = CGRect(x: screen.frame.midX - 30, y: screen.frame.midY - 15,
                                width: 60, height: 30)
            let controller = PinnedImageWindowController(image: image, anchor: target)
            weakController = controller
            controller.present()
            let pin = controller.panel
            let canvas = try canvas(in: pin)
            canvas.displayIfNeeded()
            let bitmap = try XCTUnwrap(canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds))
            canvas.cacheDisplay(in: canvas.bounds, to: bitmap)
            controller.dispose()
            XCTAssertNil(canvas.image)
            XCTAssertNil(pin.contentView)
            return (pin, canvas)
        }
        XCTAssertNil(weakController)
        let deadline = Date().addingTimeInterval(2)
        while autoreleasepool(invoking: { weakImage != nil }), Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertNil(weakImage)
        XCTAssertNil(retainedCanvas.image)
        XCTAssertNil(pin.contentView)
        XCTAssertFalse(pin.isVisible)
    }

    func testKeyboardZoomKeepsCanvasAspectAndFitsDisplay() throws {
        let manager = PinnedImageManager()
        defer { manager.closeAll() }
        let image = try makeImage(width: 800, height: 600)
        manager.open(image)
        let pin = try panel(for: image)
        let ratio = pin.frame.width / pin.frame.height
        for _ in 0..<10 {
            XCTAssertTrue(pin.performKeyEquivalent(with: try keyEvent("=", panel: pin, modifiers: .command)))
            XCTAssertEqual(pin.frame.width / pin.frame.height, ratio, accuracy: 0.001)
        }
        XCTAssertTrue(try XCTUnwrap(pin.screen).visibleFrame.insetBy(dx: -1, dy: -1).contains(pin.frame))
    }

    func testPlacementAndResizeHaveNoToolbarHeightBudget() {
        let visible = CGRect(x: -1_000, y: -500, width: 900, height: 700)
        let frame = PinnedImagePlacement.frame(imageSize: CGSize(width: 800, height: 600),
                                               anchor: nil, visibleFrame: visible, backingScale: 2)
        XCTAssertEqual(frame.size, CGSize(width: 400, height: 300))
        let available = CGRect(x: -100, y: -200, width: 600, height: 400)
        XCTAssertEqual(PinnedImagePlacement.fittedImageSize(CGSize(width: 1_000, height: 0),
                                                           aspect: 1, visibleFrame: available),
                       CGSize(width: 400, height: 400))
    }

    func testResizeMinimumKeepsShortSideAt24AndLongSideAtLeast48Points() {
        let available = CGRect(x: -2_000, y: -1_000, width: 4_000, height: 2_000)
        for aspect: CGFloat in [0.1, 0.5, 1, 2, 10] {
            let size = PinnedImagePlacement.fittedImageSize(
                CGSize(width: 0, height: 0), aspect: aspect, visibleFrame: available)
            XCTAssertGreaterThanOrEqual(min(size.width, size.height), 24)
            XCTAssertGreaterThanOrEqual(max(size.width, size.height), 48)
            XCTAssertEqual(size.width / size.height, aspect, accuracy: 0.000_001)
            XCTAssertLessThanOrEqual(size.width, available.width)
            XCTAssertLessThanOrEqual(size.height, available.height)
        }
        XCTAssertEqual(PinnedImagePlacement.fittedImageSize(.zero, aspect: 2, visibleFrame: available),
                       CGSize(width: 48, height: 24))
        XCTAssertEqual(PinnedImagePlacement.fittedImageSize(.zero, aspect: 1, visibleFrame: available),
                       CGSize(width: 48, height: 48))
        XCTAssertEqual(PinnedImagePlacement.fittedImageSize(.zero, aspect: 0.1,
            visibleFrame: CGRect(x: 0, y: 0, width: 20, height: 100)),
            CGSize(width: 10, height: 100), "A small display still takes precedence over the resize floor")
    }

    func testCompactToolbarThresholdChecksBothDimensions() {
        XCTAssertTrue(PinnedImagePlacement.canShowToolbar(in: CGSize(width: 240, height: 76)))
        XCTAssertFalse(PinnedImagePlacement.canShowToolbar(in: CGSize(width: 239, height: 300)))
        XCTAssertFalse(PinnedImagePlacement.canShowToolbar(in: CGSize(width: 800, height: 75)))
        XCTAssertFalse(PinnedImagePlacement.canShowToolbar(in: .zero))
    }

    func testScrollDeltaConversionIgnoresInvalidAndHorizontalInput() throws {
        XCTAssertEqual(try XCTUnwrap(PinnedImageScrollZoom.factor(deltaX: 0, deltaY: 1, precise: false)),
                       1.1, accuracy: 0.000_001)
        XCTAssertEqual(try XCTUnwrap(PinnedImageScrollZoom.factor(deltaX: 0, deltaY: -1, precise: false)),
                       1 / 1.1, accuracy: 0.000_001)
        let fine = try XCTUnwrap(PinnedImageScrollZoom.factor(deltaX: 0, deltaY: 0.25, precise: true))
        XCTAssertGreaterThan(fine, 1)
        XCTAssertLessThan(fine, 1.01)
        let reverse = try XCTUnwrap(PinnedImageScrollZoom.factor(deltaX: 0, deltaY: -0.25, precise: true))
        XCTAssertEqual(fine * reverse, 1, accuracy: 0.000_001)
        for (x, y) in [(CGFloat(0), CGFloat(0)), (2, 1), (1, 1), (1, 0),
                       (.nan, 1), (0, .nan), (.infinity, 1), (0, -.infinity)] {
            XCTAssertNil(PinnedImageScrollZoom.factor(deltaX: x, deltaY: y, precise: false))
        }
        XCTAssertTrue(try XCTUnwrap(PinnedImageScrollZoom.factor(
            deltaX: 0, deltaY: .greatestFiniteMagnitude, precise: true)).isFinite)
    }

    func testRealWheelAndTrackpadEventsZoomAtImagePointWithoutStealingFocus() throws {
        let controller = PinnedImageWindowController(image: try makeImage(width: 800, height: 600), anchor: nil)
        defer { controller.dispose() }
        controller.present()
        let pin = controller.panel
        let canvas = try canvas(in: pin)
        let other = NSPanel(contentRect: CGRect(x: 10, y: 10, width: 100, height: 100),
                            styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
        defer { other.close() }
        other.makeKeyAndOrderFront(nil)
        let wasKey = pin.isKeyWindow
        let firstResponder = pin.firstResponder
        let active = NSApp.isActive
        let imageRect = canvas.imageRect
        let unit = CGPoint(x: 0.3, y: 0.4)
        let point = CGPoint(x: imageRect.minX + unit.x * imageRect.width,
                            y: imageRect.minY + unit.y * imageRect.height)
        let screenPoint = pin.convertPoint(toScreen: canvas.convert(point, to: nil))
        let originalWidth = pin.frame.width
        let backingPixel = 1 / max(1, pin.backingScaleFactor)
        let wheel = try scrollEvent(in: canvas, at: point, deltaY: 1)
        XCTAssertEqual(wheel.type, .scrollWheel)
        XCTAssertFalse(wheel.hasPreciseScrollingDeltas)
        canvas.scrollWheel(with: wheel)
        // NSWindow aligns the two frame edges independently to backing pixels.
        XCTAssertEqual(pin.frame.width, originalWidth * 1.1, accuracy: 2 * backingPixel + 0.000_001)
        let scaled = canvas.imageRect
        let scaledAnchor = CGPoint(x: scaled.minX + unit.x * scaled.width,
                                   y: scaled.minY + unit.y * scaled.height)
        let nextScreenPoint = pin.convertPoint(toScreen: canvas.convert(scaledAnchor, to: nil))
        XCTAssertEqual(nextScreenPoint.x, screenPoint.x, accuracy: backingPixel + 0.000_001)
        XCTAssertEqual(nextScreenPoint.y, screenPoint.y, accuracy: backingPixel + 0.000_001)
        let beforeTrackpad = pin.frame.width
        let trackpad = try scrollEvent(in: canvas, at: CGPoint(x: scaled.midX, y: scaled.midY),
                                       deltaY: 3, precise: true)
        XCTAssertTrue(trackpad.hasPreciseScrollingDeltas)
        canvas.scrollWheel(with: trackpad)
        XCTAssertGreaterThan(pin.frame.width, beforeTrackpad)
        XCTAssertLessThan(pin.frame.width, beforeTrackpad * 1.1)
        XCTAssertEqual(pin.isKeyWindow, wasKey)
        XCTAssertTrue(pin.firstResponder === firstResponder)
        XCTAssertEqual(NSApp.isActive, active)
        XCTAssertTrue(other.isKeyWindow)
    }

    func testScrollIgnoresLetterboxHorizontalZeroAndMomentumAndDoesNotReachOtherPin() throws {
        let first = PinnedImageWindowController(image: try makeImage(width: 25, height: 100), anchor: nil)
        let second = PinnedImageWindowController(image: try makeImage(), anchor: nil)
        defer { first.dispose(); second.dispose() }
        first.present()
        second.present()
        let canvas = try canvas(in: first.panel)
        let initial = first.panel.frame
        let otherFrame = second.panel.frame
        let center = CGPoint(x: canvas.imageRect.midX, y: canvas.imageRect.midY)
        for event in [try scrollEvent(in: canvas, at: CGPoint(x: 1, y: canvas.bounds.midY), deltaY: 1),
                      try scrollEvent(in: canvas, at: center, deltaY: 0),
                      try scrollEvent(in: canvas, at: center, deltaX: 2, deltaY: 0),
                      try scrollEvent(in: canvas, at: center, deltaY: 3, precise: true, momentum: true)] {
            canvas.scrollWheel(with: event)
            XCTAssertEqual(first.panel.frame, initial)
        }
        canvas.scrollWheel(with: try scrollEvent(in: canvas, at: center, deltaY: 1))
        XCTAssertGreaterThan(first.panel.frame.width, initial.width)
        XCTAssertEqual(second.panel.frame, otherFrame)
    }

    func testScrollClampsOnceAndReverseImmediatelyLeavesEitherLimit() throws {
        let controller = PinnedImageWindowController(image: try makeImage(width: 800, height: 600), anchor: nil)
        defer { controller.dispose() }
        controller.present()
        let pin = controller.panel
        let canvas = try canvas(in: pin)
        let ratio = pin.frame.width / pin.frame.height
        func scroll(_ amount: Int32) throws {
            canvas.scrollWheel(with: try scrollEvent(in: canvas,
                at: CGPoint(x: canvas.imageRect.midX, y: canvas.imageRect.midY), deltaY: amount))
        }
        try scroll(10_000)
        let maxFrame = pin.frame
        try scroll(10_000)
        XCTAssertEqual(pin.frame, maxFrame)
        let available = try XCTUnwrap(pin.screen).visibleFrame.insetBy(dx: 8, dy: 8)
        XCTAssertTrue(available.insetBy(dx: -0.01, dy: -0.01).contains(pin.frame))
        try scroll(-1)
        XCTAssertLessThan(pin.frame.width, maxFrame.width)
        try scroll(-10_000)
        let minimum = pin.frame.width
        let expectedMinimum = PinnedImagePlacement.minimumImageWidth(aspect: ratio)
        XCTAssertEqual(minimum, expectedMinimum, accuracy: 2 / max(1, pin.backingScaleFactor))
        XCTAssertLessThan(minimum, 240)
        XCTAssertFalse(controller.isToolbarVisible)
        try scroll(-10_000)
        XCTAssertEqual(pin.frame.width, minimum)
        try scroll(1)
        XCTAssertGreaterThan(pin.frame.width, minimum)
        let pixel = 1 / max(1, pin.backingScaleFactor)
        XCTAssertEqual(pin.frame.width / pin.frame.height, ratio,
                       accuracy: 2 * pixel * (1 + ratio) / pin.frame.height)
    }

    func testSmallCaptureStartsWithoutToolbarAndKeepsImageHitTesting() throws {
        let screen = try XCTUnwrap(NSScreen.screens.first)
        let target = CGRect(x: screen.frame.midX - 20, y: screen.frame.midY - 10,
                            width: 40, height: 20)
        let controller = PinnedImageWindowController(image: try makeImage(width: 80, height: 40),
                                                     anchor: target)
        defer { controller.dispose() }
        controller.present()
        let pin = controller.panel
        let container = try XCTUnwrap(pin.contentView as? PinnedImageContainer)
        let toolbar = try XCTUnwrap(descendant(of: container, as: PinnedImageToolbarHost.self))
        let canvas = try canvas(in: pin)
        XCTAssertFalse(controller.isToolbarVisible)
        XCTAssertFalse(controller.controls.isToolbarVisible)
        XCTAssertEqual(toolbar.alphaValue, 0)
        XCTAssertFalse(toolbar.interactionEnabled)
        XCTAssertTrue(toolbar.isAccessibilityHidden())
        container.mouseEntered(with: try hoverEvent(.mouseEntered, panel: pin))
        XCTAssertFalse(controller.isToolbarVisible, "Hover must not reveal clipped controls on small pins")
        XCTAssertFalse(controller.hasPendingToolbarHide)
        XCTAssertTrue(container.hitTest(CGPoint(x: 5, y: canvas.bounds.maxY - 2)) === canvas)
        XCTAssertEqual(pin.frame.width, target.width, accuracy: 1)
        XCTAssertEqual(pin.frame.height, target.height, accuracy: 1)
    }

    func testWheelShrinkDismissesFocusedToolbarMenuAndOpacityAndCanRestoreControls() throws {
        let controller = PinnedImageWindowController(image: try makeImage(width: 800, height: 600), anchor: nil)
        defer { controller.dispose() }
        controller.present()
        let pin = controller.panel
        let container = try XCTUnwrap(pin.contentView as? PinnedImageContainer)
        let toolbar = try XCTUnwrap(descendant(of: container, as: PinnedImageToolbarHost.self))
        let button = try XCTUnwrap(descendant(of: container, as: PinnedImageActionMenuButton.self))
        let menu = try XCTUnwrap(button.menu)
        let canvas = try canvas(in: pin)
        pin.makeKey()
        XCTAssertTrue(pin.makeFirstResponder(button))
        controller.controls.showsOpacity = true
        button.menuWillOpen(menu)
        XCTAssertTrue(controller.isToolbarVisible)
        canvas.scrollWheel(with: try scrollEvent(in: canvas,
            at: CGPoint(x: canvas.imageRect.midX, y: canvas.imageRect.midY), deltaY: -10_000))
        XCTAssertLessThan(pin.frame.width, PinnedImagePlacement.toolbarMinimumSize.width)
        XCTAssertFalse(controller.isToolbarVisible)
        XCTAssertFalse(controller.controls.showsOpacity)
        XCTAssertFalse(controller.controls.isMenuTracking)
        XCTAssertFalse(controller.hasPendingToolbarHide)
        XCTAssertFalse(toolbar.interactionEnabled)
        XCTAssertTrue(pin.firstResponder === canvas, "Hidden toolbar focus must return to the image")
        container.mouseEntered(with: try hoverEvent(.mouseEntered, panel: pin))
        XCTAssertFalse(controller.isToolbarVisible)
        canvas.scrollWheel(with: try scrollEvent(in: canvas,
            at: CGPoint(x: canvas.imageRect.midX, y: canvas.imageRect.midY), deltaY: 10_000))
        container.mouseEntered(with: try hoverEvent(.mouseEntered, panel: pin))
        XCTAssertTrue(controller.isToolbarVisible)
        XCTAssertTrue(toolbar.interactionEnabled)
        XCTAssertEqual(toolbar.alphaValue, 1)
    }

    func testNativeResizeHidesWideButShortToolbarAndRestoresHoverWhenLargeEnough() throws {
        let controller = PinnedImageWindowController(image: try makeImage(width: 800, height: 80), anchor: nil)
        defer { controller.dispose() }
        controller.present()
        let pin = controller.panel
        let container = try XCTUnwrap(pin.contentView as? PinnedImageContainer)
        container.mouseEntered(with: try hoverEvent(.mouseEntered, panel: pin))
        XCTAssertTrue(controller.isToolbarVisible)
        let originalFrame = pin.frame
        let aspect = originalFrame.width / originalFrame.height
        let compact = CGSize(width: 70 * aspect, height: 70)
        pin.setFrame(CGRect(origin: pin.frame.origin, size: compact), display: true)
        controller.windowDidResize(Notification(name: NSWindow.didResizeNotification, object: pin))
        XCTAssertGreaterThanOrEqual(pin.frame.width, PinnedImagePlacement.toolbarMinimumSize.width)
        XCTAssertLessThan(pin.frame.height, PinnedImagePlacement.toolbarMinimumSize.height)
        container.mouseEntered(with: try hoverEvent(.mouseEntered, panel: pin))
        XCTAssertFalse(controller.isToolbarVisible)
        XCTAssertFalse(controller.hasPendingToolbarHide)
        pin.setFrame(originalFrame, display: true)
        controller.windowDidResize(Notification(name: NSWindow.didResizeNotification, object: pin))
        container.mouseEntered(with: try hoverEvent(.mouseEntered, panel: pin))
        XCTAssertTrue(controller.isToolbarVisible)
    }

    func testHoverOverlayPreservesCanvasImageAndEditAnchorAndHiddenTopHitTesting() async throws {
        let image = try makeImage(width: 25, height: 100)
        let controller = PinnedImageWindowController(image: image, anchor: nil)
        defer { controller.dispose() }
        controller.present()
        moveAwayFromPointer(controller.panel)
        let pin = controller.panel
        let container = try XCTUnwrap(pin.contentView as? PinnedImageContainer)
        let canvas = try canvas(in: pin)
        let toolbar = try XCTUnwrap(container.subviews.compactMap { $0 as? PinnedImageToolbarHost }.first)
        XCTAssertTrue(container.trackingAreas.contains {
            $0.options.contains(.activeAlways) && $0.options.contains(.mouseEnteredAndExited)
        })
        let initialCanvas = canvas.frame
        let initialImage = canvas.imageRect
        let initialToolbar = toolbar.frame
        var anchors: [CGRect] = []
        controller.onAction = { _, received, anchor in
            XCTAssertTrue(received.cgImage === image.cgImage)
            anchors.append(anchor)
        }
        pin.onCommand?("e")
        let wasKey = pin.isKeyWindow
        let responder = pin.firstResponder
        let active = NSApp.isActive
        container.mouseEntered(with: try hoverEvent(.mouseEntered, panel: pin))
        XCTAssertTrue(controller.isToolbarVisible)
        container.mouseExited(with: try hoverEvent(.mouseExited, panel: pin))
        XCTAssertTrue(controller.hasPendingToolbarHide)
        try await Task.sleep(nanoseconds: 200_000_000)
        container.mouseEntered(with: try hoverEvent(.mouseEntered, panel: pin))
        XCTAssertFalse(controller.hasPendingToolbarHide)
        try await Task.sleep(nanoseconds: 650_000_000)
        XCTAssertTrue(controller.isToolbarVisible, "Re-enter cancels the previous hide task")
        container.mouseExited(with: try hoverEvent(.mouseExited, panel: pin))
        try await Task.sleep(nanoseconds: 800_000_000)
        XCTAssertFalse(controller.isToolbarVisible)
        XCTAssertFalse(controller.hasPendingToolbarHide)
        XCTAssertEqual(canvas.frame, initialCanvas)
        XCTAssertEqual(canvas.frame, container.bounds)
        XCTAssertEqual(canvas.imageRect, initialImage)
        XCTAssertEqual(toolbar.frame, initialToolbar)
        XCTAssertEqual(toolbar.alphaValue, 0, accuracy: 0.001)
        XCTAssertFalse(toolbar.interactionEnabled)
        XCTAssertFalse(toolbar.canBecomeKeyView)
        XCTAssertTrue(toolbar.isAccessibilityHidden())
        let topPoint = CGPoint(x: initialImage.midX, y: container.bounds.maxY - 5)
        XCTAssertTrue(container.hitTest(topPoint) === canvas)
        pin.onCommand?("e")
        XCTAssertEqual(anchors.count, 2)
        XCTAssertEqual(anchors.first, anchors.last)
        container.mouseEntered(with: try hoverEvent(.mouseEntered, panel: pin))
        XCTAssertTrue(controller.isToolbarVisible)
        XCTAssertEqual(toolbar.alphaValue, 1)
        XCTAssertEqual(toolbar.frame, initialToolbar)
        XCTAssertEqual(canvas.imageRect, initialImage)
        XCTAssertEqual(pin.isKeyWindow, wasKey)
        XCTAssertTrue(pin.firstResponder === responder)
        XCTAssertEqual(NSApp.isActive, active)
        // A hidden toolbar must not block a wheel event in the top image strip.
        container.mouseExited(with: try hoverEvent(.mouseExited, panel: pin))
        try await Task.sleep(nanoseconds: 750_000_000)
        let width = pin.frame.width
        try XCTUnwrap(container.hitTest(topPoint)).scrollWheel(with:
            try scrollEvent(in: canvas, at: topPoint, deltaY: 1))
        XCTAssertGreaterThan(pin.frame.width, width)
    }

    func testMenuAndPopoverKeepOnlyTheirOwnToolbarAliveThenRescheduleHide() async throws {
        let first = PinnedImageWindowController(image: try makeImage(), anchor: nil)
        let second = PinnedImageWindowController(image: try makeImage(), anchor: nil)
        defer { first.dispose(); second.dispose() }
        first.present()
        second.present()
        moveAwayFromPointer(first.panel)
        moveAwayFromPointer(second.panel)
        let firstContainer = try XCTUnwrap(first.panel.contentView as? PinnedImageContainer)
        let secondContainer = try XCTUnwrap(second.panel.contentView as? PinnedImageContainer)
        let menuButton = try XCTUnwrap(descendant(of: firstContainer, as: PinnedImageActionMenuButton.self))
        let menu = try XCTUnwrap(menuButton.menu)
        XCTAssertFalse(menu.items.contains { $0.title.contains("放大") || $0.title.contains("缩小") })
        XCTAssertEqual(menu.items.filter(\.isSeparatorItem).count, 1)
        firstContainer.mouseEntered(with: try hoverEvent(.mouseEntered, panel: first.panel))
        menuButton.menuWillOpen(menu)
        firstContainer.mouseExited(with: try hoverEvent(.mouseExited, panel: first.panel))
        secondContainer.mouseEntered(with: try hoverEvent(.mouseEntered, panel: second.panel))
        secondContainer.mouseExited(with: try hoverEvent(.mouseExited, panel: second.panel))
        try await Task.sleep(nanoseconds: 750_000_000)
        XCTAssertTrue(first.controls.isMenuTracking)
        XCTAssertTrue(first.isToolbarVisible)
        XCTAssertFalse(second.isToolbarVisible)
        XCTAssertFalse(first.hasPendingToolbarHide)
        first.controls.showsOpacity = true
        menuButton.menuDidClose(menu)
        try await Task.sleep(nanoseconds: 750_000_000)
        XCTAssertTrue(first.isToolbarVisible)
        first.controls.showsOpacity = false
        XCTAssertTrue(first.hasPendingToolbarHide)
        try await Task.sleep(nanoseconds: 750_000_000)
        XCTAssertFalse(first.isToolbarVisible)
    }

    func testToolbarMaterialHasSquareCornersAndOnlyOuterContainerClipsAtTen() throws {
        XCTAssertEqual(PanelMaterial().cornerRadius, 16)
        XCTAssertEqual(PanelBackground().cornerRadius, 16)
        let controller = PinnedImageWindowController(image: try makeImage(), anchor: nil)
        defer { controller.dispose() }
        controller.present()
        let container = try XCTUnwrap(controller.panel.contentView as? PinnedImageContainer)
        let toolbar = try XCTUnwrap(descendant(of: container, as: PinnedImageToolbarHost.self))
        let material = try XCTUnwrap(descendant(of: toolbar, as: NSVisualEffectView.self))
        XCTAssertEqual(material.material, .hudWindow)
        XCTAssertEqual(try XCTUnwrap(material.layer).cornerRadius, 0)
        XCTAssertTrue(try XCTUnwrap(material.layer).masksToBounds)
        XCTAssertEqual(try XCTUnwrap(container.layer).cornerRadius, 10)
        XCTAssertTrue(try XCTUnwrap(container.layer).masksToBounds)
        XCTAssertEqual(toolbar.frame.width, container.bounds.width)
        XCTAssertEqual(toolbar.frame.height, PinnedImagePlacement.toolbarHeight)
    }

    func testPanelMaterialUpdatesCornerRadiusWithoutChangingDefaultPanels() async throws {
        let host = NSHostingView(rootView: PanelMaterial())
        let panel = NSPanel(contentRect: CGRect(x: 20, y: 20, width: 100, height: 80),
                            styleMask: .nonactivatingPanel, backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        defer { panel.contentView = nil; panel.close() }
        panel.contentView = host
        panel.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        let material = try XCTUnwrap(descendant(of: host, as: NSVisualEffectView.self))
        XCTAssertEqual(try XCTUnwrap(material.layer).cornerRadius, 16)
        for radius: CGFloat in [0, 7, 16] {
            host.rootView = PanelMaterial(cornerRadius: radius)
            try await Task.sleep(nanoseconds: 30_000_000)
            host.layoutSubtreeIfNeeded()
            XCTAssertTrue(descendant(of: host, as: NSVisualEffectView.self) === material)
            XCTAssertEqual(try XCTUnwrap(material.layer).cornerRadius, radius)
        }
    }

    func testRenderedToolbarAndOpaqueFallbackFillCornersWhileDefaultThemeStaysRounded() throws {
        let controls = PinnedImageControls(title: "Rendered toolbar", isOriginal: true)
        let toolbar = PinnedImageToolbar(controls: controls, onAction: { _ in }, onClose: {},
                                        onToggleTop: {}, onOpacity: { _ in })
            .environment(\.colorScheme, .light)
        let renderedToolbar = try renderedBitmap(toolbar,
            size: CGSize(width: 320, height: PinnedImagePlacement.toolbarHeight))
        // Reduce Transparency is read-only in macOS 13's SwiftUI environment.
        // Render its exact branch without changing the user's system settings.
        let defaultBackground = try renderedBitmap(PanelBackground().opaqueBackground,
                                                    size: CGSize(width: 80, height: 80))
        let squareBackground = try renderedBitmap(PanelBackground(cornerRadius: 0).opaqueBackground,
                                                   size: CGSize(width: 80, height: 80))
        let corners: [(Int, Int)] = [(1, 1), (renderedToolbar.pixelsWide - 2, 1),
                                    (1, renderedToolbar.pixelsHigh - 2),
                                    (renderedToolbar.pixelsWide - 2, renderedToolbar.pixelsHigh - 2)]
        for (x, y) in corners {
            XCTAssertGreaterThan(try XCTUnwrap(renderedToolbar.colorAt(x: x, y: y)).alphaComponent, 0.95,
                                 "Toolbar corners must be filled, with no inner 16pt scallop")
        }
        XCTAssertLessThan(try XCTUnwrap(defaultBackground.colorAt(x: 1, y: 1)).alphaComponent, 0.1)
        XCTAssertGreaterThan(try XCTUnwrap(defaultBackground.colorAt(
            x: defaultBackground.pixelsWide / 2, y: defaultBackground.pixelsHigh / 2)).alphaComponent, 0.95)
        XCTAssertGreaterThan(try XCTUnwrap(squareBackground.colorAt(x: 1, y: 1)).alphaComponent, 0.95)
    }

    func testNativeMenuTrackingTeardownDoesNotPublishIntoSwiftUIGraph() throws {
        let controls = PinnedImageControls(title: "Menu lifecycle", isOriginal: true)
        let button = PinnedImageActionMenuButton(controls: controls)
        button.configure(onAction: { _ in }, onClose: {}, onToggleTop: {}, onOpacity: { _ in })
        let menu = try XCTUnwrap(button.menu)
        var publications = 0
        var interactionChanges = 0
        let observation = controls.objectWillChange.sink { publications += 1 }
        defer { observation.cancel() }
        controls.onInteractionChanged = { interactionChanges += 1 }
        button.menuWillOpen(menu)
        button.menuWillOpen(menu)
        XCTAssertTrue(controls.isMenuTracking)
        button.stopTracking()
        button.stopTracking()
        button.menuDidClose(menu)
        XCTAssertFalse(controls.isMenuTracking)
        XCTAssertEqual(interactionChanges, 2, "Native tracking changes still notify the auto-hide owner")
        XCTAssertEqual(publications, 0, "Dismantling a native menu must not invalidate SwiftUI's graph")
        controls.isOnTop = false
        button.menuWillOpen(menu)
        XCTAssertEqual(menu.items.first { $0.keyEquivalent == "t" }?.title, "置顶")
        button.stopTracking()
    }

    func testToolbarKeyboardFocusKeepsControlsVisibleWithoutHover() async throws {
        let controller = PinnedImageWindowController(image: try makeImage(), anchor: nil)
        defer { controller.dispose() }
        controller.present()
        moveAwayFromPointer(controller.panel)
        let container = try XCTUnwrap(controller.panel.contentView as? PinnedImageContainer)
        let button = try XCTUnwrap(descendant(of: container, as: PinnedImageActionMenuButton.self))
        controller.panel.makeKey()
        XCTAssertTrue(controller.panel.makeFirstResponder(button))
        container.mouseEntered(with: try hoverEvent(.mouseEntered, panel: controller.panel))
        container.mouseExited(with: try hoverEvent(.mouseExited, panel: controller.panel))
        try await Task.sleep(nanoseconds: 750_000_000)
        XCTAssertTrue(controller.isToolbarVisible)
        XCTAssertFalse(controller.hasPendingToolbarHide)
        XCTAssertTrue(controller.panel.makeFirstResponder(try canvas(in: controller.panel)))
        try await Task.sleep(nanoseconds: 750_000_000)
        XCTAssertFalse(controller.isToolbarVisible)
    }

    func testDisposeCancelsHideTaskTrackingAndObserversWithoutRetainingController() async throws {
        weak var weakController: PinnedImageWindowController?
        // AppKit callbacks can create autoreleased controller references.
        // Drain those and keep Swift temporaries out of the async frame, while
        // retaining the panel, container and controls to detect actual cycles.
        let (pin, container, controls) = try autoreleasepool {
            let controller = PinnedImageWindowController(image: try makeImage(), anchor: nil)
            weakController = controller
            let pin = controller.panel
            controller.present()
            moveAwayFromPointer(pin)
            let container = try XCTUnwrap(pin.contentView as? PinnedImageContainer)
            let controls = controller.controls
            container.mouseEntered(with: try hoverEvent(.mouseEntered, panel: pin))
            container.mouseExited(with: try hoverEvent(.mouseExited, panel: pin))
            XCTAssertTrue(controller.hasPendingToolbarHide)
            controller.dispose()
            XCTAssertFalse(controller.hasPendingToolbarHide)
            XCTAssertTrue(container.trackingAreas.isEmpty)
            XCTAssertNil(container.onPointerChanged)
            XCTAssertNil(controls.onInteractionChanged)
            XCTAssertNil(pin.onFirstResponderChanged)
            return (pin, container, controls)
        }
        XCTAssertNil(weakController)
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: pin)
        controls.showsOpacity = true
        try await Task.sleep(nanoseconds: 750_000_000)
        XCTAssertNil(pin.contentView)
        XCTAssertFalse(pin.isVisible)
        XCTAssertTrue(container.trackingAreas.isEmpty)
        XCTAssertNil(weakController)
    }

    func testSuspendAndRestoreResynchronizePointerAndCancelPendingHide() throws {
        let controller = PinnedImageWindowController(image: try makeImage(), anchor: nil)
        defer { controller.dispose() }
        controller.present()
        moveAwayFromPointer(controller.panel)
        let container = try XCTUnwrap(controller.panel.contentView as? PinnedImageContainer)
        container.mouseEntered(with: try hoverEvent(.mouseEntered, panel: controller.panel))
        container.mouseExited(with: try hoverEvent(.mouseExited, panel: controller.panel))
        XCTAssertTrue(controller.hasPendingToolbarHide)
        controller.hide()
        XCTAssertFalse(controller.hasPendingToolbarHide)
        controller.present()
        XCTAssertFalse(container.isPointerInside)
        XCTAssertTrue(controller.hasPendingToolbarHide)
    }

    private func assertRect(_ actual: CGRect, equals expected: CGRect, accuracy: CGFloat,
                            file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.minX, expected.minX, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(actual.minY, expected.minY, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(actual.width, expected.width, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(actual.height, expected.height, accuracy: accuracy, file: file, line: line)
    }

    private func assertCapturedPanel(image: ToolImage, target: CGRect, screen: NSScreen) throws {
        let controller = PinnedImageWindowController(image: image, anchor: target)
        defer { controller.dispose() }
        controller.present()
        let pin = controller.panel
        let canvas = try canvas(in: pin)
        let container = try XCTUnwrap(pin.contentView as? PinnedImageContainer)
        let expected = PinnedImagePlacement.frame(imageSize: image.pixelSize, anchor: target,
            visibleFrame: screen.visibleFrame, backingScale: screen.backingScaleFactor,
            screenFrame: screen.frame)
        let pixel = 1 / max(1, pin.backingScaleFactor)
        XCTAssertEqual(pin.screen?.frame, screen.frame, "Screen selection must use the anchor center")
        assertRect(pin.frame, equals: expected, accuracy: pixel)
        assertRect(canvas.frame, equals: container.bounds, accuracy: 0.000_001)
        assertRect(canvas.imageRect, equals: canvas.bounds, accuracy: pixel)
        let globalImage = pin.convertToScreen(canvas.convert(canvas.imageRect, to: nil))
        assertRect(globalImage, equals: expected, accuracy: pixel)
        XCTAssertTrue(canvas.image === image.cgImage)
        let originalPixels = image.pixelSize
        var actions = 0
        controller.onAction = { _, received, anchor in
            actions += 1
            XCTAssertTrue(received.cgImage === image.cgImage)
            XCTAssertEqual(received.pixelSize, originalPixels)
            self.assertRect(anchor, equals: expected, accuracy: pixel)
        }
        pin.onCommand?("c")
        pin.onCommand?("e")
        container.mouseEntered(with: try hoverEvent(.mouseEntered, panel: pin))
        container.mouseExited(with: try hoverEvent(.mouseExited, panel: pin))
        pin.onCommand?("e")
        XCTAssertEqual(actions, 3)
        assertRect(pin.convertToScreen(canvas.convert(canvas.imageRect, to: nil)),
                   equals: expected, accuracy: pixel)
        canvas.displayIfNeeded()
        let bitmap = try XCTUnwrap(canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds))
        canvas.cacheDisplay(in: canvas.bounds, to: bitmap)
        // Inspect actual AppKit drawing near both edges as well as the center.
        // Nonuniform pixel sampling must not leave background-colored side bars.
        // colorAt constructs calibrated NSColor values on macOS 13 instead of
        // preserving this bitmap's display ICC profile. Sample its CGImage via
        // the existing sRGB conversion, not a second calibrated-color transform.
        let rendered = ToolImage(cgImage: try XCTUnwrap(bitmap.cgImage))
        for fraction in [0.1, 0.5, 0.9] {
            let color = try XCTUnwrap(rendered.color(at: CGPoint(
                x: Double(bitmap.pixelsWide - 1) * fraction, y: Double(bitmap.pixelsHigh / 2))))
            XCTAssertEqual(Double(color.red) / 255, 0.2, accuracy: 0.02)
            XCTAssertEqual(Double(color.green) / 255, 0.5, accuracy: 0.02)
            XCTAssertEqual(Double(color.blue) / 255, 0.8, accuracy: 0.02)
            XCTAssertGreaterThan(color.alpha, 0.99)
        }
        XCTAssertEqual(image.pixelSize, originalPixels)
    }

    private func renderedBitmap<Content: View>(_ content: Content, size: CGSize) throws -> NSBitmapImageRep {
        let host = NSHostingView(rootView: content)
        let panel = NSPanel(contentRect: CGRect(origin: .zero, size: size),
                            styleMask: .nonactivatingPanel, backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        defer { panel.contentView = nil; panel.close() }
        panel.contentView = host
        panel.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return bitmap
    }

    private func canvas(in panel: NSPanel) throws -> PinnedImageCanvas {
        let container = try XCTUnwrap(panel.contentView)
        container.layoutSubtreeIfNeeded()
        return try XCTUnwrap(container.subviews.compactMap { $0 as? PinnedImageCanvas }.first)
    }

    private func descendant<T: NSView>(of view: NSView, as type: T.Type) -> T? {
        if let result = view as? T { return result }
        for child in view.subviews {
            if let result = descendant(of: child, as: type) { return result }
        }
        return nil
    }

    private func moveAwayFromPointer(_ panel: NSPanel) {
        guard let visible = panel.screen?.visibleFrame else { return }
        let origins = [CGPoint(x: visible.minX + 8, y: visible.minY + 8),
                       CGPoint(x: visible.maxX - panel.frame.width - 8,
                               y: visible.maxY - panel.frame.height - 8)]
        let mouse = NSEvent.mouseLocation
        let origin = origins.max { lhs, rhs in
            hypot(lhs.x - mouse.x, lhs.y - mouse.y) < hypot(rhs.x - mouse.x, rhs.y - mouse.y)
        }!
        panel.setFrameOrigin(origin)
    }

    private func hoverEvent(_ type: NSEvent.EventType, panel: NSPanel) throws -> NSEvent {
        try XCTUnwrap(NSEvent.enterExitEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0,
                                           windowNumber: panel.windowNumber, context: nil,
                                           eventNumber: 1, trackingNumber: 1, userData: nil))
    }

    /// CGEvent creates real NSScrollWheel events. Direct view dispatch deliberately
    /// leaves the event windowless, mapping its locationInWindow to the target view.
    private func scrollEvent(in canvas: PinnedImageCanvas, at point: CGPoint,
                             deltaX: Int32 = 0, deltaY: Int32, precise: Bool = false,
                             momentum: Bool = false) throws -> NSEvent {
        let cg = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: precise ? .pixel : .line,
                                       wheelCount: 2, wheel1: deltaY, wheel2: deltaX, wheel3: 0))
        if momentum { cg.setIntegerValueField(.scrollWheelEventMomentumPhase, value: 1) }
        cg.location = .zero
        let base = try XCTUnwrap(NSEvent(cgEvent: cg)).locationInWindow
        let target = canvas.convert(point, to: nil)
        cg.location = CGPoint(x: target.x - base.x, y: base.y - target.y)
        let event = try XCTUnwrap(NSEvent(cgEvent: cg))
        XCTAssertEqual(event.locationInWindow.x, target.x, accuracy: 0.01)
        XCTAssertEqual(event.locationInWindow.y, target.y, accuracy: 0.01)
        if momentum { XCTAssertFalse(event.momentumPhase.isEmpty) }
        return event
    }

    private func makeImage(width: Int = 120, height: Int = 80,
                           isOriginal: Bool = true) throws -> ToolImage {
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(try XCTUnwrap(CGColor(colorSpace: colorSpace, components: [0.2, 0.5, 0.8, 1])))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ToolImage(cgImage: try XCTUnwrap(context.makeImage()), title: UUID().uuidString,
                         isOriginal: isOriginal)
    }

    private func panel(for image: ToolImage) throws -> PinnedImagePanel {
        try XCTUnwrap(NSApp.windows.compactMap { $0 as? PinnedImagePanel }
            .first { $0.title == "贴图 — \(image.title)" })
    }

    private func keyEvent(_ characters: String, keyCode: UInt16 = 0, panel: NSPanel,
                          modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
            windowNumber: panel.windowNumber, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode))
    }
}
