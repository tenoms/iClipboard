import AppKit
import Combine
import CoreGraphics
import Foundation

/// Image export and selection preferences; system permissions remain separate.
@MainActor
final class ImageToolsPreferences: ObservableObject {
    static let shared = ImageToolsPreferences()
    private static let directoryKey = "imageTools.defaultSaveDirectory"
    private static let detectionModeKey = "imageTools.captureDetectionMode"

    var detectionMode: CaptureDetectionMode {
        get {
            defaults.string(forKey: Self.detectionModeKey).flatMap(CaptureDetectionMode.init(rawValue:)) ?? .window
        }
        set {
            guard detectionMode != newValue else { return }
            objectWillChange.send()
            defaults.set(newValue.rawValue, forKey: Self.detectionModeKey)
        }
    }

    private let defaults: UserDefaults
    private let fileExists: (URL) -> Bool
    private let validateDirectory: (URL) throws -> Void
    private let timeZone: TimeZone

    init(defaults: UserDefaults = .standard,
         fileExists: @escaping (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) },
         validateDirectory: @escaping (URL) throws -> Void = ImageSaveDirectoryError.validate,
         timeZone: TimeZone = .current) {
        self.defaults = defaults
        self.fileExists = fileExists
        self.validateDirectory = validateDirectory
        self.timeZone = timeZone
    }

    /// Read on demand so every export uses the latest preference, not a cached folder.
    var defaultSaveDirectory: URL? {
        guard let path = defaults.string(forKey: Self.directoryKey), !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    func validatedDefaultSaveDirectory() throws -> URL? {
        guard let directory = defaultSaveDirectory else { return nil }
        try validateDirectory(directory)
        return directory
    }

    func setDefaultSaveDirectory(_ directory: URL?) throws {
        guard let directory else {
            restoreDefaultSaveDirectory()
            return
        }
        let normalizedDirectory = directory.standardizedFileURL
        try validateDirectory(normalizedDirectory)
        objectWillChange.send()
        defaults.set(normalizedDirectory.path, forKey: Self.directoryKey)
    }

    func restoreDefaultSaveDirectory() {
        objectWillChange.send()
        defaults.removeObject(forKey: Self.directoryKey)
    }

    @discardableResult
    func chooseDefaultSaveDirectory() throws -> Bool {
        try chooseDefaultSaveDirectory { initialDirectory in
            let panel = NSOpenPanel()
            panel.title = "选择图像默认保存目录"
            panel.prompt = "选择"
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = false
            panel.canCreateDirectories = true
            if let initialDirectory, (try? self.validateDirectory(initialDirectory)) != nil {
                panel.directoryURL = initialDirectory
            }
            return panel.runModal() == .OK ? panel.url : nil
        }
    }

    /// A cancelled picker never changes or clears the existing preference.
    @discardableResult
    func chooseDefaultSaveDirectory(using chooseDirectory: (URL?) -> URL?) throws -> Bool {
        guard let directory = chooseDirectory(defaultSaveDirectory) else { return false }
        try setDefaultSaveDirectory(directory)
        return true
    }

    /// The save request freezes this unsuffixed name; exclusive publication resolves collisions.
    /// Prechecking here for direct saves would turn a concurrent `_2` collision into `_2_2`.
    func rawFilename(at date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyMMdd_HHmmss"
        return "iclipboard_" + formatter.string(from: date) + ".png"
    }

    /// Retained for explicit save-panel suggestions and callers that need a collision preview.
    func suggestedFilename(at date: Date = Date()) -> String {
        let rawName = rawFilename(at: date)
        let stem = String(rawName.dropLast(4))
        var filename = rawName
        if let directory = defaultSaveDirectory {
            var suffix = 2
            while fileExists(directory.appendingPathComponent(filename)) {
                filename = "\(stem)_\(suffix).png"
                suffix += 1
            }
        }
        return filename
    }
}

enum ImageSaveDirectoryError: LocalizedError, Equatable {
    case unavailable(URL)
    case notDirectory(URL)
    case notWritable(URL)

    var errorDescription: String? {
        switch self {
        case let .unavailable(url):
            return "默认保存目录不可用（可能已移动、删除或离线）：\(url.path)"
        case let .notDirectory(url):
            return "默认保存位置不是文件夹：\(url.path)"
        case let .notWritable(url):
            return "默认保存目录为只读或没有写入权限：\(url.path)"
        }
    }

    static func validate(_ directory: URL) throws {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard directory.isFileURL,
              manager.fileExists(atPath: directory.path, isDirectory: &isDirectory) else {
            throw Self.unavailable(directory)
        }
        guard isDirectory.boolValue else { throw Self.notDirectory(directory) }
        let resources: URLResourceValues
        do {
            resources = try directory.resourceValues(forKeys: [.volumeIsReadOnlyKey])
        } catch {
            throw Self.unavailable(directory)
        }
        guard resources.volumeIsReadOnly != true,
              manager.isWritableFile(atPath: directory.path) else {
            throw Self.notWritable(directory)
        }
    }
}

/// This is a snapshot of macOS permission, never an app-owned enable switch.
@MainActor
final class ScreenCapturePermissionController: ObservableObject {
    @Published private(set) var hasAccess: Bool
    private let preflight: () -> Bool
    private let request: () -> Bool
    private let openSettings: () -> Void

    init(preflight: @escaping () -> Bool = { CGPreflightScreenCaptureAccess() },
         request: @escaping () -> Bool = { CGRequestScreenCaptureAccess() },
         openSettings: @escaping () -> Void = {
             guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else { return }
             NSWorkspace.shared.open(url)
         }) {
        self.preflight = preflight
        self.request = request
        self.openSettings = openSettings
        hasAccess = preflight()
    }

    func refresh() {
        hasAccess = preflight()
    }

    /// Called only by the user's toggle action. Revocation belongs to System Settings.
    func setAccessRequested(_ enabled: Bool) {
        refresh()
        if enabled {
            guard !hasAccess else { return }
            _ = request()
            refresh()
            if !hasAccess { openSettings() }
        } else if hasAccess {
            openSettings()
            refresh()
        }
    }
}
