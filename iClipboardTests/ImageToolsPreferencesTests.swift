import Foundation
import XCTest
@testable import iClipboard

@MainActor
final class ImageToolsPreferencesTests: XCTestCase {
    private final class CountingDefaults: UserDefaults {
        var directoryReads = 0

        override func string(forKey defaultName: String) -> String? {
            if defaultName == "imageTools.defaultSaveDirectory" { directoryReads += 1 }
            return super.string(forKey: defaultName)
        }
    }

    private func defaults() -> UserDefaults {
        let suite = "iClipboard.ImageToolsPreferencesTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testDetectionDefaultsToWindowAndInvalidStoredValueDoesNotRequestPermission() {
        let defaults = defaults()
        let preferences = ImageToolsPreferences(defaults: defaults)
        XCTAssertEqual(preferences.detectionMode, .window)
        XCTAssertNil(defaults.string(forKey: "imageTools.captureDetectionMode"))
        defaults.set("invalid", forKey: "imageTools.captureDetectionMode")
        XCTAssertEqual(preferences.detectionMode, .window)
        XCTAssertEqual(defaults.string(forKey: "imageTools.captureDetectionMode"), "invalid")
    }

    func testDetectionModesPersistWithoutChangingSaveDirectory() throws {
        let defaults = defaults()
        let preferences = ImageToolsPreferences(defaults: defaults)
        let path = try directory()
        try preferences.setDefaultSaveDirectory(path)
        for mode in CaptureDetectionMode.allCases {
            preferences.detectionMode = mode
            let restored = ImageToolsPreferences(defaults: defaults)
            XCTAssertEqual(restored.detectionMode, mode)
            XCTAssertEqual(restored.defaultSaveDirectory, path)
        }
    }

