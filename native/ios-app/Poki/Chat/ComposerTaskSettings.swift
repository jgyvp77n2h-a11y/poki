import SwiftUI

private extension VerticalAlignment {
    private enum ApprovalTitleCenter: AlignmentID {
        static func defaultValue(in dimensions: ViewDimensions) -> CGFloat {
            dimensions[VerticalAlignment.center]
        }
    }

    static let approvalTitleCenter = VerticalAlignment(ApprovalTitleCenter.self)
}

/// The model button under the message opens this sheet: the models of every account set up, grouped by
/// account, then how Poki asks before it acts. It uses the same settings as Poki's profile and Settings.
struct ComposerTaskSettings: View {
    enum Kind: String, Identifiable {
        case model
        case search

        var id: Self { self }

        var title: String { self == .model ? "模型" : "联网搜索" }
    }

    struct ModelSelection: Equatable {
        let provider: ModelProvider
        let id: String

        static var simulatorPreview: Self? {
            #if DEBUG && targetEnvironment(simulator)
            if ProcessInfo.processInfo.arguments.contains("-pokiComposerModelPreview"),
               let first = ModelProvider.chatgpt.models.first {
                return Self(provider: .chatgpt, id: first.id)
            }
            #endif
            return nil
        }
    }

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var contentHeight: CGFloat?
    @State private var modelVersion = ModelKeys.saved
    let kind: Kind
    let approvalIconSize: CGFloat
    @Binding var previewSelection: ModelSelection?
    let openModelSetup: () -> Void

