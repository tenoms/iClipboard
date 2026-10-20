import AppKit
import UniformTypeIdentifiers
import XCTest
@testable import iClipboard

@MainActor
final class ImageSaveDestinationTests: XCTestCase {
    private final class PanelStub: ImageSavePanelPresenting {
        var allowedContentTypes: [UTType] = []
        var nameFieldStringValue = ""
        var canCreateDirectories = false
        var directoryURL: URL?
        var warningMessage = ""
        var url: URL?
        var response: NSApplication.ModalResponse?
        var completion: ((NSApplication.ModalResponse) -> Void)?
        var didBegin = false
        var didCancel = false
        var didOrderOut = false

        func begin(completionHandler handler: @escaping (NSApplication.ModalResponse) -> Void) {
            didBegin = true
            completion = handler
            if let response { handler(response) }
        }

        func cancel(_ sender: Any?) {
            didCancel = true
            completion?(.cancel)
        }

        func orderOut(_ sender: Any?) { didOrderOut = true }
    }

    private func preferences(validateDirectory: @escaping (URL) throws -> Void = { _ in }) -> ImageToolsPreferences {
        let suite = "iClipboard.ImageSaveDestinationTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return ImageToolsPreferences(defaults: defaults, validateDirectory: validateDirectory)
    }

