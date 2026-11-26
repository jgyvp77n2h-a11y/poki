import Foundation
import SwiftUI

/// One saved search endpoint, as the owner names it. The API key lives in the Keychain under the preset's
/// id, so a preset carries its own credential and switching never mixes two services up.
struct WebSearchPreset: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var config: WebSearchConfig

    init(id: String = UUID().uuidString, name: String, config: WebSearchConfig = WebSearchConfig()) {
        self.id = id
        self.name = name
        self.config = config
    }

    /// What the owner reads on a row and on the composer's button.
    var title: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return host.isEmpty ? "未命名预设" : host
    }

    var host: String {
        let text = config.url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "" }
        let parts = URLComponents(string: text) ?? URLComponents(string: "http://" + text)
        return parts?.host ?? text
    }

    /// A preset answers searches only once it names an address.
    var isConfigured: Bool {
        !config.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The second line of a row: where it searches, and the path when it has one.
    var detail: String {
        guard isConfigured else { return "还没填地址" }
        let parts = URLComponents(string: config.url.trimmingCharacters(in: .whitespacesAndNewlines))
        let path = parts?.path ?? ""
        return host + (path.isEmpty || path == "/" ? "" : path)
    }
}

/// The saved presets and the one in use. Switching writes the selection and posts `ModelKeys.changed`, so
/// every view that reads it redraws and the next search uses the new preset, with no restart.
enum WebSearchPresets {
    static let presetsKey = "webSearch.presets.v1"
    static let selectedKey = "webSearch.selected.v1"
    static let keyAccountPrefix = "webSearch.apiKey.v1."
    private static let migratedKey = "webSearch.migrated.v1"

    /// The single endpoint a build before presets kept.
    private static let legacyConfigKey = "webSearch.config.v1"
    private static let legacyKeyAccount = "webSearch.apiKey.v1"

    static var all: [WebSearchPreset] {
        migrateLegacyIfNeeded()
        return read()
    }

    static func read() -> [WebSearchPreset] {
        guard let data = UserDefaults.standard.data(forKey: presetsKey),
              let list = try? JSONDecoder().decode([WebSearchPreset].self, from: data) else { return [] }
        return list
    }

    static func replace(_ list: [WebSearchPreset]) {
        UserDefaults.standard.set(try? JSONEncoder().encode(list), forKey: presetsKey)
        // A preset removed while it was in use leaves nothing selected.
        if let selected = selectedID, !list.contains(where: { $0.id == selected }) {
            choose(nil, bump: false)
        }
        bump()
    }

    static func add(_ preset: WebSearchPreset) {
        var list = read()
        list.append(preset)
        replace(list)
    }

    static func update(_ preset: WebSearchPreset) {
        var list = read()
        guard let index = list.firstIndex(where: { $0.id == preset.id }) else { return }
        list[index] = preset
        replace(list)
    }

    static func delete(_ id: String) {
        var list = read()
        list.removeAll { $0.id == id }
        Keychain.delete(keyAccountPrefix + id)
        replace(list)
    }

    /// The preset the chat uses now, or nil when search is off.
    static var selectedID: String? {
        migrateLegacyIfNeeded()
        return UserDefaults.standard.string(forKey: selectedKey)
    }

    static func choose(_ id: String?) {
        choose(id, bump: true)
    }

    private static func choose(_ id: String?, bump: Bool) {
        UserDefaults.standard.set(id, forKey: selectedKey)
        if bump { self.bump() }
    }

    /// A selected preset that still names an address.
    static var current: WebSearchPreset? {
        guard let id = selectedID else { return nil }
        guard let preset = read().first(where: { $0.id == id }), preset.isConfigured else { return nil }
        return preset
    }

    /// A name no other preset has, so two rows never read the same.
    static func unusedName(in list: [WebSearchPreset]) -> String {
        let taken = Set(list.map(\.name))
        var index = list.count + 1
        while taken.contains("预设 \(index)") { index += 1 }
        return "预设 \(index)"
    }

    static func apiKey(for id: String) -> String {
        guard let data = try? Keychain.read(keyAccountPrefix + id),
              let key = String(data: data, encoding: .utf8) else { return "" }
        return key
    }

    static func saveKey(_ key: String, for id: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            Keychain.delete(keyAccountPrefix + id)
        } else {
            try? Keychain.write(Data(trimmed.utf8), account: keyAccountPrefix + id)
        }
        bump()
    }

    /// The one endpoint an earlier build kept becomes the first preset, key and all.
    private static func migrateLegacyIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: migratedKey) else { return }
        UserDefaults.standard.set(true, forKey: migratedKey)
        guard let data = UserDefaults.standard.data(forKey: legacyConfigKey),
              let config = try? JSONDecoder().decode(WebSearchConfig.self, from: data),
              !config.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        var preset = WebSearchPreset(name: config.url, config: config)
        preset.name = preset.host.isEmpty ? "默认" : preset.host
        var list = read()
        guard !list.contains(where: { $0.config.url == config.url }) else { return }
        list.append(preset)
        UserDefaults.standard.set(try? JSONEncoder().encode(list), forKey: presetsKey)
        if let keyData = try? Keychain.read(legacyKeyAccount),
           let key = String(data: keyData, encoding: .utf8), !key.isEmpty {
            try? Keychain.write(Data(key.utf8), account: keyAccountPrefix + preset.id)
        }
        UserDefaults.standard.set(preset.id, forKey: selectedKey)
    }

    private static func bump() {
        ModelKeys.saved += 1
    }
}

