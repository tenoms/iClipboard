import Foundation

protocol TranslationServicing {
    func translateStreaming(
        text: String,
        provider: TranslationProvider,
        sessionID: String,
        onUpdate: @escaping @Sendable (TranslationStreamUpdate) async -> Void
    ) async throws -> TranslationResult
}

final class DoubaoTranslationClient: TranslationServicing {
    private let session: URLSession
    private let detectLanguageURL = URL(
        string: "https://www.doubao.com/samantha/plugin/detect_lang"
    )!
    private let translateURL = URL(
        string: "https://www.doubao.com/samantha/plugin/stream_article_translate"
    )!

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpCookieStorage = nil
            configuration.urlCache = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            self.session = URLSession(configuration: configuration)
        }
    }

    func translate(
        text: String,
        provider: TranslationProvider,
        sessionID: String
    ) async throws -> TranslationResult {
        try await translateStreaming(
            text: text,
            provider: provider,
            sessionID: sessionID,
            onUpdate: { _ in }
        )
    }

    func translateStreaming(
        text: String,
        provider: TranslationProvider,
        sessionID: String,
        onUpdate: @escaping @Sendable (TranslationStreamUpdate) async -> Void
    ) async throws -> TranslationResult {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { throw TranslationFeatureError.emptySelection }

        let detectedLanguage = try await detectLanguage(
            segments: [normalized],
            sessionID: sessionID
        )
        let targetLanguage = detectedLanguage.lowercased().hasPrefix("zh") ? "en" : "zh"
        await onUpdate(.detected(sourceLanguage: detectedLanguage, targetLanguage: targetLanguage))

        let translated = try await streamTranslation(
            segments: [normalized],
            targetLanguage: targetLanguage,
            provider: provider,
            sessionID: sessionID,
            onPartialText: { await onUpdate(.partialText($0)) }
        )

        guard let first = translated.first else {
            throw TranslationFeatureError.invalidResponse
        }

        return TranslationResult(
            sourceText: normalized,
            translatedText: first,
            detectedLanguage: detectedLanguage,
            targetLanguage: targetLanguage,
            provider: provider
        )
    }

    func detectLanguage(segments: [String], sessionID: String) async throws -> String {
        try validate(segments: segments)
        let body = DetectLanguageRequest(rawText: segments)
        let data = try await performJSONRequest(
            url: detectLanguageURL,
            body: body,
            sessionID: sessionID
        )
        let response = try JSONDecoder().decode(DetectLanguageResponse.self, from: data)
        guard response.code == 0 else {
            throw TranslationFeatureError.server(code: response.code, message: response.msg)
        }
        guard let language = response.data?.infos.first?.langCode, !language.isEmpty else {
            throw TranslationFeatureError.invalidResponse
        }
        return language
    }

    func translate(
        segments: [String],
        targetLanguage: String,
        provider: TranslationProvider,
        sessionID: String
    ) async throws -> [String] {
        try validate(segments: segments)

        let payload = TranslationRequest(
            rawText: segments,
            targetLanguage: targetLanguage,
            translateService: provider.rawValue,
            scene: 20
        )
        var request = try makeRequest(url: translateURL, sessionID: sessionID)
        request.httpBody = try JSONEncoder().encode(payload)

        let (data, response) = try await session.data(for: request)
        try validateHTTPResponse(response)

        guard let stream = String(data: data, encoding: .utf8) else {
            throw TranslationFeatureError.invalidResponse
        }

        var results: [Int: String] = [:]
        var lastServerError: TranslationFeatureError?

        for line in stream.split(whereSeparator: \.isNewline) {
            guard line.hasPrefix("data:") else { continue }
            let json = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard !json.isEmpty, let eventData = json.data(using: .utf8) else { continue }

            if let envelope = try? JSONDecoder().decode(TranslationEnvelope.self, from: eventData) {
                if envelope.code != 0 {
                    lastServerError = .server(code: envelope.code, message: envelope.msg)
                }
                envelope.data?.items.forEach { item in
                    if !item.result.isEmpty {
                        results[item.index] = item.result
                    }
                }
            }
        }

        if let lastServerError { throw lastServerError }
        guard results.count == segments.count else {
            throw TranslationFeatureError.invalidResponse
        }
        return segments.indices.compactMap { results[$0] }
    }

    private func streamTranslation(
        segments: [String],
        targetLanguage: String,
        provider: TranslationProvider,
        sessionID: String,
        onPartialText: @escaping (String) async -> Void
    ) async throws -> [String] {
        try validate(segments: segments)

        let payload = TranslationRequest(
            rawText: segments,
            targetLanguage: targetLanguage,
            translateService: provider.rawValue,
            scene: 20
        )
        var request = try makeRequest(url: translateURL, sessionID: sessionID)
        request.httpBody = try JSONEncoder().encode(payload)

        let (bytes, response) = try await session.bytes(for: request)
        try validateHTTPResponse(response)

        let contentType = (response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Content-Type") ?? ""
        if !contentType.lowercased().contains("text/event-stream") {
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
            }
            if let error = try? JSONDecoder().decode(BasicServerResponse.self, from: data) {
                throw TranslationFeatureError.server(code: error.code, message: error.msg)
            }
            throw TranslationFeatureError.invalidResponse
        }

        var results: [Int: String] = [:]
        var lastServerError: TranslationFeatureError?

        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data:") else { continue }
            let json = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard !json.isEmpty, let eventData = json.data(using: .utf8) else { continue }

            if let envelope = try? JSONDecoder().decode(TranslationEnvelope.self, from: eventData) {
                if envelope.code != 0 {
                    lastServerError = .server(code: envelope.code, message: envelope.msg)
                }
                for item in envelope.data?.items ?? [] {
                    if item.result.isEmpty { continue }
                    let previous = results[item.index] ?? ""
                    let updated: String
                    if item.result.hasPrefix(previous) || previous.isEmpty {
                        updated = item.result
                    } else {
                        // Some backends send deltas while others send the full
                        // translated segment on every SSE event.
                        updated = previous + item.result
                    }
                    results[item.index] = updated
                    if item.index == 0 {
                        await onPartialText(updated)
                    }
                }
            }
        }

        if let lastServerError { throw lastServerError }
        guard results.count == segments.count else {
            throw TranslationFeatureError.invalidResponse
        }
        return segments.indices.compactMap { results[$0] }
    }

    private func performJSONRequest<Body: Encodable>(
        url: URL,
        body: Body,
        sessionID: String
    ) async throws -> Data {
        var request = try makeRequest(url: url, sessionID: sessionID)
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await session.data(for: request)
        try validateHTTPResponse(response)
        return data
    }

    private func makeRequest(url: URL, sessionID: String) throws -> URLRequest {
        guard !sessionID.isEmpty,
              !sessionID.contains(";"),
              !sessionID.contains("\n"),
              !sessionID.contains("\r") else {
            throw TranslationFeatureError.invalidSessionID
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("sessionid=\(sessionID)", forHTTPHeaderField: "Cookie")
        return request
    }

    private func validate(segments: [String]) throws {
        guard !segments.isEmpty else { throw TranslationFeatureError.emptySelection }
        guard segments.count <= 100 else { throw TranslationFeatureError.tooManySegments }
        guard segments.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw TranslationFeatureError.emptySelection
        }
    }

    private func validateHTTPResponse(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw TranslationFeatureError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw TranslationFeatureError.transport("网络请求失败（HTTP \(http.statusCode)）")
        }
    }
}

