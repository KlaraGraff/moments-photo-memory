import SwiftUI

/// AI on the one settings page: one switch, off until the person turns it
/// on. On, only what their choice needs is shown: nothing more on a Mac that
/// runs Apple's on-device model, and the key for a cloud model where it
/// cannot run or the person prefers one.
struct AISettingsSections: View {
    @AppStorage(AISettings.enabledKey) private var enabled = false
    @AppStorage(AISettings.engineKey) private var engineRaw = AISettings.defaultEngine.rawValue
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

    private let onDeviceAvailable = AppleOnDeviceOrganizer.unavailableReason() == nil

    private var provider: CloudProvider {
        CloudProvider(rawValue: providerRaw) ?? .claude
    }

    private var engine: AIEngine {
        AIEngine(rawValue: engineRaw) ?? AISettings.defaultEngine
    }

    /// The key and the model are asked for only where a cloud model can be
    /// used: this Mac cannot run Apple's, or the person chose the cloud.
    private var showsCloud: Bool {
        !onDeviceAvailable || engine == .cloud || fallbackRaw == OnDeviceFallback.useCloud.rawValue
    }

    var body: some View {
        Section {
            Toggle(String(localized: "Let AI fix places from memories"), isOn: $enabled)
                .accessibilityIdentifier("settings.ai-enabled")
        } footer: {
            Text(String(localized: "Off, your memories are just the words you write and nothing is sent anywhere. On, after you write, AI corrects the photo's place and notes what the place is like. Your words are never changed."))
        }

        if enabled {
            if onDeviceAvailable {
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
                    if engine == .onDevice {
                        Picker(String(localized: "When the on-device model can't run"), selection: $fallbackRaw) {
                            Text(String(localized: "Keep my words and organize them later")).tag(OnDeviceFallback.keepForLater.rawValue)
                            Text(String(localized: "Use the cloud model")).tag(OnDeviceFallback.useCloud.rawValue)
                        }
                    }
                } footer: {
                    Text(String(localized: "Whichever you choose, a corrected place can still be changed by hand in the photo's details."))
                }
            }

            if showsCloud {
                Section(String(localized: "Cloud model")) {
                    // Why there is no choice of model on this Mac.
                    if let reason = AppleOnDeviceOrganizer.unavailableReason() {
                        LabeledContent(String(localized: "On-device model")) {
                            Text(reason).foregroundStyle(Paper.muted)
                        }
                        .font(.callout)
                    }
                    Picker(String(localized: "Provider"), selection: $providerRaw) {
                        Text(verbatim: "Anthropic").tag(CloudProvider.claude.rawValue)
                        Text(String(localized: "OpenAI-compatible API")).tag(CloudProvider.openAICompatible.rawValue)
                    }
                    SecureField(String(localized: "API key"), text: Binding(
                        get: { apiKey },
                        set: { apiKey = $0; keyEdited = true }
                    ))
                        .onSubmit { storeKey(for: provider) }
                        .accessibilityIdentifier("settings.ai-key")
                        // On the key field, so the keychain is read and the
                        // provider asked only while a cloud model is in use.
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
                        .task(id: "\(providerRaw) \(apiKey)") {
                            // Wait for typing or pasting to settle; a newer key cancels this one.
                            do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
                            // Kept as soon as it is typed: the page has no tab to
                            // leave, and a closed window must not lose the key.
                            storeKey(for: provider)
                            await loadModels()
                        }
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
            }
        }
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
        // Nothing is asked of the provider while AI is off or the cloud
        // model is not in use.
        guard enabled, showsCloud, provider == .claude, !key.isEmpty else {
            fetchedModels = []
            return
        }
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
