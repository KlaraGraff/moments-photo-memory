import SwiftUI

/// Settings › AI Model: which model organizes notes. The on-device Apple model
/// is the default; a cloud model is optional and uses the person's own key.
struct AISettingsView: View {
    @AppStorage(AISettings.engineKey) private var engineRaw = AIEngine.onDevice.rawValue
    @AppStorage(AISettings.providerKey) private var providerRaw = CloudProvider.claude.rawValue
    @AppStorage(AISettings.modelKey) private var model = CloudProvider.claude.defaultModel
    @AppStorage(AISettings.baseURLKey) private var baseURL = ""
    @AppStorage(AISettings.fallbackKey) private var fallbackRaw = OnDeviceFallback.keepForLater.rawValue
    @State private var apiKey = ""
    /// Only a key the person typed is ever written, so a failed keychain read
    /// can't erase the stored key.
    @State private var keyEdited = false
    @State private var testResult: String?
    @State private var isTesting = false
    /// Models the Anthropic key can use, fetched as soon as a key is there.
    @State private var fetchedModels: [CloudModelOption] = []
    @State private var isLoadingModels = false
    @State private var modelsError: String?

    private var provider: CloudProvider {
        CloudProvider(rawValue: providerRaw) ?? .claude
    }

    var body: some View {
        Form {
            Section {
                Picker(String(localized: "Model for organizing notes"), selection: $engineRaw) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(String(localized: "On-device Apple model (recommended)"))
                        Text(String(localized: "Runs on this Mac; your words never leave it. Free, nothing to set up. Needs Apple Intelligence."))
                            .font(.caption)
                            .foregroundStyle(Paper.muted)
                    }
                    .tag(AIEngine.onDevice.rawValue)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(String(localized: "Cloud model"))
                        Text(String(localized: "Better with long notes. Uses your own API key; the provider bills you."))
                            .font(.caption)
                            .foregroundStyle(Paper.muted)
                    }
                    .tag(AIEngine.cloud.rawValue)
                }
                .pickerStyle(.radioGroup)

