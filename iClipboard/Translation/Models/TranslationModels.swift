import AppKit
import Foundation

enum TranslationProvider: String, CaseIterable, Codable, Identifiable {
    case volcano = "0"
    case doubaoAI = "1"
    case microsoft = "3"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .volcano: return "火山引擎"
        case .doubaoAI: return "豆包 AI"
        case .microsoft: return "微软"
        }
    }

    var shortTitle: String {
        switch self {
        case .volcano: return "火山"
        case .doubaoAI: return "豆包 AI"
        case .microsoft: return "微软"
        }
    }

    var symbolName: String {
        switch self {
        case .volcano: return "flame.fill"
        case .doubaoAI: return "sparkles"
        case .microsoft: return "square.grid.2x2.fill"
        }
    }
}

struct SelectedTextContext: Equatable {
    let text: String
    let anchorRect: CGRect
    let cursorPoint: CGPoint
    let sourceApplicationName: String
    let sourceBundleIdentifier: String?
}

struct TranslationResult: Equatable {
    let sourceText: String
    let translatedText: String
    let detectedLanguage: String
    let targetLanguage: String
    let provider: TranslationProvider

    var directionLabel: String {
        targetLanguage == "en" ? "中文 → English" : "自动检测 → 中文"
    }
}

enum TranslationStreamUpdate: Equatable {
    case detected(sourceLanguage: String, targetLanguage: String)
    case partialText(String)
}

enum TranslationFeatureError: LocalizedError {
    case accessibilityPermissionRequired
    case missingSessionID
    case invalidSessionID
    case emptySelection
    case tooManySegments
    case invalidResponse
    case server(code: Int, message: String)
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .accessibilityPermissionRequired:
            return "需要辅助功能权限才能读取其他应用中的选中文字"
        case .missingSessionID:
            return "请先在设置中配置豆包 sessionid"
        case .invalidSessionID:
            return "sessionid 格式无效，请重新检查"
        case .emptySelection:
            return "没有可翻译的文本"
        case .tooManySegments:
            return "单次最多翻译 100 段文本"
        case .invalidResponse:
            return "翻译服务返回了无法识别的数据"
        case let .server(code, message):
            return message.isEmpty ? "翻译服务错误（\(code)）" : message
        case let .transport(message):
            return message
        }
    }
}
