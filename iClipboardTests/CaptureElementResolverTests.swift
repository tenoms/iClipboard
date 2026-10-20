import AppKit
import ApplicationServices
import XCTest
@testable import iClipboard

final class CaptureElementResolverTests: XCTestCase {
    private final class Reader: SelectionAccessibilityReading {
        typealias Element = String
        var attributes: [String: [String: Any]] = [:]
        var pids: [String: pid_t] = [:]
        var hit: String? = "control"
        var reads: [(String, String)] = []
        var hitApplications: [String] = []
        var hitPoints: [CGPoint] = []
        var onRead: (() -> Void)?
        var onHit: (() -> Void)?

        func value(_ attribute: String, of element: String) -> Any? {
            let allowed = [kAXRoleAttribute, kAXSubroleAttribute, kAXPositionAttribute,
                           kAXSizeAttribute, kAXParentAttribute]
            XCTAssertTrue(allowed.contains(attribute), "Unexpected AX read: \(attribute)")
            reads.append((element, attribute))
            onRead?()
            return attributes[element]?[attribute]
        }

        func value(_ attribute: String, parameter: Any, of element: String) -> Any? {
            XCTFail("Element detection must not read parameterized text/selection attributes")
            return nil
        }

        func hitTest(_ point: CGPoint, in application: String) -> String? {
            hitApplications.append(application)
            hitPoints.append(point)
            onHit?()
            return hit
        }
    }

    private let coordinates = CaptureDetectionCoordinates(primaryHeight: 1_000)
    private let window = CaptureDetectionWindow(frame: CGRect(x: -100, y: 100, width: 500, height: 400),
                                                 windowID: 71, ownerPID: 42)
    private let leafFrame = CGRect(x: 95, y: 195, width: 20, height: 15)

    private func request(point: CGPoint = CGPoint(x: 100, y: 200),
                         display: CGRect = CGRect(x: -200, y: 0, width: 1_000, height: 1_000)) -> CaptureElementRequest {
        CaptureElementRequest(window: window, point: point, displayFrame: display, coordinates: coordinates)
    }

    private func pointValue(_ point: CGPoint) -> AXValue {
        var point = point
        return AXValueCreate(.cgPoint, &point)!
    }

    private func sizeValue(_ size: CGSize) -> AXValue {
        var size = size
        return AXValueCreate(.cgSize, &size)!
    }

    private func attributes(role: String, frame: CGRect, parent: String? = nil) -> [String: Any] {
        let quartz = coordinates.quartzRect(fromGlobalAppKit: frame)
        var result: [String: Any] = [
            kAXRoleAttribute: role,
            kAXPositionAttribute: pointValue(quartz.origin),
            kAXSizeAttribute: sizeValue(quartz.size)
        ]
        if let parent { result[kAXParentAttribute] = parent }
        return result
    }

    private func reader() -> Reader {
        let reader = Reader()
        reader.pids = ["app": 42, "control": 42, "window": 42]
        reader.attributes = [
            "control": attributes(role: kAXButtonRole,
                                  frame: CGRect(x: 90, y: 190, width: 50, height: 40), parent: "window"),
            "window": attributes(role: kAXWindowRole, frame: window.frame, parent: "app"),
            "app": [kAXRoleAttribute: kAXApplicationRole]
        ]
        return reader
    }

    private func readerWithLeaf(role: String = kAXStaticTextRole,
                                parentRole: String = kAXButtonRole) -> Reader {
        let reader = reader()
        reader.hit = "leaf"
        reader.pids["leaf"] = 42
        reader.attributes["leaf"] = attributes(role: role, frame: leafFrame, parent: "control")
        reader.attributes["control"]?[kAXRoleAttribute] = parentRole
        return reader
    }

    private func readerWithAncestors(_ count: Int) -> Reader {
        let reader = reader()
        reader.attributes["control"]?[kAXParentAttribute] = count > 0 ? "ancestor0" : "window"
        for index in 0..<count {
            let name = "ancestor\(index)"
            reader.pids[name] = 42
            reader.attributes[name] = [kAXRoleAttribute: kAXGroupRole,
                                       kAXParentAttribute: index == count - 1 ? "window" : "ancestor\(index + 1)"]
        }
        return reader
    }

    private func resolve(_ reader: Reader, request: CaptureElementRequest? = nil,
                         shouldContinue: @escaping () -> Bool = { true }) -> CaptureDetectionCandidate? {
        CaptureElementResolver(reader: reader, processID: { reader.pids[$0] })
            .resolve(request ?? self.request(), application: "app", shouldContinue: shouldContinue)
    }