    func testUnconfiguredPreferenceLeavesSystemDefaultAndCreatesNothing() {
        let defaults = defaults()
        let preferences = ImageToolsPreferences(defaults: defaults,
                                                fileExists: { _ in XCTFail("No default folder to inspect"); return false },
                                                validateDirectory: { _ in XCTFail("No folder to validate") })
        XCTAssertNil(preferences.defaultSaveDirectory)
        XCTAssertNil(try preferences.validatedDefaultSaveDirectory())
        XCTAssertTrue(defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix("imageTools.") }.isEmpty)
        XCTAssertTrue(preferences.suggestedFilename(at: Date(timeIntervalSince1970: 0)).hasSuffix(".png"))
    }

    func testChosenDirectoryPersistsAndEachInstanceReadsLatestValue() throws {
        let defaults = defaults()
        let first = ImageToolsPreferences(defaults: defaults)
        let second = ImageToolsPreferences(defaults: defaults)
        let firstDirectory = try directory()
        let secondDirectory = try directory()
        try first.setDefaultSaveDirectory(firstDirectory)
        XCTAssertEqual(second.defaultSaveDirectory, firstDirectory)
        try second.setDefaultSaveDirectory(secondDirectory)
        XCTAssertEqual(first.defaultSaveDirectory, secondDirectory)
        XCTAssertEqual(try first.validatedDefaultSaveDirectory(), secondDirectory)
    }

    func testChoosingCancelDoesNotChangeExistingDirectory() throws {
        let preferences = ImageToolsPreferences(defaults: defaults())
        let original = try directory()
        try preferences.setDefaultSaveDirectory(original)
        let changed = try preferences.chooseDefaultSaveDirectory { initial in
            XCTAssertEqual(initial, original)
            return nil
        }
        XCTAssertFalse(changed)
        XCTAssertEqual(preferences.defaultSaveDirectory, original)
    }

    func testChoosingValidDirectoryStoresOnlyAfterValidation() throws {
        let preferences = ImageToolsPreferences(defaults: defaults())
        let selected = try directory()
        XCTAssertTrue(try preferences.chooseDefaultSaveDirectory { _ in selected })
        XCTAssertEqual(preferences.defaultSaveDirectory, selected)
        let missing = selected.appendingPathComponent("unavailable", isDirectory: true)
        XCTAssertThrowsError(try preferences.chooseDefaultSaveDirectory { _ in missing }) { error in
            XCTAssertEqual(error as? ImageSaveDirectoryError, .unavailable(missing))
        }
        XCTAssertEqual(preferences.defaultSaveDirectory, selected)
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
    }

    func testUnavailableDirectoryRemainsConfiguredAndReportsError() throws {
        let preferences = ImageToolsPreferences(defaults: defaults())
        let selected = try directory()
        try preferences.setDefaultSaveDirectory(selected)
        try FileManager.default.removeItem(at: selected)
        XCTAssertThrowsError(try preferences.validatedDefaultSaveDirectory()) { error in
            XCTAssertEqual(error as? ImageSaveDirectoryError, .unavailable(selected))
        }
        XCTAssertEqual(preferences.defaultSaveDirectory, selected)
        XCTAssertFalse(FileManager.default.fileExists(atPath: selected.path))
    }

    func testRegularFileAndReadOnlyDirectoryAreRejectedWithoutChangingPreference() throws {
        let selected = try directory()
        let file = selected.appendingPathComponent("not-a-directory")
        try Data("keep".utf8).write(to: file)
        let preferences = ImageToolsPreferences(defaults: defaults())
        XCTAssertThrowsError(try preferences.setDefaultSaveDirectory(file)) { error in
            XCTAssertEqual(error as? ImageSaveDirectoryError, .notDirectory(file))
        }
        XCTAssertNil(preferences.defaultSaveDirectory)

        let simulatedReadOnly = ImageToolsPreferences(defaults: defaults(), validateDirectory: { url in
            throw ImageSaveDirectoryError.notWritable(url)
        })
        XCTAssertThrowsError(try simulatedReadOnly.setDefaultSaveDirectory(selected)) { error in
            XCTAssertEqual(error as? ImageSaveDirectoryError, .notWritable(selected))
        }
        XCTAssertNil(simulatedReadOnly.defaultSaveDirectory)
        XCTAssertEqual(try Data(contentsOf: file), Data("keep".utf8))
    }

    func testRestoreDefaultClearsPreferenceWithoutDeletingDirectoryOrFiles() throws {
        let defaults = defaults()
        let preferences = ImageToolsPreferences(defaults: defaults)
        let selected = try directory()
        let file = selected.appendingPathComponent("existing.png")
        let data = Data([1, 2, 3])
        try data.write(to: file)
        try preferences.setDefaultSaveDirectory(selected)
        preferences.restoreDefaultSaveDirectory()
        XCTAssertNil(preferences.defaultSaveDirectory)
        XCTAssertNil(ImageToolsPreferences(defaults: defaults).defaultSaveDirectory)
        XCTAssertTrue(FileManager.default.fileExists(atPath: selected.path))
        XCTAssertEqual(try Data(contentsOf: file), data)
    }

    func testFilenameUsesFixedDateAndSameSecondCollisionSuffixWithoutDeletingFiles() throws {
        let selected = try directory()
        let preferences = ImageToolsPreferences(defaults: defaults(), timeZone: TimeZone(secondsFromGMT: 0)!)
        try preferences.setDefaultSaveDirectory(selected)
        let fixedDate = Date(timeIntervalSince1970: 1_704_164_645) // 2024-01-02 03:04:05 UTC
        let originalName = "iclipboard_240102_030405.png"
        XCTAssertEqual(preferences.suggestedFilename(at: fixedDate), originalName)
        let original = selected.appendingPathComponent(originalName)
        let second = selected.appendingPathComponent("iclipboard_240102_030405_2.png")
        let data = Data([137, 80, 78, 71])
        try data.write(to: original)
        XCTAssertEqual(preferences.suggestedFilename(at: fixedDate), second.lastPathComponent)
        try data.write(to: second)
        XCTAssertEqual(preferences.suggestedFilename(at: fixedDate), "iclipboard_240102_030405_3.png")
        XCTAssertEqual(try Data(contentsOf: original), data)
        XCTAssertEqual(try Data(contentsOf: second), data)
    }

    func testFilenameCollisionCheckUsesInjectedFileSystemAndLatestDirectory() throws {
        let first = URL(fileURLWithPath: "/virtual/first", isDirectory: true)
        let second = URL(fileURLWithPath: "/virtual/second", isDirectory: true)
        var inspected: [URL] = []
        let preferences = ImageToolsPreferences(defaults: defaults(), fileExists: { url in
            inspected.append(url)
            return url.deletingLastPathComponent() == first && !url.lastPathComponent.contains("_2.")
        }, validateDirectory: { _ in }, timeZone: TimeZone(secondsFromGMT: 0)!)
        let date = Date(timeIntervalSince1970: 0)
        try preferences.setDefaultSaveDirectory(first)
        XCTAssertEqual(preferences.suggestedFilename(at: date), "iclipboard_700101_000000_2.png")
        try preferences.setDefaultSaveDirectory(second)
        XCTAssertEqual(preferences.suggestedFilename(at: date), "iclipboard_700101_000000.png")
        XCTAssertEqual(inspected.last?.deletingLastPathComponent(), second)
    }

    func testRawFilenameUsesFrozenDateAndNeverInspectsDirectoryCollisions() throws {
        let preferences = ImageToolsPreferences(defaults: defaults(), fileExists: { _ in
            XCTFail("A raw request filename must not probe existing files")
            return true
        }, validateDirectory: { _ in }, timeZone: TimeZone(secondsFromGMT: 0)!)
        let date = Date(timeIntervalSince1970: 1_704_164_645)
        XCTAssertEqual(preferences.rawFilename(at: date), "iclipboard_240102_030405.png")
        try preferences.setDefaultSaveDirectory(URL(fileURLWithPath: "/virtual/configured", isDirectory: true))
        XCTAssertEqual(preferences.rawFilename(at: date), "iclipboard_240102_030405.png")
        XCTAssertEqual(preferences.rawFilename(at: date.addingTimeInterval(1)), "iclipboard_240102_030406.png")
    }

    func testSaveRequestReadsDirectoryOnceAndDoesNotValidateOrPreflightCollision() throws {
        let suite = "iClipboard.ImageToolsPreferencesTests." + UUID().uuidString
        let defaults = CountingDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let first = URL(fileURLWithPath: "/virtual/first", isDirectory: true)
        let second = URL(fileURLWithPath: "/virtual/second", isDirectory: true)
        var validations = 0
        let preferences = ImageToolsPreferences(defaults: defaults, fileExists: { _ in
            XCTFail("Request creation must not preflight a collision")
            return false
        }, validateDirectory: { _ in validations += 1 }, timeZone: TimeZone(secondsFromGMT: 0)!)
        try preferences.setDefaultSaveDirectory(first)
        let initialValidations = validations
        defaults.directoryReads = 0
        let firstRequest = ImageSaveDestination.request(preferences: preferences, date: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(defaults.directoryReads, 1)
        XCTAssertEqual(validations, initialValidations, "Directory validation belongs to the background write")
        try preferences.setDefaultSaveDirectory(second)
        XCTAssertEqual(firstRequest, .directory(first, filename: "iclipboard_700101_000000.png"))
        defaults.directoryReads = 0
        XCTAssertEqual(ImageSaveDestination.request(preferences: preferences, date: Date(timeIntervalSince1970: 1)),
                       .directory(second, filename: "iclipboard_700101_000001.png"))
        XCTAssertEqual(defaults.directoryReads, 1)
        preferences.restoreDefaultSaveDirectory()
        defaults.directoryReads = 0
        XCTAssertEqual(ImageSaveDestination.request(preferences: preferences, date: Date(timeIntervalSince1970: 0)),
                       .panel(suggestedName: "iclipboard_700101_000000.png"))
        XCTAssertEqual(defaults.directoryReads, 1)
    }

    func testPermissionRefreshNeverRequestsAccessOrOpensSettings() {
        var granted = false
        var requests = 0
        var settings = 0
        let permission = ScreenCapturePermissionController(preflight: { granted }, request: {
            requests += 1
            return true
        }, openSettings: { settings += 1 })
        XCTAssertFalse(permission.hasAccess)
        granted = true
        permission.refresh()
        XCTAssertTrue(permission.hasAccess)
        granted = false
        permission.refresh()
        XCTAssertFalse(permission.hasAccess)
        XCTAssertEqual(requests, 0)
        XCTAssertEqual(settings, 0)
    }

    func testPermissionEnableUsesPreflightRatherThanRequestReturnValue() {
        var requests = 0
        var settings = 0
        let permission = ScreenCapturePermissionController(preflight: { false }, request: {
            requests += 1
            return true // macOS can still require a restart before preflight becomes true.
        }, openSettings: { settings += 1 })
        permission.setAccessRequested(true)
        XCTAssertFalse(permission.hasAccess)
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(settings, 1)
    }

    func testPermissionRequestRefreshesNewGrantAndDoesNotOpenSettings() {
        var granted = false
        var requests = 0
        var settings = 0
        let permission = ScreenCapturePermissionController(preflight: { granted }, request: {
            requests += 1
            granted = true
            return true
        }, openSettings: { settings += 1 })
        permission.setAccessRequested(true)
        XCTAssertTrue(permission.hasAccess)
        permission.setAccessRequested(true)
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(settings, 0)
    }

    func testPermissionDisableOpensSettingsButKeepsActualGrantUntilRevoked() {
        var granted = true
        var requests = 0
        var settings = 0
        let permission = ScreenCapturePermissionController(preflight: { granted }, request: {
            requests += 1
            return false
        }, openSettings: { settings += 1 })
        permission.setAccessRequested(false)
        XCTAssertTrue(permission.hasAccess)
        XCTAssertEqual(settings, 1)
        XCTAssertEqual(requests, 0)
        granted = false
        permission.refresh()
        XCTAssertFalse(permission.hasAccess)
        permission.setAccessRequested(false)
        XCTAssertEqual(settings, 1)
    }
}