private struct DetectLanguageRequest: Encodable {
    let rawText: [String]

    enum CodingKeys: String, CodingKey {
        case rawText = "raw_text"
    }
}

private struct DetectLanguageResponse: Decodable {
    let code: Int
    let msg: String
    let data: DataContainer?

    struct DataContainer: Decodable {
        let infos: [LanguageInfo]
    }

    struct LanguageInfo: Decodable {
        let langCode: String

        enum CodingKeys: String, CodingKey {
            case langCode = "lang_code"
        }
    }
}

private struct TranslationRequest: Encodable {
    let rawText: [String]
    let targetLanguage: String
    let translateService: String
    let scene: Int

    enum CodingKeys: String, CodingKey {
        case rawText = "raw_text"
        case targetLanguage = "target_lang"
        case translateService = "translate_service"
        case scene
    }
}

private struct TranslationEnvelope: Decodable {
    let code: Int
    let msg: String
    let data: DataContainer?

    struct DataContainer: Decodable {
        let items: [TranslationItem]
    }

    struct TranslationItem: Decodable {
        let result: String
        let detectedLanguage: String
        let index: Int

        enum CodingKeys: String, CodingKey {
            case result = "res"
            case detectedLanguage = "detect_lang"
            case index
        }
    }
}

private struct BasicServerResponse: Decodable {
    let code: Int
    let msg: String
}