    func testResolvesOnlyOwnerApplicationAndUsesFrozenQuartzCoordinates() {
        let reader = reader()
        XCTAssertEqual(resolve(reader), CaptureDetectionCandidate(
            rect: CGRect(x: 90, y: 190, width: 50, height: 40), windowID: 71, ownerPID: 42, kind: .element))
        XCTAssertEqual(reader.hitApplications, ["app"])
        XCTAssertEqual(reader.hitPoints, [CGPoint(x: 100, y: 800)])
        XCTAssertFalse(reader.reads.contains { $0.1 == kAXValueAttribute })
    }

    func testStrictPointAndSizeAXTypesRejectRectAndNSValue() {
        var rect = CGRect(x: 90, y: 770, width: 50, height: 40)
        let wrongValues: [Any] = [AXValueCreate(.cgRect, &rect)!,
                                  NSValue(point: NSPoint(x: 90, y: 770)), "90,770", 12]
        for value in wrongValues {
            let reader = reader()
            reader.attributes["control"]?[kAXPositionAttribute] = value
            XCTAssertNil(resolve(reader))
        }
        let reader = reader()
        reader.attributes["control"]?[kAXSizeAttribute] = pointValue(CGPoint(x: 50, y: 40))
        XCTAssertNil(resolve(reader))
        XCTAssertNil(CaptureElementGeometry.point(sizeValue(CGSize(width: 1, height: 1))))
        XCTAssertNil(CaptureElementGeometry.size(pointValue(.zero)))
    }

    func testNonfiniteAndNonpositiveGeometryIsRejected() {
        for size in [CGSize(width: 0, height: 40), CGSize(width: -1, height: 40),
                     CGSize(width: CGFloat.infinity, height: 40), CGSize(width: 40, height: CGFloat.nan)] {
            let reader = reader()
            reader.attributes["control"]?[kAXSizeAttribute] = sizeValue(size)
            XCTAssertNil(resolve(reader))
        }
        let reader = reader()
        reader.attributes["control"]?[kAXPositionAttribute] = pointValue(CGPoint(x: CGFloat.nan, y: 0))
        XCTAssertNil(resolve(reader))
    }

    func testMissingChildGeometryCanRefineToAValidAncestor() {
        let reader = reader()
        reader.attributes["control"] = [kAXRoleAttribute: kAXStaticTextRole, kAXParentAttribute: "group"]
        reader.attributes["group"] = attributes(role: kAXGroupRole,
                                                frame: CGRect(x: 50, y: 150, width: 150, height: 100), parent: "window")
        reader.pids["group"] = 42
        XCTAssertEqual(resolve(reader)?.rect, CGRect(x: 50, y: 150, width: 150, height: 100))
    }

    func testTextAndImageLeavesPromoteToActionableParents() {
        let roles = [kAXButtonRole, kAXCheckBoxRole, kAXRadioButtonRole, kAXPopUpButtonRole,
                     kAXMenuButtonRole, "AXLink", kAXMenuItemRole, kAXDisclosureTriangleRole]
        for leafRole in [kAXStaticTextRole, kAXImageRole] {
            for parentRole in roles {
                let reader = readerWithLeaf(role: leafRole, parentRole: parentRole)
                XCTAssertEqual(resolve(reader), CaptureDetectionCandidate(
                    rect: CGRect(x: 90, y: 190, width: 50, height: 40),
                    windowID: 71, ownerPID: 42, kind: .element), "\(leafRole) inside \(parentRole)")
            }
        }
    }

    func testLeafPromotesThroughLayoutGroupToNearestActionableAncestorOnly() {
        let reader = readerWithLeaf()
        reader.attributes["leaf"]?[kAXParentAttribute] = "layout"
        reader.pids["layout"] = 42
        reader.attributes["layout"] = attributes(role: kAXGroupRole,
                                                  frame: leafFrame.insetBy(dx: -2, dy: -2), parent: "control")
        reader.attributes["control"]?[kAXParentAttribute] = "outer"
        reader.pids["outer"] = 42
        reader.attributes["outer"] = attributes(role: kAXButtonRole,
                                                 frame: CGRect(x: 50, y: 150, width: 200, height: 150), parent: "window")
        XCTAssertEqual(resolve(reader)?.rect, CGRect(x: 90, y: 190, width: 50, height: 40))
        XCTAssertFalse(reader.reads.contains { $0.0 == "layout" && $0.1 == kAXPositionAttribute })
        XCTAssertFalse(reader.reads.contains { $0.0 == "outer" && $0.1 == kAXPositionAttribute })
    }