/// What the harness and the executor read: the preset in use, resolved at call time.
enum WebSearchStore {
    static var isEnabled: Bool { WebSearchPresets.current != nil }

    static var config: WebSearchConfig { WebSearchPresets.current?.config ?? WebSearchConfig() }

    static var apiKey: String {
        guard let preset = WebSearchPresets.current else { return "" }
        return WebSearchPresets.apiKey(for: preset.id)
    }

    /// The name on the composer's button, "关闭" when search is off.
    static var summary: String { WebSearchPresets.current?.title ?? "关闭" }
}

/// Settings' search page: the preset in use on top, the saved ones below. Tapping a preset switches it
/// at once; a row opens it for editing.
struct WebSearchSettingsView: View {
    @State private var presets = WebSearchPresets.read()
    @State private var selected = WebSearchPresets.selectedID
    @State private var editing: WebSearchPreset?
    @State private var confirmingDelete: WebSearchPreset?

    var body: some View {
        List {
            Section {
                Button { switchTo(nil) } label: {
                    presetRow(name: "关闭", detail: "下一条消息不提供 web_search", selected: selected == nil)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("webSearch.off")

                ForEach(presets) { preset in
                    Button { switchTo(preset.id) } label: {
                        presetRow(name: preset.title, detail: preset.detail, selected: selected == preset.id)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("webSearch.preset.\(preset.id)")
                }
            } header: {
                Text("当前使用")
            } footer: {
                Text("点一行就切换，下一条消息立即生效；与切换模型一样，不用重启。")
            }

            Section {
                ForEach(presets) { preset in
                    NavigationLink {
                        WebSearchPresetEditor(preset: preset) { reload() }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: preset.title)
                            Text(verbatim: preset.detail)
                                .font(.caption)
                                .foregroundStyle(Color(.secondaryLabel))
                        }
                    }
                    .swipeActions(edge: .trailing) {
                        Button("删除", role: .destructive) { confirmingDelete = preset }
                    }
                }
                Button("新建预设", systemImage: "plus") { create() }
            } header: {
                Text("已保存的预设")
            } footer: {
                Text("每个预设各存一份 Key，保存在 iPhone Keychain，不进入模型上下文。")
            }
        }
        .navigationTitle("联网搜索")
        .navigationBarTitleDisplayMode(.inline)
        .onReceive(NotificationCenter.default.publisher(for: ModelKeys.changed)) { _ in reload() }
        .sheet(item: $editing) { preset in
            NavigationStack {
                WebSearchPresetEditor(preset: preset) { reload() }
            }
        }
        .confirmationDialog("删除这个预设？", isPresented: Binding(
            get: { confirmingDelete != nil },
            set: { if !$0 { confirmingDelete = nil } }
        ), presenting: confirmingDelete) { preset in
            Button("删除 \(preset.title)", role: .destructive) { delete(preset) }
        }
    }

    private func presetRow(name: String, detail: String, selected: Bool) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: name).foregroundStyle(Color(.label))
                Text(verbatim: detail).font(.caption).foregroundStyle(Color(.secondaryLabel))
            }
            Spacer(minLength: 8)
            Image(systemName: "checkmark")
                .font(.body.weight(.semibold))
                .foregroundStyle(Tint.blueText)
                .opacity(selected ? 1 : 0)
                .accessibilityHidden(true)
        }
        .contentShape(.rect)
    }

    private func switchTo(_ id: String?) {
        selected = id
        WebSearchPresets.choose(id)
    }

    private func create() {
        let preset = WebSearchPreset(name: WebSearchPresets.unusedName(in: presets))
        WebSearchPresets.add(preset)
        reload()
        editing = preset
    }

    private func delete(_ preset: WebSearchPreset) {
        WebSearchPresets.delete(preset.id)
        confirmingDelete = nil
        reload()
    }

    private func reload() {
        presets = WebSearchPresets.read()
        selected = WebSearchPresets.selectedID
    }
}

