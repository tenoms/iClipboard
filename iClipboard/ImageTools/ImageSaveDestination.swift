import AppKit
import UniformTypeIdentifiers

/// The native save panel retains replacement confirmation; tests can supply a panel without UI.
@MainActor
protocol ImageSavePanelPresenting: AnyObject {
    var allowedContentTypes: [UTType] { get set }
    var nameFieldStringValue: String { get set }
    var canCreateDirectories: Bool { get set }
    var directoryURL: URL? { get set }
    var warningMessage: String { get set }
    var url: URL? { get }
    func begin(completionHandler handler: @escaping (NSApplication.ModalResponse) -> Void)
    func cancel(_ sender: Any?)
    func orderOut(_ sender: Any?)
}

extension NSSavePanel: ImageSavePanelPresenting {
    var warningMessage: String {
        get { message ?? "" }
        set { message = newValue }
    }
}

@MainActor
private final class ImageSavePanelRequest {
    let panel: ImageSavePanelPresenting
    private let activate: () -> Void
    private var continuation: CheckedContinuation<URL?, Error>?
    private var finished = false

    init(panel: ImageSavePanelPresenting, activate: @escaping () -> Void) {
        self.panel = panel
        self.activate = activate
    }

    func choose(name: String, initialDirectory: URL?, warning: String,
                willPresentPanel: @escaping @MainActor () -> Void) async throws -> URL? {
        try Task.checkCancellation()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = name
        panel.canCreateDirectories = true
        panel.directoryURL = initialDirectory
        panel.warningMessage = warning
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                guard !finished, !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                self.continuation = continuation
                willPresentPanel()
                guard !Task.isCancelled else {
                    finish(.failure(CancellationError()))
                    return
                }
                activate()
                panel.begin { [weak self] response in
                    guard let self else { return }
                    guard response == .OK else {
                        self.finish(.success(nil))
                        return
                    }
                    guard let url = self.panel.url else {
                        self.finish(.failure(ImageOutputError.missingSaveURL))
                        return
                    }
                    self.finish(.success(url))
                }
            }
        }, onCancel: {
            Task { @MainActor [weak self] in self?.cancel() }
        })
    }

    private func finish(_ result: Result<URL?, Error>) {
        guard !finished else { return }
        finished = true
        let continuation = self.continuation
        self.continuation = nil
        continuation?.resume(with: result)
    }

    func cancel() {
        guard !finished else { return }
        finish(.failure(CancellationError()))
        panel.cancel(nil)
        panel.orderOut(nil)
    }
}

/// Frozen before any suspension; subsequent preference changes affect only the next action.
enum ImageSaveRequest: Equatable, Sendable {
    case directory(URL, filename: String)
    case panel(suggestedName: String)
}

@MainActor
enum ImageSaveDestination {
    static func request(preferences: ImageToolsPreferences, date: Date = Date()) -> ImageSaveRequest {
        let directory = preferences.defaultSaveDirectory
        let filename = preferences.rawFilename(at: date)
        if let directory { return .directory(directory, filename: filename) }
        return .panel(suggestedName: filename)
    }

    /// Only the panel branch activates the app or invokes the injected URL chooser.
    /// A configured directory never falls back to a panel, including when validation fails.
    static func savePNG(_ data: Data, request: ImageSaveRequest,
                        chooseURL: (@MainActor (String) async throws -> URL?)? = nil,
                        willPresentPanel: @escaping @MainActor () -> Void = {}) async throws -> URL? {
        try await savePNG(data, request: request, chooseURL: chooseURL,
                          willPresentPanel: willPresentPanel, panelFactory: { NSSavePanel() },
                          activate: { NSApp.activate(ignoringOtherApps: true) })
    }

    /// Lazy panel factory lets tests prove direct saves neither create a panel nor activate the app.
    static func savePNG(_ data: Data, request: ImageSaveRequest,
                        chooseURL: (@MainActor (String) async throws -> URL?)? = nil,
                        willPresentPanel: @escaping @MainActor () -> Void = {},
                        panelFactory: @MainActor () -> ImageSavePanelPresenting,
                        activate: @escaping @MainActor () -> Void) async throws -> URL? {
        try Task.checkCancellation()
        switch request {
        case let .directory(directory, filename):
            return try await AtomicPNGWriter.write(data, directory: directory, filename: filename)
        case let .panel(suggestedName):
            let selectedURL: URL?
            if let chooseURL {
                willPresentPanel()
                try Task.checkCancellation()
                selectedURL = try await chooseURL(suggestedName)
            } else {
                let panelRequest = ImageSavePanelRequest(panel: panelFactory(), activate: activate)
                defer { withExtendedLifetime(panelRequest) {} }
                selectedURL = try await panelRequest.choose(name: suggestedName, initialDirectory: nil,
                                                            warning: "", willPresentPanel: willPresentPanel)
            }
            try Task.checkCancellation()
            guard let selectedURL else { return nil }
            // Native NSSavePanel (or its injected chooser) has already confirmed replacement.
            return try await AtomicPNGWriter.replace(data, at: selectedURL)
        }
    }

    /// Explicit save-panel helper, retained for Save As and existing panel lifecycle tests.
    static func choose(name: String, preferences: ImageToolsPreferences) async throws -> URL? {
        try Task.checkCancellation()
        return try await choose(name: name, preferences: preferences, panel: NSSavePanel())
    }

    /// Injectable panel seam; the request remains alive until completion or owner cancellation.
    static func choose(name: String, preferences: ImageToolsPreferences,
                       panel: ImageSavePanelPresenting,
                       activate: @escaping @MainActor () -> Void = { NSApp.activate(ignoringOtherApps: true) }) async throws -> URL? {
        let initialDirectory: URL?
        let warning: String
        do {
            initialDirectory = try preferences.validatedDefaultSaveDirectory()
            warning = ""
        } catch {
            // Explicit Save As may choose an alternative, without changing the stored preference.
            initialDirectory = nil
            warning = error.localizedDescription + "\n请选择其他可写目录后确认保存，或取消。"
        }
        let request = ImageSavePanelRequest(panel: panel, activate: activate)
        defer { withExtendedLifetime(request) {} }
        return try await request.choose(name: name, initialDirectory: initialDirectory,
                                        warning: warning, willPresentPanel: {})
    }
}

enum ImageOutputError: LocalizedError {
    case savedFileButHistoryFailed(String)
    case missingSaveURL
    case noRecognizedText

    var errorDescription: String? {
        switch self {
        case let .savedFileButHistoryFailed(message):
            return "文件已保存，但历史收录失败：\(message)"
        case .missingSaveURL:
            return "未能取得保存位置，请重新选择保存文件。"
        case .noRecognizedText:
            return "没有识别到文字，请重新框选或继续编辑。"
        }
    }
}
