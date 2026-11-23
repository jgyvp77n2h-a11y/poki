import Foundation
import Security
import SwiftUI

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

enum WebSearchStore {
    static let configKey = "webSearch.config.v1"
    static let keychainAccount = "webSearch.apiKey.v1"

    static var config: WebSearchConfig {
        guard let data = UserDefaults.standard.data(forKey: configKey),
              let value = try? JSONDecoder().decode(WebSearchConfig.self, from: data) else { return WebSearchConfig() }
        return value
    }

    static func save(_ config: WebSearchConfig) {
        let data = try? JSONEncoder().encode(config)
        UserDefaults.standard.set(data, forKey: configKey)
        ModelKeys.saved += 1
    }

    static var apiKey: String {
        guard let raw = try? Keychain.read(keychainAccount), let data = raw,
              let key = String(data: data, encoding: .utf8) else { return "" }
        return key
    }

    static func save(apiKey: String) {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.isEmpty {
            Keychain.delete(keychainAccount)
        } else {
            try? Keychain.write(Data(key.utf8), account: keychainAccount)
        }
        ModelKeys.saved += 1
    }

    static func save(_ config: WebSearchConfig, apiKey: String) {
        save(config)
        save(apiKey: apiKey)
    }

    static var isEnabled: Bool {
        !config.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

enum WebSearchExecutor {
    struct SearchError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func search(query: String) async throws -> String {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { throw SearchError(message: "web_search query is empty") }
        let config = WebSearchStore.config
        let key = WebSearchStore.apiKey
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

struct WebSearchSettingsView: View {
    @State private var config = WebSearchStore.config
    @State private var apiKey = WebSearchStore.apiKey
    @State private var headersText = ""
    @State private var paramsText = ""
    @State private var bodyText = ""
    @State private var busy = false
    @State private var result = ""
    @State private var resultFailed = false

    var body: some View {
        Form {
            Section {
                LabeledContent("状态", value: config.url.isEmpty ? "未启用" : "已启用")
                TextField("https://example.com/search", text: $config.url)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Picker("请求方法", selection: $config.method) {
                    Text("GET").tag("GET")
                    Text("POST").tag("POST")
                }
                TextField("查询参数名", text: $config.queryParam)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                Text("搜索服务")
            }

            Section {
                SecureField("API Key，不需要可留空", text: $apiKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Key Header", text: $config.keyHeader)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Header 前缀", text: $config.keyScheme)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Key 参数名", text: $config.keyParam)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                Text("可选 Key")
            } footer: {
                Text("Key 保存在 iPhone Keychain。Header 与参数名同时存在时，优先使用 Header。")
            }

            Section {
                TextField("结果 JSON 路径", text: $config.resultPath)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("标题字段，逗号分隔", text: Binding(
                    get: { config.titleKeys.joined(separator: ", ") },
                    set: { config.titleKeys = splitList($0) }))
                TextField("链接字段，逗号分隔", text: Binding(
                    get: { config.urlKeys.joined(separator: ", ") },
                    set: { config.urlKeys = splitList($0) }))
                TextField("摘要字段，逗号分隔", text: Binding(
                    get: { config.snippetKeys.joined(separator: ", ") },
                    set: { config.snippetKeys = splitList($0) }))
                TextField("结果条数", value: $config.topK, format: .number).keyboardType(.numberPad)
                TextField("超时秒数", value: $config.timeout, format: .number).keyboardType(.numberPad)
            } header: {
                Text("结果解析")
            }

            Section {
                TextEditor(text: $headersText).frame(minHeight: 86)
                TextEditor(text: $paramsText).frame(minHeight: 86)
                TextEditor(text: $bodyText).frame(minHeight: 86)
            } header: {
                Text("高级 JSON 参数")
            } footer: {
                Text("每个文本框都必须是 JSON 对象，例如 {\"Accept-Language\":\"zh-CN\"}；不需要可留空。")
            }

            Section {
                Button("保存") { Task { await save(andTest: false) } }
                Button("保存并测试") { Task { await save(andTest: true) } }
                if !result.isEmpty {
                    Text(result).foregroundStyle(resultFailed ? Color.red : Color.green)
                }
            }
        }
        .navigationTitle("联网搜索")
        .navigationBarTitleDisplayMode(.inline)
        .disabled(busy)
        .onAppear {
            headersText = jsonText(config.extraHeaders)
            paramsText = jsonText(config.extraParams)
            bodyText = jsonText(config.extraBody)
        }
    }

    private func save(andTest: Bool) async {
        busy = true
        defer { busy = false }
        do {
            config.method = config.method == "POST" ? "POST" : "GET"
            config.queryParam = config.queryParam.trimmedOr("q")
            config.topK = max(1, min(20, config.topK))
            config.timeout = max(1, min(60, config.timeout))
            config.extraHeaders = try parseObject(headersText)
            config.extraParams = try parseObject(paramsText)
            config.extraBody = try parseObject(bodyText)
            WebSearchStore.save(config, apiKey: apiKey)
            if andTest {
                result = try await WebSearchExecutor.search(query: "Qwen 是哪家公司开发的")
                resultFailed = false
            } else {
                result = "已保存，下一条消息立即生效。"
                resultFailed = false
            }
        } catch {
            result = error.localizedDescription
            resultFailed = true
        }
    }

    private func splitList(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == "," || $0 == "，" }).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
    }

    private func parseObject(_ text: String) throws -> [String: String] {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return [:] }
        let object = try JSONSerialization.jsonObject(with: Data(text.utf8))
        guard let dict = object as? [String: String] else { throw WebSearchExecutor.SearchError(message: "JSON 必须是字符串键值对象") }
        return dict
    }

    private func jsonText(_ object: [String: String]) -> String {
        guard !object.isEmpty, let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "" }
        return text
    }
}

private extension String {
    func trimmedOr(_ fallback: String) -> String {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? fallback : value
    }
}