    func testStandaloneTextAndImageKeepTheirGeometryInsideGenericContainers() {
        for role in [kAXStaticTextRole, kAXImageRole] {
            let reader = readerWithLeaf(role: role, parentRole: kAXGroupRole)
            XCTAssertEqual(resolve(reader)?.rect, leafFrame)
        }
    }

    func testNonLeafControlIsNotPromotedToLargerActionableAncestor() {
        let reader = readerWithLeaf(role: kAXButtonRole)
        XCTAssertEqual(resolve(reader)?.rect, leafFrame)
    }

    func testPromotionRequiresValidParentGeometryContainingWholeLeafAndPointer() {
        let frames = [CGRect(x: 99, y: 199, width: 5, height: 5),
                      CGRect(x: 200, y: 200, width: 50, height: 40),
                      CGRect(x: 90, y: 190, width: 0, height: 40)]
        for frame in frames {
            let reader = readerWithLeaf()
            reader.attributes["control"] = attributes(role: kAXButtonRole, frame: frame, parent: "window")
            XCTAssertEqual(resolve(reader)?.rect, leafFrame)
        }
        let malformed = readerWithLeaf()
        malformed.attributes["control"]?[kAXSizeAttribute] = pointValue(CGPoint(x: 50, y: 40))
        XCTAssertEqual(resolve(malformed)?.rect, leafFrame)
    }

    func testInvalidNearestActionableParentDoesNotJumpToOuterControl() {
        for missingGeometry in [false, true] {
            let reader = readerWithLeaf()
            reader.attributes["control"] = attributes(role: kAXButtonRole,
                                                       frame: CGRect(x: 99, y: 199, width: 5, height: 5), parent: "outer")
            if missingGeometry { reader.attributes["control"]?.removeValue(forKey: kAXPositionAttribute) }
            reader.pids["outer"] = 42
            reader.attributes["outer"] = attributes(role: kAXButtonRole,
                                                     frame: CGRect(x: 50, y: 150, width: 200, height: 150), parent: "window")
            XCTAssertEqual(resolve(reader)?.rect, leafFrame)
            XCTAssertFalse(reader.reads.contains { $0.0 == "outer" && $0.1 == kAXPositionAttribute })
        }
    }

    func testPromotionChecksWholeLeafBeforeDisplayClipping() {
        let reader = readerWithLeaf()
        let crossingLeaf = CGRect(x: -20, y: 195, width: 150, height: 15)
        reader.attributes["leaf"] = attributes(role: kAXStaticTextRole, frame: crossingLeaf, parent: "control")
        reader.attributes["control"] = attributes(role: kAXButtonRole,
                                                   frame: CGRect(x: 0, y: 190, width: 140, height: 40), parent: "window")
        let display = CGRect(x: 0, y: 0, width: 300, height: 1_000)
        XCTAssertEqual(resolve(reader, request: request(display: display))?.rect,
                       crossingLeaf.intersection(display))
    }

    func testPromotedCandidateIsStillClippedToSourceWindowAndPointerDisplay() {
        let reader = readerWithLeaf(role: kAXImageRole)
        reader.attributes["control"] = attributes(role: kAXButtonRole,
                                                   frame: CGRect(x: -150, y: 50, width: 700, height: 500), parent: "window")
        let display = CGRect(x: 0, y: 0, width: 300, height: 1_000)
        XCTAssertEqual(resolve(reader, request: request(display: display))?.rect,
                       CGRect(x: 0, y: 100, width: 300, height: 400))
    }

    func testPromotionStillRejectsSecureLeavesControlsAndAncestors() {
        for element in ["leaf", "control", "window"] {
            let reader = readerWithLeaf()
            reader.attributes[element]?[kAXSubroleAttribute] = kAXSecureTextFieldSubrole
            XCTAssertNil(resolve(reader))
        }
    }

    func testPromotionStillRejectsWrongOwnersAndMismatchedSourceWindows() {
        for element in ["app", "leaf", "control", "window"] {
            let reader = readerWithLeaf()
            reader.pids[element] = 99
            XCTAssertNil(resolve(reader))
        }
        let mismatched = readerWithLeaf()
        mismatched.attributes["window"] = attributes(role: kAXWindowRole,
                                                      frame: window.frame.offsetBy(dx: 20, dy: 0))
        XCTAssertNil(resolve(mismatched))
    }

