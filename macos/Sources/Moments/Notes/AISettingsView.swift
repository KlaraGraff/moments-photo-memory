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
                    Text(verbatim: "Claude").tag(CloudProvider.claude.rawValue)
                    Text(String(localized: "OpenAI-compatible API")).tag(CloudProvider.openAICompatible.rawValue)
                }
                TextField(String(localized: "Model"), text: $model, prompt: Text(provider == .claude ? CloudProvider.claude.defaultModel : "model-name"))
                if provider == .openAICompatible {
                    TextField(String(localized: "Endpoint"), text: $baseURL, prompt: Text(verbatim: "https://example.com/v1"))
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
                    Spacer()
                    if isTesting { ProgressView().controlSize(.small) }
                    Button(String(localized: "Test connection")) { test() }
                        .disabled(isTesting || apiKey.isEmpty)
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
        .onAppear { loadKey(for: provider) }
        .onChange(of: providerRaw) { oldValue, newValue in
            if let old = CloudProvider(rawValue: oldValue) { storeKey(for: old) }
            let new = CloudProvider(rawValue: newValue) ?? .claude
            loadKey(for: new)
            if model.isEmpty || model == CloudProvider.claude.defaultModel { model = new.defaultModel }
            testResult = nil
        }
        .onDisappear { storeKey(for: provider) }
    }

    private func loadKey(for provider: CloudProvider) {
        apiKey = AIKeychain.key(for: provider) ?? ""
        keyEdited = false
    }

    private func storeKey(for provider: CloudProvider) {
        guard keyEdited else { return }
        AIKeychain.setKey(apiKey, for: provider)
        keyEdited = false
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
