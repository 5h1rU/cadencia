import SwiftUI
import CadenciaCore

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            List {
                Section("Account") {
                    NavigationLink { AccountView() } label: {
                        LabeledContent {
                            Text(model.state.athlete?.name ?? "")
                        } label: {
                            Label("Intervals.icu", systemImage: "person.crop.circle")
                        }
                    }
                    NavigationLink { SyncView() } label: {
                        LabeledContent {
                            if !model.pendingUploads.isEmpty { Text("\(model.pendingUploads.count) pending") }
                        } label: {
                            Label("Sync", systemImage: "arrow.triangle.2.circlepath")
                        }
                    }
                }

                Section("Data") {
                    NavigationLink { DataSourcesView() } label: { Label("Sources", systemImage: "heart.text.square") }
                    NavigationLink { FTPSettingsView() } label: {
                        LabeledContent { Text(Format.watts(model.workingFTP)) } label: { Label("FTP", systemImage: "bolt") }
                    }
                }

                Section("Training") {
                    NavigationLink { CoachSettingsView() } label: { Label("Coach", systemImage: "sparkles") }
                    NavigationLink { RidePreferencesView() } label: { Label("Ride", systemImage: "bicycle") }
                }

                Section {
                    LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")
                    Link(destination: URL(string: "https://intervals.icu/api/v1/docs")!) { Label("Intervals API documentation", systemImage: "book") }
                } header: {
                    Text("About")
                } footer: {
                    Text("Cadencia keeps Intervals.icu as the system of record. Nothing is stored on other servers.")
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Settings")
        }
    }
}