    func testPromotionNeverReturnsBeforeWindowVerificationOrAfterCycle() {
        let detached = readerWithLeaf()
        detached.attributes["control"]?.removeValue(forKey: kAXParentAttribute)
        XCTAssertNil(resolve(detached))
        let cyclic = readerWithLeaf()
        cyclic.attributes["control"]?[kAXParentAttribute] = "leaf"
        XCTAssertNil(resolve(cyclic))
    }

    func testCycleNeverReturnsUnverifiedCandidate() {
        let reader = reader()
        reader.attributes["control"]?[kAXParentAttribute] = "control"
        XCTAssertNil(resolve(reader))
        XCTAssertLessThan(reader.reads.count, 10)
    }

    func testDeepHierarchyResolvesAtSixteenNodeLimitWithinBudget() {
        // Hit + fourteen layout ancestors + window = sixteen visited elements.
        let reader = readerWithAncestors(14)
        var clock: TimeInterval = 10
        reader.onRead = { clock += 0.001 }
        let resolver = CaptureElementResolver(reader: reader, processID: { reader.pids[$0] }, now: { clock })
        XCTAssertEqual(resolver.resolve(request(), application: "app")?.rect,
                       CGRect(x: 90, y: 190, width: 50, height: 40))
        XCTAssertEqual(reader.reads.filter { $0.1 == kAXRoleAttribute }.count, 16)
    }

    func testDepthBeyondSixteenNodesNeverReturnsUnverifiedCandidate() {
        // The window would be the seventeenth element, so no candidate can escape.
        let reader = readerWithAncestors(15)
        XCTAssertNil(resolve(reader))
        XCTAssertEqual(reader.reads.filter { $0.1 == kAXRoleAttribute }.count, 16)
        XCTAssertFalse(reader.reads.contains { $0.0 == "window" })
        XCTAssertLessThanOrEqual(reader.reads.count, 16 * 5)
    }

    func testDeepHierarchyStillStopsAtTimeBudget() {
        let reader = readerWithAncestors(14)
        var clock: TimeInterval = 10
        reader.onRead = { clock += 0.01 }
        let resolver = CaptureElementResolver(reader: reader, processID: { reader.pids[$0] }, now: { clock })
        XCTAssertNil(resolver.resolve(request(), application: "app"))
        XCTAssertLessThan(reader.reads.filter { $0.1 == kAXRoleAttribute }.count, 16)
        XCTAssertFalse(reader.reads.contains { $0.0 == "window" })
    }

    func testDeepHierarchyStillChecksAncestorOwnershipAndSecurity() {
        let wrongOwner = readerWithAncestors(14)
        wrongOwner.pids["ancestor10"] = 99
        XCTAssertNil(resolve(wrongOwner))
        let secure = readerWithAncestors(14)
        secure.attributes["ancestor10"]?[kAXSubroleAttribute] = kAXSecureTextFieldSubrole
        XCTAssertNil(resolve(secure))
        let cyclic = readerWithAncestors(14)
        cyclic.attributes["ancestor10"]?[kAXParentAttribute] = "ancestor8"
        XCTAssertNil(resolve(cyclic))
    }

    func testWindowAndApplicationAreNeverElementCandidates() {
        let reader = reader()
        reader.hit = "window"
        XCTAssertNil(resolve(reader))
        reader.hit = "app"
        XCTAssertNil(resolve(reader))
    }

    func testSecureFieldOrAncestorRejectsCandidateWithoutReadingText() {
        let reader = reader()
        reader.attributes["control"]?[kAXSubroleAttribute] = kAXSecureTextFieldSubrole
        XCTAssertNil(resolve(reader))
        XCTAssertFalse(reader.reads.contains { $0.1 == kAXPositionAttribute })

        let ancestor = self.reader()
        ancestor.attributes["window"]?[kAXSubroleAttribute] = kAXSecureTextFieldSubrole
        XCTAssertNil(resolve(ancestor))
    }

    func testMismatchedApplicationHitAndAncestorPIDAreRejected() {
        for element in ["app", "control", "window"] {
            let reader = reader()
            reader.pids[element] = 99
            XCTAssertNil(resolve(reader))
            if element == "app" { XCTAssertTrue(reader.hitApplications.isEmpty) }
        }
    }

