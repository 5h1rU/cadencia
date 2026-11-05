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
                    NavigationLink { CyclistMeasurementsView() } label: { Label("Cyclist profile", systemImage: "person.crop.circle") }
                    NavigationLink { FTPSettingsView() } label: {
                        LabeledContent { Text(Format.watts(model.workingFTP)) } label: { Label("FTP", systemImage: "bolt") }
                    }
                }

                Section("Training") {
                    NavigationLink { CoachSettingsView() } label: { Label("Coach", systemImage: "sparkles") }
                    NavigationLink { RidePreferencesView() } label: { Label("Ride", systemImage: "bicycle") }
                }

                InfoSection {
                    LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")
                    Link(destination: URL(string: "https://intervals.icu/api/v1/docs")!) { Label("Intervals API documentation", systemImage: "book") }
                } header: {
                    Text("About")
                } information: {
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
    @State private var signingOut = false

    var body: some View {
        List {
            InfoSection {
                LabeledContent("Athlete", value: model.state.athlete?.name ?? "")
                LabeledContent("Athlete id", value: model.state.athlete?.id ?? "")
                LabeledContent("Method", value: method)
                LabeledContent("Last sync", value: Format.relative(model.state.lastSyncAt))
            } header: {
                Text("Connection")
            } information: {
                Text("Your credential lives only in this phone's Keychain.")
            }
            Section {
                if !model.pendingUploads.isEmpty {
                    Text("\(model.pendingUploads.count) rides have not reached Intervals yet. They stay on this phone and upload when the same athlete signs back in.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                // An OAuth sign-out waits for Intervals to disconnect the app before the account clears.
                Button(role: .destructive) { confirmSignOut = true } label: {
                    // An HStack, not LabeledContent: a LabeledContent title stays full strength while disabled.
                    HStack {
                        Text("Sign out")
                        Spacer()
                        if signingOut { ProgressView() }
                    }
                }
                .disabled(signingOut)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Account")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Sign out of Intervals.icu?", isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button("Sign out", role: .destructive) {
                guard !signingOut else { return }
                signingOut = true
                Task { await model.signOut(); signingOut = false }
            }
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
            InfoSection {
                ForEach(entries) { e in
                    let ride = model.state.rideIndex.first { $0.id == e.rideID }
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(ride?.name ?? String(localized: "Ride"))
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
            } information: {
                Text("A ride is saved here first, then sent to Intervals. “Checking” means the request went out but no answer came back; it is matched by id before any retry, so nothing is uploaded twice.")
            }
            Section {
                // An explicit retry skips the backoff; parked (needs reconnect) uploads never count.
                Button {
                    Task { await model.runUploads(force: true) }
                } label: {
                    // An HStack, not LabeledContent, so the title greys out with the button and the spinner trails.
                    HStack {
                        Text("Retry now")
                        Spacer()
                        if model.isUploading { ProgressView() }
                    }
                }
                .disabled(model.isUploading || !model.canRetryUploads)
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
            InfoSection {
                Toggle("Read Apple Health", isOn: Binding(get: { model.state.settings.readHealth }, set: { on in
                    model.updateSettings { $0.readHealth = on }
                    if on { Task { await model.readHealth(); await model.askCoachForToday() } }
                }))
                Toggle("Save rides to Apple Health", isOn: Binding(get: { model.state.settings.writeWorkoutsToHealth }, set: { on in model.updateSettings { $0.writeWorkoutsToHealth = on } }))
                LabeledContent("Last read", value: Format.relative(model.state.lastHealthReadAt))
            } header: {
                Text("Apple Health")
            } information: {
                Text("Cadencia reads HRV, resting heart rate, sleep and available body measurements from Apple Health.")
            }
            InfoSection {
                Toggle("Send Health wellness to Intervals", isOn: Binding(get: { model.state.settings.pushWellnessToIntervals }, set: { on in model.updateSettings { $0.pushWellnessToIntervals = on } }))
            } header: {
                Text("Intervals.icu")
            } information: {
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
            InfoSection {
                LabeledContent("Working FTP", value: Format.watts(model.workingFTP))
                LabeledContent("Intervals FTP", value: Format.watts(model.state.athlete?.ftp))
                LabeledContent("Intervals indoor FTP", value: Format.watts(model.state.athlete?.indoorFTP))
                if let e = model.state.ftpEstimate { LabeledContent("Latest estimate", value: "\(e.watts) W · \(e.confidence.rawValue)") }
            } header: {
                Text("FTP")
            } information: {
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
    /// The fields as last loaded or saved (the key masked when one exists), so Save and onAppear know what was edited.
    @State private var savedKey = ""
    @State private var savedEndpoint = ""
    @FocusState private var focusedField: Field?
    @State private var signingIn = false
    @State private var signInError: String?
    @State private var availableModels: [LLMCoach.Model] = []
    @State private var modelsError: String?
    /// Bumped by Save and Reload models to load the list again.
    @State private var modelsReload = 0
    /// The `modelsTaskID` whose load finished. Until it matches, the Model row shows a spinner.
    @State private var loadedModelsID: String?
    @State private var confirmSignOut = false

    private enum Field { case key, endpoint }

    var body: some View {
        @Bindable var model = model
        Form {
            chatGPTSection
            modelSection
            apiKeySection
            Section {
                Text(currentSource)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button("Save") { save() }
                    .disabled(!hasChanges || endpointURL == nil)
            }
        }
        .navigationTitle("Coach")
        .navigationBarTitleDisplayMode(.inline)
        // The sign-in ends after the browser sheet closes (the token exchange), and the welcome sheet is
        // presented from this screen: leaving it then would lose the one-time welcome. Also blocks swipe-back.
        .navigationBarBackButtonHidden(signingIn)
        .onAppear {
            // Coming back from the Model picker must not wipe unsaved edits. Untouched fields reload, so this
            // screen left open in another tab never offers to save back what was changed there.
            guard key == savedKey, endpoint == savedEndpoint else { return }
            loadFields()
        }
        .task(id: modelsTaskID) {
            // Coming back from the Model picker restarts the task; a finished list is not loaded again.
            let id = modelsTaskID
            guard loadedModelsID != id else { return }
            await loadModels(id)
        }
        .alert("Could not sign in", isPresented: Binding(get: { signInError != nil }, set: { if !$0 { signInError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(signInError ?? "") }
        .sheet(isPresented: $model.showChatGPTWelcome) { ChatGPTWelcomeView() }
        .confirmationDialog("Sign out of ChatGPT?", isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button("Sign out", role: .destructive) { Task { await model.signOutChatGPT() } }
        } message: {
            Text("The coach goes back to your API key. Without one, Cadencia cannot decide your days.")
        }
    }

    // MARK: ChatGPT plan

    @ViewBuilder private var chatGPTSection: some View {
        if let account = model.chatGPT {
            InfoSection {
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
                // A re-consent that is still exchanging tokens would sign the account straight back in.
                Button("Sign out of ChatGPT", role: .destructive) { confirmSignOut = true }
                    .disabled(signingIn)
            } header: {
                Text("ChatGPT")
            } information: {
                Text("Eligible coach requests count against your ChatGPT plan. Tokens live only in this phone's Keychain; nothing goes through a Cadencia server.")
            }
        } else {
            InfoSection {
                signInButton("Continue with ChatGPT", requestPlanUsage: false)
            } header: {
                Text("Use your ChatGPT plan")
            } information: {
                Text("Run the coach with usage included in your ChatGPT plan instead of paying per request with an API key. You sign in with OpenAI in a browser sheet; Cadencia never sees your password.")
            }
        }
    }

    private func signInButton(_ title: LocalizedStringKey, requestPlanUsage: Bool) -> some View {
        Button {
            guard !signingIn else { return }
            signingIn = true
            Task {
                defer { signingIn = false }
                do { try await model.signInWithChatGPT(requestPlanUsage: requestPlanUsage) }
                catch ChatGPTSignIn.Failure.cancelled {}
                catch { signInError = error.localizedDescription }
            }
        } label: {
            // The title stays in place while busy so the button keeps its size; the spinner takes the
            // button's `.primary` tint, readable on the grey disabled fill, and .regular stops it inheriting .large.
            Label(title, systemImage: "bubble.left.and.text.bubble.right.fill")
                .labelStyle(.titleAndIcon)
                .font(.headline)
                .multilineTextAlignment(.center)
                .foregroundStyle(Color(.systemBackground))
                .opacity(signingIn ? 0 : 1)
                .overlay { if signingIn { ProgressView().controlSize(.regular) } }
                .frame(maxWidth: .infinity)
        }
        // Black on white in light mode, white on black in dark: `.primary` flips with the appearance,
        // so the button never disappears into a dark list background.
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .tint(.primary)
        .disabled(signingIn)
        .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    // MARK: Model

    private var modelSection: some View {
        InfoSection {
            if loadingModels {
                LabeledContent("Model") {
                    HStack { Text(model.state.settings.llmModel); ProgressView() }
                }
            } else if !availableModels.isEmpty {
                Picker("Model", selection: Binding(get: { model.state.settings.llmModel }, set: { model.setCoachModel($0) })) {
                    ForEach(availableModels) { m in
                        VStack(alignment: .leading) {
                            Text(m.name)
                            if m.name != m.id { Text(m.id).font(.caption).foregroundStyle(.secondary) }
                        }
                        .tag(m.id)
                    }
                    if !availableModels.contains(where: { $0.id == model.state.settings.llmModel }) {
                        Text(model.state.settings.llmModel).tag(model.state.settings.llmModel)
                    }
                }
                .pickerStyle(.navigationLink)
            } else {
                LabeledContent("Model", value: model.state.settings.llmModel)
                if let modelsError {
                    Label(modelsError, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.secondary)
                }
                Button("Reload models", systemImage: "arrow.clockwise") { modelsReload += 1 }
                    .disabled(model.coachSource == nil)
            }
        } header: {
            Text("Model")
        } information: {
            switch model.coachSource {
            case .chatGPTPlan: Text("The models your ChatGPT plan can use. Changing it asks the coach to decide today again.")
            case .apiKey: Text("The models your API key can use. Changing it asks the coach to decide today again.")
            case nil: Text("Connect ChatGPT or an API key to choose a model.")
            }
        }
    }

    /// Keyed on the account, its plan consent, the coach source and Save/Reload, not on the access token:
    /// a token refresh during the load must not cancel and restart it.
    private var modelsTaskID: String {
        [model.chatGPT?.subject ?? "", String(model.chatGPT?.planUsageEnabled == true),
         String(describing: model.coachSource), String(modelsReload)].joined(separator: "|")
    }

    /// True until the list for the current inputs has arrived, so a fresh screen never flashes Reload models.
    private var loadingModels: Bool { model.coachSource != nil && loadedModelsID != modelsTaskID }

    private func loadModels(_ id: String) async {
        guard model.coachSource != nil else { availableModels = []; modelsError = nil; loadedModelsID = id; return }
        do {
            let models = try await model.listCoachModels()
            // A list for the current inputs is kept even if the screen stopped waiting for it.
            guard modelsTaskID == id else { return }
            availableModels = models
            modelsError = models.isEmpty ? String(localized: "Your account returned no models.") : nil
        } catch {
            // Cancelled or superseded: change nothing. The task for the current inputs loads again.
            guard !Task.isCancelled, modelsTaskID == id else { return }
            if error is CancellationError || (error as? URLError)?.code == .cancelled {
                // A cancellation this screen did not ask for is not an error: keep the list, stop the spinner.
                modelsError = nil
            } else {
                availableModels = []
                modelsError = error.localizedDescription
            }
        }
        loadedModelsID = id
    }

    // MARK: API key

    private var apiKeySection: some View {
        InfoSection {
            SecureField("API key", text: $key)
                .textContentType(.password)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .focused($focusedField, equals: .key)
            TextField("Endpoint", text: $endpoint)
                .keyboardType(.URL)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .focused($focusedField, equals: .endpoint)
                // Red while it is not an http(s) URL; Save stays disabled until it is.
                .foregroundStyle(endpointURL == nil ? Color.red : Color.primary)
        } header: {
            Text("API key (alternative)")
        } information: {
            Text(model.chatGPT?.planUsageEnabled == true
                 ? "Used only if you sign out of ChatGPT. Any OpenAI-compatible chat completions endpoint."
                 : "Any OpenAI-compatible chat completions endpoint. The key is stored in the Keychain and only ever sent to this endpoint, together with your recovery data, your plan and your words.")
        }
    }

    /// The endpoint field as an http(s) URL with a host; nil while it is not one.
    private var endpointURL: URL? {
        let text = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        // `https://:443/v1` parses with an empty host, so the host must also be non-empty.
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host()?.isEmpty == false else { return nil }
        return url
    }

    private var hasChanges: Bool { key != savedKey || endpointURL != model.state.settings.llmEndpoint }

    /// Saves only what changed, closes the keyboard and re-masks the key, so Save greys out at once.
    private func save() {
        guard hasChanges, let url = endpointURL else { return }
        focusedField = nil
        if key != savedKey { model.setLLMKey(key) }
        if url != model.state.settings.llmEndpoint { model.updateSettings { $0.llmEndpoint = url } }
        loadFields()
        modelsReload += 1
    }

    /// Shows what is saved: the stored endpoint, and the masked key when one exists.
    private func loadFields() {
        endpoint = model.state.settings.llmEndpoint.absoluteString
        key = model.hasLLMKey ? Self.maskedKey : ""
        savedKey = key
        savedEndpoint = endpoint
    }

    private var currentSource: String {
        switch model.coachSource {
        case .chatGPTPlan: return String(localized: "Currently: ChatGPT plan · \(model.state.settings.llmModel)")
        case .apiKey: return String(localized: "Currently: API key · \(model.state.settings.llmModel)")
        case nil: return String(localized: "No coach connected. Sign in with ChatGPT or add an API key; Cadencia needs one to work.")
        }
    }

    private static let maskedKey = "••••••••"
}

/// Shown once after the first sign-in with plan usage, as OpenAI's guidelines ask.
struct ChatGPTWelcomeView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        // Scrolls (and can grow to .large) so the notice is never cut off by Dynamic Type or longer copy.
        ScrollView {
            VStack(spacing: 20) {
                Image(systemName: "bubble.left.and.text.bubble.right.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(.primary)
                    .accessibilityHidden(true)
                Text("You're using your ChatGPT plan")
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                Text("Eligible coach requests in Cadencia use your ChatGPT plan. You can review and manage usage in ChatGPT settings at any time.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
                Link(destination: ChatGPTAuth.usageSettingsURL) {
                    Text("Manage usage")
                        .frame(minHeight: 44)
                        .contentShape(.rect)
                }
                .font(.subheadline)
            }
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaInset(edge: .bottom) {
            Button { dismiss() } label: {
                Text("Got it").font(.headline).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding()
            .background(.bar)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

struct RidePreferencesView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            InfoSection {
                Toggle("ERG by default", isOn: Binding(get: { model.state.settings.ergByDefault }, set: { on in model.updateSettings { $0.ergByDefault = on } }))
            } header: {
                Text("ERG mode")
            } information: {
                Text("You can still switch ERG off before each ride.")
            }
            InfoSection {
                Toggle("Coach voice", isOn: Binding(get: { model.state.settings.rideVoice }, set: { on in model.updateSettings { $0.rideVoice = on } }))
                Toggle("Captions", isOn: Binding(get: { model.state.settings.rideCaptions }, set: { on in model.updateSettings { $0.rideCaptions = on } }))
                if model.hasOpenAISpeech {
                    Picker("Voice", selection: Binding(get: { model.state.settings.coachVoice }, set: { v in model.updateSettings { $0.coachVoice = v } })) {
                        ForEach(CoachVoice.options) { option in
                            VStack(alignment: .leading) {
                                Text(option.name)
                                Text(LocalizedStringKey(option.note)).font(.caption).foregroundStyle(.secondary)
                            }
                            .tag(option.id)
                        }
                    }
                    .pickerStyle(.navigationLink)
                } else {
                    LabeledContent("Voice", value: String(localized: "iPhone voice"))
                }
            } header: {
                Text("Coach during rides")
            } information: {
                if model.hasOpenAISpeech {
                    Text("At the start of each block, halfway through long ones and at the finish, the coach reads your numbers and says what they mean. Spoken with an OpenAI voice over your music; you can mute it from the ride screen.")
                } else {
                    Text("At the start of each block, halfway through long ones and at the finish, the coach reads your numbers and says what they mean. The ChatGPT sign-in covers text only, so the phone's own voice speaks; add an OpenAI API key under Coach to unlock the OpenAI coach voices. For a better iPhone voice, download an enhanced one in Settings › Accessibility › Spoken Content › Voices.")
                }
            }
            Section("Devices") {
                ForEach(BluetoothManager.Role.allCases) { role in
                    LabeledContent(roleTitle(role)) {
                        if model.bluetooth.remembered[role] != nil {
                            // Borderless: only the word forgets the device, not a tap anywhere on the row.
                            Button("Forget", role: .destructive) { model.bluetooth.forget(role) }
                                .buttonStyle(.borderless)
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
