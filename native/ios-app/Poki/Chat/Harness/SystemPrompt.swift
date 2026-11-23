import SwiftUI

/// The chat's system prompt: the file the app ships, or the owner's replacement saved on this iPhone.
/// Keyed apart from the model accounts, so editing the prompt never touches a key or an address.
enum SystemPromptStore {
    static let key = "chat.systemPrompt"

    /// What the app ships: `agent-system.md` in the bundle, next to the harness.
    static var bundled: String {
        guard let url = Bundle.main.url(forResource: "agent-system", withExtension: "md"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return text
    }

    /// The owner's replacement, or nil while the bundled one runs.
    static var saved: String? {
        guard let text = UserDefaults.standard.string(forKey: key),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }

    static var isEditing: Bool { saved != nil }

    /// What the next request carries.
    static var current: String { saved ?? bundled }

    /// Saves the editor's text; empty text falls back to the bundled prompt.
    static func save(_ text: String) {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            reset()
        } else {
            UserDefaults.standard.set(text, forKey: key)
            ModelKeys.saved += 1
        }
    }

    /// One tap back to the bundled prompt; it takes effect on the next message.
    static func reset() {
        UserDefaults.standard.removeObject(forKey: key)
        ModelKeys.saved += 1
    }
}

/// Edits the chat's system prompt in place, with the bundled one one tap away.
struct PromptEditorView: View {
    @State private var text = SystemPromptStore.current
    @State private var showsSaved = false
    @State private var confirmingReset = false
    @State private var showingDefault = false

    var body: some View {
        List {
            Section {
                TextEditor(text: $text)
                    .font(.system(.footnote, design: .monospaced))
                    .frame(minHeight: 340)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("prompt.editor")
            } header: {
                Text("系统提示词")
            } footer: {
                Text(SystemPromptStore.isEditing
                     ? "正在用你保存的版本；保存后下一条消息即生效。"
                     : "正在用 App 自带的默认版本。")
            }

            Section {
                Button {
                    SystemPromptStore.save(text)
                    showsSaved = true
                } label: {
                    Text("保存并生效")
                }
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Button(role: .destructive) {
                    confirmingReset = true
                } label: {
                    Text("恢复默认")
                }

                Button {
                    showingDefault = true
                } label: {
                    Text("查看默认内容")
                }

                Button {
                    text = SystemPromptStore.current
                } label: {
                    Text("重新载入当前生效的文本")
                }
            }
        }
        .navigationTitle("提示词")
        .navigationBarTitleDisplayMode(.inline)
        .alert("已保存", isPresented: $showsSaved) {
            Button(role: .cancel) {} label: { Text("好") }
        } message: {
            Text("下一条消息开始使用修改后的提示词。")
        }
        .alert("恢复默认？", isPresented: $confirmingReset) {
            Button(role: .destructive) {
                SystemPromptStore.reset()
                text = SystemPromptStore.current
            } label: { Text("恢复默认") }
            Button(role: .cancel) {} label: { Text("取消") }
        } message: {
            Text("将用 App 自带的提示词覆盖你保存的版本；想改回来随时再编辑。")
        }
        .sheet(isPresented: $showingDefault) {
            NavigationStack {
                ScrollView {
                    Text(SystemPromptStore.bundled)
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
                .navigationTitle("默认提示词")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button { showingDefault = false } label: { Text("关闭") }
                    }
                }
            }
        }
    }
}