    private func waitForBegin(_ panel: PanelStub) async {
        for _ in 0..<100 where !panel.didBegin {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertTrue(panel.didBegin)
    }

    func testUnconfiguredDirectoryKeepsSystemDefaultAndCancelledPanelReturnsNil() async throws {
        let preferences = preferences()
        let panel = PanelStub()
        panel.response = .cancel
        var activated = false
        let url = try await ImageSaveDestination.choose(name: "iclipboard_240102_030405.png",
                                                       preferences: preferences, panel: panel,
                                                       activate: { activated = true })
        XCTAssertNil(url)
        XCTAssertNil(panel.directoryURL)
        XCTAssertEqual(panel.allowedContentTypes, [.png])
        XCTAssertEqual(panel.nameFieldStringValue, "iclipboard_240102_030405.png")
        XCTAssertTrue(panel.canCreateDirectories)
        XCTAssertTrue(panel.warningMessage.isEmpty)
        XCTAssertTrue(activated)
        XCTAssertNil(preferences.defaultSaveDirectory)
    }

    func testEachSaveReadsLatestDirectoryAndPreservesProposedFilename() async throws {
        let preferences = preferences()
        let first = URL(fileURLWithPath: "/virtual/first", isDirectory: true)
        let second = URL(fileURLWithPath: "/virtual/second", isDirectory: true)
        try preferences.setDefaultSaveDirectory(first)
        let firstPanel = PanelStub()
        firstPanel.response = .cancel
        _ = try await ImageSaveDestination.choose(name: "First.png", preferences: preferences,
                                                  panel: firstPanel, activate: {})
        XCTAssertEqual(firstPanel.directoryURL, first)
        try preferences.setDefaultSaveDirectory(second)
        let secondPanel = PanelStub()
        secondPanel.response = .cancel
        _ = try await ImageSaveDestination.choose(name: "Second.png", preferences: preferences,
                                                  panel: secondPanel, activate: {})
        XCTAssertEqual(secondPanel.directoryURL, second)
        XCTAssertEqual(secondPanel.nameFieldStringValue, "Second.png")
        preferences.restoreDefaultSaveDirectory()
        let defaultPanel = PanelStub()
        defaultPanel.response = .cancel
        _ = try await ImageSaveDestination.choose(name: "Default.png", preferences: preferences,
                                                  panel: defaultPanel, activate: {})
        XCTAssertNil(defaultPanel.directoryURL)
    }

    func testUnavailableDirectoryShowsWarningAndAllowsExplicitAlternateSelection() async throws {
        let selected = URL(fileURLWithPath: "/virtual/offline", isDirectory: true)
        var available = true
        let preferences = preferences { url in
            if !available { throw ImageSaveDirectoryError.unavailable(url) }
        }
        try preferences.setDefaultSaveDirectory(selected)
        available = false
        let panel = PanelStub()
        let alternate = URL(fileURLWithPath: "/virtual/alternate/result.png")
        panel.url = alternate
        panel.response = .OK
        let output = try await ImageSaveDestination.choose(name: "result.png", preferences: preferences,
                                                          panel: panel, activate: {})
        XCTAssertEqual(output, alternate)
        XCTAssertNil(panel.directoryURL)
        XCTAssertTrue(panel.warningMessage.contains(selected.path))
        XCTAssertTrue(panel.warningMessage.contains("不可用"))
        XCTAssertTrue(panel.warningMessage.contains("请选择其他可写目录"))
        XCTAssertEqual(preferences.defaultSaveDirectory, selected, "Choosing an export path must not rewrite the default preference")
    }

    func testReadOnlyDirectoryShowsWarningAndCancelKeepsPreference() async throws {
        let selected = URL(fileURLWithPath: "/virtual/read-only", isDirectory: true)
        var writable = true
        let preferences = preferences { url in
            if !writable { throw ImageSaveDirectoryError.notWritable(url) }
        }
        try preferences.setDefaultSaveDirectory(selected)
        writable = false
        let panel = PanelStub()
        panel.response = .cancel
        let result = try await ImageSaveDestination.choose(name: "result.png", preferences: preferences,
                                                          panel: panel, activate: {})
        XCTAssertNil(result)
        XCTAssertNil(panel.directoryURL)
        XCTAssertTrue(panel.warningMessage.contains("只读"))
        XCTAssertEqual(preferences.defaultSaveDirectory, selected)
    }

    func testOKWithoutSelectedURLThrowsRatherThanPretendingUserCancelled() async {
        let panel = PanelStub()
        panel.response = .OK
        do {
            _ = try await ImageSaveDestination.choose(name: "result.png", preferences: preferences(),
                                                      panel: panel, activate: {})
            XCTFail("An accepted panel must supply a destination")
        } catch ImageOutputError.missingSaveURL {
            // Expected: this is a failure, not cancellation.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testConfirmedDestinationIsReturnedWithoutWritingOrDeletingExistingFile() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("existing.png")
        let original = Data([1, 2, 3])
        try original.write(to: url)
        let panel = PanelStub()
        panel.url = url
        panel.response = .OK // Native NSSavePanel owns any existing-file replacement confirmation.
        let result = try await ImageSaveDestination.choose(name: "existing.png", preferences: preferences(),
                                                          panel: panel, activate: {})
        XCTAssertEqual(result, url)
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testOwnedRequestStaysAliveUntilDelayedPanelResponse() async throws {
        let panel = PanelStub()
        panel.url = URL(fileURLWithPath: "/virtual/result.png")
        let preferences = preferences()
        let task = Task {
            try await ImageSaveDestination.choose(name: "result.png", preferences: preferences,
                                                  panel: panel, activate: {})
        }
        await waitForBegin(panel)
        panel.completion?(.OK)
        let result = try await task.value
        XCTAssertEqual(result, panel.url)
        XCTAssertFalse(panel.didCancel)
    }

    func testOwnerCancellationClosesPanelAndLateCompletionDoesNotResumeTwice() async throws {
        let panel = PanelStub()
        let preferences = preferences()
        let task = Task {
            try await ImageSaveDestination.choose(name: "result.png", preferences: preferences,
                                                  panel: panel, activate: {})
        }
        await waitForBegin(panel)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Owner cancellation must propagate")
        } catch is CancellationError {
        }
        XCTAssertTrue(panel.didCancel)
        XCTAssertTrue(panel.didOrderOut)
        panel.completion?(.OK)
    }

    func testAlreadyCancelledOwnerDoesNotPresentPanel() async {
        let panel = PanelStub()
        let preferences = preferences()
        let task = Task {
            try await ImageSaveDestination.choose(name: "result.png", preferences: preferences,
                                                  panel: panel, activate: {})
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("A cancelled owner must fail")
        } catch is CancellationError {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertFalse(panel.didBegin)
    }

    private func directory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    func testConfiguredSaveNeverCreatesPanelActivatesOrInvokesChooserAndWritesExactBytes() async throws {
        let preferences = preferences()
        let directory = try directory()
        try preferences.setDefaultSaveDirectory(directory)
        let request = ImageSaveDestination.request(preferences: preferences, date: Date(timeIntervalSince1970: 0))
        let data = Data(repeating: 0xB6, count: 1_200_017)
        var factoryCalls = 0
        var activations = 0
        var presentations = 0
        var chooserCalls = 0
        let receipt = try await ImageSaveDestination.savePNG(data, request: request, chooseURL: { _ in
            chooserCalls += 1
            return nil
        }, willPresentPanel: {
            presentations += 1
        }, panelFactory: {
            factoryCalls += 1
            return PanelStub()
        }, activate: {
            activations += 1
        })
        let saved = try XCTUnwrap(receipt)
        XCTAssertEqual(saved.deletingLastPathComponent(), directory)
        XCTAssertEqual(try Data(contentsOf: saved), data)
        XCTAssertEqual(factoryCalls, 0)
        XCTAssertEqual(activations, 0)
        XCTAssertEqual(presentations, 0)
        XCTAssertEqual(chooserCalls, 0)
    }

    func testUnconfiguredSaveUsesPanelAndCancelCreatesNoOutput() async throws {
        let preferences = preferences()
        let request = ImageSaveDestination.request(preferences: preferences, date: Date(timeIntervalSince1970: 0))
        let panel = PanelStub()
        panel.response = .cancel
        var factoryCalls = 0
        var presentations = 0
        var activations = 0
        let result = try await ImageSaveDestination.savePNG(Data([1]), request: request, willPresentPanel: {
            XCTAssertFalse(panel.didBegin)
            presentations += 1
        }, panelFactory: {
            factoryCalls += 1
            return panel
        }, activate: {
            XCTAssertEqual(presentations, 1)
            activations += 1
        })
        XCTAssertNil(result)
        XCTAssertEqual(factoryCalls, 1)
        XCTAssertEqual(activations, 1)
        XCTAssertEqual(presentations, 1)
        XCTAssertTrue(panel.didBegin)
        XCTAssertNil(panel.directoryURL)
        XCTAssertNil(preferences.defaultSaveDirectory)
    }

    func testRequestFreezesDirectoryAndDateButNextActionReadsChangedPreference() async throws {
        let preferences = preferences()
        let first = try directory()
        let second = try directory()
        let date = Date(timeIntervalSince1970: 1_704_164_645)
        try preferences.setDefaultSaveDirectory(first)
        let request = ImageSaveDestination.request(preferences: preferences, date: date)
        try preferences.setDefaultSaveDirectory(second)
        let nextRequest = ImageSaveDestination.request(preferences: preferences, date: date.addingTimeInterval(1))
        XCTAssertEqual(request, .directory(first, filename: preferences.rawFilename(at: date)))
        XCTAssertEqual(nextRequest, .directory(second, filename: preferences.rawFilename(at: date.addingTimeInterval(1))))
        let receipt = try await ImageSaveDestination.savePNG(Data([1, 2, 3]), request: request)
        let saved = try XCTUnwrap(receipt)
        XCTAssertEqual(saved.deletingLastPathComponent(), first)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: second.path), [])
        preferences.restoreDefaultSaveDirectory()
        XCTAssertEqual(ImageSaveDestination.request(preferences: preferences, date: date),
                       .panel(suggestedName: preferences.rawFilename(at: date)))
    }

    func testRequestKeepsRawStemEvenWhenSuggestedFilenameAlreadyHasCollisionSuffix() async throws {
        let directory = try directory()
        let preferences = preferences()
        try preferences.setDefaultSaveDirectory(directory)
        let date = Date(timeIntervalSince1970: 0)
        let name = preferences.rawFilename(at: date)
        let original = directory.appendingPathComponent(name)
        let existing = Data([99])
        try existing.write(to: original)
        let request = ImageSaveDestination.request(preferences: preferences, date: date)
        XCTAssertEqual(request, .directory(directory, filename: name))
        let firstReceipt = try await ImageSaveDestination.savePNG(Data([1]), request: request)
        let secondReceipt = try await ImageSaveDestination.savePNG(Data([2]), request: request)
        let stem = String(name.dropLast(4))
        XCTAssertEqual(firstReceipt?.lastPathComponent, stem + "_2.png")
        XCTAssertEqual(secondReceipt?.lastPathComponent, stem + "_3.png")
        XCTAssertEqual(try Data(contentsOf: original), existing)
    }

    func testInvalidConfiguredDirectoryThrowsWithoutPanelFallbackOrChangingInput() async throws {
        let preferences = preferences()
        let root = try directory()
        let configured = root.appendingPathComponent("configured", isDirectory: true)
        try FileManager.default.createDirectory(at: configured, withIntermediateDirectories: false)
        try preferences.setDefaultSaveDirectory(configured)
        let request = ImageSaveDestination.request(preferences: preferences)
        try FileManager.default.removeItem(at: configured)
        let image = Data([137, 80, 78, 71, 1, 2, 3])
        let originalImage = image
        var presentations = 0
        do {
            _ = try await ImageSaveDestination.savePNG(image, request: request, chooseURL: { _ in
                XCTFail("Invalid configured directory must not fall back to a chooser")
                return nil
            }, willPresentPanel: {
                presentations += 1
            }, panelFactory: {
                XCTFail("Invalid configured directory must not create a panel")
                return PanelStub()
            }, activate: { XCTFail("Direct saves must not activate") })
            XCTFail("An unavailable directory must explicitly fail")
        } catch let error as ImageSaveDirectoryError {
            XCTAssertEqual(error, .unavailable(configured))
        }
        XCTAssertEqual(presentations, 0)
        XCTAssertEqual(image, originalImage)
        XCTAssertEqual(preferences.defaultSaveDirectory, configured)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
    }

    func testInjectedChooserRunsOnlyAfterPresentationCallbackAndCanConfirmReplacement() async throws {
        let directory = try directory()
        let existing = directory.appendingPathComponent("confirmed.png")
        try Data([0]).write(to: existing)
        let data = Data([1, 2, 3])
        var events: [String] = []
        let result = try await ImageSaveDestination.savePNG(data, request: .panel(suggestedName: "suggested.png"), chooseURL: { name in
            events.append("choose")
            XCTAssertEqual(name, "suggested.png")
            return existing
        }, willPresentPanel: { events.append("willPresent") }, panelFactory: {
            XCTFail("An injected chooser must bypass native panel construction")
            return PanelStub()
        }, activate: { XCTFail("An injected chooser owns activation") })
        XCTAssertEqual(events, ["willPresent", "choose"])
        XCTAssertEqual(result, existing)
        XCTAssertEqual(try Data(contentsOf: existing), data)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["confirmed.png"])
    }