                LabeledContent(String(localized: "On-device model")) {
                    if let reason = AppleOnDeviceOrganizer.unavailableReason() {
                        Text(reason).foregroundStyle(Paper.muted)
                    } else {
                        Label(String(localized: "Ready"), systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }
                .font(.callout)
            } footer: {
                Text(String(localized: "Whichever you choose, the result is written right away. Click the mark next to a photo's place to change or undo it."))
            }

            Section(String(localized: "Cloud model")) {
                Picker(String(localized: "Provider"), selection: $providerRaw) {
                    Text(verbatim: "Anthropic").tag(CloudProvider.claude.rawValue)
                    Text(String(localized: "OpenAI-compatible API")).tag(CloudProvider.openAICompatible.rawValue)
                }
                SecureField(String(localized: "API key"), text: Binding(
                    get: { apiKey },
                    set: { apiKey = $0; keyEdited = true }
                ))
                    .onSubmit { storeKey(for: provider) }
                HStack(alignment: .firstTextBaseline) {
                    Text(String(localized: "The key is kept in your Mac's keychain."))
                        .font(.caption)
                        .foregroundStyle(Paper.muted)
                    if provider == .claude {
                        Link(String(localized: "Get a key"), destination: URL(string: "https://platform.claude.com/settings/keys")!)
                            .font(.caption)
                    }
                    Spacer()
                    if isTesting { ProgressView().controlSize(.small) }
                    Button(String(localized: "Test connection")) { test() }
                        .disabled(isTesting || apiKey.isEmpty)
                }
                if provider == .claude {
                    Picker(String(localized: "Model"), selection: $model) {
                        ForEach(anthropicOptions) { option in
                            Text(verbatim: modelLabel(option)).tag(option.id)
                        }
                    }
                    if isLoadingModels {
                        ProgressView().controlSize(.small)
                    } else if let modelsError {
                        Text(modelsError)
                            .font(.caption)
                            .foregroundStyle(Paper.muted)
                    }
                } else {
                    TextField(String(localized: "Model"), text: $model, prompt: Text(verbatim: "model-name"))
                    TextField(String(localized: "Endpoint"), text: $baseURL, prompt: Text(verbatim: "https://example.com/v1"))
                }
                if let testResult {
                    Text(testResult)
                        .font(.caption)
                        .foregroundStyle(Paper.muted)
                }
                Text(String(localized: "Only the words you wrote, the photo's date and its place name are sent. Never the photo itself or GPS coordinates."))
                    .font(.caption)
                    .foregroundStyle(Paper.muted)
            }

            Section {
                Picker(String(localized: "When the on-device model can't run"), selection: $fallbackRaw) {
                    Text(String(localized: "Keep my words and organize them later")).tag(OnDeviceFallback.keepForLater.rawValue)
                    Text(String(localized: "Use the cloud model")).tag(OnDeviceFallback.useCloud.rawValue)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(Paper.canvas)
        .tint(Paper.accent)
        .frame(width: 560)
        .onAppear {
            loadKey(for: provider)
            // An empty model from the old text field already meant the default.
            if provider == .claude, model.trimmingCharacters(in: .whitespaces).isEmpty {
                model = CloudProvider.claude.defaultModel
            }
        }
        .onChange(of: providerRaw) { oldValue, newValue in
            if let old = CloudProvider(rawValue: oldValue) { storeKey(for: old) }
            let new = CloudProvider(rawValue: newValue) ?? .claude
            loadKey(for: new)
            switch new {
            case .claude where !model.hasPrefix("claude-"): model = new.defaultModel
            case .openAICompatible where model.hasPrefix("claude-"): model = new.defaultModel
            default: break
            }
            testResult = nil
        }
        .onDisappear { storeKey(for: provider) }
        .task(id: provider == .claude ? apiKey : "") { await loadModels() }
    }

    /// The fetched list, or our own short list before there is a key. The
    /// chosen model always stays in it.
    private var anthropicOptions: [CloudModelOption] {
        var options = fetchedModels.isEmpty
            ? ClaudeModel.allCases.map { CloudModelOption(id: $0.rawValue, displayName: $0.displayName) }
            : fetchedModels
        if !model.isEmpty, !options.contains(where: { $0.id == model }) {
            options.append(CloudModelOption(id: model, displayName: model))
        }
        return options
    }

    private func modelLabel(_ option: CloudModelOption) -> String {
        guard let known = ClaudeModel(rawValue: option.id) else { return option.displayName }
        return "\(option.displayName) · \(known.summary)"
    }

    private func loadModels() async {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        modelsError = nil
        guard provider == .claude, !key.isEmpty else {
            fetchedModels = []
            return
        }
        // Wait for typing or pasting to settle; a newer key cancels this one.
        do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
        isLoadingModels = true
        defer { isLoadingModels = false }
        do {
            let models = try await AnthropicModelList.fetch(apiKey: key)
            guard !Task.isCancelled else { return }
            fetchedModels = models
        } catch {
            guard !Task.isCancelled else { return }
            fetchedModels = []
            modelsError = error.localizedDescription
        }
    }

    private func loadKey(for provider: CloudProvider) {
        apiKey = AIKeychain.key(for: provider) ?? ""
        keyEdited = false
    }

    private func storeKey(for provider: CloudProvider) {
        guard keyEdited else { return }
        AIKeychain.setKey(apiKey, for: provider)
        keyEdited = false
        // Pasting a key on a Mac that can't run Apple's model means the
        // person wants the cloud model; don't make them find a second switch.
        let hasKey = !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if hasKey, engineRaw == AIEngine.onDevice.rawValue, AppleOnDeviceOrganizer.unavailableReason() != nil {
            engineRaw = AIEngine.cloud.rawValue
        }
    }

    private func test() {
        storeKey(for: provider)
        var settings = AISettings.load()
        settings.provider = provider
        let organizer = NoteOrganizerFactory.cloudOrganizer(settings: settings, apiKey: AIKeychain.key(for:))
        isTesting = true
        testResult = nil
        Task {
            do {
                _ = try await organizer.organize(NoteOrganizerContext(noteText: String(localized: "The café by the river was quiet in the afternoon.")))
                testResult = String(localized: "Connected.")
            } catch {
                testResult = error.localizedDescription
            }
            isTesting = false
        }
    }
}