    func testDifferentSameProcessWindowGeometryIsRejected() {
        let reader = reader()
        reader.attributes["window"] = attributes(role: kAXWindowRole,
                                                 frame: CGRect(x: -99, y: 100, width: 510, height: 400))
        XCTAssertNil(resolve(reader))
        reader.attributes["window"] = attributes(role: kAXWindowRole,
                                                 frame: window.frame.insetBy(dx: 1, dy: 1))
        XCTAssertNotNil(resolve(reader))
    }

    func testPointMustBeInsideElementAndSourceWindow() {
        let reader = reader()
        reader.attributes["control"] = attributes(role: kAXButtonRole,
                                                   frame: CGRect(x: 200, y: 200, width: 50, height: 40), parent: "window")
        XCTAssertNil(resolve(reader))
        XCTAssertNil(resolve(reader, request: request(point: CGPoint(x: 450, y: 200))))
    }

    func testCrossDisplayElementIsClippedToPointerDisplayAndSourceWindow() {
        let reader = reader()
        reader.attributes["control"] = attributes(role: kAXGroupRole,
                                                   frame: CGRect(x: -150, y: 50, width: 700, height: 500), parent: "window")
        let display = CGRect(x: 0, y: 0, width: 300, height: 1_000)
        XCTAssertEqual(resolve(reader, request: request(display: display))?.rect,
                       CGRect(x: 0, y: 100, width: 300, height: 400))
        XCTAssertNil(resolve(reader, request: request(point: CGPoint(x: -10, y: 200), display: display)))
    }

    func testCancelledBeforeHitDoesNotPerformAXReads() {
        let reader = reader()
        XCTAssertNil(resolve(reader, shouldContinue: { false }))
        XCTAssertTrue(reader.reads.isEmpty)
        XCTAssertTrue(reader.hitApplications.isEmpty)
    }

    func testBudgetChecksBeforeEveryReadAndDiscardsSlowHitAndFinalRead() {
        let reader = reader()
        var clock: TimeInterval = 10
        reader.onRead = { clock += 0.09 }
        let resolver = CaptureElementResolver(reader: reader, processID: { reader.pids[$0] },
                                              budget: 0.16, now: { clock })
        XCTAssertNil(resolver.resolve(request(), application: "app"))
        XCTAssertEqual(reader.reads.count, 2)

        let slowHit = self.reader()
        clock = 20
        slowHit.onHit = { clock += 0.3 }
        let slowResolver = CaptureElementResolver(reader: slowHit, processID: { slowHit.pids[$0] },
                                                  now: { clock })
        XCTAssertNil(slowResolver.resolve(request(), application: "app"))
        XCTAssertTrue(slowHit.reads.isEmpty)

        let slowFinalRead = self.reader()
        clock = 30
        slowFinalRead.onRead = {
            if let read = slowFinalRead.reads.last, read.0 == "window", read.1 == kAXSizeAttribute {
                clock += 0.3
            }
        }
        let finalResolver = CaptureElementResolver(reader: slowFinalRead, processID: { slowFinalRead.pids[$0] },
                                                   now: { clock })
        XCTAssertNil(finalResolver.resolve(request(), application: "app"))
    }

    func testPromotionDoesNotBypassBudgetOrCancellation() {
        let slow = readerWithLeaf()
        var clock: TimeInterval = 10
        slow.onRead = {
            if let read = slow.reads.last, read.0 == "control", read.1 == kAXSizeAttribute {
                clock += 0.3
            }
        }
        let resolver = CaptureElementResolver(reader: slow, processID: { slow.pids[$0] }, now: { clock })
        XCTAssertNil(resolver.resolve(request(), application: "app"))
        XCTAssertFalse(slow.reads.contains { $0.0 == "window" })

        let cancelled = readerWithLeaf()
        var valid = true
        cancelled.onRead = {
            if let read = cancelled.reads.last, read.0 == "control", read.1 == kAXParentAttribute {
                valid = false
            }
        }
        XCTAssertNil(resolve(cancelled, shouldContinue: { valid }))
        XCTAssertFalse(cancelled.reads.contains { $0.0 == "window" })
    }

    func testCancellationDuringTraversalDiscardsPartialCandidate() {
        let reader = reader()
        var valid = true
        reader.onRead = { if reader.reads.count == 5 { valid = false } }
        XCTAssertNil(resolve(reader, shouldContinue: { valid }))
        XCTAssertEqual(reader.reads.count, 5)
    }
}