/// One preset's form: its name, where it searches, the optional key, and how its JSON is read.
struct WebSearchPresetEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var preset: WebSearchPreset
    @State private var apiKey: String
    @State private var headersText: String
    @State private var paramsText: String
    @State private var bodyText: String
    @State private var busy = false
    @State private var result = ""
    @State private var resultFailed = false
    @State private var confirmingDelete = false
    let onChange: () -> Void

    init(preset: WebSearchPreset, onChange: @escaping () -> Void) {
        _preset = State(initialValue: preset)
        _apiKey = State(initialValue: WebSearchPresets.apiKey(for: preset.id))
        _headersText = State(initialValue: Self.jsonText(preset.config.extraHeaders))
        _paramsText = State(initialValue: Self.jsonText(preset.config.extraParams))
        _bodyText = State(initialValue: Self.jsonText(preset.config.extraBody))
        self.onChange = onChange
    }

    var body: some View {
        Form {
            Section {
                TextField("名称", text: $preset.name)
                TextField("https://example.com/search", text: $preset.config.url)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Picker("请求方法", selection: $preset.config.method) {
                    Text("GET").tag("GET")
                    Text("POST").tag("POST")
                }
                TextField("查询参数名", text: $preset.config.queryParam)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                Text("搜索服务")
            }

            Section {
                SecureField("API Key，不需要可留空", text: $apiKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Key Header", text: $preset.config.keyHeader)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Header 前缀", text: $preset.config.keyScheme)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Key 参数名", text: $preset.config.keyParam)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                Text("可选 Key")
            } footer: {
                Text("Key 只跟随这个预设保存。Header 与参数名同时存在时，优先使用 Header。")
            }

            Section {
                TextField("结果 JSON 路径", text: $preset.config.resultPath)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("标题字段，逗号分隔", text: Binding(
                    get: { preset.config.titleKeys.joined(separator: ", ") },
                    set: { preset.config.titleKeys = Self.splitList($0) }))
                TextField("链接字段，逗号分隔", text: Binding(
                    get: { preset.config.urlKeys.joined(separator: ", ") },
                    set: { preset.config.urlKeys = Self.splitList($0) }))
                TextField("摘要字段，逗号分隔", text: Binding(
                    get: { preset.config.snippetKeys.joined(separator: ", ") },
                    set: { preset.config.snippetKeys = Self.splitList($0) }))
                TextField("结果条数", value: $preset.config.topK, format: .number).keyboardType(.numberPad)
                TextField("超时秒数", value: $preset.config.timeout, format: .number).keyboardType(.numberPad)
            } header: {
                Text("结果解析")
            }

            Section {
                TextEditor(text: $headersText).frame(minHeight: 76)
                TextEditor(text: $paramsText).frame(minHeight: 76)
                TextEditor(text: $bodyText).frame(minHeight: 76)
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

            Section {
                Button("删除这个预设", role: .destructive) { confirmingDelete = true }
            } footer: {
                Text("删除后它的 Key 也从 Keychain 移除。")
            }
        }
        .navigationTitle(Text(verbatim: preset.title))
        .navigationBarTitleDisplayMode(.inline)
        .disabled(busy)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("完成") { dismiss() }
            }
        }
        .confirmationDialog("删除这个预设？", isPresented: $confirmingDelete) {
            Button("删除", role: .destructive) {
                WebSearchPresets.delete(preset.id)
                onChange()
                dismiss()
            }
        }
    }

    @MainActor
    private func save(andTest: Bool) async {
        busy = true
        defer { busy = false }
        do {
            preset.config.method = preset.config.method == "POST" ? "POST" : "GET"
            preset.config.queryParam = preset.config.queryParam.trimmedOr("q")
            preset.config.topK = max(1, min(20, preset.config.topK))
            preset.config.timeout = max(1, min(60, preset.config.timeout))
            preset.config.extraHeaders = try Self.parseObject(headersText)
            preset.config.extraParams = try Self.parseObject(paramsText)
            preset.config.extraBody = try Self.parseObject(bodyText)
            preset.name = preset.name.trimmingCharacters(in: .whitespacesAndNewlines)
            WebSearchPresets.update(preset)
            WebSearchPresets.saveKey(apiKey, for: preset.id)
            onChange()
            if andTest {
                result = try await WebSearchExecutor.search(query: "Qwen 是哪家公司开发的",
                                                            config: preset.config, key: apiKey)
                resultFailed = false
            } else {
                result = WebSearchPresets.current?.id == preset.id
                    ? "已保存，下一条消息立即使用这个预设。"
                    : "已保存。要在对话里用它，在预设列表里点它一下。"
                resultFailed = false
            }
        } catch {
            result = error.localizedDescription
            resultFailed = true
        }
    }

    private static func splitList(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == "," || $0 == "，" }).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
    }

    private static func parseObject(_ text: String) throws -> [String: String] {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return [:] }
        let object = try JSONSerialization.jsonObject(with: Data(text.utf8))
        guard let dict = object as? [String: String] else {
            throw WebSearchExecutor.SearchError(message: "JSON 必须是字符串键值对象")
        }
        return dict
    }

    private static func jsonText(_ object: [String: String]) -> String {
        guard !object.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
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
