import AppKit

enum ScreenCaptureAction {
    case copyImage(ToolImage)
    case saveImage(ToolImage, willPresentPanel: @MainActor () -> Void = {})
    case pinImage(ToolImage, CGRect)
    case copyText(String)
    case copyRecognizedText(@MainActor () async throws -> String)

    var endsCapture: Bool {
        switch self {
        case .copyText: return false
        case .copyImage, .saveImage, .pinImage, .copyRecognizedText: return true
        }
    }

}

enum ScreenCaptureCurrentAction { case pin, copyRecognizedText }

enum ScreenCaptureActionOutcome: Equatable {
    case completed
    case cancelled
}

typealias ScreenCaptureActionHandler = @MainActor (ScreenCaptureAction) async throws -> ScreenCaptureActionOutcome
