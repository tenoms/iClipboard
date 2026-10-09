import AppKit
import Combine
import QuartzCore
import XCTest
@testable import iClipboard

@MainActor
final class PanelPresentationTests: XCTestCase {
    @MainActor
    private final class Fixture {
        let manager: WindowManager
        let status = NSStatusBar.system.statusItem(withLength: 24)
        let panel = ClipboardPanel(
            contentRect: NSRect(x: 100, y: 100, width: 420, height: 460),
            backing: .buffered, defer: false
        )

        init(reduceMotion: Bool = false) {
            manager = WindowManager(registerHotKey: false, reduceMotion: { reduceMotion })
            panel.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 460))
            panel.contentView?.wantsLayer = true
            manager.panel = panel
            manager.statusItem = status
        }

        func dispose() {
            panel.orderOut(nil)
            panel.close()
            NSStatusBar.system.removeStatusItem(status)
        }
    }

    func testReverseCloseContinuesFromDisplayedStateAndDoesNotHideTheReopenedPanel() async throws {
        let fixture = Fixture()
        defer { fixture.dispose() }
        fixture.manager.openWindow()
        try await Task.sleep(nanoseconds: 70_000_000)
        XCTAssertGreaterThan(fixture.panel.alphaValue, 0)
        fixture.manager.closeWindow()
        try await Task.sleep(nanoseconds: 25_000_000)
        let before = fixture.panel.frame
        let opacity = fixture.panel.alphaValue
        let transform = try XCTUnwrap(fixture.panel.contentView?.layer?.transform)
        fixture.manager.openWindow()
        XCTAssertEqual(fixture.panel.frame.minY, before.minY, accuracy: 0.5)
        XCTAssertEqual(fixture.panel.alphaValue, opacity, accuracy: 0.02)
        XCTAssertEqual(fixture.panel.contentView!.layer!.transform.m11, transform.m11, accuracy: 0.002)
        await waitFor { !fixture.manager.isPresentationAnimating }
        try await Task.sleep(nanoseconds: 160_000_000)
        XCTAssertTrue(fixture.manager.isPanelVisible)
        XCTAssertTrue(fixture.panel.isVisible)
        XCTAssertEqual(fixture.panel.alphaValue, 1)
        XCTAssertTrue(CATransform3DIsIdentity(fixture.panel.contentView!.layer!.transform))
        fixture.manager.closeWindow()
        await waitFor { !fixture.manager.isPanelVisible }
    }

    func testImmediateDoubleToggleDoesNotLeaveAVisibleOrAnimatingGhost() async {
        let fixture = Fixture()
        defer { fixture.dispose() }
        fixture.manager.toggleWindow()
        fixture.manager.toggleWindow()
        await waitFor { !fixture.manager.isPanelVisible }
        XCTAssertFalse(fixture.panel.isVisible)
        XCTAssertFalse(fixture.manager.isPresentationAnimating)
        fixture.manager.toggleWindow()
        await waitFor { !fixture.manager.isPresentationAnimating }
        XCTAssertTrue(fixture.panel.isVisible)
        XCTAssertEqual(fixture.panel.alphaValue, 1)
        fixture.manager.closeWindow()
        await waitFor { !fixture.manager.isPanelVisible }
    }

    func testPinningDuringCloseReversesToTheFullyVisibleState() async throws {
        let fixture = Fixture()
        defer { fixture.dispose() }
        fixture.manager.openWindow()
        await waitFor { !fixture.manager.isPresentationAnimating }
        fixture.manager.closeWindow()
        try await Task.sleep(nanoseconds: 20_000_000)
        fixture.manager.isPinned = true
        await waitFor { !fixture.manager.isPresentationAnimating }
        XCTAssertTrue(fixture.manager.isPanelVisible)
        XCTAssertTrue(fixture.panel.isVisible)
        XCTAssertEqual(fixture.panel.alphaValue, 1)
        fixture.manager.isPinned = false
        fixture.manager.closeWindow()
        await waitFor { !fixture.manager.isPanelVisible }
    }

    func testRepeatedOpenClosePreservesGeometryAndKeepsHiddenPanelTransparent() async {
        let fixture = Fixture()
        defer { fixture.dispose() }
        for _ in 0..<4 {
            fixture.manager.openWindow()
            await waitFor { !fixture.manager.isPresentationAnimating }
            let resting = fixture.panel.frame
            XCTAssertEqual(fixture.panel.alphaValue, 1)
            fixture.manager.closeWindow()
            await waitFor { !fixture.manager.isPanelVisible }
            XCTAssertEqual(fixture.panel.frame, resting)
            XCTAssertEqual(fixture.panel.alphaValue, 0)
            XCTAssertTrue(CATransform3DIsIdentity(fixture.panel.contentView!.layer!.transform))
            XCTAssertFalse(fixture.manager.isPresentationAnimating)
        }
    }

    func testReduceMotionCompletesImmediately() {
        let fixture = Fixture(reduceMotion: true)
        defer { fixture.dispose() }
        fixture.manager.openWindow()
        XCTAssertTrue(fixture.panel.isVisible)
        XCTAssertEqual(fixture.panel.alphaValue, 1)
        XCTAssertTrue(CATransform3DIsIdentity(fixture.panel.contentView!.layer!.transform))
        XCTAssertFalse(fixture.manager.isPresentationAnimating)
        let frame = fixture.panel.frame
        fixture.manager.closeWindow()
        XCTAssertFalse(fixture.panel.isVisible)
        XCTAssertFalse(fixture.manager.isPanelVisible)
        XCTAssertEqual(fixture.panel.frame, frame)
        XCTAssertEqual(fixture.panel.alphaValue, 0)
        XCTAssertFalse(fixture.manager.isPresentationAnimating)
    }

    func testPinnedPanelAndAttachedSheetSurviveFocusLoss() async {
        let fixture = Fixture(reduceMotion: true)
        defer { fixture.dispose() }
        fixture.manager.openWindow()
        fixture.manager.isPinned = true
        fixture.manager.handleFocusLoss()
        fixture.manager.toggleWindow()
        XCTAssertTrue(fixture.panel.isVisible)
        XCTAssertFalse(fixture.manager.isPresentationAnimating)
        fixture.manager.isPinned = false
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 160, height: 100),
                             styleMask: .titled, backing: .buffered, defer: false)
        sheet.isReleasedWhenClosed = false
        fixture.panel.beginSheet(sheet, completionHandler: nil)
        fixture.manager.handleFocusLoss()
        XCTAssertTrue(fixture.panel.isVisible)
        fixture.panel.endSheet(sheet)
        sheet.orderOut(nil)
        sheet.close()
        fixture.manager.closeWindow()
    }

    func testFadeLeavesWindowGeometryAndContentLayerUntouched() async throws {
        let fixture = Fixture()
        defer { fixture.dispose() }
        let animator = PanelPresentationAnimator()
        let resting = fixture.panel.frame
        let content = try XCTUnwrap(fixture.panel.contentView)
        content.wantsLayer = false
        animator.transition(fixture.panel, opening: true, reduceMotion: false)
        try await Task.sleep(nanoseconds: 40_000_000)
        XCTAssertGreaterThan(fixture.panel.alphaValue, 0)
        XCTAssertLessThan(fixture.panel.alphaValue, 1)
        XCTAssertEqual(fixture.panel.frame, resting)
        XCTAssertFalse(content.wantsLayer)
        await waitFor { !animator.isAnimating }
        animator.transition(fixture.panel, opening: false, reduceMotion: false)
        await waitFor { !animator.isAnimating }
        XCTAssertFalse(fixture.panel.isVisible)
        XCTAssertEqual(fixture.panel.frame, resting)
        XCTAssertFalse(content.wantsLayer)
    }

    func testReduceMotionInterruptsPendingFadeWithoutStaleCompletion() async throws {
        let fixture = Fixture()
        defer { fixture.dispose() }
        let animator = PanelPresentationAnimator()
        var supersededCompletion = false
        animator.transition(fixture.panel, opening: true, reduceMotion: false) {
            supersededCompletion = true
        }
        try await Task.sleep(nanoseconds: 30_000_000)
        animator.transition(fixture.panel, opening: false, reduceMotion: true)
        XCTAssertFalse(animator.isAnimating)
        XCTAssertFalse(fixture.panel.isVisible)
        XCTAssertEqual(fixture.panel.alphaValue, 0)
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertFalse(supersededCompletion)
        XCTAssertFalse(fixture.panel.isVisible)
        XCTAssertEqual(fixture.panel.alphaValue, 0)
    }

    func testCloseOpacityDoesNotReboundDuringOrAfterContentTeardown() async throws {
        let fixture = Fixture()
        defer { fixture.dispose() }
        fixture.manager.openWindow()
        await waitFor { !fixture.manager.isPresentationAnimating }
        var teardownOpacity: CGFloat?
        let observation = fixture.manager.$isPanelVisible.dropFirst().sink { visible in
            if !visible { teardownOpacity = fixture.panel.alphaValue }
        }
        defer { observation.cancel() }

        fixture.manager.closeWindow()
        var previousOpacity: CGFloat = 1
        let deadline = Date().addingTimeInterval(3)
        while fixture.manager.isPanelVisible, Date() < deadline {
            let opacity = fixture.panel.alphaValue
            XCTAssertLessThanOrEqual(opacity, previousOpacity)
            previousOpacity = opacity
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(fixture.manager.isPanelVisible)
        XCTAssertFalse(fixture.panel.isVisible)
        XCTAssertEqual(teardownOpacity, 0)
        XCTAssertEqual(fixture.panel.alphaValue, 0)
        try await Task.sleep(nanoseconds: 160_000_000)
        XCTAssertEqual(fixture.panel.alphaValue, 0)

        fixture.manager.openWindow()
        XCTAssertEqual(fixture.panel.alphaValue, 0)
        await waitFor { !fixture.manager.isPresentationAnimating }
        XCTAssertTrue(fixture.panel.isVisible)
        XCTAssertEqual(fixture.panel.alphaValue, 1)
        fixture.manager.closeWindow()
        await waitFor { !fixture.manager.isPanelVisible }
    }

    func testAnimatorReleasesDuringAnInterruptedTransition() async throws {
        let fixture = Fixture()
        defer { fixture.dispose() }
        var animator: PanelPresentationAnimator? = PanelPresentationAnimator()
        weak var weakAnimator = animator
        animator?.transition(fixture.panel, opening: true, reduceMotion: false)
        try await Task.sleep(nanoseconds: 35_000_000)
        animator = nil
        XCTAssertNil(weakAnimator)
    }

    private func waitFor(_ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(3)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(condition(), "Panel animation did not reach its requested state")
    }
}
