import SwiftUI

/// Settings › AI Model as a page of its own.
struct AISettingsView: View {
    var body: some View {
        Form {
            AISettingsSections()
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(Paper.canvas)
        .tint(Paper.accent)
        .frame(width: SettingsLayout.width, height: SettingsLayout.height)
    }
}

/// AI organizing, in a few rows: on or off, which model, and for a custom
/// model its address, name and key. On by default with the on-device model;
/// a custom model is whatever service the person points it at. Only
/// sections, so it can sit in any settings Form.
struct AISettingsSections: View {
    @AppStorage(AISettings.enabledKey) private var enabled = true
    @AppStorage(AISettings.engineKey) private var engineRaw = AISettings.defaultEngine.rawValue
    @AppStorage(AISettings.providerKey) private var providerRaw = CloudProvider.claude.rawValue
    @AppStorage(AISettings.modelKey) private var model = ""
    @AppStorage(AISettings.baseURLKey) private var baseURL = ""
    @State private var apiKey = ""
    /// Only a key the person typed is ever written, so a failed keychain read
    /// can't erase the stored key.
    @State private var keyEdited = false
    @State private var status: ConnectionStatus = .idle

    private enum ConnectionStatus: Equatable {
        case idle
        case incomplete
        case testing
        case connected
        case failed(String)
    }

    private var engine: AIEngine {
        AIEngine(rawValue: engineRaw) ?? .onDevice
    }

    var body: some View {
        Section {
            Toggle(String(localized: "Organize memories with AI after you write"), isOn: $enabled)
                .accessibilityIdentifier("settings.ai-enabled")
            if enabled {
                Picker(String(localized: "Model"), selection: $engineRaw) {
                    Text(String(localized: "On this Mac")).tag(AIEngine.onDevice.rawValue)
                    Text(String(localized: "Custom")).tag(AIEngine.cloud.rawValue)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("settings.ai-engine")
                switch engine {
                case .onDevice:
                    LabeledContent(String(localized: "Status")) {
                        if let reason = AppleOnDeviceOrganizer.unavailableReason() {
                            Text(reason).foregroundStyle(Paper.muted)
                        } else {
                            Label(String(localized: "Ready"), systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        }
                    }
                    .font(.callout)
                case .cloud:
                    TextField(String(localized: "Address"), text: $baseURL, prompt: Text(verbatim: "https://example.com/v1"))
                        .accessibilityIdentifier("settings.ai-address")
                    TextField(String(localized: "Model name"), text: $model, prompt: Text(verbatim: "model-name"))
                        .accessibilityIdentifier("settings.ai-model")
                    SecureField(String(localized: "API key"), text: Binding(
                        get: { apiKey },
                        set: { apiKey = $0; keyEdited = true }
                    ))
                    .onSubmit { storeKey() }
                    .accessibilityIdentifier("settings.ai-key")
                    LabeledContent(String(localized: "Status")) { statusView }
                        .font(.callout)
                }
            }
        } footer: {
            Text(footer)
        }
        .onAppear {
            moveOldKeyToCustom()
            apiKey = AIKeychain.key(for: .openAICompatible) ?? ""
            keyEdited = false
        }
        .onDisappear { storeKey() }
        // Saves the key and checks the connection once typing settles; a
        // newer edit cancels the wait.
        .task(id: "\(enabled)|\(engineRaw)|\(baseURL)|\(model)|\(apiKey)") { await checkConnection() }
    }

    private var footer: String {
        let words = String(localized: "Your words are never changed. What AI adds is marked AI and can be undone.")
        guard enabled else { return words }
        switch engine {
        case .onDevice:
            return String(localized: "The model runs on this Mac; your words never leave it.") + " " + words
        case .cloud:
            return String(localized: "Only the words you wrote, the photo's date and its place name are sent. Never the photo itself or GPS coordinates.")
                + " " + String(localized: "The key is kept in your Mac's keychain.") + " " + words
        }
    }

    @ViewBuilder
    private var statusView: some View {
        switch status {
        case .idle:
            EmptyView()
        case .incomplete:
            Text(String(localized: "Fill in the address, model name and API key.")).foregroundStyle(Paper.muted)
        case .testing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(String(localized: "Testing…")).foregroundStyle(Paper.muted)
            }
        case .connected:
            Label(String(localized: "Connected."), systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed(let message):
            Text(message).foregroundStyle(Paper.muted)
        }
    }

    /// A key saved for Anthropic before the custom model becomes the custom
    /// model's, with Anthropic's address, so nothing has to be typed again.
    private func moveOldKeyToCustom() {
        guard CloudProvider(rawValue: providerRaw) == .claude else { return }
        if let old = AIKeychain.key(for: .claude) {
            if AIKeychain.key(for: .openAICompatible) == nil {
                AIKeychain.setKey(old, for: .openAICompatible)
            }
            if baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                baseURL = "https://api.anthropic.com/v1"
            }
            if model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                model = CloudProvider.claude.defaultModel
            }
        }
        providerRaw = CloudProvider.openAICompatible.rawValue
    }

    private func storeKey() {
        guard keyEdited else { return }
        AIKeychain.setKey(apiKey, for: .openAICompatible)
        keyEdited = false
    }

    private func checkConnection() async {
        guard enabled, engine == .cloud else {
            status = .idle
            return
        }
        let filledIn = [baseURL, model, apiKey].allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard filledIn else {
            storeKey()
            status = .incomplete
            return
        }
        do { try await Task.sleep(for: .milliseconds(800)) } catch { return }
        storeKey()
        status = .testing
        var settings = AISettings.load()
        settings.provider = .openAICompatible
        let organizer = NoteOrganizerFactory.cloudOrganizer(settings: settings, apiKey: AIKeychain.key(for:))
        do {
            _ = try await organizer.organize(NoteOrganizerContext(noteText: String(localized: "The café by the river was quiet in the afternoon.")))
            guard !Task.isCancelled else { return }
            status = .connected
        } catch {
            guard !Task.isCancelled else { return }
            status = .failed(error.localizedDescription)
        }
    }
}