    func testInjectedChooserCancellationReturnsNilWithoutWriting() async throws {
        var presented = false
        let result = try await ImageSaveDestination.savePNG(Data([1]), request: .panel(suggestedName: "cancel.png"), chooseURL: { _ in
            XCTAssertTrue(presented)
            return nil
        }, willPresentPanel: { presented = true })
        XCTAssertNil(result)
        XCTAssertTrue(presented)
    }

    func testSavePNGTaskCancellationClosesNativePanelAndLateResponseDoesNotWrite() async throws {
        let panel = PanelStub()
        let directory = try directory()
        panel.url = directory.appendingPathComponent("cancel.png")
        let task = Task {
            try await ImageSaveDestination.savePNG(Data([1]), request: .panel(suggestedName: "cancel.png"),
                                                  panelFactory: { panel }, activate: {})
        }
        await waitForBegin(panel)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Task cancellation must propagate")
        } catch is CancellationError {
        }
        XCTAssertTrue(panel.didCancel)
        XCTAssertTrue(panel.didOrderOut)
        panel.completion?(.OK)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
    }

    func testAlreadyCancelledSaveDoesNotCreatePanelOrCallPresentationCallback() async throws {
        var factoryCalls = 0
        var presentations = 0
        let task = Task {
            try await ImageSaveDestination.savePNG(Data([1]), request: .panel(suggestedName: "cancel.png"),
                                                  willPresentPanel: { presentations += 1 },
                                                  panelFactory: { factoryCalls += 1; return PanelStub() },
                                                  activate: { XCTFail("Cancelled save must not activate") })
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Task cancellation must propagate")
        } catch is CancellationError {
        }
        XCTAssertEqual(factoryCalls, 0)
        XCTAssertEqual(presentations, 0)
    }

    func testPartialHistoryFailureAndNoRecognizedTextMessagesRemainExplicit() {
        XCTAssertEqual(ImageOutputError.savedFileButHistoryFailed("reason").errorDescription,
                       "文件已保存，但历史收录失败：reason")
        XCTAssertEqual(ImageOutputError.noRecognizedText.errorDescription,
                       "没有识别到文字，请重新框选或继续编辑。")
    }
}
