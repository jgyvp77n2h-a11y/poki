import Foundation

/// One search endpoint as the owner describes it: where it is, how the query travels, and which fields
/// of its JSON hold a title, a link and a snippet.
struct WebSearchConfig: Codable, Equatable {
    var url: String = ""
    var method: String = "GET"
    var queryParam: String = "q"
    var keyParam: String = ""
    var keyHeader: String = ""
    var keyScheme: String = "Bearer"
    var extraParams: [String: String] = [:]
    var extraHeaders: [String: String] = [:]
    var extraBody: [String: String] = [:]
    var resultPath: String = ""
    var titleKeys: [String] = ["title", "name"]
    var urlKeys: [String] = ["url", "link", "href"]
    var snippetKeys: [String] = ["content", "snippet", "description", "summary"]
    var topK: Int = 5
    var timeout: Int = 20
}

/// Runs one search on this iPhone with the preset the owner is using now. Reads the preset at call time,
/// so a switch in the composer applies to the next message without restarting anything.
enum WebSearchExecutor {
    struct SearchError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func search(query: String) async throws -> String {
        guard WebSearchStore.isEnabled else { throw SearchError(message: "web_search is off: no preset selected") }
        return try await search(query: query, config: WebSearchStore.config, key: WebSearchStore.apiKey)
    }

    /// Runs a search with the given endpoint, so the editor can test the preset it is holding rather than
    /// whichever one the chat has selected.
    static func search(query: String, config: WebSearchConfig, key: String) async throws -> String {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { throw SearchError(message: "web_search query is empty") }
        let baseURLText = config.url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let baseURL = URL(string: baseURLText) else { throw SearchError(message: "Invalid web_search URL") }

        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        var queryItems = components?.queryItems ?? []
        for (name, value) in config.extraParams {
            queryItems.append(URLQueryItem(name: name, value: value))
        }
        let usesHeaderKey = !config.keyHeader.isEmpty && !key.isEmpty
        if config.method == "GET", !key.isEmpty, !config.keyParam.isEmpty, !usesHeaderKey {
            queryItems.append(URLQueryItem(name: config.keyParam, value: key))
        }
        queryItems.append(URLQueryItem(name: config.queryParam, value: query))
        components?.queryItems = queryItems
        guard let finalURL = components?.url else { throw SearchError(message: "Cannot build web_search URL") }

        var request = URLRequest(url: finalURL)
        request.httpMethod = config.method
        request.cachePolicy = .reloadIgnoringLocalCacheData
        for (name, value) in config.extraHeaders {
            request.setValue(value, forHTTPHeaderField: name)
        }
        if !key.isEmpty, !config.keyHeader.isEmpty {
            let scheme = config.keyScheme.trimmingCharacters(in: .whitespacesAndNewlines)
            request.setValue(scheme.isEmpty ? key : "\(scheme) \(key)", forHTTPHeaderField: config.keyHeader)
        }

        if config.method == "POST" {
            var body = config.extraBody
            if !key.isEmpty, !config.keyParam.isEmpty, !usesHeaderKey {
                body[config.keyParam] = key
            }
            body[config.queryParam] = query
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.timeoutIntervalForRequest = TimeInterval(max(1, config.timeout))
        sessionConfig.timeoutIntervalForResource = TimeInterval(max(1, config.timeout) + 5)
        let session = URLSession(configuration: sessionConfig)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SearchError(message: "web_search received a non-HTTP response") }
        guard (200..<300).contains(http.statusCode) else { throw SearchError(message: "web_search HTTP \(http.statusCode)") }

        let json: Any
        do {
            json = try JSONSerialization.jsonObject(with: data)
        } catch {
            return String(data: data, encoding: .utf8) ?? "web_search returned unreadable data"
        }
        let root = value(at: config.resultPath, in: json)
        let items: [Any]
        if let array = root as? [Any] {
            items = array
        } else if let object = root {
            items = [object]
        } else {
            items = []
        }

        let topK = max(1, min(20, config.topK))
        var output: [String] = []
        for item in items.prefix(topK) {
            if let text = item as? String {
                if !text.isEmpty { output.append(text) }
            } else if let object = item as? [String: Any] {
                let title = firstScalar(object, keys: config.titleKeys)
                let link = firstScalar(object, keys: config.urlKeys)
                let snippet = firstScalar(object, keys: config.snippetKeys)
                let line = [title, link, snippet].filter { !$0.isEmpty }.joined(separator: "\n")
                if !line.isEmpty { output.append(line) }
            }
        }
        if let result = output.joined(separator: "\n\n").nilIfEmpty { return result }
        let fallback = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        return fallback.flatMap { String(data: $0, encoding: .utf8) } ?? "web_search returned no usable fields"
    }

    private static func value(at path: String, in root: Any) -> Any? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return root }
        var current = root
        for part in trimmed.split(separator: ".") {
            let key = String(part)
            if let array = current as? [Any] {
                guard let index = Int(key), array.indices.contains(index) else { return nil }
                current = array[index]
            } else if let object = current as? [String: Any] {
                guard let value = object[key], !(value is NSNull) else { return nil }
                current = value
            } else {
                return nil
            }
        }
        return current
    }

    private static func firstScalar(_ object: [String: Any], keys: [String]) -> String {
        for key in keys {
            if let value = object[key] as? String, !value.isEmpty {
                return value
            }
            if let number = object[key] as? NSNumber {
                return number.stringValue
            }
        }
        return ""
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