    var body: some View {
        NavigationStack {
            List {
                switch kind {
                case .model:
                    modelOptions
                    approvalOptions
                case .search:
                    searchOptions
                }
            }
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                ceil(geometry.contentSize.height + geometry.contentInsets.top)
            } action: { _, height in
                if height > 0 { contentHeight = height }
            }
            .environment(\.defaultMinListRowHeight, 44)
            .settingsPage()
            .navigationTitle(kind.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") { dismiss() }
                        .accessibilityIdentifier("composer.settings.close")
                }
            }
        }
        .presentationDetents([contentHeight.map { .height($0) } ?? .medium])
        .presentationDragIndicator(.visible)
        .onReceive(NotificationCenter.default.publisher(for: ModelKeys.changed)) { _ in
            modelVersion = ModelKeys.saved
        }
    }

    private var approvalOptions: some View {
        Section {
            ForEach(ApprovalClassifier.Mode.allCases) { mode in
                let selected = model.approvalMode == mode
                Button {
                    model.approvalMode = mode
                    dismiss()
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .approvalTitleCenter, spacing: 12) {
                            mode.composerIcon(size: approvalIconSize)
                                .frame(minWidth: approvalIconSize + 2)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(verbatim: mode.title)
                                    .alignmentGuide(.approvalTitleCenter) { $0[VerticalAlignment.center] }
                                if !typeSize.isAccessibilitySize {
                                    approvalDescription(for: mode)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            selectionMark(selected)
                        }
                        if typeSize.isAccessibilitySize {
                            approvalDescription(for: mode)
                        }
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityIdentifier("composer.approval.\(mode.rawValue)")
            }
        } header: {
            Text("Approvals")
        } footer: {
            Text(ApprovalCopy.alwaysConfirm)
        }
        .sensoryFeedback(.selection, trigger: model.approvalMode)
    }

    private func approvalDescription(for mode: ApprovalClassifier.Mode) -> some View {
        Text(mode.composerDescription)
            .font(.subheadline)
            .foregroundStyle(.secondary)
    }

    /// The search presets the composer's globe button picks from: tap one and the next message searches
    /// with it, exactly as tapping a model switches the model that answers.
    @ViewBuilder private var searchOptions: some View {
        let _ = modelVersion
        let presets = WebSearchPresets.all
        let selected = WebSearchPresets.selectedID

        Section {
            Button {
                WebSearchPresets.choose(nil)
                dismiss()
            } label: {
                searchRow(title: "关闭", detail: "下一条消息不提供 web_search", selected: selected == nil)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("composer.search.off")

            ForEach(presets) { preset in
                Button {
                    WebSearchPresets.choose(preset.id)
                    dismiss()
                } label: {
                    searchRow(title: preset.title, detail: preset.detail, selected: selected == preset.id)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("composer.search.\(preset.id)")
            }
        } header: {
            Text("联网搜索配置")
        } footer: {
            if presets.isEmpty {
                Text("还没有预设。在下面的管理页新建一个搜索服务地址。")
            } else {
                Text("选中后下一条消息立即使用它，和切换模型一样即时。")
            }
        }

        Section {
            NavigationLink { WebSearchSettingsView() } label: {
                Label("管理预设", systemImage: "slider.horizontal.3")
            }
        }
    }

    private func searchRow(title: String, detail: String, selected: Bool) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title)
                Text(verbatim: detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            selectionMark(selected)
        }
        .contentShape(.rect)
    }

    @ViewBuilder private var modelOptions: some View {
        let _ = modelVersion
        let storage = model.storage
        let providers = ModelProvider.allCases.filter {
            ModelAccounts.isSetUp($0, storage: storage) && ModelAccounts.canChat($0)
        }
        #if DEBUG && targetEnvironment(simulator)
        if previewSelection != nil {
            modelGroup(AppLocalization.text(LocalizedStringResource("ChatGPT Subscription")),
                       provider: .chatgpt, choices: ModelProvider.chatgpt.models)
            modelGroup("DeepSeek API", provider: .deepseek, choices: ModelProvider.deepseek.models)
        } else {
            configuredModels(providers, storage: storage)
        }
        #else
        configuredModels(providers, storage: storage)
        #endif
        Section {
            Button(action: openModelSetup) {
                Label("Add Model", systemImage: "plus")
                    .labelStyle(.titleAndIcon)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("composer.model.setup")
        } footer: {
            if providers.isEmpty, previewSelection == nil {
                Text("Poki needs a model account before it can reply.")
            }
        }
    }

    private func configuredModels(_ providers: [ModelProvider], storage: PokiStorage) -> some View {
        ForEach(providers) { provider in
            let choices = ModelCatalog.available(provider, storage: storage)
            if provider == .custom {
                ForEach(CustomProviders.all(in: storage)) { custom in
                    let entries = choices.compactMap { choice -> ChatModelChoice? in
                        guard let selection = CustomProviders.parse(choice.id), selection.provider == custom.id else { return nil }
                        return ChatModelChoice(id: choice.id, name: selection.model)
                    }
                    modelGroup(custom.displayName, provider: provider, choices: entries)
                }
            } else {
                modelGroup(provider.name, provider: provider, choices: choices)
            }
        }
    }

    @ViewBuilder private func modelGroup(_ title: String, provider: ModelProvider, choices: [ChatModelChoice]) -> some View {
        if !choices.isEmpty {
            let storage = model.storage
            let current = previewSelection ?? ModelSelection(
                provider: ModelKeys.selectedProvider(in: storage), id: ModelKeys.selectedModel(in: storage)
            )
            Section {
                ForEach(choices) { choice in
                    let selection = ModelSelection(provider: provider, id: choice.id)
                    let selected = selection == current
                    Button {
                        guard !selected else { return }
                        if previewSelection != nil {
                            previewSelection = selection
                        } else {
                            ModelKeys.choose(provider, model: choice.id, in: storage)
                        }
                        dismiss()
                    } label: {
                        HStack {
                            Text(verbatim: choice.name)
                            Spacer(minLength: 8)
                            selectionMark(selected)
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                    .accessibilityIdentifier("composer.model.\(provider.rawValue).\(choice.id)")
                }
            } header: {
                Text(verbatim: title)
            }
        }
    }

    private func selectionMark(_ selected: Bool) -> some View {
        Image(systemName: "checkmark")
            .font(.body.weight(.semibold))
            .foregroundStyle(Tint.blueText)
            .opacity(selected ? 1 : 0)
            .accessibilityHidden(true)
    }
}

extension ApprovalClassifier.Mode {
    @ViewBuilder func composerIcon(size: CGFloat) -> some View {
        switch self {
        case .reply:
            Image(systemName: "hand.raised")
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(.secondary)
        case .confirm:
            Image(systemName: "checkmark.circle")
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(.secondary)
        case .off:
            Image(systemName: "exclamationmark.shield")
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(Tint.red)
        }
    }

    fileprivate var composerDescription: LocalizedStringKey {
        switch self {
        case .reply: "Poki asks in the chat and proceeds after you reply."
        case .confirm: "Tap Allow or Don’t Allow in the Live Activity, a notification, or Poki."
        case .off: "Optional steps run automatically without asking."
        }
    }
}