struct AccountView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmSignOut = false

    var body: some View {
        List {
            Section {
                LabeledContent("Athlete", value: model.state.athlete?.name ?? "")
                LabeledContent("Athlete id", value: model.state.athlete?.id ?? "")
                LabeledContent("Method", value: method)
                LabeledContent("Last sync", value: Format.relative(model.state.lastSyncAt))
            } header: {
                Text("Connection")
            } footer: {
                Text("Your credential lives only in this phone's Keychain.")
            }
            Section {
                Button("Sign out", role: .destructive) { confirmSignOut = true }
            } footer: {
                if !model.pendingUploads.isEmpty {
                    Text("\(model.pendingUploads.count) rides have not reached Intervals yet. They stay on this phone and upload when the same athlete signs back in.")
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Account")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Sign out of Intervals.icu?", isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button("Sign out", role: .destructive) { Task { await model.signOut() } }
        } message: {
            if model.pendingUploads.isEmpty { Text("Rides already in Intervals are unaffected.") }
            else { Text("\(model.pendingUploads.count) pending uploads are kept and resume when you reconnect this athlete.") }
        }
    }

    private var method: String {
        switch model.credential {
        case .apiKey: return String(localized: "API key")
        case .oauth: return String(localized: "OAuth")
        case nil: return "–"
        }
    }
}

struct SyncView: View {
    @Environment(AppModel.self) private var model

    private var entries: [UploadEntry] {
        model.state.ledger.entries.filter { $0.athleteID == model.athleteID }.sorted { ($0.lastAttemptAt ?? .distantPast) > ($1.lastAttemptAt ?? .distantPast) }
    }

    var body: some View {
        List {
            Section {
                ForEach(entries) { e in
                    let ride = model.state.rideIndex.first { $0.id == e.rideID }
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(ride?.name ?? "Ride")
                            HStack(spacing: 4) {
                                if let ride { Text(ride.startedAt, style: .date) }
                                Text("·")
                                Text(e.state.title)
                            }
                            .font(.footnote).foregroundStyle(.secondary)
                            if let err = e.lastError, e.state != .confirmed { Text(err).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                        }
                    } icon: {
                        Image(systemName: e.state.symbol).foregroundStyle(e.state == .confirmed ? .green : (e.state == .needsReconnect ? .orange : .secondary))
                    }
                }
                if entries.isEmpty { Text("No rides recorded on this phone yet.").foregroundStyle(.secondary) }
            } header: {
                Text("Uploads")
            } footer: {
                Text("A ride is saved here first, then sent to Intervals. “Checking” means the request went out but no answer came back; it is matched by id before any retry, so nothing is uploaded twice.")
            }
            Section {
                Button {
                    Task { await model.runUploads() }
                } label: {
                    HStack { if model.isUploading { ProgressView() }; Text("Retry now") }
                }
                .disabled(model.isUploading || model.pendingUploads.isEmpty)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Sync")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct DataSourcesView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List {
            Section {
                Toggle("Read Apple Health", isOn: Binding(get: { model.state.settings.readHealth }, set: { on in
                    model.updateSettings { $0.readHealth = on }
                    if on { Task { await model.readHealth(); model.prescribeToday() } }
                }))
                Toggle("Save rides to Apple Health", isOn: Binding(get: { model.state.settings.writeWorkoutsToHealth }, set: { on in model.updateSettings { $0.writeWorkoutsToHealth = on } }))
                LabeledContent("Last read", value: Format.relative(model.state.lastHealthReadAt))
            } header: {
                Text("Apple Health")
            } footer: {
                Text("HRV (SDNN), resting heart rate and sleep from your watch. Health values win over Intervals for the same day.")
            }
            Section {
                Toggle("Send Health wellness to Intervals", isOn: Binding(get: { model.state.settings.pushWellnessToIntervals }, set: { on in model.updateSettings { $0.pushWellnessToIntervals = on } }))
            } header: {
                Text("Intervals.icu")
            } footer: {
                Text("Off by default: if Intervals already receives Apple Health through its own integration, leave this off to avoid duplicates.")
            }
            Section("Status") {
                LabeledContent("Health available", value: HealthKitService.isAvailable ? String(localized: "Yes") : String(localized: "No"))
                LabeledContent("Wellness days", value: "\(model.state.wellness.count)")
                LabeledContent("Activities (42 d)", value: "\(model.state.activities.count)")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Sources")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct FTPSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var showReview = false

    var body: some View {
        List {
            Section {
                LabeledContent("Working FTP", value: Format.watts(model.workingFTP))
                LabeledContent("Intervals FTP", value: Format.watts(model.state.athlete?.ftp))
                LabeledContent("Intervals indoor FTP", value: Format.watts(model.state.athlete?.indoorFTP))
                if let e = model.state.ftpEstimate { LabeledContent("Latest estimate", value: "\(e.watts) W · \(e.confidence.rawValue)") }
            } footer: {
                Text("Indoor FTP is used when Intervals has one. Estimates come from the 42-day power curve and only become the working FTP when you accept them.")
            }
            Section {
                Button("Review estimate") { showReview = true }.disabled(model.state.ftpEstimate == nil)
                if model.state.acceptedFTP != nil {
                    Button("Use the Intervals value again") { model.useIntervalsFTP() }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("FTP")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showReview) { FTPReviewView() }
    }
}

struct CoachSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var key = ""
    @State private var endpoint = ""
    @State private var modelName = ""
    @State private var signingIn = false
    @State private var signInError: String?
    @State private var planModels: [LLMCoach.Model] = []
    @State private var confirmSignOut = false

    var body: some View {
        @Bindable var model = model
        Form {
            chatGPTSection
            modelSection
            apiKeySection
            Section {
                Button("Save") {
                    if key != Self.maskedKey { model.setLLMKey(key) }
                    model.updateSettings {
                        if let url = URL(string: endpoint), url.scheme?.hasPrefix("http") == true { $0.llmEndpoint = url }
                        if !modelName.trimmingCharacters(in: .whitespaces).isEmpty { $0.llmModel = modelName }
                    }
                }
            } footer: {
                Text(currentSource)
            }
        }
        .navigationTitle("Coach")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            endpoint = model.state.settings.llmEndpoint.absoluteString
            modelName = model.state.settings.llmModel
            key = model.hasLLMKey ? Self.maskedKey : ""
        }
        .task(id: model.chatGPT?.accessToken) { await loadPlanModels() }
        .alert("Could not sign in", isPresented: Binding(get: { signInError != nil }, set: { if !$0 { signInError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(signInError ?? "") }
        .sheet(isPresented: $model.showChatGPTWelcome) { ChatGPTWelcomeView() }
        .confirmationDialog("Sign out of ChatGPT?", isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button("Sign out", role: .destructive) { Task { await model.signOutChatGPT() } }
        } message: {
            Text("The coach goes back to your API key, or to on-device rules if there is none.")
        }
    }

    // MARK: ChatGPT plan

    @ViewBuilder private var chatGPTSection: some View {
        if let account = model.chatGPT {
            Section {
                LabeledContent("Account", value: account.email ?? account.subject)
                if account.planUsageEnabled {
                    Label("Using ChatGPT plan", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                    Link(destination: ChatGPTAuth.usageSettingsURL) {
                        Label("Manage usage", systemImage: "arrow.up.right.square")
                    }
                } else {
                    Label("Plan usage not enabled", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    signInButton("Enable ChatGPT plan usage", requestPlanUsage: true)
                }
                Button("Sign out of ChatGPT", role: .destructive) { confirmSignOut = true }
            } header: {
                Text("ChatGPT")
            } footer: {
                Text("Eligible coach requests count against your ChatGPT plan. Tokens live only in this phone's Keychain; nothing goes through a Cadencia server.")
            }
        } else {
            Section {
                signInButton("Continue with ChatGPT", requestPlanUsage: false)
            } header: {
                Text("Use your ChatGPT plan")
            } footer: {
                Text("Run the coach with usage included in your ChatGPT plan instead of paying per request with an API key. You sign in with OpenAI in a browser sheet; Cadencia never sees your password.")
            }
        }
    }

    private func signInButton(_ title: LocalizedStringKey, requestPlanUsage: Bool) -> some View {
        Button {
            signingIn = true
            Task {
                defer { signingIn = false }
                do { try await model.signInWithChatGPT(requestPlanUsage: requestPlanUsage) }
                catch ChatGPTSignIn.Failure.cancelled {}
                catch { signInError = error.localizedDescription }
            }
        } label: {
            HStack {
                Spacer()
                if signingIn { ProgressView().tint(.white) } else { Image(systemName: "bubble.left.and.text.bubble.right.fill") }
                Text(title).fontWeight(.semibold)
                Spacer()
            }
            .foregroundStyle(.white)
            .padding(.vertical, 6)
        }
        .buttonStyle(.borderedProminent)
        .tint(.black)
        .disabled(signingIn)
        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
        .listRowBackground(Color.clear)
    }

    // MARK: Model

    private var modelSection: some View {
        Section {
            Picker("Model", selection: $modelName) {
                if model.coachSource == .chatGPTPlan, !planModels.isEmpty {
                    ForEach(planModels) { m in
                        VStack(alignment: .leading) {
                            Text(m.name)
                            Text(m.id).font(.caption).foregroundStyle(.secondary)
                        }
                        .tag(m.id)
                    }
                    if !planModels.contains(where: { $0.id == modelName }) { Text(modelName).tag(modelName) }
                } else {
                    ForEach(AppConfig.llmModelPresets, id: \.id) { preset in
                        VStack(alignment: .leading) {
                            Text(preset.id)
                            Text(preset.note).font(.caption).foregroundStyle(.secondary)
                        }
                        .tag(preset.id)
                    }
                    if !AppConfig.llmModelPresets.contains(where: { $0.id == modelName }) { Text(modelName).tag(modelName) }
                }
            }
            .pickerStyle(.navigationLink)
            TextField("Custom model id", text: $modelName)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
        } header: {
            Text("Model")
        } footer: {
            if model.coachSource == .chatGPTPlan {
                Text("Models listed here are the ones your ChatGPT plan can use.")
            }
        }
    }

    private func loadPlanModels() async {
        guard model.coachSource == .chatGPTPlan else { planModels = []; return }
        planModels = (try? await model.listCoachModels()) ?? []
    }

    // MARK: API key

    private var apiKeySection: some View {
        Section {
            SecureField("API key", text: $key)
                .textContentType(.password)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            TextField("Endpoint", text: $endpoint)
                .keyboardType(.URL)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
        } header: {
            Text("API key (alternative)")
        } footer: {
            Text(model.chatGPT?.planUsageEnabled == true
                 ? "Used only if you sign out of ChatGPT. Any OpenAI-compatible chat completions endpoint."
                 : "Any OpenAI-compatible chat completions endpoint. The key is stored in the Keychain and only ever sent to this endpoint, together with today's readiness, your plan and your words. Leave it empty to interpret on the phone only.")
        }
    }

    private var currentSource: String {
        switch model.coachSource {
        case .chatGPTPlan: return String(localized: "Currently: ChatGPT plan · \(model.state.settings.llmModel)")
        case .apiKey: return String(localized: "Currently: API key · \(model.state.settings.llmModel)")
        case .onDevice: return String(localized: "Currently: on-device interpretation")
        }
    }

    private static let maskedKey = "••••••••"
}

/// Shown once after the first sign-in with plan usage, as OpenAI's guidelines ask.
struct ChatGPTWelcomeView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "bubble.left.and.text.bubble.right.fill")
                .font(.system(size: 56))
                .foregroundStyle(.primary)
            Text("You're using your ChatGPT plan")
                .font(.title2.bold())
                .multilineTextAlignment(.center)
            Text("Eligible coach requests in Cadencia use your ChatGPT plan. You can review and manage usage in ChatGPT settings at any time.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
            Link("Manage usage", destination: ChatGPTAuth.usageSettingsURL)
                .font(.subheadline)
            Spacer()
            Button { dismiss() } label: {
                Text("Got it").fontWeight(.semibold).frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(24)
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }
}

struct RidePreferencesView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section {
                Toggle("ERG by default", isOn: Binding(get: { model.state.settings.ergByDefault }, set: { on in model.updateSettings { $0.ergByDefault = on } }))
            } footer: {
                Text("You can still switch ERG off before each ride.")
            }
            Section("Devices") {
                ForEach(BluetoothManager.Role.allCases) { role in
                    LabeledContent(roleTitle(role)) {
                        if model.bluetooth.remembered[role] != nil {
                            Button("Forget") { model.bluetooth.forget(role) }
                        } else {
                            Text("Not paired").foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("Ride")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func roleTitle(_ role: BluetoothManager.Role) -> LocalizedStringKey {
        switch role {
        case .trainer: return "Smart trainer"
        case .heartRate: return "Heart rate"
        case .powerMeter: return "Power meter"
        }
    }
}

#Preview {
    SettingsView().environment(PreviewData.model())
}
